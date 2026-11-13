package auth

import (
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func setupAuthHotPathBench(b *testing.B) (*Store, string, int64, string) {
	b.Helper()
	store, err := Open(filepath.Join(b.TempDir(), "accounts.sqlite"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = store.Close() })
	if err := store.Setup("owner", "owner-password-bench-2026"); err != nil {
		b.Fatal(err)
	}
	adminSession, err := store.Login("owner", "owner-password-bench-2026")
	if err != nil {
		b.Fatal(err)
	}
	member, err := store.CreateUser(adminSession, "family", "family-password-bench-2026", RoleMember)
	if err != nil {
		b.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-password-bench-2026")
	if err != nil {
		b.Fatal(err)
	}
	const rootID = "11111111111111111111111111111111"
	for _, cat := range []string{StorageFiles, StoragePhotos, StorageVideos} {
		if _, err := store.AssignUserStorage(adminSession, member.ID, cat, rootID, 1); err != nil {
			b.Fatal(err)
		}
	}
	if err := store.SetRootGrant(adminSession, member.ID, rootID, "SharedFamily", false); err != nil {
		b.Fatal(err)
	}
	if err := store.SetRootGrant(adminSession, member.ID, rootID, "SharedTrips", true); err != nil {
		b.Fatal(err)
	}
	for i := 0; i < 25; i++ {
		if _, err := store.db.Exec(
			`INSERT INTO user_storage_files(root_id,root_generation,relative_path,user_id,size_bytes) VALUES(?,1,?,?,?)`,
			rootID, fmt.Sprintf("Users/u%d/files/doc-%d.pdf", member.ID, i), member.ID, 1024*1024,
		); err != nil {
			b.Fatal(err)
		}
	}
	return store, memberSession, member.ID, rootID
}

func BenchmarkHotPath_StoragePolicy(b *testing.B) {
	store, memberSession, memberID, _ := setupAuthHotPathBench(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		p, err := store.StoragePolicy(memberSession, memberID)
		if err != nil || p.Enforcement != "pending" {
			b.Fatalf("unexpected policy result: %+v %v", p, err)
		}
	}
}

func BenchmarkHotPath_FirstScreenUnderWriteContention(b *testing.B) {
	store, memberSession, memberID, rootID := setupAuthHotPathBench(b)
	var stop atomic.Bool
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		now := time.Now().Unix()
		for !stop.Load() {
			tx, err := store.db.Begin()
			if err != nil {
				continue
			}
			_, _ = tx.Exec(`INSERT INTO audit_events(actor_id,action,target,outcome,created_at) VALUES(1,'upload_chunk','/files','success',?)`, now)
			time.Sleep(500 * time.Microsecond)
			_ = tx.Commit()
		}
	}()
	b.Cleanup(func() {
		stop.Store(true)
		<-writerDone
	})

	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := store.StoragePolicy(memberSession, memberID); err != nil {
				b.Errorf("StoragePolicy failed: %v", err)
				return
			}
			if !store.CanAccessRootForUser(memberID, rootID, "SharedFamily/album", false, true) {
				b.Errorf("CanAccessRootForUser denied valid path")
				return
			}
			if _, err := store.SearchRootsRoot(memberSession, rootID, "."); err != nil {
				b.Errorf("SearchRootsRoot failed: %v", err)
				return
			}
		}
	})
	b.StopTimer()
	stop.Store(true)
}

func TestHotPathReadsNeverBlockOnActiveWriteTransaction(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-bench-2026"); err != nil {
		t.Fatal(err)
	}
	adminSession, err := store.Login("owner", "owner-password-bench-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(adminSession, "family", "family-password-bench-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-password-bench-2026")
	if err != nil {
		t.Fatal(err)
	}
	const rootID = "11111111111111111111111111111111"
	if _, err := store.AssignUserStorage(adminSession, member.ID, StorageFiles, rootID, 1); err != nil {
		t.Fatal(err)
	}
	if err := store.SetRootGrant(adminSession, member.ID, rootID, "SharedFamily", false); err != nil {
		t.Fatal(err)
	}

	// Hold the single write-pool connection inside an active transaction.
	tx, err := store.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO audit_events(actor_id,action,target,outcome,created_at) VALUES(1,'upload','/files','success',?)`, time.Now().Unix()); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		p, err := store.StoragePolicy(memberSession, member.ID)
		if err != nil {
			done <- err
			return
		}
		if p.Enforcement != "pending" {
			done <- fmt.Errorf("enforcement=%q, want pending", p.Enforcement)
			return
		}
		if !store.CanAccessRootForUser(member.ID, rootID, "SharedFamily/doc.pdf", false, true) {
			done <- fmt.Errorf("CanAccessRootForUser unexpectedly denied")
			return
		}
		if _, err := store.SearchRootsRoot(memberSession, rootID, "."); err != nil {
			done <- err
			return
		}
		done <- nil
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("read hot-path failed under active write tx: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("read hot-path blocked behind uncommitted write-pool transaction")
	}
}
