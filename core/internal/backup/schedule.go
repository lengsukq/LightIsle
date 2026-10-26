package backup

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

type Schedule struct {
	BackupType                     string `json:"backupType,omitempty"`
	RootID                         string `json:"rootID,omitempty"`
	RootGeneration                 uint64 `json:"rootGeneration,omitempty"`
	Enabled                        bool   `json:"enabled"`
	EveryHours                     int    `json:"everyHours"`
	Destination                    string `json:"destination,omitempty"`
	DestinationVolumeUUID          string `json:"destinationVolumeUUID,omitempty"`
	DestinationDirectoryID         string `json:"destinationDirectoryID,omitempty"`
	DestinationDirectoryBirthSec   int64  `json:"destinationDirectoryBirthSec,omitempty"`
	DestinationDirectoryBirthNsec  int64  `json:"destinationDirectoryBirthNsec,omitempty"`
	DestinationDirectoryGeneration uint32 `json:"destinationDirectoryGeneration,omitempty"`
	DestinationIdentityStatus      string `json:"destinationIdentityStatus"`
	PlanID                         string `json:"planID,omitempty"`
	RetentionCount                 int    `json:"retentionCount"`
	LastAttempt                    int64  `json:"lastAttempt"`
	NextRun                        int64  `json:"nextRun"`
	LastError                      string `json:"lastError,omitempty"`
	LastErrorDetail                string `json:"lastErrorDetail,omitempty"`
}

type Scheduler struct {
	service       *Service
	rootPlan      bool
	rootRecord    roots.Root
	rootRegistry  *roots.Registry
	rootProvider  RootBackupProvider
	ctx           context.Context
	cancel        context.CancelFunc
	path          string
	mu            sync.Mutex
	config        Schedule
	persisted     bool
	wg            sync.WaitGroup
	closeErr      error
	jobMu         sync.Mutex
	activeService *Service
	activeDone    chan struct{}
	// Optional fault-injection seam; nil uses the real directory sync.
	syncParentDir func(string) error
	// Optional volume identity reader for deterministic tests. Production uses
	// diskutil on macOS and never falls back to a device number.
	readVolumeInfo func(string) (diskutilVolumeInfo, error)
}

const (
	destinationIdentityBound                = "bound"
	destinationIdentityConfirmationRequired = "confirmation_required"
	maximumScheduledRetention               = 30
	diskutilTimeout                         = 3 * time.Second
	diskutilOutputLimit                     = 256 << 10
)

var (
	ErrDestinationConfirmationRequired = errors.New("backup_destination_confirmation_required")
	ErrDestinationVolumeUnavailable    = errors.New("backup_destination_volume_unavailable")
	ErrDestinationVolumeMismatch       = errors.New("backup_destination_volume_mismatch")
	ErrDestinationFolderChanged        = errors.New("backup_destination_folder_changed")
	ErrRootPlanUnavailable             = errors.New("root_backup_plan_unavailable")
	ErrRootPlanConfigInvalid           = errors.New("root_backup_plan_config_invalid")
	ErrRootPlanConfigUnsafe            = errors.New("root_backup_plan_config_unsafe")
	ErrRootPlanArchiveFailed           = errors.New("root_backup_plan_archive_failed")
)

// RootBackupLease keeps a root's local services alive while a scheduled job
// runs. The provider must return the exact requested root generation.
type RootBackupLease struct {
	Root    roots.Root
	Service *Service
	Close   func() error
}

// RootBackupProvider acquires the local backup service for one registered
// root generation. It must not select a different root if the requested
// generation has gone stale.
type RootBackupProvider func(context.Context, string, uint64) (*RootBackupLease, error)

// Retained for the existing root identity helper and snapshot validation.
// Home edition does not start an independent scheduler for each disk.
func eligibleBackupRoot(root roots.Root) bool {
	return root.ID != "" && root.Generation != 0 && !root.Pending && !root.Compatibility &&
		root.Path == root.Binding.Path && root.Binding.Validate() == nil
}

type diskutilVolumeInfo struct {
	UUID       string
	MountPoint string
}

type directoryIdentity struct {
	ID         string
	BirthSec   int64
	BirthNsec  int64
	Generation uint32
}

type destinationIdentity struct {
	VolumeUUID string
	directoryIdentity
}

func NewScheduler(service *Service, dataDir string) (*Scheduler, error) {
	ctx, cancel := context.WithCancel(service.ctx)
	s := &Scheduler{service: service, path: filepath.Join(dataDir, "backup-schedule.json"), ctx: ctx, cancel: cancel}
	raw, err := os.ReadFile(s.path)
	legacyNeedsConfirmation := false
	if err == nil {
		s.persisted = true
		if err := json.Unmarshal(raw, &s.config); err != nil {
			cancel()
			return nil, err
		}
		if s.config.BackupType != "" && s.config.BackupType != MetadataBackupType {
			cancel()
			return nil, ErrInvalid
		}
		if s.config.Enabled && (s.config.EveryHours != 24 && s.config.EveryHours != 168) {
			cancel()
			return nil, ErrInvalid
		}
		if s.config.RetentionCount < 0 || s.config.RetentionCount > maximumScheduledRetention ||
			(s.config.PlanID != "" && !validPlanID(s.config.PlanID)) {
			cancel()
			return nil, ErrInvalid
		}
		if s.config.Enabled {
			if !scheduleHasDestinationIdentity(s.config) {
				// An old path-only schedule must never bind itself to whichever disk
				// happens to occupy that path after an upgrade or reboot.
				s.config.DestinationIdentityStatus = destinationIdentityConfirmationRequired
				s.config.LastError = ErrDestinationConfirmationRequired.Error()
				s.config.NextRun = 0
				legacyNeedsConfirmation = true
			} else {
				s.config.DestinationIdentityStatus = destinationIdentityBound
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		cancel()
		return nil, err
	}
	if legacyNeedsConfirmation {
		if _, err := s.writeLocked(); err != nil {
			// The in-memory status still blocks dispatch. On the next start the
			// legacy file will be recognized and marked again if this write fails.
			slog.Error("persist backup destination confirmation requirement", "error", err)
		}
	}
	s.wg.Add(1)
	go s.loop()
	return s, nil
}
func (s *Scheduler) Close() error {
	if s.cancel != nil {
		s.cancel()
	}
	s.wg.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closeErr
}

// Root plans acquire a generation-specific service and hold its lease until
// the job has finished. Compatibility plans use their existing service.
func (s *Scheduler) acquireService(ctx context.Context) (*Service, func() error, error) {
	if !s.rootPlan {
		if s.service == nil {
			return nil, nil, ErrRootPlanUnavailable
		}
		return s.service, func() error { return nil }, nil
	}
	if s.rootProvider == nil || s.rootRegistry == nil || s.rootRecord.ID == "" {
		return nil, nil, ErrRootPlanUnavailable
	}
	if ctx == nil || ctx.Err() != nil {
		if ctx != nil {
			return nil, nil, ctx.Err()
		}
		return nil, nil, context.Canceled
	}
	var current *roots.Root
	for _, item := range s.rootRegistry.List() {
		if item.ID == s.rootRecord.ID {
			copy := item
			current = &copy
			break
		}
	}
	if current == nil || !sameRootRecord(*current, s.rootRecord) || !eligibleBackupRoot(*current) {
		return nil, nil, ErrRootChanged
	}
	lease, err := s.rootProvider(ctx, s.rootRecord.ID, s.rootRecord.Generation)
	if err != nil {
		return nil, nil, err
	}
	if lease == nil || lease.Service == nil ||
		!sameRootRecord(lease.Root, s.rootRecord) || lease.Close == nil ||
		lease.Service.rootRegistry != s.rootRegistry || !sameRootRecord(lease.Service.rootRecord, s.rootRecord) {
		var closeErr error
		if lease != nil && lease.Close != nil {
			closeErr = lease.Close()
		}
		return nil, nil, errors.Join(ErrRootChanged, closeErr)
	}
	var once sync.Once
	var closeErr error
	return lease.Service, func() error {
		once.Do(func() { closeErr = lease.Close() })
		return closeErr
	}, nil
}

// Scheduled jobs are async. Releasing the physical-root lease immediately
// after starting would permit rebind/volume removal during the backup.
func (s *Scheduler) trackScheduledJob(completion <-chan Status, release func() error) {
	s.wg.Add(1)
	go func() {
		defer func() {
			if err := release(); err != nil {
				s.mu.Lock()
				s.closeErr = errors.Join(s.closeErr, err)
				s.mu.Unlock()
				s.recordRootPlanError(err)
			}
			s.wg.Done()
		}()
		if completion == nil {
			s.recordRootPlanError(ErrRootPlanUnavailable)
			return
		}
		completed, ok := <-completion
		if !ok {
			return
		}
		if completed.LastError != "" {
			s.recordRootPlanError(errors.New(completed.LastError))
		} else if completed.RetentionError != "" {
			s.recordRootPlanError(fmt.Errorf("backup_retention: %s", completed.RetentionError))
		}
	}()
}

func (s *Scheduler) recordRootPlanError(err error) {
	if err == nil || !s.rootPlan {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.config.RootID != s.rootRecord.ID || s.config.RootGeneration != s.rootRecord.Generation {
		return
	}
	s.config.LastError = err.Error()
	if _, saveErr := s.writeLocked(); saveErr != nil {
		s.closeErr = errors.Join(s.closeErr, saveErr)
		slog.Error("persist root backup job error", "error", saveErr)
	}
}
func (s *Scheduler) Status() Schedule {
	s.mu.Lock()
	defer s.mu.Unlock()
	status := s.config
	if status.Enabled && !scheduleHasDestinationIdentity(status) {
		status.DestinationIdentityStatus = destinationIdentityConfirmationRequired
	} else if scheduleHasDestinationIdentity(status) {
		status.DestinationIdentityStatus = destinationIdentityBound
	}
	return status
}

// replaced distinguishes an uncommitted write from a durability failure after
// rename. Once replaced, memory must retain the configuration now on disk.
func (s *Scheduler) writeLocked() (replaced bool, err error) {
	data, err := json.MarshalIndent(s.config, "", "  ")
	if err != nil {
		return false, err
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".backup-schedule-*")
	if err != nil {
		return false, err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	_, writeErr := f.Write(data)
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if writeErr != nil {
		return false, writeErr
	}
	if closeErr != nil {
		return false, closeErr
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return false, err
	}
	s.persisted = true
	if s.syncParentDir != nil {
		return true, s.syncParentDir(filepath.Dir(s.path))
	}
	dir, err := os.Open(filepath.Dir(s.path))
	if err != nil {
		return true, err
	}
	defer dir.Close()
	return true, dir.Sync()
}
func (s *Scheduler) Configure(destination string, hours int) error {
	return s.configureWithContext(context.Background(), destination, hours, nil)
}

// ConfigureWithRetention updates the schedule and makes the user's retention
// choice explicit. Zero keeps automatic rotation disabled.
func (s *Scheduler) ConfigureWithRetention(destination string, hours, retentionCount int) error {
	return s.configureWithContext(context.Background(), destination, hours, &retentionCount)
}

// ConfigureMetadataWeekly creates the small personal-use settings backup plan.
// Complete-file schedules are preserved and remain available separately.
func (s *Scheduler) ConfigureMetadataWeekly(destination string, retentionCount int) error {
	if s.rootPlan {
		return ErrInvalid
	}
	return s.configureWithType(context.Background(), destination, 168, &retentionCount, MetadataBackupType)
}

func (s *Scheduler) configureWithContext(ctx context.Context, destination string, hours int, retentionCount *int) (returnErr error) {
	return s.configureWithType(ctx, destination, hours, retentionCount, "")
}

func (s *Scheduler) configureWithType(ctx context.Context, destination string, hours int, retentionCount *int, backupType string) (returnErr error) {
	if hours != 24 && hours != 168 {
		return ErrInvalid
	}
	if backupType != "" && backupType != MetadataBackupType {
		return ErrInvalid
	}
	if retentionCount != nil && (*retentionCount < 0 || *retentionCount > maximumScheduledRetention) {
		return ErrInvalid
	}
	service, release, err := s.acquireService(ctx)
	if err != nil {
		return err
	}
	defer func() {
		if releaseErr := release(); releaseErr != nil {
			returnErr = errors.Join(returnErr, releaseErr)
		}
	}()
	validated, err := service.CheckDestination(destination)
	if err != nil {
		return err
	}
	identity, err := s.captureDestinationIdentity(validated)
	if err != nil {
		return err
	}
	source, ok := service.files.State()
	if !ok {
		return ErrOffline
	}
	if err := disjoint(source, validated); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	before := s.config
	planID := s.config.PlanID
	if planID == "" || s.config.BackupType != backupType {
		planID, err = newSchedulePlanID()
		if err != nil {
			return err
		}
	}
	retention := s.config.RetentionCount
	if retentionCount != nil {
		retention = *retentionCount
	}
	now := time.Now()
	s.config = Schedule{Enabled: true, EveryHours: hours, BackupType: backupType, Destination: validated,
		DestinationVolumeUUID: identity.VolumeUUID, DestinationDirectoryID: identity.ID,
		DestinationDirectoryBirthSec: identity.BirthSec, DestinationDirectoryBirthNsec: identity.BirthNsec,
		DestinationDirectoryGeneration: identity.Generation, DestinationIdentityStatus: destinationIdentityBound,
		PlanID: planID, RetentionCount: retention,
		LastAttempt: 0, NextRun: now.Add(time.Duration(hours) * time.Hour).Unix()}
	if s.rootPlan {
		s.config.RootID = s.rootRecord.ID
		s.config.RootGeneration = s.rootRecord.Generation
	}
	if replaced, err := s.writeLocked(); err != nil {
		if !replaced {
			s.config = before
		}
		return err
	}
	return nil
}
func (s *Scheduler) Disable() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.config
	s.config.Enabled = false
	s.config.NextRun = 0
	s.config.LastError = ""
	s.config.LastErrorDetail = ""
	if replaced, err := s.writeLocked(); err != nil {
		if !replaced {
			s.config = previous
		}
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
	defer s.mu.Unlock()
	if !s.config.Enabled || s.ctx.Err() != nil {
		return
	}
	if s.rootPlan && (s.config.RootID != s.rootRecord.ID || s.config.RootGeneration != s.rootRecord.Generation) {
		s.config.Enabled = false
		s.config.NextRun = 0
		s.config.LastError = ErrRootChanged.Error()
		if _, err := s.writeLocked(); err != nil {
			slog.Error("persist stale root backup plan", "error", err)
		}
		return
	}
	if !scheduleHasDestinationIdentity(s.config) {
		if s.config.DestinationIdentityStatus != destinationIdentityConfirmationRequired ||
			s.config.LastError != ErrDestinationConfirmationRequired.Error() || s.config.NextRun != 0 {
			s.config.DestinationIdentityStatus = destinationIdentityConfirmationRequired
			s.config.LastError = ErrDestinationConfirmationRequired.Error()
			s.config.NextRun = 0
			if _, err := s.writeLocked(); err != nil {
				slog.Error("persist backup destination confirmation requirement", "error", err)
			}
		}
		return
	}
	if s.config.NextRun > now.Unix() {
		return
	}
	service, release, err := s.acquireService(s.ctx)
	if err != nil {
		s.recordDispatchFailureLocked(now, err)
		return
	}
	if service.Status().Running {
		if releaseErr := release(); releaseErr != nil {
			s.config.LastError = releaseErr.Error()
			if _, saveErr := s.writeLocked(); saveErr != nil {
				s.closeErr = errors.Join(s.closeErr, saveErr)
			}
		}
		return
	}
	previous := s.config
	hours := s.config.EveryHours
	// Record failed dispatches too: an unplugged destination must be visible
	// after restart, rather than silently retried every minute. Work errors
	// after a successful dispatch remain in the backup task journal.
	err = s.validateScheduledDestinationFor(service, s.config)
	s.config.LastAttempt = now.Unix()
	s.config.NextRun = now.Add(time.Duration(hours) * time.Hour).Unix()
	s.config.LastError = ""
	if err != nil {
		s.config.LastError = err.Error()
	}
	// Commit the next run before the worker can export the schedule into its
	// metadata snapshot. Never dispatch a job whose schedule cannot be saved.
	if replaced, saveErr := s.writeLocked(); saveErr != nil {
		releaseErr := release()
		if !replaced {
			s.config = previous
		}
		s.config.LastError = errors.Join(errors.New("backup_schedule_save_failed"), saveErr, releaseErr).Error()
		slog.Error("persist scheduled backup attempt", "error", saveErr)
		return
	}
	if err != nil {
		releaseErr := release()
		if releaseErr != nil {
			s.config.LastError = errors.Join(err, releaseErr).Error()
			if _, saveErr := s.writeLocked(); saveErr != nil {
				s.closeErr = errors.Join(s.closeErr, saveErr)
			}
		}
		return
	}
	committed := s.config
	var completion <-chan Status
	if s.ctx.Err() != nil {
		err = context.Canceled
		if releaseErr := release(); releaseErr != nil {
			err = errors.Join(err, releaseErr)
		}
	} else if s.rootPlan {
		completion, err = service.startScheduledRootBackupForSchedule(s.ctx, s.config)
	} else {
		err = service.StartScheduledBackupForSchedule(s.config)
	}
	if errors.Is(err, ErrBusy) || errors.Is(err, context.Canceled) {
		releaseErr := release()
		// A local action can acquire the service after Status(). Do not
		// consume this attempt if a worker never started.
		s.config = previous
		if releaseErr != nil {
			s.config.LastError = releaseErr.Error()
		}
	} else if err != nil {
		releaseErr := release()
		s.config.LastError = errors.Join(err, releaseErr).Error()
	} else {
		if s.rootPlan {
			s.trackScheduledJob(completion, release)
		} else {
			release()
		}
		return
	}
	if replaced, saveErr := s.writeLocked(); saveErr != nil {
		if !replaced {
			s.config = committed
		}
		s.config.LastError = "backup_schedule_save_failed"
		slog.Error("persist scheduled backup dispatch failure", "error", saveErr)
	}
}

func (s *Scheduler) recordDispatchFailureLocked(now time.Time, err error) {
	previous := s.config
	s.config.LastAttempt = now.Unix()
	interval := s.config.EveryHours
	if interval != 24 && interval != 168 {
		interval = 24
	}
	s.config.NextRun = now.Add(time.Duration(interval) * time.Hour).Unix()
	s.config.LastError = err.Error()
	if replaced, saveErr := s.writeLocked(); saveErr != nil {
		if !replaced {
			s.config = previous
		}
		s.config.LastError = "backup_schedule_save_failed"
		slog.Error("persist root backup plan dispatch failure", "error", saveErr)
	}
}

func (s *Scheduler) validateScheduledDestination(schedule Schedule) error {
	if s.service == nil {
		return ErrInvalid
	}
	return s.validateScheduledDestinationFor(s.service, schedule)
}

func (s *Scheduler) validateScheduledDestinationFor(service *Service, schedule Schedule) error {
	destination := schedule.Destination
	validated, err := service.CheckDestination(destination)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrDestinationVolumeUnavailable
		}
		return err
	}
	// Do not follow a path changed into a symlink to another destination.
	if validated != destination {
		return ErrInvalid
	}
	current, err := s.captureDestinationIdentity(destination)
	if err != nil {
		return err
	}
	if current.VolumeUUID != schedule.DestinationVolumeUUID {
		return ErrDestinationVolumeMismatch
	}
	if current.ID != schedule.DestinationDirectoryID ||
		current.BirthSec != schedule.DestinationDirectoryBirthSec ||
		current.BirthNsec != schedule.DestinationDirectoryBirthNsec ||
		current.Generation != schedule.DestinationDirectoryGeneration {
		return ErrDestinationFolderChanged
	}
	source, online := service.files.State()
	if !online {
		return ErrOffline
	}
	return disjoint(source, validated)
}

func scheduleHasDestinationIdentity(schedule Schedule) bool {
	return validUUID(schedule.DestinationVolumeUUID) && validDirectoryIdentity(directoryIdentity{
		ID: schedule.DestinationDirectoryID, BirthSec: schedule.DestinationDirectoryBirthSec,
		BirthNsec: schedule.DestinationDirectoryBirthNsec, Generation: schedule.DestinationDirectoryGeneration,
	}) &&
		validPlanID(schedule.PlanID) && schedule.RetentionCount >= 0 && schedule.RetentionCount <= maximumScheduledRetention
}

func validDirectoryIdentity(identity directoryIdentity) bool {
	if len(identity.ID) != 16 {
		return false
	}
	decoded, err := hex.DecodeString(identity.ID)
	if err != nil || len(decoded) != 8 || identity.BirthNsec < 0 || identity.BirthNsec >= 1_000_000_000 {
		return false
	}
	// Inode numbers may be reused after a directory is removed. Require at
	// least one filesystem-provided creation/generation value to distinguish a
	// replacement on filesystems that expose those fields.
	return identity.BirthSec != 0 || identity.BirthNsec != 0 || identity.Generation != 0
}

func (s *Scheduler) captureDestinationIdentity(destination string) (destinationIdentity, error) {
	return captureDestinationIdentity(destination, s.readVolumeInfo)
}

func captureDestinationIdentity(destination string, reader func(string) (diskutilVolumeInfo, error)) (destinationIdentity, error) {
	resolved, err := filepath.EvalSymlinks(destination)
	if err != nil || resolved != destination {
		return destinationIdentity{}, ErrDestinationVolumeUnavailable
	}
	before, err := readDirectoryIdentity(destination)
	if err != nil {
		return destinationIdentity{}, ErrDestinationVolumeUnavailable
	}
	if reader == nil {
		reader = readDiskutilVolumeInfo
	}
	volume, err := reader(destination)
	if err != nil || !validUUID(volume.UUID) || !filepath.IsAbs(volume.MountPoint) || filepath.Clean(volume.MountPoint) != volume.MountPoint {
		return destinationIdentity{}, ErrDestinationVolumeUnavailable
	}
	after, err := readDirectoryIdentity(destination)
	if err != nil || before != after {
		return destinationIdentity{}, ErrDestinationFolderChanged
	}
	return destinationIdentity{VolumeUUID: strings.ToUpper(volume.UUID), directoryIdentity: after}, nil
}

func verifyScheduleDestinationIdentity(schedule Schedule) error {
	if !scheduleHasDestinationIdentity(schedule) {
		return ErrDestinationConfirmationRequired
	}
	current, err := captureDestinationIdentity(schedule.Destination, nil)
	if err != nil {
		return err
	}
	if current.VolumeUUID != schedule.DestinationVolumeUUID {
		return ErrDestinationVolumeMismatch
	}
	if current.ID != schedule.DestinationDirectoryID ||
		current.BirthSec != schedule.DestinationDirectoryBirthSec ||
		current.BirthNsec != schedule.DestinationDirectoryBirthNsec ||
		current.Generation != schedule.DestinationDirectoryGeneration {
		return ErrDestinationFolderChanged
	}
	return nil
}

func readDirectoryIdentity(path string) (directoryIdentity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return directoryIdentity{}, err
	}
	if !info.IsDir() {
		return directoryIdentity{}, ErrInvalid
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Ino == 0 {
		return directoryIdentity{}, ErrDestinationVolumeUnavailable
	}
	identity := directoryIdentity{
		ID:         fmt.Sprintf("%016x", stat.Ino),
		BirthSec:   stat.Birthtimespec.Sec,
		BirthNsec:  stat.Birthtimespec.Nsec,
		Generation: stat.Gen,
	}
	if !validDirectoryIdentity(identity) {
		return directoryIdentity{}, ErrDestinationVolumeUnavailable
	}
	return identity, nil
}

func newSchedulePlanID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func validPlanID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, r := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return false
			}
			continue
		}
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return false
		}
	}
	return true
}

func readDiskutilVolumeInfo(path string) (diskutilVolumeInfo, error) {
	if runtime.GOOS != "darwin" || !filepath.IsAbs(path) {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	var filesystem syscall.Statfs_t
	if err := syscall.Statfs(path, &filesystem); err != nil {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	mountPoint := filepath.Clean(cStringFromInt8(filesystem.Mntonname[:]))
	if !filepath.IsAbs(mountPoint) {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), diskutilTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/sbin/diskutil", "info", "-plist", mountPoint)
	stdout := &boundedOutput{limit: diskutilOutputLimit}
	stderr := &boundedOutput{limit: diskutilOutputLimit}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil || ctx.Err() != nil || stdout.exceeded || stderr.exceeded {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	info, err := parseDiskutilVolumeInfo(stdout.data.Bytes())
	if err != nil || !validUUID(info.UUID) || !filepath.IsAbs(info.MountPoint) ||
		filepath.Clean(info.MountPoint) != mountPoint {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	info.UUID = strings.ToUpper(info.UUID)
	return info, nil
}

func cStringFromInt8(value []int8) string {
	end := 0
	for end < len(value) && value[end] != 0 {
		end++
	}
	bytesValue := make([]byte, end)
	for i := 0; i < end; i++ {
		bytesValue[i] = byte(value[i])
	}
	return string(bytesValue)
}

type boundedOutput struct {
	data     bytes.Buffer
	limit    int
	exceeded bool
}

func (b *boundedOutput) Write(p []byte) (int, error) {
	if len(p) > b.limit-b.data.Len() {
		b.exceeded = true
		return 0, errors.New("diskutil_output_limit")
	}
	return b.data.Write(p)
}

func parseDiskutilVolumeInfo(data []byte) (diskutilVolumeInfo, error) {
	if len(data) == 0 || len(data) > diskutilOutputLimit {
		return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	for {
		token, err := decoder.Token()
		if err != nil {
			return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
		}
		start, ok := token.(xml.StartElement)
		if ok && start.Name.Local == "dict" {
			values, err := parsePlistDict(decoder)
			if err != nil {
				return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
			}
			info := diskutilVolumeInfo{UUID: values["VolumeUUID"], MountPoint: values["MountPoint"]}
			if !validUUID(info.UUID) || !filepath.IsAbs(info.MountPoint) {
				return diskutilVolumeInfo{}, ErrDestinationVolumeUnavailable
			}
			return info, nil
		}
	}
}

func parsePlistDict(decoder *xml.Decoder) (map[string]string, error) {
	values := make(map[string]string)
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		switch token := token.(type) {
		case xml.EndElement:
			if token.Name.Local == "dict" {
				return values, nil
			}
		case xml.StartElement:
			if token.Name.Local != "key" {
				if err := decoder.Skip(); err != nil {
					return nil, err
				}
				continue
			}
			var key string
			if err := decoder.DecodeElement(&key, &token); err != nil {
				return nil, err
			}
			valueStart, err := nextPlistStart(decoder)
			if err != nil {
				return nil, err
			}
			if valueStart.Name.Local == "string" {
				var value string
				if err := decoder.DecodeElement(&value, &valueStart); err != nil {
					return nil, err
				}
				values[key] = value
			} else if err := decoder.Skip(); err != nil {
				return nil, err
			}
		}
	}
}

func nextPlistStart(decoder *xml.Decoder) (xml.StartElement, error) {
	for {
		token, err := decoder.Token()
		if err != nil {
			return xml.StartElement{}, err
		}
		switch token := token.(type) {
		case xml.StartElement:
			return token, nil
		case xml.CharData:
			if strings.TrimSpace(string(token)) != "" {
				return xml.StartElement{}, ErrDestinationVolumeUnavailable
			}
		}
	}
}
