package cloudflareapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// recorder captures the request and replies with a canned v4 envelope.
type recorder struct {
	t       *testing.T
	status  int
	result  any
	seen    *http.Request
	sawAuth string
	rawBody []byte
}

func (r *recorder) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.seen = req
	r.sawAuth = req.Header.Get("Authorization")
	r.rawBody, _ = io.ReadAll(req.Body)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(r.status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"success": r.status < 400,
		"errors":  []map[string]any{{"code": 9109, "message": "Unauthorized to access requested resource"}},
		"result":  r.result,
	})
}

func TestListAccountsDiscoversID(t *testing.T) {
	backend := &recorder{t: t, status: 200, result: []map[string]string{
		{"id": "acct123", "name": "Personal"},
	}}
	server := httptest.NewServer(backend)
	defer server.Close()
	client := NewWithBase("token-a", server.URL)
	accounts, err := client.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("ListAccounts: %v", err)
	}
	if len(accounts) != 1 || accounts[0].ID != "acct123" || accounts[0].Name != "Personal" {
		t.Fatalf("accounts = %+v", accounts)
	}
	if backend.sawAuth != "Bearer token-a" {
		t.Errorf("authorization header = %q", backend.sawAuth)
	}
	if backend.seen.URL.Path != "/accounts" {
		t.Errorf("path = %q", backend.seen.URL.Path)
	}
}

func TestTokenRejectionMapsToFriendlyMessage(t *testing.T) {
	backend := &recorder{t: t, status: 401}
	server := httptest.NewServer(backend)
	defer server.Close()
	client := NewWithBase("stale", server.URL)
	_, err := client.ListAccounts(context.Background())
	apiErr, ok := err.(*APIError)
	if !ok {
		t.Fatalf("expected *APIError, got %v", err)
	}
	if !strings.Contains(apiErr.Friendly(), "无效或已过期") {
		t.Errorf("friendly = %q", apiErr.Friendly())
	}
	if strings.Contains(apiErr.Friendly(), "stale") {
		t.Error("error text must never echo the token")
	}
}

func TestCreateTunnelUsesRemoteConfig(t *testing.T) {
	backend := &recorder{t: t, status: 200, result: map[string]any{
		"id": "tunnel1", "name": "nas", "status": "inactive", "config_src": "cloudflare",
	}}
	server := httptest.NewServer(backend)
	defer server.Close()
	client := NewWithBase("token", server.URL)
	tunnel, err := client.CreateTunnel(context.Background(), "acct123", "nas")
	if err != nil {
		t.Fatalf("CreateTunnel: %v", err)
	}
	if !tunnel.RemoteConfig || tunnel.ID != "tunnel1" {
		t.Fatalf("tunnel = %+v", tunnel)
	}
	if backend.seen.URL.Path != "/accounts/acct123/cfd_tunnel" {
		t.Errorf("path = %q", backend.seen.URL.Path)
	}
	var body map[string]any
	_ = json.Unmarshal(backend.rawBody, &body)
	if body["config_src"] != "cloudflare" {
		t.Errorf("config_src = %v", body["config_src"])
	}
}

func TestTunnelTokenAndConfigurations(t *testing.T) {
	backend := &recorder{t: t, status: 200, result: map[string]any{
		"ingress": []map[string]string{
			{"hostname": "nas.example.com", "service": "http://localhost:16666"},
			{"service": "http_status:404"},
		},
	}}
	server := httptest.NewServer(backend)
	defer server.Close()
	client := NewWithBase("token", server.URL)
	config, err := client.TunnelConfigurations(context.Background(), "acct", "tid")
	if err != nil {
		t.Fatalf("TunnelConfigurations: %v", err)
	}
	if len(config.Ingress) != 2 || config.Ingress[0].Hostname != "nas.example.com" {
		t.Fatalf("config = %+v", config)
	}
	// PUT must preserve existing rules and keep the catch-all last.
	err = client.PutTunnelConfigurations(context.Background(), "acct", "tid", config)
	if err != nil {
		t.Fatalf("PutTunnelConfigurations: %v", err)
	}
	if backend.seen.Method != http.MethodPut {
		t.Errorf("method = %s", backend.seen.Method)
	}
}

func TestEnsureHostnameRoute(t *testing.T) {
	created := 0
	mux := http.NewServeMux()
	mux.HandleFunc("GET /zones/z1/dns_records", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		var records []map[string]string
		if name == "nas.example.com" {
			records = append(records, map[string]string{"id": "rec1", "name": "nas.example.com", "type": "CNAME", "content": "tunnel1.cfargotunnel.com"})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "errors": []any{}, "result": records})
	})
	mux.HandleFunc("POST /zones/z1/dns_records", func(w http.ResponseWriter, r *http.Request) {
		created++
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "errors": []any{}, "result": map[string]string{"id": "rec2"}})
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	client := NewWithBase("token", server.URL)
	ctx := context.Background()

	// Existing matching record → no duplicate creation.
	did, err := client.EnsureHostnameRoute(ctx, "z1", "nas.example.com", "tunnel1")
	if err != nil || did {
		t.Fatalf("existing route: created=%v err=%v", did, err)
	}
	// New hostname → one CNAME created.
	did, err = client.EnsureHostnameRoute(ctx, "z1", "fresh.example.com", "tunnel1")
	if err != nil || !did {
		t.Fatalf("new route: created=%v err=%v", did, err)
	}
	if created != 1 {
		t.Errorf("created %d records", created)
	}
	// Hostname pointing elsewhere must never be rewritten silently.
	if _, err := client.EnsureHostnameRoute(ctx, "z1", "nas.example.com", "tunnel2"); err == nil {
		t.Fatal("conflicting record must be refused")
	}
	// Invalid hostname rejected before any network call.
	if _, err := client.EnsureHostnameRoute(ctx, "z1", "../evil", "tunnel1"); err == nil {
		t.Fatal("invalid hostname must be rejected")
	}
}

func TestValidIDAndHostname(t *testing.T) {
	if !validID("acct123") || validID("../x") || validID("") || validID("a b") {
		t.Error("validID misbehaves")
	}
	if !validHostname("nas.example.com") || !validHostname("nas.lengsu.top") {
		t.Error("valid hostname rejected")
	}
	if validHostname("example") || validHostname("bad_.example.com") || validHostname("") {
		t.Error("invalid hostname accepted")
	}
}
