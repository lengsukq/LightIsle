package cinema

import (
	"database/sql"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

type Collection struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Count       int    `json:"count"`
	CoverFilmID int64  `json:"coverFilmId,omitempty"`
	CreatedAt   int64  `json:"createdAt"`
}

func ensureCollectionTables(db *sql.DB) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS collections (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			share TEXT NOT NULL,
			name TEXT NOT NULL,
			description TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL,
			UNIQUE(share, name)
		)`,
		`CREATE TABLE IF NOT EXISTS collection_items (
			collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
			film_id INTEGER NOT NULL REFERENCES films(id) ON DELETE CASCADE,
			added_at INTEGER NOT NULL,
			PRIMARY KEY(collection_id, film_id)
		)`,
	}
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			return err
		}
	}
	return nil
}

func normalizeCollectionText(name, description string) (string, string, error) {
	name = strings.TrimSpace(name)
	description = strings.TrimSpace(description)
	if len([]rune(name)) < 1 || len([]rune(name)) > 60 || strings.ContainsAny(name, "\r\n\x00") {
		return "", "", ErrInvalid
	}
	if len([]rune(description)) > 200 || strings.ContainsRune(description, 0) {
		return "", "", ErrInvalid
	}
	return name, description, nil
}

// ListCollectionsScoped returns family collections with film counts and cover
// IDs computed strictly within the viewer's authorized directory roots.
func (l *Library) ListCollectionsScoped(roots []string) ([]Collection, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, ErrInvalid
	}
	query := `SELECT c.id, c.name, c.description, c.created_at,
		COUNT(f.id) AS film_count,
		COALESCE(MIN(f.id), 0) AS cover_id
		FROM collections c
		LEFT JOIN collection_items ci ON ci.collection_id = c.id
		LEFT JOIN films f ON f.id = ci.film_id AND f.share = c.share AND f.missing_path = ''` + fragment + `
		WHERE c.share = ?
		GROUP BY c.id
		ORDER BY c.created_at DESC, c.id DESC`
	args := append(scopedArgs, share)
	rows, err := l.readDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Collection{}
	for rows.Next() {
		var item Collection
		if err := rows.Scan(&item.ID, &item.Name, &item.Description, &item.CreatedAt, &item.Count, &item.CoverFilmID); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (l *Library) CreateCollection(name, description string) (Collection, error) {
	share, err := l.share()
	if err != nil {
		return Collection{}, err
	}
	name, description, err = normalizeCollectionText(name, description)
	if err != nil {
		return Collection{}, err
	}
	now := time.Now().Unix()
	res, err := l.db.Exec(
		"INSERT INTO collections(share, name, description, created_at) VALUES(?,?,?,?)",
		share, name, description, now,
	)
	if err != nil {
		return Collection{}, ErrInvalid
	}
	id, _ := res.LastInsertId()
	return Collection{ID: id, Name: name, Description: description, CreatedAt: now}, nil
}

func (l *Library) UpdateCollection(id int64, name, description string) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	if id <= 0 {
		return ErrInvalid
	}
	name, description, err = normalizeCollectionText(name, description)
	if err != nil {
		return err
	}
	res, err := l.db.Exec(
		"UPDATE collections SET name=?, description=? WHERE share=? AND id=?",
		name, description, share, id,
	)
	if err != nil {
		return ErrInvalid
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (l *Library) DeleteCollection(id int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	res, err := l.db.Exec("DELETE FROM collections WHERE share=? AND id=?", share, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (l *Library) AddFilmToCollection(collectionID, filmID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	if collectionID <= 0 || filmID <= 0 {
		return ErrInvalid
	}
	var cExists, fExists int
	if err := l.readDB().QueryRow("SELECT 1 FROM collections WHERE share=? AND id=?", share, collectionID).Scan(&cExists); err != nil {
		return err
	}
	if err := l.readDB().QueryRow("SELECT 1 FROM films WHERE share=? AND id=? AND missing_path=''", share, filmID).Scan(&fExists); err != nil {
		return err
	}
	_, err = l.db.Exec(
		"INSERT OR IGNORE INTO collection_items(collection_id, film_id, added_at) VALUES(?,?,?)",
		collectionID, filmID, time.Now().Unix(),
	)
	return err
}

func (l *Library) RemoveFilmFromCollection(collectionID, filmID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	var cExists int
	if err := l.readDB().QueryRow("SELECT 1 FROM collections WHERE share=? AND id=?", share, collectionID).Scan(&cExists); err != nil {
		return err
	}
	_, err = l.db.Exec("DELETE FROM collection_items WHERE collection_id=? AND film_id=?", collectionID, filmID)
	return err
}

func (l *Library) ListCollectionFilmsScoped(userID, collectionID int64, roots []string) ([]Film, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	var cExists int
	if err := l.readDB().QueryRow("SELECT 1 FROM collections WHERE share=? AND id=?", share, collectionID).Scan(&cExists); err != nil {
		return nil, err
	}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, ErrInvalid
	}
	q := `SELECT f.id,f.title,f.path,f.kind,f.series,f.season,f.episode,f.year,f.size,f.modified,
 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),COALESCE(p.updated_at,0),
 f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,
 f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source,f.scrape_state
 FROM collection_items ci
 JOIN films f ON f.id=ci.film_id
 LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
 WHERE ci.collection_id=? AND f.share=? AND f.missing_path=''` + fragment + `
 ORDER BY ci.added_at DESC, f.id DESC`
	args := append([]any{userID, collectionID, share}, scopedArgs...)
	rows, err := l.readDB().Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Film{}
	for rows.Next() {
		var f Film
		var complete int
		if err := rows.Scan(&f.ID, &f.Title, &f.Path, &f.Kind, &f.Series, &f.Season, &f.Episode, &f.Year, &f.Size, &f.Modified,
			&f.Position, &f.Duration, &complete, &f.UpdatedAt,
			&f.ProbeStatus, &f.BrowserPlayback, &f.Container, &f.VideoCodec, &f.AudioCodec, &f.MediaDuration,
			&f.Width, &f.Height, &f.CapturedAt, &f.Overview, &f.Rating, &f.MetadataSource, &f.PosterURL,
			&f.TitleSource, &f.YearSource, &f.ScrapeState); err != nil {
			return nil, err
		}
		decorateLoadedFilm(&f, complete)
		out = append(out, f)
	}
	return out, rows.Err()
}
