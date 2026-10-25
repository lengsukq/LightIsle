package tasks

import (
	"encoding/json"
	"errors"
	"os"
	"sync"
	"time"
)

// Retention holds the opt-in trash auto-cleanup policy. Auto-purge
// permanently deletes trashed items, so the default is disabled and the
// Mac App is the only surface allowed to change it.
type Retention struct {
	Enabled bool `json:"enabled"`
	Days    int  `json:"days"`
}

const (
	MinRetentionDays = 1
	MaxRetentionDays = 365
)

var ErrInvalidRetention = errors.New("invalid_trash_retention")

// RetentionStore persists the policy as a small JSON file in the private
// data directory so the setting survives Core restarts.
type RetentionStore struct {
	mu    sync.Mutex
	path  string
	value Retention
}

func OpenRetentionStore(path string) *RetentionStore {
	store := &RetentionStore{path: path, value: Retention{Enabled: false, Days: 30}}
	if data, err := os.ReadFile(path); err == nil && len(data) < 4096 {
		var loaded Retention
		if json.Unmarshal(data, &loaded) == nil {
			store.value = clampRetention(loaded)
		}
	}
	return store
}

func clampRetention(r Retention) Retention {
	if r.Days < MinRetentionDays {
		r.Days = MinRetentionDays
	}
	if r.Days > MaxRetentionDays {
		r.Days = MaxRetentionDays
	}
	return r
}

func (s *RetentionStore) Get() Retention {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.value
}

// Cutoff reports the oldest deletion timestamp that should survive. A
// disabled policy returns the zero time and the sweeper skips the round.
func (s *RetentionStore) Cutoff(now time.Time) time.Time {
	value := s.Get()
	if !value.Enabled {
		return time.Time{}
	}
	return now.AddDate(0, 0, -value.Days)
}

// Set validates, persists and returns the applied policy.
func (s *RetentionStore) Set(r Retention) (Retention, error) {
	r = clampRetention(r)
	if !r.Enabled && r.Days == 0 {
		// Clearing the toggle without a day count keeps the previous days.
		r.Days = s.Get().Days
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.Marshal(r)
	if err != nil {
		return s.value, err
	}
	if err := os.WriteFile(s.path, data, 0600); err != nil {
		return s.value, err
	}
	s.value = r
	return r, nil
}
