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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
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
	idleProcessTTL    = 5 * time.Minute
	importSuffixMax   = 999
	maxPublishedFiles = 50
	maxHashBuffer     = 64 * 1024
	phaseDownload     = "download"
	phasePublishing   = "publishing"
)

var (
	ErrNotAvailable      = errors.New("download_unavailable")
	ErrNotFound          = errors.New("download_not_found")
	ErrInput             = errors.New("download_invalid_request")
	ErrBusy              = errors.New("download_limit_reached")
	ErrRootUnavailable   = files.ErrDownloadRootUnavailable
	ErrRootChanged       = files.ErrDownloadRootChanged
	ErrRootUnbound       = errors.New("download_root_unbound")
	ErrPermission        = errors.New("download_permission_revoked")
	ErrAccountingPending = errors.New("download_storage_accounting_pending")
)

// Publisher provides the download-specific part of the safe file API. Every
// operation is pinned to the task's persisted physical-root identity.
type Publisher interface {
	DownloadRootBinding() (storageidentity.Binding, error)
	PublishDownload(storageidentity.Binding, string, io.Reader, func() error) (int64, error)
	InspectDownload(storageidentity.Binding, string, func(io.Reader, int64) error) error
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
	// OnTaskDone reports a fully published task; filename is the published
	// base name only, never a path.
	OnTaskDone func(filename string)
}

// Task is the JSON-facing journal row.
type Task struct {
	ID                      string          `json:"id"`
	Owner                   int64           `json:"-"`
	URL                     string          `json:"url"`
	Destination             string          `json:"destination"`
	Status                  string          `json:"status"`
	Phase                   string          `json:"phase,omitempty"`
	Filename                string          `json:"filename,omitempty"`
	TotalBytes              int64           `json:"totalBytes"`
	CompletedBytes          int64           `json:"completedBytes"`
	MaxBytes                int64           `json:"maxBytes"`
	Error                   string          `json:"error,omitempty"`
	CreatedAt               int64           `json:"createdAt"`
	UpdatedAt               int64           `json:"updatedAt"`
	CompletedAt             int64           `json:"completedAt,omitempty"`
	PartialPublish          bool            `json:"partialPublish,omitempty"`
	RecoveryRequired        bool            `json:"recoveryRequired,omitempty"`
	PublishedFiles          []PublishedFile `json:"publishedFiles,omitempty"`
	PublishedFilesTotal     int             `json:"publishedFilesTotal,omitempty"`
	PublishedFilesTruncated bool            `json:"publishedFilesTruncated,omitempty"`
	rootBinding             storageidentity.Binding
	rootBound               bool
}

// PublishedFile is a bounded UI projection of a per-file durable publication
// journal row. The physical root binding and content digest remain server-side.
type PublishedFile struct {
	Target string `json:"target"`
	Size   int64  `json:"size"`
	Status string `json:"status"`
}

type publication struct {
	source string
	target string
	size   int64
	sha256 string
	state  string
}

type Manager struct {
	opts Options
	db   *sql.DB

	mu          sync.Mutex
	rpc         *RPC
	cmd         *exec.Cmd
	processDone chan struct{}
	idleSince   time.Time
	idleTimeout time.Duration
	available   bool
	version     string
	alertUp     bool
	importMu    sync.Mutex

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
	db, err := sql.Open("sqlite3", filepath.Join(opts.DataDir, "downloads.sqlite")+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=on")
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
		root_binding TEXT,
		phase TEXT NOT NULL DEFAULT 'download',
		filename TEXT NOT NULL DEFAULT '',
		total_bytes INTEGER NOT NULL DEFAULT 0,
		completed_bytes INTEGER NOT NULL DEFAULT 0,
		error TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL,
		completed_at INTEGER NOT NULL DEFAULT 0)`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS download_tasks_owner ON download_tasks(owner,created_at)`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := ensureDownloadColumn(db, "root_binding", "TEXT"); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := ensureDownloadColumn(db, "phase", "TEXT NOT NULL DEFAULT 'download'"); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS download_publications(
		task_id TEXT NOT NULL REFERENCES download_tasks(id) ON DELETE CASCADE,
		source_path TEXT NOT NULL,
		target_path TEXT NOT NULL,
		size INTEGER NOT NULL,
		sha256 TEXT NOT NULL,
		state TEXT NOT NULL CHECK(state IN ('pending','publishing','published','recovery_required')),
		updated_at INTEGER NOT NULL,
		PRIMARY KEY(task_id,source_path))`); err != nil {
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
	// Legacy tasks have no physical-root binding. They remain visible, but may
	// never inherit write permission from whatever share is selected now.
	if _, err := db.Exec(`UPDATE download_tasks SET status=?, error='download_root_unbound',
		updated_at=?, gid='' WHERE root_binding IS NULL AND status<>?`, StatusFailed, now, StatusCompleted); err != nil {
		_ = db.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{opts: opts, db: db, ctx: ctx, cancel: cancel, idleTimeout: idleProcessTTL}, nil
}

func ensureDownloadColumn(db *sql.DB, name, declaration string) error {
	rows, err := db.Query(`PRAGMA table_info(download_tasks)`)
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var cid, notNull, primaryKey int
		var column, dataType string
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &column, &dataType, &notNull, &defaultValue, &primaryKey); err != nil {
			rows.Close()
			return err
		}
		if column == name {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if found {
		return nil
	}
	_, err = db.Exec("ALTER TABLE download_tasks ADD COLUMN " + name + " " + declaration)
	return err
}

// Start explicitly starts the engine. Normal callers use Create/Action, which
// start it on demand. Serialize startup with mutations and idle shutdown.
func (m *Manager) Start() error {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	return m.startLocked()
}

func (m *Manager) startLocked() error {
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
	if m.ctx.Err() != nil {
		return ErrNotAvailable
	}
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
	m.processDone = make(chan struct{})
	done := m.processDone
	m.rpc = NewRPC(port, secret)
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		_ = cmd.Wait()
		close(done)
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
	m.idleSince = time.Now()
	m.wg.Add(1)
	go m.pollLoop(m.rpc, done)
	return nil
}

// The v1 download publisher is not root-scoped and has no user-ledger
// reservation. An aria2 payload can also contain nested source names even
// when the requested destination is "."; check both at publication time.
func personalStorageDestination(name string) bool {
	return strings.EqualFold(name, "Users") ||
		(len(name) > 6 && name[5] == '/' && strings.EqualFold(name[:5], "Users"))
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
	m.stopLocked()
	m.mu.Unlock()
	m.wg.Wait()
	m.importMu.Lock()
	defer m.importMu.Unlock()
	return m.db.Close()
}

func (m *Manager) stopLocked() {
	if m.cmd != nil && m.cmd.Process != nil {
		_ = m.cmd.Process.Kill()
		// Always reap startup failures and idle engines before dropping handles.
		<-m.processDone
	}
	m.processDone = nil
	m.available = false
	m.rpc = nil
	m.cmd = nil
}

// Available reports whether the download center can run on this machine.
func (m *Manager) Available() (bool, string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.ctx.Err() != nil {
		return false, "aria2_not_running"
	}
	if m.opts.Binary == "" {
		return false, "aria2_not_installed"
	}
	return true, "" // installed, including a deliberately idle engine
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
		return Task{}, ErrInput
	}
	if err := ValidateURL(rawURL); err != nil {
		return Task{}, err
	}
	if err := ValidateDestination(destination); err != nil {
		return Task{}, err
	}
	if personalStorageDestination(destination) {
		return Task{}, ErrAccountingPending
	}
	m.importMu.Lock()
	defer m.importMu.Unlock()
	binding, err := m.opts.Publisher.DownloadRootBinding()
	if err != nil {
		return Task{}, err
	}
	bindingJSON, err := json.Marshal(binding)
	if err != nil {
		return Task{}, err
	}
	var count int
	if err := m.db.QueryRow(`SELECT COUNT(*) FROM download_tasks
		WHERE owner=? AND status IN ('queued','running','paused')`, owner).Scan(&count); err != nil {
		return Task{}, err
	}
	if count >= MaxTasks {
		return Task{}, ErrBusy
	}
	if err := m.startLocked(); err != nil {
		return Task{}, err
	}
	now := time.Now().Unix()
	id, err := randomToken()
	if err != nil {
		return Task{}, err
	}
	task := Task{ID: id[:24], Owner: owner, URL: rawURL, Destination: destination,
		MaxBytes: maxBytes, Status: StatusQueued, Phase: phaseDownload, CreatedAt: now, UpdatedAt: now,
		rootBinding: binding, rootBound: true}
	if _, err := m.db.Exec(`INSERT INTO download_tasks
		(id,owner,url,destination,max_bytes,status,root_binding,phase,created_at,updated_at)
		VALUES(?,?,?,?,?,?,?,?,?,?)`,
		task.ID, owner, task.URL, task.Destination, task.MaxBytes, task.Status, string(bindingJSON), task.Phase, now, now); err != nil {
		return Task{}, err
	}
	m.kick(task.ID)
	return m.taskByID(task.ID, owner)
}

func (m *Manager) List(owner int64) ([]Task, error) {
	rows, err := m.db.Query(`SELECT id,url,destination,status,filename,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at,phase,root_binding FROM download_tasks
		WHERE owner=? ORDER BY created_at DESC LIMIT 200`, owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tasks []Task
	for rows.Next() {
		var item Task
		var bindingJSON sql.NullString
		if err := rows.Scan(&item.ID, &item.URL, &item.Destination, &item.Status, &item.Filename,
			&item.TotalBytes, &item.CompletedBytes, &item.MaxBytes, &item.Error,
			&item.CreatedAt, &item.UpdatedAt, &item.CompletedAt, &item.Phase, &bindingJSON); err != nil {
			return nil, err
		}
		item.rootBinding, item.rootBound = decodeTaskBinding(bindingJSON)
		tasks = append(tasks, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for i := range tasks {
		if err := m.populatePublicationSummary(&tasks[i]); err != nil {
			return nil, err
		}
	}
	return tasks, nil
}

func decodeTaskBinding(raw sql.NullString) (storageidentity.Binding, bool) {
	if !raw.Valid || raw.String == "" {
		return storageidentity.Binding{}, false
	}
	var binding storageidentity.Binding
	if json.Unmarshal([]byte(raw.String), &binding) != nil || binding.Validate() != nil {
		return storageidentity.Binding{}, false
	}
	return binding, true
}

func (m *Manager) populatePublicationSummary(task *Task) error {
	var total, published, recovery int
	if err := m.db.QueryRow(`SELECT COUNT(*),
		COALESCE(SUM(CASE WHEN state='published' THEN 1 ELSE 0 END),0),
		COALESCE(SUM(CASE WHEN state='recovery_required' THEN 1 ELSE 0 END),0)
		FROM download_publications WHERE task_id=?`, task.ID).Scan(&total, &published, &recovery); err != nil {
		return err
	}
	task.PublishedFilesTotal = total
	task.PublishedFilesTruncated = total > maxPublishedFiles
	task.PartialPublish = published > 0 && task.Status != StatusCompleted
	task.RecoveryRequired = recovery > 0 || task.Error == "download_root_changed" ||
		task.Error == "download_root_unavailable" || task.Error == "download_root_unbound" ||
		task.Error == "download_publish_recovery_required"
	rows, err := m.db.Query(`SELECT target_path,size,state FROM download_publications
		WHERE task_id=? ORDER BY source_path LIMIT ?`, task.ID, maxPublishedFiles)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var item PublishedFile
		if err := rows.Scan(&item.Target, &item.Size, &item.Status); err != nil {
			return err
		}
		task.PublishedFiles = append(task.PublishedFiles, item)
	}
	return rows.Err()
}

// Action applies pause, resume or retry to an own task.
func (m *Manager) Action(owner int64, id, action string) (Task, error) {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return Task{}, err
	}
	switch action {
	case "pause":
		if task.Phase != phaseDownload || (task.Status != StatusRunning && task.Status != StatusQueued) {
			return Task{}, ErrInput
		}
		if !m.isAvailable() {
			return Task{}, ErrNotAvailable
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Pause(ctx, gid) })
		}
		if err := m.update(id, "status", StatusPaused); err != nil {
			return Task{}, err
		}
	case "resume":
		if task.Phase != phaseDownload || task.Status != StatusPaused {
			return Task{}, ErrInput
		}
		if err := m.startLocked(); err != nil {
			return Task{}, err
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Unpause(ctx, gid) })
		} else {
			if err := m.update(id, "status", StatusQueued); err != nil {
				return Task{}, err
			}
			m.kick(id)
			return m.taskByID(id, owner)
		}
		if err := m.update(id, "status", StatusRunning); err != nil {
			return Task{}, err
		}
	case "retry":
		if task.Status != StatusFailed && task.Status != StatusCancelled {
			return Task{}, ErrInput
		}
		if gid != "" {
			m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
		}
		if !task.rootBound {
			_ = m.update(id, "status", StatusFailed, "error", ErrRootUnbound.Error())
			return m.taskByID(id, owner)
		}
		if err := m.requireTaskRoot(task); err != nil {
			_ = m.update(id, "status", StatusFailed, "error", downloadRootError(err), "gid", "")
			return m.taskByID(id, owner)
		}
		if task.Phase == phasePublishing {
			ready, readyErr := m.canResumePublish(task)
			if readyErr != nil {
				return Task{}, readyErr
			}
			if ready {
				if err := m.update(id, "status", StatusRunning, "error", "", "gid", ""); err != nil {
					return Task{}, err
				}
				m.importDownloadLocked(id)
				return m.taskByID(id, owner)
			}
			if err := m.startLocked(); err != nil {
				return Task{}, err
			}
			if err := os.RemoveAll(m.stagingDir(id)); err != nil {
				return Task{}, err
			}
			if err := m.update(id, "status", StatusQueued, "phase", phaseDownload, "error", "", "gid", "",
				"total_bytes", int64(0), "completed_bytes", int64(0)); err != nil {
				return Task{}, err
			}
			m.kick(id)
			return m.taskByID(id, owner)
		}
		if err := m.startLocked(); err != nil {
			return Task{}, err
		}
		if err := os.RemoveAll(m.stagingDir(id)); err != nil {
			return Task{}, err
		}
		if err := m.update(id, "status", StatusQueued, "phase", phaseDownload, "error", "", "gid", "", "filename", "",
			"total_bytes", int64(0), "completed_bytes", int64(0)); err != nil {
			return Task{}, err
		}
		m.kick(id)
	case "cancel":
		if err := m.cancelLocked(task, gid); err != nil {
			return Task{}, err
		}
	default:
		return Task{}, ErrInput
	}
	return m.taskByID(id, owner)
}

// Cancel stops a task; the journal row stays for audit.
func (m *Manager) Cancel(owner int64, id string) (Task, error) {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return Task{}, err
	}
	if task.Status == StatusCompleted || task.Status == StatusCancelled || task.Status == StatusFailed {
		return task, nil
	}
	if err := m.cancelLocked(task, gid); err != nil {
		return Task{}, err
	}
	return m.taskByID(id, owner)
}

func (m *Manager) cancelLocked(task Task, gid string) error {
	if task.Status == StatusCompleted || task.Status == StatusCancelled || task.Status == StatusFailed {
		return ErrInput
	}
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	if err := m.update(task.ID, "status", StatusCancelled, "gid", ""); err != nil {
		return err
	}
	return os.RemoveAll(m.stagingDir(task.ID))
}

// Delete removes a terminal task from the journal; running tasks are
// cancelled first.
func (m *Manager) Delete(owner int64, id string) error {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	task, gid, err := m.rowByID(id, owner)
	if err != nil {
		return err
	}
	if task.Status != StatusCompleted && task.Status != StatusCancelled && task.Status != StatusFailed {
		if err := m.cancelLocked(task, gid); err != nil {
			return err
		}
	}
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	// Failed publications intentionally retain staging for retry. Explicit
	// deletion ends that recovery opportunity, but never removes shared files.
	if err := os.RemoveAll(m.stagingDir(id)); err != nil {
		return err
	}
	tx, err := m.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// SQLite foreign-key enforcement is connection-specific; delete child
	// rows explicitly so no orphan journal survives a removed task.
	if _, err := tx.Exec("DELETE FROM download_publications WHERE task_id=?", id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM download_tasks WHERE id=? AND owner=?", id, owner); err != nil {
		return err
	}
	return tx.Commit()
}

func (m *Manager) isAvailable() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.available && m.rpc != nil
}

func (m *Manager) requireTaskRoot(task Task) error {
	if !task.rootBound {
		return ErrRootUnbound
	}
	current, err := m.opts.Publisher.DownloadRootBinding()
	if err != nil {
		return err
	}
	if current != task.rootBinding {
		return ErrRootChanged
	}
	return nil
}

func downloadRootError(err error) string {
	switch {
	case errors.Is(err, ErrRootChanged):
		return ErrRootChanged.Error()
	case errors.Is(err, ErrRootUnavailable):
		return ErrRootUnavailable.Error()
	default:
		return ErrRootUnavailable.Error()
	}
}

func (m *Manager) stagingDir(id string) string {
	return filepath.Join(m.opts.DataDir, "downloads-staging", id)
}

// kick starts a queued task that is not yet known to aria2.
func (m *Manager) kick(id string) {
	m.mu.Lock()
	if m.ctx.Err() != nil || !m.available || m.rpc == nil {
		m.mu.Unlock()
		return
	}
	m.wg.Add(1)
	m.mu.Unlock()
	go func() {
		defer m.wg.Done()
		m.importMu.Lock()
		defer m.importMu.Unlock()
		m.mu.Lock()
		rpc := m.rpc
		ready := m.ctx.Err() == nil && m.available && rpc != nil
		m.mu.Unlock()
		if !ready {
			return
		}
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

func (m *Manager) pollLoop(rpc *RPC, done <-chan struct{}) {
	defer m.wg.Done()
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-done:
			m.engineExited(rpc)
			return
		case <-ticker.C:
			m.pollOnce()
			if m.stopIfIdle(time.Now()) {
				return
			}
		}
	}
}

// Paused tasks keep their aria2 state. Publishing and queued tasks also pin the
// engine; mutations hold importMu through startup and the journal transition.
func (m *Manager) stopIfIdle(now time.Time) bool {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	var active int
	if err := m.db.QueryRow(`SELECT COUNT(*) FROM download_tasks WHERE status IN ('queued','running','paused')`).Scan(&active); err != nil {
		return false
	}
	if active != 0 {
		m.idleSince = now
		return false
	}
	if now.Sub(m.idleSince) < m.idleTimeout {
		return false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopLocked()
	return true
}

func (m *Manager) engineExited(rpc *RPC) {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	m.mu.Lock()
	if m.rpc != rpc || m.ctx.Err() != nil {
		m.mu.Unlock()
		return
	}
	m.stopLocked()
	m.mu.Unlock()
	// No automatic restart storm. Preserve staging/journals for explicit retry.
	result, err := m.db.Exec(`UPDATE download_tasks SET status='failed', error='download_restarted', gid='', updated_at=? WHERE status IN ('queued','running','paused')`, time.Now().Unix())
	if err == nil {
		if count, _ := result.RowsAffected(); count > 0 {
			m.raiseAlert()
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

// importDownload synchronizes the journal and source staging with the
// durable, root-bound publication flow in publish.go.
func (m *Manager) importDownload(id, _ string) {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	m.importDownloadLocked(id)
}
func (m *Manager) failTask(id, reason, gid string) {
	if gid != "" {
		m.withRPC(func(ctx context.Context, rpc *RPC) { _ = rpc.Remove(ctx, gid) })
	}
	m.update(id, "status", StatusFailed, "error", reason, "gid", "")
	// A partly published batch must retain its source files and journal.
	// Removing them here makes crash-safe retries impossible.
	var phase string
	if err := m.db.QueryRow("SELECT phase FROM download_tasks WHERE id=?", id).Scan(&phase); err == nil && phase != phasePublishing {
		_ = os.RemoveAll(m.stagingDir(id))
	}
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

func (m *Manager) update(id string, fields ...any) error {
	if len(fields) == 0 || len(fields)%2 != 0 {
		return ErrInput
	}
	var sets []string
	var args []any
	for i := 0; i < len(fields); i += 2 {
		column, ok := fields[i].(string)
		if !ok {
			return ErrInput
		}
		sets = append(sets, column+"=?")
		args = append(args, fields[i+1])
	}
	args = append(args, time.Now().Unix(), id)
	_, err := m.db.Exec("UPDATE download_tasks SET "+strings.Join(sets, ",")+",updated_at=? WHERE id=?", args...)
	return err
}

func (m *Manager) rowByID(id string, owner int64) (Task, string, error) {
	var task Task
	var gid string
	var bindingJSON sql.NullString
	err := m.db.QueryRow(`SELECT id,url,destination,status,filename,gid,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at,phase,root_binding FROM download_tasks WHERE id=? AND owner=?`,
		id, owner).Scan(&task.ID, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt, &task.Phase, &bindingJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return Task{}, "", ErrNotFound
	}
	if err != nil {
		return Task{}, "", err
	}
	task.Owner = owner
	task.rootBinding, task.rootBound = decodeTaskBinding(bindingJSON)
	if err := m.populatePublicationSummary(&task); err != nil {
		return Task{}, "", err
	}
	return task, gid, nil
}

func (m *Manager) rowByIDUnscoped(id string) (Task, string, error) {
	var task Task
	var gid string
	var owner int64
	var bindingJSON sql.NullString
	err := m.db.QueryRow(`SELECT id,owner,url,destination,status,filename,gid,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at,phase,root_binding FROM download_tasks WHERE id=?`,
		id).Scan(&task.ID, &owner, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt, &task.Phase, &bindingJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return Task{}, "", ErrNotFound
	}
	if err != nil {
		return Task{}, "", err
	}
	task.Owner = owner
	task.rootBinding, task.rootBound = decodeTaskBinding(bindingJSON)
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
