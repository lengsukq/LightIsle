package tasks

import (
	"database/sql"
	"errors"
	"regexp"
	"time"

	"github.com/lengsukq/lightisle/core/internal/diskhealth"
)

// Only metadata from an explicitly requested SMART read is persisted. The
// disk's validated opaque identity scopes history across device replacement;
// serial numbers, mount paths and filenames are never written to SQLite.
type DiskHealthSample struct {
	Timestamp    int64  `json:"timestamp"`
	Source       string `json:"source"`
	Reason       string `json:"reason,omitempty"`
	Temperature  *int   `json:"temperature,omitempty"`
	Passed       *bool  `json:"passed"`
	LifeUsed     *int   `json:"lifeUsed,omitempty"`
	PowerOnHours *int   `json:"powerOnHours,omitempty"`
	Risk         string `json:"risk"` // unknown, ok, warning, critical
}

var opaqueDiskKey = regexp.MustCompile("^[a-f0-9]{64}$")

func diskSample(report diskhealth.Report, now int64) DiskHealthSample {
	s := DiskHealthSample{Timestamp: now, Source: report.Source, Reason: report.Reason,
		Temperature: report.Temperature, Passed: report.Passed, LifeUsed: report.LifeUsed,
		PowerOnHours: report.PowerOnHours, Risk: "unknown"}
	if report.Source != "smartctl" {
		return s
	}
	if report.Passed != nil && !*report.Passed {
		s.Risk = "critical"
		return s
	}
	// Conservative advisory thresholds; not a replacement for vendor SMART.
	if report.Temperature != nil && *report.Temperature >= 60 ||
		report.LifeUsed != nil && *report.LifeUsed >= 90 {
		s.Risk = "warning"
		return s
	}
	if report.Passed != nil || report.Temperature != nil || report.LifeUsed != nil {
		s.Risk = "ok"
	}
	return s
}

func (j *Journal) RecordDiskHealth(deviceKey string, report diskhealth.Report) (DiskHealthSample, error) {
	if j == nil || j.db == nil || !opaqueDiskKey.MatchString(deviceKey) {
		return DiskHealthSample{}, errors.New("invalid_disk_history_identity")
	}
	now := time.Now().Unix()
	s := diskSample(report, now)
	if report.Source != "smartctl" && report.Source != "none" {
		return DiskHealthSample{}, errors.New("invalid_disk_history_source")
	}
	tx, err := j.db.Begin()
	if err != nil {
		return DiskHealthSample{}, err
	}
	defer tx.Rollback()
	var passed *int
	if s.Passed != nil {
		v := 0
		if *s.Passed {
			v = 1
		}
		passed = &v
	}
	_, err = tx.Exec("INSERT INTO disk_health_history(device_key,timestamp,source,reason,temperature,passed,life_used,power_on_hours,risk) VALUES(?,?,?,?,?,?,?,?,?) "+
		"ON CONFLICT(device_key,timestamp) DO UPDATE SET source=excluded.source,reason=excluded.reason,"+
		"temperature=excluded.temperature,passed=excluded.passed,life_used=excluded.life_used,power_on_hours=excluded.power_on_hours,risk=excluded.risk",
		deviceKey, s.Timestamp, s.Source, s.Reason, s.Temperature, passed, s.LifeUsed, s.PowerOnHours, s.Risk)
	if err != nil {
		return DiskHealthSample{}, err
	}
	if _, err = tx.Exec("DELETE FROM disk_health_history WHERE timestamp < ?", now-30*86400); err != nil {
		return DiskHealthSample{}, err
	}
	if _, err = tx.Exec("DELETE FROM disk_health_history WHERE device_key=? AND timestamp NOT IN "+
		"(SELECT timestamp FROM disk_health_history WHERE device_key=? ORDER BY timestamp DESC LIMIT 360)", deviceKey, deviceKey); err != nil {
		return DiskHealthSample{}, err
	}
	if err = tx.Commit(); err != nil {
		return DiskHealthSample{}, err
	}
	return s, nil
}

func (j *Journal) DiskHealthHistory(deviceKey string, limit int) ([]DiskHealthSample, error) {
	if j == nil || j.db == nil || !opaqueDiskKey.MatchString(deviceKey) || limit < 1 || limit > 360 {
		return nil, errors.New("invalid_disk_history_query")
	}
	rows, err := j.db.Query("SELECT timestamp,source,reason,temperature,passed,life_used,power_on_hours,risk "+
		"FROM disk_health_history WHERE device_key=? ORDER BY timestamp DESC LIMIT ?", deviceKey, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]DiskHealthSample, 0, limit)
	for rows.Next() {
		var s DiskHealthSample
		var temperature, passed, life, power sql.NullInt64
		if err := rows.Scan(&s.Timestamp, &s.Source, &s.Reason, &temperature, &passed, &life, &power, &s.Risk); err != nil {
			return nil, err
		}
		if temperature.Valid {
			v := int(temperature.Int64)
			s.Temperature = &v
		}
		if passed.Valid {
			v := passed.Int64 != 0
			s.Passed = &v
		}
		if life.Valid {
			v := int(life.Int64)
			s.LifeUsed = &v
		}
		if power.Valid {
			v := int(power.Int64)
			s.PowerOnHours = &v
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, k := 0, len(out)-1; i < k; i, k = i+1, k-1 {
		out[i], out[k] = out[k], out[i]
	}
	return out, nil
}
