//go:build darwin && arm64

package system

import (
	"context"
	"os/exec"
	"sync"
	"time"
)

var (
	powerCacheMu sync.Mutex
	powerCached  PowerStatus
	powerCachedAt time.Time
)

// CollectPowerStatus queries macOS native `/usr/bin/pmset -g batt` with a short
// timeout and 5-second cache so background health checks and system dashboards
// never spawn redundant subprocesses.
func CollectPowerStatus() PowerStatus {
	powerCacheMu.Lock()
	if !powerCachedAt.IsZero() && time.Since(powerCachedAt) < 5*time.Second {
		cached := powerCached
		powerCacheMu.Unlock()
		return cached
	}
	powerCacheMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/pmset", "-g", "batt").Output()
	if err != nil {
		return PowerStatus{}
	}
	parsed := ParsePmsetBatt(string(out))

	powerCacheMu.Lock()
	powerCached = parsed
	powerCachedAt = time.Now()
	powerCacheMu.Unlock()
	return parsed
}
