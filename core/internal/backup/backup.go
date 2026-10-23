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
const legacyFormat = "lightisle-file-backup-v1"

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

func (s *Service) SetJournal(j *tasks.Journal) { s.mu.Lock(); s.journal = j; s.mu.Unlock() }

type Manifest struct {
	Format         string   `json:"format"`
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
	rootRegistry      *roots.Registry
	protectedRegistry *roots.Registry
	rootRecord        roots.Root
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
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status.Running {
		return ErrBusy
	}
	if s.ctx.Err() != nil {
		return context.Canceled
	}
	if s.journal != nil {
		if err := s.journal.Start("backup", kind); err != nil {
			return err
		}
	}
	job, cancel := context.WithCancel(s.ctx)
	s.jobCancel = cancel
	s.journalError = ""
	s.status = Status{Running: true, Operation: kind}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer cancel()
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
		s.mu.Unlock()
	}()
	return nil
}
func (s *Service) StartBackup(folder string) error {
	if s.rootRegistry == nil {
		if s.destinationRegistry() != nil {
			resolved, err := s.CheckDestination(folder)
			if err != nil {
				return err
			}
			folder = resolved
		}
		return s.start("backup", folder, s.create)
	}
	lease, err := s.acquireBoundRoot(context.Background())
	if err != nil {
		return err
	}
	resolved, err := s.validateExternalFolder(context.Background(), folder, nil)
	if err == nil {
		err = s.validateBoundRoot(context.Background(), lease)
	}
	if err != nil {
		_ = lease.Close()
		return err
	}
	err = s.start("backup", resolved, func(ctx context.Context, target string) (string, error) {
		defer lease.Close()
		return s.createWithRoot(ctx, target, lease)
	})
	if err != nil {
		_ = lease.Close()
	}
	return err
}

func (s *Service) StartRestore(snapshot string) error {
	if s.rootRegistry == nil {
		if s.destinationRegistry() != nil {
			resolved, err := s.CheckDestination(snapshot)
			if err != nil {
				return err
			}
			snapshot = resolved
		}
		return s.start("restore", snapshot, s.restore)
	}
	lease, err := s.acquireBoundRoot(context.Background())
	if err != nil {
		return err
	}
	resolved, err := s.validateExternalFolder(context.Background(), snapshot, nil)
	if err == nil {
		err = s.validateBoundRoot(context.Background(), lease)
	}
	if err == nil {
		var root *os.Root
		root, err = os.OpenRoot(resolved)
		if err == nil {
			var manifest Manifest
			manifest, err = parseManifest(root)
			if err == nil {
				err = s.validateRootManifest(manifest, lease.Binding)
			}
			if err == nil {
				err = s.validateSnapshotRootCatalog(context.Background(), root, manifest)
			}
			_ = root.Close()
		}
	}
	if err != nil {
		_ = lease.Close()
		return err
	}
	err = s.start("restore", resolved, func(ctx context.Context, target string) (string, error) {
		defer lease.Close()
		return s.restoreWithRoot(ctx, target, lease)
	})
	if err != nil {
		_ = lease.Close()
	}
	return err
}

// StartScheduledBackup starts a plan-owned backup. A zero retention count
// records plan ownership when the source volume identity is available, but
// never deletes snapshots. Manual StartBackup deliberately has no retention
// behavior.
func (s *Service) StartScheduledBackup(destination, planID string, retentionCount int) error {
	if s.rootRegistry != nil {
		return ErrInvalid // multi-root schedules remain v1 until they carry a root binding.
	}
	return s.startScheduledBackup(destination, planID, retentionCount, nil)
}

// StartScheduledBackupForSchedule revalidates the persisted destination
// volume and directory identity around opening the output root. The scheduler
// should call this with the exact configuration snapshot it already checked.
func (s *Service) StartScheduledBackupForSchedule(schedule Schedule) error {
	if s.rootRegistry != nil {
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
	return s.startScheduledBackup(schedule.Destination, schedule.PlanID, schedule.RetentionCount, &expected)
}

func (s *Service) startScheduledBackup(destination, planID string, retentionCount int, expected *destinationIdentity) error {
	if !validPlanID(planID) || retentionCount < 0 || retentionCount > maximumScheduledRetention {
		return ErrRetentionInvalid
	}
	if s.destinationRegistry() != nil {
		resolved, err := s.CheckDestination(destination)
		if err != nil {
			return err
		}
		destination = resolved
	}
	return s.start("backup", destination, func(ctx context.Context, folder string) (string, error) {
		return s.createWithPlan(ctx, folder, planID, retentionCount, expected)
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
func (s *Service) create(ctx context.Context, folder string) (string, error) {
	return s.createWithPlan(ctx, folder, "", 0, nil)
}

func (s *Service) createWithPlan(ctx context.Context, folder, planID string, retentionCount int, expectedDestination *destinationIdentity) (string, error) {
	return s.createWithScope(ctx, folder, planID, retentionCount, expectedDestination, nil)
}

func (s *Service) createWithRoot(ctx context.Context, folder string, lease *roots.Lease) (string, error) {
	return s.createWithScope(ctx, folder, "", 0, nil, lease)
}

func (s *Service) createWithScope(ctx context.Context, folder, planID string, retentionCount int,
	expectedDestination *destinationIdentity, lease *roots.Lease) (string, error) {
	if lease != nil {
		if err := s.validateBoundRoot(ctx, lease); err != nil {
			return "", err
		}
	}
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	if lease != nil && source != s.rootRecord.Path {
		return "", ErrRootChanged
	}
	sourceRootID := ""
	var retentionIdentityErr error
	if lease != nil {
		var identityErr error
		sourceRootID, identityErr = sourceRootIDForBinding(lease.Binding)
		if identityErr != nil {
			return "", identityErr
		}
	} else if planID != "" {
		if identity, identityErr := sourceRootIdentity(source, s.readVolumeInfo); identityErr == nil {
			sourceRootID = identity
		} else if retentionCount > 0 {
			retentionIdentityErr = fmt.Errorf("%w: %v", ErrRetentionIdentityUnavailable, identityErr)
		}
	}
	destination, err := authorizedFolder(folder)
	if err != nil {
		return "", err
	}
	if lease != nil || s.destinationRegistry() != nil {
		destination, err = s.validateExternalFolder(ctx, destination, nil)
		if err != nil {
			return "", err
		}
	}
	if expectedDestination != nil {
		if destination != folder {
			return "", ErrInvalid
		}
		observed, identityErr := volumeDirectoryIdentity(destination, s.readVolumeInfo)
		if identityErr != nil || observed != *expectedDestination {
			return "", ErrDestinationFolderChanged
		}
	} else if retentionCount > 0 {
		if observed, identityErr := volumeDirectoryIdentity(destination, s.readVolumeInfo); identityErr == nil {
			expectedDestination = &observed
		} else {
			retentionIdentityErr = errors.Join(retentionIdentityErr,
				fmt.Errorf("%w: destination: %v", ErrRetentionIdentityUnavailable, identityErr))
		}
	}
	if err := disjoint(source, destination); err != nil {
		return "", err
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		return "", err
	}
	defer root.Close()
	if lease != nil || s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, destination, root); err != nil {
			return "", err
		}
	}
	if expectedDestination != nil {
		if err := verifyPinnedDestination(root, destination, *expectedDestination, s.readVolumeInfo); err != nil {
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
	manifest := Manifest{Format: format, Created: time.Now().Unix(), Source: filepath.Base(source), PlanID: planID, SourceRootID: sourceRootID, Dirs: []string{}, Files: []File{}}
	if lease != nil {
		manifest.LogicalRootID = s.rootRecord.ID
		manifest.RootGeneration = s.rootRecord.Generation
	}
	queue := []string{"."}
	var total int64
	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if current, ok := s.files.State(); !ok || current != source {
			return "", ErrOffline
		}
		current := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		cursor := ""
		for {
			if err := ctx.Err(); err != nil {
				return "", err
			}
			entries, next, e := s.files.Page(current, cursor, 100)
			if e != nil {
				return "", e
			}
			for _, entry := range entries {
				if len(manifest.Files)+len(manifest.Dirs) >= maxFiles {
					return "", ErrTooLarge
				}
				if !safeName(entry.Path) {
					return "", ErrInvalid
				}
				target := path.Join(stage, "data", entry.Path)
				if entry.Type == "folder" {
					if err := makeParents(root, target+"/placeholder"); err != nil {
						return "", err
					}
					if err := root.Mkdir(target, 0700); err != nil && !errors.Is(err, os.ErrExist) {
						return "", err
					}
					manifest.Dirs = append(manifest.Dirs, entry.Path)
					queue = append(queue, entry.Path)
					continue
				}
				total += entry.Size
				if total > maxBytes {
					return "", ErrTooLarge
				}
				in, info, e := s.files.Read(entry.Path)
				if e != nil {
					return "", e
				}
				if info.Size() != entry.Size {
					in.Close()
					return "", errors.New("file_changed_during_backup")
				}
				if err := makeParents(root, target); err != nil {
					in.Close()
					return "", err
				}
				out, e := root.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
				if e != nil {
					in.Close()
					return "", e
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
				manifest.Files = append(manifest.Files, File{Path: entry.Path, Size: entry.Size, SHA256: hash})
				s.progress(len(manifest.Files), total)
			}
			if next == "" {
				break
			}
			cursor = next
		}
	}
	if current, ok := s.files.State(); !ok || current != source {
		return "", ErrOffline
	}
	if expectedDestination != nil {
		if err := verifyPinnedDestination(root, destination, *expectedDestination, s.readVolumeInfo); err != nil {
			return "", err
		}
	}
	if planID != "" && sourceRootID != "" {
		currentSourceRootID, identityErr := sourceRootIdentity(source, s.readVolumeInfo)
		if identityErr != nil {
			if retentionCount > 0 {
				retentionIdentityErr = errors.Join(retentionIdentityErr,
					fmt.Errorf("%w: source recheck: %v", ErrRetentionIdentityUnavailable, identityErr))
			}
			sourceRootID = ""
			manifest.SourceRootID = ""
		} else if currentSourceRootID != sourceRootID {
			return "", ErrBackupSourceChanged
		}
	}
	if err := s.backupMetadata(ctx, root, stage, &manifest); err != nil {
		return "", err
	}
	if lease != nil {
		if err := s.validateStagedRootCatalog(ctx, root, stage, manifest); err != nil {
			return "", err
		}
	}
	if planID != "" && sourceRootID != "" {
		currentSourceRootID, identityErr := sourceRootIdentity(source, s.readVolumeInfo)
		if identityErr != nil {
			if retentionCount > 0 {
				retentionIdentityErr = errors.Join(retentionIdentityErr,
					fmt.Errorf("%w: source recheck: %v", ErrRetentionIdentityUnavailable, identityErr))
			}
			sourceRootID = ""
			manifest.SourceRootID = ""
		} else if currentSourceRootID != sourceRootID {
			return "", ErrBackupSourceChanged
		}
	}
	contents, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	if int64(len(contents)) > maxManifest {
		return "", ErrTooLarge
	}
	out, err := root.OpenFile(path.Join(stage, "manifest.json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	_, err = out.Write(contents)
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
	if lease != nil || s.destinationRegistry() != nil {
		if lease != nil {
			if err := s.validateBoundRoot(ctx, lease); err != nil {
				return "", err
			}
		}
		if _, err := s.validateExternalFolder(ctx, destination, root); err != nil {
			return "", err
		}
		if lease != nil {
			if err := s.validateStagedRootCatalog(ctx, root, stage, manifest); err != nil {
				return "", err
			}
		}
	}
	if expectedDestination != nil {
		if err := verifyPinnedDestination(root, destination, *expectedDestination, s.readVolumeInfo); err != nil {
			return "", err
		}
	}
	if err := root.Rename(stage, final); err != nil {
		return "", err
	}
	finalPath := filepath.Join(destination, final)
	if planID == "" {
		if lease != nil {
			if err := syncBackupRoot(root); err != nil {
				return finalPath, fmt.Errorf("backup_publish_sync_failed: %w", err)
			}
		}
		return finalPath, nil
	}
	if err := syncBackupRoot(root); err != nil {
		return finalPath, fmt.Errorf("backup_publish_sync_failed: %w", err)
	}
	if retentionCount > 0 {
		if retentionIdentityErr != nil {
			s.recordRetentionOutcome(0, retentionIdentityErr)
		} else if sourceRootID == "" {
			s.recordRetentionOutcome(0, ErrRetentionIdentityUnavailable)
		} else if removed, retentionErr := retainScheduledSnapshots(ctx, root, destination, final, planID, sourceRootID, retentionCount, expectedDestination, s.readVolumeInfo); retentionErr != nil {
			s.recordRetentionOutcome(removed, retentionErr)
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
func (s *Service) restore(ctx context.Context, snapshot string) (string, error) {
	return s.restoreWithScope(ctx, snapshot, nil)
}

func (s *Service) restoreWithRoot(ctx context.Context, snapshot string, lease *roots.Lease) (string, error) {
	return s.restoreWithScope(ctx, snapshot, lease)
}

func (s *Service) restoreWithScope(ctx context.Context, snapshot string, lease *roots.Lease) (string, error) {
	if lease != nil {
		if err := s.validateBoundRoot(ctx, lease); err != nil {
			return "", err
		}
	}
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	if lease != nil && source != s.rootRecord.Path {
		return "", ErrRootChanged
	}
	location, err := authorizedFolder(snapshot)
	if err != nil {
		return "", err
	}
	if lease != nil || s.destinationRegistry() != nil {
		location, err = s.validateExternalFolder(ctx, location, nil)
		if err != nil {
			return "", err
		}
	}
	if err := disjoint(source, location); err != nil {
		return "", err
	}
	input, err := os.OpenRoot(location)
	if err != nil {
		return "", err
	}
	defer input.Close()
	if lease != nil || s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, location, input); err != nil {
			return "", err
		}
	}
	manifest, err := parseManifest(input)
	if err != nil {
		return "", err
	}
	if lease != nil {
		if err := s.validateRootManifest(manifest, lease.Binding); err != nil {
			return "", err
		}
		if err := s.validateSnapshotRootCatalog(ctx, input, manifest); err != nil {
			return "", err
		}
	}
	output, err := os.OpenRoot(source)
	if err != nil {
		return "", err
	}
	defer output.Close()
	if lease != nil {
		rootInfo, rootErr := lease.Root.Stat(".")
		outputInfo, outputErr := output.Stat(".")
		if rootErr != nil || outputErr != nil || !os.SameFile(rootInfo, outputInfo) {
			return "", ErrRootChanged
		}
	}
	suffix := time.Now().UTC().Format("20060102-150405") + "-" + id()
	stage := ".lightisle-recovery-" + suffix + ".partial"
	final := "LightIsle-Restored-" + suffix
	if err := output.Mkdir(stage, 0700); err != nil {
		return "", err
	}
	defer output.RemoveAll(stage)
	for _, dir := range manifest.Dirs {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		target := path.Join(stage, dir)
		if err := makeParents(output, target); err != nil {
			return "", err
		}
		if err := output.Mkdir(target, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	var copied int64
	for i, entry := range manifest.Files {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if current, ok := s.files.State(); !ok || current != source {
			return "", ErrOffline
		}
		inputFile, err := input.Open(path.Join("data", entry.Path))
		if err != nil {
			return "", err
		}
		target := path.Join(stage, entry.Path)
		if err := makeParents(output, target); err != nil {
			inputFile.Close()
			return "", err
		}
		out, err := output.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			inputFile.Close()
			return "", err
		}
		hash, copyErr := boundedCopy(ctx, out, inputFile, entry.Size)
		closeErr := out.Close()
		inputFile.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if hash != entry.SHA256 {
			return "", errors.New("backup_checksum_mismatch")
		}
		copied += entry.Size
		s.progress(i+1, copied)
	}
	if current, ok := s.files.State(); !ok || current != source {
		return "", ErrOffline
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if lease != nil || s.destinationRegistry() != nil {
		if lease != nil {
			if err := s.validateBoundRoot(ctx, lease); err != nil {
				return "", err
			}
			if err := s.validateSnapshotRootCatalog(ctx, input, manifest); err != nil {
				return "", err
			}
		}
		if _, err := s.validateExternalFolder(ctx, location, input); err != nil {
			return "", err
		}
	}
	metadataPath, err := s.restoreMetadata(ctx, input, manifest, suffix)
	if err != nil {
		return "", err
	}
	if lease != nil || s.destinationRegistry() != nil {
		if lease != nil {
			if err := s.validateBoundRoot(ctx, lease); err != nil {
				return "", err
			}
			if err := s.validateSnapshotRootCatalog(ctx, input, manifest); err != nil {
				return "", err
			}
		}
		if _, err := s.validateExternalFolder(ctx, location, input); err != nil {
			return "", err
		}
	}
	if err := output.Rename(stage, final); err != nil {
		return "", err
	}
	if metadataPath != "" {
		s.mu.Lock()
		s.status.RestoredMetadata = metadataPath
		s.mu.Unlock()
	}
	return filepath.Join(source, final), nil
}
