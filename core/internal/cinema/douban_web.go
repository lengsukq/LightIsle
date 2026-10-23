package cinema

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// This is a limited, user-initiated lookup of the Douban web site's
// (undocumented) suggestion response. It is NOT an official or stable API.
// If Douban restricts access, return an error; do not use cookies, captcha
// solving, header impersonation, proxies, retries, or bulk crawling.
const doubanSuggestEndpoint = "https://movie.douban.com/j/subject_suggest"

var doubanSubjectID = regexp.MustCompile(`^[0-9]{1,12}$`)

type DoubanCandidate struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Year  string `json:"year,omitempty"`
	Kind  string `json:"kind,omitempty"`
}
type doubanSuggestion struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Year  string `json:"year"`
	Type  string `json:"type"`
}
type DoubanWebService struct {
	endpoint string
	client   *http.Client
}

func (s DoubanWebService) Search(ctx context.Context, query string) ([]DoubanCandidate, error) {
	query = strings.TrimSpace(query)
	if len([]rune(query)) < 2 || len([]rune(query)) > 60 || strings.ContainsAny(query, "\x00\r\n") {
		return nil, ErrInvalid
	}
	endpoint := s.endpoint
	if endpoint == "" {
		endpoint = doubanSuggestEndpoint
	}
	if endpoint != doubanSuggestEndpoint && s.client == nil {
		return nil, ErrInvalid
	}
	requestCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, endpoint+"?q="+url.QueryEscape(query), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	httpClient := s.client
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("douban_web_unavailable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// No automated retry, CAPTCHA/login bypass or fingerprint spoofing.
		return nil, fmt.Errorf("douban_web_status_%d", resp.StatusCode)
	}
	const maxBody = 128 * 1024
	payload, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil || len(payload) > maxBody {
		return nil, errors.New("douban_web_response_unavailable")
	}
	var raw []doubanSuggestion
	if err := json.Unmarshal(payload, &raw); err != nil {
		return nil, errors.New("douban_web_response_unavailable")
	}
	result := make([]DoubanCandidate, 0, min(10, len(raw)))
	seen := make(map[string]bool)
	for _, item := range raw {
		item.Title = strings.TrimSpace(item.Title)
		if !doubanSubjectID.MatchString(item.ID) || len([]rune(item.Title)) < 1 ||
			len([]rune(item.Title)) > 150 || seen[item.ID] {
			continue
		}
		kind := strings.ToLower(item.Type)
		if kind != "" && kind != "movie" && kind != "tv" {
			continue
		}
		year := ""
		if len(item.Year) == 4 {
			if y, err := strconv.Atoi(item.Year); err == nil && y >= 1870 && y <= 2100 {
				year = item.Year
			}
		}
		seen[item.ID] = true
		result = append(result, DoubanCandidate{ID: item.ID, Title: item.Title, Year: year, Kind: kind})
		if len(result) >= 10 {
			break
		}
	}
	return result, nil
}

func (l *Library) SearchDouban(ctx context.Context, filmID int64, query string) ([]DoubanCandidate, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return nil, err
	}
	if query == "" {
		query = film.Title
	}
	return (DoubanWebService{}).Search(ctx, query)
}

func (l *Library) MatchDouban(ctx context.Context, filmID int64, query, id string) (Film, error) {
	return l.matchDoubanWithService(ctx, filmID, query, id, DoubanWebService{})
}

func (l *Library) matchDoubanWithService(ctx context.Context, filmID int64, query, id string, service DoubanWebService) (Film, error) {
	if !doubanSubjectID.MatchString(id) {
		return Film{}, ErrInvalid
	}
	film, err := l.Get(filmID, 0)
	if err != nil {
		return Film{}, err
	}
	if query == "" {
		query = film.Title
	}
	candidates, err := service.Search(ctx, query)
	if err != nil {
		return Film{}, err
	}
	for _, c := range candidates {
		if c.ID == id {
			if err = l.applyDoubanSuggestion(film, c); err != nil {
				return Film{}, err
			}
			return l.Get(filmID, 0)
		}
	}
	return Film{}, errors.New("douban_candidate_no_longer_found")
}
func (l *Library) applyDoubanSuggestion(film Film, selected DoubanCandidate) error {
	if err := l.validateFilmSnapshot(film); err != nil {
		return err
	}
	if !doubanSubjectID.MatchString(selected.ID) || selected.Title == "" ||
		(selected.Kind != "" && selected.Kind != "movie" && selected.Kind != "tv") {
		return ErrInvalid
	}
	if film.Kind == "movie" && selected.Kind == "tv" {
		return ErrInvalid
	}
	if film.Kind == "series" && selected.Kind == "movie" {
		return ErrInvalid
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	var year int
	if selected.Year != "" {
		year, err = strconv.Atoi(selected.Year)
		if err != nil || year < 1870 || year > 2100 {
			return ErrInvalid
		}
	}
	// Fallback is ONLY a brief web-search suggestion. Do not attribute plot,
	// ratings or posters to Douban or overwrite already curated rich data.
	// No original file, manual title or watch-progress row is modified.
	result, err := l.db.Exec(`UPDATE films SET
        title=CASE WHEN manual_title=1 THEN title ELSE ? END,
        title_source=CASE WHEN manual_title=1 THEN title_source ELSE ? END,
        year=CASE WHEN ? > 0 THEN ? ELSE year END,
        year_source=CASE WHEN ? > 0 THEN ? ELSE year_source END
		WHERE share=? AND id=? AND path=? AND kind=? AND size=? AND modified=?`,
		selected.Title, "douban-suggest:"+selected.ID, year, year,
		year, "douban-suggest:"+selected.ID, share, film.ID, film.Path, film.Kind, film.Size, film.Modified)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrAssetChanged
	}
	return nil
}
