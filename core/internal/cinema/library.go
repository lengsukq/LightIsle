package cinema

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
	"github.com/lengsukq/lightisle/core/internal/tasks"
	_ "github.com/mattn/go-sqlite3"
)

var (
	ErrOffline      = errors.New("cinema_volume_offline")
	ErrScanning     = errors.New("cinema_scan_running")
	ErrInvalid      = errors.New("invalid_cinema_request")
	ErrAssetChanged = errors.New("asset_changed_rescan_required")
)

type Film struct {
	ID              int64   `json:"id"`
	Title           string  `json:"title"`
	Path            string  `json:"path"`
	Kind            string  `json:"kind"`
	Series          string  `json:"series"`
	Season          int     `json:"season"`
	Episode         int     `json:"episode"`
	Year            int     `json:"year"`
	Size            int64   `json:"size"`
	Modified        int64   `json:"modified"`
	Playable        bool    `json:"playable"`
	Mime            string  `json:"mime"`
	ProbeStatus     string  `json:"probeStatus,omitempty"`
	BrowserPlayback string  `json:"browserPlayback"`
	Container       string  `json:"container,omitempty"`
	VideoCodec      string  `json:"videoCodec,omitempty"`
	AudioCodec      string  `json:"audioCodec,omitempty"`
	MediaDuration   float64 `json:"durationSeconds,omitempty"`
	Width           int     `json:"width,omitempty"`
	Height          int     `json:"height,omitempty"`
	CapturedAt      string  `json:"capturedAt,omitempty"`
	Overview        string  `json:"overview,omitempty"`
	Rating          float64 `json:"rating,omitempty"`
	MetadataSource  string  `json:"metadataSource,omitempty"`
	TitleSource     string  `json:"titleSource,omitempty"`
	YearSource      string  `json:"yearSource,omitempty"`
	PosterURL       string  `json:"posterURL,omitempty"`
	Position        float64 `json:"position"`
	Duration        float64 `json:"duration"`
	Completed       bool    `json:"completed"`
}

// ForgetLegacyShare deletes the chosen disconnected share's film rows;
// SQLite foreign-key cascading also removes its watch progress. The actual
// video files are never accessed or deleted.
func (l *Library) ForgetLegacyShare(path string) error {
	if path == "" || !filepath.IsAbs(path) || l.shareScope != "" {
		return ErrOffline
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.Running {
		return ErrScanning
	}
	_, err := l.db.Exec("DELETE FROM films WHERE share=?", path)
	return err
}

func (l *Library) SetJournal(j *tasks.Journal) { l.journal = j }

type Progress struct {
	Position  float64 `json:"position"`
	Duration  float64 `json:"duration"`
	Completed bool    `json:"completed"`
}
type Status struct {
	Running   bool   `json:"running"`
	Visited   int    `json:"visited"`
	Found     int    `json:"found"`
	LastDone  int64  `json:"lastDone"`
	LastError string `json:"lastError,omitempty"`
}
type Library struct {
	journal    *tasks.Journal
	db         *sql.DB
	files      *files.Manager
	shareScope string
	worker     mediaWorker
	ctx        context.Context
	cancel     context.CancelFunc
	wg         sync.WaitGroup
	mu         sync.Mutex
	status     Status
	jobCancel  context.CancelFunc
}

func Open(dataDir string, store *files.Manager) (*Library, error) {
	return open(dataDir, store, "cinema.sqlite", "")
}

// OpenRootScoped creates one flat, root-specific cinema database. It never
// reads or migrates the legacy single-root database.
func OpenRootScoped(dataDir string, store *files.Manager, rootID string, generations ...uint64) (*Library, error) {
	if !validRootID(rootID) {
		return nil, errors.New("invalid_root_id")
	}
	var generation uint64
	if len(generations) > 0 {
		generation = generations[0]
	}
	scope := fmt.Sprintf("root:%s:generation:%d", rootID, generation)
	return open(dataDir, store, "cinema-root-"+rootID+".sqlite", scope)
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

func open(dataDir string, store *files.Manager, databaseName, shareScope string) (*Library, error) {
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dataDir, databaseName)+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS films (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     share TEXT NOT NULL, path TEXT NOT NULL, title TEXT NOT NULL,
     manual_title INTEGER NOT NULL DEFAULT 0,
     kind TEXT NOT NULL, series TEXT NOT NULL DEFAULT '',
     season INTEGER NOT NULL DEFAULT 0, episode INTEGER NOT NULL DEFAULT 0,
     year INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL,
     modified INTEGER NOT NULL, seen INTEGER NOT NULL,
     UNIQUE(share,path)
   )`,
		`CREATE INDEX IF NOT EXISTS cinema_browse ON films(share,kind,title,id)`,
		`CREATE TABLE IF NOT EXISTS watch_progress (
     user_id INTEGER NOT NULL, film_id INTEGER NOT NULL,
     position REAL NOT NULL, duration REAL NOT NULL,
     completed INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL,
     PRIMARY KEY(user_id,film_id),
     FOREIGN KEY(film_id) REFERENCES films(id) ON DELETE CASCADE
   )`,
	}
	for _, q := range migrations {
		if _, err := db.Exec(q); err != nil {
			db.Close()
			return nil, fmt.Errorf("cinema migration: %w", err)
		}
	}
	if err := ensureProbeColumns(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("cinema probe migration: %w", err)
	}
	if err := ensureCinemaMetadataColumns(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("cinema metadata migration: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Library{db: db, files: store, shareScope: shareScope, ctx: ctx, cancel: cancel}, nil
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
	p, online := l.files.State()
	if !online {
		return "", "", ErrOffline
	}
	if l.shareScope != "" {
		return l.shareScope + "|" + p, p, nil
	}
	return p, p, nil
}
func FileMime(p string) string {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".webm":
		return "video/webm"
		// QuickTime MOV, MKV and AVI may need on-demand transcoding.
	}
	return ""
}
func isFilm(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".m4v", ".webm", ".mov", ".mkv", ".avi", ".ts":
		return true
	}
	return false
}

var episodePattern = regexp.MustCompile(`(?i)(?:^|[. _-])s([0-9]{1,2})[. _-]*e([0-9]{1,3})(?:[. _-]|$)`)
var altEpisodePattern = regexp.MustCompile(`(?i)(?:^|[. _-])([0-9]{1,2})x([0-9]{1,3})(?:[. _-]|$)`)
var yearPattern = regexp.MustCompile(`(?:^|[. _(])((?:19|20)[0-9]{2})(?:[. _)]|$)`)
var extraSeparators = regexp.MustCompile(`[._]+`)

func Identify(filename string) (title, kind, series string, season, episode, year int) {
	base := strings.TrimSuffix(filename, filepath.Ext(filename))
	kind = "movie"
	yearFound := yearPattern.FindStringSubmatch(base)
	if len(yearFound) > 1 {
		year, _ = strconv.Atoi(yearFound[1])
	}
	seasonMatch := episodePattern.FindStringSubmatchIndex(base)
	if seasonMatch == nil {
		seasonMatch = altEpisodePattern.FindStringSubmatchIndex(base)
	}
	titlePart := base
	if seasonMatch != nil {
		kind = "series"
		season, _ = strconv.Atoi(base[seasonMatch[2]:seasonMatch[3]])
		episode, _ = strconv.Atoi(base[seasonMatch[4]:seasonMatch[5]])
		titlePart = base[:seasonMatch[0]]
	}
	if kind == "movie" && len(yearFound) > 0 {
		index := yearPattern.FindStringIndex(base)
		if index != nil {
			titlePart = base[:index[0]]
		}
	}
	title = strings.TrimSpace(extraSeparators.ReplaceAllString(titlePart, " "))
	if title == "" {
		title = base
	}
	if kind == "series" {
		series = title
	}
	return
}
func (l *Library) Status() Status { l.mu.Lock(); defer l.mu.Unlock(); return l.status }
func (l *Library) StartScan() error {
	return l.StartScanDirs([]string{"."})
}
func (l *Library) StartScanDirs(input []string) error {
	dirs, err := mediascope.ScanDirectories(input)
	if err != nil {
		return err
	}
	if _, err := l.share(); err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.Running {
		return ErrScanning
	}
	if l.journal != nil {
		if err := l.journal.Start("cinema", "scan"); err != nil {
			return err
		}
	}
	job, cancel := context.WithCancel(l.ctx)
	l.jobCancel = cancel
	l.status = Status{Running: true}
	l.wg.Add(1)
	go func() { defer cancel(); l.scan(job, dirs) }()
	return nil
}
func (l *Library) scan(job context.Context, scope []string) {
	defer l.wg.Done()
	st := Status{Running: true}
	defer func() {
		if l.journal != nil {
			var runErr error
			if st.LastError != "" {
				runErr = errors.New(st.LastError)
			}
			_ = l.journal.Progress("cinema", int64(st.Visited), 0)
			_ = l.journal.Finish("cinema", runErr)
		}
		st.Running = false
		st.LastDone = time.Now().Unix()
		l.mu.Lock()
		l.status = st
		l.jobCancel = nil
		l.mu.Unlock()
	}()
	share, physicalShare, err := l.shareState()
	if err != nil {
		st.LastError = err.Error()
		return
	}
	generation := time.Now().UnixNano()
	dirs := append([]string(nil), scope...)
	for len(dirs) > 0 && st.Visited < 200000 {
		select {
		case <-job.Done():
			st.LastError = "cancelled"
			return
		default:
		}
		if current, ok := l.files.State(); !ok || current != physicalShare {
			st.LastError = "share_changed"
			return
		}
		dir := dirs[len(dirs)-1]
		dirs = dirs[:len(dirs)-1]
		cursor := ""
		for {
			select {
			case <-job.Done():
				st.LastError = "cancelled"
				return
			default:
			}
			if current, ok := l.files.State(); !ok || current != physicalShare {
				st.LastError = "share_changed"
				return
			}
			entries, next, err := l.files.Page(dir, cursor, 200)
			if err != nil {
				st.LastError = err.Error()
				return
			}
			for _, entry := range entries {
				st.Visited++
				if st.Visited > 200000 {
					st.LastError = "scan_limit"
					return
				}
				if entry.Type == "folder" {
					dirs = append(dirs, entry.Path)
					continue
				}
				if !isFilm(entry.Name) {
					continue
				}
				st.Found++
				title, kind, series, season, episode, year := Identify(entry.Name)
				oldProbe, oldSize, oldModified, oldExists := l.filmProbe(share, entry.Path)
				mtime := entry.Modified.UnixNano()
				unchanged := oldExists && oldSize == entry.Size && oldModified == mtime
				probe := l.probeFilm(job, entry.Path, entry.Name, entry.Size, mtime, unchanged, oldProbe)
				if job.Err() != nil {
					st.LastError = "cancelled"
					return
				}
				_, err = l.db.Exec(`INSERT INTO films(share,path,title,kind,series,season,episode,year,size,modified,seen,probe_status,browser_playback,container,video_codec,audio_codec,duration_seconds,width,height,captured_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET
      title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE excluded.title END,
      kind=excluded.kind,series=excluded.series,season=excluded.season,
      episode=excluded.episode,
      year=CASE WHEN year_source<>'' THEN year ELSE excluded.year END,
      size=excluded.size,
      modified=excluded.modified,seen=excluded.seen,probe_status=excluded.probe_status,
      browser_playback=excluded.browser_playback,container=excluded.container,video_codec=excluded.video_codec,
      audio_codec=excluded.audio_codec,duration_seconds=excluded.duration_seconds,width=excluded.width,
      height=excluded.height,captured_at=excluded.captured_at`,
					share, entry.Path, title, kind, series, season, episode, year, entry.Size, mtime, generation,
					probe.ProbeStatus, probe.BrowserPlayback, probe.Container, probe.VideoCodec, probe.AudioCodec,
					probe.DurationSeconds, probe.Width, probe.Height, probe.CapturedAt)
				if err != nil {
					st.LastError = err.Error()
					return
				}
			}
			l.mu.Lock()
			l.status = st
			l.mu.Unlock()
			if l.journal != nil && st.Visited%200 == 0 {
				_ = l.journal.Progress("cinema", int64(st.Visited), 0)
			}
			if next == "" {
				break
			}
			cursor = next
		}
	}
	if st.Visited >= 200000 {
		st.LastError = "scan_limit"
		return
	}
	if err := job.Err(); err != nil {
		st.LastError = "cancelled"
		return
	}
	if current, ok := l.files.State(); !ok || current != physicalShare {
		st.LastError = "share_changed"
		return
	}
	pruneSQL := "DELETE FROM films WHERE share=? AND seen<>?"
	pruneArgs := []any{share, generation}
	if len(scope) != 1 || scope[0] != "." {
		pruneSQL += " AND ("
		for i, dir := range scope {
			if i > 0 {
				pruneSQL += " OR "
			}
			pruneSQL += "(path=? OR substr(path,1,length(?)+1)=?||'/')"
			pruneArgs = append(pruneArgs, dir, dir, dir)
		}
		pruneSQL += ")"
	}
	if _, err = l.db.Exec(pruneSQL, pruneArgs...); err != nil {
		st.LastError = err.Error()
	}
}
func (l *Library) Get(id, userID int64) (Film, error) {
	share, err := l.share()
	if err != nil {
		return Film{}, err
	}
	var f Film
	var completed int
	err = l.db.QueryRow(`SELECT f.id,f.title,f.path,f.kind,f.series,f.season,f.episode,f.year,f.size,f.modified,
 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source
 FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
 WHERE f.share=? AND f.id=?`, userID, share, id).
		Scan(&f.ID, &f.Title, &f.Path, &f.Kind, &f.Series, &f.Season, &f.Episode, &f.Year, &f.Size, &f.Modified, &f.Position, &f.Duration, &completed,
			&f.ProbeStatus, &f.BrowserPlayback, &f.Container, &f.VideoCodec, &f.AudioCodec, &f.MediaDuration, &f.Width, &f.Height, &f.CapturedAt, &f.Overview, &f.Rating, &f.MetadataSource, &f.PosterURL, &f.TitleSource, &f.YearSource)
	f.PosterURL = tmdbPosterURL(f.PosterURL)
	f.Completed = completed != 0
	f.BrowserPlayback = normalizedPlayback(f.Path, f.BrowserPlayback)
	f.Mime = filmMime(f.Path, f.ProbeStatus, f.BrowserPlayback, f.Container)
	f.Playable = f.BrowserPlayback != "download-only"
	return f, err
}
func (l *Library) List(userID int64, kind, query string, limit, offset int) ([]Film, int, error) {
	return l.ListScoped(userID, kind, query, limit, offset, []string{"."})
}

func (l *Library) ListScoped(userID int64, kind, query string, limit, offset int, roots []string) ([]Film, int, error) {
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	if limit < 1 || limit > 120 || offset < 0 || offset > 1000000 || len(query) > 120 {
		return nil, 0, ErrInvalid
	}
	q := `SELECT f.id,f.title,f.path,f.kind,f.series,f.season,f.episode,f.year,f.size,f.modified,
 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source
 FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
 WHERE f.share=?`
	args := []any{userID, share}
	if kind == "movie" || kind == "series" {
		q += " AND f.kind=?"
		args = append(args, kind)
	}
	if kind == "continue" {
		q += " AND p.position>5 AND p.completed=0"
	}
	if query != "" {
		q += " AND (instr(lower(f.title),lower(?))>0 OR instr(lower(f.series),lower(?))>0)"
		args = append(args, query, query)
	}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, 0, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " ORDER BY f.title COLLATE NOCASE, f.season, f.episode, f.id LIMIT ? OFFSET ?"
	args = append(args, limit+1, offset)
	rows, err := l.db.Query(q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	result := []Film{}
	for rows.Next() {
		var f Film
		var complete int
		if err := rows.Scan(&f.ID, &f.Title, &f.Path, &f.Kind, &f.Series, &f.Season, &f.Episode, &f.Year, &f.Size, &f.Modified, &f.Position, &f.Duration, &complete,
			&f.ProbeStatus, &f.BrowserPlayback, &f.Container, &f.VideoCodec, &f.AudioCodec, &f.MediaDuration, &f.Width, &f.Height, &f.CapturedAt, &f.Overview, &f.Rating, &f.MetadataSource, &f.PosterURL, &f.TitleSource, &f.YearSource); err != nil {
			return nil, 0, err
		}
		f.Completed = complete != 0
		f.BrowserPlayback = normalizedPlayback(f.Path, f.BrowserPlayback)
		f.Mime = filmMime(f.Path, f.ProbeStatus, f.BrowserPlayback, f.Container)
		f.Playable = f.BrowserPlayback != "download-only"
		f.PosterURL = tmdbPosterURL(f.PosterURL)
		result = append(result, f)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	next := 0
	if len(result) > limit {
		result = result[:limit]
		next = offset + limit
	}
	return result, next, nil
}
func (l *Library) SaveProgress(userID, filmID int64, position, duration float64, completed bool) error {
	if position < 0 || duration < 0 || position > 86400*48 || duration > 86400*48 {
		return ErrInvalid
	}
	if _, err := l.Get(filmID, userID); err != nil {
		return err
	}
	complete := 0
	if completed {
		complete = 1
	}
	_, err := l.db.Exec(`INSERT INTO watch_progress(user_id,film_id,position,duration,completed,updated_at)
 VALUES(?,?,?,?,?,?)
 ON CONFLICT(user_id,film_id) DO UPDATE SET position=excluded.position,
 duration=excluded.duration,completed=excluded.completed,updated_at=excluded.updated_at`,
		userID, filmID, position, duration, complete, time.Now().Unix())
	return err
}
func (l *Library) Rename(id int64, title string) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	title = strings.TrimSpace(title)
	if len([]rune(title)) < 1 || len([]rune(title)) > 100 {
		return ErrInvalid
	}
	result, err := l.db.Exec("UPDATE films SET title=?,manual_title=1,title_source='manual' WHERE share=? AND id=?", title, share, id)
	if err != nil {
		return err
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}
func (l *Library) Read(id, userID int64) (*os.File, os.FileInfo, Film, error) {
	film, err := l.Get(id, userID)
	if err != nil {
		return nil, nil, Film{}, err
	}
	f, info, err := l.files.Read(film.Path)
	if err != nil {
		return nil, nil, Film{}, err
	}
	if !info.Mode().IsRegular() {
		f.Close()
		return nil, nil, Film{}, ErrInvalid
	}
	if info.Size() != film.Size || info.ModTime().UnixNano() != film.Modified {
		f.Close()
		return nil, nil, Film{}, ErrAssetChanged
	}
	return f, info, film, nil
}
func (l *Library) FindSubtitle(film Film, lang string) (*os.File, string, error) {
	if lang != "" && lang != "zh" && lang != "en" {
		return nil, "", ErrInvalid
	}
	ext := path.Ext(film.Path)
	stem := strings.TrimSuffix(film.Path, ext)
	langSuffix := ""
	if lang != "" {
		langSuffix = "." + lang
	}
	for _, format := range []string{".vtt", ".srt"} {
		candidate := stem + langSuffix + format
		f, info, err := l.files.Read(candidate)
		if err == nil {
			if info.Size() > 1<<20 {
				f.Close()
				return nil, "", ErrInvalid
			}
			return f, format, nil
		}
	}
	return nil, "", sql.ErrNoRows
}
