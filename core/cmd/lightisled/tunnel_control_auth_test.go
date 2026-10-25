//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestTunnelFirstTokenSetupDoesNotRequireStoredToken(t *testing.T) {
	ctl := &tunnelControl{}
	firstClient, err := ctl.clientForOperation("configure")
	if err != nil || firstClient != nil {
		t.Fatalf("first-time configure must use request token: client=%v error=%v", firstClient, err)
	}
	forgottenClient, err := ctl.clientForOperation("forget")
	if err != nil || forgottenClient != nil {
		t.Fatalf("credential revoke must not require an existing token: client=%v error=%v", forgottenClient, err)
	}
	for _, operation := range []string{"accounts", "zones", "tunnels", "token", "route"} {
		if _, err := ctl.clientForOperation(operation); err == nil {
			t.Fatalf("%s must reject use before a token is configured", operation)
		}
	}
	ctl.apiToken = "previously-verified-test-token"
	client, err := ctl.clientForOperation("accounts")
	if err != nil || client == nil {
		t.Fatalf("configured API should resolve a client: error=%v", err)
	}
}

func TestTunnelForgetRevokesCoreAPIToken(t *testing.T) {
	output, err := os.CreateTemp(t.TempDir(), "lightisle-tunnel-ipc-*")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	ctl := &tunnelControl{output: output, apiToken: "previously-verified-test-token"}
	ctl.handleAPI(context.Background(), "forget e30")
	if ctl.apiToken != "" {
		t.Fatal("forget must clear Go Core in-memory API credentials")
	}
	if _, err := ctl.clientForOperation("accounts"); err == nil {
		t.Fatal("a forgotten token must not authenticate further account requests")
	}
	if _, err := output.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(output.Name())
	if err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(string(raw))
	encoded := strings.TrimPrefix(line, "LIGHTISLE_TUNNEL_API ")
	if encoded == line {
		t.Fatalf("forget must acknowledge revocation, got %q", line)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Operation string `json:"operation"`
		Forgotten bool   `json:"forgotten"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		t.Fatal(err)
	}
	if result.Operation != "forget" || !result.Forgotten {
		t.Fatalf("forget acknowledgement mismatch: %+v", result)
	}
}
