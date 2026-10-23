package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestWritableHintsRespectSubtreesAndRevocation(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "file-hints-owner-password"); err != nil {
		t.Fatal(err)
	}
	owner, err := store.Login("owner", "file-hints-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(owner, "viewer", "file-hints-viewer-password", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	viewer, err := store.Login("viewer", "file-hints-viewer-password")
	if err != nil {
		t.Fatal(err)
	}
	for _, grant := range []struct {
		path  string
		write bool
	}{{"family", false}, {"family/uploads", true}} {
		if err := store.SetFileGrant(owner, member.ID, grant.path, grant.write); err != nil {
			t.Fatal(err)
		}
	}
	paths := []string{".", "family", "family/photo.jpg", "family/uploads", "family/uploads/photo.jpg", "family/uploads-other/photo.jpg", "private", "../private"}
	hints, err := store.WritablePaths(viewer, paths)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		want := path == "family/uploads" || path == "family/uploads/photo.jpg"
		if hints[path] != want || hints[path] != store.CanAccess(viewer, path, true, false) {
			t.Errorf("write hint disagrees with effective permission for %s: %v", path, hints[path])
		}
	}
	if err := store.RemoveFileGrant(owner, member.ID, "family/uploads"); err != nil {
		t.Fatal(err)
	}
	refreshed, err := store.WritablePaths(viewer, []string{"family/uploads/photo.jpg"})
	if err != nil || refreshed["family/uploads/photo.jpg"] || store.CanAccess(viewer, "family/uploads/photo.jpg", true, false) {
		t.Fatalf("revoked write permission remained effective: %+v %v", refreshed, err)
	}
	adminHints, err := store.WritablePaths(owner, paths)
	if err != nil || !adminHints["private"] || adminHints["../private"] {
		t.Fatalf("admin hint path validation: %+v %v", adminHints, err)
	}
	if _, err := store.WritablePaths("not-a-session", paths); !errors.Is(err, ErrForbidden) {
		t.Fatalf("anonymous hint access: %v", err)
	}
	if _, err := store.WritablePaths(owner, make([]string, 257)); !errors.Is(err, ErrInput) {
		t.Fatalf("unbounded hints request: %v", err)
	}
}
