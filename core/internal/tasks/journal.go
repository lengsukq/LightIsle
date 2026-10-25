package tasks

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// Journal persists only progress and failure metadata; it never persists
// privileged commands or replays a destructive operation after a restart.
// Interrupted scans may be safely retried by their existing idempotent indexer.
type Journal struct {
	db *sql.DB
	mu sync.Mutex
}

type State struct {
	Kind      string `json:"kind"`
	Operation string `json:"operation"`
	Running   bool   `json:"running"`
	Processed int64  `json:"processed"`
	Bytes     int64  `json:"bytes"`
	StartedAt int64  `json:"startedAt"`
	LastDone  int64  `json:"lastDone"`
	LastError string `json:"lastError,omitempty"`
	Attempts  int64  `json:"attempts"`
}

// Run is one persisted execution of a background task. The current State table
// remains the fast, one-row-per-kind summary; Runs preserves each attempt.
type Run struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Operation string `json:"operation"`
	Running   bool   `json:"running"`
	Progress  int64  `json:"progress"`
	Bytes     int64  `json:"bytes"`
	StartedAt int64  `json:"startedAt"`
	LastDone  int64  `json:"lastDone"`
	LastError string `json:"lastError"`
	Attempts  int64  `json:"attempts"`
}

const maxHistoryRows = 1000

var ErrRunning = errors.New("task_already_running")

func Open(dataDir string) (*Journal, error) {
	return open(dataDir, "tasks.sqlite")
}

// OpenRootScoped persists task and alert state in a flat database dedicated to
// one logical root, leaving the legacy single-root journal untouched.
func OpenRootScoped(dataDir, rootID string) (*Journal, error) {
	if !validRootID(rootID) {
		return nil, errors.New("invalid_root_id")
	}
	return open(dataDir, "tasks-root-"+rootID+".sqlite")
}

func validRootID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func open(dataDir, databaseName string) (*Journal, error) {
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dataDir, databaseName)+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	statements := []string{
		"CREATE TABLE IF NOT EXISTS disk_health_history (" +
			"device_key TEXT NOT NULL,timestamp INTEGER NOT NULL,source TEXT NOT NULL," +
			"reason TEXT NOT NULL,temperature INTEGER,passed INTEGER,life_used INTEGER,power_on_hours INTEGER," +
			"risk TEXT NOT NULL,PRIMARY KEY(device_key,timestamp))",
		"CREATE TABLE IF NOT EXISTS metric_history (" +
			"timestamp INTEGER PRIMARY KEY, cpu_percent REAL, memory_percent REAL NOT NULL, " +
			"disk_percent REAL NOT NULL, download_bps REAL, upload_bps REAL)",
		`CREATE TABLE IF NOT EXISTS task_journal (
            kind TEXT PRIMARY KEY, operation TEXT NOT NULL, running INTEGER NOT NULL,
            processed INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
            started_at INTEGER NOT NULL DEFAULT 0, last_done INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE IF NOT EXISTS task_runs (
		    id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, operation TEXT NOT NULL,
		    running INTEGER NOT NULL, progress INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
		    started_at INTEGER NOT NULL, last_done INTEGER NOT NULL DEFAULT 0,
		    last_error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS task_runs_kind_id ON task_runs(kind,id DESC)`,
		`CREATE TABLE IF NOT EXISTS system_alerts(
        code TEXT PRIMARY KEY,
        severity TEXT NOT NULL,
        message TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        acknowledged INTEGER NOT NULL DEFAULT 0,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL)`,
	}
	for _, query := range statements {
		if _, err := db.Exec(query); err != nil {
			db.Close()
			return nil, err
		}
	}
	tx, err := db.Begin()
	if err != nil {
		db.Close()
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE task_journal SET running=0,last_error='interrupted_by_restart',last_done=strftime('%s','now') WHERE running=1`); err != nil {
		tx.Rollback()
		db.Close()
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE task_runs SET running=0,last_error='interrupted_by_restart',last_done=strftime('%s','now') WHERE running=1`); err != nil {
		tx.Rollback()
		db.Close()
		return nil, err
	}
	if err := pruneHistory(tx); err != nil {
		tx.Rollback()
		db.Close()
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		db.Close()
		return nil, err
	}
	return &Journal{db: db}, nil
}
func (j *Journal) Close() error { return j.db.Close() }

func (j *Journal) Start(kind, operation string) error {
	if !validKind(kind) || operation == "" || len(operation) > 32 {
		return errors.New("invalid_task")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var running int
	var attempts int64
	err = tx.QueryRow("SELECT running,attempts FROM task_journal WHERE kind=?", kind).Scan(&running, &attempts)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if running != 0 {
		return ErrRunning
	}
	started := time.Now().Unix()
	attempts++
	if _, err := tx.Exec(`INSERT INTO task_runs(kind,operation,running,progress,bytes,started_at,last_done,last_error,attempts)
		VALUES(?,?,1,0,0,?,0,'',?)`, kind, operation, started, attempts); err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO task_journal(kind,operation,running,processed,bytes,started_at,last_done,last_error,attempts)
    VALUES(?,?,1,0,0,?,0,'',1) ON CONFLICT(kind) DO UPDATE SET
    operation=excluded.operation,running=1,processed=0,bytes=0,
    started_at=excluded.started_at,last_done=0,last_error='',attempts=task_journal.attempts+1`,
		kind, operation, started)
	if err != nil {
		return err
	}
	if err := pruneHistory(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func validKind(k string) bool {
	switch k {
	case "gallery", "cinema", "backup", "trash":
		return true
	}
	return false
}
func (j *Journal) Progress(kind string, processed, bytes int64) error {
	if !validKind(kind) || processed < 0 || bytes < 0 {
		return errors.New("invalid_progress")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("UPDATE task_journal SET processed=?,bytes=? WHERE kind=? AND running=1", processed, bytes, kind); err != nil {
		return err
	}
	if _, err := tx.Exec("UPDATE task_runs SET progress=?,bytes=? WHERE kind=? AND running=1", processed, bytes, kind); err != nil {
		return err
	}
	return tx.Commit()
}
func (j *Journal) Finish(kind string, runErr error) error {
	if !validKind(kind) {
		return errors.New("invalid_task")
	}
	status := ""
	if runErr != nil {
		status = runErr.Error()
	}
	if len(status) > 512 {
		status = status[:512]
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	done := time.Now().Unix()
	if _, err := tx.Exec("UPDATE task_journal SET running=0,last_error=?,last_done=? WHERE kind=? AND running=1", status, done, kind); err != nil {
		return err
	}
	if _, err := tx.Exec("UPDATE task_runs SET running=0,last_error=?,last_done=? WHERE kind=? AND running=1", status, done, kind); err != nil {
		return err
	}
	if err := pruneHistory(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// History returns completed and running attempts in newest-first order. A
// before cursor is exclusive; zero starts at the newest retained run.
func (j *Journal) History(kind string, before int64, limit int) ([]Run, int64, error) {
	if kind != "" && !validKind(kind) || before < 0 || limit < 1 || limit > 100 {
		return nil, 0, errors.New("invalid_task_history_query")
	}
	query := `SELECT id,kind,operation,running,progress,bytes,started_at,last_done,last_error,attempts
		FROM task_runs WHERE (?='' OR kind=?) AND (?=0 OR id<?) ORDER BY id DESC LIMIT ?`
	rows, err := j.db.Query(query, kind, kind, before, before, limit+1)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	result := make([]Run, 0, limit+1)
	for rows.Next() {
		var run Run
		var running int
		if err := rows.Scan(&run.ID, &run.Kind, &run.Operation, &running, &run.Progress, &run.Bytes,
			&run.StartedAt, &run.LastDone, &run.LastError, &run.Attempts); err != nil {
			return nil, 0, err
		}
		run.Running = running == 1
		result = append(result, run)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	var next int64
	if len(result) > limit {
		result = result[:limit]
		next = result[len(result)-1].ID
	}
	return result, next, nil
}

func pruneHistory(tx *sql.Tx) error {
	_, err := tx.Exec(`DELETE FROM task_runs
		WHERE running=0 AND id NOT IN (SELECT id FROM task_runs ORDER BY id DESC LIMIT ?)`, maxHistoryRows)
	return err
}
func (j *Journal) List() ([]State, error) {
	rows, err := j.db.Query("SELECT kind,operation,running,processed,bytes,started_at,last_done,last_error,attempts FROM task_journal ORDER BY kind")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []State{}
	for rows.Next() {
		var r State
		var running int
		if err := rows.Scan(&r.Kind, &r.Operation, &running, &r.Processed, &r.Bytes, &r.StartedAt, &r.LastDone, &r.LastError, &r.Attempts); err != nil {
			return nil, err
		}
		r.Running = running == 1
		out = append(out, r)
	}
	return out, rows.Err()
}
