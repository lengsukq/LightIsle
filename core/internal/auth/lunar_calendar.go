package auth

import (
	"errors"
	"fmt"
	"time"
)

const (
	LunarMinYear = 1900
	LunarMaxYear = 2100
)

var ErrLunarOutOfRange = errors.New("lunar_date_out_of_range")

// lunarInfo encodes the Chinese traditional lunisolar calendar for 1900–2100
// (201 years, verified against China Standard Time UTC+8 astronomical new moons
// and major solar terms):
//   - bits 0..3:  leap month number (0 = no leap month, 1..12 = leap month)
//   - bits 4..15: month lengths for regular months 1..12 via (0x10000 >> m)
//     (1 = 30 days, 0 = 29 days)
//   - bit 16:     leap month length (1 = 30 days, 0 = 29 days)
var lunarInfo = [201]uint32{
	0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2, // 1900
	0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d295, 0x0b550, 0x056a0, 0x0ada2, 0x095b0, 0x14977, // 1910
	0x049b0, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970, // 1920
	0x06566, 0x0d4a0, 0x0ea50, 0x16a95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950, // 1930
	0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557, // 1940
	0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0, // 1950
	0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0, // 1960
	0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6, // 1970
	0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570, // 1980
	0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0, // 1990
	0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5, // 2000
	0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930, // 2010
	0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530, // 2020
	0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45, // 2030
	0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0, // 2040
	0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0, // 2050
	0x092e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4, // 2060
	0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0, // 2070
	0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160, // 2080
	0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a4d0, 0x0d150, 0x0f252, // 2090
	0x0d520, // 2100
}

var (
	lunarBaseSolar  = time.Date(1900, 1, 31, 0, 0, 0, 0, time.UTC)
	lunarMonthNames = [12]string{"正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"}
	lunarDayNames   = [30]string{
		"初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
		"十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
		"廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
	}
	heavenlyStems   = [10]string{"甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"}
	earthlyBranches = [12]string{"子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"}
	zodiacAnimals   = [12]string{"鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"}
)

// LunarDate is a calendar date in the traditional Chinese lunisolar calendar.
type LunarDate struct {
	Year      int    `json:"year"`
	Month     int    `json:"month"`
	Day       int    `json:"day"`
	IsLeap    bool   `json:"isLeap"`
	GanZhi    string `json:"ganZhi"`
	Zodiac    string `json:"zodiac"`
	MonthName string `json:"monthName"`
	DayName   string `json:"dayName"`
	Display   string `json:"display"`
}

// FormatLunarMonthDay formats a lunar month/day pair such as "闰四月初五" or
// "腊月三十".
func FormatLunarMonthDay(month, day int, isLeap bool) string {
	if month < 1 || month > 12 || day < 1 || day > 30 {
		return ""
	}
	prefix := ""
	if isLeap {
		prefix = "闰"
	}
	return prefix + lunarMonthNames[month-1] + lunarDayNames[day-1]
}

// LunarLeapMonth returns the leap month number (1..12) for the given lunar
// year, or 0 if the year has no leap month.
func LunarLeapMonth(year int) int {
	if year < LunarMinYear || year > LunarMaxYear {
		return 0
	}
	return int(lunarInfo[year-LunarMinYear] & 0x0f)
}

// LunarLeapDays returns the number of days (29 or 30) in the leap month of
// year, or 0 if the year has no leap month.
func LunarLeapDays(year int) int {
	if LunarLeapMonth(year) == 0 {
		return 0
	}
	if lunarInfo[year-LunarMinYear]&0x10000 != 0 {
		return 30
	}
	return 29
}

// LunarMonthDays returns the number of days (29 or 30) in regular lunar month
// m (1..12) of year.
func LunarMonthDays(year, month int) int {
	if year < LunarMinYear || year > LunarMaxYear || month < 1 || month > 12 {
		return 0
	}
	if lunarInfo[year-LunarMinYear]&(0x10000>>uint(month)) != 0 {
		return 30
	}
	return 29
}

// LunarYearDays returns the total number of days in lunar year (353..385).
func LunarYearDays(year int) int {
	if year < LunarMinYear || year > LunarMaxYear {
		return 0
	}
	sum := 348
	info := lunarInfo[year-LunarMinYear]
	for bit := uint32(0x8000); bit > 0x8; bit >>= 1 {
		if info&bit != 0 {
			sum++
		}
	}
	return sum + LunarLeapDays(year)
}

// LunarToSolar converts a valid Chinese lunar date (1900–2100) into its
// corresponding Gregorian date (UTC midnight).
func LunarToSolar(year, month, day int, isLeap bool) (time.Time, error) {
	if year < LunarMinYear || year > LunarMaxYear || month < 1 || month > 12 || day < 1 {
		return time.Time{}, ErrLunarOutOfRange
	}
	leapMonth := LunarLeapMonth(year)
	if isLeap {
		if leapMonth != month {
			return time.Time{}, ErrLunarOutOfRange
		}
		if day > LunarLeapDays(year) {
			return time.Time{}, ErrLunarOutOfRange
		}
	} else {
		if day > LunarMonthDays(year, month) {
			return time.Time{}, ErrLunarOutOfRange
		}
	}

	offset := 0
	for y := LunarMinYear; y < year; y++ {
		offset += LunarYearDays(y)
	}
	for m := 1; m < month; m++ {
		offset += LunarMonthDays(year, m)
		if leapMonth == m {
			offset += LunarLeapDays(year)
		}
	}
	if isLeap {
		offset += LunarMonthDays(year, month)
	}
	offset += day - 1
	return lunarBaseSolar.AddDate(0, 0, offset), nil
}

// SolarToLunar converts a Gregorian date (using its Y/M/D components) into the
// corresponding Chinese lunar date.
func SolarToLunar(t time.Time) (LunarDate, error) {
	d := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
	offset := int(d.Sub(lunarBaseSolar).Hours() / 24)
	if offset < 0 {
		return LunarDate{}, ErrLunarOutOfRange
	}

	lunarYear := LunarMinYear
	for lunarYear <= LunarMaxYear {
		yd := LunarYearDays(lunarYear)
		if offset < yd {
			break
		}
		offset -= yd
		lunarYear++
	}
	if lunarYear > LunarMaxYear {
		return LunarDate{}, ErrLunarOutOfRange
	}

	leapMonth := LunarLeapMonth(lunarYear)
	isLeap := false
	lunarMonth := 1
	for lunarMonth <= 12 {
		md := LunarMonthDays(lunarYear, lunarMonth)
		if offset < md {
			break
		}
		offset -= md
		if leapMonth == lunarMonth {
			ld := LunarLeapDays(lunarYear)
			if offset < ld {
				isLeap = true
				break
			}
			offset -= ld
		}
		lunarMonth++
	}
	lunarDay := offset + 1
	return buildLunarDate(lunarYear, lunarMonth, lunarDay, isLeap), nil
}

func buildLunarDate(year, month, day int, isLeap bool) LunarDate {
	stem := heavenlyStems[(year-4)%10]
	branch := earthlyBranches[(year-4)%12]
	zodiac := zodiacAnimals[(year-4)%12]
	monthName := lunarMonthNames[month-1]
	if isLeap {
		monthName = "闰" + monthName
	}
	dayName := lunarDayNames[day-1]
	return LunarDate{
		Year:      year,
		Month:     month,
		Day:       day,
		IsLeap:    isLeap,
		GanZhi:    stem + branch,
		Zodiac:    zodiac,
		MonthName: monthName,
		DayName:   dayName,
		Display:   monthName + dayName,
	}
}

// LunarDateInYear resolves a recurring lunar month/day (such as a birthday) in
// a specific lunar year. If isLeap is true but targetYear does not have that
// leap month, it falls back to the regular month. If day is 30 in a 29-day
// month (e.g. 腊月三十 / 除夕 in a 29-day 腊月), it clamps to day 29.
func LunarDateInYear(targetLunarYear, month, day int, isLeap bool) (time.Time, LunarDate, error) {
	if targetLunarYear < LunarMinYear || targetLunarYear > LunarMaxYear || month < 1 || month > 12 || day < 1 || day > 30 {
		return time.Time{}, LunarDate{}, ErrLunarOutOfRange
	}
	useLeap := isLeap && LunarLeapMonth(targetLunarYear) == month
	maxDays := LunarMonthDays(targetLunarYear, month)
	if useLeap {
		maxDays = LunarLeapDays(targetLunarYear)
	}
	clampedDay := day
	if clampedDay > maxDays {
		clampedDay = maxDays
	}
	solar, err := LunarToSolar(targetLunarYear, month, clampedDay, useLeap)
	if err != nil {
		return time.Time{}, LunarDate{}, err
	}
	return solar, buildLunarDate(targetLunarYear, month, clampedDay, useLeap), nil
}

// NextLunarOccurrence computes the earliest Gregorian date >= fromDate (date
// only) for a recurring Chinese lunar month/day. It also returns the resolved
// LunarDate and countdown days.
func NextLunarOccurrence(month, day int, isLeap bool, fromDate time.Time) (time.Time, LunarDate, int, error) {
	today := dateOnlyUTC(fromDate)
	baseYear := today.Year()
	for y := baseYear - 1; y <= baseYear+2; y++ {
		if y < LunarMinYear || y > LunarMaxYear {
			continue
		}
		solar, ld, err := LunarDateInYear(y, month, day, isLeap)
		if err != nil {
			continue
		}
		if !solar.Before(today) {
			days := int(solar.Sub(today).Hours() / 24)
			return solar, ld, days, nil
		}
	}
	return time.Time{}, LunarDate{}, 0, ErrLunarOutOfRange
}

// NextSolarYearlyOccurrence computes the earliest Gregorian date >= fromDate
// for a recurring solar month/day (clamping Feb 29 to Feb 28 in non-leap years).
func NextSolarYearlyOccurrence(month, day int, fromDate time.Time) (time.Time, int, error) {
	if month < 1 || month > 12 || day < 1 || day > 31 {
		return time.Time{}, 0, ErrInput
	}
	today := dateOnlyUTC(fromDate)
	for y := today.Year(); y <= today.Year()+2; y++ {
		cand := solarClampedDate(y, month, day)
		if !cand.Before(today) {
			days := int(cand.Sub(today).Hours() / 24)
			return cand, days, nil
		}
	}
	return time.Time{}, 0, fmt.Errorf("solar date out of range")
}

func solarDaysInMonth(year, month int) int {
	return time.Date(year, time.Month(month+1), 0, 0, 0, 0, 0, time.UTC).Day()
}

func solarClampedDate(year, month, day int) time.Time {
	maxDay := solarDaysInMonth(year, month)
	if day > maxDay {
		day = maxDay
	}
	return time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
}

func dateOnlyUTC(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}
