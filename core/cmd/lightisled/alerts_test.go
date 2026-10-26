//go:build darwin && arm64

package main

import (
	"errors"
	"syscall"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestUnknownCapacityNeverClearsPersistedLowSpaceAlert(t *testing.T) {
	j, err := tasks.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	if _, err := j.SyncAlert("storage_low_space", true); err != nil {
		t.Fatal(err)
	}
	probe := func(_ string, stat *syscall.Statfs_t) error { return errors.New("disk unavailable") }
	for _, online := range []bool{true, false} {
		if err := syncAlertObservations(j, storageAlertObservations("fixture", online, probe, tasks.DefaultThreshold), nil); err != nil {
			t.Fatal(err)
		}
		alerts, err := j.Alerts(true)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, alert := range alerts {
			if alert.Code == "storage_low_space" {
				found = true
			}
		}
		if !found {
			t.Fatalf("unknown capacity reported recovery (online=%v): %+v", online, alerts)
		}
	}
	healthy := func(_ string, stat *syscall.Statfs_t) error {
		stat.Blocks, stat.Bavail, stat.Bsize = 100<<20, 50<<20, 4096
		return nil
	}
	if err := syncAlertObservations(j, storageAlertObservations("fixture", true, healthy, tasks.DefaultThreshold), nil); err != nil {
		t.Fatal(err)
	}
	alerts, err := j.Alerts(true)
	if err != nil || len(alerts) != 0 {
		t.Fatalf("verified capacity did not clear warning: %+v %v", alerts, err)
	}
}

// A transition to active must reach the outbound dispatcher exactly once;
// repeated polling of the same state and the resolution edge stay silent.
func TestSyncAlertObservationsDispatchOnlyOnActivation(t *testing.T) {
	j, err := tasks.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	var activated []string
	record := func(code string) { activated = append(activated, code) }

	if err := syncAlertObservations(j, map[string]bool{"storage_offline": true}, record); err != nil {
		t.Fatal(err)
	}
	if err := syncAlertObservations(j, map[string]bool{"storage_offline": true}, record); err != nil {
		t.Fatal(err)
	}
	if len(activated) != 1 {
		t.Fatalf("activation dispatched %d times: %v", len(activated), activated)
	}
	if err := syncAlertObservations(j, map[string]bool{"storage_offline": false}, record); err != nil {
		t.Fatal(err)
	}
	if len(activated) != 1 {
		t.Fatalf("resolution dispatched: %v", activated)
	}
	if err := syncAlertObservations(j, map[string]bool{"storage_offline": true}, record); err != nil {
		t.Fatal(err)
	}
	if len(activated) != 2 || activated[1] != "storage_offline" {
		t.Fatalf("reopen did not dispatch exactly once: %v", activated)
	}
}
