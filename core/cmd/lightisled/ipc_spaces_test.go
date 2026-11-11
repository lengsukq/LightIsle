//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestHandleCreateSpaceUserPartialSuccessRetainsCreatedUser(t *testing.T) {
	base := t.TempDir()
	store, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-2026"); err != nil {
		t.Fatal(err)
	}

	overview, err := handleCreateSpaceUser(context.Background(), store, nil, nil, spacesIPCRequest{
		RequestID:  "req-partial-1",
		Username:   "family_member",
		Password:   "member-password-2026",
		Role:       auth.RoleMember,
		RootID:     "missing-root",
		Generation: 1,
		Categories: []string{"files", "photos"},
	})
	if err == nil {
		t.Fatal("expected allocation error when rootServer is nil")
	}
	if overview == nil || overview.CreatedUser == nil {
		t.Fatalf("expected createdUser in overview on partial failure, got: %+v", overview)
	}
	if overview.CreatedUser.Username != "family_member" {
		t.Fatalf("unexpected createdUser username: %s", overview.CreatedUser.Username)
	}
	found := false
	for _, u := range overview.Users {
		if u.User.ID == overview.CreatedUser.ID && u.User.Username == "family_member" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected newly created user in overview.Users, got: %+v", overview.Users)
	}

	// Verify spacesErrorCode maps root offline / missing errors properly.
	if got := spacesErrorCode(roots.ErrOffline); got != "root_unavailable" {
		t.Fatalf("unexpected error code for offline root: %s", got)
	}
	if got := spacesErrorCode(errors.New("root_services_unavailable")); got != "root_services_unavailable" {
		t.Fatalf("unexpected error code: %s", got)
	}

	// Verify NativeResetMemberPassword and NativeSetUserEnabled lifecycle.
	memberID := overview.CreatedUser.ID
	if err := store.NativeResetMemberPassword(memberID, "updated-password-2026"); err != nil {
		t.Fatalf("NativeResetMemberPassword failed: %v", err)
	}
	if _, err := store.Login("family_member", "updated-password-2026"); err != nil {
		t.Fatalf("expected member login with reset password to succeed: %v", err)
	}
	if err := store.NativeSetUserEnabled(memberID, false); err != nil {
		t.Fatalf("NativeSetUserEnabled(false) failed: %v", err)
	}
	if _, err := store.Login("family_member", "updated-password-2026"); err == nil {
		t.Fatal("expected disabled member login to fail")
	}
	if err := store.NativeSetUserEnabled(1, false); !errors.Is(err, auth.ErrForbidden) {
		t.Fatalf("expected disabling first admin to return ErrForbidden, got: %v", err)
	}
}
