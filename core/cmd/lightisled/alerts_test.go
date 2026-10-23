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
	if err := j.SyncAlert("storage_low_space", true); err != nil {
		t.Fatal(err)
	}
	probe := func(_ string, stat *syscall.Statfs_t) error { return errors.New("disk unavailable") }
	for _, online := range []bool{true, false} {
		if err := syncAlertObservations(j, storageAlertObservations("fixture", online, probe)); err != nil {
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
	if err := syncAlertObservations(j, storageAlertObservations("fixture", true, healthy)); err != nil {
		t.Fatal(err)
	}
	alerts, err := j.Alerts(true)
	if err != nil || len(alerts) != 0 {
		t.Fatalf("verified capacity did not clear warning: %+v %v", alerts, err)
	}
}
