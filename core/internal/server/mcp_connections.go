package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

const mcpConnectionsPath = "/api/v2/auth/mcp-connections"

func registerMCPConnections(mux *http.ServeMux, a *API, manager *apps.Manager) {
	mux.HandleFunc("GET "+mcpConnectionsPath, a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		connections, err := a.auth.ListMCPConnections(token(r))
		if err != nil {
			mcpConnectionError(w, err)
			return
		}
		cfg := manager.GetSystemConfig()
		local, lan := manager.Endpoints()
		if localMCPHost(r.Host) && !isLocal(r.RemoteAddr) {
			if origin := inferRequestLanOrigin(r); origin != "" && cfg.MCPLanEnabled {
				lan = origin
			}
		}
		trimmedLan := strings.TrimRight(lan, "/")
		jsonReply(w, 200, map[string]any{
			"connections": connections,
			"enabled":     cfg.MCPEnabled,
			"lanEnabled":  cfg.MCPLanEnabled,
			"localUrl":    local + "/api/v2/mcp",
			"lanUrl":      trimmedLan + "/api/v2/mcp",
			"localSseUrl": local + "/api/v2/mcp/sse",
			"lanSseUrl":   trimmedLan + "/api/v2/mcp/sse",
		})
	}))
	mux.HandleFunc("POST "+mcpConnectionsPath, a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if !manager.MCPEnabled() {
			jsonReply(w, 409, map[string]string{"error": "mcp_disabled"})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		defer r.Body.Close()
		var body struct {
			Label    string `json:"label"`
			CanWrite bool   `json:"canWrite"`
		}
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF {
			mcpConnectionError(w, auth.ErrInput)
			return
		}
		item, bearer, err := a.auth.CreateMCPConnection(token(r), body.Label, body.CanWrite)
		if err != nil {
			mcpConnectionError(w, err)
			return
		}
		jsonReply(w, 201, map[string]any{"connection": item, "token": bearer})
	}))
	mux.HandleFunc("DELETE "+mcpConnectionsPath+"/{id}", a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if err := a.auth.RevokeMCPConnection(token(r), r.PathValue("id")); err != nil {
			mcpConnectionError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}

func mcpConnectionError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, 400, map[string]string{"error": "mcp_invalid_connection"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, 404, map[string]string{"error": "mcp_connection_not_found"})
	case errors.Is(err, auth.ErrMCPConnectionLimit):
		jsonReply(w, 409, map[string]string{"error": "mcp_connection_limit"})
	default:
		jsonReply(w, 503, map[string]string{"error": "mcp_connections_unavailable"})
	}
}
