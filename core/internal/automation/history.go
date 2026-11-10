package automation

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"time"
)

type RunSummary struct {
	StartedAt  int64  `json:"startedAt"`
	FinishedAt int64  `json:"finishedAt"`
	State      string `json:"state"`
	ExitCode   int    `json:"exitCode"`
}

func initializeHistory(db *sql.DB) error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS runs(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 task_id TEXT NOT NULL,
 started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL,
 state TEXT NOT NULL, exit_code INTEGER NOT NULL, output TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS runs_task_id ON runs(task_id,id);
 CREATE TABLE IF NOT EXISTS run_deliveries(
 run_id INTEGER NOT NULL, channel TEXT NOT NULL, status TEXT NOT NULL,
 PRIMARY KEY(run_id,channel));
 CREATE TRIGGER IF NOT EXISTS prune_run_deliveries AFTER DELETE ON runs BEGIN
 DELETE FROM run_deliveries WHERE run_id=old.id;
 END;
 UPDATE runs SET state='interrupted', finished_at=strftime('%s','now'), exit_code=-1,
 output='上次运行时 Core 退出，任务结果无法确认。' WHERE state='running';
 UPDATE run_deliveries SET status='interrupted' WHERE status='queued';`)
	return err
}

func (m *Manager) beginRun(id string, started int64) (int64, error) {
	result, err := m.db.Exec(`INSERT INTO runs(task_id,started_at,finished_at,state,exit_code,output)
 VALUES(?,?,0,'running',-1,'')`, id, started)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

func (m *Manager) recordSkipped(id, reason string) {
	now := time.Now()
	if _, err := m.db.Exec(`INSERT INTO runs(task_id,started_at,finished_at,state,exit_code,output)
 VALUES(?,?,?,'skipped',-1,?)`, id, now.Unix(), now.Unix(), reason); err != nil {
		slog.Warn("cannot record skipped automation", "task", id, "error", err)
		return
	}
	if _, err := m.db.Exec(pruneRunsSQL, id, id); err != nil {
		slog.Warn("cannot prune automation history", "task", id, "error", err)
	}
}

// Preserve the active row while overlapping scheduled executions are skipped.
const pruneRunsSQL = `DELETE FROM runs WHERE task_id=? AND state<>'running'
 AND id NOT IN(SELECT id FROM runs WHERE task_id=? ORDER BY id DESC LIMIT 30)`

func (m *Manager) finishRun(runID int64, taskID, state string, exitCode int, output string, finished time.Time, channels []string) error {
	tx, err := m.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE runs SET finished_at=?, state=?, exit_code=?, output=? WHERE id=?`, finished.Unix(), state, exitCode, output, runID); err != nil {
		return err
	}
	for _, channel := range channels {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO run_deliveries(run_id,channel,status) VALUES(?,?,'queued')`, runID, channel); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(pruneRunsSQL, taskID, taskID); err != nil {
		return err
	}
	return tx.Commit()
}

func (m *Manager) reportDelivery(runID int64, channel, status string) {
	if _, err := m.db.Exec(`UPDATE run_deliveries SET status=? WHERE run_id=? AND channel=? AND status='queued'`, status, runID, channel); err != nil {
		slog.Warn("cannot record automation notification result", "run", runID, "channel", channel, "error", err)
	}
}

func (m *Manager) appendRunNote(runID int64, note string) {
	if _, err := m.db.Exec(`UPDATE runs SET output=CAST(substr(CAST(output AS BLOB),1,?) AS TEXT)||char(10)||? WHERE id=?`, maxOutput-len(note)-1, note, runID); err != nil {
		slog.Warn("cannot record automation note", "run", runID, "error", err)
	}
}

func (m *Manager) lastRuns(tasks []Task) (map[string]*RunSummary, error) {
	summaries := make(map[string]*RunSummary, len(tasks))
	m.mu.Lock()
	db, closed := m.db, m.closed
	m.mu.Unlock()
	if db == nil || closed {
		return summaries, nil
	}
	for _, task := range tasks {
		var summary RunSummary
		err := db.QueryRow(`SELECT started_at,finished_at,state,exit_code FROM runs
 WHERE task_id=? AND state<>'running' ORDER BY finished_at DESC,id DESC LIMIT 1`, task.ID).
			Scan(&summary.StartedAt, &summary.FinishedAt, &summary.State, &summary.ExitCode)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return summaries, err
		}
		summaries[task.ID] = &summary
	}
	return summaries, nil
}

func (m *Manager) History(id string) ([]Record, error) {
	if !taskID.MatchString(id) {
		return nil, ErrInvalid
	}
	m.mu.Lock()
	db, closed := m.db, m.closed
	m.mu.Unlock()
	if db == nil || closed {
		return nil, ErrUnavailable
	}
	rows, err := db.Query(`SELECT id,task_id,started_at,finished_at,state,exit_code,output,
 (SELECT json_group_object(channel,status) FROM run_deliveries WHERE run_id=runs.id)
 FROM runs WHERE task_id=? ORDER BY id DESC LIMIT 30`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]Record, 0)
	for rows.Next() {
		var record Record
		var deliveries string
		if err := rows.Scan(&record.ID, &record.TaskID, &record.StartedAt, &record.FinishedAt, &record.State, &record.ExitCode, &record.Output, &deliveries); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(deliveries), &record.Deliveries); err != nil {
			return nil, err
		}
		result = append(result, record)
	}
	return result, rows.Err()
}
