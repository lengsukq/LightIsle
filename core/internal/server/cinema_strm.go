package server

import (
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/cinema"
)

func (a *API) cinemaStrmTarget(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	user := a.viewerID(w, r)
	if user == 0 {
		return
	}
	requested, err := a.cinema.Get(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, requested.Path, false, "film_not_found") {
		return
	}
	targetURL, _, err := a.cinema.ReadStrmTarget(id, user)
	if err != nil {
		switch {
		case errors.Is(err, cinema.ErrForbiddenStrmURL):
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "forbidden_strm_url"})
		case errors.Is(err, cinema.ErrInvalidStrmURL), errors.Is(err, cinema.ErrInvalid):
			jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "invalid_strm_url"})
		default:
			cinemaError(w, err)
		}
		return
	}
	jsonReply(w, http.StatusOK, map[string]string{
		"url":  targetURL,
		"host": cinema.StrmHostSummary(targetURL),
		"mime": cinema.InferStrmMime(targetURL),
	})
}
