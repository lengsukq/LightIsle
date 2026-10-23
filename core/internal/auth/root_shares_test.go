package auth

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

const (
	rootShareA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	rootShareB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

func newRootShareFixture(t *testing.T) (*Store, string, int64, string) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "reader", "reader-password-12345", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := s.Login("reader", "reader-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	return s, admin, member.ID, reader
}

func rootShareExpiry() int64 { return time.Now().Add(time.Hour).Unix() }

func TestRootFileSharesBindSamePathToDistinctRoots(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	for _, rootID := range []string{rootShareA, rootShareB} {
		if err := s.SetRootGrant(admin, userID, rootID, "photos", false); err != nil {
			t.Fatal(err)
		}
	}
	shareA, tokenA, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/same.jpg", "fingerprint-a", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	shareB, tokenB, err := s.CreateRootFileShare(context.Background(), reader, rootShareB, 1, "photos/same.jpg", "fingerprint-b", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	if shareA.RootID != rootShareA || shareB.RootID != rootShareB || shareA.RootGeneration != 1 || shareB.RootGeneration != 1 || shareA.ID == shareB.ID {
		t.Fatalf("shares did not retain independent root identity: A=%+v B=%+v", shareA, shareB)
	}
	accessA, err := s.ResolveRootFileShare(tokenA)
	if err != nil || accessA.RootID != rootShareA || accessA.RootGeneration != 1 || accessA.Path != "photos/same.jpg" || accessA.Identity != "fingerprint-a" {
		t.Fatalf("root A resolution: %+v %v", accessA, err)
	}
	accessB, err := s.ResolveRootFileShare(tokenB)
	if err != nil || accessB.RootID != rootShareB || accessB.RootGeneration != 1 || accessB.Identity != "fingerprint-b" {
		t.Fatalf("root B resolution: %+v %v", accessB, err)
	}
	listedA, err := s.ListRootFileShares(reader, rootShareA)
	if err != nil || len(listedA) != 1 || listedA[0].ID != shareA.ID || listedA[0].RootID != rootShareA {
		t.Fatalf("root A list leaked or omitted shares: %+v %v", listedA, err)
	}
	listedB, err := s.ListRootFileShares(reader, rootShareB)
	if err != nil || len(listedB) != 1 || listedB[0].ID != shareB.ID || listedB[0].RootID != rootShareB {
		t.Fatalf("root B list leaked or omitted shares: %+v %v", listedB, err)
	}
	if err := s.RevokeRootFileShare(context.Background(), reader, rootShareA, shareA.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveRootFileShare(tokenA); !errors.Is(err, ErrNotFound) {
		t.Fatalf("root A token survived revocation: %v", err)
	}
	if _, err := s.ResolveRootFileShare(tokenB); err != nil {
		t.Fatalf("root A revocation affected root B: %v", err)
	}
}

func TestRootFileSharesRequireAndPersistRootGeneration(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 0, "photos/old.jpg", "old", rootShareExpiry()); !errors.Is(err, ErrInput) {
		t.Fatalf("zero root generation was accepted: %v", err)
	}
	_, oldToken, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 3, "photos/old.jpg", "old", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	_, newToken, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 4, "photos/new.jpg", "new", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	oldAccess, err := s.ResolveRootFileShare(oldToken)
	if err != nil || oldAccess.RootGeneration != 3 {
		t.Fatalf("old root generation was not retained: %+v %v", oldAccess, err)
	}
	newAccess, err := s.ResolveRootFileShare(newToken)
	if err != nil || newAccess.RootGeneration != 4 {
		t.Fatalf("new root generation was not retained: %+v %v", newAccess, err)
	}
}

func TestOpenInvalidatesRootSharesWithoutGeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "accounts.sqlite")
	legacy, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = legacy.Exec(`CREATE TABLE root_file_shares(
		id BLOB PRIMARY KEY,user_id INTEGER NOT NULL,root_id TEXT NOT NULL,
		file_path TEXT NOT NULL,file_identity TEXT NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL)`)
	if err != nil {
		_ = legacy.Close()
		t.Fatal(err)
	}
	_, err = legacy.Exec(`INSERT INTO root_file_shares(id,user_id,root_id,file_path,file_identity,created_at,expires_at)
		VALUES(?,?,?,?,?,?,?)`, []byte("old-token-digest"), 1, rootShareA, "photos/old.jpg", "fingerprint", time.Now().Unix(), time.Now().Add(time.Hour).Unix())
	if err != nil {
		_ = legacy.Close()
		t.Fatal(err)
	}
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM root_file_shares").Scan(&count); err != nil || count != 0 {
		t.Fatalf("unbound pre-generation links were not cleared: count=%d err=%v", count, err)
	}
	var generationColumn int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('root_file_shares') WHERE name='root_generation'").Scan(&generationColumn); err != nil || generationColumn != 1 {
		t.Fatalf("root generation migration missing: count=%d err=%v", generationColumn, err)
	}
}

func TestRootGrantRevokeAndRegrantDoesNotReviveShare(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	share, token, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/photo.jpg", "fingerprint", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveRootGrant(admin, userID, rootShareA, "photos"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveRootFileShare(token); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked root share still resolved: %v", err)
	}
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	if !s.UserCanReadRoot(userID, rootShareA, "photos/photo.jpg") {
		t.Fatal("fresh grant was not restored")
	}
	if _, err := s.ResolveRootFileShare(token); !errors.Is(err, ErrNotFound) {
		t.Fatalf("old token revived after grant recreation: %v", err)
	}
	if shares, err := s.ListRootFileShares(reader, rootShareA); err != nil || len(shares) != 0 {
		t.Fatalf("revoked token remains listed: %+v %v", shares, err)
	}
	if share.ID == "" {
		t.Fatal("fixture did not create the expected share")
	}
}

func TestRootShareConcurrentGrantRevocationRejectsCreate(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	checked, resume := make(chan struct{}), make(chan struct{})
	s.afterShareAuthorization = func() { close(checked); <-resume }
	type result struct {
		token string
		err   error
	}
	done := make(chan result, 1)
	go func() {
		_, token, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/photo.jpg", "fingerprint", rootShareExpiry())
		done <- result{token: token, err: err}
	}()
	<-checked
	if err := s.RemoveRootGrant(admin, userID, rootShareA, "photos"); err != nil {
		close(resume)
		t.Fatal(err)
	}
	close(resume)
	created := <-done
	if created.token != "" || !errors.Is(created.err, ErrForbidden) {
		t.Fatalf("create passed after concurrent grant revoke: token=%q err=%v", created.token, created.err)
	}
	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM root_file_shares WHERE user_id=? AND root_id=?", userID, rootShareA).Scan(&count); err != nil || count != 0 {
		t.Fatalf("stale root share persisted: count=%d err=%v", count, err)
	}
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	s.afterShareAuthorization = nil
	if _, _, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/photo.jpg", "fresh", rootShareExpiry()); err != nil {
		t.Fatalf("freshly authorized create failed: %v", err)
	}
}

func TestRootReadAndSearchHelpersAreRootScoped(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos/family", false); err != nil {
		t.Fatal(err)
	}
	if !s.CanSeeRoot(reader, rootShareA, "photos") || s.CanSeeRoot(reader, rootShareB, "photos") {
		t.Fatal("root-scoped traversal crossed roots")
	}
	if !s.UserCanReadRoot(userID, rootShareA, "photos/family/2026.jpg") || s.UserCanReadRoot(userID, rootShareB, "photos/family/2026.jpg") {
		t.Fatal("root-scoped read authorization crossed roots")
	}
	got, err := s.SearchRootsRoot(reader, rootShareA, ".")
	if err != nil || !reflect.DeepEqual(got, []string{"photos/family"}) {
		t.Fatalf("root A search roots = %#v, err=%v", got, err)
	}
	got, err = s.SearchRootsRoot(reader, rootShareB, ".")
	if err != nil || len(got) != 0 {
		t.Fatalf("root B inherited root A search roots: %#v, err=%v", got, err)
	}
	if got, err = s.SearchRootsRoot(reader, rootShareA, "photos"); err != nil || !reflect.DeepEqual(got, []string{"photos/family"}) {
		t.Fatalf("nested search roots = %#v, err=%v", got, err)
	}
	if s.UserCanReadRoot(userID, rootShareA, "photosX/family/2026.jpg") {
		t.Fatal("path prefix without a separator was treated as an authorized subtree")
	}
	if _, err := s.SearchRootsRoot(reader, "not-a-root", "."); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid root accepted: %v", err)
	}
}

func TestDisablingMemberDeletesLegacyAndRootShareTokens(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetFileGrant(admin, userID, "photos", false); err != nil {
		t.Fatal(err)
	}
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	_, legacyToken, err := s.CreateFileShare(reader, "photos/legacy.jpg", "legacy-fingerprint", 1)
	if err != nil {
		t.Fatal(err)
	}
	_, rootToken, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/root.jpg", "root-fingerprint", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveRootFileShare(legacyToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("v1 token resolved through v2 capability table: %v", err)
	}
	if _, err := s.ResolveFileShare(rootToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("v2 token resolved through legacy capability table: %v", err)
	}
	if err := s.SetEnabled(admin, userID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveFileShare(legacyToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("disabled member's v1 token survived: %v", err)
	}
	if _, err := s.ResolveRootFileShare(rootToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("disabled member's v2 token survived: %v", err)
	}
	if err := s.SetEnabled(admin, userID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveFileShare(legacyToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("v1 token revived after re-enable: %v", err)
	}
	if _, err := s.ResolveRootFileShare(rootToken); !errors.Is(err, ErrNotFound) {
		t.Fatalf("v2 token revived after re-enable: %v", err)
	}
}

func TestRootShareConcurrentCreateAndRevokeSerialization(t *testing.T) {
	s, admin, userID, reader := newRootShareFixture(t)
	if err := s.SetRootGrant(admin, userID, rootShareA, "photos", false); err != nil {
		t.Fatal(err)
	}
	share, token, err := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/photo.jpg", "fingerprint", rootShareExpiry())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	createDone := make(chan resultShare, 1)
	go func() {
		defer wg.Done()
		_, newToken, createErr := s.CreateRootFileShare(context.Background(), reader, rootShareA, 1, "photos/other.jpg", "other", rootShareExpiry())
		createDone <- resultShare{token: newToken, err: createErr}
	}()
	go func() {
		defer wg.Done()
		_ = s.RevokeRootFileShare(context.Background(), reader, rootShareA, share.ID)
	}()
	wg.Wait()
	created := <-createDone
	if created.err != nil && !errors.Is(created.err, ErrForbidden) {
		t.Fatalf("concurrent create failed unexpectedly: %v", created.err)
	}
	if _, err := s.ResolveRootFileShare(token); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked token still resolved after concurrent operations: %v", err)
	}
}

type resultShare struct {
	token string
	err   error
}
