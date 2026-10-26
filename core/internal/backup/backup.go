package backup

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/tasks"
	_ "github.com/mattn/go-sqlite3"
)

const maxFiles = 20000
const maxBytes = int64(50) << 30
const maxManifest = int64(32) << 20
const format = "lightisle-complete-backup-v2"
const MetadataBackupType = "metadata"

var (
	ErrBusy                      = errors.New("backup_already_running")
	ErrInvalid                   = errors.New("invalid_backup_location_or_manifest")
	ErrOffline                   = errors.New("share_offline")
	ErrTooLarge                  = errors.New("backup_safety_limit")
	ErrRootChanged               = errors.New("backup_root_binding_changed")
	ErrRootSnapshotMismatch      = errors.New("backup_snapshot_root_mismatch")
	ErrRootDestinationOverlap    = errors.New("backup_destination_overlaps_registered_root")
	ErrPrivateDestinationOverlap = errors.New("backup_destination_overlaps_private_data")
)

type File struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Restore only application settings from a validated, already-open snapshot.
func (s *Service) StartMetadataRestore(snapshot string) error {
	if s.dataDir == "" {
		return ErrInvalid
	}
	if s.destinationRegistry() != nil {
		resolved, err := s.CheckDestination(snapshot)
		if err != nil {
			return err
		}
		snapshot = resolved
	}
	return s.start("restore", snapshot, func(ctx context.Context, destination string) (string, error) {
		return s.restoreMetadataOnly(ctx, destination)
	})
}

// StartMetadataBackup exports the application's consistent SQLite/settings.
func (s *Service) StartMetadataBackup(folder string) error {
	if s.dataDir == "" {
		return ErrInvalid
	}
	if s.destinationRegistry() != nil {
		resolved, err := s.CheckDestination(folder)
		if err != nil {
			return err
		}
		folder = resolved
	}
	return s.start("backup", folder, func(ctx context.Context, destination string) (string, error) {
		return s.createMetadataSnapshot(ctx, destination, "", 0, nil)
	})
}

// The standalone service's destination identity is checked with the same
// physical-volume rules as the scheduler, rather than comparing path strings.
func (s *Service) captureDestinationIdentity(destination string) (destinationIdentity, error) {
	return captureDestinationIdentity(destination, s.readVolumeInfo)
}

func (s *Service) SetJournal(j *tasks.Journal) { s.mu.Lock(); s.journal = j; s.mu.Unlock() }

type Manifest struct {
	Format         string   `json:"format"`
	BackupType     string   `json:"backupType,omitempty"`
	Created        int64    `json:"created"`
	Source         string   `json:"source"`
	PlanID         string   `json:"planID,omitempty"`
	SourceRootID   string   `json:"sourceRootID,omitempty"`
	LogicalRootID  string   `json:"logicalRootID,omitempty"`
	RootGeneration uint64   `json:"rootGeneration,omitempty"`
	Dirs           []string `json:"dirs"`
	Files          []File   `json:"files"`
	Metadata       []File   `json:"metadata,omitempty"`
}
type Status struct {
	Running          bool   `json:"running"`
	Operation        string `json:"operation"`
	Files            int    `json:"files"`
	Bytes            int64  `json:"bytes"`
	LastError        string `json:"lastError,omitempty"`
	RetentionError   string `json:"retentionError,omitempty"`
	RetentionRemoved int    `json:"retentionRemoved,omitempty"`
	LastSnapshot     string `json:"lastSnapshot,omitempty"`
	RestoredMetadata string `json:"restoredMetadata,omitempty"`
	LastDone         int64  `json:"lastDone,omitempty"`
}
type Service struct {
	journal      *tasks.Journal
	files        *files.Manager
	dataDir      string
	ctx          context.Context
	cancel       context.CancelFunc
	wg           sync.WaitGroup
	mu           sync.Mutex
	status       Status
	jobCancel    context.CancelFunc
	journalError string
	// Optional identity reader keeps scheduled-retention tests deterministic.
	// Production uses diskutil and never falls back to a path or device number.
	readVolumeInfo    func(string) (diskutilVolumeInfo, error)
	protectedRegistry *roots.Registry
	startGuard        func() (func(), bool)
}

func New(files *files.Manager, dataDir ...string) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{files: files, ctx: ctx, cancel: cancel}
	if len(dataDir) > 0 {
		s.dataDir = dataDir[0]
	}
	return s
}

// Metadata sqlite files are exported using SQLite's consistent VACUUM INTO
// snapshot, not unsafe reads of an active WAL database. Application credentials
// remain in a private (0600) backup directory selected by the Mac owner. Active
// task runs are omitted from the snapshot: restoring a backup never resumes or
// records an in-flight operation as historical work.
func (s *Service) backupMetadata(ctx context.Context, root *os.Root, stage string, manifest *Manifest) error {
	if s.dataDir == "" {
		return nil
	} // legacy tests without application data
	dataRoot, err := os.OpenRoot(s.dataDir)
	if err != nil {
		return err
	}
	defer dataRoot.Close()
	rootIDs, _, err := readRegisteredRootIDs(dataRoot)
	if err != nil {
		return err
	}
	var metadataBytes int64
	for _, name := range metadataNamesForRootIDs(rootIDs) {
		if err := ctx.Err(); err != nil {
			return err
		}
		source := filepath.Join(s.dataDir, name)
		st, err := dataRoot.Lstat(name)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() {
			return ErrInvalid
		}
		if !strings.HasSuffix(name, ".sqlite") && st.Size() > 4<<20 {
			return ErrTooLarge
		}
		rel := path.Join("metadata", name)
		target := path.Join(stage, rel)
		if err := makeParents(root, target); err != nil {
			return err
		}
		if strings.HasSuffix(name, ".sqlite") {
			// Existing output must not exist for VACUUM INTO.
			uri := (&url.URL{Scheme: "file", Path: source}).String() + "?mode=ro&_busy_timeout=5000"
			db, err := sql.Open("sqlite3", uri)
			if err != nil {
				return err
			}
			_, e := db.ExecContext(ctx, "VACUUM INTO ?", filepath.Join(root.Name(), target))
			ce := db.Close()
			if e != nil {
				return e
			}
			if ce != nil {
				return ce
			}
			if name == "tasks.sqlite" || strings.HasPrefix(name, "tasks-root-") {
				if e := normalizeTaskSnapshot(ctx, filepath.Join(root.Name(), target)); e != nil {
					return e
				}
			}
			if name == "accounts.sqlite" {
				// Browser sessions are ephemeral authorization capabilities.
				// Restoring an account must never resurrect a stolen/revoked
				// cookie from the time the backup was made.
				if e := clearTransientCapabilities(ctx, filepath.Join(root.Name(), target)); e != nil {
					return e
				}
			}
		} else {
			in, e := dataRoot.Open(name)
			if e != nil {
				return e
			}
			out, e := root.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if e != nil {
				in.Close()
				return e
			}
			_, e = io.Copy(out, io.LimitReader(in, 4<<20))
			if e == nil {
				e = out.Sync()
			}
			ce := out.Close()
			in.Close()
			if e != nil {
				return e
			}
			if ce != nil {
				return ce
			}
		}
		f, e := root.Open(target)
		if e != nil {
			return e
		}
		info, e := f.Stat()
		if e != nil {
			f.Close()
			return e
		}
		if info.Size() > maxBytes || info.Size() > maxMetadataSnapshotBytes-metadataBytes {
			f.Close()
			return ErrTooLarge
		}
		h := sha256.New()
		_, e = io.Copy(h, io.LimitReader(cancellationReader{ctx: ctx, source: f}, info.Size()+1))
		f.Close()
		if e != nil {
			return e
		}
		metadataBytes += info.Size()
		manifest.Metadata = append(manifest.Metadata, File{Path: name, Size: info.Size(), SHA256: hex.EncodeToString(h.Sum(nil))})
	}
	if len(manifest.Metadata) > maxMetadataEntries {
		return ErrTooLarge
	}
	return nil
}

// normalizeTaskSnapshot removes attempts that were still running at the backup
// snapshot boundary. The corresponding current summary is left non-running with
// a marker and zero progress, so restoring the metadata cannot imply that work
// was resumed or fabricate a completed result. Completed task history survives.
func normalizeTaskSnapshot(ctx context.Context, file string) error {
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	db, err := sql.Open("sqlite3", uri+"?_journal_mode=DELETE&_busy_timeout=5000")
	if err != nil {
		return err
	}
	db.SetMaxOpenConns(1)
	defer db.Close()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var journalTables int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='task_journal'`).Scan(&journalTables); err != nil {
		return err
	}
	if journalTables != 1 {
		return errors.New("task_journal_missing")
	}
	var historyTables int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='task_runs'`).Scan(&historyTables); err != nil {
		return err
	}
	if historyTables == 1 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM task_runs WHERE running<>0`); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE task_journal SET running=0,processed=0,bytes=0,started_at=0,
		last_done=0,last_error='in_progress_not_restored_from_backup' WHERE running<>0`); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return db.Close()
}

func (s *Service) Close()         { s.cancel(); s.wg.Wait() }
func (s *Service) Status() Status { s.mu.Lock(); defer s.mu.Unlock(); return s.status }

// SetStartGuard installs an optional nonblocking gate around the transition
// from idle to running. A rejected acquisition prevents the job from starting.
// The gate is released immediately after Running becomes true.
func (s *Service) SetStartGuard(guard func() (func(), bool)) {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.startGuard = guard
	s.mu.Unlock()
}

func (s *Service) Cancel() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.status.Running || s.jobCancel == nil {
		return false
	}
	s.jobCancel()
	return true
}
func (s *Service) progress(f int, b int64) {
	s.mu.Lock()
	s.status.Files = f
	s.status.Bytes = b
	s.mu.Unlock()
	if s.journal != nil && f%32 == 0 {
		if err := s.journal.Progress("backup", int64(f), b); err != nil {
			s.recordJournalError("progress", err)
		}
	}
}

func (s *Service) recordJournalError(stage string, err error) {
	if err == nil {
		return
	}
	failure := fmt.Sprintf("task_journal_%s_failed: %v", stage, err)
	slog.Error("persist backup task journal", "stage", stage, "error", err)
	s.mu.Lock()
	if s.journalError == "" {
		s.journalError = failure
	} else if !strings.Contains(s.journalError, failure) {
		s.journalError += "; " + failure
	}
	s.status.LastError = s.journalError
	s.mu.Unlock()
}

func (s *Service) start(kind, target string, work func(context.Context, string) (string, error)) error {
	_, err := s.startWithCompletion(kind, target, work)
	return err
}

// startWithCompletion returns a per-job snapshot after the worker and its
// journal updates finish. Consumers that retain a lease must wait for this
// signal instead of polling the shared service status, which a later job can
// overwrite as soon as the service returns to idle.
func (s *Service) startWithCompletion(kind, target string, work func(context.Context, string) (string, error)) (<-chan Status, error) {
	s.mu.Lock()
	guard := s.startGuard
	s.mu.Unlock()
	var releaseGuard func()
	if guard != nil {
		var ok bool
		releaseGuard, ok = guard()
		if !ok {
			return nil, files.ErrLegacyTransitionBusy
		}
	}
	defer func() {
		if releaseGuard != nil {
			releaseGuard()
		}
	}()

	s.mu.Lock()
	if s.status.Running {
		s.mu.Unlock()
		return nil, ErrBusy
	}
	if s.ctx.Err() != nil {
		s.mu.Unlock()
		return nil, context.Canceled
	}
	if s.journal != nil {
		if err := s.journal.Start("backup", kind); err != nil {
			s.mu.Unlock()
			return nil, err
		}
	}
	job, cancel := context.WithCancel(s.ctx)
	s.jobCancel = cancel
	s.journalError = ""
	s.status = Status{Running: true, Operation: kind}
	completion := make(chan Status, 1)
	s.wg.Add(1)
	s.mu.Unlock()
	if releaseGuard != nil {
		releaseGuard()
		releaseGuard = nil
	}
	go func() {
		var completed Status
		defer func() {
			cancel()
			s.wg.Done()
			completion <- completed
			close(completion)
		}()
		snapshot, err := work(job, target)
		if s.journal != nil {
			current := s.Status()
			if journalErr := s.journal.Progress("backup", int64(current.Files), current.Bytes); journalErr != nil {
				s.recordJournalError("progress", journalErr)
			}
			if journalErr := s.journal.Finish("backup", err); journalErr != nil {
				s.recordJournalError("finish", journalErr)
			}
		}
		s.mu.Lock()
		s.jobCancel = nil
		s.status.Running = false
		s.status.LastDone = time.Now().Unix()
		if snapshot != "" {
			s.status.LastSnapshot = snapshot
		}
		if err != nil {
			s.status.LastError = err.Error()
		} else {
			s.status.LastError = ""
		}
		if s.journalError != "" {
			if s.status.LastError == "" {
				s.status.LastError = s.journalError
			} else {
				s.status.LastError += "; " + s.journalError
			}
		}
		completed = s.status
		s.mu.Unlock()
	}()
	return completion, nil
}

// StartScheduledBackupForSchedule revalidates the persisted destination
// volume and directory identity around opening the output root. The scheduler
// should call this with the exact configuration snapshot it already checked.
func (s *Service) StartScheduledBackupForSchedule(schedule Schedule) error {
	if schedule.BackupType != MetadataBackupType || schedule.EveryHours != 168 || schedule.RetentionCount != 5 {
		return ErrInvalid
	}
	if !schedule.Enabled || !scheduleHasDestinationIdentity(schedule) {
		return ErrDestinationConfirmationRequired
	}
	expected := destinationIdentity{
		VolumeUUID: strings.ToUpper(schedule.DestinationVolumeUUID),
		directoryIdentity: directoryIdentity{
			ID: schedule.DestinationDirectoryID, BirthSec: schedule.DestinationDirectoryBirthSec,
			BirthNsec: schedule.DestinationDirectoryBirthNsec, Generation: schedule.DestinationDirectoryGeneration,
		},
	}
	return s.startScheduledBackupWithType(schedule.Destination, schedule.PlanID, schedule.RetentionCount, &expected, schedule.BackupType)
}

func (s *Service) startScheduledBackupWithType(destination, planID string, retentionCount int, expected *destinationIdentity, backupType string) error {
	if !validPlanID(planID) || retentionCount < 0 || retentionCount > maximumScheduledRetention {
		return ErrRetentionInvalid
	}
	if backupType != MetadataBackupType {
		return ErrInvalid
	}
	if backupType == MetadataBackupType && s.dataDir == "" {
		return ErrInvalid
	}
	if s.destinationRegistry() != nil {
		resolved, err := s.CheckDestination(destination)
		if err != nil {
			return err
		}
		destination = resolved
	}
	return s.start("backup", destination, func(ctx context.Context, folder string) (string, error) {
		return s.createMetadataSnapshot(ctx, folder, planID, retentionCount, expected)
	})
}
func id() string {
	var raw [8]byte
	_, _ = rand.Read(raw[:])
	return hex.EncodeToString(raw[:])
}
func inside(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
func authorizedFolder(folder string) (string, error) {
	if !filepath.IsAbs(folder) {
		return "", ErrInvalid
	}
	resolved, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return "", err
	}
	fi, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", ErrInvalid
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	home, err = filepath.EvalSymlinks(home)
	if err != nil {
		return "", err
	}
	if !(inside(resolved, home) && resolved != home) && !(strings.HasPrefix(resolved, "/Volumes/")) {
		return "", ErrInvalid
	}
	return resolved, nil
}
func disjoint(source, target string) error {
	if inside(source, target) || inside(target, source) {
		return ErrInvalid
	}
	return nil
}
func safeName(name string) bool {
	if name == "" || name == "." || strings.HasPrefix(name, "/") || strings.ContainsRune(name, 92) || strings.ContainsRune(name, 0) {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == "" || part == "." || part == ".." || strings.HasPrefix(part, ".lightisle-") {
			return false
		}
	}
	return path.Clean(name) == name
}
func makeParents(root *os.Root, name string) error {
	dir := path.Dir(name)
	if dir == "." {
		return nil
	}
	pieces := strings.Split(dir, "/")
	for i := range pieces {
		current := strings.Join(pieces[:i+1], "/")
		if err := root.Mkdir(current, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
	}
	return nil
}

type cancellationReader struct {
	ctx    context.Context
	source io.Reader
}

func (r cancellationReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}
func boundedCopy(ctx context.Context, dst *os.File, src *os.File, expected int64) (string, error) {
	if expected < 0 || expected > maxBytes {
		return "", ErrTooLarge
	}
	hash := sha256.New()
	size, err := io.CopyBuffer(io.MultiWriter(dst, hash), io.LimitReader(cancellationReader{ctx: ctx, source: src}, expected+1), make([]byte, 256<<10))
	if err != nil {
		return "", err
	}
	if size != expected {
		return "", errors.New("file_changed_during_backup")
	}
	if err := dst.Sync(); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
func (s *Service) createMetadataSnapshot(ctx context.Context, folder, planID string, retentionCount int, expected *destinationIdentity) (string, error) {
	if s.dataDir == "" || s.files == nil {
		return "", ErrInvalid
	}
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	destination, err := s.CheckDestination(folder)
	if err != nil {
		return "", err
	}
	if err := disjoint(source, destination); err != nil {
		return "", err
	}
	var sourceID string
	var retentionIdentityErr error
	if planID != "" {
		sourceID, err = sourceRootIdentity(source, s.readVolumeInfo)
		if err != nil {
			if retentionCount > 0 {
				retentionIdentityErr = err
			}
			sourceID = ""
		}
	}
	if expected != nil {
		if folder != destination {
			return "", ErrInvalid
		}
		current, err := volumeDirectoryIdentity(destination, s.readVolumeInfo)
		if err != nil || current != *expected {
			return "", ErrDestinationFolderChanged
		}
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		return "", err
	}
	defer root.Close()
	if s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, destination, root); err != nil {
			return "", err
		}
	}
	if expected != nil {
		if err := verifyPinnedDestination(root, destination, *expected, s.readVolumeInfo); err != nil {
			return "", err
		}
	}
	suffix := time.Now().UTC().Format("20060102-150405") + "-" + id()
	stage := ".lightisle-backup-" + suffix + ".partial"
	final := "LightIsle-Backup-" + suffix
	if err := root.Mkdir(stage, 0700); err != nil {
		return "", err
	}
	defer root.RemoveAll(stage)
	manifest := Manifest{Format: format, BackupType: MetadataBackupType, Created: time.Now().Unix(),
		Source: filepath.Base(source), PlanID: planID, SourceRootID: sourceID,
		Dirs: []string{}, Files: []File{}}
	if err := s.backupMetadata(ctx, root, stage, &manifest); err != nil {
		return "", err
	}
	if !metadataCatalogHasAccounts(manifest.Metadata) {
		return "", ErrInvalid
	}
	content, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	if int64(len(content)) > maxManifest {
		return "", ErrTooLarge
	}
	out, err := root.OpenFile(path.Join(stage, "manifest.json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	_, err = out.Write(content)
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if current, online := s.files.State(); !online || current != source {
		return "", ErrOffline
	}
	if sourceID != "" {
		if current, identityErr := sourceRootIdentity(source, s.readVolumeInfo); identityErr != nil || current != sourceID {
			return "", ErrBackupSourceChanged
		}
	}
	if s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, destination, root); err != nil {
			return "", err
		}
	}
	if expected != nil {
		if err := verifyPinnedDestination(root, destination, *expected, s.readVolumeInfo); err != nil {
			return "", err
		}
	}
	if err := root.Rename(stage, final); err != nil {
		return "", err
	}
	finalPath := filepath.Join(destination, final)
	if planID == "" {
		return finalPath, nil
	}
	if err := syncBackupRoot(root); err != nil {
		return finalPath, fmt.Errorf("backup_publish_sync_failed: %w", err)
	}
	if retentionCount > 0 {
		if retentionIdentityErr != nil {
			s.recordRetentionOutcome(0, retentionIdentityErr)
		} else if sourceID == "" {
			s.recordRetentionOutcome(0, ErrRetentionIdentityUnavailable)
		} else if removed, err := retainScheduledSnapshots(ctx, root, destination, final, planID, sourceID, retentionCount, expected, s.readVolumeInfo); err != nil {
			s.recordRetentionOutcome(removed, err)
		} else {
			s.recordRetentionOutcome(removed, nil)
		}
	}
	return finalPath, nil
}

func (s *Service) recordRetentionOutcome(removed int, err error) {
	s.mu.Lock()
	s.status.RetentionRemoved = removed
	if err != nil {
		s.status.RetentionError = err.Error()
		slog.Error("scheduled backup retention did not complete", "removed", removed, "error", err)
	} else {
		s.status.RetentionError = ""
	}
	s.mu.Unlock()
}

func parseManifest(root *os.Root) (Manifest, error) {
	f, err := root.Open("manifest.json")
	if err != nil {
		return Manifest{}, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxManifest+1))
	if err != nil {
		return Manifest{}, err
	}
	if int64(len(data)) > maxManifest {
		return Manifest{}, ErrTooLarge
	}
	var manifest Manifest
	if json.Unmarshal(data, &manifest) != nil {
		return Manifest{}, ErrInvalid
	}
	if err := validateInventoryManifest(manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// Verify and stage application metadata. Never replace a live SQLite database;
// recovered accounts and settings require an explicit, offline migration.
func (s *Service) restoreMetadata(ctx context.Context, input *os.Root, manifest Manifest, suffix string) (string, error) {
	if len(manifest.Metadata) == 0 || s.dataDir == "" {
		return "", nil
	}
	ids, err := metadataRootIDsFromSnapshot(ctx, input, manifest.Metadata)
	if err != nil {
		return "", err
	}
	if err := validateMetadataCatalog(manifest.Metadata, ids); err != nil {
		return "", err
	}
	root, err := os.OpenRoot(s.dataDir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	stage := ".lightisle-metadata-" + suffix + ".partial"
	final := "LightIsle-RestoredMetadata-" + suffix
	if err = root.Mkdir(stage, 0700); err != nil {
		return "", err
	}
	defer root.RemoveAll(stage)
	for _, entry := range manifest.Metadata {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		in, err := input.Open(path.Join("metadata", entry.Path))
		if err != nil {
			return "", err
		}
		out, err := root.OpenFile(path.Join(stage, entry.Path), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			in.Close()
			return "", err
		}
		hash, copyErr := boundedCopy(ctx, out, in, entry.Size)
		closeErr := out.Close()
		in.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if hash != entry.SHA256 {
			return "", errors.New("metadata_checksum_mismatch")
		}
	}
	stagedRoot, err := root.OpenRoot(stage)
	if err != nil {
		return "", err
	}
	defer stagedRoot.Close()
	for i, entry := range manifest.Metadata {
		if entry.Path != "accounts.sqlite" {
			continue
		}
		if err := clearTransientCapabilities(ctx, filepath.Join(root.Name(), stage, entry.Path)); err != nil {
			return "", err
		}
		sha, size, err := hashRootFile(stagedRoot, entry.Path, maxBytes)
		if err != nil {
			return "", err
		}
		manifest.Metadata[i].SHA256 = sha
		manifest.Metadata[i].Size = size
	}
	if err := validateMetadataCatalog(manifest.Metadata, ids); err != nil {
		return "", err
	}
	// Retain per-file checksums in the isolated recovery directory. The
	// offline activation helper must revalidate these before touching any
	// running application's metadata.
	metadataManifest, err := json.Marshal(manifest.Metadata)
	if err != nil {
		return "", err
	}
	manifestFile, err := root.OpenFile(path.Join(stage, "metadata-manifest.json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	_, err = manifestFile.Write(metadataManifest)
	if err == nil {
		err = manifestFile.Sync()
	}
	closeErr := manifestFile.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err = root.Rename(stage, final); err != nil {
		return "", err
	}
	return filepath.Join(s.dataDir, final), nil
}
func (s *Service) restoreMetadataOnly(ctx context.Context, snapshot string) (string, error) {
	if s.dataDir == "" || s.files == nil {
		return "", ErrInvalid
	}
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	location, err := s.CheckDestination(snapshot)
	if err != nil {
		return "", err
	}
	if err := disjoint(source, location); err != nil {
		return "", err
	}
	input, err := os.OpenRoot(location)
	if err != nil {
		return "", err
	}
	defer input.Close()
	if s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, location, input); err != nil {
			return "", err
		}
	}
	manifest, err := parseManifest(input)
	if err != nil {
		return "", err
	}
	if manifest.BackupType != MetadataBackupType || manifest.Format != format ||
		len(manifest.Files) != 0 || len(manifest.Dirs) != 0 || !metadataCatalogHasAccounts(manifest.Metadata) {
		return "", ErrInvalid
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if current, ok := s.files.State(); !ok || current != source {
		return "", ErrOffline
	}
	suffix := time.Now().UTC().Format("20060102-150405") + "-" + id()
	locationSaved, err := s.restoreMetadata(ctx, input, manifest, suffix)
	if err != nil {
		return "", err
	}
	if locationSaved == "" {
		return "", ErrInvalid
	}
	s.mu.Lock()
	s.status.RestoredMetadata = locationSaved
	s.mu.Unlock()
	return locationSaved, nil
}
