package auth

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestFamilyBoardOrderingAndPermissions(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "auth.sqlite"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()

	if err := store.Setup("admin_owner", "admin-password-12345"); err != nil {
		t.Fatalf("setup admin: %v", err)
	}
	adminTok, err := store.Login("admin_owner", "admin-password-12345")
	if err != nil {
		t.Fatalf("admin login: %v", err)
	}
	if _, err := store.CreateUser(adminTok, "family_alice", "alice-password-12345", RoleMember); err != nil {
		t.Fatalf("create alice: %v", err)
	}
	if _, err := store.CreateUser(adminTok, "family_bob", "bob-password-12345", RoleMember); err != nil {
		t.Fatalf("create bob: %v", err)
	}
	aliceTok, err := store.Login("family_alice", "alice-password-12345")
	if err != nil {
		t.Fatalf("alice login: %v", err)
	}
	bobTok, err := store.Login("family_bob", "bob-password-12345")
	if err != nil {
		t.Fatalf("bob login: %v", err)
	}

	// Empty list works for signed-in member.
	initial, err := store.ListFamilyBoardMessages(aliceTok, 20)
	if err != nil {
		t.Fatalf("list empty: %v", err)
	}
	if len(initial) != 0 {
		t.Fatalf("expected 0 messages, got %d", len(initial))
	}

	// Input validation.
	if _, err := store.CreateFamilyBoardMessage(aliceTok, "   ", "留言", "amber"); !errors.Is(err, ErrInput) {
		t.Fatalf("expected ErrInput for blank content, got %v", err)
	}
	if _, err := store.CreateFamilyBoardMessage(aliceTok, strings.Repeat("字", 501), "留言", "amber"); !errors.Is(err, ErrInput) {
		t.Fatalf("expected ErrInput for >500 runes, got %v", err)
	}
	if _, err := store.CreateFamilyBoardMessage(aliceTok, "hello", "非法标签", "amber"); !errors.Is(err, ErrInput) {
		t.Fatalf("expected ErrInput for invalid tag, got %v", err)
	}
	if _, err := store.CreateFamilyBoardMessage(aliceTok, "hello", "留言", "neon"); !errors.Is(err, ErrInput) {
		t.Fatalf("expected ErrInput for invalid color, got %v", err)
	}

	// Members and admin can post freely.
	m1, err := store.CreateFamilyBoardMessage(aliceTok, "晚上想吃番茄炒蛋", "心愿", "rose")
	if err != nil {
		t.Fatalf("alice post: %v", err)
	}
	m2, err := store.CreateFamilyBoardMessage(bobTok, "下班顺路买两盒牛奶", "采购", "sage")
	if err != nil {
		t.Fatalf("bob post: %v", err)
	}
	m3, err := store.CreateFamilyBoardMessage(adminTok, "周六下午全家去公园野餐", "提醒", "blue")
	if err != nil {
		t.Fatalf("admin post: %v", err)
	}

	// Default order is reverse chronological (newest first: m3, m2, m1).
	list, err := store.ListFamilyBoardMessages(aliceTok, 20)
	if err != nil {
		t.Fatalf("list after posts: %v", err)
	}
	if len(list) != 3 || list[0].ID != m3.ID || list[1].ID != m2.ID || list[2].ID != m1.ID {
		t.Fatalf("unexpected reverse order: %+v", list)
	}

	// Ordinary member cannot pin a message.
	if _, err := store.SetFamilyBoardMessagePinned(aliceTok, m1.ID, true); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ErrForbidden when member pins, got %v", err)
	}

	// Admin pins m1 -> m1 moves to top, followed by m3, m2.
	pinned, err := store.SetFamilyBoardMessagePinned(adminTok, m1.ID, true)
	if err != nil {
		t.Fatalf("admin pin: %v", err)
	}
	if !pinned.Pinned || pinned.PinnedBy != "admin_owner" || pinned.PinnedAt <= 0 {
		t.Fatalf("unexpected pinned message: %+v", pinned)
	}
	list, err = store.ListFamilyBoardMessages(bobTok, 20)
	if err != nil {
		t.Fatalf("list after pin: %v", err)
	}
	if len(list) != 3 || list[0].ID != m1.ID || list[1].ID != m3.ID || list[2].ID != m2.ID {
		t.Fatalf("unexpected pinned order: %+v", list)
	}

	// Admin unpins m1 -> order returns to m3, m2, m1.
	unpinned, err := store.SetFamilyBoardMessagePinned(adminTok, m1.ID, false)
	if err != nil {
		t.Fatalf("admin unpin: %v", err)
	}
	if unpinned.Pinned || unpinned.PinnedBy != "" || unpinned.PinnedAt != 0 {
		t.Fatalf("unexpected unpinned message: %+v", unpinned)
	}
	list, err = store.ListFamilyBoardMessages(bobTok, 20)
	if err != nil {
		t.Fatalf("list after unpin: %v", err)
	}
	if len(list) != 3 || list[0].ID != m3.ID || list[1].ID != m2.ID || list[2].ID != m1.ID {
		t.Fatalf("unexpected unpinned order: %+v", list)
	}

	// Member cannot delete another member's message.
	if err := store.DeleteFamilyBoardMessage(aliceTok, m2.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ErrForbidden when alice deletes bob's message, got %v", err)
	}

	// Member can delete their own message.
	if err := store.DeleteFamilyBoardMessage(aliceTok, m1.ID); err != nil {
		t.Fatalf("alice delete own message: %v", err)
	}

	// Admin can delete any member's message.
	if err := store.DeleteFamilyBoardMessage(adminTok, m2.ID); err != nil {
		t.Fatalf("admin delete bob's message: %v", err)
	}

	list, err = store.ListFamilyBoardMessages(adminTok, 20)
	if err != nil {
		t.Fatalf("list after deletes: %v", err)
	}
	if len(list) != 1 || list[0].ID != m3.ID {
		t.Fatalf("expected only m3 remaining, got %+v", list)
	}
}
