package cinema

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// Series aggregates filename-derived episodes into a navigable show. Rows
// are derived state: syncSeries rebuilds the links from films.series on
// every completed scan, and a deleted show's episodes keep their files.
type Series struct {
	ID           int64   `json:"id"`
	Name         string  `json:"name"`
	TMDBID       int64   `json:"tmdbId,omitempty"`
	Overview     string  `json:"overview,omitempty"`
	PosterURL    string  `json:"posterURL,omitempty"`
	EpisodeCount int     `json:"episodeCount"`
	WatchedCount int     `json:"watchedCount"`
	Year         int     `json:"year,omitempty"`
	NextFilmID   int64   `json:"nextFilmId,omitempty"`
	NextTitle    string  `json:"nextTitle,omitempty"`
	InProgress   bool    `json:"inProgress"`
	Position     float64 `json:"position,omitempty"`
	Duration     float64 `json:"duration,omitempty"`
}

// ensureSeriesTables adds the derived series index and the scrape bookkeeping
// columns to an existing library database.
func ensureSeriesTables(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(films)")
	if err != nil {
		return err
	}
	exists := make(map[string]bool)
	for rows.Next() {
		var cid, notnull, primary int
		var name, kind string
		var defaultValue any
		if err = rows.Scan(&cid, &name, &kind, &notnull, &defaultValue, &primary); err != nil {
			break
		}
		exists[name] = true
	}
	if err == nil {
		err = rows.Err()
	}
	if closeErr := rows.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	for _, column := range []struct{ name, ddl string }{
		{"series_id", "INTEGER NOT NULL DEFAULT 0"},
		{"scrape_state", "TEXT NOT NULL DEFAULT ''"},
	} {
		if !exists[column.name] {
			if _, err := db.Exec("ALTER TABLE films ADD COLUMN " + column.name + " " + column.ddl); err != nil {
				return err
			}
		}
	}
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS series (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     share TEXT NOT NULL, name TEXT NOT NULL,
     tmdb_id INTEGER NOT NULL DEFAULT 0,
     overview TEXT NOT NULL DEFAULT '',
     poster_path TEXT NOT NULL DEFAULT '',
     metadata_source TEXT NOT NULL DEFAULT '',
     UNIQUE(share,name)
   )`)
	if err != nil {
		return err
	}
	_, err = db.Exec("CREATE INDEX IF NOT EXISTS cinema_series ON series(share,name)")
	return err
}

// syncSeries refreshes the derived series index for the current share after
// a scan: one row per distinct episode-series name, films linked by name,
// and rows whose episodes disappeared pruned. Shows are never renamed here;
// the name follows the filenames (TMDB matching refines display names).
func (l *Library) syncSeries(share string) error {
	if _, err := l.db.Exec(`INSERT INTO series(share,name)
		SELECT DISTINCT share,series FROM films
		WHERE share=? AND kind='series' AND series<>''
		ON CONFLICT(share,name) DO NOTHING`, share); err != nil {
		return err
	}
	if _, err := l.db.Exec(`UPDATE films SET series_id=(
		SELECT s.id FROM series s WHERE s.share=films.share AND s.name=films.series)
		WHERE share=? AND kind='series' AND series<>''`, share); err != nil {
		return err
	}
	_, err := l.db.Exec(`DELETE FROM series WHERE share=? AND id NOT IN (
		SELECT DISTINCT series_id FROM films WHERE share=? AND series_id>0)`, share, share)
	return err
}

// ListSeries returns shows with at least one authorized episode plus a
// cross-episode continue point (the first unfinished episode in playback
// order), so the client can offer "continue watching" per show.
func (l *Library) ListSeries(userID int64, limit int, roots []string) ([]Series, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	if limit < 1 || limit > 120 {
		return nil, ErrInvalid
	}
	q := `SELECT s.id,s.name,s.tmdb_id,s.overview,s.poster_path,
		COUNT(f.id),
		COALESCE(SUM(CASE WHEN COALESCE(p.completed,0)=1 THEN 1 ELSE 0 END),0),
		MAX(f.year)
		FROM series s JOIN films f ON f.series_id=s.id
		LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
		WHERE s.share=?`
	args := []any{userID, share}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " GROUP BY s.id HAVING COUNT(f.id)>0 ORDER BY s.name COLLATE NOCASE LIMIT ?"
	args = append(args, limit)
	rows, err := l.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Series{}
	for rows.Next() {
		var s Series
		var posterPath string
		if err := rows.Scan(&s.ID, &s.Name, &s.TMDBID, &s.Overview, &posterPath,
			&s.EpisodeCount, &s.WatchedCount, &s.Year); err != nil {
			return nil, err
		}
		s.PosterURL = tmdbPosterURL(posterPath)
		result = append(result, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range result {
		l.fillSeriesProgress(userID, roots, &result[i])
	}
	return result, nil
}

// fillSeriesProgress locates the show's first unfinished episode. Episodes
// the caller cannot read are skipped, so the continue point never leaks
// another member's folder layout.
func (l *Library) fillSeriesProgress(userID int64, roots []string, s *Series) {
	share, err := l.share()
	if err != nil {
		return
	}
	q := `SELECT f.id,f.title,COALESCE(p.completed,0),COALESCE(p.position,0),COALESCE(p.duration,0)
		FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
		WHERE f.share=? AND f.series_id=?`
	args := []any{userID, share, s.ID}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " ORDER BY f.season,f.episode,f.id"
	rows, err := l.db.Query(q, args...)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var filmID int64
		var title string
		var completed int
		var position, duration float64
		if err := rows.Scan(&filmID, &title, &completed, &position, &duration); err != nil {
			return
		}
		if completed != 0 {
			continue
		}
		s.NextFilmID = filmID
		s.NextTitle = title
		s.InProgress = position > 5
		s.Position = position
		s.Duration = duration
		return
	}
}

// GetSeries returns one show with its authorized episodes in playback order.
func (l *Library) GetSeries(userID, seriesID int64, roots []string) (Series, []Film, error) {
	share, err := l.share()
	if err != nil {
		return Series{}, nil, err
	}
	var s Series
	var posterPath string
	err = l.db.QueryRow(`SELECT s.id,s.name,s.tmdb_id,s.overview,s.poster_path FROM series s
		WHERE s.share=? AND s.id=?`, share, seriesID).Scan(&s.ID, &s.Name, &s.TMDBID, &s.Overview, &posterPath)
	if errors.Is(err, sql.ErrNoRows) {
		return Series{}, nil, err
	}
	if err != nil {
		return Series{}, nil, err
	}
	s.PosterURL = tmdbPosterURL(posterPath)
	films, _, err := l.seriesFilms(userID, seriesID, 240, 0, roots)
	if err != nil {
		return Series{}, nil, err
	}
	watched := 0
	for _, film := range films {
		if film.Completed {
			watched++
		}
	}
	s.EpisodeCount = len(films)
	s.WatchedCount = watched
	l.fillSeriesProgress(userID, roots, &s)
	return s, films, nil
}

func (l *Library) seriesFilms(userID, seriesID int64, limit, offset int, roots []string) ([]Film, int, error) {
	if limit < 1 || limit > 240 || offset < 0 {
		return nil, 0, ErrInvalid
	}
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	q := `SELECT f.id,f.title,f.path,f.kind,f.series,f.season,f.episode,f.year,f.size,f.modified,
	 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source
	 FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
	 WHERE f.share=? AND f.series_id=?`
	args := []any{userID, share, seriesID}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, 0, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " ORDER BY f.season,f.episode,f.id LIMIT ? OFFSET ?"
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

// MatchSeriesTMDB attaches TMDB show metadata to a derived series row.
// Episode files are never touched; only the show card changes.
func (l *Library) MatchSeriesTMDB(ctx context.Context, token string, seriesID, externalID int64) (Series, error) {
	candidate, err := (TMDBService{}).Details(ctx, token, "series", externalID)
	if err != nil {
		return Series{}, err
	}
	if candidate.Title == "" || candidate.ID != externalID {
		return Series{}, ErrInvalid
	}
	share, err := l.share()
	if err != nil {
		return Series{}, err
	}
	poster := ""
	if candidate.PosterURL != "" {
		poster = candidate.posterPath
	}
	updated, err := l.db.Exec(`UPDATE series SET name=?,overview=?,poster_path=?,tmdb_id=?,metadata_source=?
		WHERE share=? AND id=?`,
		candidate.Title, candidate.Overview, poster, externalID,
		fmt.Sprintf("tmdb:tv:%d", externalID), share, seriesID)
	if err != nil {
		return Series{}, err
	}
	if n, err := updated.RowsAffected(); err != nil || n == 0 {
		if err != nil {
			return Series{}, err
		}
		return Series{}, sql.ErrNoRows
	}
	series, _, err := l.GetSeries(0, seriesID, []string{"."})
	return series, err
}

// seriesNeedsMatch reports whether the show behind a filename-derived series
// name still lacks TMDB metadata.
func (l *Library) seriesNeedsMatch(share, name string) (int64, bool) {
	var id int64
	var tmdbID int64
	err := l.db.QueryRow("SELECT id,tmdb_id FROM series WHERE share=? AND name=?", share, name).Scan(&id, &tmdbID)
	if err != nil || tmdbID != 0 {
		return 0, false
	}
	return id, true
}

func absInt(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

// pickTMBDCandidate selects a confident automatic match: normalized title
// equality and, when both sides carry a year, a ±1 year agreement. Anything
// less confident stays unmatched (the scrape records "miss" instead of
// guessing).
func pickTMBDCandidate(candidates []TMDBCandidate, title string, year int) *TMDBCandidate {
	want := normalizeTitle(title)
	if want == "" {
		return nil
	}
	for i := range candidates {
		candidate := &candidates[i]
		if normalizeTitle(candidate.Title) != want {
			continue
		}
		if year > 0 && candidate.Year != "" {
			if parsed, err := strconv.Atoi(candidate.Year); err == nil && absInt(parsed-year) > 1 {
				continue
			}
		}
		return candidate
	}
	return nil
}

func normalizeTitle(value string) string {
	value = strings.ToLower(value)
	var builder strings.Builder
	for _, r := range value {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			builder.WriteRune(r)
		}
	}
	return builder.String()
}

// MatchSeriesTMDBWithStoredToken matches a series using the Keychain-provided
// token instead of a per-request token.
func (l *Library) MatchSeriesTMDBWithStoredToken(ctx context.Context, seriesID, externalID int64) (Series, error) {
	token := l.tmdbTokenSnapshot()
	if token == "" {
		return Series{}, ErrTMDBNotConfigured
	}
	return l.MatchSeriesTMDB(ctx, token, seriesID, externalID)
}
