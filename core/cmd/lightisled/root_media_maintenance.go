//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// One serial sweep covers registered roots at startup and occasionally
// reconciles events the native watcher could not deliver.
type rootMediaMaintenance struct {
	list     func() []roots.Root
	scan     func(context.Context, string) error
	record   func(string, uint64, string) error
	next     map[string]rootScanDue
	failures map[string]int
	startup  time.Duration
	tick     time.Duration
	periodic time.Duration
	retry    time.Duration
}

// Errors must not suppress indexing for a full daily interval. Exponential
// retry bounds work when an index stays corrupt while allowing repaired
// optional services to recover without a new filesystem event.
func (m *rootMediaMaintenance) failureDelay(id string) time.Duration {
	if m.failures == nil {
		m.failures = make(map[string]int)
	}
	count := m.failures[id]
	if count < 5 {
		m.failures[id] = count + 1
	}
	delay := m.retry * time.Duration(1<<min(count, 5))
	if delay > 30*time.Minute {
		return 30 * time.Minute
	}
	return delay
}

type rootScanDue struct {
	generation uint64
	at         time.Time
}

const rootMediaReconcileInterval = 24 * time.Hour

func newRootMediaMaintenance(registry *roots.Registry, rootServer *server.RootServer, journal *tasks.Journal) *rootMediaMaintenance {
	return &rootMediaMaintenance{
		list: registry.List, scan: rootServer.ReconcileRootMedia,
		record: func(id string, generation uint64, status string) error {
			if journal == nil {
				return nil
			}
			return journal.UpdateRootMaintenance(id, generation, status)
		},
		next: map[string]rootScanDue{}, startup: 30 * time.Second, tick: time.Minute,
		failures: map[string]int{},
		periodic: rootMediaReconcileInterval, retry: time.Minute,
	}
}

// runDue processes roots sequentially. Even a 16-root NAS will not launch
// 16 media indexers simultaneously. A busy manual scan is retried, not
// interrupted or counted as an automatic successful pass.
func (m *rootMediaMaintenance) runDue(ctx context.Context, now time.Time) {
	live := map[string]bool{}
	for _, root := range m.list() {
		if ctx.Err() != nil {
			return
		}
		live[root.ID] = true
		due, ok := m.next[root.ID]
		if ok && due.generation != root.Generation {
			delete(m.failures, root.ID)
		}
		if ok && due.generation == root.Generation && now.Before(due.at) {
			continue
		}
		status := "running"
		delay := m.retry
		if root.Pending {
			status = "offline"
		}
		if err := m.record(root.ID, root.Generation, status); err != nil {
			slog.Warn("root maintenance state unavailable; scan postponed", "error", err)
			m.next[root.ID] = rootScanDue{root.Generation, now.Add(m.retry)}
			continue
		}
		if status != "offline" {
			err := m.scan(ctx, root.ID)
			switch {
			case err == nil:
				status = "ok"
				delay = m.periodic
				delete(m.failures, root.ID)
			case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrStale), errors.Is(err, roots.ErrMissing):
				status = "offline"
			case errors.Is(err, server.ErrRootMaintenanceBusy):
				status = "busy"
			case errors.Is(err, server.ErrRootMediaUnavailable):
				status = "failed"
				delay = m.failureDelay(root.ID)
			default:
				status = "failed"
				delay = m.failureDelay(root.ID)
				if ctx.Err() == nil {
					slog.Warn("additional root media reconciliation failed", "rootID", root.ID, "error", err)
				}
			}
		}
		if ctx.Err() != nil {
			return
		} // journal Open marks interrupted scans
		if err := m.record(root.ID, root.Generation, status); err != nil {
			slog.Warn("root maintenance result unavailable", "rootID", root.ID, "error", err)
			status = "failed"
			delay = m.retry
		}
		m.next[root.ID] = rootScanDue{root.Generation, now.Add(delay)}
	}
	for id := range m.next {
		if !live[id] {
			delete(m.next, id)
			delete(m.failures, id)
		}
	}
}

func (m *rootMediaMaintenance) Run(ctx context.Context) {
	start := time.NewTimer(m.startup)
	defer start.Stop()
	select {
	case <-ctx.Done():
		return
	case <-start.C:
	}
	m.runDue(ctx, time.Now())
	ticker := time.NewTicker(m.tick)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			m.runDue(ctx, now)
		}
	}
}
