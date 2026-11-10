package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

// WithApps mounts the LightIsle App Center & Plugin Gateway (/api/v2/apps* and /apps/*)
// and enforces the Origin Isolation Guard preventing pages under /apps/* from calling /api/v2/*.
func WithApps(next http.Handler, dataDir string, store *auth.Store, appsMgr *apps.Manager) http.Handler {
	if appsMgr == nil && dataDir != "" {
		appsMgr = apps.NewManager(dataDir, "", nil)
		_ = appsMgr.Reload()
	}
	if appsMgr != nil && store != nil {
		appsMgr.SetUserVerifier(func(u apps.UserIdentity) (apps.UserIdentity, bool) {
			if u.SessionToken != "" {
				live, ok := store.Identity(u.SessionToken)
				if !ok || live.ID != u.ID {
					return apps.UserIdentity{}, false
				}
				return apps.UserIdentity{
					ID:           live.ID,
					Username:     live.Username,
					Role:         live.Role,
					SessionToken: u.SessionToken,
				}, true
			}
			live, err := store.GetUser(u.ID)
			if err != nil || !live.Enabled {
				return apps.UserIdentity{}, false
			}
			return apps.UserIdentity{
				ID:       live.ID,
				Username: live.Username,
				Role:     live.Role,
			}, true
		})
	}
	a := &API{auth: store}
	resolveSession := func(r *http.Request) (apps.UserIdentity, bool) {
		if store == nil {
			return apps.UserIdentity{}, false
		}
		tok := token(r)
		if tok == "" {
			return apps.UserIdentity{}, false
		}
		u, ok := store.Identity(tok)
		if !ok {
			return apps.UserIdentity{}, false
		}
		return apps.UserIdentity{
			ID:           u.ID,
			Username:     u.Username,
			Role:         u.Role,
			SessionToken: tok,
		}, true
	}

	mux := http.NewServeMux()

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

	handleGetMCP := a.requireAdmin(func(w http.ResponseWriter, _ *http.Request) {
		cfg := appsMgr.GetSystemConfig()
		jsonReply(w, http.StatusOK, map[string]any{
			"mcpEnabled":    cfg.MCPEnabled,
			"mcpPrompt":     appsMgr.MCPBootstrapPrompt(),
			"updatedAt":     cfg.UpdatedAt,
			"config":        cfg,
			"pluginsDir":    appsMgr.PluginsDir(),
			"pluginDataDir": appsMgr.PluginDataRoot(),
			"command":       appsMgr.MCPCommand(),
		})
	})
	mux.HandleFunc("GET /api/v2/apps/mcp", handleGetMCP)
	mux.HandleFunc("GET /api/v2/apps/config", handleGetMCP)

	handleSetMCP := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		defer r.Body.Close()
		var body struct {
			MCPEnabled *bool `json:"mcpEnabled"`
			Enabled    *bool `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		var enabled bool
		switch {
		case body.MCPEnabled != nil:
			enabled = *body.MCPEnabled
		case body.Enabled != nil:
			enabled = *body.Enabled
		default:
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		if err := appsMgr.SetMCPEnabled(enabled); err != nil {
			appsErrorReply(w, err)
			return
		}
		cfg := appsMgr.GetSystemConfig()
		jsonReply(w, http.StatusOK, map[string]any{
			"mcpEnabled":    cfg.MCPEnabled,
			"mcpPrompt":     appsMgr.MCPBootstrapPrompt(),
			"updatedAt":     cfg.UpdatedAt,
			"config":        cfg,
			"pluginsDir":    appsMgr.PluginsDir(),
			"pluginDataDir": appsMgr.PluginDataRoot(),
			"command":       appsMgr.MCPCommand(),
		})
	})
	mux.HandleFunc("PUT /api/v2/apps/mcp", handleSetMCP)
	mux.HandleFunc("POST /api/v2/apps/mcp", handleSetMCP)
	mux.HandleFunc("PUT /api/v2/apps/config", handleSetMCP)

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
		isLaunch := strings.HasSuffix(r.URL.Path, "/launch")
		if app.PendingActivation {
			if user.Role != auth.RoleAdmin || !isLaunch {
				appsErrorReply(w, apps.ErrPendingActivation)
				return
			}
			appsMgr.ActivateApp(id)
			app, err = appsMgr.GetForUser(id, user.ID, user.Role)
			if err != nil {
				appsErrorReply(w, err)
				return
			}
		}
		if isLaunch && app.Web.Enabled && app.Web.Mode != apps.WebModeStatic && app.Web.Mode != "none" {
			woken, wakeErr := appsMgr.WakeApp(r.Context(), id)
			if wakeErr != nil {
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

	handleWake := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		appsMgr.ActivateApp(id)
		app, err := appsMgr.WakeApp(r.Context(), id)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"app": app})
	})
	mux.HandleFunc("POST /api/v2/apps/{id}/start", handleWake)
	mux.HandleFunc("POST /api/v2/apps/{id}/wake", handleWake)

	mux.HandleFunc("POST /api/v2/apps/{id}/stop", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		app, err := appsMgr.StopApp(r.PathValue("id"))
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"app": app})
	}))

	mux.HandleFunc("POST /api/v2/apps/{id}/restart", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		app, err := appsMgr.RestartApp(r.Context(), r.PathValue("id"))
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"app": app})
	}))

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
		var (
			app apps.PublicApp
			err error
		)
		switch body.Action {
		case "start", "wake":
			appsMgr.ActivateApp(id)
			app, err = appsMgr.WakeApp(r.Context(), id)
		case "activate":
			appsMgr.ActivateApp(id)
			app, err = appsMgr.GetForUser(id, 0, auth.RoleAdmin)
		case "stop":
			app, err = appsMgr.StopApp(id)
		case "restart":
			app, err = appsMgr.RestartApp(r.Context(), id)
		case "run_cron":
			err = appsMgr.TriggerCron(id)
			if err == nil {
				app, err = appsMgr.GetForUser(id, 0, auth.RoleAdmin)
			}
		default:
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_action"})
			return
		}
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
		if err := appsMgr.TriggerCron(r.PathValue("id")); err != nil {
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

	securedAPIMux := securityHeaders(mux)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// Origin Isolation Guard: mini-apps running under /apps/* execute in a
		// sandboxed opaque Origin ("null") via both <iframe sandbox> and HTTP CSP
		// sandbox headers, and are strictly forbidden from calling any host /api/v2/*
		// endpoint even if Referer is suppressed via no-referrer.
		if path == "/api/v2" || strings.HasPrefix(path, "/api/v2/") {
			if isIsolatedAppOriginRequest(r) {
				jsonReply(w, http.StatusForbidden, map[string]string{
					"error":   "app_origin_isolated",
					"message": "轻应用页面处于沙箱隔离环境，不允许直接调用宿主管理接口",
				})
				return
			}
		}

		if path == "/api/v2/apps/local-reload" && r.Method == http.MethodPost {
			handleLocalReload(w, r, appsMgr)
			return
		}

		if path == "/api/v2/apps" || strings.HasPrefix(path, "/api/v2/apps/") {
			securedAPIMux.ServeHTTP(w, r)
			return
		}

		if strings.HasPrefix(path, "/apps/") {
			appsMgr.ServeApp(w, r, resolveSession)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func isIsolatedAppOriginRequest(r *http.Request) bool {
	if origin := strings.TrimSpace(r.Header.Get("Origin")); strings.EqualFold(origin, "null") {
		return true
	}
	if site := strings.TrimSpace(r.Header.Get("Sec-Fetch-Site")); strings.EqualFold(site, "cross-site") {
		return true
	}
	if ref := strings.TrimSpace(r.Header.Get("Referer")); ref != "" {
		if u, err := url.Parse(ref); err == nil {
			if u.Path == "/apps" || strings.HasPrefix(u.Path, "/apps/") {
				return true
			}
		}
	}
	return false
}

func handleLocalReload(w http.ResponseWriter, r *http.Request, appsMgr *apps.Manager) {
	if !isLocal(r.RemoteAddr) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "loopback_only"})
		return
	}
	token := strings.TrimSpace(r.Header.Get("X-LightIsle-MCP-Token"))
	if token == "" {
		if authHeader := r.Header.Get("Authorization"); strings.HasPrefix(authHeader, "Bearer ") {
			token = strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
		}
	}
	if !appsMgr.VerifyReloadToken(token) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "mcp_reload_forbidden"})
		return
	}
	if err := appsMgr.ReloadFromMCP(); err != nil {
		appsErrorReply(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"reloaded": true,
		"apps":     appsMgr.ListForUser(0, auth.RoleAdmin),
	})
}

func replyAppsList(w http.ResponseWriter, appsMgr *apps.Manager, store *auth.Store, user apps.UserIdentity) {
	isAdmin := user.Role == auth.RoleAdmin
	resp := map[string]any{
		"apps":    appsMgr.ListForUser(user.ID, user.Role),
		"isAdmin": isAdmin,
	}
	if isAdmin {
		cfg := appsMgr.GetSystemConfig()
		resp["mcpEnabled"] = cfg.MCPEnabled
		resp["mcpPrompt"] = appsMgr.MCPBootstrapPrompt()
		resp["mcpConfig"] = cfg
		resp["pluginsDir"] = appsMgr.PluginsDir()
		resp["pluginDataDir"] = appsMgr.PluginDataRoot()
		resp["mcpCommand"] = appsMgr.MCPCommand()
		resp["configuredChannels"] = appsMgr.ConfiguredChannels()
		members := make([]map[string]any, 0)
		if store != nil {
			if users, err := store.ListUsers(""); err == nil {
				for _, u := range users {
					if u.Enabled {
						members = append(members, map[string]any{
							"id":       u.ID,
							"username": u.Username,
							"role":     u.Role,
						})
					}
				}
			}
		}
		resp["members"] = members
	}
	jsonReply(w, http.StatusOK, resp)
}

func appsErrorReply(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, apps.ErrInvalid):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "app_invalid", "message": err.Error()})
	case errors.Is(err, apps.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "app_not_found"})
	case errors.Is(err, apps.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "app_access_forbidden"})
	case errors.Is(err, apps.ErrPendingActivation):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "app_pending_activation", "message": "该轻应用尚未经管理员首次激活确认"})
	case errors.Is(err, apps.ErrDisabled):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "app_disabled"})
	case errors.Is(err, apps.ErrBusy):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "app_busy"})
	case errors.Is(err, apps.ErrChanged):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "app_changed"})
	case errors.Is(err, apps.ErrUnavailable):
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "app_unavailable"})
	default:
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "app_operation_failed", "message": err.Error()})
	}
}
