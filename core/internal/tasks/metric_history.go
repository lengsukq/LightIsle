package tasks

import (
	"database/sql"
	"errors"
	"math"
	"time"
)

// Numeric aggregates only; no identity, filenames, network addresses.
type MetricSample struct {
	Timestamp     int64    `json:"timestamp"`
	CPUPercent    *float64 `json:"cpuPercent"`
	MemoryPercent float64  `json:"memoryPercent"`
	DiskPercent   float64  `json:"diskPercent"`
	DownloadBps   *float64 `json:"downloadBps"`
	UploadBps     *float64 `json:"uploadBps"`
}

const maxMetricSamples = 2880

func validPercent(n float64) bool { return !math.IsNaN(n) && !math.IsInf(n, 0) && n >= 0 && n <= 100 }
func validRate(p *float64) bool {
	return p == nil || (!math.IsNaN(*p) && !math.IsInf(*p, 0) && *p >= 0)
}

func (j *Journal) RecordMetric(sample MetricSample) error {
	if j == nil || j.db == nil {
		return errors.New("metric_history_unavailable")
	}
	now := time.Now().Unix()
	if sample.Timestamp < now-300 || sample.Timestamp > now+60 ||
		!validPercent(sample.MemoryPercent) || !validPercent(sample.DiskPercent) ||
		(sample.CPUPercent != nil && !validPercent(*sample.CPUPercent)) ||
		!validRate(sample.DownloadBps) || !validRate(sample.UploadBps) {
		return errors.New("invalid_metric_sample")
	}
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.Exec("INSERT INTO metric_history(timestamp,cpu_percent,memory_percent,disk_percent,download_bps,upload_bps) VALUES(?,?,?,?,?,?) "+
		"ON CONFLICT(timestamp) DO UPDATE SET cpu_percent=excluded.cpu_percent,memory_percent=excluded.memory_percent,"+
		"disk_percent=excluded.disk_percent,download_bps=excluded.download_bps,upload_bps=excluded.upload_bps",
		sample.Timestamp, sample.CPUPercent, sample.MemoryPercent, sample.DiskPercent, sample.DownloadBps, sample.UploadBps)
	if err != nil {
		return err
	}
	if _, err = tx.Exec("DELETE FROM metric_history WHERE timestamp < ?", now-48*3600); err != nil {
		return err
	}
	if _, err = tx.Exec("DELETE FROM metric_history WHERE timestamp NOT IN ("+
		"SELECT timestamp FROM metric_history ORDER BY timestamp DESC LIMIT ?)", maxMetricSamples); err != nil {
		return err
	}
	return tx.Commit()
}

func (j *Journal) MetricHistory(limit int) ([]MetricSample, error) {
	if j == nil || j.db == nil {
		return nil, errors.New("metric_history_unavailable")
	}
	if limit < 1 || limit > maxMetricSamples {
		return nil, errors.New("invalid_limit")
	}
	rows, err := j.db.Query("SELECT timestamp,cpu_percent,memory_percent,disk_percent,download_bps,upload_bps "+
		"FROM metric_history ORDER BY timestamp DESC LIMIT ?", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MetricSample, 0, limit)
	for rows.Next() {
		var s MetricSample
		var cpu, down, up sql.NullFloat64
		if err := rows.Scan(&s.Timestamp, &cpu, &s.MemoryPercent, &s.DiskPercent, &down, &up); err != nil {
			return nil, err
		}
		if cpu.Valid {
			s.CPUPercent = &cpu.Float64
		}
		if down.Valid {
			s.DownloadBps = &down.Float64
		}
		if up.Valid {
			s.UploadBps = &up.Float64
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
