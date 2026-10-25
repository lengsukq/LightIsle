// Package downloads implements the bounded download center. It supervises a
// user-installed aria2c (Homebrew whitelist, never bundled), keeps a SQLite
// task journal, and publishes finished downloads into the share exclusively
// through the safe file APIs — a task can never write outside an authorized
// destination, overwrite an existing file, or exceed its declared budget.
package downloads

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/lengsukq/lightisle/core/internal/files"
)

const (
	StatusQueued    = "queued"
	StatusRunning   = "running"
	StatusPaused    = "paused"
	StatusCompleted = "completed"
	StatusFailed    = "failed"
	StatusCancelled = "cancelled"

	MaxTasks          = 100
	maxURLLength      = 2048
	maxDestinationLen = 1024
	maxTaskBytes      = int64(1) << 40 // per-task ceiling even when unlimited
	pollInterval      = time.Second
	importSuffixMax   = 999
)

var (
	ErrNotAvailable = errors.New("download_unavailable")
	ErrNotFound     = errors.New("download_not_found")
	ErrInput        = errors.New("download_invalid_request")
	ErrBusy         = errors.New("download_limit_reached")
)

// Publisher is the slice of the safe file API used to move finished
// downloads into the share. files.Access satisfies it.
type Publisher interface {
	Mkdir(string) error
	Upload(string, io.Reader) (int64, error)
}

// Options wires the manager into the daemon.
type Options struct {
	DataDir   string // daemon data dir; downloads.sqlite and staging live here
	Binary    string // resolved aria2c path; "" keeps the center unavailable
	Publisher Publisher
	// CanImport re-checks the owner's write grant at publish time; a grant
	// revoked after creation must stop the task, not smuggle files in.
	CanImport func(owner int64, destination string) bool
	// OnAlert raises/lowers a persistent "download_failed" alert.
	OnAlert func(active bool)
}

// Task is the JSON-facing journal row.
type Task struct {
	ID             string `json:"id"`
	Owner          int64  `json:"-"`
	URL            string `json:"url"`
	Destination    string `json:"destination"`
	Status         string `json:"status"`
	Filename       string `json:"filename,omitempty"`
	TotalBytes     int64  `json:"totalBytes"`
	CompletedBytes int64  `json:"completedBytes"`
	MaxBytes       int64  `json:"maxBytes"`
	Error          string `json:"error,omitempty"`
	CreatedAt      int64  `json:"createdAt"`
	UpdatedAt      int64  `json:"updatedAt"`
	CompletedAt    int64  `json:"completedAt,omitempty"`
}

type Manager struct {
	opts Options
	db   *sql.DB

	mu        sync.Mutex
	rpc       *RPC
	cmd       *exec.Cmd
	available bool
	version   string
	alertUp   bool

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// New opens the task journal and honestly retires everything that was in
// flight when the previous Core process died; aria2 state is not persisted,
// so those tasks fail with download_restarted and keep their one-click
// retry. The supervised process only starts when Start is called with a
// usable binary.
func New(opts Options) (*Manager, error) {
	if opts.DataDir == "" || opts.Publisher == nil || opts.CanImport == nil {
		return nil, errors.New("downloads: incomplete options")
	}
	db, err := sql.Open("sqlite3", filepath.Join(opts.DataDir, "downloads.sqlite")+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS download_tasks(
		id TEXT PRIMARY KEY,
		owner INTEGER NOT NULL,
		url TEXT NOT NULL,
		destination TEXT NOT NULL,
		max_bytes INTEGER NOT NULL DEFAULT 0,
		status TEXT NOT NULL CHECK(status IN ('queued','running','paused','completed','failed','cancelled')),
		gid TEXT NOT NULL DEFAULT '',
		filename TEXT NOT NULL DEFAULT '',
		total_bytes INTEGER NOT NULL DEFAULT 0,
		completed_bytes INTEGER NOT NULL DEFAULT 0,
		error TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL,
		completed_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE INDEX IF NOT EXISTS download_tasks_owner ON download_tasks(owner,created_at)`); err != nil {
		_ = db.Close()
		return nil, err
	}
	now := time.Now().Unix()
	if _, err := db.Exec(`UPDATE download_tasks SET status=?, error='download_restarted',
		updated_at=?, gid='' WHERE status IN ('running','paused') OR (status='queued' AND gid<>'')`,
		StatusFailed, now); err != nil {
		_ = db.Close()
		return nil, err
	}
	// Staging is transient by definition; nothing outside the journal
	// survives a restart.
	_ = os.RemoveAll(filepath.Join(opts.DataDir, "downloads-staging"))
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{opts: opts, db: db, ctx: ctx, cancel: cancel}, nil
}

// Start launches the supervised aria2c process and the poller. When the
// binary is missing the manager stays honestly unavailable.
func (m *Manager) Start() error {
	if m.opts.Binary == "" {
		return ErrNotAvailable
	}
	staging := filepath.Join(m.opts.DataDir, "downloads-staging")
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return err
	}
	port, err := freeLoopbackPort()
	if err != nil {
		return err
	}
	secret, err := randomToken()
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.rpc != nil {
		return nil
	}
	cmd := exec.Command(m.opts.Binary,
		"--enable-rpc",
		"--rpc-listen-port="+strconv.Itoa(port),
		"--rpc-secret="+secret,
		"--rpc-listen-all=false",
		"--dir="+staging,
		"--max-concurrent-downloads=3",
		"--max-connection-per-server=4",
		"--split=4",
		"--continue=true",
		"--allow-overwrite=false",
		"--auto-file-renaming=false",
		"--seed-time=0",
		"--quiet=true",
		"--stop-with-process="+strconv.Itoa(os.Getpid()),
	)
	if err := cmd.Start(); err != nil {
		return err
	}
	m.cmd = cmd
	m.rpc = NewRPC(port, secret)
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		_ = cmd.Wait()
	}()
	rpcCtx, cancel := context.WithTimeout(m.ctx, 8*time.Second)
	version, rpcErr := m.awaitReady(rpcCtx)
	cancel()
	if rpcErr != nil {
		m.stopLocked()
		return fmt.Errorf("%w: aria2 rpc not ready", ErrNotAvailable)
	}
	m.available = true
	m.version = version
	m.wg.Add(1)
	go m.pollLoop()
	return nil
}

func (m *Manager) awaitReady(ctx context.Context) (string, error) {
	ticker := time.NewTicker(150 * time.Millisecond)
	defer ticker.Stop()
	for {
		if version, err := m.rpc.GetVersion(ctx); err == nil {
			return version, nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ticker.C:
		}
	}
}

// Close stops the supervised process and the poller, then closes the journal.
func (m *Manager) Close() error {
	m.cancel()
	m.mu.Lock()
	if m.cmd != nil && m.cmd.Process != nil {
		_ = m.cmd.Process.Kill()
	}
	m.stopLocked()
	m.mu.Unlock()
	m.wg.Wait()
	return m.db.Close()
}

func (m *Manager) stopLocked() {
	m.available = false
	m.rpc = nil
	m.cmd = nil
}

// Available reports whether the download center can run on this machine.
func (m *Manager) Available() (bool, string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.available {
		return true, ""
	}
	if m.opts.Binary == "" {
		return false, "aria2_not_installed"
	}
	return false, "aria2_not_running"
}

func (m *Manager) Version() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.version
}

// ValidateURL enforces the protocol allowlist. file://, data:, userinfo and
// other exotic schemes never reach aria2.
func ValidateURL(raw string) error {
	if len(raw) > maxURLLength {
		return ErrInput
	}
	if strings.HasPrefix(raw, "magnet:") {
		if magnetPattern.MatchString(raw) {
			return nil
		}
		return ErrInput
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ErrInput
	}
	switch parsed.Scheme {
	case "http", "https", "ftp":
	default:
		return ErrInput
	}
	if parsed.Host == "" || parsed.User != nil {
		return ErrInput
	}
	if _, _, err := net.SplitHostPort(hostnamePort(parsed)); err != nil {
		// Hosts without an explicit port are fine; only malformed
		// bracket literals or ports fail SplitHostPort on the synthetic
		// form below.
		if parsed.Port() != "" {
			return ErrInput
		}
	}
	return nil
}

func hostnamePort(parsed *url.URL) string {
	if parsed.Port() != "" {
		return parsed.Host
	}
	return net.JoinHostPort(parsed.Hostname(), "80")
}

var magnetPattern = regexp.MustCompile(`^magnet:\?xt=urn:btih:[A-Za-z0-9]{32,40}(&[A-Za-z0-9_.%*-]+=[^&]*)*$`)

// ValidateDestination accepts "." (share root) or a relative in-share path.
func ValidateDestination(destination string) error {
	if destination == "." {
		return nil
	}
	if destination == "" || len(destination) > maxDestinationLen ||
		strings.HasPrefix(destination, "/") || strings.Contains(destination, "\\") ||
		strings.Contains(destination, "..") {
		return ErrInput
	}
	for _, segment := range strings.Split(destination, "/") {
		if segment == "" || segment == "." {
			return ErrInput
		}
	}
	return nil
}

// Create records a queued task and immediately hands it to aria2.
func (m *Manager) Create(owner int64, rawURL, destination string, maxBytes int64) (Task, error) {
	if maxBytes < 0 || maxBytes > maxTaskBytes {
		maxBytes = 0
	}
	if err := ValidateURL(rawURL); err != nil {
		return Task{}, err
	}
	if err := ValidateDestination(destination); err != nil {
		return Task{}, err
	}
	m.mu.Lock()
	available := m.available && m.rpc != nil
	m.mu.Unlock()
	if !available {
		return Task{}, ErrNotAvailable
	}
	var count int
	if err := m.db.QueryRow(`SELECT COUNT(*) FROM download_tasks
		WHERE owner=? AND status IN ('queued','running','paused')`, owner).Scan(&count); err != nil {
		return Task{}, err
	}
	if count >= MaxTasks {
		return Task{}, ErrBusy
	}
	now := time.Now().Unix()
	id, err := randomToken()
	if err != nil {
		return Task{}, err
	}
	task := Task{ID: id[:24], Owner: owner, URL: rawURL, Destination: destination,
		MaxBytes: maxBytes, Status: StatusQueued, CreatedAt: now, UpdatedAt: now}
	if _, err := m.db.Exec(`INSERT INTO download_tasks
		(id,owner,url,destination,max_bytes,status,created_at,updated_at)
		VALUES(?,?,?,?,?,?,?,?)`,
		task.ID, owner, task.URL, task.Destination, task.MaxBytes, task.Status, now, now); err != nil {
		return Task{}, err
	}
	m.kick(task.ID)
	return m.taskByID(task.ID, owner)
}

func (m *Manager) List(owner int64) ([]Task, error) {
	rows, err := m.db.Query(`SELECT id,url,destination,status,filename,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at FROM download_tasks
		WHERE owner=? ORDER BY created_at DESC LIMIT 200`, owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tasks []Task
	for rows.Next() {
		var item Task
		if err := rows.Scan(&item.ID, &item.URL, &item.Destination, &item.Status, &item.Filename,
			&item.TotalBytes, &item.CompletedBytes, &item.MaxBytes, &item.Error,
			&item.CreatedAt, &item.UpdatedAt, &item.CompletedAt); err != nil {
			return nil, err
		}
		tasks = append(tasks, item)
	}
	return tasks, rows.Err()
}

// Action applies pause, resume or retry to an own task.
func (m *Manager) Action(owner int64, id, action string) (Task, error) {
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return Task{}, err
	}
	switch action {
	case "pause":
		if task.Status != StatusRunning && task.Status != StatusQueued {
			return Task{}, ErrInput
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Pause(ctx, gid) })
		}
		m.update(id, "status", StatusPaused)
	case "resume":
		if task.Status != StatusPaused {
			return Task{}, ErrInput
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Unpause(ctx, gid) })
		} else {
			m.update(id, "status", StatusQueued)
			m.kick(id)
			return m.taskByID(id, owner)
		}
		m.update(id, "status", StatusRunning)
	case "retry":
		if task.Status != StatusFailed && task.Status != StatusCancelled {
			return Task{}, ErrInput
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
		}
		m.mu.Lock()
		available := m.available && m.rpc != nil
		m.mu.Unlock()
		if !available {
			return Task{}, ErrNotAvailable
		}
		m.update(id, "status", StatusQueued, "error", "", "gid", "", "filename", "",
			"total_bytes", int64(0), "completed_bytes", int64(0))
		m.kick(id)
	case "cancel":
		if task.Status == StatusCompleted || task.Status == StatusCancelled || task.Status == StatusFailed {
			return Task{}, ErrInput
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
		}
		m.update(id, "status", StatusCancelled, "gid", "")
		_ = os.RemoveAll(m.stagingDir(id))
	default:
		return Task{}, ErrInput
	}
	return m.taskByID(id, owner)
}

// Cancel stops a task; the journal row stays for audit.
func (m *Manager) Cancel(owner int64, id string) (Task, error) {
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return Task{}, err
	}
	if task.Status == StatusCompleted || task.Status == StatusCancelled || task.Status == StatusFailed {
		return task, nil
	}
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	m.update(id, "status", StatusCancelled, "gid", "")
	_ = os.RemoveAll(m.stagingDir(id))
	return m.taskByID(id, owner)
}

// Delete removes a terminal task from the journal; running tasks are
// cancelled first.
func (m *Manager) Delete(owner int64, id string) error {
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return err
	}
	if task.Status != StatusCompleted && task.Status != StatusCancelled && task.Status != StatusFailed {
		if _, err := m.Cancel(owner, id); err != nil {
			return err
		}
	}
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	_, err = m.db.Exec("DELETE FROM download_tasks WHERE id=? AND owner=?", id, owner)
	return err
}

func (m *Manager) stagingDir(id string) string {
	return filepath.Join(m.opts.DataDir, "downloads-staging", id)
}

// kick starts a queued task that is not yet known to aria2.
func (m *Manager) kick(id string) {
	m.mu.Lock()
	rpc := m.rpc
	available := m.available
	m.mu.Unlock()
	if !available || rpc == nil {
		return
	}
	go func() {
		task, gid, err := m.rowByIDUnscoped(id)
		if err != nil || task.Status != StatusQueued || gid != "" {
			return
		}
		options := map[string]any{
			"dir":                m.stagingDir(id),
			"continue":           "true",
			"allow-overwrite":    "false",
			"auto-file-renaming": "false",
			"max-tries":          "8",
			"retry-wait":         "3",
			"timeout":            "120",
			"seed-time":          "0",
		}
		ctx, cancel := context.WithTimeout(m.ctx, 15*time.Second)
		newGID, err := rpc.AddURI(ctx, task.URL, options)
		cancel()
		if err != nil {
			m.update(id, "status", StatusFailed, "error", sanitizeError(err))
			m.raiseAlert()
			return
		}
		m.update(id, "status", StatusRunning, "gid", newGID, "error", "")
	}()
}

func (m *Manager) pollLoop() {
	defer m.wg.Done()
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-ticker.C:
			m.pollOnce()
		}
	}
}

func (m *Manager) pollOnce() {
	m.mu.Lock()
	rpc := m.rpc
	available := m.available
	m.mu.Unlock()
	if !available || rpc == nil {
		return
	}
	rows, err := m.db.Query(`SELECT id,gid,url,destination,max_bytes,status FROM download_tasks
		WHERE status IN ('running','paused')`)
	if err != nil {
		return
	}
	type pending struct {
		id, gid, url, destination string
		maxBytes                  int64
	}
	var active []pending
	for rows.Next() {
		var item pending
		var status string
		if err := rows.Scan(&item.id, &item.gid, &item.url, &item.destination, &item.maxBytes, &status); err != nil {
			rows.Close()
			return
		}
		active = append(active, item)
	}
	rows.Close()
	for _, item := range active {
		ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
		status, err := rpc.TellStatus(ctx, item.gid)
		cancel()
		switch {
		case err != nil && IsGIDNotFound(err):
			m.failTask(item.id, "download_gone", item.gid)
		case err != nil:
			// Transient RPC error; the next tick retries.
		case status.Status == "complete":
			// Magnet links resolve through a metadata hop; follow the chain.
			if len(status.FollowedBy) > 0 {
				last := status.FollowedBy[len(status.FollowedBy)-1]
				m.update(item.id, "gid", last, "status", StatusRunning)
				continue
			}
			m.importDownload(item.id, item.destination)
		case status.Status == "error":
			m.failTask(item.id, firstNonEmpty(sanitizeText(status.ErrorMessage), "download_failed"), item.gid)
		case status.Status == "removed":
			m.failTask(item.id, "download_cancelled_externally", item.gid)
		case item.maxBytes > 0 && status.CompletedBytes > item.maxBytes:
			ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
			_ = rpc.Remove(ctx, item.gid)
			cancel()
			m.failTask(item.id, "download_exceeds_limit", item.gid)
		case status.Status == "paused":
			m.update(item.id, "status", StatusPaused, "total_bytes", status.TotalBytes, "completed_bytes", status.CompletedBytes)
		default: // active | waiting
			m.update(item.id, "status", StatusRunning, "total_bytes", status.TotalBytes, "completed_bytes", status.CompletedBytes)
		}
	}
	// Start queued tasks that lost their race earlier.
	queued, err := m.db.Query(`SELECT id FROM download_tasks WHERE status='queued' AND gid='' LIMIT 5`)
	if err != nil {
		return
	}
	var ids []string
	for queued.Next() {
		var id string
		if err := queued.Scan(&id); err == nil {
			ids = append(ids, id)
		}
	}
	queued.Close()
	for _, id := range ids {
		m.kick(id)
	}
	if healthy, err := m.noFailedActive(); err == nil && healthy {
		m.lowerAlert()
	}
}

// importDownload publishes the staged files through the safe file API.
func (m *Manager) importDownload(id, destination string) {
	task, gid, err := m.rowByIDUnscoped(id)
	if err != nil {
		return
	}
	if !m.opts.CanImport(task.Owner, destination) {
		m.failTask(id, "download_permission_revoked", gid)
		return
	}
	staging := m.stagingDir(id)
	var staged []string
	if err := filepath.Walk(staging, func(current string, info os.FileInfo, walkErr error) error {
		if walkErr != nil || info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return walkErr
		}
		staged = append(staged, current)
		return nil
	}); err != nil && !os.IsNotExist(err) {
		m.failTask(id, "download_staging_lost", gid)
		return
	}
	if len(staged) == 0 {
		m.failTask(id, "download_produced_no_files", gid)
		return
	}
	published := ""
	for _, source := range staged {
		relative, err := filepath.Rel(staging, source)
		if err != nil {
			m.failTask(id, "download_publish_failed", gid)
			return
		}
		info, err := os.Stat(source)
		if err != nil || !info.Mode().IsRegular() {
			m.failTask(id, "download_publish_failed", gid)
			return
		}
		if info.Size() > maxTaskBytes {
			m.failTask(id, "download_exceeds_limit", gid)
			return
		}
		target := path.Join(destination, filepath.ToSlash(relative))
		if destination == "." {
			target = path.Clean(filepath.ToSlash(relative))
		}
		if err := m.publishFile(source, target); err != nil {
			m.failTask(id, "download_publish_failed", gid)
			return
		}
		if published == "" {
			published = path.Base(target)
		}
	}
	now := time.Now().Unix()
	m.update(id, "status", StatusCompleted, "filename", published, "gid", "",
		"completed_at", now, "error", "")
	_ = os.RemoveAll(staging)
}

func (m *Manager) publishFile(source, target string) error {
	dir := path.Dir(target)
	if dir != "." && dir != "/" {
		// An existing directory is fine; the raw EEXIST from Mkdir and the
		// package sentinel both mean "already there".
		if err := m.opts.Publisher.Mkdir(dir); err != nil && !errors.Is(err, files.ErrExists) && !os.IsExist(err) {
			return err
		}
	}
	candidate := target
	for attempt := 2; ; attempt++ {
		handle, err := os.Open(source)
		if err != nil {
			return err
		}
		written, uploadErr := m.opts.Publisher.Upload(candidate, handle)
		closeErr := handle.Close()
		if uploadErr == nil && closeErr == nil {
			if info, statErr := os.Stat(source); statErr == nil && written != info.Size() {
				return fmt.Errorf("short publish: %d of %d", written, info.Size())
			}
			return nil
		}
		if !errors.Is(uploadErr, files.ErrExists) {
			return uploadErr
		}
		if attempt > importSuffixMax {
			return files.ErrExists
		}
		extension := path.Ext(target)
		stem := strings.TrimSuffix(target, extension)
		candidate = stem + " (" + strconv.Itoa(attempt) + ")" + extension
	}
}

func (m *Manager) failTask(id, reason, gid string) {
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	m.update(id, "status", StatusFailed, "error", reason, "gid", "")
	_ = os.RemoveAll(m.stagingDir(id))
	m.raiseAlert()
}

func (m *Manager) raiseAlert() {
	if m.opts.OnAlert == nil {
		return
	}
	m.mu.Lock()
	already := m.alertUp
	m.alertUp = true
	m.mu.Unlock()
	if !already {
		m.opts.OnAlert(true)
	}
}

func (m *Manager) lowerAlert() {
	if m.opts.OnAlert == nil {
		return
	}
	m.mu.Lock()
	was := m.alertUp
	m.alertUp = false
	m.mu.Unlock()
	if was {
		m.opts.OnAlert(false)
	}
}

func (m *Manager) noFailedActive() (bool, error) {
	// The alert mirrors terminal failures still visible in the journal;
	// a healthy center with no failed rows lowers it.
	var failed int
	if err := m.db.QueryRow(`SELECT COUNT(*) FROM download_tasks
		WHERE status='failed' AND updated_at>?`, time.Now().Add(-24*time.Hour).Unix()).Scan(&failed); err != nil {
		return false, err
	}
	return failed == 0, nil
}

func (m *Manager) withRPC(fn func(context.Context, *RPC)) {
	m.mu.Lock()
	rpc := m.rpc
	m.mu.Unlock()
	if rpc == nil {
		return
	}
	ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
	defer cancel()
	fn(ctx, rpc)
}

func (m *Manager) update(id string, fields ...any) {
	if len(fields) == 0 || len(fields)%2 != 0 {
		return
	}
	var sets []string
	var args []any
	for i := 0; i < len(fields); i += 2 {
		column, ok := fields[i].(string)
		if !ok {
			return
		}
		sets = append(sets, column+"=?")
		args = append(args, fields[i+1])
	}
	args = append(args, time.Now().Unix(), id)
	_, _ = m.db.Exec("UPDATE download_tasks SET "+strings.Join(sets, ",")+",updated_at=? WHERE id=?", args...)
}

func (m *Manager) rowByID(id string, owner int64) (Task, string, error) {
	var task Task
	var gid string
	err := m.db.QueryRow(`SELECT id,url,destination,status,filename,gid,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at FROM download_tasks WHERE id=? AND owner=?`,
		id, owner).Scan(&task.ID, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Task{}, "", ErrNotFound
	}
	if err != nil {
		return Task{}, "", err
	}
	task.Owner = owner
	return task, gid, nil
}

func (m *Manager) rowByIDUnscoped(id string) (Task, string, error) {
	var task Task
	var gid string
	var owner int64
	err := m.db.QueryRow(`SELECT id,owner,url,destination,status,filename,gid,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at FROM download_tasks WHERE id=?`,
		id).Scan(&task.ID, &owner, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Task{}, "", ErrNotFound
	}
	if err != nil {
		return Task{}, "", err
	}
	task.Owner = owner
	return task, gid, nil
}

func (m *Manager) taskByID(id string, owner int64) (Task, error) {
	task, _, err := m.rowByID(id, owner)
	return task, err
}

func freeLoopbackPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		return 0, err
	}
	return port, nil
}

func randomToken() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	const hexDigits = "0123456789abcdef"
	out := make([]byte, len(buffer)*2)
	for i, b := range buffer {
		out[i*2] = hexDigits[b>>4]
		out[i*2+1] = hexDigits[b&0xF]
	}
	return string(out), nil
}

func sanitizeError(err error) string {
	return sanitizeText(err.Error())
}

// sanitizeText keeps journal payloads bounded and strips path-like content
// so a hostile server response cannot smuggle staging paths into the UI.
func sanitizeText(message string) string {
	const limit = 160
	clean := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		case r == ' ', r == '-', r == '_', r == '.', r == ',', r == ':':
			return r
		default:
			return ' '
		}
	}, message)
	clean = strings.Join(strings.Fields(clean), " ")
	if len(clean) > limit {
		clean = clean[:limit]
	}
	if clean == "" {
		return "download_failed"
	}
	return clean
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
