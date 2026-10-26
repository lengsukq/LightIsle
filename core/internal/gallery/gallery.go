package gallery

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
	"github.com/lengsukq/lightisle/core/internal/tasks"
	_ "github.com/mattn/go-sqlite3"
)

type Asset struct {
	ID               int64   `json:"id"`
	Path             string  `json:"path"`
	Name             string  `json:"name"`
	Type             string  `json:"type"`
	Size             int64   `json:"size"`
	Modified         int64   `json:"-"`
	TakenAt          int64   `json:"takenAt"`
	Favorite         bool    `json:"favorite"`
	PersonalFavorite bool    `json:"personalFavorite"`
	ProbeStatus      string  `json:"probeStatus,omitempty"`
	BrowserPlayback  string  `json:"browserPlayback,omitempty"`
	MIME             string  `json:"mime,omitempty"`
	Container        string  `json:"container,omitempty"`
	VideoCodec       string  `json:"videoCodec,omitempty"`
	AudioCodec       string  `json:"audioCodec,omitempty"`
	DurationSeconds  float64 `json:"durationSeconds,omitempty"`
	Width            int     `json:"width,omitempty"`
	Height           int     `json:"height,omitempty"`
	Orientation      int     `json:"orientation,omitempty"`
	CapturedAt       string  `json:"capturedAt,omitempty"`
	// Capture location (nil when absent) and camera metadata for the map and
	// the viewer info panel.
	Latitude        *float64 `json:"latitude,omitempty"`
	Longitude       *float64 `json:"longitude,omitempty"`
	CameraMake      string   `json:"cameraMake,omitempty"`
	CameraModel     string   `json:"cameraModel,omitempty"`
	LensModel       string   `json:"lensModel,omitempty"`
	ISO             int      `json:"iso,omitempty"`
	FNumber         float64  `json:"fNumber,omitempty"`
	ExposureSeconds float64  `json:"exposureSeconds,omitempty"`
	FocalLength     float64  `json:"focalLength,omitempty"`
}

// ForgetLegacyShare removes only an explicitly selected legacy share's
// derived photo index and associated albums/favorites. It cannot touch source
// files. Root-scoped multi-root libraries are intentionally not supported.
func (l *Library) ForgetLegacyShare(path string) error {
	if path == "" || !filepath.IsAbs(path) || l.shareScope != "" {
		return ErrUnavailable
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.Running {
		return ErrBusy
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, sqlText := range []string{
		"DELETE FROM private_albums WHERE share=?",
		"DELETE FROM albums WHERE share=?",
		"DELETE FROM assets WHERE share=?",
	} {
		if _, err := tx.Exec(sqlText, path); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (l *Library) AlbumsScoped(roots []string) ([]Album, error) {
	if len(roots) == 1 && roots[0] == "." {
		return l.Albums()
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, args, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	q := `SELECT al.id,al.name,COUNT(ai.asset_id)
	 FROM albums al JOIN album_items ai ON ai.album_id=al.id
	 JOIN assets a ON a.id=ai.asset_id
	 WHERE al.share=? AND a.share=al.share` + fragment + ` GROUP BY al.id ORDER BY al.name`
	parameters := append([]any{share}, args...)
	rows, err := l.db.Query(q, parameters...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Album{}
	for rows.Next() {
		var item Album
		if err := rows.Scan(&item.ID, &item.Name, &item.Count); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// SetJournal must be called before the first scan is started.
func (l *Library) SetJournal(j *tasks.Journal) { l.journal = j }

type Album struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Count int    `json:"count"`
}
type BackfillStatus struct {
	Running   bool `json:"running"`
	Remaining int  `json:"remaining"`
	Total     int  `json:"total"`
}
type Status struct {
	Running   bool            `json:"running"`
	Scanned   int             `json:"scanned"`
	Found     int             `json:"found"`
	LastError string          `json:"lastError,omitempty"`
	LastDone  int64           `json:"lastDone,omitempty"`
	Backfill  *BackfillStatus `json:"backfill,omitempty"`
}
type Library struct {
	journal    *tasks.Journal
	db         *sql.DB
	storage    *files.Manager
	worker     mediaWorker
	cache      string
	shareScope string
	cacheMu    sync.Mutex
	cacheBytes int64
	cacheLimit int64
	// cacheEntries tracks the LRU order rebuilt from the cache directory.
	cacheEntries map[string]thumbnailCacheEntry
	renderer     thumbnailRenderer
	now          func() time.Time
	// workerMu guards workerTemp, the set of private renderer files that a
	// request currently owns. Cleanup uses it so a scan cannot unlink the source
	// copy under an in-flight conversion.
	workerMu   sync.Mutex
	workerTemp map[string]struct{}
	mu         sync.Mutex
	thumbMu    *thumbnailGate
	status     Status
	backfill   BackfillStatus
	ctx        context.Context
	cancel     context.CancelFunc
	jobCancel  context.CancelFunc
	wg         sync.WaitGroup
}

var (
	ErrBusy        = errors.New("scan_already_running")
	ErrUnavailable = errors.New("shared_folder_not_mounted")
)

func Open(dir string, store *files.Manager) (*Library, error) {
	return OpenWithOptions(dir, store, Options{})
}

// OpenWithOptions opens the gallery and validates the configured thumbnail
// cache budget before any scan or rendering starts.
func OpenWithOptions(dir string, store *files.Manager, options Options) (*Library, error) {
	return openWithOptions(dir, store, options, "gallery.sqlite", "thumbnails", "")
}

// OpenRootScoped opens an index isolated from the legacy v1 gallery. Root
// files stay flat so the offline metadata backup allowlist can enumerate them
// without recursively trusting arbitrary state directories.
func OpenRootScoped(dir string, store *files.Manager, rootID string, options ...Options) (*Library, error) {
	if !validRootID(rootID) {
		return nil, errors.New("invalid_root_id")
	}
	var option Options
	if len(options) > 0 {
		option = options[0]
	}
	shareScope := "root:" + rootID + ":generation:" + strconv.FormatUint(option.RootGeneration, 10)
	cacheName := "thumbnails-root-" + rootID + "-generation-" + strconv.FormatUint(option.RootGeneration, 10)
	return openWithOptions(dir, store, option, "gallery-root-"+rootID+".sqlite", cacheName, shareScope)
}

func openWithOptions(dir string, store *files.Manager, options Options, databaseName, cacheName, shareScope string) (*Library, error) {
	if options.ThumbnailCacheBytes == 0 {
		options.ThumbnailCacheBytes = DefaultThumbnailCacheBytes
	}
	if !validThumbnailCacheLimit(options.ThumbnailCacheBytes) {
		return nil, ErrThumbnailCacheLimit
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dir, databaseName)+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	statements := []string{
		`CREATE TABLE IF NOT EXISTS assets(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    share TEXT NOT NULL,path TEXT NOT NULL, type TEXT NOT NULL,
    size INTEGER NOT NULL, modified INTEGER NOT NULL, taken_at INTEGER NOT NULL,
    seen INTEGER NOT NULL DEFAULT 0, favorite INTEGER NOT NULL DEFAULT 0,
    UNIQUE(share,path))`,
		`CREATE INDEX IF NOT EXISTS assets_timeline ON assets(share,taken_at DESC,id DESC)`,
		`CREATE TABLE IF NOT EXISTS albums(
    id INTEGER PRIMARY KEY AUTOINCREMENT, share TEXT NOT NULL, name TEXT NOT NULL,
    UNIQUE(share,name))`,
		`CREATE TABLE IF NOT EXISTS album_items(
    album_id INTEGER NOT NULL,asset_id INTEGER NOT NULL,
    PRIMARY KEY(album_id,asset_id),
    FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
    FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE)`,
		`CREATE TABLE IF NOT EXISTS personal_favorites(
    user_id INTEGER NOT NULL,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    PRIMARY KEY(user_id, asset_id))`,
		`CREATE TABLE IF NOT EXISTS private_albums(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    share TEXT NOT NULL,
    user_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    UNIQUE(share,user_id,name))`,
		`CREATE INDEX IF NOT EXISTS private_albums_by_owner ON private_albums(share,user_id,id)`,
		`CREATE TABLE IF NOT EXISTS private_album_items(
    album_id INTEGER NOT NULL REFERENCES private_albums(id) ON DELETE CASCADE,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    PRIMARY KEY(album_id,asset_id))`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, err
		}
	}
	if err := ensureGalleryProbeColumns(db); err != nil {
		db.Close()
		return nil, err
	}
	// Partial index covering only located assets: the map view scans this
	// subset instead of the whole timeline. It must run after the capture
	// columns exist.
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS assets_geo ON assets(share,taken_at DESC) WHERE gps_lat IS NOT NULL`); err != nil {
		db.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	library := &Library{
		db: db, storage: store, cache: filepath.Join(dir, cacheName),
		shareScope: shareScope,
		cacheLimit: options.ThumbnailCacheBytes, cacheEntries: map[string]thumbnailCacheEntry{},
		workerTemp: map[string]struct{}{}, thumbMu: newThumbnailGate(), ctx: ctx, cancel: cancel,
	}
	if err := library.openThumbnailCache(); err != nil {
		cancel()
		db.Close()
		return nil, err
	}
	library.wg.Add(1)
	go library.backfillLoop()
	return library, nil
}

func validRootID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func (l *Library) Close() error { l.cancel(); l.wg.Wait(); return l.db.Close() }
func (l *Library) CancelScan() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.status.Running || l.jobCancel == nil {
		return false
	}
	l.jobCancel()
	return true
}
func (l *Library) share() (string, error) {
	key, _, err := l.shareState()
	return key, err
}

func (l *Library) shareState() (key, physicalPath string, err error) {
	p, online := l.storage.State()
	if !online {
		return "", "", ErrUnavailable
	}
	if l.shareScope != "" {
		return l.shareScope + "|" + p, p, nil
	}
	return p, p, nil
}
func mediaType(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	switch ext {
	case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".avif", ".tiff":
		return "photo"
	case ".mp4", ".mov", ".m4v", ".webm":
		return "video"
	}
	return ""
}
func (l *Library) Status() Status {
	l.mu.Lock()
	defer l.mu.Unlock()
	status := l.status
	if l.backfill.Running || l.backfill.Remaining > 0 {
		backfill := l.backfill
		status.Backfill = &backfill
	}
	return status
}
func (l *Library) StartScan() error {
	return l.StartScanDirs([]string{"."})
}

// StartScanDirs reconciles only complete, bounded changed subtrees.
func (l *Library) StartScanDirs(input []string) error {
	release, ok := l.storage.TryAcquireLegacyRequest()
	if !ok {
		return ErrBusy
	}
	defer release()
	dirs, err := mediascope.ScanDirectories(input)
	if err != nil {
		return err
	}
	if _, err := l.share(); err != nil {
		return err
	}
	l.mu.Lock()
	if l.status.Running {
		l.mu.Unlock()
		return ErrBusy
	}
	if l.journal != nil {
		if err := l.journal.Start("gallery", "scan"); err != nil {
			l.mu.Unlock()
			return err
		}
	}
	job, cancel := context.WithCancel(l.ctx)
	l.jobCancel = cancel
	l.status = Status{Running: true}
	l.wg.Add(1)
	l.mu.Unlock()
	go func() { defer l.wg.Done(); defer cancel(); l.scan(job, dirs) }()
	return nil
}
func (l *Library) scan(job context.Context, dirs []string) {
	status := Status{Running: true}
	defer func() {
		if l.journal != nil {
			var runErr error
			if status.LastError != "" {
				runErr = errors.New(status.LastError)
			}
			_ = l.journal.Progress("gallery", int64(status.Scanned), 0)
			_ = l.journal.Finish("gallery", runErr)
		}
		l.mu.Lock()
		status.Running = false
		status.LastDone = time.Now().Unix()
		l.status = status
		l.jobCancel = nil
		l.mu.Unlock()
	}()
	share, physicalShare, err := l.shareState()
	if err != nil {
		status.LastError = err.Error()
		return
	}
	generation := time.Now().UnixNano()
	queue := append([]string(nil), dirs...)
	// Bounded recursion; cap a manual scan to 200k entries to limit unintended
	// huge volume traversals and allow cancellation between pages.
	for len(queue) > 0 && status.Scanned < 200000 {
		select {
		case <-job.Done():
			status.LastError = "cancelled"
			return
		default:
		}
		dir := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		cursor := ""
		for {
			entries, next, err := l.storage.Page(dir, cursor, 200)
			if err != nil {
				status.LastError = err.Error()
				return
			}
			for _, e := range entries {
				status.Scanned++
				if status.Scanned >= 200000 {
					status.LastError = "scan_limit_reached"
					return
				}
				if e.Type == "folder" {
					queue = append(queue, e.Path)
					continue
				}
				kind := mediaType(e.Name)
				if kind == "" {
					continue
				}
				status.Found++
				mtime := e.Modified.UnixNano()
				oldProbe, oldModified, oldSize, oldTaken, oldExists := l.assetProbe(share, e.Path)
				// A row is fully reusable only when the file is untouched, it
				// was written by the current extraction pass, and its probe did
				// not fail; failed probes always retry, older rows are
				// re-derived so capture locations surface after an upgrade.
				exifFresh := oldExists && oldModified == mtime && oldSize == e.Size &&
					oldProbe.ExifVersion >= exifSchemaVersion && oldProbe.ProbeStatus != "failed"
				var probe assetProbe
				var taken int64
				if exifFresh {
					probe = oldProbe
					taken = oldTaken
				} else {
					probe, taken = l.captureForAsset(job, e.Path, e.Name, kind, e.Size, mtime, oldProbe)
				}
				if job.Err() != nil {
					status.LastError = "cancelled"
					return
				}
				_, err = l.db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,seen,probe_status,browser_playback,mime,container,video_codec,audio_codec,duration_seconds,width,height,orientation,captured_at,gps_lat,gps_lon,camera_make,camera_model,exif_json,exif_version)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET type=excluded.type,size=excluded.size,
      modified=excluded.modified,taken_at=excluded.taken_at,seen=excluded.seen,
      probe_status=excluded.probe_status,browser_playback=excluded.browser_playback,mime=excluded.mime,
      container=excluded.container,video_codec=excluded.video_codec,audio_codec=excluded.audio_codec,
      duration_seconds=excluded.duration_seconds,width=excluded.width,height=excluded.height,
      orientation=excluded.orientation,captured_at=excluded.captured_at,
      gps_lat=excluded.gps_lat,gps_lon=excluded.gps_lon,camera_make=excluded.camera_make,
      camera_model=excluded.camera_model,exif_json=excluded.exif_json,exif_version=excluded.exif_version`,
					share, e.Path, kind, e.Size, mtime, taken, generation,
					probe.ProbeStatus, probe.BrowserPlayback, probe.MIME, probe.Container, probe.VideoCodec, probe.AudioCodec,
					probe.DurationSeconds, probe.Width, probe.Height, probe.Orientation, probe.CapturedAt,
					probe.Latitude, probe.Longitude, probe.CameraMake, probe.CameraModel, probe.ExifJSON, probe.ExifVersion)
				if err != nil {
					status.LastError = err.Error()
					return
				}
			}
			l.mu.Lock()
			l.status = status
			l.mu.Unlock()
			if l.journal != nil && status.Scanned%200 == 0 {
				_ = l.journal.Progress("gallery", int64(status.Scanned), 0)
			}
			if next == "" {
				break
			}
			cursor = next
		}
	}
	// Only prune on a clean full scan. Detached disks must never erase gallery.
	// Do not treat a scan that hit its entry cap, was canceled just before
	// completion, or still has pending directories as authoritative. Removing
	// unseen rows after an incomplete walk could silently discard albums and
	// favorites from the user's library.
	if len(queue) > 0 || status.Scanned >= 200000 {
		status.LastError = "scan_limit_reached"
		return
	}
	if err := job.Err(); err != nil {
		status.LastError = "cancelled"
		return
	}
	if current, online := l.storage.State(); !online || current != physicalShare {
		status.LastError = "share_changed_or_offline"
		return
	}
	pruneSQL := "DELETE FROM assets WHERE share=? AND seen<>?"
	pruneArgs := []any{share, generation}
	if len(dirs) != 1 || dirs[0] != "." {
		pruneSQL += " AND ("
		for i, dir := range dirs {
			if i > 0 {
				pruneSQL += " OR "
			}
			pruneSQL += "(path=? OR substr(path,1,length(?)+1)=?||'/')"
			pruneArgs = append(pruneArgs, dir, dir, dir)
		}
		pruneSQL += ")"
	}
	if _, err := l.db.Exec(pruneSQL, pruneArgs...); err != nil {
		status.LastError = err.Error()
		return
	}
	l.pruneStaleThumbnails(share)
}
func (l *Library) List(cursor int64, limit int, albumID int64, favorites bool) ([]Asset, int64, error) {
	return l.ListScoped(cursor, limit, albumID, favorites, []string{"."})
}

func (l *Library) ListScoped(cursor int64, limit int, albumID int64, favorites bool, roots []string) ([]Asset, int64, error) {
	return l.ListScopedForUser(0, cursor, limit, albumID, favorites, false, roots)
}

func (l *Library) ListScopedForUser(userID int64, cursor int64, limit int, albumID int64, favorites, personalOnly bool, roots []string) ([]Asset, int64, error) {
	return l.ListScopedForUserWithPrivateAlbum(userID, cursor, limit, albumID, 0, favorites, personalOnly, roots)
}

// The user-scoped album predicate runs before pagination, not as a frontend
// post-filter, and every join includes the current mounted share identity.
func (l *Library) ListScopedForUserWithPrivateAlbum(userID, cursor int64, limit int, albumID, privateAlbumID int64, favorites, personalOnly bool, roots []string) ([]Asset, int64, error) {
	return l.ListScopedForUserFiltered(userID, cursor, limit, albumID, privateAlbumID, favorites, personalOnly, PhotoFilter{}, roots)
}

// PhotoFilter narrows a timeline listing: by media kind, a filename/path
// substring, the server-local "on this day" match, or an explicit id set used
// to expand a map cluster.
type PhotoFilter struct {
	Kind      string
	Query     string
	OnThisDay bool
	IDs       []int64
}

func (l *Library) ListScopedForUserFiltered(userID, cursor int64, limit int, albumID, privateAlbumID int64, favorites, personalOnly bool, filter PhotoFilter, roots []string) ([]Asset, int64, error) {
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	if limit < 1 || limit > 120 {
		return nil, 0, errors.New("invalid_limit")
	}
	if filter.Kind != "" && filter.Kind != "photo" && filter.Kind != "video" {
		return nil, 0, errors.New("invalid_filter")
	}
	if len(filter.IDs) > 120 {
		return nil, 0, errors.New("invalid_filter")
	}
	query := `SELECT a.id,a.path,a.type,a.size,a.modified,a.taken_at,a.favorite,a.probe_status,a.browser_playback,a.mime,a.container,a.video_codec,a.audio_codec,a.duration_seconds,a.width,a.height,a.orientation,a.captured_at,a.gps_lat,a.gps_lon,a.camera_make,a.camera_model,a.exif_json,
	 EXISTS(SELECT 1 FROM personal_favorites pf WHERE pf.user_id=? AND pf.asset_id=a.id) FROM assets a
	 WHERE a.share=?`
	args := []any{userID, share}
	if albumID > 0 {
		query += " AND EXISTS(SELECT 1 FROM album_items ai WHERE ai.asset_id=a.id AND ai.album_id=?)"
		args = append(args, albumID)
	}
	if privateAlbumID > 0 {
		if userID <= 0 {
			return nil, 0, sql.ErrNoRows
		}
		var exists int
		if err := l.db.QueryRow("SELECT 1 FROM private_albums WHERE share=? AND user_id=? AND id=?", share, userID, privateAlbumID).Scan(&exists); err != nil {
			return nil, 0, err
		}
		query += " AND EXISTS(SELECT 1 FROM private_album_items pai JOIN private_albums pa ON pa.id=pai.album_id WHERE pai.asset_id=a.id AND pa.id=? AND pa.user_id=? AND pa.share=a.share)"
		args = append(args, privateAlbumID, userID)
	}
	if favorites {
		query += " AND a.favorite=1"
	}
	if personalOnly {
		if userID <= 0 {
			return nil, 0, errors.New("personal_favorites_require_user")
		}
		query += " AND EXISTS(SELECT 1 FROM personal_favorites pf WHERE pf.user_id=? AND pf.asset_id=a.id)"
		args = append(args, userID)
	}
	if filter.Kind != "" {
		query += " AND a.type=?"
		args = append(args, filter.Kind)
	}
	if filter.Query != "" {
		query += " AND a.path LIKE ? ESCAPE '\\'"
		args = append(args, likePattern(filter.Query))
	}
	if filter.OnThisDay {
		query += " AND a.taken_at>0 AND strftime('%m-%d',a.taken_at,'unixepoch','localtime')=strftime('%m-%d','now','localtime')"
	}
	if len(filter.IDs) > 0 {
		placeholders := make([]string, len(filter.IDs))
		for i, id := range filter.IDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		query += " AND a.id IN (" + strings.Join(placeholders, ",") + ")"
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, 0, err
	}
	query += fragment
	args = append(args, scopedArgs...)
	query += " ORDER BY a.taken_at DESC,a.id DESC LIMIT ? OFFSET ?"
	args = append(args, limit+1, cursor)
	rows, err := l.db.Query(query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []Asset{}
	for rows.Next() {
		var a Asset
		var favorite int
		var personalFavorite int
		var latitude, longitude sql.NullFloat64
		var cameraMake, cameraModel, exifJSON string
		if err := rows.Scan(&a.ID, &a.Path, &a.Type, &a.Size, &a.Modified, &a.TakenAt, &favorite, &a.ProbeStatus, &a.BrowserPlayback, &a.MIME, &a.Container, &a.VideoCodec, &a.AudioCodec, &a.DurationSeconds, &a.Width, &a.Height, &a.Orientation, &a.CapturedAt, &latitude, &longitude, &cameraMake, &cameraModel, &exifJSON, &personalFavorite); err != nil {
			return nil, 0, err
		}
		applyCaptureColumns(&a, latitude, longitude, cameraMake, cameraModel, exifJSON)
		a.Name = path.Base(a.Path)
		a.Favorite = favorite != 0
		a.PersonalFavorite = personalFavorite != 0
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	next := int64(0)
	if len(out) > limit {
		out = out[:limit]
		next = cursor + int64(limit)
	}
	return out, next, nil
}
func (l *Library) Asset(id int64) (Asset, error) {
	share, err := l.share()
	if err != nil {
		return Asset{}, err
	}
	var a Asset
	var favorite int
	var latitude, longitude sql.NullFloat64
	var cameraMake, cameraModel, exifJSON string
	err = l.db.QueryRow("SELECT id,path,type,size,modified,taken_at,favorite,probe_status,browser_playback,mime,container,video_codec,audio_codec,duration_seconds,width,height,orientation,captured_at,gps_lat,gps_lon,camera_make,camera_model,exif_json FROM assets WHERE share=? AND id=?", share, id).
		Scan(&a.ID, &a.Path, &a.Type, &a.Size, &a.Modified, &a.TakenAt, &favorite, &a.ProbeStatus, &a.BrowserPlayback, &a.MIME, &a.Container, &a.VideoCodec, &a.AudioCodec, &a.DurationSeconds, &a.Width, &a.Height, &a.Orientation, &a.CapturedAt, &latitude, &longitude, &cameraMake, &cameraModel, &exifJSON)
	if err == nil {
		applyCaptureColumns(&a, latitude, longitude, cameraMake, cameraModel, exifJSON)
	}
	a.Favorite = favorite != 0
	a.Name = path.Base(a.Path)
	return a, err
}

// applyCaptureColumns flattens the stored capture payload onto the API shape:
// coordinates become pointers (nil when absent) and exif_json is decoded into
// the display fields.
func applyCaptureColumns(a *Asset, latitude, longitude sql.NullFloat64, cameraMake, cameraModel, exifJSON string) {
	a.Latitude = nullFloatPtr(latitude)
	a.Longitude = nullFloatPtr(longitude)
	a.CameraMake = cameraMake
	a.CameraModel = cameraModel
	details := decodeExifDetails(exifJSON)
	a.LensModel = details.LensModel
	a.ISO = details.ISO
	a.FNumber = details.FNumber
	a.ExposureSeconds = details.ExposureSeconds
	a.FocalLength = details.FocalLength
}
func (l *Library) Favorite(id int64, on bool) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	v := 0
	if on {
		v = 1
	}
	res, err := l.db.Exec("UPDATE assets SET favorite=? WHERE share=? AND id=?", v, share, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}
func (l *Library) Albums() ([]Album, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	rows, err := l.db.Query(`SELECT al.id,al.name,COUNT(ai.asset_id)
  FROM albums al LEFT JOIN album_items ai ON ai.album_id=al.id
  WHERE al.share=? GROUP BY al.id ORDER BY al.name`, share)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Album{}
	for rows.Next() {
		var a Album
		if err := rows.Scan(&a.ID, &a.Name, &a.Count); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
func (l *Library) CreateAlbum(name string) (Album, error) {
	share, err := l.share()
	if err != nil {
		return Album{}, err
	}
	name, err = normalizeAlbumName(name)
	if err != nil {
		return Album{}, err
	}
	res, err := l.db.Exec("INSERT INTO albums(share,name) VALUES(?,?)", share, name)
	if err != nil {
		return Album{}, albumWriteError(err)
	}
	id, err := res.LastInsertId()
	return Album{ID: id, Name: name, Count: 0}, err
}
func (l *Library) AddToAlbum(albumID, assetID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	var count int
	if err := l.db.QueryRow("SELECT COUNT(*) FROM albums WHERE share=? AND id=?", share, albumID).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	if err := l.db.QueryRow("SELECT COUNT(*) FROM assets WHERE share=? AND id=?", share, assetID).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	_, err = l.db.Exec("INSERT OR IGNORE INTO album_items(album_id,asset_id) VALUES(?,?)", albumID, assetID)
	return err
}
func (l *Library) Count() (int, error) {
	return l.CountScoped([]string{"."})
}
func (l *Library) CountScoped(roots []string) (int, error) {
	share, err := l.share()
	if err != nil {
		return 0, err
	}
	var count int
	fragment, args, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return 0, err
	}
	parameters := append([]any{share}, args...)
	err = l.db.QueryRow("SELECT COUNT(*) FROM assets a WHERE a.share=?"+fragment, parameters...).Scan(&count)
	return count, err
}
func cacheID(share, path string, modified int64, size int64) string {
	b := sha256.Sum256([]byte(share + "|" + path + "|" + strconv.FormatInt(modified, 10) + "|" + strconv.FormatInt(size, 10)))
	return hex.EncodeToString(b[:])
}

// likePattern escapes LIKE metacharacters so a filename search matches the
// literal substring the user typed.
func likePattern(term string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return "%" + replacer.Replace(term) + "%"
}
