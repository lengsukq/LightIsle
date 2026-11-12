package system

import (
	"regexp"
	"strconv"
	"strings"
)

// PowerStatus describes the host AC / UPS / battery state parsed from macOS
// pmset -g batt so desktop Mac minis with USB UPS units can trigger safe
// power-loss throttling and checkpointing without kernel drivers.
type PowerStatus struct {
	Available        bool   `json:"available"`
	Source           string `json:"source"` // "ac" | "battery" | "ups"
	OnBattery        bool   `json:"onBattery"`
	UPSPresent       bool   `json:"upsPresent"`
	DeviceName       string `json:"deviceName,omitempty"`
	Percent          *int   `json:"percent,omitempty"`
	RemainingMinutes *int   `json:"remainingMinutes,omitempty"`
	State            string `json:"state,omitempty"` // "charged" | "charging" | "discharging" | "finishing charge"
	LowBattery       bool   `json:"lowBattery"`
}

const LowBatteryThresholdPercent = 25

var (
	pmsetPercentRe = regexp.MustCompile(`(\d{1,3})%`)
	pmsetRemTimeRe = regexp.MustCompile(`(\d+):(\d{2})\s+remaining`)
)

// ParsePmsetBatt parses the human-readable output of `/usr/bin/pmset -g batt`.
func ParsePmsetBatt(raw string) PowerStatus {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return PowerStatus{}
	}
	lines := strings.Split(trimmed, "\n")
	header := strings.ToLower(strings.TrimSpace(lines[0]))

	st := PowerStatus{Available: true, Source: "ac"}
	switch {
	case strings.Contains(header, "ups power"):
		st.Source = "ups"
		st.OnBattery = true
		st.UPSPresent = true
	case strings.Contains(header, "battery power"):
		st.Source = "battery"
		st.OnBattery = true
	case strings.Contains(header, "ac power"):
		st.Source = "ac"
		st.OnBattery = false
	default:
		return PowerStatus{}
	}

	for _, line := range lines[1:] {
		entry := strings.TrimSpace(line)
		if entry == "" {
			continue
		}
		lower := strings.ToLower(entry)
		if strings.Contains(lower, "ups") && !strings.Contains(lower, "internalbattery") {
			st.UPSPresent = true
		}
		if nameEnd := strings.Index(entry, "\t"); nameEnd > 0 {
			name := strings.TrimPrefix(strings.TrimSpace(entry[:nameEnd]), "-")
			name = strings.TrimSpace(name)
			if idx := strings.Index(name, " (id="); idx > 0 {
				name = strings.TrimSpace(name[:idx])
			}
			st.DeviceName = name
		}
		if m := pmsetPercentRe.FindStringSubmatch(entry); len(m) == 2 {
			if pct, err := strconv.Atoi(m[1]); err == nil && pct >= 0 && pct <= 100 {
				st.Percent = &pct
			}
		}
		if m := pmsetRemTimeRe.FindStringSubmatch(lower); len(m) == 3 {
			h, errH := strconv.Atoi(m[1])
			mins, errM := strconv.Atoi(m[2])
			if errH == nil && errM == nil {
				total := h*60 + mins
				st.RemainingMinutes = &total
			}
		}
		for _, candidate := range []string{"discharging", "finishing charge", "charging", "charged"} {
			if strings.Contains(lower, candidate) {
				st.State = candidate
				break
			}
		}
		break
	}

	if st.OnBattery && st.Percent != nil && *st.Percent <= LowBatteryThresholdPercent {
		st.LowBattery = true
	}
	if st.OnBattery && st.RemainingMinutes != nil && *st.RemainingMinutes > 0 && *st.RemainingMinutes <= 10 {
		st.LowBattery = true
	}
	return st
}
