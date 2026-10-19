//go:build darwin && arm64

package system

/*
#cgo CFLAGS: -Wno-deprecated-declarations
#include <mach/mach.h>
#include <mach/host_info.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <sys/sysctl.h>
#include <stdint.h>

static int lightisle_sample(uint64_t* memoryTotal, uint64_t* memoryUsed, uint64_t* cpuIdle, uint64_t* cpuTotal, uint32_t* cpuCount) {
  size_t size = sizeof(uint64_t);
  if (sysctlbyname("hw.memsize", memoryTotal, &size, NULL, 0) != 0) return -1;
  vm_statistics64_data_t stats;
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count) != KERN_SUCCESS) return -2;
  vm_size_t pageSize = 0;
  if (host_page_size(mach_host_self(), &pageSize) != KERN_SUCCESS) return -3;
  uint64_t available = ((uint64_t)stats.free_count + (uint64_t)stats.inactive_count
    + (uint64_t)stats.speculative_count + (uint64_t)stats.purgeable_count) * pageSize;
  // OS memory pressure / Activity Monitor do not use exactly the same definition.
  *memoryUsed = available < *memoryTotal ? *memoryTotal - available : 0;

  natural_t ncpu = 0;
  processor_info_array_t info = NULL;
  mach_msg_type_number_t infoCount = 0;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &infoCount) != KERN_SUCCESS) return -4;
  *cpuIdle = 0;
  *cpuTotal = 0;
  *cpuCount = (uint32_t)ncpu;
  processor_cpu_load_info_t loads = (processor_cpu_load_info_t)info;
  for (natural_t i = 0; i < ncpu; i++) {
    uint64_t idle = (uint32_t)loads[i].cpu_ticks[CPU_STATE_IDLE];
    uint64_t user = (uint32_t)loads[i].cpu_ticks[CPU_STATE_USER];
    uint64_t nice = (uint32_t)loads[i].cpu_ticks[CPU_STATE_NICE];
    uint64_t system = (uint32_t)loads[i].cpu_ticks[CPU_STATE_SYSTEM];
    *cpuIdle += idle;
    *cpuTotal += idle + user + nice + system;
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, (vm_size_t)(infoCount * sizeof(integer_t)));
  return 0;
}
*/
import "C"

import (
	"errors"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
)

type Snapshot struct {
	Timestamp    time.Time `json:"timestamp"`
	Hostname     string    `json:"hostname"`
	Architecture string    `json:"architecture"`
	CPUCount     uint32    `json:"cpuCount"`
	CPUPercent   *float64  `json:"cpuPercent"`
	MemoryTotal  uint64    `json:"memoryTotal"`
	MemoryUsed   uint64    `json:"memoryUsed"`
	DiskTotal    uint64    `json:"diskTotal"`
	DiskFree     uint64    `json:"diskFree"`
}

type Collector struct {
	mu        sync.Mutex
	lastIdle  uint64
	lastTotal uint64
	started   bool
}

func (c *Collector) Collect() (Snapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var total, used, idle, ticks C.uint64_t
	var cpus C.uint32_t
	if code := C.lightisle_sample(&total, &used, &idle, &ticks, &cpus); code != 0 {
		return Snapshot{}, errors.New("cannot read macOS Mach host metrics")
	}

	var fs syscall.Statfs_t
	if err := syscall.Statfs("/", &fs); err != nil {
		return Snapshot{}, err
	}
	host, _ := os.Hostname()
	result := Snapshot{
		Timestamp: time.Now().UTC(), Hostname: host,
		Architecture: runtime.GOOS + "/" + runtime.GOARCH,
		CPUCount:     uint32(cpus),
		MemoryTotal:  uint64(total), MemoryUsed: uint64(used),
		DiskTotal: uint64(fs.Blocks) * uint64(fs.Bsize),
		DiskFree:  uint64(fs.Bavail) * uint64(fs.Bsize),
	}
	nextIdle, nextTicks := uint64(idle), uint64(ticks)
	if c.started && nextTicks >= c.lastTotal && nextIdle >= c.lastIdle {
		totalDelta := nextTicks - c.lastTotal
		idleDelta := nextIdle - c.lastIdle
		if totalDelta > 0 && idleDelta <= totalDelta {
			percent := 100 * float64(totalDelta-idleDelta) / float64(totalDelta)
			result.CPUPercent = &percent
		}
	}
	c.lastIdle, c.lastTotal, c.started = nextIdle, nextTicks, true
	return result, nil
}
