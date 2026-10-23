package cinema

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// External TMDB access is opt-in per request: a user-supplied Read Access
// Token remains in browser memory and the HTTP request body, never a URL,
// SQLite database, file, log or permanent backend configuration.
const officialTMDBEndpoint = "https://api.themoviedb.org/3"

var tmdbPosterPattern = regexp.MustCompile(`^/[a-zA-Z0-9_-]{1,110}\.(?:jpg|jpeg|png|webp)$`)

func tmdbPosterURL(p string) string {
	if !tmdbPosterPattern.MatchString(p) {
		return ""
	}
	return "https://image.tmdb.org/t/p/w342" + p
}

type TMDBCandidate struct {
	ID         int64   `json:"id"`
	Kind       string  `json:"kind"`
	Title      string  `json:"title"`
	Year       string  `json:"year,omitempty"`
	Overview   string  `json:"overview,omitempty"`
	Rating     float64 `json:"rating"`
	PosterURL  string  `json:"posterURL,omitempty"`
	posterPath string
}

type tmdbSearchResult struct {
	ID           int64   `json:"id"`
	Title        string  `json:"title"`
	Name         string  `json:"name"`
	Overview     string  `json:"overview"`
	ReleaseDate  string  `json:"release_date"`
	FirstAirDate string  `json:"first_air_date"`
	VoteAverage  float64 `json:"vote_average"`
	PosterPath   string  `json:"poster_path"`
	Adult        bool    `json:"adult"`
}

type TMDBService struct {
	endpoint string
	client   *http.Client
}

func (s TMDBService) request(ctx context.Context, token, location string, output any) error {
	if len(token) < 20 || len(token) > 2048 || strings.TrimSpace(token) != token ||
		strings.ContainsAny(token, "\r\n\t ") {
		return ErrInvalid
	}
	base := s.endpoint
	if base == "" {
		base = officialTMDBEndpoint
	}
	if base != officialTMDBEndpoint && s.client == nil {
		return ErrInvalid // Do not allow an arbitrary upstream from production.
	}
	ctx, cancel := context.WithTimeout(ctx, 9*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, base+location, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/json")
	client := s.client
	if client == nil {
		client = &http.Client{Timeout: 9 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("tmdb_upstream_unavailable: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("tmdb_upstream_status_%d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 {
		return errors.New("tmdb_response_too_large_or_invalid")
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	if err := decoder.Decode(output); err != nil {
		return errors.New("tmdb_invalid_response")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("tmdb_response_too_large_or_invalid")
	}
	return nil
}

func tmdbKind(kind string) (string, error) {
	switch kind {
	case "movie":
		return "movie", nil
	case "series":
		return "tv", nil
	default:
		return "", ErrInvalid
	}
}

func cleanTMDB(r tmdbSearchResult, kind string) TMDBCandidate {
	title := r.Title
	date := r.ReleaseDate
	if kind == "tv" {
		title = r.Name
		date = r.FirstAirDate
	}
	title = strings.TrimSpace(title)
	if len([]rune(title)) > 150 {
		title = string([]rune(title)[:150])
	}
	overview := strings.TrimSpace(r.Overview)
	if len([]rune(overview)) > 4000 {
		overview = string([]rune(overview)[:4000])
	}
	rating := r.VoteAverage
	if math.IsNaN(rating) || math.IsInf(rating, 0) || rating < 0 || rating > 10 {
		rating = 0
	}
	year := ""
	if len(date) >= 4 {
		if n, err := strconv.Atoi(date[:4]); err == nil && n >= 1870 && n <= 2100 {
			year = date[:4]
		}
	}
	return TMDBCandidate{ID: r.ID, Kind: kind, Title: title, Year: year, Overview: overview,
		Rating: rating, PosterURL: tmdbPosterURL(r.PosterPath), posterPath: r.PosterPath}
}

func (s TMDBService) Search(ctx context.Context, token, query, kind string) ([]TMDBCandidate, error) {
	q := strings.TrimSpace(query)
	if q == "" || len([]rune(q)) > 120 {
		return nil, ErrInvalid
	}
	kind, err := tmdbKind(kind)
	if err != nil {
		return nil, err
	}
	values := url.Values{"query": {q}, "language": {"zh-CN"}, "include_adult": {"false"}, "page": {"1"}}
	var response struct {
		Results []tmdbSearchResult `json:"results"`
	}
	if err := s.request(ctx, token, "/search/"+kind+"?"+values.Encode(), &response); err != nil {
		return nil, err
	}
	result := make([]TMDBCandidate, 0, min(10, len(response.Results)))
	for _, entry := range response.Results {
		if entry.Adult || entry.ID <= 0 {
			continue
		}
		candidate := cleanTMDB(entry, kind)
		if candidate.Title != "" {
			result = append(result, candidate)
		}
		if len(result) >= 10 {
			break
		}
	}
	return result, nil
}

func (s TMDBService) Details(ctx context.Context, token, kind string, id int64) (TMDBCandidate, error) {
	if id < 1 || id > 1_000_000_000 {
		return TMDBCandidate{}, ErrInvalid
	}
	kind, err := tmdbKind(kind)
	if err != nil {
		return TMDBCandidate{}, err
	}
	var response tmdbSearchResult
	if err := s.request(ctx, token, "/"+kind+"/"+strconv.FormatInt(id, 10)+"?language=zh-CN", &response); err != nil {
		return TMDBCandidate{}, err
	}
	if response.ID != id {
		return TMDBCandidate{}, errors.New("tmdb_detail_id_mismatch")
	}
	candidate := cleanTMDB(response, kind)
	if candidate.Title == "" {
		return TMDBCandidate{}, errors.New("tmdb_missing_title")
	}
	return candidate, nil
}

func (l *Library) SearchTMDB(ctx context.Context, token string, filmID int64, query string) ([]TMDBCandidate, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return nil, err
	}
	if query == "" {
		query = film.Title
	}
	return (TMDBService{}).Search(ctx, token, query, film.Kind)
}

func (l *Library) MatchTMDB(ctx context.Context, token string, filmID, externalID int64) (Film, error) {
	return l.matchTMDBWithService(ctx, token, filmID, externalID, TMDBService{})
}

func (l *Library) matchTMDBWithService(ctx context.Context, token string, filmID, externalID int64, service TMDBService) (Film, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return Film{}, err
	}
	candidate, err := service.Details(ctx, token, film.Kind, externalID)
	if err != nil {
		return Film{}, err
	}
	if err := l.applyTMDB(film, candidate); err != nil {
		return Film{}, err
	}
	return l.Get(filmID, 0)
}

func (l *Library) applyTMDB(film Film, result TMDBCandidate) error {
	if err := l.validateFilmSnapshot(film); err != nil {
		return err
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	kind, err := tmdbKind(film.Kind)
	if err != nil || kind != result.Kind || result.ID <= 0 || result.Title == "" {
		return ErrInvalid
	}
	poster := ""
	if result.PosterURL != "" {
		poster = result.posterPath
	}
	updated, err := l.db.Exec(`UPDATE films
		SET title=CASE WHEN manual_title=1 THEN title ELSE ? END,
		title_source=CASE WHEN manual_title=1 THEN title_source ELSE ? END,
		overview=?,rating=?,metadata_source=?,poster_path=?
		WHERE share=? AND id=? AND path=? AND kind=? AND size=? AND modified=?`,
		result.Title, fmt.Sprintf("tmdb:%s:%d", kind, result.ID), result.Overview, result.Rating,
		fmt.Sprintf("tmdb:%s:%d", kind, result.ID), poster,
		share, film.ID, film.Path, film.Kind, film.Size, film.Modified)
	if err != nil {
		return err
	}
	n, err := updated.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrAssetChanged
	}
	return nil
}

// validateFilmSnapshot ensures remote metadata selected for an earlier scan
// cannot be attached to a replacement file at the same path. Read checks the
// current safe file handle against the indexed size and modification time;
// the UPDATE also repeats these values to catch a concurrent scan.
func (l *Library) validateFilmSnapshot(film Film) error {
	file, info, current, err := l.Read(film.ID, 0)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrAssetChanged
	}
	if err != nil {
		return err
	}
	defer file.Close()
	if current.Path != film.Path || current.Kind != film.Kind ||
		current.Size != film.Size || current.Modified != film.Modified ||
		info.Size() != film.Size || info.ModTime().UnixNano() != film.Modified {
		return ErrAssetChanged
	}
	return nil
}
