package system

import "time"

// DiskIOStat carries cumulative per-whole-disk I/O counters plus the derived
// per-second rates since the previous sample (nil on first observation).
type DiskIOStat struct {
	Device     string   `json:"device"`
	ReadBytes  uint64   `json:"readBytes"`
	WriteBytes uint64   `json:"writeBytes"`
	ReadOps    uint64   `json:"readOps"`
	WriteOps   uint64   `json:"writeOps"`
	ReadBps    *float64 `json:"readBps,omitempty"`
	WriteBps   *float64 `json:"writeBps,omitempty"`
}

type diskCounter struct{ readBytes, writeBytes uint64 }

// computeDiskIORates converts cumulative counters into byte-per-second rates
// against the previous sample. Counter resets (device replaced), new devices
// and an unmeasurable elapsed time yield nil rates; devices with no recorded
// traffic (synthesized APFS container objects) are filtered out entirely.
func computeDiskIORates(samples []DiskIOStat, prev map[string]diskCounter, prevTime time.Time, now time.Time) ([]DiskIOStat, map[string]diskCounter, time.Time) {
	measured := samples[:0]
	for _, sample := range samples {
		if sample.ReadBytes == 0 && sample.WriteBytes == 0 && sample.ReadOps == 0 && sample.WriteOps == 0 {
			continue
		}
		measured = append(measured, sample)
	}
	current := make(map[string]diskCounter, len(measured))
	for _, sample := range measured {
		current[sample.Device] = diskCounter{sample.ReadBytes, sample.WriteBytes}
	}
	elapsed := now.Sub(prevTime).Seconds()
	if !prevTime.IsZero() && elapsed >= 0.1 {
		for i := range measured {
			sample := &measured[i]
			last, ok := prev[sample.Device]
			if !ok || last.readBytes > sample.ReadBytes || last.writeBytes > sample.WriteBytes {
				continue
			}
			readBps := float64(sample.ReadBytes-last.readBytes) / elapsed
			writeBps := float64(sample.WriteBytes-last.writeBytes) / elapsed
			sample.ReadBps, sample.WriteBps = &readBps, &writeBps
		}
	}
	return measured, current, now
}
