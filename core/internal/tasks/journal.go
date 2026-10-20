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

var ErrRunning = errors.New("task_already_running")

func Open(dataDir string) (*Journal, error) {
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dataDir, "tasks.sqlite")+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	statements := []string{
		`CREATE TABLE IF NOT EXISTS task_journal (
            kind TEXT PRIMARY KEY, operation TEXT NOT NULL, running INTEGER NOT NULL,
            processed INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
            started_at INTEGER NOT NULL DEFAULT 0, last_done INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0)`,
		`UPDATE task_journal SET running=0,last_error='interrupted_by_restart',last_done=strftime('%s','now') WHERE running=1`,
	}
	for _, query := range statements {
		if _, err := db.Exec(query); err != nil {
			db.Close()
			return nil, err
		}
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
	err = tx.QueryRow("SELECT running FROM task_journal WHERE kind=?", kind).Scan(&running)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if running != 0 {
		return ErrRunning
	}
	_, err = tx.Exec(`INSERT INTO task_journal(kind,operation,running,processed,bytes,started_at,last_done,last_error,attempts)
    VALUES(?,?,1,0,0,?,0,'',1) ON CONFLICT(kind) DO UPDATE SET
    operation=excluded.operation,running=1,processed=0,bytes=0,
    started_at=excluded.started_at,last_done=0,last_error='',attempts=task_journal.attempts+1`,
		kind, operation, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

func validKind(k string) bool {
	switch k {
	case "gallery", "cinema", "backup":
		return true
	}
	return false
}
func (j *Journal) Progress(kind string, processed, bytes int64) error {
	if !validKind(kind) || processed < 0 || bytes < 0 {
		return errors.New("invalid_progress")
	}
	_, err := j.db.Exec("UPDATE task_journal SET processed=?,bytes=? WHERE kind=? AND running=1", processed, bytes, kind)
	return err
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
	_, err := j.db.Exec("UPDATE task_journal SET running=0,last_error=?,last_done=? WHERE kind=? AND running=1",
		status, time.Now().Unix(), kind)
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
