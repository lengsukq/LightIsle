package cinema

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// ErrTMDBNotConfigured is returned when an automatic scrape is requested
// without a token. The Mac App stores the token in the Keychain and forwards
// it over the private IPC channel; Core keeps it in memory only.
var ErrTMDBNotConfigured = errors.New("tmdb_token_not_configured")

const (
	scrapeRequestGap = 250 * time.Millisecond
	scrapeBatch      = 20
)

// SetTMDBToken stores the TMDB Read Access Token for automatic matching in
// memory only. The validation mirrors the per-request rules in tmdb.go so a
// token accepted here cannot fail later for formatting reasons.
func (l *Library) SetTMDBToken(token string) error {
	if len(token) < 20 || len(token) > 2048 || strings.TrimSpace(token) != token ||
		strings.ContainsAny(token, "\r\n\t ") {
		return ErrInvalid
	}
	l.tmdbMu.Lock()
	defer l.tmdbMu.Unlock()
	l.tmdbToken = token
	return nil
}

func (l *Library) ClearTMDBToken() {
	l.tmdbMu.Lock()
	defer l.tmdbMu.Unlock()
	l.tmdbToken = ""
}

func (l *Library) TMDBTokenConfigured() bool {
	l.tmdbMu.Lock()
	defer l.tmdbMu.Unlock()
	return l.tmdbToken != ""
}

func (l *Library) tmdbTokenSnapshot() string {
	l.tmdbMu.Lock()
	defer l.tmdbMu.Unlock()
	return l.tmdbToken
}

// StartScrape launches the automatic metadata backfill for films that have
// no confirmed source yet. It never runs concurrently with a scan or another
// scrape; retryMisses re-queues items whose earlier automatic attempt found
// no confident match.
func (l *Library) StartScrape(retryMisses bool) error {
	release, ok := l.files.TryAcquireLegacyRequest()
	if !ok {
		return ErrScanning
	}
	defer release()
	if _, err := l.share(); err != nil {
		return err
	}
	if !l.TMDBTokenConfigured() {
		return ErrTMDBNotConfigured
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.Running {
		return ErrScanning
	}
	if retryMisses {
		if _, err := l.db.Exec("UPDATE films SET scrape_state='' WHERE scrape_state<>'auto'"); err != nil {
			return err
		}
	}
	if l.journal != nil {
		if err := l.journal.Start("cinema", "scrape"); err != nil {
			if errors.Is(err, tasks.ErrRunning) {
				return ErrScanning
			}
			return err
		}
	}
	job, cancel := context.WithCancel(l.ctx)
	l.jobCancel = cancel
	l.status = Status{Running: true, Operation: "scrape"}
	l.wg.Add(1)
	go func() { defer cancel(); l.scrape(job) }()
	return nil
}

func (l *Library) scrape(job context.Context) {
	defer l.wg.Done()
	st := Status{Running: true, Operation: "scrape"}
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
	token := l.tmdbTokenSnapshot()
	if token == "" {
		st.LastError = "tmdb_token_not_configured"
		return
	}
	share, physicalShare, err := l.shareState()
	if err != nil {
		st.LastError = err.Error()
		return
	}
	service := TMDBService{}
	if l.scrapeService != nil {
		service = *l.scrapeService
	}
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
		batch, err := l.pendingScrapeFilms(share, scrapeBatch)
		if err != nil {
			st.LastError = err.Error()
			return
		}
		if len(batch) == 0 {
			break
		}
		for _, film := range batch {
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
			state := l.scrapeFilm(job, token, service, share, film)
			if state == "auth_failed" {
				st.LastError = "tmdb_auth_failed"
				return
			}
			st.Visited++
			if state == "auto" {
				st.Found++
			}
			if _, err := l.db.Exec("UPDATE films SET scrape_state=? WHERE id=?", state, film.ID); err != nil {
				st.LastError = err.Error()
				return
			}
			if l.journal != nil {
				_ = l.journal.Progress("cinema", int64(st.Visited), 0)
			}
			l.mu.Lock()
			l.status = st
			l.mu.Unlock()
			select {
			case <-job.Done():
				st.LastError = "cancelled"
				return
			case <-time.After(scrapeRequestGap):
			}
		}
	}
}

type scrapeFilmRow struct {
	ID       int64
	Path     string
	Title    string
	Kind     string
	Series   string
	Year     int
	Size     int64
	Modified int64
}

// pendingScrapeFilms returns films without confirmed metadata that were not
// resolved by an earlier automatic attempt.
func (l *Library) pendingScrapeFilms(share string, limit int) ([]scrapeFilmRow, error) {
	rows, err := l.db.Query(`SELECT id,path,title,kind,series,year,size,modified FROM films
		WHERE share=? AND metadata_source='' AND scrape_state='' AND kind IN ('movie','series')
		ORDER BY id LIMIT ?`, share, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []scrapeFilmRow{}
	for rows.Next() {
		var row scrapeFilmRow
		if err := rows.Scan(&row.ID, &row.Path, &row.Title, &row.Kind, &row.Series, &row.Year, &row.Size, &row.Modified); err != nil {
			return nil, err
		}
		result = append(result, row)
	}
	return result, rows.Err()
}

// scrapeFilm applies one automatic match decision. The returned state is
// persisted so a rerun skips resolved items instead of re-querying upstream:
// auto (matched), miss (no confident candidate), series (belongs to a show
// handled at show level), changed (file moved on mid-run) or failed.
func (l *Library) scrapeFilm(job context.Context, token string, service TMDBService, share string, film scrapeFilmRow) string {
	if film.Kind == "series" {
		return l.scrapeSeries(job, token, service, share, film)
	}
	candidates, err := service.Search(job, token, film.Title, "movie")
	if err != nil {
		return scrapeStateForUpstreamError(err)
	}
	candidate := pickTMBDCandidate(candidates, film.Title, film.Year)
	if candidate == nil {
		return "miss"
	}
	if err := l.applyTMDB(Film{ID: film.ID, Path: film.Path, Kind: film.Kind, Title: film.Title, Size: film.Size, Modified: film.Modified, Year: film.Year}, *candidate); err != nil {
		if errors.Is(err, ErrAssetChanged) {
			return "changed"
		}
		return "failed"
	}
	return "auto"
}

// scrapeSeries matches the show once and lets every episode inherit it.
// Episode-level titles remain filename-derived in this version.
func (l *Library) scrapeSeries(job context.Context, token string, service TMDBService, share string, film scrapeFilmRow) string {
	if strings.TrimSpace(film.Series) == "" {
		return "noseries"
	}
	seriesID, needs := l.seriesNeedsMatch(share, film.Series)
	if !needs {
		return "series"
	}
	candidates, err := service.Search(job, token, film.Series, "series")
	if err != nil {
		return scrapeStateForUpstreamError(err)
	}
	candidate := pickTMBDCandidate(candidates, film.Series, 0)
	if candidate == nil {
		return "miss"
	}
	poster := ""
	if candidate.PosterURL != "" {
		poster = candidate.posterPath
	}
	if _, err := l.db.Exec(`UPDATE series SET name=CASE WHEN name=? THEN ? ELSE name END,
		overview=?,poster_path=?,tmdb_id=?,metadata_source=? WHERE share=? AND id=?`,
		film.Series, candidate.Title, candidate.Overview, poster, candidate.ID,
		"tmdb:tv:"+strconv.FormatInt(candidate.ID, 10), share, seriesID); err != nil {
		return "failed"
	}
	return "auto"
}

func scrapeStateForUpstreamError(err error) string {
	message := err.Error()
	if strings.Contains(message, "status_401") || strings.Contains(message, "status_403") {
		// Authentication problems repeat for every title; stop the run and
		// surface the reason instead of burning through the library.
		return "auth_failed"
	}
	return "failed"
}
