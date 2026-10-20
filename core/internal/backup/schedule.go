package backup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Schedule struct {
	Enabled     bool   `json:"enabled"`
	EveryHours  int    `json:"everyHours"`
	Destination string `json:"destination,omitempty"`
	LastAttempt int64  `json:"lastAttempt"`
	NextRun     int64  `json:"nextRun"`
}

type Scheduler struct {
	service *Service
	ctx     context.Context
	cancel  context.CancelFunc
	path    string
	mu      sync.Mutex
	config  Schedule
	wg      sync.WaitGroup
}

func NewScheduler(service *Service, dataDir string) (*Scheduler, error) {
	ctx, cancel := context.WithCancel(service.ctx)
	s := &Scheduler{service: service, path: filepath.Join(dataDir, "backup-schedule.json"), ctx: ctx, cancel: cancel}
	raw, err := os.ReadFile(s.path)
	if err == nil {
		if err := json.Unmarshal(raw, &s.config); err != nil {
			cancel()
			return nil, err
		}
		if s.config.Enabled && (s.config.EveryHours != 24 && s.config.EveryHours != 168) {
			cancel()
			return nil, ErrInvalid
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		cancel()
		return nil, err
	}
	s.wg.Add(1)
	go s.loop()
	return s, nil
}
func (s *Scheduler) Close() { s.cancel(); s.wg.Wait() }
func (s *Scheduler) Status() Schedule {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.config
}
func (s *Scheduler) writeLocked() error {
	data, err := json.MarshalIndent(s.config, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
func (s *Scheduler) Configure(destination string, hours int) error {
	if hours != 24 && hours != 168 {
		return ErrInvalid
	}
	validated, err := authorizedFolder(destination)
	if err != nil {
		return err
	}
	source, ok := s.service.files.State()
	if !ok {
		return ErrOffline
	}
	if err := disjoint(source, validated); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	before := s.config
	now := time.Now()
	s.config = Schedule{Enabled: true, EveryHours: hours, Destination: validated,
		LastAttempt: 0, NextRun: now.Add(time.Duration(hours) * time.Hour).Unix()}
	if err := s.writeLocked(); err != nil {
		s.config = before
		return err
	}
	return nil
}
func (s *Scheduler) Disable() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.config
	s.config = Schedule{}
	if err := s.writeLocked(); err != nil {
		s.config = previous
		return err
	}
	return nil
}
func (s *Scheduler) loop() {
	defer s.wg.Done()
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.runDue(time.Now())
		}
	}
}
func (s *Scheduler) runDue(now time.Time) {
	s.mu.Lock()
	if !s.config.Enabled || s.config.NextRun > now.Unix() {
		s.mu.Unlock()
		return
	}
	if s.service.Status().Running {
		s.mu.Unlock()
		return
	}
	dest := s.config.Destination
	hours := s.config.EveryHours
	// Validate the destination each time; on disk changes the job will be
	// recorded as failed, never redirected to another folder.
	if err := s.service.StartBackup(dest); err == nil {
		s.config.LastAttempt = now.Unix()
		s.config.NextRun = now.Add(time.Duration(hours) * time.Hour).Unix()
		_ = s.writeLocked()
	}
	s.mu.Unlock()
}
