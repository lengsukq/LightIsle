package auth

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestCollectLinksIsolationPermissionsAndAtomicCounters(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.Setup("admin", "AdminPass123456!"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := st.Login("admin", "AdminPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	member, err := st.CreateUser(adminTok, "bob", "BobPass12345678!", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberTok, err := st.Login("bob", "BobPass12345678!")
	if err != nil {
		t.Fatal(err)
	}

	const rootID = "0123456789abcdef0123456789abcdef"
	const gen uint64 = 3
	// Grant read-only first: creating a collect link MUST fail.
	if err := st.SetRootGrant(adminTok, member.ID, rootID, "DropBox", false); err != nil {
		t.Fatal(err)
	}
	exp := time.Now().Add(24 * time.Hour).Unix()
	if _, _, err := st.CreateRootCollectLink(context.Background(), memberTok, rootID, gen, "DropBox", "d:1:2", exp, CollectLinkPolicy{Title: "婚礼原图"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("read-only member should be forbidden from creating collect link, got %v", err)
	}

	// Upgrade to write grant: creating succeeds.
	if err := st.SetRootGrant(adminTok, member.ID, rootID, "DropBox", true); err != nil {
		t.Fatal(err)
	}
	link, tok, err := st.CreateRootCollectLink(context.Background(), memberTok, rootID, gen, "DropBox", "d:1:2", exp, CollectLinkPolicy{
		Title:         "婚礼原图收集",
		Password:      "love2026",
		MaxFiles:      3,
		MaxFileBytes:  10 << 20,
		MaxTotalBytes: 25 << 20,
		AllowedExts:   []string{"JPG", ".png"},
	})
	if err != nil {
		t.Fatalf("CreateRootCollectLink: %v", err)
	}
	if !link.HasPassword || len(link.AllowedExts) != 2 || link.AllowedExts[0] != ".jpg" {
		t.Fatalf("unexpected created link: %+v", link)
	}

	// Strict isolation: collect token MUST NEVER resolve as a download share.
	if _, err := st.ResolveRootFileShare(tok); !errors.Is(err, ErrNotFound) {
		t.Fatalf("collect token resolved as download share! err=%v", err)
	}

	// Normal resolve succeeds and password verifies.
	access, err := st.ResolveRootCollectLink(tok)
	if err != nil {
		t.Fatalf("ResolveRootCollectLink: %v", err)
	}
	if !SharePasswordOK(access.PasswordHash, "love2026") || SharePasswordOK(access.PasswordHash, "wrong") {
		t.Fatalf("password verification mismatch")
	}

	// Concurrent ConsumeRootCollectUpload respects MaxFiles=3 atomically.
	var wg sync.WaitGroup
	var mu sync.Mutex
	succeeded := 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := st.ConsumeRootCollectUpload(access.Digest, 5<<20); err == nil {
				mu.Lock()
				succeeded++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if succeeded != 3 {
		t.Fatalf("expected exactly 3 atomic consumes for MaxFiles=3, got %d", succeeded)
	}
	if err := st.ConsumeRootCollectUpload(access.Digest, 1); !errors.Is(err, ErrCollectLimitReached) {
		t.Fatalf("expected ErrCollectLimitReached, got %v", err)
	}

	// Refund restores 1 slot.
	if err := st.RefundRootCollectUpload(access.Digest, 5<<20); err != nil {
		t.Fatal(err)
	}
	if err := st.ConsumeRootCollectUpload(access.Digest, 5<<20); err != nil {
		t.Fatalf("consume after refund failed: %v", err)
	}

	// Downgrading grant back to read-only immediately invalidates resolve!
	if err := st.SetRootGrant(adminTok, member.ID, rootID, "DropBox", false); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ResolveRootCollectLink(tok); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound after write grant removed, got %v", err)
	}

	// Revoke removes link from listing.
	if err := st.RevokeRootCollectLink(context.Background(), memberTok, rootID, link.ID); err != nil {
		t.Fatal(err)
	}
	listed, err := st.ListRootCollectLinks(memberTok, rootID)
	if err != nil || len(listed) != 0 {
		t.Fatalf("expected empty list after revoke, got %+v err=%v", listed, err)
	}
}
