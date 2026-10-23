package server

import (
	"net/http"
)

func (a *API) alertList(w http.ResponseWriter, r *http.Request) {
	if a.journal == nil {
		jsonReply(w, 503, map[string]string{"error": "alert_center_unavailable"})
		return
	}
	alerts, err := a.journal.Alerts(r.URL.Query().Get("history") != "1")
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "alert_center_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]any{"alerts": alerts})
}
func (a *API) alertAcknowledge(w http.ResponseWriter, r *http.Request) {
	if a.journal == nil {
		jsonReply(w, 503, map[string]string{"error": "alert_center_unavailable"})
		return
	}
	if err := a.journal.AcknowledgeAlert(r.PathValue("code")); err != nil {
		jsonReply(w, 404, map[string]string{"error": "alert_not_active"})
		return
	}
	jsonReply(w, 200, map[string]bool{"acknowledged": true})
}
