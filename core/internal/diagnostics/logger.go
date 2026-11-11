package diagnostics

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	maxLogBytes = 5 << 20
	logFiles    = 3
)

// Event is the exportable schema. Paths, headers, raw errors and arbitrary
// process output have no representation in it.
type Event struct {
	Time      time.Time `json:"time"`
	Version   string    `json:"version"`
	Level     string    `json:"level"`
	Component string    `json:"component"`
	Operation string    `json:"operation"`
	Code      string    `json:"code,omitempty"`
	RequestID string    `json:"requestID,omitempty"`
	TaskID    string    `json:"taskID,omitempty"`
	Status    int       `json:"status,omitempty"`
	ElapsedMS int64     `json:"elapsedMs,omitempty"`
}

type Logger struct {
	dir        string
	version    string
	events     chan Event
	done       chan struct{}
	fallback   atomic.Bool
	debugUntil atomic.Int64
	mu         sync.RWMutex
	closed     bool
}

func Start(dataDir string) *Logger {
	version := "development"
	if info, ok := debug.ReadBuildInfo(); ok {
		if info.Main.Version != "(devel)" {
			version = info.Main.Version
		}
		for _, setting := range info.Settings {
			if setting.Key == "vcs.revision" && len(setting.Value) >= 12 {
				version = setting.Value[:12]
				break
			}
		}
	}
	logger := &Logger{
		dir:     filepath.Join(dataDir, "diagnostics", "core"),
		version: version,
		events:  make(chan Event, 256),
		done:    make(chan struct{}),
	}
	go logger.run()
	return logger
}

func (l *Logger) DebugForHalfHour() {
	l.debugUntil.Store(time.Now().Add(30 * time.Minute).UnixNano())
}

func (l *Logger) Handler() slog.Handler { return safeHandler{logger: l} }

func (l *Logger) Close() {
	l.mu.Lock()
	if !l.closed {
		close(l.events)
		l.closed = true
	}
	l.mu.Unlock()
	<-l.done
}

func (l *Logger) submit(event Event) {
	event.Version = l.version
	event.Time = event.Time.UTC()
	l.mu.RLock()
	defer l.mu.RUnlock()
	if !l.closed {
		select {
		case l.events <- event:
		default:
			// Storage backpressure must not stall NAS requests.
		}
	}
}

func (l *Logger) run() {
	defer close(l.done)
	var log *os.File
	var size int64
	var retryAt time.Time
	defer func() {
		if log != nil {
			_ = log.Close()
		}
	}()
	for event := range l.events {
		if time.Now().Before(retryAt) {
			continue
		}
		line, err := json.Marshal(event)
		if err != nil {
			continue
		}
		line = append(line, '\n')
		if log == nil {
			log, size, err = openLog(l.dir)
		}
		if err == nil && size+int64(len(line)) > maxLogBytes {
			err = log.Close()
			log = nil
			if err == nil {
				err = rotateLogs(l.dir)
			}
			if err == nil {
				log, size, err = openLog(l.dir)
			}
		}
		if err == nil {
			var written int
			written, err = log.Write(line)
			size += int64(written)
		}
		if err != nil {
			if log != nil {
				_ = log.Close()
				log = nil
			}
			retryAt = time.Now().Add(time.Minute)
			if !l.fallback.Swap(true) {
				_, _ = fmt.Fprintln(os.Stderr, "LightIsle diagnostics unavailable")
			}
		} else {
			l.fallback.Store(false)
		}
	}
}

func openLog(dir string) (*os.File, int64, error) {
	// Both directories are local application data. Reject links and public
	// permissions before opening any file, including when retrying a write.
	for _, name := range []string{filepath.Dir(dir), dir} {
		if err := os.Mkdir(name, 0700); err != nil && !os.IsExist(err) {
			return nil, 0, err
		}
		info, err := os.Lstat(name)
		if err != nil {
			return nil, 0, err
		}
		if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
			return nil, 0, os.ErrPermission
		}
	}
	name := logName(dir, 0)
	fd, err := unix.Open(name, unix.O_CREAT|unix.O_APPEND|unix.O_WRONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0600)
	if err != nil {
		return nil, 0, err
	}
	file := os.NewFile(uintptr(fd), name)
	var info unix.Stat_t
	if err := unix.Fstat(fd, &info); err != nil || info.Mode&unix.S_IFMT != unix.S_IFREG ||
		info.Nlink != 1 || info.Mode&0077 != 0 {
		_ = file.Close()
		return nil, 0, os.ErrPermission
	}
	return file, info.Size, nil
}

func logName(dir string, index int) string {
	return filepath.Join(dir, fmt.Sprintf("events-%d.jsonl", index))
}

func rotateLogs(dir string) error {
	for i := logFiles - 1; i > 0; i-- {
		if err := os.Rename(logName(dir, i-1), logName(dir, i)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

type safeHandler struct{ logger *Logger }

func (h safeHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= slog.LevelInfo || time.Now().UnixNano() < h.logger.debugUntil.Load()
}

func (h safeHandler) Handle(ctx context.Context, record slog.Record) error {
	event, typed := ctx.Value(eventKey{}).(Event)
	if !typed {
		// Older calls often attach raw errors, file names or child output.
		// Only preassigned event names are recorded from this interface.
		event = legacyEvents[record.Message]
		if event.Operation == "" {
			if record.Level < slog.LevelWarn {
				return nil
			}
			event = Event{Component: "core", Operation: "runtime", Code: "core_warning"}
			if record.Level >= slog.LevelError {
				event.Code = "core_error"
			}
		}
	}
	event.Time = record.Time
	event.Level = record.Level.String()
	event.RequestID = safeID(event.RequestID)
	event.TaskID = safeID(event.TaskID)
	h.logger.submit(event)
	return nil
}

func (h safeHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h safeHandler) WithGroup(string) slog.Handler      { return h }

type eventKey struct{}

func safeID(id string) string {
	if len(id) < 16 || len(id) > 64 {
		return ""
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'f' || c >= '0' && c <= '9' || c == '-') {
			return ""
		}
	}
	return id
}

// Emit passes only a code-defined event to the structured logger. Callers
// must supply fixed component, operation and code values.
func Emit(ctx context.Context, level slog.Level, event Event) {
	slog.Log(context.WithValue(ctx, eventKey{}, event), level, "LightIsle diagnostic event")
}

var legacyEvents = map[string]Event{
	"HTTP server failure":                             {Component: "core", Operation: "listener", Code: "listener_failed"},
	"cannot bind local API":                           {Component: "core", Operation: "listener", Code: "listener_bind_failed"},
	"cannot initialize accounts":                      {Component: "core", Operation: "startup", Code: "accounts_unavailable"},
	"cannot initialize physical shared root registry": {Component: "storage", Operation: "startup", Code: "registry_unavailable"},
	"personal storage switch stopped":                 {Component: "storage", Operation: "switch", Code: "storage_switch_failed"},
	"trash sweep failed":                              {Component: "storage", Operation: "trash_sweep", Code: "trash_sweep_failed"},
	"cannot refresh automation":                       {Component: "automation", Operation: "refresh", Code: "automation_refresh_failed"},
	"dav credential lookup failed":                    {Component: "webdav", Operation: "authentication", Code: "credential_lookup_failed"},
}
