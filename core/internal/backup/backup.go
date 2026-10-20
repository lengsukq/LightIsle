package backup

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/tasks"
	_ "github.com/mattn/go-sqlite3"
)

const maxFiles = 20000
const maxBytes = int64(50) << 30
const maxManifest = int64(32) << 20
const format = "lightisle-complete-backup-v2"
const legacyFormat = "lightisle-file-backup-v1"

var (
	ErrBusy     = errors.New("backup_already_running")
	ErrInvalid  = errors.New("invalid_backup_location_or_manifest")
	ErrOffline  = errors.New("share_offline")
	ErrTooLarge = errors.New("backup_safety_limit")
)

type File struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

func (s *Service) SetJournal(j *tasks.Journal) { s.mu.Lock(); s.journal = j; s.mu.Unlock() }

type Manifest struct {
	Format   string   `json:"format"`
	Created  int64    `json:"created"`
	Source   string   `json:"source"`
	Dirs     []string `json:"dirs"`
	Files    []File   `json:"files"`
	Metadata []File   `json:"metadata,omitempty"`
}
type Status struct {
	Running          bool   `json:"running"`
	Operation        string `json:"operation"`
	Files            int    `json:"files"`
	Bytes            int64  `json:"bytes"`
	LastError        string `json:"lastError,omitempty"`
	LastSnapshot     string `json:"lastSnapshot,omitempty"`
	RestoredMetadata string `json:"restoredMetadata,omitempty"`
	LastDone         int64  `json:"lastDone,omitempty"`
}
type Service struct {
	journal   *tasks.Journal
	files     *files.Manager
	dataDir   string
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	mu        sync.Mutex
	status    Status
	jobCancel context.CancelFunc
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
// remain in a private (0600) backup directory selected by the Mac owner.
func (s *Service) backupMetadata(ctx context.Context, root *os.Root, stage string, manifest *Manifest) error {
	if s.dataDir == "" {
		return nil
	} // legacy tests without application data
	for _, name := range []string{"accounts.sqlite", "gallery.sqlite", "cinema.sqlite", "tasks.sqlite", "shared-root.json", "backup-schedule.json"} {
		if err := ctx.Err(); err != nil {
			return err
		}
		source := filepath.Join(s.dataDir, name)
		st, err := os.Lstat(source)
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
			if name == "accounts.sqlite" {
				// Browser sessions are ephemeral authorization capabilities.
				// Restoring an account must never resurrect a stolen/revoked
				// cookie from the time the backup was made.
				snapshotURI := (&url.URL{Scheme: "file", Path: filepath.Join(root.Name(), target)}).String()
				snapshotDB, e := sql.Open("sqlite3", snapshotURI+"?_journal_mode=DELETE&_busy_timeout=5000")
				if e != nil {
					return e
				}
				var hasSessions int
				e = snapshotDB.QueryRowContext(ctx, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sessions'").Scan(&hasSessions)
				if e == nil && hasSessions > 0 {
					_, e = snapshotDB.ExecContext(ctx, "DELETE FROM sessions")
				}
				closeErr := snapshotDB.Close()
				if e != nil {
					return e
				}
				if closeErr != nil {
					return closeErr
				}
			}
		} else {
			in, e := os.Open(source)
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
		if info.Size() > maxBytes {
			f.Close()
			return ErrTooLarge
		}
		h := sha256.New()
		_, e = io.Copy(h, io.LimitReader(f, maxBytes+1))
		f.Close()
		if e != nil {
			return e
		}
		manifest.Metadata = append(manifest.Metadata, File{Path: name, Size: info.Size(), SHA256: hex.EncodeToString(h.Sum(nil))})
	}
	return nil
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
		_ = s.journal.Progress("backup", int64(f), b)
	}
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
	s.status = Status{Running: true, Operation: kind}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer cancel()
		snapshot, err := work(job, target)
		if s.journal != nil {
			current := s.Status()
			_ = s.journal.Progress("backup", int64(current.Files), current.Bytes)
			_ = s.journal.Finish("backup", err)
		}
		s.mu.Lock()
		s.jobCancel = nil
		s.status.Running = false
		s.status.LastDone = time.Now().Unix()
		if err != nil {
			s.status.LastError = err.Error()
		} else {
			s.status.LastSnapshot = snapshot
		}
		s.mu.Unlock()
	}()
	return nil
}
func (s *Service) StartBackup(folder string) error    { return s.start("backup", folder, s.create) }
func (s *Service) StartRestore(snapshot string) error { return s.start("restore", snapshot, s.restore) }
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
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	destination, err := authorizedFolder(folder)
	if err != nil {
		return "", err
	}
	if err := disjoint(source, destination); err != nil {
		return "", err
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		return "", err
	}
	defer root.Close()
	suffix := time.Now().UTC().Format("20060102-150405") + "-" + id()
	stage := ".lightisle-backup-" + suffix + ".partial"
	final := "LightIsle-Backup-" + suffix
	if err := root.Mkdir(stage, 0700); err != nil {
		return "", err
	}
	defer root.RemoveAll(stage)
	manifest := Manifest{Format: format, Created: time.Now().Unix(), Source: filepath.Base(source), Dirs: []string{}, Files: []File{}}
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
	if err := s.backupMetadata(ctx, root, stage, &manifest); err != nil {
		return "", err
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
	if err := root.Rename(stage, final); err != nil {
		return "", err
	}
	return filepath.Join(destination, final), nil
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
	if json.Unmarshal(data, &manifest) != nil || (manifest.Format != format && manifest.Format != legacyFormat) {
		return Manifest{}, ErrInvalid
	}
	if len(manifest.Files)+len(manifest.Dirs)+len(manifest.Metadata) > maxFiles {
		return Manifest{}, ErrTooLarge
	}
	paths := map[string]bool{}
	for _, name := range manifest.Dirs {
		if !safeName(name) || paths[name] {
			return Manifest{}, ErrInvalid
		}
		paths[name] = true
	}
	var total int64
	for _, entry := range manifest.Files {
		if !safeName(entry.Path) || paths[entry.Path] || entry.Size < 0 || len(entry.SHA256) != 64 {
			return Manifest{}, ErrInvalid
		}
		if _, err := hex.DecodeString(entry.SHA256); err != nil {
			return Manifest{}, ErrInvalid
		}
		paths[entry.Path] = true
		total += entry.Size
		if total > maxBytes {
			return Manifest{}, ErrTooLarge
		}
	}
	allowedMetadata := map[string]bool{"accounts.sqlite": true, "gallery.sqlite": true, "cinema.sqlite": true, "tasks.sqlite": true, "shared-root.json": true, "backup-schedule.json": true}
	for _, entry := range manifest.Metadata {
		if manifest.Format != format || !allowedMetadata[entry.Path] || paths["metadata/"+entry.Path] || entry.Size < 0 || entry.Size > maxBytes || len(entry.SHA256) != 64 {
			return Manifest{}, ErrInvalid
		}
		if _, err := hex.DecodeString(entry.SHA256); err != nil {
			return Manifest{}, ErrInvalid
		}
		paths["metadata/"+entry.Path] = true
	}
	return manifest, nil
}

// Verify and stage application metadata. Never replace a live SQLite database;
// recovered accounts and settings require an explicit, offline migration.
func (s *Service) restoreMetadata(ctx context.Context, input *os.Root, manifest Manifest, suffix string) (string, error) {
	if len(manifest.Metadata) == 0 || s.dataDir == "" {
		return "", nil
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
	source, online := s.files.State()
	if !online {
		return "", ErrOffline
	}
	location, err := authorizedFolder(snapshot)
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
	manifest, err := parseManifest(input)
	if err != nil {
		return "", err
	}
	output, err := os.OpenRoot(source)
	if err != nil {
		return "", err
	}
	defer output.Close()
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
	metadataPath, err := s.restoreMetadata(ctx, input, manifest, suffix)
	if err != nil {
		return "", err
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
