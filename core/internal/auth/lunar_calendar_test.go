package auth

import (
	"testing"
	"time"
)

func TestLunarSolarKnownMilestones(t *testing.T) {
	cases := []struct {
		solar  string
		lYear  int
		lMonth int
		lDay   int
		isLeap bool
	}{
		{"1900-01-31", 1900, 1, 1, false},
		{"1949-01-29", 1949, 1, 1, false},
		{"1949-10-01", 1949, 8, 10, false},
		{"1970-02-06", 1970, 1, 1, false},
		{"2000-02-05", 2000, 1, 1, false},
		{"2020-01-25", 2020, 1, 1, false},
		{"2020-05-23", 2020, 4, 1, true},  // 2020 闰四月初一
		{"2023-01-22", 2023, 1, 1, false},
		{"2023-03-22", 2023, 2, 1, true},  // 2023 闰二月初一
		{"2024-02-09", 2023, 12, 30, false}, // 除夕 (2023 腊月大 30天)
		{"2024-02-10", 2024, 1, 1, false},
		{"2025-01-28", 2024, 12, 29, false}, // 除夕 (2024 腊月小 29天)
		{"2025-01-29", 2025, 1, 1, false},
		{"2025-07-25", 2025, 6, 1, true},  // 2025 闰六月初一
		{"2026-02-16", 2025, 12, 29, false}, // 除夕
		{"2026-02-17", 2026, 1, 1, false},
		{"2027-02-06", 2027, 1, 1, false},
		{"2028-01-26", 2028, 1, 1, false},
		{"2030-02-03", 2030, 1, 1, false},
		{"2100-02-09", 2100, 1, 1, false},
	}

	for _, tc := range cases {
		solar, err := time.Parse("2006-01-02", tc.solar)
		if err != nil {
			t.Fatal(err)
		}
		gotLunar, err := SolarToLunar(solar)
		if err != nil {
			t.Fatalf("SolarToLunar(%s) error: %v", tc.solar, err)
		}
		if gotLunar.Year != tc.lYear || gotLunar.Month != tc.lMonth || gotLunar.Day != tc.lDay || gotLunar.IsLeap != tc.isLeap {
			t.Fatalf("SolarToLunar(%s) = %+v, want %d-%d-%d leap=%v", tc.solar, gotLunar, tc.lYear, tc.lMonth, tc.lDay, tc.isLeap)
		}
		gotSolar, err := LunarToSolar(tc.lYear, tc.lMonth, tc.lDay, tc.isLeap)
		if err != nil {
			t.Fatalf("LunarToSolar(%d-%d-%d leap=%v) error: %v", tc.lYear, tc.lMonth, tc.lDay, tc.isLeap, err)
		}
		if gotSolar.Format("2006-01-02") != tc.solar {
			t.Fatalf("LunarToSolar(%d-%d-%d leap=%v) = %s, want %s", tc.lYear, tc.lMonth, tc.lDay, tc.isLeap, gotSolar.Format("2006-01-02"), tc.solar)
		}
	}
}

func TestLunarSolarFullRangeBijection(t *testing.T) {
	start := time.Date(1900, 1, 31, 0, 0, 0, 0, time.UTC)
	end := time.Date(2100, 12, 31, 0, 0, 0, 0, time.UTC)
	count := 0
	for d := start; !d.After(end); d = d.AddDate(0, 0, 1) {
		ld, err := SolarToLunar(d)
		if err != nil {
			t.Fatalf("SolarToLunar(%s): %v", d.Format("2006-01-02"), err)
		}
		back, err := LunarToSolar(ld.Year, ld.Month, ld.Day, ld.IsLeap)
		if err != nil {
			t.Fatalf("LunarToSolar(%+v): %v", ld, err)
		}
		if !back.Equal(d) {
			t.Fatalf("roundtrip mismatch: %s -> %+v -> %s", d.Format("2006-01-02"), ld, back.Format("2006-01-02"))
		}
		count++
	}
	if count < 73000 {
		t.Fatalf("expected full 201-year span, got %d days", count)
	}
}

func TestLunarLeapFallbackAndChuxiClamping(t *testing.T) {
	// 2024 has a 29-day 腊月, so 腊月三十 clamps to 腊月廿九 = 2025-01-28.
	solar, ld, err := LunarDateInYear(2024, 12, 30, false)
	if err != nil {
		t.Fatal(err)
	}
	if solar.Format("2006-01-02") != "2025-01-28" || ld.Day != 29 {
		t.Fatalf("2024 腊月三十 clamp = %s (%+v), want 2025-01-28 day 29", solar.Format("2006-01-02"), ld)
	}

	// Leap 6th month birthday: in 2025 (has leap 6) -> 2025-07-25; in 2026 (no leap 6) -> regular 6th month.
	s2025, ld2025, err := LunarDateInYear(2025, 6, 1, true)
	if err != nil {
		t.Fatal(err)
	}
	if !ld2025.IsLeap || s2025.Format("2006-01-02") != "2025-07-25" {
		t.Fatalf("2025 闰六月初一 = %s (%+v), want 2025-07-25 leap", s2025.Format("2006-01-02"), ld2025)
	}
	s2026, ld2026, err := LunarDateInYear(2026, 6, 1, true)
	if err != nil {
		t.Fatal(err)
	}
	if ld2026.IsLeap || ld2026.Month != 6 || ld2026.Day != 1 {
		t.Fatalf("2026 leap fallback = %s (%+v), want non-leap 6-1", s2026.Format("2006-01-02"), ld2026)
	}

	// Cross-year NextLunarOccurrence: on 2026-01-15, next 腊月三十 is 2026-02-16 (Lunar 2025-12-29).
	from := time.Date(2026, 1, 15, 0, 0, 0, 0, time.UTC)
	nextSolar, nextLD, days, err := NextLunarOccurrence(12, 30, false, from)
	if err != nil {
		t.Fatal(err)
	}
	if nextSolar.Format("2006-01-02") != "2026-02-16" || nextLD.Year != 2025 || days != 32 {
		t.Fatalf("NextLunarOccurrence cross-year = %s (%+v) days=%d, want 2026-02-16 (lunar 2025) days=32",
			nextSolar.Format("2006-01-02"), nextLD, days)
	}

	// Solar Feb 29 clamps to Feb 28 in non-leap year 2026.
	febSolar, febDays, err := NextSolarYearlyOccurrence(2, 29, time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if febSolar.Format("2006-01-02") != "2026-02-28" || febDays != 27 {
		t.Fatalf("Feb 29 clamp = %s days=%d, want 2026-02-28 days=27", febSolar.Format("2006-01-02"), febDays)
	}
}
