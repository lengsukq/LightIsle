package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func (a *API) getCleanupRules(w http.ResponseWriter, r *http.Request) {
	days, err := a.auth.UploadRetentionDays()
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "cleanup_rules_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]any{"uploadRetentionDays": days})
}

func (a *API) setCleanupRules(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var request struct {
		UploadRetentionDays *int `json:"uploadRetentionDays"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF || request.UploadRetentionDays == nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_cleanup_rules"})
		return
	}
	if err := a.auth.SetUploadRetentionDays(token(r), *request.UploadRetentionDays); err != nil {
		switch {
		case errors.Is(err, auth.ErrInput):
			jsonReply(w, 400, map[string]string{"error": "invalid_cleanup_rules"})
		case errors.Is(err, auth.ErrForbidden):
			jsonReply(w, 403, map[string]string{"error": "admin_only"})
		default:
			jsonReply(w, 503, map[string]string{"error": "cleanup_rules_unavailable"})
		}
		return
	}
	jsonReply(w, 200, map[string]any{"uploadRetentionDays": *request.UploadRetentionDays})
}
