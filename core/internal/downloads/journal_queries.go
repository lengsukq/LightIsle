package downloads

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// Task mutations deliberately exclude owner, destination, URL and root binding.
// SQL identifiers cannot be bound as parameters: never interpolate arbitrary
// caller-supplied column names into an UPDATE statement.
var mutableTaskColumns = map[string]struct{}{
	"status": {}, "error": {}, "gid": {}, "phase": {},
	"filename": {}, "total_bytes": {}, "completed_bytes": {},
	"completed_at": {},
}

func taskUpdateFields(fields ...any) ([]string, []any, error) {
	if len(fields) == 0 || len(fields)%2 != 0 {
		return nil, nil, ErrInput
	}
	sets := make([]string, 0, len(fields)/2)
	args := make([]any, 0, len(fields)/2)
	for i := 0; i < len(fields); i += 2 {
		column, ok := fields[i].(string)
		if !ok {
			return nil, nil, ErrInput
		}
		if _, allowed := mutableTaskColumns[column]; !allowed {
			return nil, nil, ErrInput
		}
		sets = append(sets, column+"=?")
		args = append(args, fields[i+1])
	}
	return sets, args, nil
}

// These queries are the only ID-scoped entry points to the persisted task
// journal. Public lookups bind both the task ID and owner, while the internal
// poller deliberately uses the unscoped lookup.
func (m *Manager) update(id string, fields ...any) error {
	sets, args, err := taskUpdateFields(fields...)
	if err != nil {
		return err
	}
	args = append(args, time.Now().Unix(), id)
	_, err = m.db.Exec("UPDATE download_tasks SET "+strings.Join(sets, ",")+",updated_at=? WHERE id=?", args...)
	return err
}

// An idle or paused engine reports identical progress every second. Persist
// only changes; updated_at describes a task change, not the last RPC poll.
// Keep the engine generation/status guard in SQL as well as in the poller.
func (m *Manager) updatePolledProgress(id, gid, status string, total, completed int64) error {
	_, err := m.db.Exec(`UPDATE download_tasks SET status=?,total_bytes=?,completed_bytes=?,updated_at=?
		WHERE id=? AND gid=? AND status IN ('running','paused')
		AND (status<>? OR total_bytes<>? OR completed_bytes<>?)`,
		status, total, completed, time.Now().Unix(), id, gid, status, total, completed)
	return err
}

func (m *Manager) rowByID(id string, owner int64) (Task, string, error) {
	var task Task
	var gid string
	var bindingJSON sql.NullString
	err := m.db.QueryRow(`SELECT id,url,destination,status,filename,gid,total_bytes,completed_bytes,
        max_bytes,error,created_at,updated_at,completed_at,phase,root_binding,root_id,root_generation FROM download_tasks WHERE id=? AND owner=?`,
		id, owner).Scan(&task.ID, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt, &task.Phase, &bindingJSON,
		&task.RootID, &task.RootGeneration)
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
        max_bytes,error,created_at,updated_at,completed_at,phase,root_binding,root_id,root_generation FROM download_tasks WHERE id=?`,
		id).Scan(&task.ID, &owner, &task.URL, &task.Destination, &task.Status, &task.Filename, &gid,
		&task.TotalBytes, &task.CompletedBytes, &task.MaxBytes, &task.Error,
		&task.CreatedAt, &task.UpdatedAt, &task.CompletedAt, &task.Phase, &bindingJSON,
		&task.RootID, &task.RootGeneration)
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
