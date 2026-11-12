package auth

import (
	"path/filepath"
	"testing"
)

func TestSessionDeviceMetadataAndSingleDeviceRevoke(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	if err := store.Setup("admin", "StrongPass#2026"); err != nil {
		t.Fatal(err)
	}

	tokIphone, err := store.LoginWithMetadata("admin", "StrongPass#2026", "192.168.1.55", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1")
	if err != nil {
		t.Fatal(err)
	}
	tokMac, err := store.LoginWithMetadata("admin", "StrongPass#2026", "100.88.10.2", "LightIsle/1.0 (macOS; arm64)")
	if err != nil {
		t.Fatal(err)
	}

	sessions, _, err := store.ListSessions(tokMac)
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(sessions))
	}
	if !sessions[0].Current || sessions[0].DeviceLabel != "Mac · 轻屿客户端" || sessions[0].ClientIP != "100.88.10.2" {
		t.Fatalf("unexpected current session metadata: %+v", sessions[0])
	}
	if sessions[1].DeviceLabel != "iPhone · Safari" {
		t.Fatalf("unexpected iPhone session label: %+v", sessions[1])
	}

	isCurrent, err := store.RevokeSession(tokMac, sessions[1].ID)
	if err != nil || isCurrent {
		t.Fatalf("expected non-current session revoke, isCurrent=%v err=%v", isCurrent, err)
	}
	if store.Session(tokIphone) {
		t.Fatal("revoked iPhone session must no longer authenticate")
	}
	if !store.Session(tokMac) {
		t.Fatal("current Mac session must remain active")
	}
}
