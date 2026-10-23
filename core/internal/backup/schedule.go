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
)

type Schedule struct {
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
}

type Scheduler struct {
	service *Service
	ctx     context.Context
	cancel  context.CancelFunc
	path    string
	mu      sync.Mutex
	config  Schedule
	wg      sync.WaitGroup
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
)

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
		if err := json.Unmarshal(raw, &s.config); err != nil {
			cancel()
			return nil, err
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
func (s *Scheduler) Close() { s.cancel(); s.wg.Wait() }
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
	return s.configure(destination, hours, nil)
}

// ConfigureWithRetention updates the schedule and makes the user's retention
// choice explicit. Zero keeps automatic rotation disabled.
func (s *Scheduler) ConfigureWithRetention(destination string, hours, retentionCount int) error {
	return s.configure(destination, hours, &retentionCount)
}

func (s *Scheduler) configure(destination string, hours int, retentionCount *int) error {
	if hours != 24 && hours != 168 {
		return ErrInvalid
	}
	if retentionCount != nil && (*retentionCount < 0 || *retentionCount > maximumScheduledRetention) {
		return ErrInvalid
	}
	validated, err := s.service.CheckDestination(destination)
	if err != nil {
		return err
	}
	identity, err := s.captureDestinationIdentity(validated)
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
	planID := s.config.PlanID
	if planID == "" {
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
	s.config = Schedule{Enabled: true, EveryHours: hours, Destination: validated,
		DestinationVolumeUUID: identity.VolumeUUID, DestinationDirectoryID: identity.ID,
		DestinationDirectoryBirthSec: identity.BirthSec, DestinationDirectoryBirthNsec: identity.BirthNsec,
		DestinationDirectoryGeneration: identity.Generation, DestinationIdentityStatus: destinationIdentityBound,
		PlanID: planID, RetentionCount: retention,
		LastAttempt: 0, NextRun: now.Add(time.Duration(hours) * time.Hour).Unix()}
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
	if s.service.Status().Running {
		return
	}
	previous := s.config
	hours := s.config.EveryHours
	// Record failed dispatches too: an unplugged destination must be visible
	// after restart, rather than silently retried every minute. Work errors
	// after a successful dispatch remain in the backup task journal.
	err := s.validateScheduledDestination(s.config)
	s.config.LastAttempt = now.Unix()
	s.config.NextRun = now.Add(time.Duration(hours) * time.Hour).Unix()
	s.config.LastError = ""
	if err != nil {
		s.config.LastError = err.Error()
	}
	// Commit the next run before the worker can export the schedule into its
	// metadata snapshot. Never dispatch a job whose schedule cannot be saved.
	if replaced, saveErr := s.writeLocked(); saveErr != nil {
		if !replaced {
			s.config = previous
		}
		s.config.LastError = "backup_schedule_save_failed"
		slog.Error("persist scheduled backup attempt", "error", saveErr)
		return
	}
	if err != nil {
		return
	}
	committed := s.config
	if s.ctx.Err() != nil {
		err = context.Canceled
	} else {
		err = s.service.StartScheduledBackupForSchedule(s.config)
	}
	if errors.Is(err, ErrBusy) || errors.Is(err, context.Canceled) {
		// A local action can acquire the service after Status(). Do not
		// consume this attempt if a worker never started.
		s.config = previous
	} else if err != nil {
		s.config.LastError = err.Error()
	} else {
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

func (s *Scheduler) validateScheduledDestination(schedule Schedule) error {
	destination := schedule.Destination
	validated, err := s.service.CheckDestination(destination)
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
	source, online := s.service.files.State()
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
