package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"os"

	"github.com/lengsukq/lightisle/core/internal/cinema"
)

// On-demand, limited fallback for local movie matching. The upstream web
// suggestion is not an official API; blocked/unavailable means no fallback.
func (a *API) cinemaDoubanSearch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var input struct {
		Query string `json:"query"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		writeAPIErrorCode(w, 400, "invalid_douban_query")
		return
	}
	results, err := a.cinema.SearchDouban(r.Context(), id, input.Query)
	if errors.Is(err, cinema.ErrInvalid) {
		writeAPIErrorCode(w, 400, "invalid_douban_query")
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		writeAPIErrorCode(w, 404, "film_not_found")
		return
	}
	if err != nil {
		writeAPIErrorCode(w, 502, "douban_web_unavailable")
		return
	}
	jsonReply(w, 200, map[string]any{"results": results})
}

func (a *API) cinemaDoubanMatch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var input struct {
		Query    string `json:"query"`
		DoubanID string `json:"doubanId"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		writeAPIErrorCode(w, 400, "invalid_douban_request")
		return
	}
	film, err := a.cinema.MatchDouban(r.Context(), id, input.Query, input.DoubanID)
	if errors.Is(err, cinema.ErrInvalid) {
		writeAPIErrorCode(w, 400, "invalid_douban_request")
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		writeAPIErrorCode(w, 404, "film_not_found")
		return
	}
	if errors.Is(err, cinema.ErrAssetChanged) {
		writeAPIErrorCode(w, 409, "asset_changed_rescan_required")
		return
	}
	if err != nil {
		writeAPIErrorCode(w, 502, "douban_web_unavailable")
		return
	}
	jsonReply(w, 200, film)
}

func cinemaTMDBError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, cinema.ErrInvalid):
		writeAPIErrorCode(w, 400, "invalid_tmdb_request")
	case errors.Is(err, sql.ErrNoRows):
		writeAPIErrorCode(w, 404, "film_not_found")
	case isTMDBAuthenticationFailure(err):
		writeAPIErrorCode(w, 401, "tmdb_auth_failed")
	case isTMDBAccessDenied(err):
		writeAPIErrorCode(w, 403, "tmdb_access_denied")
	default:
		// Timeout, rate limiting or malformed upstream results are generic
		// failures; never include token-bearing request details in responses.
		writeAPIErrorCode(w, 502, "tmdb_upstream_failed")
	}
}

// TMDBService currently represents upstream HTTP status responses with these
// opaque errors. Translate only the exact status codes needed by the client;
// keep all other upstream details private and map them to the generic failure.
func isTMDBAuthenticationFailure(err error) bool {
	return err != nil && err.Error() == "tmdb_upstream_status_401"
}

func isTMDBAccessDenied(err error) bool {
	return err != nil && err.Error() == "tmdb_upstream_status_403"
}

func (a *API) cinemaTMDBSearch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var request struct {
		AccessToken string `json:"accessToken"`
		Query       string `json:"query"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		writeAPIErrorCode(w, 400, "invalid_tmdb_request")
		return
	}
	result, err := a.cinema.SearchTMDB(r.Context(), request.AccessToken, id, request.Query)
	if err != nil {
		cinemaTMDBError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"results": result})
}

func (a *API) cinemaTMDBMatch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var request struct {
		AccessToken string `json:"accessToken"`
		TMDBID      int64  `json:"tmdbId"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || request.TMDBID < 1 {
		writeAPIErrorCode(w, 400, "invalid_tmdb_request")
		return
	}
	film, err := a.cinema.MatchTMDB(r.Context(), request.AccessToken, id, request.TMDBID)
	if err != nil {
		cinemaTMDBError(w, err)
		return
	}
	jsonReply(w, 200, film)
}

func (a *API) cinemaImportNFO(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	film, err := a.cinema.ImportLocalNFO(id)
	if errors.Is(err, sql.ErrNoRows) {
		writeAPIErrorCode(w, 404, "film_not_found")
		return
	}
	if errors.Is(err, os.ErrNotExist) {
		writeAPIErrorCode(w, 404, "nfo_not_found")
		return
	}
	if errors.Is(err, cinema.ErrInvalid) {
		writeAPIErrorCode(w, 400, "invalid_nfo")
		return
	}
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, film)
}
