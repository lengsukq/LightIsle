package tasks

import (
	"encoding/json"
	"os"
	"sync"
)

// Threshold holds the user-configurable low-space warning limits. A volume is
// considered low when the free space falls below either limit (absolute size
// or share of capacity); setting one limit to zero disables just that limit.
type Threshold struct {
	FreeMiB int `json:"freeMiB"`
	Percent int `json:"percent"`
}

// DefaultThreshold keeps the historical behavior: warn below 2 GiB or 5%.
var DefaultThreshold = Threshold{FreeMiB: 2048, Percent: 5}

const (
	maxFreeMiB = 1 << 20 // 1 TiB expressed in MiB
	maxPercent = 50
)

// ThresholdStore persists the low-space thresholds as a small JSON file in the
// private data directory so the setting survives Core restarts.
type ThresholdStore struct {
	mu    sync.Mutex
	path  string
	value Threshold
}

func OpenThresholdStore(path string) *ThresholdStore {
	store := &ThresholdStore{path: path, value: DefaultThreshold}
	if data, err := os.ReadFile(path); err == nil && len(data) < 4096 {
		var loaded Threshold
		if json.Unmarshal(data, &loaded) == nil {
			store.value = clampThreshold(loaded)
		}
	}
	return store
}

func clampThreshold(t Threshold) Threshold {
	if t.FreeMiB < 0 {
		t.FreeMiB = 0
	}
	if t.FreeMiB > maxFreeMiB {
		t.FreeMiB = maxFreeMiB
	}
	if t.Percent < 0 {
		t.Percent = 0
	}
	if t.Percent > maxPercent {
		t.Percent = maxPercent
	}
	return t
}

func (s *ThresholdStore) Get() Threshold {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.value
}

// Set validates, persists and returns the applied threshold. Both limits at
// zero would silence the warning entirely and is rejected.
func (s *ThresholdStore) Set(t Threshold) (Threshold, error) {
	t = clampThreshold(t)
	if t.FreeMiB == 0 && t.Percent == 0 {
		return s.Get(), errInvalidThreshold
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.Marshal(t)
	if err != nil {
		return s.value, err
	}
	if err := os.WriteFile(s.path, data, 0600); err != nil {
		return s.value, err
	}
	s.value = t
	return t, nil
}

type thresholdError string

func (e thresholdError) Error() string { return string(e) }

const errInvalidThreshold = thresholdError("invalid_storage_threshold")
