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
