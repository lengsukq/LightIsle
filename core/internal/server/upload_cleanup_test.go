package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func prepareCleanupPhotos(t *testing.T, f *rootRoutingFixture) string {
	t.Helper()
	response := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, fmt.Sprintf("/users/%d/storage/photos", f.memberID)), "")
	if response.Code != http.StatusOK {
		t.Fatalf("assign photos: %d %s", response.Code, response.Body.String())
	}
	return fmt.Sprintf("Users/u%d/photos", f.memberID)
}

func beginCleanupUpload(t *testing.T, f *rootRoutingFixture, path string, size int) files.UploadState {
	t.Helper()
	body, err := json.Marshal(map[string]any{"path": path, "size": size})
	if err != nil {
		t.Fatal(err)
	}
	response := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/uploads"), string(body))
	if response.Code != http.StatusCreated {
		t.Fatalf("begin upload: %d %s", response.Code, response.Body.String())
	}
	var state files.UploadState
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func ageCleanupUpload(t *testing.T, f *rootRoutingFixture, id string, old time.Time) {
	t.Helper()
	base := filepath.Join(f.pathA, ".lightisle-parts", id)
	data, err := os.ReadFile(base + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var journal map[string]any
	if err := json.Unmarshal(data, &journal); err != nil {
		t.Fatal(err)
	}
	journal["activity"] = old.Unix()
	data, err = json.Marshal(journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(base+".json", data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{".json", ".part"} {
		if err := os.Chtimes(base+suffix, old, old); err != nil {
			t.Fatal(err)
		}
	}
}

func TestUploadCleanupPreservesUncertainDataAndReleasesOnlySafeReservation(t *testing.T) {
	f := newRootRoutingFixture(t)
	dir := prepareCleanupPhotos(t, f)
	stale := beginCleanupUpload(t, f, dir+"/stale.jpg", 5)
	recent := beginCleanupUpload(t, f, dir+"/recent.jpg", 7)
	uncertain := beginCleanupUpload(t, f, dir+"/uncertain.jpg", 9)
	now := time.Now().Truncate(time.Second)
	old := now.Add(-31 * 24 * time.Hour)
	ageCleanupUpload(t, f, stale.ID, old)
	ageCleanupUpload(t, f, uncertain.ID, old)
	destination := filepath.Join(f.pathA, filepath.FromSlash(dir), "uncertain.jpg")
	if err := os.WriteFile(destination, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	orphan := filepath.Join(f.pathA, ".lightisle-parts", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.part")
	if err := os.WriteFile(orphan, []byte("unknown"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(orphan, old, old); err != nil {
		t.Fatal(err)
	}
	cutoff := now.Add(-30 * 24 * time.Hour)
	if _, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation+1, cutoff); !errors.Is(err, roots.ErrStale) {
		t.Fatalf("wrong generation accepted: %v", err)
	}
	report, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation, cutoff)
	if err == nil || err.Error() != "upload_cleanup_needs_review" || report.Removed != 1 || report.Skipped != 2 || report.PendingReservations != 0 {
		t.Fatalf("cleanup report %+v err=%v", report, err)
	}
	if _, err := f.accounts.ReservationForUpload(stale.ID, f.admin); !errors.Is(err, auth.ErrStorageReservationMissing) {
		t.Fatalf("safe reservation not released: %v", err)
	}
	for _, id := range []string{recent.ID, uncertain.ID} {
		if _, err := f.accounts.ReservationForUpload(id, f.admin); err != nil {
			t.Fatalf("uncertain or active reservation lost: %v", err)
		}
	}
	if data, err := os.ReadFile(destination); err != nil || string(data) != "existing" {
		t.Fatalf("destination changed: %q %v", data, err)
	}
	if data, err := os.ReadFile(orphan); err != nil || string(data) != "unknown" {
		t.Fatalf("orphan changed: %q %v", data, err)
	}
	second, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation, cutoff)
	if err == nil || second.Removed != 0 || second.Skipped != 2 {
		t.Fatalf("repeat cleanup: %+v %v", second, err)
	}
}

func TestUploadCleanupRetainsReservationWhenReleaseFails(t *testing.T) {
	f := newRootRoutingFixture(t)
	dir := prepareCleanupPhotos(t, f)
	item := beginCleanupUpload(t, f, dir+"/old.jpg", 5)
	now := time.Now().Truncate(time.Second)
	ageCleanupUpload(t, f, item.ID, now.Add(-31*24*time.Hour))
	db, err := sql.Open("sqlite3", filepath.Join(f.base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TRIGGER fail_cleanup_reservation BEFORE DELETE ON user_storage_reservations BEGIN SELECT RAISE(ABORT,'injected_failure'); END`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	report, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation, now.Add(-30*24*time.Hour))
	if err == nil || err.Error() != "upload_cleanup_needs_review" || report.Removed != 1 || report.PendingReservations != 1 {
		t.Fatalf("failed release hidden: %+v %v", report, err)
	}
	if _, err := f.accounts.ReservationForUpload(item.ID, f.admin); err != nil {
		t.Fatalf("uncertain reservation lost: %v", err)
	}
	response := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/tasks"), "")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "upload_cleanup_needs_review") {
		t.Fatalf("cleanup failure not visible in task center: %d %s", response.Code, response.Body.String())
	}
	response = f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/tasks"), "")
	if response.Code != http.StatusForbidden && response.Code != http.StatusNotFound {
		t.Fatalf("member could inspect cleanup task: %d", response.Code)
	}
	if _, err := os.Stat(filepath.Join(f.pathA, ".lightisle-parts", item.ID+".part")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging was not cleaned: %v", err)
	}
}

func TestUploadCleanupDoesNotTreatOfflineRootAsEmpty(t *testing.T) {
	f := newRootRoutingFixture(t)
	dir := prepareCleanupPhotos(t, f)
	item := beginCleanupUpload(t, f, dir+"/old.jpg", 5)
	now := time.Now().Truncate(time.Second)
	ageCleanupUpload(t, f, item.ID, now.Add(-31*24*time.Hour))
	offline := f.pathA + "-offline"
	if err := os.Rename(f.pathA, offline); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(f.pathA); _ = os.Rename(offline, f.pathA) })
	if _, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation, now.Add(-30*24*time.Hour)); err == nil {
		t.Fatal("offline root was accepted")
	}
	if err := os.Mkdir(f.pathA, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := f.server.SweepRootUploads(context.Background(), f.rootA.ID, f.rootA.Generation, now.Add(-30*24*time.Hour)); err == nil {
		t.Fatal("a different directory at the old path was accepted")
	}
	if _, err := os.Stat(filepath.Join(f.pathA, ".lightisle-parts")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replacement directory was modified: %v", err)
	}
	if _, err := os.Stat(filepath.Join(offline, ".lightisle-parts", item.ID+".part")); err != nil {
		t.Fatalf("offline staged data changed: %v", err)
	}
	if _, err := f.accounts.ReservationForUpload(item.ID, f.admin); err != nil {
		t.Fatalf("offline reservation lost: %v", err)
	}
}
