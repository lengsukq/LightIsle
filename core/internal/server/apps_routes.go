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

type appsManagementHandler struct {
	api            *API
	appsMgr        *apps.Manager
	store          *auth.Store
	resolveSession func(*http.Request) (apps.UserIdentity, bool)
}

func registerAppsManagementRoutes(
	mux *http.ServeMux,
	a *API,
	appsMgr *apps.Manager,
	store *auth.Store,
	resolveSession func(*http.Request) (apps.UserIdentity, bool),
) {
	h := &appsManagementHandler{
		api:            a,
		appsMgr:        appsMgr,
		store:          store,
		resolveSession: resolveSession,
	}
	h.register(mux)
}

func (h *appsManagementHandler) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v2/apps", h.api.requireLogin(h.handleListApps))
	mux.HandleFunc("GET /api/v2/apps/templates", h.api.requireLogin(h.handleListTemplates))
	mux.HandleFunc("POST /api/v2/apps/templates/{id}/install", h.api.requireAdmin(h.handleInstallTemplate))

	mux.HandleFunc("GET /api/v2/apps/storage", h.api.requireAdmin(h.handleGetStorage))
	mux.HandleFunc("PUT /api/v2/apps/storage", h.api.requireAdmin(h.handleMutateStorage))
	mux.HandleFunc("POST /api/v2/apps/storage", h.api.requireAdmin(h.handleMutateStorage))

	reload := h.api.requireAdmin(h.handleReloadApps)
	mux.HandleFunc("POST /api/v2/apps/refresh", reload)
	mux.HandleFunc("POST /api/v2/apps/reload", reload)

	mux.HandleFunc("GET /api/v2/apps/{id}", h.api.requireLogin(h.handleGetApp))

	update := h.api.requireAdmin(h.handleUpdateApp)
	mux.HandleFunc("PUT /api/v2/apps/{id}", update)
	mux.HandleFunc("PATCH /api/v2/apps/{id}", update)

	mux.HandleFunc("DELETE /api/v2/apps/{id}", h.api.requireAdmin(h.handleDeleteApp))

	issueTicket := h.api.requireLogin(h.handleIssueTicketOrLaunch)
	mux.HandleFunc("POST /api/v2/apps/{id}/ticket", issueTicket)
	mux.HandleFunc("POST /api/v2/apps/{id}/launch", issueTicket)

	for _, action := range []string{"start", "wake", "stop", "restart", "approve", "activate"} {
		mux.HandleFunc("POST /api/v2/apps/{id}/"+action, h.handleDirectAction(action))
	}

	dispatchAction := h.api.requireAdmin(h.handleAppAction)
	mux.HandleFunc("POST /api/v2/apps/{id}/action", dispatchAction)
	mux.HandleFunc("POST /api/v2/apps/{id}/actions", dispatchAction)

	mux.HandleFunc("GET /api/v2/apps/{id}/logs", h.api.requireAdmin(h.handleGetAppLogs))
	mux.HandleFunc("GET /api/v2/apps/{id}/runs", h.api.requireAdmin(h.handleGetAppRuns))
	mux.HandleFunc("POST /api/v2/apps/{id}/cron/run", h.api.requireAdmin(h.handleTriggerCron))
	mux.HandleFunc("GET /api/v2/apps/{id}/icon", h.api.requireLogin(h.handleServeIcon))
	mux.HandleFunc("GET /api/v2/apps/{id}/data-backup", h.api.requireAdmin(h.handleExportDataBackup))
	mux.HandleFunc("POST /api/v2/apps/{id}/data-restore", h.api.requireAdmin(h.handleRestoreDataBackup))
}

func (h *appsManagementHandler) handleListApps(w http.ResponseWriter, r *http.Request) {
	user, ok := h.resolveSession(r)
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	if isMCPManagementRequest(r) {
		jsonReply(w, http.StatusOK, map[string]any{"apps": h.appsMgr.ListForUser(user.ID, user.Role)})
		return
	}
	replyAppsList(w, h.appsMgr, h.store, user)
}

func (h *appsManagementHandler) handleListTemplates(w http.ResponseWriter, _ *http.Request) {
	jsonReply(w, http.StatusOK, map[string]any{"templates": h.appsMgr.ListTemplates()})
}

func (h *appsManagementHandler) handleInstallTemplate(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	var body struct {
		LocationID string `json:"locationId"`
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
		defer r.Body.Close()
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
	}
	app, err := h.appsMgr.InstallTemplateAt(r.PathValue("id"), body.LocationID)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusCreated, map[string]any{
		"app":        app,
		"apps":       h.appsMgr.ListForUser(user.ID, user.Role),
		"templates":  h.appsMgr.ListTemplates(),
		"appStorage": h.appsMgr.GetStorageSnapshot(),
	})
}

func (h *appsManagementHandler) handleGetStorage(w http.ResponseWriter, _ *http.Request) {
	jsonReply(w, http.StatusOK, map[string]any{
		"appStorage": h.appsMgr.GetStorageSnapshot(),
	})
}

func (h *appsManagementHandler) handleMutateStorage(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	defer r.Body.Close()
	var req apps.AppStorageMutationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request", "message": "无效的存储位置请求参数"})
		return
	}
	storageSnap, err := h.appsMgr.MutateStorageLocation(req)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	mcpSnap := h.appsMgr.BuildMCPConfigSnapshot("")
	jsonReply(w, http.StatusOK, map[string]any{
		"appStorage":    storageSnap,
		"apps":          h.appsMgr.ListForUser(user.ID, user.Role),
		"templates":     h.appsMgr.ListTemplates(),
		"pluginsDir":    mcpSnap.PluginsDir,
		"pluginDataDir": mcpSnap.PluginDataDir,
	})
}

func (h *appsManagementHandler) handleReloadApps(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	if err := h.appsMgr.Reload(); err != nil {
		appsErrorReply(w, err)
		return
	}
	replyAppsList(w, h.appsMgr, h.store, user)
}

func (h *appsManagementHandler) handleGetApp(w http.ResponseWriter, r *http.Request) {
	user, ok := h.resolveSession(r)
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	app, err := h.appsMgr.GetForUser(r.PathValue("id"), user.ID, user.Role)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"app": app})
}

func (h *appsManagementHandler) handleUpdateApp(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	defer r.Body.Close()
	var req apps.AppUpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	req.RequireApproved = isMCPManagementRequest(r)
	app, err := h.appsMgr.UpdateApp(r.PathValue("id"), req)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"app":  app,
		"apps": h.appsMgr.ListForUser(user.ID, user.Role),
	})
}

func (h *appsManagementHandler) handleDeleteApp(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	deleteData := parseDeleteAppDataFlag(w, r)
	if err := h.appsMgr.DeleteApp(r.PathValue("id"), deleteData); err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"deleted": true,
		"apps":    h.appsMgr.ListForUser(user.ID, user.Role),
	})
}

func parseDeleteAppDataFlag(w http.ResponseWriter, r *http.Request) bool {
	queryFlag := r.URL.Query().Get("deleteData")
	if queryFlag == "true" || queryFlag == "1" {
		return true
	}
	if r.Body == nil {
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2<<10)
	var body struct {
		DeleteData bool `json:"deleteData"`
	}
	return json.NewDecoder(r.Body).Decode(&body) == nil && body.DeleteData
}

func (h *appsManagementHandler) handleIssueTicketOrLaunch(w http.ResponseWriter, r *http.Request) {
	user, ok := h.resolveSession(r)
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	id := r.PathValue("id")
	if !h.appsMgr.CanAccess(id, user.ID, user.Role) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "app_access_forbidden"})
		return
	}
	app, err := h.appsMgr.GetForUser(id, user.ID, user.Role)
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
		woken, wakeErr := h.appsMgr.WakeApp(r.Context(), id)
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
	ticket := h.appsMgr.IssueTicket(id, user)
	jsonReply(w, http.StatusOK, map[string]any{
		"id":         id,
		"status":     app.Web.Status,
		"app":        app,
		"ticket":     ticket,
		"launchUrl":  "/apps/" + id + "/?__li_ticket=" + ticket,
		"launchPath": "/apps/" + id + "/",
		"expiresIn":  60,
	})
}

func (h *appsManagementHandler) handleDirectAction(action string) http.HandlerFunc {
	return h.api.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		app, err := h.appsMgr.ExecuteAction(r.Context(), r.PathValue("id"), action)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"app": app})
	})
}

func (h *appsManagementHandler) handleAppAction(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
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
	if !isSupportedDispatchedAppAction(action) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_action"})
		return
	}
	app, err := h.appsMgr.ExecuteAction(r.Context(), id, action)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"ok":   true,
		"app":  app,
		"apps": h.appsMgr.ListForUser(user.ID, user.Role),
	})
}

func isSupportedDispatchedAppAction(action string) bool {
	switch action {
	case "start", "wake", "stop", "restart", "trigger-cron", "run_cron", "approve", "activate":
		return true
	default:
		return false
	}
}

func (h *appsManagementHandler) handleGetAppLogs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	logs, err := h.appsMgr.GetWebLogs(id)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	runs, _ := h.appsMgr.GetCronRuns(id, 30)
	jsonReply(w, http.StatusOK, map[string]any{
		"id":        id,
		"webOutput": logs,
		"cronRuns":  runs,
		"logs":      logs,
		"runs":      runs,
	})
}

func (h *appsManagementHandler) handleGetAppRuns(w http.ResponseWriter, r *http.Request) {
	runs, err := h.appsMgr.GetCronRuns(r.PathValue("id"), 30)
	if err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"runs": runs})
}

func (h *appsManagementHandler) handleTriggerCron(w http.ResponseWriter, r *http.Request) {
	if _, err := h.appsMgr.ExecuteAction(r.Context(), r.PathValue("id"), "trigger-cron"); err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"triggered": true})
}

func (h *appsManagementHandler) handleServeIcon(w http.ResponseWriter, r *http.Request) {
	user, ok := h.resolveSession(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	id := r.PathValue("id")
	if !h.appsMgr.CanAccess(id, user.ID, user.Role) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	h.appsMgr.ServeIcon(w, r, id)
}

func (h *appsManagementHandler) handleExportDataBackup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.appsMgr.GetForUser(id, 0, auth.RoleAdmin); err != nil {
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
	if err := h.appsMgr.ExportAppData(r.Context(), id, tmpFile); err != nil {
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
}

func (h *appsManagementHandler) handleRestoreDataBackup(w http.ResponseWriter, r *http.Request) {
	user, _ := h.resolveSession(r)
	id := r.PathValue("id")
	r.Body = http.MaxBytesReader(w, r.Body, (512<<20)+(1<<20))
	defer r.Body.Close()
	if err := h.appsMgr.RestoreAppData(r.Context(), id, r.Body); err != nil {
		appsErrorReply(w, err)
		return
	}
	replyAppsList(w, h.appsMgr, h.store, user)
}
