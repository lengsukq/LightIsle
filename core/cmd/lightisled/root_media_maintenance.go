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

// Only the explicitly enabled multi-root preview uses this reconciler.
// The legacy root keeps its existing FSEvents reconciler; extra roots need
// periodic full scans to catch changes made while volumes were offline.
type rootMediaMaintenance struct {
	list     func() []roots.Root
	scan     func(context.Context, string) error
	record   func(string, uint64, string) error
	next     map[string]rootScanDue
	startup  time.Duration
	tick     time.Duration
	periodic time.Duration
	retry    time.Duration
}

type rootScanDue struct {
	generation uint64
	at         time.Time
}

func newRootMediaMaintenance(registry *roots.Registry, rootServer *server.RootServer, journal *tasks.Journal) *rootMediaMaintenance {
	return &rootMediaMaintenance{
		list: registry.List, scan: rootServer.ReconcileRootMedia, record: journal.UpdateRootMaintenance,
		next: map[string]rootScanDue{}, startup: 30 * time.Second, tick: time.Minute,
		periodic: 15 * time.Minute, retry: time.Minute,
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
		if ok && due.generation == root.Generation && now.Before(due.at) {
			continue
		}
		status := "running"
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
			case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrStale), errors.Is(err, roots.ErrMissing):
				status = "offline"
			case errors.Is(err, server.ErrRootMaintenanceBusy):
				status = "busy"
			default:
				status = "failed"
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
		}
		delay := m.retry
		if status == "ok" {
			delay = m.periodic
		}
		m.next[root.ID] = rootScanDue{root.Generation, now.Add(delay)}
	}
	for id := range m.next {
		if !live[id] {
			delete(m.next, id)
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
