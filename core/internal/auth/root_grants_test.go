package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestRootGrantsNeverInheritLegacyPermissions(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = db.Setup("owner", "owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := db.Login("owner", "owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	user, err := db.CreateUser(admin, "member", "member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, err := db.Login("member", "member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	a, b := "11111111111111111111111111111111", "22222222222222222222222222222222"
	if err := db.SetFileGrant(admin, user.ID, ".", true); err != nil {
		t.Fatal(err)
	}
	if db.CanAccessRoot(session, a, ".", false, false) || db.CanAccessRoot(session, b, "album", false, false) {
		t.Fatal("root-scoped permissions inherited legacy wildcard grant")
	}
	if err := db.SetRootGrant(admin, user.ID, a, "photos", false); err != nil {
		t.Fatal(err)
	}
	if !db.CanAccessRoot(session, a, "photos/item.jpg", false, false) {
		t.Fatal("root a denied")
	}
	if db.CanAccessRoot(session, a, "photos/item.jpg", true, false) {
		t.Fatal("read-only allowed writes")
	}
	if db.CanAccessRoot(session, b, "photos/item.jpg", false, false) {
		t.Fatal("root b inherited root a")
	}
	if !db.CanAccessRoot(session, a, ".", false, true) || db.CanAccessRoot(session, a, ".", false, false) {
		t.Fatal("ancestor traversal check incorrect")
	}
	if err := db.SetRootGrant(admin, user.ID, b, "photos", true); err != nil {
		t.Fatal(err)
	}
	if !db.CanAccessRoot(session, b, "photos/item.jpg", true, false) {
		t.Fatal("write root b denied")
	}
	hintsA, err := db.WritableRootPaths(session, a, []string{"photos/item.jpg", "outside/item.jpg"})
	if err != nil || hintsA["photos/item.jpg"] || hintsA["outside/item.jpg"] {
		t.Fatalf("root A write hints inherited legacy or root B grants: %#v %v", hintsA, err)
	}
	hintsB, err := db.WritableRootPaths(session, b, []string{"photos/item.jpg", "outside/item.jpg"})
	if err != nil || !hintsB["photos/item.jpg"] || hintsB["outside/item.jpg"] {
		t.Fatalf("root B write hints crossed grant subtree: %#v %v", hintsB, err)
	}
	if err := db.RemoveRootGrant(admin, user.ID, b, "photos"); err != nil {
		t.Fatal(err)
	}
	if db.CanAccessRoot(session, b, "photos/item.jpg", false, false) {
		t.Fatal("revoked root still accessible")
	}
	valid, err := db.UserCanWriteRoot(user.ID, b, "photos/item.jpg")
	if err != nil || valid {
		t.Fatalf("revocation failed: %v %v", valid, err)
	}
	grants, err := db.RootGrants(admin, user.ID, a)
	if err != nil || len(grants) != 1 || grants[0].CanWrite {
		t.Fatalf("grant list: %v %v", grants, err)
	}
	if err := db.SetRootGrant(session, user.ID, a, ".", true); err != ErrForbidden {
		t.Fatal("member modified ACL")
	}
	if db.CanAccessRoot(session, "not-a-root", "photos", false, false) {
		t.Fatal("bad root ID accepted")
	}
	if db.CanAccessRoot(session, a, "../escape", false, false) {
		t.Fatal("bad rel path accepted")
	}
}

func TestUserCanWriteRootRejectsSiblingPersonalHomesEvenWithBroadGrant(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "member", "member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	root := "11111111111111111111111111111111"
	if err := store.SetRootGrant(admin, member.ID, root, ".", true); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"Users", "users", "Users/u999/files/foreign.txt", "uSeRs/U999/files/foreign.txt"} {
		if ok, err := store.UserCanWriteRoot(member.ID, root, path); err != nil || ok {
			t.Fatalf("member wrote sibling personal namespace %q: ok=%v err=%v", path, ok, err)
		}
	}
	self := "Users/u" + fmt.Sprint(member.ID) + "/files/own.txt"
	if ok, err := store.UserCanWriteRoot(member.ID, root, self); err != nil || !ok {
		t.Fatalf("member's own path rejected: ok=%v err=%v", ok, err)
	}
	if store.UserCanReadRoot(member.ID, root, "users/U999/files/secret.txt") {
		t.Fatal("user ID read helper exposed sibling private directory")
	}
	if session, err := store.Login("member", "member-password-2026"); err != nil {
		t.Fatal(err)
	} else if store.CanAccessRoot(session, root, "USERS/U999/files/secret.txt", false, false) {
		t.Fatal("root session inherited a case-variant sibling path")
	}
}

func TestSetRootGrantRejectsMemberDisabledAfterEarlyAuthorization(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = db.Setup("owner", "owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := db.Login("owner", "owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := db.CreateUser(admin, "member", "member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	checked, resume := make(chan struct{}), make(chan struct{})
	db.afterRootGrantAuthorization = func() { close(checked); <-resume }
	result := make(chan error, 1)
	go func() { result <- db.SetRootGrant(admin, member.ID, rootShareA, "photos", false) }()
	<-checked
	if err := db.SetEnabled(admin, member.ID, false); err != nil {
		close(resume)
		t.Fatal(err)
	}
	close(resume)
	if err := <-result; !errors.Is(err, ErrForbidden) {
		t.Fatalf("grant published after target member was disabled: %v", err)
	}
	var count int
	if err := db.db.QueryRow("SELECT COUNT(*) FROM root_file_grants WHERE user_id=? AND root_id=?", member.ID, rootShareA).Scan(&count); err != nil || count != 0 {
		t.Fatalf("unauthorized root grant persisted: count=%d err=%v", count, err)
	}
}
