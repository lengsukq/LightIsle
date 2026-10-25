//go:build darwin && arm64

package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/system"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// One sample/minute; no filesystem scans or outbound network traffic.
func monitorMetricHistory(ctx context.Context, journal *tasks.Journal) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	collector := &system.Collector{}
	save := func() {
		s, err := collector.Collect()
		if err != nil {
			slog.Warn("metric sample failed", "error", err)
			return
		}
		memory, disk := 0.0, 0.0
		if s.MemoryTotal > 0 {
			memory = 100 * float64(s.MemoryUsed) / float64(s.MemoryTotal)
		}
		if s.DiskTotal > 0 {
			disk = 100 * float64(s.DiskTotal-s.DiskFree) / float64(s.DiskTotal)
		}
		err = journal.RecordMetric(tasks.MetricSample{
			Timestamp: time.Now().Unix(), CPUPercent: s.CPUPercent,
			MemoryPercent: memory, DiskPercent: disk, DownloadBps: s.NetworkDownBps, UploadBps: s.NetworkUpBps,
		})
		if err != nil {
			slog.Warn("metric persistence failed", "error", err)
		}
	}
	save()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			save()
		}
	}
}
