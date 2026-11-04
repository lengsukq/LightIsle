package tasks

import (
	"math"
	"testing"
	"time"
)

func TestMetricHistoryBoundedPersistentAndValidated(t *testing.T) {
	dir := t.TempDir()
	j, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	for i := 0; i < 3; i++ {
		cpu := float64(10 + i)
		if err := j.RecordMetric(MetricSample{Timestamp: now - int64(2-i), CPUPercent: &cpu, MemoryPercent: 35, DiskPercent: 60}); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.RecordMetric(MetricSample{Timestamp: now + 1, MemoryPercent: math.NaN(), DiskPercent: 20}); err == nil {
		t.Fatal("NaN must be refused")
	}
	if err := j.RecordMetric(MetricSample{Timestamp: now - 400, MemoryPercent: 20, DiskPercent: 20}); err == nil {
		t.Fatal("stale sample must be refused")
	}
	if _, err := j.MetricHistory(2881); err == nil {
		t.Fatal("unbounded request accepted")
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	j, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	history, err := j.MetricHistory(100)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 3 || history[0].Timestamp != now-2 || history[2].Timestamp != now {
		t.Fatalf("history = %+v", history)
	}
}

func TestMetricRetentionKeepsExactlyNewestSamples(t *testing.T) {
	j, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	now := time.Now().Unix()
	tx, err := j.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	// More than the cap, all within 48h, plus one expired row. Retention
	// must enforce both age and count without deleting the boundary sample.
	for i := 1; i <= maxMetricSamples+20; i++ {
		if _, err := tx.Exec("INSERT INTO metric_history(timestamp,memory_percent,disk_percent) VALUES(?,30,40)", now-int64(i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec("INSERT INTO metric_history(timestamp,memory_percent,disk_percent) VALUES(?,30,40)", now-49*3600); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := j.RecordMetric(MetricSample{Timestamp: now, MemoryPercent: 30, DiskPercent: 40}); err != nil {
			t.Fatal(err)
		}
	}
	history, err := j.MetricHistory(maxMetricSamples)
	if err != nil || len(history) != maxMetricSamples || history[0].Timestamp != now-maxMetricSamples+1 || history[len(history)-1].Timestamp != now {
		t.Fatalf("retention size=%d: %v", len(history), err)
	}
}
