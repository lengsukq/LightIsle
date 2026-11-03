package downloads

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// These queries are the only ID-scoped entry points to the persisted task
// journal. Public lookups bind both the task ID and owner, while the internal
// poller deliberately uses the unscoped lookup.
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
