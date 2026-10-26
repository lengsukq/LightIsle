package files

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAccountingAwareCancellationOnlyReleasesDefinitelyUnpublishedUploads(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	unpublished, err := store.BeginUpload("pending.txt", 3, 42)
	if err != nil {
		t.Fatal(err)
	}
	if safe, err := store.AbortUploadWithAccounting(unpublished.ID, 42); err != nil || !safe {
		t.Fatalf("ordinary abort failed to reclaim staging: safe=%v err=%v", safe, err)
	}
	adminCancelled, err := store.BeginUpload("admin.txt", 3, 42)
	if err != nil {
		t.Fatal(err)
	}
	if safe, err := store.CancelUploadWithAccounting(adminCancelled.ID); err != nil || !safe {
		t.Fatalf("ordinary admin cancellation: safe=%v err=%v", safe, err)
	}

	linked := beginPublishedUpload(t, store, "published.txt", 42, "data")
	if safe, err := store.AbortUploadWithAccounting(linked.ID, 42); err != nil || safe {
		t.Fatalf("published journal returned reclaimable: safe=%v err=%v", safe, err)
	}
	if content, err := store.root.ReadFile("published.txt"); err != nil || string(content) != "data" {
		t.Fatalf("published file changed after cancelling journal: %q %v", content, err)
	}

	ambiguous, err := store.BeginUpload("ambiguous.txt", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.root.Name(), "ambiguous.txt"), []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	if safe, err := store.CancelUploadWithAccounting(ambiguous.ID); err != nil || safe {
		t.Fatalf("occupied destination returned reclaimable: safe=%v err=%v", safe, err)
	}
}

func TestExpiredUploadCleanupKeepsAmbiguousPublicationForReconciliation(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	upload, err := store.BeginUpload("uncertain.txt", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	upload.Activity = time.Now().Add(-9 * 24 * time.Hour).Unix()
	if _, err := store.persistUpload(upload); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.root.Name(), "uncertain.txt"), []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	removed, skipped, _, err := store.CleanupExpiredUploads(time.Now().Add(-7 * 24 * time.Hour).Unix())
	if err != nil || len(removed) != 0 || skipped != 1 {
		t.Fatalf("uncertain upload cleaned without reconciliation: removed=%v skipped=%d err=%v", removed, skipped, err)
	}
	if _, err := store.UploadInfo(upload.ID, 42); err != nil {
		t.Fatalf("uncertain upload journal removed: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(store.root.Name(), "uncertain.txt")); err != nil || string(data) != "data" {
		t.Fatalf("uncertain published bytes changed: %q %v", data, err)
	}
}
