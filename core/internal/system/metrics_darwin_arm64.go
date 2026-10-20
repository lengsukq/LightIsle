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
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/socket.h>
#include <string.h>
#include <libproc.h>
#include <unistd.h>

static uint64_t lightisle_core_resident(void) {
  struct proc_taskinfo task;
  int bytes=proc_pidinfo(getpid(),PROC_PIDTASKINFO,0,&task,sizeof(task));
  if(bytes!=(int)sizeof(task))return 0;
  return (uint64_t)task.pti_resident_size;
}

static void lightisle_network(uint64_t *rx,uint64_t *tx){
  struct ifaddrs *head=NULL;
  *rx=0;*tx=0;
  if(getifaddrs(&head)!=0)return;
  for(struct ifaddrs *p=head;p;p=p->ifa_next){
    if(!p->ifa_addr||!p->ifa_data||p->ifa_addr->sa_family!=AF_LINK)continue;
    if(!(p->ifa_flags & IFF_UP)||(p->ifa_flags & IFF_LOOPBACK))continue;
    // Physical Apple interfaces; exclude virtual and redundant bridge devices.
    if(strncmp(p->ifa_name,"en",2)!=0)continue;
    struct if_data *d=(struct if_data*)p->ifa_data;
    *rx += d->ifi_ibytes;
    *tx += d->ifi_obytes;
  }
  freeifaddrs(head);
}

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
	"strings"
	"sync"
	"syscall"
	"time"
)

type Volume struct {
	Name       string `json:"name"`
	Mount      string `json:"mount"`
	Device     string `json:"device"`
	Filesystem string `json:"filesystem"`
	Total      uint64 `json:"total"`
	Free       uint64 `json:"free"`
	ReadOnly   bool   `json:"readOnly"`
}

func cName(p []int8) string {
	b := make([]byte, 0, len(p))
	for _, v := range p {
		if v == 0 {
			break
		}
		b = append(b, byte(v))
	}
	return string(b)
}

func Volumes() []Volume {
	const mntNowait = 2   // macOS getfsstat(2) MNT_NOWAIT
	const mntReadonly = 1 // macOS sys/mount.h MNT_RDONLY
	n, err := syscall.Getfsstat(nil, mntNowait)
	if err != nil || n < 1 {
		return []Volume{}
	}
	if n > 256 {
		n = 256
	}
	stats := make([]syscall.Statfs_t, n)
	n, err = syscall.Getfsstat(stats, mntNowait)
	if err != nil {
		return []Volume{}
	}
	if n > len(stats) {
		n = len(stats)
	}
	list := make([]Volume, 0, n)
	for _, v := range stats[:n] {
		mount := cName(v.Mntonname[:])
		if mount != "/" && !strings.HasPrefix(mount, "/Volumes/") {
			continue
		}
		total := v.Blocks * uint64(v.Bsize)
		if total == 0 {
			continue
		}
		name := strings.TrimPrefix(mount, "/Volumes/")
		if mount == "/" {
			name = "Macintosh HD"
		}
		list = append(list, Volume{Name: name, Mount: mount,
			Device: cName(v.Mntfromname[:]), Filesystem: cName(v.Fstypename[:]),
			Total: total, Free: v.Bavail * uint64(v.Bsize), ReadOnly: v.Flags&mntReadonly != 0})
	}
	return list
}

type Snapshot struct {
	Timestamp      time.Time `json:"timestamp"`
	Hostname       string    `json:"hostname"`
	Architecture   string    `json:"architecture"`
	CPUCount       uint32    `json:"cpuCount"`
	CPUPercent     *float64  `json:"cpuPercent"`
	MemoryTotal    uint64    `json:"memoryTotal"`
	MemoryUsed     uint64    `json:"memoryUsed"`
	DiskTotal      uint64    `json:"diskTotal"`
	DiskFree       uint64    `json:"diskFree"`
	Volumes        []Volume  `json:"volumes"`
	NetworkRxBytes uint64    `json:"networkRxBytes"`
	NetworkTxBytes uint64    `json:"networkTxBytes"`
	NetworkDownBps *float64  `json:"networkDownBps"`
	NetworkUpBps   *float64  `json:"networkUpBps"`
	CorePID        int       `json:"corePid"`
	CoreRSSBytes   *uint64   `json:"coreRssBytes"`
}

type Collector struct {
	mu          sync.Mutex
	lastIdle    uint64
	lastTotal   uint64
	started     bool
	lastRx      uint64
	lastTx      uint64
	lastNetwork time.Time
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
		Volumes:   Volumes(),
		CorePID:   os.Getpid(),
	}
	if rss := uint64(C.lightisle_core_resident()); rss > 0 {
		result.CoreRSSBytes = &rss
	}
	var rx, tx C.uint64_t
	C.lightisle_network(&rx, &tx)
	result.NetworkRxBytes = uint64(rx)
	result.NetworkTxBytes = uint64(tx)
	if !c.lastNetwork.IsZero() && uint64(rx) >= c.lastRx && uint64(tx) >= c.lastTx {
		elapsed := time.Since(c.lastNetwork).Seconds()
		if elapsed >= 0.1 {
			down := float64(uint64(rx)-c.lastRx) / elapsed
			up := float64(uint64(tx)-c.lastTx) / elapsed
			result.NetworkDownBps = &down
			result.NetworkUpBps = &up
		}
	}
	c.lastRx, c.lastTx, c.lastNetwork = uint64(rx), uint64(tx), time.Now()
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
