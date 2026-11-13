package cinema

import (
	"strings"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

const maxCinemaSearchTokens = 8

// ListFilter configures film library listing, search, watch-state filtering, and sorting.
type ListFilter struct {
	Kind    string
	Query   string
	Watched string
	Sort    string
}

// SeriesFilter configures series shelf search, watch-state filtering, and sorting.
type SeriesFilter struct {
	Query   string
	Watched string
	Sort    string
}

// ValidWatchFilter reports whether watched is a supported watch-state filter.
func ValidWatchFilter(watched string) bool {
	switch watched {
	case "", "all", "watched", "unwatched":
		return true
	default:
		return false
	}
}

// ValidSortOrder reports whether sortBy is a supported cinema sort mode.
func ValidSortOrder(sortBy string) bool {
	switch sortBy {
	case "", "recent", "added", "rating", "year", "title", "name":
		return true
	default:
		return false
	}
}

func parseCinemaSearchTokens(raw string) ([]string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil
	}
	if len([]rune(trimmed)) > 120 || strings.ContainsRune(trimmed, 0) {
		return nil, ErrInvalid
	}
	fields := strings.Fields(strings.ToLower(trimmed))
	seen := make(map[string]struct{}, len(fields))
	tokens := make([]string, 0, len(fields))
	for _, f := range fields {
		if _, dup := seen[f]; dup {
			continue
		}
		seen[f] = struct{}{}
		tokens = append(tokens, f)
	}
	if len(tokens) > maxCinemaSearchTokens {
		tail := strings.Join(tokens[maxCinemaSearchTokens-1:], " ")
		tokens = append(tokens[:maxCinemaSearchTokens-1], tail)
	}
	return tokens, nil
}

// ListScopedFiltered lists authorized films matching kind, multi-keyword search,
// watched state, and sort order.
func (l *Library) ListScopedFiltered(userID int64, filter ListFilter, limit, offset int, roots []string) ([]Film, int, error) {
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	if limit < 1 || limit > 120 || offset < 0 || offset > 1000000 {
		return nil, 0, ErrInvalid
	}
	if !ValidWatchFilter(filter.Watched) || !ValidSortOrder(filter.Sort) {
		return nil, 0, ErrInvalid
	}
	tokens, err := parseCinemaSearchTokens(filter.Query)
	if err != nil {
		return nil, 0, err
	}
	q := `SELECT f.id,f.title,f.path,f.kind,f.series,f.season,f.episode,f.year,f.size,f.modified,
 COALESCE(p.position,0),COALESCE(p.duration,0),COALESCE(p.completed,0),COALESCE(p.updated_at,0),f.probe_status,f.browser_playback,f.container,f.video_codec,f.audio_codec,f.duration_seconds,f.width,f.height,f.captured_at,f.overview,f.rating,f.metadata_source,f.poster_path,f.title_source,f.year_source,f.scrape_state
 FROM films f LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
 WHERE f.share=? AND f.missing_path=''`
	args := []any{userID, share}
	switch filter.Kind {
	case "movie", "series":
		q += " AND f.kind=?"
		args = append(args, filter.Kind)
	case "unmatched":
		q += " AND f.metadata_source='' AND f.kind IN ('movie','series')"
	case "continue":
		q += " AND p.position>5 AND COALESCE(p.completed,0)=0"
	case "", "all", "recent":
	default:
		return nil, 0, ErrInvalid
	}
	switch filter.Watched {
	case "watched":
		q += " AND COALESCE(p.completed,0)=1"
	case "unwatched":
		q += " AND COALESCE(p.completed,0)=0"
	}
	for _, tok := range tokens {
		q += " AND (instr(lower(f.title),?)>0 OR instr(lower(f.series),?)>0 OR instr(lower(f.path),?)>0)"
		args = append(args, tok, tok, tok)
	}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, 0, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += cinemaFilmOrderClause(filter.Kind, filter.Sort)
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

func cinemaFilmOrderClause(kind, sortBy string) string {
	switch sortBy {
	case "recent", "added":
		return " ORDER BY f.id DESC LIMIT ? OFFSET ?"
	case "rating":
		return " ORDER BY f.rating DESC, f.year DESC, f.id DESC LIMIT ? OFFSET ?"
	case "year":
		return " ORDER BY f.year DESC, f.rating DESC, f.id DESC LIMIT ? OFFSET ?"
	case "title", "name":
		return " ORDER BY f.title COLLATE NOCASE, f.season, f.episode, f.id LIMIT ? OFFSET ?"
	}
	switch kind {
	case "recent":
		return " ORDER BY f.id DESC LIMIT ? OFFSET ?"
	case "continue":
		return " ORDER BY p.updated_at DESC, f.id LIMIT ? OFFSET ?"
	default:
		return " ORDER BY f.title COLLATE NOCASE, f.season, f.episode, f.id LIMIT ? OFFSET ?"
	}
}

// ListSeriesFiltered filters and orders authorized TV series at the SQL layer.
func (l *Library) ListSeriesFiltered(userID int64, filter SeriesFilter, limit int, roots []string) ([]Series, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	if limit < 1 || limit > 120 || !ValidWatchFilter(filter.Watched) || !ValidSortOrder(filter.Sort) {
		return nil, ErrInvalid
	}
	tokens, err := parseCinemaSearchTokens(filter.Query)
	if err != nil {
		return nil, err
	}
	q := `SELECT s.id,s.name,s.tmdb_id,s.overview,s.poster_path,
		COUNT(f.id),
		COALESCE(SUM(CASE WHEN COALESCE(p.completed,0)=1 THEN 1 ELSE 0 END),0),
		MAX(f.year),
		COALESCE(MAX(f.rating),0)
		FROM series s JOIN films f ON f.series_id=s.id
		LEFT JOIN watch_progress p ON p.film_id=f.id AND p.user_id=?
		WHERE s.share=? AND f.missing_path=''`
	args := []any{userID, share}
	fragment, scopedArgs, err := mediascope.Clause("f.path", roots)
	if err != nil {
		return nil, ErrInvalid
	}
	q += fragment
	args = append(args, scopedArgs...)
	q += " GROUP BY s.id HAVING COUNT(f.id)>0"
	switch filter.Watched {
	case "watched":
		q += " AND COALESCE(SUM(CASE WHEN COALESCE(p.completed,0)=1 THEN 1 ELSE 0 END),0)=COUNT(f.id)"
	case "unwatched":
		q += " AND COALESCE(SUM(CASE WHEN COALESCE(p.completed,0)=1 THEN 1 ELSE 0 END),0)<COUNT(f.id)"
	}
	for _, tok := range tokens {
		q += " AND (instr(lower(s.name),?)>0 OR MAX(CASE WHEN instr(lower(f.title),?)>0 OR instr(lower(f.path),?)>0 THEN 1 ELSE 0 END)=1)"
		args = append(args, tok, tok, tok)
	}
	switch filter.Sort {
	case "recent", "added":
		q += " ORDER BY MAX(f.id) DESC, s.id DESC LIMIT ?"
	case "rating":
		q += " ORDER BY COALESCE(MAX(f.rating),0) DESC, MAX(f.year) DESC, s.name COLLATE NOCASE LIMIT ?"
	case "year":
		q += " ORDER BY MAX(f.year) DESC, COALESCE(MAX(f.rating),0) DESC, s.name COLLATE NOCASE LIMIT ?"
	default:
		q += " ORDER BY s.name COLLATE NOCASE LIMIT ?"
	}
	args = append(args, limit)
	rows, err := l.readDB().Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Series{}
	for rows.Next() {
		var s Series
		var posterPath string
		if err := rows.Scan(&s.ID, &s.Name, &s.TMDBID, &s.Overview, &posterPath,
			&s.EpisodeCount, &s.WatchedCount, &s.Year, &s.Rating); err != nil {
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

type seriesEpisodeCandidate struct {
	id            int64
	title         string
	season        int
	episode       int
	position      float64
	duration      float64
	mediaDuration float64
	completed     bool
	updatedAt     int64
}

// applySeriesContinuePoint selects the continue-watching target for a show
// given its episodes ordered by (season, episode, id):
//  1. Most recently updated unfinished episode with position > 5s;
//  2. First unfinished episode strictly after the highest completed episode;
//  3. First unfinished episode from the start of the series.
func applySeriesContinuePoint(s *Series, episodes []seriesEpisodeCandidate) {
	s.NextFilmID = 0
	s.NextTitle = ""
	s.NextSeason = 0
	s.NextEpisode = 0
	s.InProgress = false
	s.Position = 0
	s.Duration = 0
	if len(episodes) == 0 {
		return
	}
	assign := func(ep seriesEpisodeCandidate) {
		s.NextFilmID = ep.id
		s.NextTitle = ep.title
		s.NextSeason = ep.season
		s.NextEpisode = ep.episode
		s.InProgress = ep.position > 5 && !ep.completed
		s.Position = ep.position
		dur := ep.duration
		if dur <= 0 && ep.mediaDuration > 0 {
			dur = ep.mediaDuration
		}
		s.Duration = dur
	}

	bestInProgressIdx := -1
	lastCompletedIdx := -1
	firstUnwatchedIdx := -1
	for i, ep := range episodes {
		if ep.completed {
			lastCompletedIdx = i
			continue
		}
		if firstUnwatchedIdx < 0 {
			firstUnwatchedIdx = i
		}
		if ep.position > 5 {
			if bestInProgressIdx < 0 || ep.updatedAt >= episodes[bestInProgressIdx].updatedAt {
				bestInProgressIdx = i
			}
		}
	}
	if bestInProgressIdx >= 0 {
		assign(episodes[bestInProgressIdx])
		return
	}
	if lastCompletedIdx >= 0 {
		for i := lastCompletedIdx + 1; i < len(episodes); i++ {
			if !episodes[i].completed {
				assign(episodes[i])
				return
			}
		}
	}
	if firstUnwatchedIdx >= 0 {
		assign(episodes[firstUnwatchedIdx])
	}
}
