package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
)

func (a *API) cinemaCollectionsList(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	list, err := a.cinema.ListCollectionsScoped(roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	// Ordinary members only see collections containing at least one authorized film.
	if viewer, authed := a.auth.Identity(token(r)); authed && viewer.Role != auth.RoleAdmin {
		visible := make([]cinema.Collection, 0, len(list))
		for _, item := range list {
			if item.Count > 0 {
				visible = append(visible, item)
			}
		}
		list = visible
	}
	jsonReply(w, http.StatusOK, map[string]any{"collections": list})
}

func (a *API) cinemaCollectionCreate(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
	defer r.Body.Close()
	var body struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	col, err := a.cinema.CreateCollection(body.Name, body.Description)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusCreated, col)
}

func (a *API) cinemaCollectionUpdate(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
	defer r.Body.Close()
	var body struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := a.cinema.UpdateCollection(id, body.Name, body.Description); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"updated": true})
}

func (a *API) cinemaCollectionDelete(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	if err := a.cinema.DeleteCollection(id); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (a *API) cinemaCollectionFilms(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	userID := a.viewerID(w, r)
	if userID == 0 {
		return
	}
	films, err := a.cinema.ListCollectionFilmsScoped(userID, id, roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	for idx := range films {
		films[idx].CanWrite = a.canAccess(token(r), films[idx].Path, true, false)
	}
	jsonReply(w, http.StatusOK, map[string]any{"films": films})
}

func (a *API) cinemaCollectionAddFilm(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		FilmID int64 `json:"filmId"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.FilmID <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := a.cinema.AddFilmToCollection(id, body.FilmID); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"added": true})
}

func (a *API) cinemaCollectionRemoveFilm(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	filmID, err := strconv.ParseInt(r.PathValue("filmID"), 10, 64)
	if err != nil || filmID <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_film_id")
		return
	}
	if err := a.cinema.RemoveFilmFromCollection(id, filmID); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"removed": true})
}

func (a *API) cinemaSearchOnlineSubtitles(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	userID := a.viewerID(w, r)
	if userID == 0 {
		return
	}
	film, err := a.cinema.Get(id, userID)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, film.Path, false, "film_not_found") {
		return
	}
	var body struct {
		Query string `json:"query"`
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
		defer r.Body.Close()
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
			return
		}
	}
	query := strings.TrimSpace(body.Query)
	if query == "" {
		query = strings.TrimSpace(film.Title)
		if query == "" {
			query = strings.TrimSuffix(path.Base(film.Path), path.Ext(film.Path))
		}
	}
	candidates, err := cinema.SearchOnlineSubtitles(r.Context(), query)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"query": query, "candidates": candidates})
}

func (a *API) cinemaDownloadOnlineSubtitle(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	userID := a.viewerID(w, r)
	if userID == 0 {
		return
	}
	film, err := a.cinema.Get(id, userID)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, film.Path, true, "film_not_found") {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	defer r.Body.Close()
	var body struct {
		URL      string `json:"url"`
		Language string `json:"language"`
		Ext      string `json:"ext"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	savedPath, err := a.cinema.SaveOnlineSubtitle(r.Context(), film.Path, body.URL, body.Language, body.Ext)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, http.StatusCreated, map[string]string{
		"savedPath": savedPath,
		"fileName":  path.Base(savedPath),
	})
}
