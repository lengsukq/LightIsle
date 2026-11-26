package auth

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func openReminderTestStore(t *testing.T) (*Store, string, string) {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.Setup("admin", "AdminPass123456!"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := st.Login("admin", "AdminPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateUser(adminTok, "alice", "AlicePass123456!", RoleMember); err != nil {
		t.Fatal(err)
	}
	memberTok, err := st.Login("alice", "AlicePass123456!")
	if err != nil {
		t.Fatal(err)
	}
	return st, adminTok, memberTok
}

func TestFamilyRemindersCRUDPermissionsCompleteAndScan(t *testing.T) {
	st, adminTok, memberTok := openReminderTestStore(t)
	now := time.Date(2025, 7, 18, 9, 0, 0, 0, time.UTC)

	// 1. Lunar leap-month birthday (2025 闰六月初一 -> 2025-07-25, 7 days away).
	bday, err := st.CreateFamilyReminder(adminTok, FamilyReminderInput{
		Title:        "妈妈农历生日",
		Category:     "birthday",
		CalendarType: "lunar",
		Year:         1965,
		Month:        6,
		Day:          1,
		IsLeapMonth:  false,
		RepeatRule:   "yearly",
		RemindDays:   []int{7, 1, 0},
		Color:        "rose",
	}, now)
	if err != nil {
		t.Fatalf("create lunar birthday: %v", err)
	}
	// 2025 regular 6th month day 1 was 2025-06-25 (already passed on 2025-07-18),
	// so next solar occurrence must be in lunar 2026 (2026-07-14), age 2026-1965=61.
	if bday.YearsCount != 61 || bday.NextSolarDate != "2026-07-14" {
		t.Fatalf("unexpected regular lunar birthday: %+v", bday)
	}

	// Leap 6th month birthday on 2025-07-18 -> 2025-07-25 (7 days away!).
	leapBday, err := st.CreateFamilyReminder(adminTok, FamilyReminderInput{
		Title:        "闰六月生日",
		Category:     "birthday",
		CalendarType: "lunar",
		Year:         1987, // 1987 had leap 6th month
		Month:        6,
		Day:          1,
		IsLeapMonth:  true,
		RepeatRule:   "yearly",
		RemindDays:   []int{7, 1, 0},
	}, now)
	if err != nil {
		t.Fatalf("create leap lunar birthday: %v", err)
	}
	if leapBday.NextSolarDate != "2025-07-25" || leapBday.DaysUntil != 7 || leapBday.YearsCount != 38 {
		t.Fatalf("unexpected leap birthday: %+v", leapBday)
	}

	// 2. Member creates an interval chore due today (2025-07-18), interval 90 days.
	chore, err := st.CreateFamilyReminder(memberTok, FamilyReminderInput{
		Title:        "更换净水器滤芯",
		Category:     "chore",
		CalendarType: "solar",
		Year:         2025,
		Month:        7,
		Day:          18,
		RepeatRule:   "interval_days",
		IntervalDays: 90,
		RemindDays:   []int{3, 0},
		Color:        "sage",
	}, now)
	if err != nil {
		t.Fatalf("create chore: %v", err)
	}
	if chore.NextSolarDate != "2025-07-18" || chore.DaysUntil != 0 {
		t.Fatalf("unexpected chore: %+v", chore)
	}

	// 3. Member cannot edit or delete admin's reminder, but can edit own.
	newTitle := "篡改标题"
	if _, err := st.UpdateFamilyReminder(memberTok, leapBday.ID, FamilyReminderPatch{Title: &newTitle}, now); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member should not edit admin reminder, got %v", err)
	}
	if err := st.DeleteFamilyReminder(memberTok, leapBday.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member should not delete admin reminder, got %v", err)
	}
	updatedChoreTitle := "换RO滤芯"
	updated, err := st.UpdateFamilyReminder(memberTok, chore.ID, FamilyReminderPatch{Title: &updatedChoreTitle}, now)
	if err != nil || updated.Title != updatedChoreTitle {
		t.Fatalf("member edit own reminder failed: %+v, err=%v", updated, err)
	}

	// 4. ScanDueReminders on 2025-07-18 should fire BOTH leapBday (daysUntil=7) and chore (daysUntil=0).
	due1, err := st.ScanDueReminders(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(due1) != 2 {
		t.Fatalf("expected 2 due reminders, got %d: %+v", len(due1), due1)
	}
	// Calling again on the same day must deduplicate completely!
	due2, err := st.ScanDueReminders(now.Add(2 * time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(due2) != 0 {
		t.Fatalf("expected 0 duplicate reminders on same day, got %d", len(due2))
	}

	// Next advance window (1 day before leapBday = 2025-07-24) should fire again.
	due3, err := st.ScanDueReminders(time.Date(2025, 7, 24, 8, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if len(due3) != 1 || due3[0].ID != leapBday.ID || due3[0].DaysUntil != 1 {
		t.Fatalf("expected leapBday 1-day reminder, got %+v", due3)
	}

	// 5. Complete chore -> advances by +90 days from 2025-07-18 to 2025-10-16.
	doneChore, err := st.CompleteFamilyReminder(adminTok, chore.ID, now)
	if err != nil {
		t.Fatalf("complete chore: %v", err)
	}
	if doneChore.NextSolarDate != "2025-10-16" || doneChore.DaysUntil != 90 {
		t.Fatalf("completed chore = %+v, want 2025-10-16 (90 days)", doneChore)
	}

	// 6. List filtered within 14 days should include leapBday (7d) only, not chore (90d) or bday (361d).
	soon, err := st.ListFamilyReminders(memberTok, 14, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if len(soon) != 1 || soon[0].ID != leapBday.ID {
		t.Fatalf("withinDays=14 = %+v, want only leapBday", soon)
	}

	// 7. Admin can delete member's reminder.
	if err := st.DeleteFamilyReminder(adminTok, chore.ID); err != nil {
		t.Fatalf("admin delete member reminder: %v", err)
	}
}
