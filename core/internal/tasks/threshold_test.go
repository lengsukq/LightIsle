package tasks

import (
	"path/filepath"
	"testing"
)

func TestThresholdDefaultsAndPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "storage-alerts.json")
	store := OpenThresholdStore(path)
	if got := store.Get(); got != DefaultThreshold {
		t.Fatalf("default threshold = %+v", got)
	}
	applied, err := store.Set(Threshold{FreeMiB: 4096, Percent: 10})
	if err != nil {
		t.Fatalf("Set: %v", err)
	}
	if applied.FreeMiB != 4096 || applied.Percent != 10 {
		t.Fatalf("applied = %+v", applied)
	}
	reopened := OpenThresholdStore(path)
	if got := reopened.Get(); got.FreeMiB != 4096 || got.Percent != 10 {
		t.Fatalf("persisted threshold lost: %+v", got)
	}
}

func TestThresholdClampAndReject(t *testing.T) {
	path := filepath.Join(t.TempDir(), "storage-alerts.json")
	store := OpenThresholdStore(path)
	if _, err := store.Set(Threshold{FreeMiB: 0, Percent: 0}); err == nil {
		t.Fatal("expected all-zero threshold to be rejected")
	}
	if got := store.Get(); got != DefaultThreshold {
		t.Fatalf("rejected set must not change state: %+v", got)
	}
	applied, err := store.Set(Threshold{FreeMiB: 1 << 30, Percent: 999})
	if err != nil {
		t.Fatalf("Set: %v", err)
	}
	if applied.FreeMiB != maxFreeMiB || applied.Percent != maxPercent {
		t.Fatalf("clamp failed: %+v", applied)
	}
	applied, err = store.Set(Threshold{FreeMiB: -5, Percent: 10})
	if err != nil {
		t.Fatalf("negative values should clamp, got %v", err)
	}
	if applied.FreeMiB != 0 || applied.Percent != 10 {
		t.Fatalf("negative clamp failed: %+v", applied)
	}
}
