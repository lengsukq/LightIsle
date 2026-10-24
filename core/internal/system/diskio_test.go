package system

import (
	"testing"
	"time"
)

func TestComputeDiskIORatesFirstSample(t *testing.T) {
	samples := []DiskIOStat{
		{Device: "disk4", ReadBytes: 100, WriteBytes: 200, ReadOps: 1, WriteOps: 2},
		{Device: "disk5", ReadBytes: 5, WriteBytes: 0, ReadOps: 1, WriteOps: 0},
	}
	now := time.Now()
	out, current, sampleTime := computeDiskIORates(samples, map[string]diskCounter{}, now, now)
	if len(out) != 2 || out[0].ReadBps != nil || out[0].WriteBps != nil {
		t.Fatalf("first sample must not fabricate rates: %+v", out)
	}
	if !sampleTime.Equal(now) || current["disk4"] != (diskCounter{readBytes: 100, writeBytes: 200}) {
		t.Fatalf("state = %+v, %+v", current, sampleTime)
	}
}

func TestComputeDiskIORatesDelta(t *testing.T) {
	prev := map[string]diskCounter{"disk4": {readBytes: 1000}}
	now := time.Now()
	elapsed := time.Duration(2 * float64(time.Second))
	samples := []DiskIOStat{{Device: "disk4", ReadBytes: 3000, WriteBytes: 500, ReadOps: 10, WriteOps: 2}}
	out, current, _ := computeDiskIORates(samples, prev, now.Add(-elapsed), now)
	if len(out) != 1 || out[0].ReadBps == nil || out[0].WriteBps == nil {
		t.Fatalf("expected rates: %+v", out)
	}
	if *out[0].ReadBps != 1000 || *out[0].WriteBps != 250 {
		t.Fatalf("rates = %v/%v, want 1000/250", *out[0].ReadBps, *out[0].WriteBps)
	}
	if current["disk4"] != (diskCounter{readBytes: 3000, writeBytes: 500}) {
		t.Fatalf("current = %+v", current)
	}
}

func TestComputeDiskIORatesFilterAndReset(t *testing.T) {
	prev := map[string]diskCounter{"disk4": {readBytes: 9000, writeBytes: 9000}, "disk7": {readBytes: 1}}
	now := time.Now()
	samples := []DiskIOStat{
		// Synthesized APFS container media objects expose no statistics.
		{Device: "disk1"},
		// Counter reset: the device was replaced between samples.
		{Device: "disk4", ReadBytes: 10, WriteBytes: 20},
		// New device without history.
		{Device: "disk8", ReadBytes: 500, WriteBytes: 0, ReadOps: 1},
	}
	out, current, _ := computeDiskIORates(samples, prev, now.Add(-time.Second), now)
	if len(out) != 2 {
		t.Fatalf("zero-traffic device must be filtered: %+v", out)
	}
	if out[0].ReadBps != nil {
		t.Fatalf("counter reset must yield nil rate: %+v", out[0])
	}
	if out[1].ReadBps != nil {
		t.Fatalf("new device must yield nil rate: %+v", out[1])
	}
	if _, ok := current["disk7"]; ok {
		t.Fatal("stale device must be dropped from tracked state")
	}
}

func TestComputeDiskIORatesShortInterval(t *testing.T) {
	prev := map[string]diskCounter{"disk4": {readBytes: 100}}
	now := time.Now()
	samples := []DiskIOStat{{Device: "disk4", ReadBytes: 200}}
	out, _, _ := computeDiskIORates(samples, prev, now.Add(-50*time.Millisecond), now)
	if out[0].ReadBps != nil {
		t.Fatalf("interval below measurement floor must not produce rates: %+v", out[0])
	}
}
