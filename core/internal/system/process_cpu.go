package system

import (
	"sort"
	"time"
)

type processCPUTimeSample struct {
	pid       int32
	startSec  uint64
	startUsec uint64
	cpuTimeNS uint64
}

type processCPUTimeState struct {
	startSec  uint64
	startUsec uint64
	cpuTimeNS uint64
}

type processCPUSampler struct {
	previous map[int32]processCPUTimeState
}

func sortProcessesByRSS(processes []ProcessSnapshot, limit int) []ProcessSnapshot {
	sort.Slice(processes, func(i, j int) bool {
		if processes[i].RSSBytes == nil {
			return false
		}
		if processes[j].RSSBytes == nil {
			return true
		}
		if *processes[i].RSSBytes != *processes[j].RSSBytes {
			return *processes[i].RSSBytes > *processes[j].RSSBytes
		}
		return processes[i].PID < processes[j].PID
	})
	if limit > 0 && len(processes) > limit {
		processes = processes[:limit]
	}
	return processes
}

func (s *processCPUSampler) sample(samples []processCPUTimeSample, elapsed time.Duration) map[int32]*float64 {
	current := make(map[int32]processCPUTimeState, len(samples))
	percentages := make(map[int32]*float64, len(samples))
	for _, sample := range samples {
		if sample.pid <= 0 {
			continue
		}
		state := processCPUTimeState{
			startSec: sample.startSec, startUsec: sample.startUsec, cpuTimeNS: sample.cpuTimeNS,
		}
		current[sample.pid] = state
		previous, ok := s.previous[sample.pid]
		if !ok || previous.startSec != state.startSec || previous.startUsec != state.startUsec ||
			state.cpuTimeNS < previous.cpuTimeNS || elapsed <= 0 {
			continue
		}
		percent := float64(state.cpuTimeNS-previous.cpuTimeNS) / float64(elapsed.Nanoseconds()) * 100
		percentages[sample.pid] = &percent
	}
	s.previous = current
	return percentages
}
