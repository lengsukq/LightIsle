package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	MaxFamilyReminders          = 200
	maxReminderTitleRunes       = 80
	maxReminderNotesRunes       = 300
	maxReminderIntervalDays     = 3650
	maxRemindAdvanceDays        = 365
	maxRemindDaysEntries        = 8
	defaultReminderAdvanceCSV   = "7,1,0"
	reminderSolarDateTimeLayout = "2006-01-02"
)

var (
	allowedReminderCategories = map[string]bool{
		"birthday":    true,
		"anniversary": true,
		"chore":       true,
		"bill":        true,
		"custom":      true,
	}
	allowedReminderRepeatRules = map[string]bool{
		"yearly":        true,
		"monthly":       true,
		"weekly":        true,
		"interval_days": true,
		"once":          true,
	}
)

// FamilyReminder represents a household birthday, anniversary, recurring chore,
// bill, or custom date reminder stored in accounts.sqlite.
type FamilyReminder struct {
	ID              int64  `json:"id"`
	AuthorUserID    int64  `json:"authorUserId"`
	AuthorUsername  string `json:"authorUsername"`
	Title           string `json:"title"`
	Category        string `json:"category"`
	CalendarType    string `json:"calendarType"`
	Year            int    `json:"year"`
	Month           int    `json:"month"`
	Day             int    `json:"day"`
	IsLeapMonth     bool   `json:"isLeapMonth"`
	RepeatRule      string `json:"repeatRule"`
	IntervalDays    int    `json:"intervalDays"`
	NextSolarDate   string `json:"nextSolarDate"`
	DaysUntil       int    `json:"daysUntil"`
	YearsCount      int    `json:"yearsCount,omitempty"`
	LunarLabel      string `json:"lunarLabel,omitempty"`
	RemindDays      []int  `json:"remindDays"`
	RemindDaysCSV   string `json:"remindDaysCsv"`
	NotifyEnabled   bool   `json:"notifyEnabled"`
	Color           string `json:"color"`
	Notes           string `json:"notes"`
	LastNotifiedKey string `json:"-"`
	CreatedAt       int64  `json:"createdAt"`
	UpdatedAt       int64  `json:"updatedAt"`
}

// FamilyReminderInput is the validated payload for creating a reminder.
type FamilyReminderInput struct {
	Title         string `json:"title"`
	Category      string `json:"category"`
	CalendarType  string `json:"calendarType"`
	Year          int    `json:"year"`
	Month         int    `json:"month"`
	Day           int    `json:"day"`
	IsLeapMonth   bool   `json:"isLeapMonth"`
	RepeatRule    string `json:"repeatRule"`
	IntervalDays  int    `json:"intervalDays"`
	NextSolarDate string `json:"nextSolarDate"`
	RemindDays    []int  `json:"remindDays"`
	RemindDaysCSV string `json:"remindDaysCsv"`
	NotifyEnabled *bool  `json:"notifyEnabled"`
	Color         string `json:"color"`
	Notes         string `json:"notes"`
}

// FamilyReminderPatch selectively updates an existing family reminder.
type FamilyReminderPatch struct {
	Title         *string `json:"title"`
	Category      *string `json:"category"`
	CalendarType  *string `json:"calendarType"`
	Year          *int    `json:"year"`
	Month         *int    `json:"month"`
	Day           *int    `json:"day"`
	IsLeapMonth   *bool   `json:"isLeapMonth"`
	RepeatRule    *string `json:"repeatRule"`
	IntervalDays  *int    `json:"intervalDays"`
	NextSolarDate *string `json:"nextSolarDate"`
	RemindDays    *[]int  `json:"remindDays"`
	RemindDaysCSV *string `json:"remindDaysCsv"`
	NotifyEnabled *bool   `json:"notifyEnabled"`
	Color         *string `json:"color"`
	Notes         *string `json:"notes"`
}

// DueFamilyReminder is emitted by ScanDueReminders for daemon notification
// dispatch via notify.Hub. It contains desensitized summary strings only.
type DueFamilyReminder struct {
	ID            int64  `json:"id"`
	Title         string `json:"title"`
	Category      string `json:"category"`
	CalendarType  string `json:"calendarType"`
	NextSolarDate string `json:"nextSolarDate"`
	DaysUntil     int    `json:"daysUntil"`
	YearsCount    int    `json:"yearsCount,omitempty"`
	LunarLabel    string `json:"lunarLabel,omitempty"`
	DedupKey      string `json:"dedupKey"`
	SummaryTitle  string `json:"summaryTitle"`
	SummaryBody   string `json:"summaryBody"`
}

func scanFamilyReminder(scanner interface{ Scan(...any) error }) (FamilyReminder, error) {
	var r FamilyReminder
	var isLeap, notify int
	err := scanner.Scan(
		&r.ID, &r.AuthorUserID, &r.AuthorUsername, &r.Title, &r.Category,
		&r.CalendarType, &r.Year, &r.Month, &r.Day, &isLeap,
		&r.RepeatRule, &r.IntervalDays, &r.NextSolarDate, &r.RemindDaysCSV,
		&notify, &r.Color, &r.Notes, &r.LastNotifiedKey, &r.CreatedAt, &r.UpdatedAt,
	)
	if err != nil {
		return FamilyReminder{}, err
	}
	r.IsLeapMonth = isLeap == 1
	r.NotifyEnabled = notify == 1
	return r, nil
}

const familyReminderColumns = `id, author_user_id, author_username, title, category,
	calendar_type, year, month, day, is_leap_month,
	repeat_rule, interval_days, next_solar_date, remind_days_csv,
	notify_enabled, color, notes, last_notified_key, created_at, updated_at`

func (s *Store) ListFamilyReminders(actorToken string, withinDays int, category string, now time.Time) ([]FamilyReminder, error) {
	if _, ok := s.Identity(actorToken); !ok {
		return nil, ErrForbidden
	}
	if category != "" && !allowedReminderCategories[category] {
		return nil, ErrInput
	}
	if now.IsZero() {
		now = time.Now()
	}
	query := `SELECT ` + familyReminderColumns + ` FROM family_reminders`
	var args []any
	if category != "" {
		query += ` WHERE category=?`
		args = append(args, category)
	}
	query += ` ORDER BY next_solar_date ASC, id ASC LIMIT ?`
	args = append(args, MaxFamilyReminders)

	rows, err := s.readDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]FamilyReminder, 0, 16)
	for rows.Next() {
		r, err := scanFamilyReminder(rows)
		if err != nil {
			return nil, err
		}
		decorateReminder(&r, now)
		if withinDays > 0 && r.DaysUntil > withinDays {
			continue
		}
		list = append(list, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].DaysUntil != list[j].DaysUntil {
			return list[i].DaysUntil < list[j].DaysUntil
		}
		return list[i].ID < list[j].ID
	})
	return list, nil
}

func (s *Store) CreateFamilyReminder(actorToken string, in FamilyReminderInput, now time.Time) (FamilyReminder, error) {
	actor, ok := s.Identity(actorToken)
	if !ok {
		return FamilyReminder{}, ErrForbidden
	}
	if now.IsZero() {
		now = time.Now()
	}
	notifyEnabled := true
	if in.NotifyEnabled != nil {
		notifyEnabled = *in.NotifyEnabled
	}
	r := FamilyReminder{
		AuthorUserID:   actor.ID,
		AuthorUsername: actor.Username,
		Title:          in.Title,
		Category:       in.Category,
		CalendarType:   in.CalendarType,
		Year:           in.Year,
		Month:          in.Month,
		Day:            in.Day,
		IsLeapMonth:    in.IsLeapMonth,
		RepeatRule:     in.RepeatRule,
		IntervalDays:   in.IntervalDays,
		RemindDays:     in.RemindDays,
		RemindDaysCSV:  in.RemindDaysCSV,
		NotifyEnabled:  notifyEnabled,
		Color:          in.Color,
		Notes:          in.Notes,
	}
	if err := normalizeReminderRecord(&r, in.NextSolarDate, now); err != nil {
		return FamilyReminder{}, err
	}

	tx, err := s.db.Begin()
	if err != nil {
		return FamilyReminder{}, err
	}
	defer tx.Rollback()

	var count int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM family_reminders`).Scan(&count); err != nil {
		return FamilyReminder{}, err
	}
	if count >= MaxFamilyReminders {
		return FamilyReminder{}, ErrExists
	}
	ts := now.Unix()
	leapInt := boolToInt(r.IsLeapMonth)
	notifyInt := boolToInt(r.NotifyEnabled)
	res, err := tx.Exec(`
		INSERT INTO family_reminders
			(author_user_id, author_username, title, category, calendar_type,
			 year, month, day, is_leap_month, repeat_rule, interval_days,
			 next_solar_date, remind_days_csv, notify_enabled, color, notes,
			 last_notified_key, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?)`,
		r.AuthorUserID, r.AuthorUsername, r.Title, r.Category, r.CalendarType,
		r.Year, r.Month, r.Day, leapInt, r.RepeatRule, r.IntervalDays,
		r.NextSolarDate, r.RemindDaysCSV, notifyInt, r.Color, r.Notes, ts, ts)
	if err != nil {
		return FamilyReminder{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return FamilyReminder{}, err
	}
	if err := tx.Commit(); err != nil {
		return FamilyReminder{}, err
	}
	r.ID = id
	r.CreatedAt = ts
	r.UpdatedAt = ts
	decorateReminder(&r, now)
	return r, nil
}

func (s *Store) UpdateFamilyReminder(actorToken string, id int64, patch FamilyReminderPatch, now time.Time) (FamilyReminder, error) {
	actor, ok := s.Identity(actorToken)
	if !ok {
		return FamilyReminder{}, ErrForbidden
	}
	if id <= 0 {
		return FamilyReminder{}, ErrInput
	}
	if now.IsZero() {
		now = time.Now()
	}

	tx, err := s.db.Begin()
	if err != nil {
		return FamilyReminder{}, err
	}
	defer tx.Rollback()

	cur, err := scanFamilyReminder(tx.QueryRow(`SELECT `+familyReminderColumns+` FROM family_reminders WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return FamilyReminder{}, ErrNotFound
	}
	if err != nil {
		return FamilyReminder{}, err
	}
	if actor.Role != RoleAdmin && cur.AuthorUserID != actor.ID {
		return FamilyReminder{}, ErrForbidden
	}

	dateChanged := false
	if patch.Title != nil {
		cur.Title = *patch.Title
	}
	if patch.Category != nil {
		cur.Category = *patch.Category
	}
	if patch.CalendarType != nil {
		cur.CalendarType = *patch.CalendarType
		dateChanged = true
	}
	if patch.Year != nil {
		cur.Year = *patch.Year
		dateChanged = true
	}
	if patch.Month != nil {
		cur.Month = *patch.Month
		dateChanged = true
	}
	if patch.Day != nil {
		cur.Day = *patch.Day
		dateChanged = true
	}
	if patch.IsLeapMonth != nil {
		cur.IsLeapMonth = *patch.IsLeapMonth
		dateChanged = true
	}
	if patch.RepeatRule != nil {
		cur.RepeatRule = *patch.RepeatRule
		dateChanged = true
	}
	if patch.IntervalDays != nil {
		cur.IntervalDays = *patch.IntervalDays
		dateChanged = true
	}
	if patch.RemindDays != nil {
		cur.RemindDays = *patch.RemindDays
		cur.RemindDaysCSV = ""
	}
	if patch.RemindDaysCSV != nil {
		cur.RemindDays = nil
		cur.RemindDaysCSV = *patch.RemindDaysCSV
	}
	if patch.NotifyEnabled != nil {
		cur.NotifyEnabled = *patch.NotifyEnabled
	}
	if patch.Color != nil {
		cur.Color = *patch.Color
	}
	if patch.Notes != nil {
		cur.Notes = *patch.Notes
	}

	explicitNext := cur.NextSolarDate
	if patch.NextSolarDate != nil {
		explicitNext = *patch.NextSolarDate
		dateChanged = true
	} else if dateChanged {
		explicitNext = ""
	}
	if err := normalizeReminderRecord(&cur, explicitNext, now); err != nil {
		return FamilyReminder{}, err
	}
	if dateChanged {
		cur.LastNotifiedKey = ""
	}
	cur.UpdatedAt = now.Unix()

	if _, err := tx.Exec(`
		UPDATE family_reminders
		SET title=?, category=?, calendar_type=?, year=?, month=?, day=?, is_leap_month=?,
		    repeat_rule=?, interval_days=?, next_solar_date=?, remind_days_csv=?,
		    notify_enabled=?, color=?, notes=?, last_notified_key=?, updated_at=?
		WHERE id=?`,
		cur.Title, cur.Category, cur.CalendarType, cur.Year, cur.Month, cur.Day, boolToInt(cur.IsLeapMonth),
		cur.RepeatRule, cur.IntervalDays, cur.NextSolarDate, cur.RemindDaysCSV,
		boolToInt(cur.NotifyEnabled), cur.Color, cur.Notes, cur.LastNotifiedKey, cur.UpdatedAt, id); err != nil {
		return FamilyReminder{}, err
	}
	if err := tx.Commit(); err != nil {
		return FamilyReminder{}, err
	}
	decorateReminder(&cur, now)
	return cur, nil
}

func (s *Store) DeleteFamilyReminder(actorToken string, id int64) error {
	actor, ok := s.Identity(actorToken)
	if !ok {
		return ErrForbidden
	}
	if id <= 0 {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var authorID int64
	err = tx.QueryRow(`SELECT author_user_id FROM family_reminders WHERE id=?`, id).Scan(&authorID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if actor.Role != RoleAdmin && authorID != actor.ID {
		return ErrForbidden
	}
	if _, err := tx.Exec(`DELETE FROM family_reminders WHERE id=?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// CompleteFamilyReminder checks off a reminder/chore and advances next_solar_date
// to the next cycle (or disables notifications for a one-time reminder). Any
// signed-in household member can check off a family task.
func (s *Store) CompleteFamilyReminder(actorToken string, id int64, now time.Time) (FamilyReminder, error) {
	if _, ok := s.Identity(actorToken); !ok {
		return FamilyReminder{}, ErrForbidden
	}
	if id <= 0 {
		return FamilyReminder{}, ErrInput
	}
	if now.IsZero() {
		now = time.Now()
	}
	tx, err := s.db.Begin()
	if err != nil {
		return FamilyReminder{}, err
	}
	defer tx.Rollback()

	cur, err := scanFamilyReminder(tx.QueryRow(`SELECT `+familyReminderColumns+` FROM family_reminders WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return FamilyReminder{}, ErrNotFound
	}
	if err != nil {
		return FamilyReminder{}, err
	}
	nextSolar, disableNotify, err := advanceReminderCycle(cur, now)
	if err != nil {
		return FamilyReminder{}, err
	}
	cur.NextSolarDate = nextSolar
	if disableNotify {
		cur.NotifyEnabled = false
	}
	cur.LastNotifiedKey = ""
	cur.UpdatedAt = now.Unix()

	if _, err := tx.Exec(`
		UPDATE family_reminders
		SET next_solar_date=?, notify_enabled=?, last_notified_key=?, updated_at=?
		WHERE id=?`,
		cur.NextSolarDate, boolToInt(cur.NotifyEnabled), cur.LastNotifiedKey, cur.UpdatedAt, id); err != nil {
		return FamilyReminder{}, err
	}
	if err := tx.Commit(); err != nil {
		return FamilyReminder{}, err
	}
	decorateReminder(&cur, now)
	return cur, nil
}

// ScanDueReminders finds enabled reminders whose current countdown matches an
// advance-notice day in remind_days_csv, atomically records their dedup key so
// repeated daemon ticks never resend the same alert, and returns desensitized
// notification payloads ready for notify.Hub.
func (s *Store) ScanDueReminders(now time.Time) ([]DueFamilyReminder, error) {
	if now.IsZero() {
		now = time.Now()
	}
	today := dateOnlyUTC(now)
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	rows, err := tx.Query(`SELECT ` + familyReminderColumns + ` FROM family_reminders WHERE notify_enabled=1 ORDER BY next_solar_date ASC, id ASC`)
	if err != nil {
		return nil, err
	}
	var all []FamilyReminder
	for rows.Next() {
		r, scanErr := scanFamilyReminder(rows)
		if scanErr != nil {
			_ = rows.Close()
			return nil, scanErr
		}
		all = append(all, r)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, err
	}
	_ = rows.Close()

	due := make([]DueFamilyReminder, 0)
	for _, r := range all {
		origNext := r.NextSolarDate
		decorateReminder(&r, today)
		if r.NextSolarDate != origNext {
			if _, err := tx.Exec(`UPDATE family_reminders SET next_solar_date=?, updated_at=? WHERE id=?`,
				r.NextSolarDate, now.Unix(), r.ID); err != nil {
				return nil, err
			}
		}
		matched := false
		for _, d := range r.RemindDays {
			if d == r.DaysUntil {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		dedupKey := fmt.Sprintf("%s:%d", r.NextSolarDate, r.DaysUntil)
		if r.LastNotifiedKey == dedupKey {
			continue
		}
		res, err := tx.Exec(`UPDATE family_reminders SET last_notified_key=? WHERE id=? AND last_notified_key<>?`,
			dedupKey, r.ID, dedupKey)
		if err != nil {
			return nil, err
		}
		affected, _ := res.RowsAffected()
		if affected != 1 {
			continue
		}
		due = append(due, buildDueFamilyReminder(r, dedupKey))
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return due, nil
}

func buildDueFamilyReminder(r FamilyReminder, dedupKey string) DueFamilyReminder {
	var whenLabel string
	switch r.DaysUntil {
	case 0:
		whenLabel = "就是今天"
	case 1:
		whenLabel = "就在明天"
	default:
		whenLabel = fmt.Sprintf("还有 %d 天", r.DaysUntil)
	}
	summaryTitle := fmt.Sprintf("家庭提醒：%s（%s）", r.Title, whenLabel)
	bodyParts := []string{fmt.Sprintf("公历日期：%s", r.NextSolarDate)}
	if r.LunarLabel != "" {
		bodyParts = append(bodyParts, r.LunarLabel)
	}
	if r.YearsCount > 0 {
		switch r.Category {
		case "birthday":
			bodyParts = append(bodyParts, fmt.Sprintf("第 %d 岁生日", r.YearsCount))
		case "anniversary":
			bodyParts = append(bodyParts, fmt.Sprintf("第 %d 周年", r.YearsCount))
		}
	}
	return DueFamilyReminder{
		ID:            r.ID,
		Title:         r.Title,
		Category:      r.Category,
		CalendarType:  r.CalendarType,
		NextSolarDate: r.NextSolarDate,
		DaysUntil:     r.DaysUntil,
		YearsCount:    r.YearsCount,
		LunarLabel:    r.LunarLabel,
		DedupKey:      dedupKey,
		SummaryTitle:  summaryTitle,
		SummaryBody:   strings.Join(bodyParts, " · "),
	}
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
