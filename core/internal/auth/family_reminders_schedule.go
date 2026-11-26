package auth

import (
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func normalizeRemindDays(days []int, csv string) ([]int, string, error) {
	var raw []int
	if days != nil {
		if len(days) == 0 {
			return nil, "", ErrInput
		}
		raw = append(raw, days...)
	} else if trimmed := strings.TrimSpace(csv); trimmed != "" {
		parts := strings.Split(trimmed, ",")
		if len(parts) > maxRemindDaysEntries {
			return nil, "", ErrInput
		}
		for _, p := range parts {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			v, err := strconv.Atoi(p)
			if err != nil {
				return nil, "", ErrInput
			}
			raw = append(raw, v)
		}
	} else {
		raw = []int{7, 1, 0}
	}
	if len(raw) == 0 || len(raw) > maxRemindDaysEntries {
		return nil, "", ErrInput
	}
	seen := make(map[int]bool, len(raw))
	clean := make([]int, 0, len(raw))
	for _, v := range raw {
		if v < 0 || v > maxRemindAdvanceDays {
			return nil, "", ErrInput
		}
		if seen[v] {
			continue
		}
		seen[v] = true
		clean = append(clean, v)
	}
	sort.Slice(clean, func(i, j int) bool { return clean[i] > clean[j] })
	strs := make([]string, len(clean))
	for i, v := range clean {
		strs[i] = strconv.Itoa(v)
	}
	return clean, strings.Join(strs, ","), nil
}

func parseRemindDaysCSV(csv string) []int {
	days, _, err := normalizeRemindDays(nil, csv)
	if err != nil {
		return []int{7, 1, 0}
	}
	return days
}

func normalizeReminderRecord(r *FamilyReminder, explicitNextSolar string, now time.Time) error {
	r.Title = strings.TrimSpace(r.Title)
	titleRunes := utf8.RuneCountInString(r.Title)
	if titleRunes < 1 || titleRunes > maxReminderTitleRunes || strings.ContainsRune(r.Title, 0) {
		return ErrInput
	}
	r.Category = strings.ToLower(strings.TrimSpace(r.Category))
	if r.Category == "" {
		r.Category = "custom"
	}
	if !allowedReminderCategories[r.Category] {
		return ErrInput
	}
	r.CalendarType = strings.ToLower(strings.TrimSpace(r.CalendarType))
	if r.CalendarType == "" {
		r.CalendarType = "solar"
	}
	if r.CalendarType != "solar" && r.CalendarType != "lunar" {
		return ErrInput
	}
	r.RepeatRule = strings.ToLower(strings.TrimSpace(r.RepeatRule))
	if r.RepeatRule == "" {
		r.RepeatRule = "yearly"
	}
	if !allowedReminderRepeatRules[r.RepeatRule] {
		return ErrInput
	}
	if r.CalendarType == "lunar" && r.RepeatRule != "yearly" && r.RepeatRule != "once" {
		return ErrInput
	}
	if r.RepeatRule == "interval_days" {
		if r.IntervalDays < 1 || r.IntervalDays > maxReminderIntervalDays {
			return ErrInput
		}
	} else {
		r.IntervalDays = 0
	}
	if r.Year != 0 && (r.Year < LunarMinYear || r.Year > LunarMaxYear) {
		return ErrInput
	}
	if r.Month < 1 || r.Month > 12 {
		return ErrInput
	}
	if r.CalendarType == "lunar" {
		if r.Day < 1 || r.Day > 30 {
			return ErrInput
		}
		if r.Year > 0 && r.IsLeapMonth && LunarLeapMonth(r.Year) != r.Month {
			return ErrInput
		}
		if r.Year > 0 && r.RepeatRule == "once" {
			if _, err := LunarToSolar(r.Year, r.Month, r.Day, r.IsLeapMonth); err != nil {
				return ErrInput
			}
		}
	} else {
		r.IsLeapMonth = false
		maxDay := 31
		if r.Year > 0 {
			maxDay = solarDaysInMonth(r.Year, r.Month)
		} else {
			maxDay = solarDaysInMonth(2024, r.Month) // allow Feb 29 when year omitted
		}
		if r.Day < 1 || r.Day > maxDay {
			return ErrInput
		}
	}
	r.Color = strings.ToLower(strings.TrimSpace(r.Color))
	if r.Color == "" {
		r.Color = "amber"
	}
	if !allowedBoardColors[r.Color] {
		return ErrInput
	}
	r.Notes = strings.TrimSpace(r.Notes)
	if utf8.RuneCountInString(r.Notes) > maxReminderNotesRunes || strings.ContainsRune(r.Notes, 0) {
		return ErrInput
	}
	days, csv, err := normalizeRemindDays(r.RemindDays, r.RemindDaysCSV)
	if err != nil {
		return ErrInput
	}
	r.RemindDays = days
	r.RemindDaysCSV = csv

	if explicit := strings.TrimSpace(explicitNextSolar); explicit != "" {
		parsed, err := time.Parse(reminderSolarDateTimeLayout, explicit)
		if err != nil {
			return ErrInput
		}
		r.NextSolarDate = parsed.Format(reminderSolarDateTimeLayout)
		return nil
	}
	nextDate, err := initialNextSolarDate(*r, now)
	if err != nil {
		return ErrInput
	}
	r.NextSolarDate = nextDate.Format(reminderSolarDateTimeLayout)
	return nil
}

func initialNextSolarDate(r FamilyReminder, now time.Time) (time.Time, error) {
	today := dateOnlyUTC(now)
	switch r.RepeatRule {
	case "yearly":
		if r.CalendarType == "lunar" {
			solar, _, _, err := NextLunarOccurrence(r.Month, r.Day, r.IsLeapMonth, today)
			return solar, err
		}
		solar, _, err := NextSolarYearlyOccurrence(r.Month, r.Day, today)
		return solar, err
	case "once":
		if r.CalendarType == "lunar" {
			if r.Year == 0 {
				solar, _, _, err := NextLunarOccurrence(r.Month, r.Day, r.IsLeapMonth, today)
				return solar, err
			}
			solar, _, err := LunarDateInYear(r.Year, r.Month, r.Day, r.IsLeapMonth)
			return solar, err
		}
		if r.Year == 0 {
			solar, _, err := NextSolarYearlyOccurrence(r.Month, r.Day, today)
			return solar, err
		}
		return solarClampedDate(r.Year, r.Month, r.Day), nil
	case "monthly":
		if r.Year > 0 {
			cand := solarClampedDate(r.Year, r.Month, r.Day)
			if !cand.Before(today) {
				return cand, nil
			}
		}
		cand := solarClampedDate(today.Year(), int(today.Month()), r.Day)
		if cand.Before(today) {
			nextMonth := time.Date(today.Year(), today.Month()+1, 1, 0, 0, 0, 0, time.UTC)
			cand = solarClampedDate(nextMonth.Year(), int(nextMonth.Month()), r.Day)
		}
		return cand, nil
	case "weekly", "interval_days":
		if r.Year > 0 {
			return solarClampedDate(r.Year, r.Month, r.Day), nil
		}
		cand := solarClampedDate(today.Year(), r.Month, r.Day)
		if cand.Before(today) {
			step := 7
			if r.RepeatRule == "interval_days" && r.IntervalDays > 0 {
				step = r.IntervalDays
			}
			daysBehind := int(today.Sub(cand).Hours() / 24)
			cycles := (daysBehind + step - 1) / step
			cand = cand.AddDate(0, 0, cycles*step)
		}
		return cand, nil
	default:
		return time.Time{}, ErrInput
	}
}

func advanceReminderCycle(r FamilyReminder, now time.Time) (nextSolar string, disableNotify bool, err error) {
	today := dateOnlyUTC(now)
	current, parseErr := time.Parse(reminderSolarDateTimeLayout, r.NextSolarDate)
	if parseErr != nil {
		current = today
	}
	base := today
	if current.After(today) {
		base = current
	}
	switch r.RepeatRule {
	case "once":
		return current.Format(reminderSolarDateTimeLayout), true, nil
	case "interval_days":
		// For interval chores (e.g. replace filter every 90 days), advance
		// from today when overdue/due today so the next cycle reflects the real
		// completion date, or from base if completed early.
		next := base.AddDate(0, 0, r.IntervalDays)
		return next.Format(reminderSolarDateTimeLayout), false, nil
	case "weekly":
		return base.AddDate(0, 0, 7).Format(reminderSolarDateTimeLayout), false, nil
	case "monthly":
		thisMonthTarget := solarClampedDate(base.Year(), int(base.Month()), r.Day)
		if thisMonthTarget.After(today) && thisMonthTarget.After(current) {
			return thisMonthTarget.Format(reminderSolarDateTimeLayout), false, nil
		}
		nextMonth := time.Date(base.Year(), base.Month()+1, 1, 0, 0, 0, 0, time.UTC)
		return solarClampedDate(nextMonth.Year(), int(nextMonth.Month()), r.Day).Format(reminderSolarDateTimeLayout), false, nil
	case "yearly":
		after := base.AddDate(0, 0, 1)
		if r.CalendarType == "lunar" {
			solar, _, _, err := NextLunarOccurrence(r.Month, r.Day, r.IsLeapMonth, after)
			if err != nil {
				return "", false, err
			}
			return solar.Format(reminderSolarDateTimeLayout), false, nil
		}
		solar, _, err := NextSolarYearlyOccurrence(r.Month, r.Day, after)
		if err != nil {
			return "", false, err
		}
		return solar.Format(reminderSolarDateTimeLayout), false, nil
	default:
		return "", false, ErrInput
	}
}

func decorateReminder(r *FamilyReminder, now time.Time) {
	today := dateOnlyUTC(now)
	r.RemindDays = parseRemindDaysCSV(r.RemindDaysCSV)
	nextDate, err := time.Parse(reminderSolarDateTimeLayout, r.NextSolarDate)
	if err != nil {
		nextDate = today
		r.NextSolarDate = today.Format(reminderSolarDateTimeLayout)
	}
	// Auto-roll past yearly birthdays/anniversaries so countdown stays forward-looking.
	if r.RepeatRule == "yearly" && nextDate.Before(today) {
		if r.CalendarType == "lunar" {
			if rolled, _, _, lerr := NextLunarOccurrence(r.Month, r.Day, r.IsLeapMonth, today); lerr == nil {
				nextDate = rolled
				r.NextSolarDate = rolled.Format(reminderSolarDateTimeLayout)
			}
		} else {
			if rolled, _, serr := NextSolarYearlyOccurrence(r.Month, r.Day, today); serr == nil {
				nextDate = rolled
				r.NextSolarDate = rolled.Format(reminderSolarDateTimeLayout)
			}
		}
	}
	r.DaysUntil = int(nextDate.Sub(today).Hours() / 24)
	if r.CalendarType == "lunar" {
		if ld, lerr := SolarToLunar(nextDate); lerr == nil {
			r.LunarLabel = "农历" + ld.Display
			if r.Year > 0 && r.RepeatRule == "yearly" && ld.Year > r.Year {
				r.YearsCount = ld.Year - r.Year
			}
		} else {
			r.LunarLabel = "农历" + FormatLunarMonthDay(r.Month, r.Day, r.IsLeapMonth)
		}
	} else {
		if r.Year > 0 && r.RepeatRule == "yearly" && nextDate.Year() > r.Year {
			r.YearsCount = nextDate.Year() - r.Year
		}
		if ld, lerr := SolarToLunar(nextDate); lerr == nil {
			r.LunarLabel = "农历" + ld.Display
		}
	}
}
