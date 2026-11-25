package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func (a *API) familyBoardList(w http.ResponseWriter, r *http.Request) {
	tok := token(r)
	user, ok := a.auth.Identity(tok)
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	messages, err := a.auth.ListFamilyBoardMessages(tok, limit)
	if err != nil {
		writeFamilyBoardError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"messages":        messages,
		"isAdmin":         user.Role == auth.RoleAdmin,
		"currentUserId":   user.ID,
		"currentUsername": user.Username,
	})
}

func (a *API) familyBoardCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	defer r.Body.Close()
	var body struct {
		Content string `json:"content"`
		Tag     string `json:"tag"`
		Color   string `json:"color"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	msg, err := a.auth.CreateFamilyBoardMessage(token(r), body.Content, body.Tag, body.Color)
	if err != nil {
		writeFamilyBoardError(w, err)
		return
	}
	jsonReply(w, http.StatusCreated, map[string]any{"message": msg})
}

func (a *API) familyBoardPin(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_message_id")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
	defer r.Body.Close()
	var body struct {
		Pinned bool `json:"pinned"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	msg, err := a.auth.SetFamilyBoardMessagePinned(token(r), id, body.Pinned)
	if err != nil {
		writeFamilyBoardError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"message": msg})
}

func (a *API) familyBoardDelete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_message_id")
		return
	}
	if err := a.auth.DeleteFamilyBoardMessage(token(r), id); err != nil {
		writeFamilyBoardError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}

func writeFamilyBoardError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_board_message")
	case errors.Is(err, auth.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "forbidden")
	case errors.Is(err, auth.ErrNotFound):
		writeAPIErrorCode(w, http.StatusNotFound, "message_not_found")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "family_board_error")
	}
}
