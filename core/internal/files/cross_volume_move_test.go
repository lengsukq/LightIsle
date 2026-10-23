package files

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMoveOutJournalPublishesVerifiedDestinationAndTrashesSource(t *testing.T) {
	base := t.TempDir()
	m, err := NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	destination := testExportRoot(t)
	const contents = "important-family-archive"
	if _, err := m.Upload("family.txt", strings.NewReader(contents)); err != nil {
		t.Fatal(err)
	}
	receipt, err := m.MoveOut(context.Background(), "family.txt", destination)
	if err != nil {
		t.Fatalf("MoveOut: %v, receipt %+v", err, receipt)
	}
	if receipt.Phase != "source_in_trash" || receipt.Destination != filepath.Join(destination, "family.txt") {
		t.Fatalf("unexpected durable receipt: %+v", receipt)
	}
	bytes, err := os.ReadFile(receipt.Destination)
	if err != nil || string(bytes) != contents {
		t.Fatalf("destination mismatch: %s %v", string(bytes), err)
	}
	if _, _, err := m.Read("family.txt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("source was not moved from visible tree: %v", err)
	}
	trash, err := m.TrashList()
	if err != nil || len(trash) != 1 || trash[0].OriginalPath != "family.txt" {
		t.Fatalf("original file not safely recoverable: %+v %v", trash, err)
	}
	list, err := m.ListTransfers()
	if err != nil || len(list) != 1 || list[0].Phase != "source_in_trash" {
		t.Fatalf("journal lost: %+v %v", list, err)
	}
	if err := m.Restore(trash[0].ID); err != nil {
		t.Fatalf("trash restore failed: %v", err)
	}
	f, _, err := m.Read("family.txt")
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := os.Stat(receipt.Destination); err != nil {
		t.Fatalf("restoring source removed exported copy: %v", err)
	}
}

func TestMoveOutPreTrashDigestDetectsPublishedCopyCorruption(t *testing.T) {
	base := t.TempDir()
	s, err := Open(filepath.Join(base, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	destination := testExportRoot(t)
	if _, err := s.Upload("family.txt", strings.NewReader("stable-content")); err != nil {
		t.Fatal(err)
	}
	original, err := s.root.Lstat("family.txt")
	if err != nil {
		t.Fatal(err)
	}
	publication, err := s.CopyOut(context.Background(), "family.txt", destination)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.verifyPublishedMove(context.Background(), "family.txt", publication, destination, original); err != nil {
		t.Fatalf("valid published copy unexpectedly rejected: %v", err)
	}
	if err := os.WriteFile(publication, []byte("tampered-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.verifyPublishedMove(context.Background(), "family.txt", publication, destination, original); err == nil {
		t.Fatal("corrupted destination unexpectedly deemed safe for source removal")
	}
	if _, _, err := s.Read("family.txt"); err != nil {
		t.Fatalf("source lost when verification failed: %v", err)
	}
}

func newMoveOutRaceFixture(t *testing.T, contents string) (*Manager, string, string) {
	t.Helper()
	m, err := NewManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = m.Close() })
	destination := testExportRoot(t)
	if _, err := m.Upload("family.txt", strings.NewReader(contents)); err != nil {
		t.Fatal(err)
	}
	share, online := m.State()
	if !online {
		t.Fatal("shared folder should be online")
	}
	return m, destination, filepath.Join(share, "family.txt")
}

func isContentTrashRename(from, to string) bool {
	return filepath.Dir(to) == Trash && filepath.Ext(to) != ".json" && from != ""
}

func TestMoveOutRestoresRacedReplacementWithoutLosingEitherVersion(t *testing.T) {
	const original = "original version"
	const replacement = "replaced version"
	m, destination, sourcePath := newMoveOutRaceFixture(t, original)
	originalInfo, err := os.Stat(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	preservedOriginal := filepath.Join(t.TempDir(), "preserved-original.txt")
	injected := false
	m.store.rename = func(from, to string) error {
		if isContentTrashRename(from, to) && !injected {
			injected = true
			if err := os.Rename(sourcePath, preservedOriginal); err != nil {
				return err
			}
			if err := os.WriteFile(sourcePath, []byte(replacement), 0600); err != nil {
				return err
			}
			if err := os.Chtimes(sourcePath, originalInfo.ModTime(), originalInfo.ModTime()); err != nil {
				return err
			}
		}
		return m.store.root.Rename(from, to)
	}
	receipt, err := m.MoveOut(context.Background(), "family.txt", destination)
	if err == nil || !injected {
		t.Fatalf("raced replacement unexpectedly moved successfully: receipt=%+v err=%v", receipt, err)
	}
	if receipt.Phase != "source_changed_restored" || receipt.TrashID != "" {
		t.Fatalf("replacement was not recorded as restored: %+v", receipt)
	}
	if got, err := os.ReadFile(sourcePath); err != nil || string(got) != replacement {
		t.Fatalf("replacement was not restored at source: %q %v", got, err)
	}
	if got, err := os.ReadFile(preservedOriginal); err != nil || string(got) != original {
		t.Fatalf("raced-away original was lost: %q %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "family.txt")); err != nil || string(got) != original {
		t.Fatalf("published original copy changed: %q %v", got, err)
	}
	trash, err := m.TrashList()
	if err != nil || len(trash) != 0 {
		t.Fatalf("restored replacement left an active trash item: %+v %v", trash, err)
	}
}

func TestMoveOutDetectsSameInodeRewriteAfterHashAndRestoresSource(t *testing.T) {
	const original = "family photo v1"
	const changed = "family photo v2"
	m, destination, sourcePath := newMoveOutRaceFixture(t, original)
	originalInfo, err := os.Stat(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	injected := false
	m.store.rename = func(from, to string) error {
		if isContentTrashRename(from, to) && !injected {
			injected = true
			if err := os.WriteFile(sourcePath, []byte(changed), 0600); err != nil {
				return err
			}
			if err := os.Chtimes(sourcePath, originalInfo.ModTime(), originalInfo.ModTime()); err != nil {
				return err
			}
		}
		return m.store.root.Rename(from, to)
	}
	receipt, err := m.MoveOut(context.Background(), "family.txt", destination)
	if err == nil || !injected {
		t.Fatalf("same-inode rewrite unexpectedly moved successfully: receipt=%+v err=%v", receipt, err)
	}
	if receipt.Phase != "source_changed_restored" {
		t.Fatalf("same-inode rewrite was not recorded as restored: %+v", receipt)
	}
	if got, err := os.ReadFile(sourcePath); err != nil || string(got) != changed {
		t.Fatalf("changed source was not restored: %q %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "family.txt")); err != nil || string(got) != original {
		t.Fatalf("verified destination unexpectedly changed: %q %v", got, err)
	}
}

func TestMoveOutKeepsTrashWhenNoOverwriteRestoreTargetAppears(t *testing.T) {
	const original = "family photo v1"
	const changed = "family photo v2"
	const occupant = "arrived at source"
	m, destination, sourcePath := newMoveOutRaceFixture(t, original)
	originalInfo, err := os.Stat(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	injected := false
	m.store.rename = func(from, to string) error {
		if isContentTrashRename(from, to) && !injected {
			injected = true
			if err := os.WriteFile(sourcePath, []byte(changed), 0600); err != nil {
				return err
			}
			if err := os.Chtimes(sourcePath, originalInfo.ModTime(), originalInfo.ModTime()); err != nil {
				return err
			}
			if err := m.store.root.Rename(from, to); err != nil {
				return err
			}
			return os.WriteFile(sourcePath, []byte(occupant), 0600)
		}
		return m.store.root.Rename(from, to)
	}
	receipt, err := m.MoveOut(context.Background(), "family.txt", destination)
	if err == nil || !injected {
		t.Fatalf("occupied restore path unexpectedly moved successfully: receipt=%+v err=%v", receipt, err)
	}
	if receipt.Phase != "source_trash_unresolved" || receipt.TrashID == "" {
		t.Fatalf("unresolved trash state was not recorded: %+v", receipt)
	}
	if got, err := os.ReadFile(sourcePath); err != nil || string(got) != occupant {
		t.Fatalf("no-overwrite restore replaced the concurrent source occupant: %q %v", got, err)
	}
	trash, err := m.TrashList()
	if err != nil || len(trash) != 1 || trash[0].ID != receipt.TrashID || trash[0].OriginalPath != "family.txt" {
		t.Fatalf("unverified moved source was not retained in recoverable trash: %+v %v", trash, err)
	}
	if got, err := os.ReadFile(filepath.Join(m.store.root.Name(), Trash, receipt.TrashID)); err != nil || string(got) != changed {
		t.Fatalf("recovery trash content was lost: %q %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "family.txt")); err != nil || string(got) != original {
		t.Fatalf("published copy unexpectedly changed: %q %v", got, err)
	}
}

func TestMoveOutRechecksPublishedTargetAfterMovingSource(t *testing.T) {
	const original = "family photo v1"
	const tampered = "family photo v2"
	m, destination, sourcePath := newMoveOutRaceFixture(t, original)
	originalInfo, err := os.Stat(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	injected := false
	m.store.rename = func(from, to string) error {
		if isContentTrashRename(from, to) && !injected {
			injected = true
			if err := os.WriteFile(filepath.Join(destination, "family.txt"), []byte(tampered), 0600); err != nil {
				return err
			}
			if err := os.Chtimes(filepath.Join(destination, "family.txt"), originalInfo.ModTime(), originalInfo.ModTime()); err != nil {
				return err
			}
		}
		return m.store.root.Rename(from, to)
	}
	receipt, err := m.MoveOut(context.Background(), "family.txt", destination)
	if err == nil || !injected {
		t.Fatalf("published target mutation unexpectedly moved successfully: receipt=%+v err=%v", receipt, err)
	}
	if receipt.Phase != "source_changed_restored" {
		t.Fatalf("target mismatch was not recorded as source-restored: %+v", receipt)
	}
	if got, err := os.ReadFile(sourcePath); err != nil || string(got) != original {
		t.Fatalf("verified source was not restored: %q %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "family.txt")); err != nil || string(got) != tampered {
		t.Fatalf("target race fixture was not retained: %q %v", got, err)
	}
}

func TestMoveOutTrashPublicationDoesNotReplaceExistingRecoveryItem(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("family.txt", strings.NewReader("visible source")); err != nil {
		t.Fatal(err)
	}
	const collisionID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	collisionPath := filepath.Join(s.root.Name(), Trash, collisionID)
	if err := os.WriteFile(collisionPath, []byte("existing recovery item"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.renameSourceToTrashNoReplace("family.txt", collisionID); !errors.Is(err, ErrExists) {
		t.Fatalf("trash-name collision was not rejected: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(s.root.Name(), Trash, collisionID)); err != nil || string(got) != "existing recovery item" {
		t.Fatalf("existing recovery item was overwritten: %q %v", got, err)
	}
	if got, _, err := s.Read("family.txt"); err != nil {
		t.Fatalf("visible source was moved despite the collision: %v", err)
	} else {
		got.Close()
	}
}

func TestMoveOutRefusesDirectoriesOverlapsAndExistingDestinations(t *testing.T) {
	base := t.TempDir()
	m, err := NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	destination := testExportRoot(t)
	if err := m.Mkdir("photos"); err != nil {
		t.Fatal(err)
	}
	if _, err := m.MoveOut(context.Background(), "photos", destination); !errors.Is(err, ErrType) {
		t.Fatalf("directory moved unsafely: %v", err)
	}
	if _, err := m.Upload("paper.txt", strings.NewReader("copy-me")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "paper.txt"), []byte("keep-original"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.MoveOut(context.Background(), "paper.txt", destination); !errors.Is(err, ErrExists) {
		t.Fatalf("overwrote destination: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "paper.txt")); err != nil || string(got) != "keep-original" {
		t.Fatalf("destination content changed: %q %v", got, err)
	}
	if _, _, err := m.Read("paper.txt"); err != nil {
		t.Fatalf("source was deleted after failed copy: %v", err)
	}
	if _, err := m.MoveOut(context.Background(), "paper.txt", filepath.Join(base, "SharedFiles")); !errors.Is(err, ErrPath) {
		t.Fatalf("overlapping path permitted: %v", err)
	}
	list, err := m.ListTransfers()
	if err != nil || len(list) != 1 || list[0].Phase != "copy_incomplete" {
		t.Fatalf("failed copy not recorded: %+v %v", list, err)
	}
}
