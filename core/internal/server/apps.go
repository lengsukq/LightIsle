package server

import (
	"context"
	"errors"
	"log/slog"
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
	if appsMgr != nil {
		if protector, ok := next.(protectedHostDirsSetter); ok {
			protector.SetProtectedHostDirsProvider(appsMgr.ProtectedHostDirs)
		}
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
	securedAPIMux := securityHeaders(mux)
	appsAndCore := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v2/apps" || strings.HasPrefix(r.URL.Path, "/api/v2/apps/") {
			securedAPIMux.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
	managementMCP := &mcpManagement{store: store, apps: appsMgr, api: appsAndCore, tools: mcpManagementTools(), active: make(chan struct{}, 16)}
	if appsMgr != nil && store != nil {
		appsMgr.SetMCPHandler(func(ctx context.Context, transport, remoteAddr string, raw []byte) ([]byte, bool) {
			u, sess, conn, ok := store.EnsureSystemMCPSession("__debug_inspector__", "debug-ui")
			if !ok {
				return apps.ExecuteMCPJSONRPC(ctx, appsMgr.DataDir(), appsMgr.ExecPath(), transport, remoteAddr, appsMgr, raw)
			}
			return managementMCP.ExecuteAuthorizedRPC(ctx, transport, remoteAddr, u, sess, conn, raw)
		})
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// App Gateway Isolation Guard: /apps/<id>/* responses enforce path-scoped
		// CSP connect-src/form-action confining sub-requests to /apps/<id>/*, and
		// any /api/v2/* call carrying an /apps/* Referer, an opaque "null" Origin,
		// or a cross-site Fetch Metadata signal is rejected here.
		if path == "/api/v2" || strings.HasPrefix(path, "/api/v2/") {
			if isIsolatedAppOriginRequest(r) {
				jsonReply(w, http.StatusForbidden, map[string]string{
					"error":   "app_origin_isolated",
					"message": "轻应用页面处于隔离环境，不允许直接调用宿主管理接口",
				})
				return
			}
		}

		if handleLocalLoopbackMCPHelpers(w, r, appsMgr) {
			return
		}

		if path == "/api/v2/mcp" || strings.HasPrefix(path, "/api/v2/mcp/") {
			handleHTTPMCPEndpoint(w, r, appsMgr, managementMCP, resolveSession, sseHub)
			return
		}

		if strings.HasPrefix(path, "/apps/") {
			appsMgr.ServeApp(w, r, resolveSession)
			return
		}

		appsAndCore.ServeHTTP(w, r)
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
	templates := []apps.OfficialAppTemplate{}
	var storeSnap *apps.AppStoreSnapshot
	if isAdmin {
		snap := appsMgr.GetStoreSnapshot()
		storeSnap = &snap
		templates = appsMgr.ListTemplates()
	}
	resp := map[string]any{
		"apps":      appsMgr.ListForUser(user.ID, user.Role),
		"templates": templates,
		"isAdmin":   isAdmin,
	}
	if storeSnap != nil {
		resp["store"] = storeSnap
	}
	if isAdmin {
		storageSnap := appsMgr.GetStorageSnapshot()
		pluginsDir := appsMgr.PluginsDir()
		pluginDataDir := appsMgr.PluginDataRoot()
		for _, loc := range storageSnap.Locations {
			if loc.IsDefault {
				pluginsDir = loc.PluginsDir
				pluginDataDir = loc.PluginDataDir
				break
			}
		}
		resp["pluginsDir"] = pluginsDir
		resp["pluginDataDir"] = pluginDataDir
		resp["configuredChannels"] = appsMgr.ConfiguredChannels()
		resp["appStorage"] = storageSnap
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

func safeAppDomainDetail(err, sentinel error, fallback string) string {
	if err == nil || sentinel == nil {
		return fallback
	}
	prefix := sentinel.Error() + ": "
	raw := err.Error()
	if !strings.HasPrefix(raw, prefix) {
		return fallback
	}
	detail := strings.TrimSpace(strings.TrimPrefix(raw, prefix))
	if detail == "" || strings.Contains(detail, "/") || strings.Contains(detail, "permission denied") {
		return fallback
	}
	return detail
}

func appsErrorReply(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, apps.ErrInvalid):
		g := apiErrorCatalog["app_invalid"]
		writeAPIError(w, http.StatusBadRequest, "app_invalid", safeAppDomainDetail(err, apps.ErrInvalid, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrStorageSlotLimit):
		g := apiErrorCatalog["app_storage_slot_limit"]
		writeAPIError(w, http.StatusConflict, "app_storage_slot_limit", safeAppDomainDetail(err, apps.ErrStorageSlotLimit, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrStorageOffline):
		g := apiErrorCatalog["app_storage_offline"]
		writeAPIError(w, http.StatusConflict, "app_storage_offline", safeAppDomainDetail(err, apps.ErrStorageOffline, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrStoreInvalidConfig):
		g := apiErrorCatalog["app_store_invalid_config"]
		writeAPIError(w, http.StatusBadRequest, "app_store_invalid_config", safeAppDomainDetail(err, apps.ErrStoreInvalidConfig, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrStorePluginNotFound):
		writeAPIErrorCode(w, http.StatusNotFound, "app_store_plugin_not_found")
	case errors.Is(err, apps.ErrStoreChecksumMismatch):
		g := apiErrorCatalog["app_store_checksum_mismatch"]
		writeAPIError(w, http.StatusBadGateway, "app_store_checksum_mismatch", safeAppDomainDetail(err, apps.ErrStoreChecksumMismatch, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrStoreNoUpdate):
		writeAPIErrorCode(w, http.StatusConflict, "app_store_no_update")
	case errors.Is(err, apps.ErrStoreUnavailable):
		g := apiErrorCatalog["app_store_unavailable"]
		writeAPIError(w, http.StatusBadGateway, "app_store_unavailable", safeAppDomainDetail(err, apps.ErrStoreUnavailable, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrAlreadyInstalled):
		writeAPIErrorCode(w, http.StatusConflict, "app_already_exists")
	case errors.Is(err, apps.ErrNotFound):
		writeAPIErrorCode(w, http.StatusNotFound, "app_not_found")
	case errors.Is(err, apps.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "app_access_forbidden")
	case errors.Is(err, apps.ErrPendingActivation):
		writeAPIErrorCode(w, http.StatusConflict, "app_pending_activation")
	case errors.Is(err, apps.ErrRunning):
		g := apiErrorCatalog["app_running"]
		writeAPIError(w, http.StatusConflict, "app_running", safeAppDomainDetail(err, apps.ErrRunning, g.message), g.dataSafe, g.nextAction)
	case errors.Is(err, apps.ErrDisabled):
		writeAPIErrorCode(w, http.StatusConflict, "app_disabled")
	case errors.Is(err, apps.ErrBusy):
		writeAPIErrorCode(w, http.StatusConflict, "app_busy")
	case errors.Is(err, apps.ErrChanged):
		writeAPIErrorCode(w, http.StatusConflict, "app_changed")
	case errors.Is(err, apps.ErrUnavailable):
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "app_unavailable")
	default:
		slog.Warn("app operation failed", "error", err)
		writeAPIErrorCode(w, http.StatusBadGateway, "app_operation_failed")
	}
}
