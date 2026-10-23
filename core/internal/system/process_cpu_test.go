package system

import (
	"testing"
	"time"
)

func TestProcessCPUSamplerFirstSampleAndDelta(t *testing.T) {
	var sampler processCPUSampler
	first := []processCPUTimeSample{{pid: 42, startSec: 10, startUsec: 20, cpuTimeNS: 100}}
	if got := sampler.sample(first, 0); got[42] != nil {
		t.Fatalf("first CPU sample = %v, want unknown", *got[42])
	}

	second := []processCPUTimeSample{{pid: 42, startSec: 10, startUsec: 20, cpuTimeNS: 250_000_100}}
	got := sampler.sample(second, time.Second)[42]
	if got == nil || *got != 25 {
		t.Fatalf("CPU percentage = %v, want 25", got)
	}
}

func TestProcessCPUSamplerHandlesNewExitedAndReusedPIDs(t *testing.T) {
	var sampler processCPUSampler
	sampler.sample([]processCPUTimeSample{
		{pid: 10, startSec: 1, startUsec: 1, cpuTimeNS: 900},
		{pid: 20, startSec: 2, startUsec: 2, cpuTimeNS: 900},
	}, time.Second)

	got := sampler.sample([]processCPUTimeSample{
		{pid: 10, startSec: 1, startUsec: 1, cpuTimeNS: 1_000_000_900},
		{pid: 20, startSec: 2, startUsec: 3, cpuTimeNS: 1_000_000_000},
		{pid: 30, startSec: 3, startUsec: 3, cpuTimeNS: 1_000_000_000},
	}, time.Second)
	if got[10] == nil || *got[10] != 100 {
		t.Fatalf("existing process CPU = %v, want 100", got[10])
	}
	if got[20] != nil {
		t.Fatalf("reused PID CPU = %v, want unknown", *got[20])
	}
	if got[30] != nil {
		t.Fatalf("new PID CPU = %v, want unknown", *got[30])
	}

	got = sampler.sample([]processCPUTimeSample{
		{pid: 10, startSec: 1, startUsec: 1, cpuTimeNS: 2_000_000_900},
		{pid: 30, startSec: 3, startUsec: 3, cpuTimeNS: 2_000_000_000},
	}, time.Second)
	if _, exists := sampler.previous[20]; exists {
		t.Fatal("exited process remained in CPU sampler state")
	}
	if got[30] == nil || *got[30] != 100 {
		t.Fatalf("process CPU after first sample = %v, want 100", got[30])
	}
}

func TestProcessCPUSamplerRejectsResetAndInvalidElapsedTime(t *testing.T) {
	var sampler processCPUSampler
	sampler.sample([]processCPUTimeSample{{pid: 7, startSec: 1, cpuTimeNS: 10}}, time.Second)
	got := sampler.sample([]processCPUTimeSample{{pid: 7, startSec: 1, cpuTimeNS: 5}}, time.Second)
	if got[7] != nil {
		t.Fatalf("reset CPU counter = %v, want unknown", *got[7])
	}
	got = sampler.sample([]processCPUTimeSample{{pid: 7, startSec: 1, cpuTimeNS: 10}}, 0)
	if got[7] != nil {
		t.Fatalf("zero elapsed CPU = %v, want unknown", *got[7])
	}
}

func TestSortProcessesByRSS(t *testing.T) {
	low, high := uint64(10), uint64(30)
	processes := []ProcessSnapshot{
		{PID: 5, Name: "low", RSSBytes: &low},
		{PID: 4, Name: "unknown"},
		{PID: 2, Name: "high", RSSBytes: &high},
		{PID: 1, Name: "same", RSSBytes: &high},
	}
	got := sortProcessesByRSS(processes, 2)
	if len(got) != 2 || got[0].PID != 1 || got[1].PID != 2 {
		t.Fatalf("top processes = %+v, want stable RSS descending order", got)
	}
}
