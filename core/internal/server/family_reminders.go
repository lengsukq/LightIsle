package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func (a *API) familyRemindersList(w http.ResponseWriter, r *http.Request) {
	tok := token(r)
	user, ok := a.auth.Identity(tok)
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	q := r.URL.Query()
	withinDays := 0
	rawDays := strings.TrimSpace(q.Get("days"))
	if rawDays == "" {
		rawDays = strings.TrimSpace(q.Get("withinDays"))
	}
	if rawDays != "" {
		parsed, err := strconv.Atoi(rawDays)
		if err != nil || parsed < 0 || parsed > 3650 {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_request")
			return
		}
		withinDays = parsed
	}
	category := strings.ToLower(strings.TrimSpace(q.Get("category")))
	now := time.Now()
	reminders, err := a.auth.ListFamilyReminders(tok, withinDays, category, now)
	if err != nil {
		writeFamilyReminderError(w, err)
		return
	}
	resp := map[string]any{
		"reminders":       reminders,
		"todaySolar":      now.Format("2006-01-02"),
		"isAdmin":         user.Role == auth.RoleAdmin,
		"currentUserId":   user.ID,
		"currentUsername": user.Username,
	}
	if todayLunar, err := auth.SolarToLunar(now); err == nil {
		resp["todayLunar"] = todayLunar
	}
	jsonReply(w, http.StatusOK, resp)
}

func (a *API) familyRemindersCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	defer r.Body.Close()
	var input auth.FamilyReminderInput
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&input); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_request")
		return
	}
	reminder, err := a.auth.CreateFamilyReminder(token(r), input, time.Now())
	if err != nil {
		writeFamilyReminderError(w, err)
		return
	}
	jsonReply(w, http.StatusCreated, map[string]any{"reminder": reminder})
}

func (a *API) familyRemindersUpdate(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_id")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	defer r.Body.Close()
	var patch auth.FamilyReminderPatch
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&patch); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_request")
		return
	}
	reminder, err := a.auth.UpdateFamilyReminder(token(r), id, patch, time.Now())
	if err != nil {
		writeFamilyReminderError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"reminder": reminder})
}

func (a *API) familyRemindersDelete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_id")
		return
	}
	if err := a.auth.DeleteFamilyReminder(token(r), id); err != nil {
		writeFamilyReminderError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}

func (a *API) familyRemindersComplete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_id")
		return
	}
	reminder, err := a.auth.CompleteFamilyReminder(token(r), id, time.Now())
	if err != nil {
		writeFamilyReminderError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"completed": true, "reminder": reminder})
}

func writeFamilyReminderError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInput), errors.Is(err, auth.ErrLunarOutOfRange):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reminder_request")
	case errors.Is(err, auth.ErrExists):
		writeAPIErrorCode(w, http.StatusConflict, "reminder_limit_reached")
	case errors.Is(err, auth.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "reminder_permission_denied")
	case errors.Is(err, auth.ErrNotFound):
		writeAPIErrorCode(w, http.StatusNotFound, "reminder_not_found")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "family_reminder_error")
	}
}
