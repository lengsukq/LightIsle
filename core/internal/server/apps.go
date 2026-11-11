package server

import (
	"errors"
	"net/http"
	"net/url"
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
	resolveSession := newAppsSessionResolver(store)
	sseHub := newMCPSSEHub()

	mux := http.NewServeMux()
	registerAppsManagementRoutes(mux, a, appsMgr, store, resolveSession)
	registerAppsMCPRoutes(mux, a, appsMgr, store, resolveSession)
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

		if handleLocalLoopbackMCPHelpers(w, r, appsMgr) {
			return
		}

		if path == "/api/v2/mcp" || strings.HasPrefix(path, "/api/v2/mcp/") {
			handleHTTPMCPEndpoint(w, r, appsMgr, resolveSession, sseHub)
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

func newAppsSessionResolver(store *auth.Store) func(*http.Request) (apps.UserIdentity, bool) {
	return func(r *http.Request) (apps.UserIdentity, bool) {
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

func replyAppsList(w http.ResponseWriter, appsMgr *apps.Manager, store *auth.Store, user apps.UserIdentity) {
	isAdmin := user.Role == auth.RoleAdmin
	resp := map[string]any{
		"apps":    appsMgr.ListForUser(user.ID, user.Role),
		"isAdmin": isAdmin,
	}
	if isAdmin {
		snap := appsMgr.BuildMCPConfigSnapshot("")
		resp["mcpEnabled"] = snap.MCPEnabled
		resp["mcpLanEnabled"] = snap.MCPLanEnabled
		resp["mcpToken"] = snap.Token
		resp["mcpPrompt"] = snap.Prompt
		resp["lanMcpPrompt"] = snap.LanPrompt
		resp["mcpConfigJson"] = snap.ClientConfigJSON
		resp["localHttpUrl"] = snap.LocalHTTPURL
		resp["lanHttpUrl"] = snap.LanHTTPURL
		resp["lanSseUrl"] = snap.LanSSEURL
		resp["mcpConfig"] = snap.Config
		resp["pluginsDir"] = snap.PluginsDir
		resp["pluginDataDir"] = snap.PluginDataDir
		resp["mcpCommand"] = snap.Command
		resp["mcpLogs"] = appsMgr.GetMCPCallLogs()
		resp["configuredChannels"] = appsMgr.ConfiguredChannels()
		members := make([]map[string]any, 0)
		if store != nil && user.SessionToken != "" {
			if users, err := store.ListUsers(user.SessionToken); err == nil {
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
		jsonReply(w, http.StatusConflict, map[string]string{"error": "app_pending_activation", "message": "该轻应用尚未经管理员首次激活确认"})
	case errors.Is(err, apps.ErrRunning):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "app_running", "message": err.Error()})
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
