package gallery

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestApplyMetadataOverridesPreservedAcrossScan(t *testing.T) {
	dataDir := t.TempDir()
	fm, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer fm.Close()
	shareDir := filepath.Join(dataDir, "SharedFiles")
	imgPath := filepath.Join(shareDir, "old-wechat-photo.jpg")
	if err := os.WriteFile(imgPath, []byte{0xFF, 0xD8, 0xFF, 0xD9}, 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(dataDir, fm)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(15 * time.Millisecond)
	}
	assets, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 {
		t.Fatalf("expected 1 scanned asset, got %d (%v)", len(assets), err)
	}
	assetID := assets[0].ID

	// Reject out-of-range latitude.
	badLat := 95.0
	badLon := 116.4
	if _, err := lib.ApplyMetadataOverrides([]int64{assetID}, MetadataOverridePatch{Latitude: &badLat, Longitude: &badLon}); !errors.Is(err, ErrInvalidMetadataOverride) {
		t.Fatalf("expected ErrInvalidMetadataOverride for lat=95, got %v", err)
	}

	// Apply corrected date + GPS location (Beijing).
	fixedTime := time.Date(2015, 10, 1, 12, 0, 0, 0, time.UTC).Unix()
	lat, lon := 39.9042, 116.4074
	n, err := lib.ApplyMetadataOverrides([]int64{assetID}, MetadataOverridePatch{
		TakenAt:   &fixedTime,
		Latitude:  &lat,
		Longitude: &lon,
	})
	if err != nil || n != 1 {
		t.Fatalf("ApplyMetadataOverrides failed: n=%d err=%v", n, err)
	}

	updated, err := lib.Asset(assetID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.TakenAt != fixedTime || updated.Latitude == nil || *updated.Latitude != lat || updated.Longitude == nil || *updated.Longitude != lon {
		t.Fatalf("unexpected updated asset metadata: %+v", updated)
	}

	// Touch file mtime to force rescan upsert and verify overrides survive.
	later := time.Now().Add(2 * time.Second)
	_ = os.Chtimes(imgPath, later, later)
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(15 * time.Millisecond)
	}
	afterScan, err := lib.Asset(assetID)
	if err != nil {
		t.Fatal(err)
	}
	if afterScan.TakenAt != fixedTime || afterScan.Latitude == nil || *afterScan.Latitude != lat {
		t.Fatalf("rescan overwrote user metadata override: %+v", afterScan)
	}

	// Clear location only, keeping corrected date.
	if _, err := lib.ApplyMetadataOverrides([]int64{assetID}, MetadataOverridePatch{ClearLocation: true}); err != nil {
		t.Fatal(err)
	}
	cleared, err := lib.Asset(assetID)
	if err != nil {
		t.Fatal(err)
	}
	if cleared.TakenAt != fixedTime || cleared.Latitude != nil || cleared.Longitude != nil {
		t.Fatalf("expected cleared location with preserved date, got %+v", cleared)
	}
}
