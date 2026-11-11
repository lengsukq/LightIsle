// Package downloads implements the bounded download center. It supervises a
// user-installed aria2c (Homebrew whitelist, never bundled), keeps a SQLite
// task journal, and publishes finished downloads into the share exclusively
// through the safe file APIs — a task can never write outside an authorized
// destination, overwrite an existing file, or exceed its declared budget.
package downloads

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
	ErrFetchForbidden    = errors.New("download_network_admin_only")
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

// RootIdentityPublisher binds every publication to rootID, generation and
// physical directory identity, not merely a historical share path.
type RootIdentityPublisher interface {
	Publisher
	DownloadRootIdentity() (RootIdentity, error)
	RootIdentityCurrent(RootIdentity) bool
	PublishDownloadRoot(RootIdentity, string, io.Reader, func() error) (int64, error)
	InspectDownloadRoot(RootIdentity, string, func(io.Reader, int64) error) error
}

type RootIdentity struct {
	ID         string
	Generation uint64
	Binding    storageidentity.Binding
}

// Options wires the manager into the daemon.
type Options struct {
	DataDir      string // daemon data dir; downloads.sqlite and staging live here
	Binary       string // resolved aria2c path; "" keeps the center unavailable unless LocateBinary discovers one
	LocateBinary func() (path string, version string, err error)
	Publisher    Publisher
	// CanImport re-checks the owner's write grant at publish time; a grant
	// revoked after creation must stop the task, not smuggle files in.
	CanImport func(owner int64, destination string) bool
	// CanFetch authorizes network access separately from local publication.
	CanFetch func(owner int64) bool
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
	RootID                  string          `json:"rootId,omitempty"`
	RootGeneration          uint64          `json:"rootGeneration,omitempty"`
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
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(opts.DataDir, "downloads.sqlite")+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=on&_cache_size=-512")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS download_tasks(
		id TEXT PRIMARY KEY,
		owner INTEGER NOT NULL,
		url TEXT NOT NULL,
		destination TEXT NOT NULL,
		max_bytes INTEGER NOT NULL DEFAULT 0,
		status TEXT NOT NULL CHECK(status IN ('queued','running','paused','completed','failed','cancelled')),
		gid TEXT NOT NULL DEFAULT '',
		root_binding TEXT,
		root_id TEXT NOT NULL DEFAULT '',
		root_generation INTEGER NOT NULL DEFAULT 0,
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
	if err := ensureDownloadColumn(db, "root_id", "TEXT NOT NULL DEFAULT ''"); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := ensureDownloadColumn(db, "root_generation", "INTEGER NOT NULL DEFAULT 0"); err != nil {
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
		updated_at=?, gid='' WHERE status IN ('queued','running','paused')`,
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
	if _, scoped := opts.Publisher.(RootIdentityPublisher); scoped {
		// Existing tasks without a durable registered root identity must
		// remain visible but may not be published to a newly selected disk.
		if _, err := db.Exec(`UPDATE download_tasks SET status=?, error='download_root_unbound',
			updated_at=?, gid='' WHERE (root_id='' OR root_generation<1) AND status<>?`,
			StatusFailed, now, StatusCompleted); err != nil {
			_ = db.Close()
			return nil, err
		}
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

func (m *Manager) canFetch(owner int64) bool {
	return m.opts.CanFetch == nil || m.opts.CanFetch(owner)
}

// Create records a queued task and immediately hands it to aria2.
func (m *Manager) Create(owner int64, rawURL, destination string, maxBytes int64) (Task, error) {
	if !m.canFetch(owner) {
		return Task{}, ErrFetchForbidden
	}
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
	var identity RootIdentity
	var binding storageidentity.Binding
	var err error
	if scoped, ok := m.opts.Publisher.(RootIdentityPublisher); ok {
		identity, err = scoped.DownloadRootIdentity()
		binding = identity.Binding
	} else {
		binding, err = m.opts.Publisher.DownloadRootBinding()
	}
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
		RootID: identity.ID, RootGeneration: identity.Generation,
		rootBinding: binding, rootBound: true}
	if _, err := m.db.Exec(`INSERT INTO download_tasks
		(id,owner,url,destination,max_bytes,status,root_binding,root_id,root_generation,phase,created_at,updated_at)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		task.ID, owner, task.URL, task.Destination, task.MaxBytes, task.Status, string(bindingJSON),
		task.RootID, task.RootGeneration, task.Phase, now, now); err != nil {
		return Task{}, err
	}
	m.kick(task.ID)
	return m.taskByID(task.ID, owner)
}

func (m *Manager) List(owner int64) ([]Task, error) {
	rows, err := m.db.Query(`SELECT id,url,destination,status,filename,total_bytes,completed_bytes,
		max_bytes,error,created_at,updated_at,completed_at,phase,root_binding,root_id,root_generation FROM download_tasks
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
			&item.CreatedAt, &item.UpdatedAt, &item.CompletedAt, &item.Phase, &bindingJSON,
			&item.RootID, &item.RootGeneration); err != nil {
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
		if !m.canFetch(owner) {
			return Task{}, ErrFetchForbidden
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
			if !m.canFetch(owner) {
				return Task{}, ErrFetchForbidden
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
		if !m.canFetch(owner) {
			return Task{}, ErrFetchForbidden
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

func (m *Manager) requireTaskRoot(task Task) error {
	if !task.rootBound {
		return ErrRootUnbound
	}
	if scoped, ok := m.opts.Publisher.(RootIdentityPublisher); ok {
		if task.RootID == "" || task.RootGeneration == 0 {
			return ErrRootUnbound
		}
		if !scoped.RootIdentityCurrent(RootIdentity{
			ID: task.RootID, Generation: task.RootGeneration, Binding: task.rootBinding,
		}) {
			return ErrRootChanged
		}
		return nil
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
