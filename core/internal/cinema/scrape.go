package cinema

import (
	"context"
	"errors"
	"log/slog"
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
// memory only, and immediately starts background scraping if there are
// unmatched films waiting. The validation mirrors the per-request rules in
// tmdb.go so a token accepted here cannot fail later for formatting reasons.
func (l *Library) SetTMDBToken(token string) error {
	if len(token) < 20 || len(token) > 2048 || strings.TrimSpace(token) != token ||
		strings.ContainsAny(token, "\r\n\t ") {
		return ErrInvalid
	}
	l.tmdbMu.Lock()
	l.tmdbToken = token
	l.tmdbMu.Unlock()
	l.StartAutoScrapeIfNeeded()
	return nil
}

func (l *Library) ClearTMDBToken() {
	l.tmdbMu.Lock()
	l.tmdbToken = ""
	l.tmdbMu.Unlock()
	l.mu.Lock()
	if l.status.Running && l.status.Operation == "scrape" && l.jobCancel != nil {
		l.jobCancel()
	}
	l.mu.Unlock()
}

// StartAutoScrapeIfNeeded starts a background scrape whenever a TMDB token is
// configured and the library contains unscraped films.
func (l *Library) StartAutoScrapeIfNeeded() {
	if !l.TMDBTokenConfigured() {
		return
	}
	share, err := l.share()
	if err != nil {
		return
	}
	pending, err := l.pendingScrapeFilms(share, 1)
	if err != nil || len(pending) == 0 {
		return
	}
	_ = l.StartScrape(false)
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

// CancelScrapeIfRunning preempts an active background TMDB scrape so a newly
// requested library scan can run immediately and re-chain scraping afterward.
// Active file scans are never interrupted by this helper.
func (l *Library) CancelScrapeIfRunning() {
	l.mu.Lock()
	if !l.status.Running || l.status.Operation != "scrape" || l.jobCancel == nil {
		l.mu.Unlock()
		return
	}
	cancel := l.jobCancel
	l.mu.Unlock()
	cancel()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		l.mu.Lock()
		running := l.status.Running && l.status.Operation == "scrape"
		l.mu.Unlock()
		if !running {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
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
		if l.status.Operation == "scrape" {
			if retryMisses {
				_, err := l.db.Exec("UPDATE films SET scrape_state='' WHERE scrape_state<>'auto'")
				return err
			}
			return nil
		}
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
			if !l.TMDBTokenConfigured() {
				st.LastError = "cancelled"
				return
			}
			state := l.scrapeFilm(job, token, service, share, film)
			if job.Err() != nil {
				st.LastError = "cancelled"
				return
			}
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
		WHERE share=? AND missing_path='' AND metadata_source='' AND scrape_state='' AND kind IN ('movie','series')
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
	variants := titleSearchVariants(film.Title)
	if len(variants) == 0 {
		variants = []string{film.Title}
	}
	var lastErr error
	for _, query := range variants {
		candidates, err := service.Search(job, token, query, "movie")
		if err != nil {
			lastErr = err
			if state := scrapeStateForUpstreamError(err); state == "auth_failed" || job.Err() != nil {
				return state
			}
			continue
		}
		if candidate := pickTMBDCandidate(candidates, film.Title, film.Year); candidate != nil {
			if err := l.applyTMDB(Film{ID: film.ID, Path: film.Path, Kind: film.Kind, Title: film.Title, Size: film.Size, Modified: film.Modified, Year: film.Year}, *candidate); err != nil {
				if errors.Is(err, ErrAssetChanged) {
					return "changed"
				}
				return "failed"
			}
			return "auto"
		}
	}
	if _, err := l.ImportLocalNFO(film.ID); err == nil {
		return "auto"
	}
	if lastErr != nil {
		return scrapeStateForUpstreamError(lastErr)
	}
	return "miss"
}

// scrapeSeries matches the show once and lets every episode inherit it.
// Episode-level titles remain filename-derived in this version.
func (l *Library) scrapeSeries(job context.Context, token string, service TMDBService, share string, film scrapeFilmRow) string {
	if strings.TrimSpace(film.Series) == "" {
		return "noseries"
	}
	seriesID, needs := l.seriesNeedsMatch(share, film.Series)
	if !needs {
		if seriesID > 0 {
			if _, err := l.db.Exec(`UPDATE films SET
				metadata_source=CASE WHEN metadata_source='' THEN (SELECT metadata_source FROM series WHERE id=?) ELSE metadata_source END,
				poster_path=CASE WHEN poster_path='' THEN (SELECT poster_path FROM series WHERE id=?) ELSE poster_path END,
				overview=CASE WHEN overview='' THEN (SELECT overview FROM series WHERE id=?) ELSE overview END
				WHERE share=? AND id=?`, seriesID, seriesID, seriesID, share, film.ID); err != nil {
				slog.Warn("cinema scrape series episode inherit failed", "filmID", film.ID, "seriesID", seriesID, "error", err)
				return "failed"
			}
		}
		return "series"
	}
	variants := titleSearchVariants(film.Series)
	if len(variants) == 0 {
		variants = []string{film.Series}
	}
	var candidate *TMDBCandidate
	var lastErr error
	for _, query := range variants {
		candidates, err := service.Search(job, token, query, "series")
		if err != nil {
			lastErr = err
			if state := scrapeStateForUpstreamError(err); state == "auth_failed" || job.Err() != nil {
				return state
			}
			continue
		}
		if picked := pickTMBDCandidate(candidates, film.Series, film.Year); picked != nil {
			candidate = picked
			break
		}
	}
	if candidate == nil {
		if lastErr != nil {
			return scrapeStateForUpstreamError(lastErr)
		}
		return "miss"
	}
	if _, err := l.applySeriesCandidate(share, seriesID, film.Series, *candidate); err != nil {
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
