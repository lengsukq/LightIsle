//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/cloudflareapi"
	"github.com/lengsukq/lightisle/core/internal/tunnel"
)

// tunnelControl translates private IPC commands into tunnel supervisor and
// Cloudflare API operations. The API token lives only in process memory:
// the Mac App keeps it in the Keychain and re-sends it after a Core restart.
type tunnelControl struct {
	output  *os.File
	manager *tunnel.Manager

	mu       sync.Mutex
	apiToken string
}

func newTunnelControl(ctx context.Context, port int, journalAlert func(code string, active bool)) *tunnelControl {
	manager := tunnel.New(ctx, fmt.Sprintf("http://127.0.0.1:%d", port))
	manager.SetHooks(func(active bool) {
		journalAlert("tunnel_disconnected", active)
	}, func(state tunnel.State) {
		if data, err := json.Marshal(state); err == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TUNNEL_STATE "+base64.RawURLEncoding.EncodeToString(data))
		}
	})
	return &tunnelControl{output: os.Stdout, manager: manager}
}

func (t *tunnelControl) emitStatus() {
	if data, err := json.Marshal(t.manager.Status()); err == nil {
		fmt.Fprintln(t.output, "LIGHTISLE_TUNNEL_STATUS "+base64.RawURLEncoding.EncodeToString(data))
	}
}

func (t *tunnelControl) emitPayload(payload any) {
	if data, err := json.Marshal(payload); err == nil {
		fmt.Fprintln(t.output, "LIGHTISLE_TUNNEL_API "+base64.RawURLEncoding.EncodeToString(data))
	}
}

func (t *tunnelControl) emitError(err error) {
	message := err.Error()
	var apiErr *cloudflareapi.APIError
	if asAPI(err, &apiErr) {
		message = apiErr.Friendly()
	}
	fmt.Fprintln(t.output, "LIGHTISLE_TUNNEL_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(message)))
}

func asAPI(err error, target **cloudflareapi.APIError) bool {
	if e, ok := err.(*cloudflareapi.APIError); ok {
		*target = e
		return true
	}
	return false
}

// handle returns false when the command is not a tunnel command.
func (t *tunnelControl) handle(ctx context.Context, command string) bool {
	switch {
	case command == "tunnel status":
		t.emitStatus()
	case command == "tunnel quick on":
		if _, err := t.manager.StartQuick(); err != nil {
			t.emitError(err)
		}
		t.emitStatus()
	case strings.HasPrefix(command, "tunnel run "):
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "tunnel run "))
		var request struct {
			TunnelID   string `json:"tunnelId"`
			TunnelName string `json:"tunnelName"`
			Token      string `json:"token"`
		}
		if err != nil || len(raw) == 0 || len(raw) > 16384 || json.Unmarshal(raw, &request) != nil {
			t.emitError(errInvalidTunnelRequest)
			return true
		}
		if _, err := t.manager.StartNamed(request.TunnelID, request.TunnelName, request.Token); err != nil {
			t.emitError(err)
		}
		t.emitStatus()
	case command == "tunnel off":
		t.manager.Stop()
		t.emitStatus()
	case strings.HasPrefix(command, "tunnel api "):
		t.handleAPI(ctx, strings.TrimPrefix(command, "tunnel api "))
	default:
		return false
	}
	return true
}

var errInvalidTunnelRequest = fmt.Errorf("invalid_tunnel_request")

func decodeTunnelPayload(raw string, target any) error {
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || len(data) == 0 || len(data) > 16384 {
		return errInvalidTunnelRequest
	}
	if err := json.Unmarshal(data, target); err != nil {
		return errInvalidTunnelRequest
	}
	return nil
}

func (t *tunnelControl) client() (*cloudflareapi.Client, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.apiToken == "" {
		return nil, fmt.Errorf("tunnel_api_not_configured")
	}
	return cloudflareapi.New(t.apiToken), nil
}

func (t *tunnelControl) handleAPI(ctx context.Context, spec string) {
	op, raw := spec, ""
	if i := strings.IndexByte(spec, ' '); i >= 0 {
		op, raw = spec[:i], strings.TrimSpace(spec[i+1:])
	}
	client, err := t.client()
	if err != nil {
		t.emitError(err)
		return
	}
	switch op {
	case "configure":
		var request struct {
			APIToken string `json:"apiToken"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil || len(request.APIToken) < 16 || len(request.APIToken) > 256 {
			t.emitError(errInvalidTunnelRequest)
			return
		}
		client := cloudflareapi.New(strings.TrimSpace(request.APIToken))
		accounts, err := client.ListAccounts(ctx)
		if err != nil {
			t.emitError(err)
			return
		}
		t.mu.Lock()
		t.apiToken = strings.TrimSpace(request.APIToken)
		t.mu.Unlock()
		t.emitPayload(map[string]any{"accounts": accounts})
	case "accounts":
		accounts, err := client.ListAccounts(ctx)
		if err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"accounts": accounts})
	case "zones":
		zones, err := client.ListZones(ctx)
		if err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"zones": zones})
	case "tunnels":
		var request struct {
			AccountID string `json:"accountId"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		tunnels, err := client.ListTunnels(ctx, request.AccountID)
		if err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"tunnels": tunnels})
	case "create":
		var request struct {
			AccountID string `json:"accountId"`
			Name      string `json:"name"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		tunnelEntry, err := client.CreateTunnel(ctx, request.AccountID, request.Name)
		if err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"tunnel": tunnelEntry})
	case "delete":
		var request struct {
			AccountID string `json:"accountId"`
			TunnelID  string `json:"tunnelId"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		if err := client.DeleteTunnel(ctx, request.AccountID, request.TunnelID); err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"deleted": true})
	case "token":
		var request struct {
			AccountID  string `json:"accountId"`
			TunnelID   string `json:"tunnelId"`
			TunnelName string `json:"tunnelName"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		token, err := client.TunnelToken(ctx, request.AccountID, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		// Start immediately: fetching a token is only ever done to run it.
		if _, err := t.manager.StartNamed(request.TunnelID, request.TunnelName, token); err != nil {
			t.emitError(err)
			return
		}
		t.emitStatus()
	case "config":
		var request struct {
			AccountID string `json:"accountId"`
			TunnelID  string `json:"tunnelId"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		config, err := client.TunnelConfigurations(ctx, request.AccountID, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"config": config})
	case "route":
		var request struct {
			AccountID string `json:"accountId"`
			TunnelID  string `json:"tunnelId"`
			ZoneID    string `json:"zoneId"`
			Hostname  string `json:"hostname"`
			Service   string `json:"service"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		if !strings.HasPrefix(request.Service, "http://") && !strings.HasPrefix(request.Service, "https://") {
			request.Service = "http://" + request.Service
		}
		created, err := client.EnsureHostnameRoute(ctx, request.ZoneID, request.Hostname, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		// Read-modify-write so hostnames configured elsewhere survive.
		config, err := client.TunnelConfigurations(ctx, request.AccountID, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		updated := make([]cloudflareapi.IngressRule, 0, len(config.Ingress)+1)
		replaced := false
		for _, rule := range config.Ingress {
			if strings.EqualFold(rule.Hostname, request.Hostname) {
				updated = append(updated, cloudflareapi.IngressRule{Hostname: request.Hostname, Service: request.Service})
				replaced = true
				continue
			}
			updated = append(updated, rule)
		}
		if !replaced {
			// Keep the catch-all (no hostname) last.
			head := updated
			tail := cloudflareapi.IngressRule{Service: "http_status:404"}
			if len(head) > 0 && head[len(head)-1].Hostname == "" {
				tail = head[len(head)-1]
				head = head[:len(head)-1]
			}
			updated = append(head, cloudflareapi.IngressRule{Hostname: request.Hostname, Service: request.Service})
			updated = append(updated, tail)
		}
		if err := client.PutTunnelConfigurations(ctx, request.AccountID, request.TunnelID, cloudflareapi.TunnelConfig{Ingress: updated}); err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"config": cloudflareapi.TunnelConfig{Ingress: updated}, "dnsCreated": created})
	case "route-remove":
		var request struct {
			AccountID string `json:"accountId"`
			TunnelID  string `json:"tunnelId"`
			ZoneID    string `json:"zoneId"`
			Hostname  string `json:"hostname"`
		}
		if err := decodeTunnelPayload(raw, &request); err != nil {
			t.emitError(err)
			return
		}
		removed, err := client.RemoveHostnameRoute(ctx, request.ZoneID, request.Hostname, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		config, err := client.TunnelConfigurations(ctx, request.AccountID, request.TunnelID)
		if err != nil {
			t.emitError(err)
			return
		}
		remaining := make([]cloudflareapi.IngressRule, 0, len(config.Ingress))
		for _, rule := range config.Ingress {
			if !strings.EqualFold(rule.Hostname, request.Hostname) {
				remaining = append(remaining, rule)
			}
		}
		if len(remaining) == 0 {
			remaining = append(remaining, cloudflareapi.IngressRule{Service: "http_status:404"})
		}
		if err := client.PutTunnelConfigurations(ctx, request.AccountID, request.TunnelID, cloudflareapi.TunnelConfig{Ingress: remaining}); err != nil {
			t.emitError(err)
			return
		}
		t.emitPayload(map[string]any{"config": cloudflareapi.TunnelConfig{Ingress: remaining}, "dnsRemoved": removed})
	default:
		t.emitError(errInvalidTunnelRequest)
	}
}
