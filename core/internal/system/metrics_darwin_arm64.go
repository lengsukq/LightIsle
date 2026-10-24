//go:build darwin && arm64

package system

/*
#cgo CFLAGS: -Wno-deprecated-declarations
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
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
#include <sys/proc_info.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <CoreFoundation/CoreFoundation.h>

#define LIGHTISLE_PROCESS_NAME_SIZE (2 * MAXCOMLEN)
typedef struct {
  int32_t pid;
  char name[LIGHTISLE_PROCESS_NAME_SIZE];
  uint64_t start_sec;
  uint64_t start_usec;
  uint64_t resident_size;
  uint64_t cpu_time_ns;
  int has_task;
} lightisle_process_data;

static int lightisle_list_process_ids(int32_t *buffer, int capacity) {
  if (!buffer || capacity <= 0) return 0;
  int bytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, capacity * (int)sizeof(pid_t));
  if (bytes <= 0) return 0;
  int count = bytes / (int)sizeof(pid_t);
  return count > capacity ? capacity : count;
}

static int lightisle_process_capacity(void) {
  int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
  if (bytes <= 0) return 0;
  return bytes / (int)sizeof(pid_t);
}

static int lightisle_read_process(int32_t pid, lightisle_process_data *result) {
  if (!result || pid <= 0) return 0;
  memset(result, 0, sizeof(*result));

  struct proc_bsdinfo process;
  int bytes = proc_pidinfo((pid_t)pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process));
  if (bytes != (int)sizeof(process)) return 0;

  result->pid = pid;
  result->start_sec = process.pbi_start_tvsec;
  result->start_usec = process.pbi_start_tvusec;
  const char *name = process.pbi_name[0] ? process.pbi_name : process.pbi_comm;
  strlcpy(result->name, name, sizeof(result->name));

  struct proc_taskinfo task;
  bytes = proc_pidinfo((pid_t)pid, PROC_PIDTASKINFO, 0, &task, sizeof(task));
  if (bytes == (int)sizeof(task)) {
    result->resident_size = task.pti_resident_size;
    result->cpu_time_ns = task.pti_total_user + task.pti_total_system;
    result->has_task = 1;
  }
  return 1;
}

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

#define LIGHTISLE_DISK_IO_CAPACITY 64
typedef struct {
  char name[16];
  uint64_t read_bytes;
  uint64_t write_bytes;
  uint64_t read_ops;
  uint64_t write_ops;
} lightisle_disk_io;

static uint64_t lightisle_stats_number(CFDictionaryRef stats, const char *key) {
  CFStringRef k=CFStringCreateWithCString(kCFAllocatorDefault,key,kCFStringEncodingUTF8);
  if(!k)return 0;
  uint64_t value=0;
  CFNumberRef n=(CFNumberRef)CFDictionaryGetValue(stats,k);
  if(n)CFNumberGetValue(n,kCFNumberSInt64Type,&value);
  CFRelease(k);
  return value;
}

// Enumerate whole-disk IOMedia objects ("diskN", never partitions) and copy
// their cumulative IOStorage statistics. Synthesized APFS container objects
// simply report zero counters; the Go side filters them.
static int lightisle_collect_disk_io(lightisle_disk_io *out, int capacity) {
  if(!out||capacity<=0)return 0;
  memset(out,0,capacity*sizeof(*out));
  CFMutableDictionaryRef match=IOServiceMatching("IOMedia");
  if(!match)return 0;
  io_iterator_t iter=0;
  if(IOServiceGetMatchingServices(kIOMainPortDefault,match,&iter)!=KERN_SUCCESS)return 0;
  int count=0;
  io_object_t media;
  while((media=IOIteratorNext(iter))!=0 && count<capacity){
    CFStringRef bsd=(CFStringRef)IORegistryEntryCreateCFProperty(media,CFSTR(kIOBSDNameKey),kCFAllocatorDefault,0);
    if(bsd){
      char name[64]={0};
      if(CFStringGetCString(bsd,name,sizeof(name),kCFStringEncodingUTF8)){
        size_t len=strlen(name);
        int whole=len>4 && strncmp(name,"disk",4)==0;
        for(size_t i=4;whole && i<len;i++)whole=name[i]>='0' && name[i]<='9';
        if(whole){
          CFDictionaryRef stats=(CFDictionaryRef)IORegistryEntryCreateCFProperty(media,CFSTR("Statistics"),kCFAllocatorDefault,0);
          if(stats){
            if(CFGetTypeID(stats)==CFDictionaryGetTypeID()){
              lightisle_disk_io *slot=&out[count];
              strlcpy(slot->name,name,sizeof(slot->name));
              slot->read_bytes=lightisle_stats_number(stats,"Bytes (Read)");
              slot->write_bytes=lightisle_stats_number(stats,"Bytes (Write)");
              slot->read_ops=lightisle_stats_number(stats,"Operations (Read)");
              slot->write_ops=lightisle_stats_number(stats,"Operations (Write)");
              count++;
            }
            CFRelease(stats);
          }
        }
      }
      CFRelease(bsd);
    }
    IOObjectRelease(media);
  }
  IOObjectRelease(iter);
  return count;
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

type ProcessSnapshot struct {
	PID        int      `json:"pid"`
	Name       string   `json:"name"`
	CPUPercent *float64 `json:"cpuPercent"`
	RSSBytes   *uint64  `json:"rssBytes"`
}

type Snapshot struct {
	Timestamp      time.Time    `json:"timestamp"`
	Hostname       string       `json:"hostname"`
	Architecture   string       `json:"architecture"`
	CPUCount       uint32       `json:"cpuCount"`
	CPUPercent     *float64     `json:"cpuPercent"`
	MemoryTotal    uint64       `json:"memoryTotal"`
	MemoryUsed     uint64       `json:"memoryUsed"`
	DiskTotal      uint64       `json:"diskTotal"`
	DiskFree       uint64       `json:"diskFree"`
	Volumes        []Volume     `json:"volumes"`
	NetworkRxBytes uint64       `json:"networkRxBytes"`
	NetworkTxBytes uint64       `json:"networkTxBytes"`
	NetworkDownBps *float64     `json:"networkDownBps"`
	NetworkUpBps   *float64     `json:"networkUpBps"`
	DiskIO         []DiskIOStat `json:"diskIo"`
	CorePID        int          `json:"corePid"`
	CoreRSSBytes   *uint64      `json:"coreRssBytes"`
}

type Collector struct {
	mu          sync.Mutex
	lastIdle    uint64
	lastTotal   uint64
	started     bool
	lastRx      uint64
	lastTx      uint64
	lastNetwork time.Time
	lastDisk    map[string]diskCounter
	lastDiskAt  time.Time
	processMu   sync.Mutex
	processCPU  processCPUSampler
	processesAt time.Time
	processes   []ProcessSnapshot
}

type LocalSnapshot struct {
	Snapshot
	Processes          []ProcessSnapshot `json:"processes"`
	ProcessesAvailable bool              `json:"processesAvailable"`
}

func (c *Collector) CollectLocal() (LocalSnapshot, error) {
	snapshot, err := c.Collect()
	if err != nil {
		return LocalSnapshot{}, err
	}
	processes, available := c.collectProcesses()
	return LocalSnapshot{Snapshot: snapshot, Processes: processes, ProcessesAvailable: available}, nil
}

func (c *Collector) collectProcesses() ([]ProcessSnapshot, bool) {
	const maxProcessIDs = 4096
	c.processMu.Lock()
	defer c.processMu.Unlock()
	if !c.processesAt.IsZero() && time.Since(c.processesAt) < 5*time.Second {
		return append([]ProcessSnapshot(nil), c.processes...), true
	}

	capacity := int(C.lightisle_process_capacity())
	if capacity <= 0 {
		return []ProcessSnapshot{}, false
	}
	if capacity > maxProcessIDs {
		capacity = maxProcessIDs
	}
	pids := make([]C.int32_t, capacity)
	count := int(C.lightisle_list_process_ids(&pids[0], C.int(capacity)))
	if count <= 0 {
		return []ProcessSnapshot{}, false
	}

	processes := make([]ProcessSnapshot, 0, count)
	samples := make([]processCPUTimeSample, 0, count)
	type processSampleIndex struct {
		index int
		pid   int32
	}
	indices := make([]processSampleIndex, 0, count)
	for i := 0; i < count; i++ {
		pid := int32(pids[i])
		if pid <= 0 {
			continue
		}
		var record C.lightisle_process_data
		if C.lightisle_read_process(C.int32_t(pid), &record) == 0 {
			continue
		}
		name := C.GoString(&record.name[0])
		if name == "" {
			name = "进程"
		}
		process := ProcessSnapshot{PID: int(pid), Name: name}
		if record.has_task != 0 {
			rss := uint64(record.resident_size)
			process.RSSBytes = &rss
			samples = append(samples, processCPUTimeSample{
				pid: pid, startSec: uint64(record.start_sec), startUsec: uint64(record.start_usec),
				cpuTimeNS: uint64(record.cpu_time_ns),
			})
			indices = append(indices, processSampleIndex{index: len(processes), pid: pid})
		}
		processes = append(processes, process)
	}

	now := time.Now()
	elapsed := time.Duration(0)
	if !c.processesAt.IsZero() {
		elapsed = now.Sub(c.processesAt)
	}
	percentages := c.processCPU.sample(samples, elapsed)
	c.processesAt = now
	for _, item := range indices {
		processes[item.index].CPUPercent = percentages[item.pid]
	}
	processes = sortProcessesByRSS(processes, 256)
	c.processes = append([]ProcessSnapshot(nil), processes...)
	return processes, true
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
	result.DiskIO = c.collectDiskIO()
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

// collectDiskIO reads cumulative per-disk counters and derives rates against
// the previous Collect call. Callers hold c.mu.
func (c *Collector) collectDiskIO() []DiskIOStat {
	raw := make([]C.lightisle_disk_io, C.LIGHTISLE_DISK_IO_CAPACITY)
	count := int(C.lightisle_collect_disk_io(&raw[0], C.LIGHTISLE_DISK_IO_CAPACITY))
	samples := make([]DiskIOStat, 0, count)
	for i := 0; i < count; i++ {
		samples = append(samples, DiskIOStat{
			Device:     C.GoString(&raw[i].name[0]),
			ReadBytes:  uint64(raw[i].read_bytes),
			WriteBytes: uint64(raw[i].write_bytes),
			ReadOps:    uint64(raw[i].read_ops),
			WriteOps:   uint64(raw[i].write_ops),
		})
	}
	out, current, at := computeDiskIORates(samples, c.lastDisk, c.lastDiskAt, time.Now())
	c.lastDisk, c.lastDiskAt = current, at
	return out
}
