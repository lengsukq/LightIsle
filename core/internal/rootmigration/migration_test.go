package rootmigration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func TestPreviewAndCopyProtectSourceConflictsAndPrivateUserData(t *testing.T) {
	base := t.TempDir()
	data, oldPath, newPath := filepath.Join(base, "data"), filepath.Join(base, "old"), filepath.Join(base, "new")
	for _, dir := range []string{data, oldPath, newPath,
		filepath.Join(oldPath, "Photos"), filepath.Join(oldPath, "Videos"),
		filepath.Join(oldPath, "Users", "u7", "files"), filepath.Join(newPath, "Photos")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for name, data := range map[string]string{
		filepath.Join(oldPath, "Photos", "shared.jpg"):                "old",
		filepath.Join(oldPath, "Videos", "film.mp4"):                  "video",
		filepath.Join(oldPath, "Users", "u7", "files", "private.txt"): "private",
		filepath.Join(newPath, "Photos", "shared.jpg"):                "new",
	} {
		if err := os.WriteFile(name, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	source, err := registry.Add(context.Background(), "old", oldPath)
	if err != nil {
		t.Fatal(err)
	}
	target, err := registry.Add(context.Background(), "new", newPath)
	if err != nil {
		t.Fatal(err)
	}
	s := New(registry)
	choice := Selection{
		SourceRootID: source.ID, SourceGeneration: source.Generation,
		TargetRootID: target.ID, TargetGeneration: target.Generation,
	}
	preview, err := s.Preview(context.Background(), choice)
	if err != nil {
		t.Fatal(err)
	}
	if preview.FilesToCopy != 1 || preview.BytesToCopy != 5 || preview.Conflicts != 1 || preview.ProtectedFolders != 1 {
		t.Fatalf("unexpected preview: %+v", preview)
	}
	if _, err := s.Start(context.Background(), choice); err != nil {
		t.Fatal(err)
	}
	var status Status
	deadline := time.After(15 * time.Second)
	for {
		status = s.Status()
		if status.Phase != "running" {
			break
		}
		select {
		case <-deadline:
			t.Fatal("copy job never completed")
		case <-time.After(25 * time.Millisecond):
		}
	}
	if status.Phase != "completed" || status.CopiedFiles != 1 || status.CopiedBytes != 5 {
		t.Fatalf("copy result: %+v", status)
	}
	for path, want := range map[string]string{
		filepath.Join(newPath, "Photos", "shared.jpg"):                "new",
		filepath.Join(newPath, "Videos", "film.mp4"):                  "video",
		filepath.Join(oldPath, "Videos", "film.mp4"):                  "video",
		filepath.Join(oldPath, "Users", "u7", "files", "private.txt"): "private",
	} {
		raw, err := os.ReadFile(path)
		if err != nil || string(raw) != want {
			t.Fatalf("%s changed: %q %v", path, raw, err)
		}
	}
	if _, err := os.Stat(filepath.Join(newPath, "Users")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("private data copied without quota or ACL handling: %v", err)
	}
	if _, err := s.Start(context.Background(), choice); err != nil {
		t.Fatal(err)
	}
	deadline = time.After(15 * time.Second)
	for s.Status().Phase == "running" {
		select {
		case <-deadline:
			t.Fatal("repeated copy job never completed")
		case <-time.After(25 * time.Millisecond):
		}
	}
	if s.Status().Phase != "completed" || s.Status().CopiedFiles != 0 {
		t.Fatalf("rerun overwrote existing files: %+v", s.Status())
	}
}

func TestMigrationPreviewSkipsSymlinksAndDoesNotFollowTargetAlias(t *testing.T) {
	base := t.TempDir()
	data, src, dst := filepath.Join(base, "data"), filepath.Join(base, "source"), filepath.Join(base, "target")
	for _, dir := range []string{data, src, dst, filepath.Join(src, "Photos"), filepath.Join(dst, "Photos")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	outside := filepath.Join(base, "outside.txt")
	if err := os.WriteFile(outside, []byte("do not replace"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "Photos", "safe.txt"), []byte("safe"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "Photos", "conflict.txt"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(src, "Photos", "link.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dst, "Photos", "conflict.txt")); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	source, err := registry.Add(context.Background(), "source", src)
	if err != nil {
		t.Fatal(err)
	}
	target, err := registry.Add(context.Background(), "target", dst)
	if err != nil {
		t.Fatal(err)
	}
	selection := Selection{SourceRootID: source.ID, SourceGeneration: source.Generation,
		TargetRootID: target.ID, TargetGeneration: target.Generation}
	migration := New(registry)
	preview, err := migration.Preview(context.Background(), selection)
	if err != nil {
		t.Fatal(err)
	}
	if preview.FilesToCopy != 1 || preview.Conflicts != 1 || preview.UnsupportedEntries != 1 {
		t.Fatalf("symlink boundaries ignored: %+v", preview)
	}
	if _, err := migration.Start(context.Background(), selection); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(10 * time.Second)
	for migration.Status().Phase == "running" {
		select {
		case <-deadline:
			t.Fatal("symlink-copy test timed out")
		case <-time.After(25 * time.Millisecond):
		}
	}
	if migration.Status().Phase != "completed" || migration.Status().CopiedFiles != 1 {
		t.Fatalf("unexpected copy result: %+v", migration.Status())
	}
	body, err := os.ReadFile(outside)
	if err != nil || string(body) != "do not replace" {
		t.Fatalf("symlink redirect modified outside data: %q %v", body, err)
	}
	if info, err := os.Lstat(filepath.Join(dst, "Photos", "conflict.txt")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("target link overwritten: %+v %v", info, err)
	}
}

func TestMigrationRejectsSameAndStaleRoots(t *testing.T) {
	base := t.TempDir()
	for _, dir := range []string{"data", "old", "new"} {
		if err := os.Mkdir(filepath.Join(base, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(filepath.Join(base, "data"), storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	old, err := registry.Add(context.Background(), "old", filepath.Join(base, "old"))
	if err != nil {
		t.Fatal(err)
	}
	svc := New(registry)
	if _, err := svc.Preview(context.Background(), Selection{
		SourceRootID: old.ID, SourceGeneration: old.Generation,
		TargetRootID: old.ID, TargetGeneration: old.Generation,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("same root allowed: %v", err)
	}
	if _, err := svc.Preview(context.Background(), Selection{
		SourceRootID: old.ID, SourceGeneration: old.Generation + 1,
		TargetRootID: "ffffffffffffffffffffffffffffffff", TargetGeneration: 1,
	}); !errors.Is(err, roots.ErrStale) {
		t.Fatalf("stale root allowed: %v", err)
	}
}
