package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

func registerAppsManagementRoutes(
	mux *http.ServeMux,
	a *API,
	appsMgr *apps.Manager,
	store *auth.Store,
	resolveSession func(*http.Request) (apps.UserIdentity, bool),
) {
	mux.HandleFunc("GET /api/v2/apps", a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		user, ok := resolveSession(r)
		if !ok {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		replyAppsList(w, appsMgr, store, user)
	}))

	handleRefresh := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		if err := appsMgr.Reload(); err != nil {
			appsErrorReply(w, err)
			return
		}
		replyAppsList(w, appsMgr, store, user)
	})
	mux.HandleFunc("POST /api/v2/apps/refresh", handleRefresh)
	mux.HandleFunc("POST /api/v2/apps/reload", handleRefresh)

	mux.HandleFunc("GET /api/v2/apps/{id}", a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		user, ok := resolveSession(r)
		if !ok {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		app, err := appsMgr.GetForUser(r.PathValue("id"), user.ID, user.Role)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"app": app})
	}))

	handleUpdateApp := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
		defer r.Body.Close()
		var req apps.AppUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		app, err := appsMgr.UpdateApp(r.PathValue("id"), req)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"app":  app,
			"apps": appsMgr.ListForUser(user.ID, user.Role),
		})
	})
	mux.HandleFunc("PUT /api/v2/apps/{id}", handleUpdateApp)
	mux.HandleFunc("PATCH /api/v2/apps/{id}", handleUpdateApp)

	mux.HandleFunc("DELETE /api/v2/apps/{id}", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		deleteData := r.URL.Query().Get("deleteData") == "true" || r.URL.Query().Get("deleteData") == "1"
		if !deleteData && r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
			var body struct {
				DeleteData bool `json:"deleteData"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err == nil && body.DeleteData {
				deleteData = true
			}
		}
		if err := appsMgr.DeleteApp(r.PathValue("id"), deleteData); err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"deleted": true,
			"apps":    appsMgr.ListForUser(user.ID, user.Role),
		})
	}))

	handleIssueTicket := a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		user, ok := resolveSession(r)
		if !ok {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		id := r.PathValue("id")
		if !appsMgr.CanAccess(id, user.ID, user.Role) {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "app_access_forbidden"})
			return
		}
		app, err := appsMgr.GetForUser(id, user.ID, user.Role)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		if app.PendingActivation {
			appsErrorReply(w, apps.ErrPendingActivation)
			return
		}
		isLaunch := strings.HasSuffix(r.URL.Path, "/launch")
		if isLaunch && app.Web.Enabled && app.Web.Mode != apps.WebModeStatic && app.Web.Mode != "none" {
			woken, wakeErr := appsMgr.WakeApp(r.Context(), id)
			if wakeErr != nil {
				if user.Role != auth.RoleAdmin {
					jsonReply(w, http.StatusBadGateway, map[string]string{
						"error":   "app_operation_failed",
						"message": "该轻应用暂时无法启动，你的个人数据不受影响，请联系管理员处理。",
					})
					return
				}
				appsErrorReply(w, wakeErr)
				return
			}
			app = woken
		}
		ticket := appsMgr.IssueTicket(id, user)
		jsonReply(w, http.StatusOK, map[string]any{
			"id":         id,
			"status":     app.Web.Status,
			"app":        app,
			"ticket":     ticket,
			"launchUrl":  "/apps/" + id + "/?__li_ticket=" + ticket,
			"launchPath": "/apps/" + id + "/",
			"expiresIn":  60,
		})
	})
	mux.HandleFunc("POST /api/v2/apps/{id}/ticket", handleIssueTicket)
	mux.HandleFunc("POST /api/v2/apps/{id}/launch", handleIssueTicket)

	handleDirectAction := func(action string) http.HandlerFunc {
		return a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
			app, err := appsMgr.ExecuteAction(r.Context(), r.PathValue("id"), action)
			if err != nil {
				appsErrorReply(w, err)
				return
			}
			jsonReply(w, http.StatusOK, map[string]any{"app": app})
		})
	}
	mux.HandleFunc("POST /api/v2/apps/{id}/start", handleDirectAction("start"))
	mux.HandleFunc("POST /api/v2/apps/{id}/wake", handleDirectAction("wake"))
	mux.HandleFunc("POST /api/v2/apps/{id}/stop", handleDirectAction("stop"))
	mux.HandleFunc("POST /api/v2/apps/{id}/restart", handleDirectAction("restart"))
	mux.HandleFunc("POST /api/v2/apps/{id}/approve", handleDirectAction("approve"))
	mux.HandleFunc("POST /api/v2/apps/{id}/activate", handleDirectAction("activate"))

	handleAppAction := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		id := r.PathValue("id")
		r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
		defer r.Body.Close()
		var body struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		action := strings.ToLower(strings.TrimSpace(body.Action))
		switch action {
		case "start", "wake", "stop", "restart", "trigger-cron", "run_cron", "approve", "activate":
		default:
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_action"})
			return
		}
		app, err := appsMgr.ExecuteAction(r.Context(), id, action)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"ok":   true,
			"app":  app,
			"apps": appsMgr.ListForUser(user.ID, user.Role),
		})
	})
	mux.HandleFunc("POST /api/v2/apps/{id}/action", handleAppAction)
	mux.HandleFunc("POST /api/v2/apps/{id}/actions", handleAppAction)

	mux.HandleFunc("GET /api/v2/apps/{id}/logs", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		logs, err := appsMgr.GetWebLogs(id)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		runs, _ := appsMgr.GetCronRuns(id, 30)
		jsonReply(w, http.StatusOK, map[string]any{
			"id":        id,
			"webOutput": logs,
			"cronRuns":  runs,
			"logs":      logs,
			"runs":      runs,
		})
	}))

	mux.HandleFunc("GET /api/v2/apps/{id}/runs", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		runs, err := appsMgr.GetCronRuns(r.PathValue("id"), 30)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"runs": runs})
	}))

	mux.HandleFunc("POST /api/v2/apps/{id}/cron/run", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		if _, err := appsMgr.ExecuteAction(r.Context(), r.PathValue("id"), "trigger-cron"); err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]bool{"triggered": true})
	}))

	mux.HandleFunc("GET /api/v2/apps/{id}/icon", a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		user, ok := resolveSession(r)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		if !appsMgr.CanAccess(id, user.ID, user.Role) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		appsMgr.ServeIcon(w, r, id)
	}))

	mux.HandleFunc("GET /api/v2/apps/{id}/data-backup", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if _, err := appsMgr.GetForUser(id, 0, auth.RoleAdmin); err != nil {
			appsErrorReply(w, err)
			return
		}
		tmpFile, err := os.CreateTemp("", "lightisle-app-backup-*.tar.gz")
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		tmpPath := tmpFile.Name()
		defer func() {
			_ = tmpFile.Close()
			_ = os.Remove(tmpPath)
		}()
		if err := appsMgr.ExportAppData(r.Context(), id, tmpFile); err != nil {
			appsErrorReply(w, err)
			return
		}
		if err := tmpFile.Sync(); err != nil {
			appsErrorReply(w, err)
			return
		}
		st, err := tmpFile.Stat()
		if err != nil || st.Size() <= 0 {
			appsErrorReply(w, errors.New("生成备份归档为空或失败"))
			return
		}
		if _, err := tmpFile.Seek(0, io.SeekStart); err != nil {
			appsErrorReply(w, err)
			return
		}
		w.Header().Set("Content-Type", "application/gzip")
		w.Header().Set("Content-Length", strconv.FormatInt(st.Size(), 10))
		w.Header().Set("Content-Disposition", "attachment; filename=\""+id+"-data-backup.tar.gz\"")
		w.WriteHeader(http.StatusOK)
		_, _ = io.Copy(w, tmpFile)
	}))

	mux.HandleFunc("POST /api/v2/apps/{id}/data-restore", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		id := r.PathValue("id")
		r.Body = http.MaxBytesReader(w, r.Body, (512<<20)+(1<<20))
		defer r.Body.Close()
		if err := appsMgr.RestoreAppData(r.Context(), id, r.Body); err != nil {
			appsErrorReply(w, err)
			return
		}
		replyAppsList(w, appsMgr, store, user)
	}))
}
