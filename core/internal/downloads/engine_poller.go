package downloads

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/lengsukq/lightisle/core/internal/diagnostics"
)

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
		if !m.canFetch(task.Owner) {
			m.failTask(id, ErrFetchForbidden.Error(), gid)
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
	var active bool
	if err := m.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM download_tasks WHERE status IN ('queued','running','paused'))`).Scan(&active); err != nil {
		return false
	}
	if active {
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
	// A concurrent AddURI can record a transient RPC failure just before
	// cmd.Wait observes the crash. Normalize only that engine-specific failure
	// to the same retryable restart state as active/queued tasks.
	result, err := m.db.Exec(`UPDATE download_tasks SET status='failed', error='download_restarted', gid='', updated_at=? WHERE status IN ('queued','running','paused') OR (status='failed' AND error LIKE 'aria2_rpc_failed:%')`, time.Now().Unix())
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
	rows, err := m.db.Query(`SELECT id,gid,max_bytes FROM download_tasks
		WHERE status IN ('running','paused')`)
	if err != nil {
		return
	}
	type pending struct {
		id, gid  string
		maxBytes int64
	}
	var active []pending
	for rows.Next() {
		var item pending
		if err := rows.Scan(&item.id, &item.gid, &item.maxBytes); err != nil {
			rows.Close()
			return
		}
		active = append(active, item)
	}
	readErr := rows.Err()
	rows.Close()
	if readErr != nil {
		return
	}
	for _, item := range active {
		ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
		status, err := rpc.TellStatus(ctx, item.gid)
		cancel()
		m.applyPolledStatus(item.id, item.gid, func() {
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
					return
				}
				m.importDownloadLocked(item.id)
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
				m.updatePolledProgress(item.id, item.gid, StatusPaused, status.TotalBytes, status.CompletedBytes)
			default: // active | waiting
				m.updatePolledProgress(item.id, item.gid, StatusRunning, status.TotalBytes, status.CompletedBytes)
			}
		})
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

func (m *Manager) applyPolledStatus(id, gid string, apply func()) {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	var currentGID, status string
	err := m.db.QueryRow("SELECT gid,status FROM download_tasks WHERE id=?", id).Scan(&currentGID, &status)
	if err != nil || currentGID != gid ||
		(status != StatusRunning && status != StatusPaused) {
		return
	}
	apply()
}

func (m *Manager) failTask(id, reason, gid string) {
	diagnostics.Emit(m.ctx, slog.LevelWarn, diagnostics.Event{
		Component: "downloads", Operation: "task", Code: "download_task_failed", TaskID: id,
	})
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
	var failed bool
	if err := m.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM download_tasks
		WHERE status='failed' AND updated_at>?)`, time.Now().Add(-24*time.Hour).Unix()).Scan(&failed); err != nil {
		return false, err
	}
	return !failed, nil
}
