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
	Rating       float64 `json:"rating,omitempty"`
	NextFilmID   int64   `json:"nextFilmId,omitempty"`
	NextTitle    string  `json:"nextTitle,omitempty"`
	NextSeason   int     `json:"nextSeason,omitempty"`
	NextEpisode  int     `json:"nextEpisode,omitempty"`
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
		WHERE share=? AND missing_path='' AND kind='series' AND series<>''
		AND NOT EXISTS(SELECT 1 FROM series s WHERE s.share=films.share AND s.name=films.series)
		ON CONFLICT(share,name) DO NOTHING`, share); err != nil {
		return err
	}
	if _, err := l.db.Exec(`UPDATE films SET series_id=(
		SELECT s.id FROM series s WHERE s.share=films.share AND s.name=films.series)
		WHERE share=? AND missing_path='' AND kind='series' AND series<>'' AND series_id IS NOT (
		SELECT s.id FROM series s WHERE s.share=films.share AND s.name=films.series)`, share); err != nil {
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
	return l.ListSeriesMatching(userID, limit, roots, "")
}

// ListSeriesMatching filters all authorized series at the SQL layer before
// applying the response limit. Filtering only an initial page in the client
// would silently miss shows beyond the first 60 titles.
func (l *Library) ListSeriesMatching(userID int64, limit int, roots []string, search string) ([]Series, error) {
	return l.ListSeriesFiltered(userID, SeriesFilter{Query: search}, limit, roots)
}

// fillSeriesProgress locates the show's continue-watching episode across
// authorized episodes only, prioritizing the most recently watched unfinished
// episode, then the episode following the highest completed one, then the
// first unfinished episode.
func (l *Library) fillSeriesProgress(userID int64, roots []string, s *Series) {
	share, err := l.share()
	if err != nil {
		return
	}
	q := `SELECT f.id,f.title,f.season,f.episode,COALESCE(p.position,0),COALESCE(p.duration,0),f.duration_seconds,COALESCE(p.completed,0),COALESCE(p.updated_at,0)
		FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
		WHERE f.share=? AND f.series_id=? AND f.missing_path=''`
	args := []any{userID, share, s.ID}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " ORDER BY f.season,f.episode,f.id"
	rows, err := l.readDB().Query(q, args...)
	if err != nil {
		return
	}
	defer rows.Close()
	var episodes []seriesEpisodeCandidate
	for rows.Next() {
		var ep seriesEpisodeCandidate
		var completed int
		if err := rows.Scan(&ep.id, &ep.title, &ep.season, &ep.episode, &ep.position, &ep.duration, &ep.mediaDuration, &completed, &ep.updatedAt); err != nil {
			return
		}
		ep.completed = completed != 0
		episodes = append(episodes, ep)
	}
	if rows.Err() != nil {
		return
	}
	applySeriesContinuePoint(s, episodes)
}

// GetSeries returns one show with its authorized episodes in playback order.
func (l *Library) GetSeries(userID, seriesID int64, roots []string) (Series, []Film, error) {
	share, err := l.share()
	if err != nil {
		return Series{}, nil, err
	}
	var s Series
	var posterPath string
	err = l.readDB().QueryRow(`SELECT s.id,s.name,s.tmdb_id,s.overview,s.poster_path FROM series s
		WHERE s.share=? AND s.id=?`, share, seriesID).Scan(&s.ID, &s.Name, &s.TMDBID, &s.Overview, &posterPath)
	if errors.Is(err, sql.ErrNoRows) {
		return Series{}, nil, err
	}
	if err != nil {
		return Series{}, nil, err
	}
	s.PosterURL = tmdbPosterURL(posterPath)
	films, nextOffset, err := l.seriesFilms(userID, seriesID, 240, 0, roots)
	if err != nil {
		return Series{}, nil, err
	}
	if len(films) == 0 {
		return Series{}, nil, sql.ErrNoRows
	}
	watched := 0
	candidates := make([]seriesEpisodeCandidate, 0, len(films))
	for _, film := range films {
		if film.Completed {
			watched++
		}
		if film.Year > s.Year {
			s.Year = film.Year
		}
		if film.Rating > s.Rating {
			s.Rating = film.Rating
		}
		candidates = append(candidates, seriesEpisodeCandidate{
			id:            film.ID,
			title:         film.Title,
			season:        film.Season,
			episode:       film.Episode,
			position:      film.Position,
			duration:      film.Duration,
			mediaDuration: film.MediaDuration,
			completed:     film.Completed,
			updatedAt:     film.UpdatedAt,
		})
	}
	s.EpisodeCount = len(films)
	s.WatchedCount = watched
	if nextOffset > 0 {
		l.fillSeriesProgress(userID, roots, &s)
	} else {
		applySeriesContinuePoint(&s, candidates)
	}
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
	 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),COALESCE(p.updated_at,0),f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source,f.scrape_state
	 FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
	 WHERE f.share=? AND f.series_id=? AND f.missing_path=''`
	args := []any{userID, share, seriesID}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, 0, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " ORDER BY f.season,f.episode,f.id LIMIT ? OFFSET ?"
	args = append(args, limit+1, offset)
	rows, err := l.readDB().Query(q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	result := []Film{}
	for rows.Next() {
		var f Film
		var complete int
		if err := rows.Scan(&f.ID, &f.Title, &f.Path, &f.Kind, &f.Series, &f.Season, &f.Episode, &f.Year, &f.Size, &f.Modified, &f.Position, &f.Duration, &complete, &f.UpdatedAt,
			&f.ProbeStatus, &f.BrowserPlayback, &f.Container, &f.VideoCodec, &f.AudioCodec, &f.MediaDuration, &f.Width, &f.Height, &f.CapturedAt, &f.Overview, &f.Rating, &f.MetadataSource, &f.PosterURL, &f.TitleSource, &f.YearSource, &f.ScrapeState); err != nil {
			return nil, 0, err
		}
		decorateLoadedFilm(&f, complete)
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
	if strings.TrimSpace(token) == "" {
		token = l.tmdbTokenSnapshot()
	}
	service := TMDBService{}
	if l.scrapeService != nil {
		service = *l.scrapeService
	}
	candidate, err := service.Details(ctx, token, "series", externalID)
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
	var oldName string
	if err := l.db.QueryRow("SELECT name FROM series WHERE share=? AND id=?", share, seriesID).Scan(&oldName); err != nil {
		return Series{}, err
	}
	finalSeriesID, err := l.applySeriesCandidate(share, seriesID, oldName, candidate)
	if err != nil {
		return Series{}, err
	}
	series, _, err := l.GetSeries(0, finalSeriesID, []string{"."})
	return series, err
}

func (l *Library) applySeriesCandidate(share string, seriesID int64, oldName string, candidate TMDBCandidate) (int64, error) {
	poster := ""
	if candidate.PosterURL != "" {
		poster = candidate.posterPath
	}
	source := fmt.Sprintf("tmdb:tv:%d", candidate.ID)
	var existingID int64
	_ = l.db.QueryRow("SELECT id FROM series WHERE share=? AND (name=? OR (tmdb_id=? AND tmdb_id<>0)) ORDER BY id LIMIT 1",
		share, candidate.Title, candidate.ID).Scan(&existingID)
	targetID := seriesID
	if existingID != 0 && existingID != seriesID {
		targetID = existingID
		if _, err := l.db.Exec(`UPDATE series SET name=?,overview=?,poster_path=?,tmdb_id=?,metadata_source=? WHERE share=? AND id=?`,
			candidate.Title, candidate.Overview, poster, candidate.ID, source, share, targetID); err != nil {
			return 0, err
		}
		if _, err := l.db.Exec(`UPDATE films SET series_id=?,series=? WHERE share=? AND (series_id=? OR (kind='series' AND series=?))`,
			targetID, candidate.Title, share, seriesID, oldName); err != nil {
			return 0, err
		}
		if _, err := l.db.Exec("DELETE FROM series WHERE share=? AND id=?", share, seriesID); err != nil {
			return 0, err
		}
	} else {
		updated, err := l.db.Exec(`UPDATE series SET name=?,overview=?,poster_path=?,tmdb_id=?,metadata_source=? WHERE share=? AND id=?`,
			candidate.Title, candidate.Overview, poster, candidate.ID, source, share, seriesID)
		if err != nil {
			return 0, err
		}
		if n, err := updated.RowsAffected(); err != nil || n == 0 {
			if err != nil {
				return 0, err
			}
			return 0, sql.ErrNoRows
		}
		if _, err := l.db.Exec(`UPDATE films SET series=? WHERE share=? AND (series_id=? OR (kind='series' AND series=?))`,
			candidate.Title, share, seriesID, oldName); err != nil {
			return 0, err
		}
	}
	if _, err := l.db.Exec(`UPDATE films SET
		metadata_source=CASE WHEN metadata_source='' THEN ? ELSE metadata_source END,
		poster_path=CASE WHEN poster_path='' THEN ? ELSE poster_path END,
		overview=CASE WHEN overview='' THEN ? ELSE overview END,
		rating=CASE WHEN rating=0 THEN ? ELSE rating END,
		scrape_state=CASE WHEN scrape_state='' THEN 'auto' ELSE scrape_state END
		WHERE share=? AND series_id=?`,
		source, poster, candidate.Overview, candidate.Rating, share, targetID); err != nil {
		return 0, err
	}
	return targetID, nil
}

// seriesNeedsMatch reports whether the show behind a filename-derived series
// name still lacks TMDB metadata.
func (l *Library) seriesNeedsMatch(share, name string) (int64, bool) {
	var id int64
	var tmdbID int64
	err := l.db.QueryRow("SELECT id,tmdb_id FROM series WHERE share=? AND name=?", share, name).Scan(&id, &tmdbID)
	if err != nil {
		return 0, false
	}
	if tmdbID != 0 {
		return id, false
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
// equality (including bilingual/original-title variants) and, when both sides
// carry a year, a ±1 year agreement. Anything less confident stays unmatched
// (the scrape records "miss" instead of guessing).
func pickTMBDCandidate(candidates []TMDBCandidate, title string, year int) *TMDBCandidate {
	variants := titleSearchVariants(title)
	wants := make([]string, 0, len(variants)+1)
	for _, v := range variants {
		if norm := normalizeTitle(v); norm != "" {
			wants = append(wants, norm)
		}
	}
	if len(wants) == 0 {
		if norm := normalizeTitle(title); norm != "" {
			wants = append(wants, norm)
		}
	}
	if len(wants) == 0 {
		return nil
	}
	yearCompatible := func(c *TMDBCandidate) bool {
		if year > 0 && c.Year != "" {
			if parsed, err := strconv.Atoi(c.Year); err == nil && absInt(parsed-year) > 1 {
				return false
			}
		}
		return true
	}
	candidateNorms := func(c *TMDBCandidate) []string {
		out := []string{}
		for _, raw := range []string{c.Title, c.OriginalTitle} {
			if n := normalizeTitle(raw); n != "" {
				out = append(out, n)
			}
		}
		return out
	}
	for i := range candidates {
		candidate := &candidates[i]
		if !yearCompatible(candidate) {
			continue
		}
		for _, cNorm := range candidateNorms(candidate) {
			for _, want := range wants {
				if cNorm == want {
					return candidate
				}
			}
		}
	}
	// Secondary pass: when release year is explicitly known and agrees within ±1,
	// allow matching the main title before a colon subtitle (e.g. "复仇者联盟4" vs "复仇者联盟4：终局之战").
	if year > 0 {
		for i := range candidates {
			candidate := &candidates[i]
			if candidate.Year == "" || !yearCompatible(candidate) {
				continue
			}
			for _, raw := range []string{candidate.Title, candidate.OriginalTitle} {
				for _, sep := range []string{"：", ":"} {
					if idx := strings.Index(raw, sep); idx > 0 {
						prefixNorm := normalizeTitle(raw[:idx])
						if len([]rune(prefixNorm)) >= 2 {
							for _, want := range wants {
								if prefixNorm == want {
									return candidate
								}
							}
						}
					}
				}
			}
		}
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
