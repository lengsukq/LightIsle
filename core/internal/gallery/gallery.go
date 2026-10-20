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
	ID       int64  `json:"id"`
	Path     string `json:"path"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	Size     int64  `json:"size"`
	TakenAt  int64  `json:"takenAt"`
	Favorite bool   `json:"favorite"`
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
type Status struct {
	Running   bool   `json:"running"`
	Scanned   int    `json:"scanned"`
	Found     int    `json:"found"`
	LastError string `json:"lastError,omitempty"`
	LastDone  int64  `json:"lastDone,omitempty"`
}
type Library struct {
	journal   *tasks.Journal
	db        *sql.DB
	storage   *files.Manager
	cache     string
	mu        sync.Mutex
	thumbMu   sync.Mutex
	status    Status
	ctx       context.Context
	cancel    context.CancelFunc
	jobCancel context.CancelFunc
	wg        sync.WaitGroup
}

var (
	ErrBusy        = errors.New("scan_already_running")
	ErrUnavailable = errors.New("shared_folder_not_mounted")
)

func Open(dir string, store *files.Manager) (*Library, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dir, "gallery.sqlite")+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1")
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
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, err
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Library{db: db, storage: store, cache: filepath.Join(dir, "thumbnails"), ctx: ctx, cancel: cancel}, nil
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
	p, online := l.storage.State()
	if !online {
		return "", ErrUnavailable
	}
	return p, nil
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
	return l.status
}
func (l *Library) StartScan() error {
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
	go func() { defer l.wg.Done(); defer cancel(); l.scan(job) }()
	return nil
}
func (l *Library) scan(job context.Context) {
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
	share, err := l.share()
	if err != nil {
		status.LastError = err.Error()
		return
	}
	generation := time.Now().UnixNano()
	queue := []string{"."}
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
				taken := e.Modified.Unix()
				var oldModified, oldTaken int64
				if l.db.QueryRow("SELECT modified,taken_at FROM assets WHERE share=? AND path=?", share, e.Path).Scan(&oldModified, &oldTaken) == nil && oldModified == mtime {
					taken = oldTaken
				} else if kind == "photo" {
					taken = l.CaptureTime(e.Path, e.Modified).Unix()
				}
				_, err = l.db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,seen)
      VALUES(?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET type=excluded.type,size=excluded.size,
      modified=excluded.modified,taken_at=excluded.taken_at,seen=excluded.seen`,
					share, e.Path, kind, e.Size, mtime, taken, generation)
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
	if current, online := l.storage.State(); !online || current != share {
		status.LastError = "share_changed_or_offline"
		return
	}
	if _, err := l.db.Exec("DELETE FROM assets WHERE share=? AND seen<>?", share, generation); err != nil {
		status.LastError = err.Error()
		return
	}
}
func (l *Library) List(cursor int64, limit int, albumID int64, favorites bool) ([]Asset, int64, error) {
	return l.ListScoped(cursor, limit, albumID, favorites, []string{"."})
}

func (l *Library) ListScoped(cursor int64, limit int, albumID int64, favorites bool, roots []string) ([]Asset, int64, error) {
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	if limit < 1 || limit > 120 {
		return nil, 0, errors.New("invalid_limit")
	}
	query := `SELECT a.id,a.path,a.type,a.size,a.taken_at,a.favorite FROM assets a
 WHERE a.share=?`
	args := []any{share}
	if albumID > 0 {
		query += " AND EXISTS(SELECT 1 FROM album_items ai WHERE ai.asset_id=a.id AND ai.album_id=?)"
		args = append(args, albumID)
	}
	if favorites {
		query += " AND a.favorite=1"
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
		if err := rows.Scan(&a.ID, &a.Path, &a.Type, &a.Size, &a.TakenAt, &favorite); err != nil {
			return nil, 0, err
		}
		a.Name = path.Base(a.Path)
		a.Favorite = favorite != 0
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
	err = l.db.QueryRow("SELECT id,path,type,size,taken_at,favorite FROM assets WHERE share=? AND id=?", share, id).
		Scan(&a.ID, &a.Path, &a.Type, &a.Size, &a.TakenAt, &favorite)
	a.Favorite = favorite != 0
	a.Name = path.Base(a.Path)
	return a, err
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
	name = strings.TrimSpace(name)
	if len([]rune(name)) < 1 || len([]rune(name)) > 60 {
		return Album{}, errors.New("invalid_album_name")
	}
	res, err := l.db.Exec("INSERT INTO albums(share,name) VALUES(?,?)", share, name)
	if err != nil {
		return Album{}, err
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
