//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

func TestRootMediaMaintenanceOfflineRetryBusyAndGeneration(t *testing.T) {
	first, second, third, legacy := strings.Repeat("a", 32), strings.Repeat("b", 32),
		strings.Repeat("c", 32), strings.Repeat("d", 32)
	items := []roots.Root{
		{ID: first, Generation: 1},
		{ID: second, Generation: 1, Pending: true},
		{ID: third, Generation: 1},
		{ID: legacy, Generation: 1, Compatibility: true},
	}
	type observation struct {
		id, status string
		gen        uint64
	}
	var persisted []observation
	scans := map[string]int{}
	m := &rootMediaMaintenance{
		list: func() []roots.Root { return items },
		scan: func(_ context.Context, id string) error {
			scans[id]++
			if id == third && scans[id] == 1 {
				return server.ErrRootMaintenanceBusy
			}
			return nil
		},
		record: func(id string, gen uint64, status string) error {
			persisted = append(persisted, observation{id, status, gen})
			return nil
		},
		next: map[string]rootScanDue{}, periodic: 15 * time.Minute, retry: time.Minute,
	}
	now := time.Unix(100000, 0)
	m.runDue(context.Background(), now)
	if scans[first] != 1 || scans[second] != 0 || scans[third] != 1 || scans[legacy] != 0 {
		t.Fatalf("offline/legacy/busy scope changed: %+v", scans)
	}
	if m.next[first].at != now.Add(15*time.Minute) || m.next[second].at != now.Add(time.Minute) ||
		m.next[third].at != now.Add(time.Minute) {
		t.Fatalf("incorrect retry cadence: %+v", m.next)
	}
	m.runDue(context.Background(), now.Add(30*time.Second))
	if scans[first] != 1 || scans[third] != 1 {
		t.Fatal("scan repeated before due")
	}
	items[1].Pending = false
	m.runDue(context.Background(), now.Add(61*time.Second))
	if scans[first] != 1 || scans[second] != 1 || scans[third] != 2 {
		t.Fatalf("offline recovery or busy retry missing: %+v", scans)
	}
	items[0].Generation = 2
	m.runDue(context.Background(), now.Add(65*time.Second))
	if scans[first] != 2 {
		t.Fatal("generation change did not force scan")
	}
	if got := persisted[len(persisted)-1]; got.id != first || got.gen != 2 || got.status != "ok" {
		t.Fatalf("generation status not recorded: %+v", got)
	}
	items = items[:3]
	items = items[1:]
	m.runDue(context.Background(), now.Add(66*time.Second))
	if _, found := m.next[first]; found {
		t.Fatal("removed root remained scheduled")
	}
}

func TestRootMediaMaintenanceDoesNotScanWhenStateCannotBePersisted(t *testing.T) {
	id := strings.Repeat("e", 32)
	attempts := 0
	m := &rootMediaMaintenance{
		list:   func() []roots.Root { return []roots.Root{{ID: id, Generation: 1}} },
		scan:   func(context.Context, string) error { attempts++; return nil },
		record: func(string, uint64, string) error { return errors.New("sqlite_unavailable") },
		next:   map[string]rootScanDue{}, periodic: 15 * time.Minute, retry: time.Minute,
	}
	m.runDue(context.Background(), time.Unix(42, 0))
	if attempts != 0 {
		t.Fatal("failed journal must not launch untracked scan")
	}
}
