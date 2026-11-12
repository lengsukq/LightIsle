package server

import (
	"net"
	"testing"
)

func TestTailscaleDetectionHelpers(t *testing.T) {
	if !IsTailscaleCGNATIPv4(net.ParseIP("100.101.102.103")) {
		t.Fatal("expected 100.101.102.103 to be recognized as CGNAT Tailscale IPv4")
	}
	if IsTailscaleCGNATIPv4(net.ParseIP("100.63.255.255")) || IsTailscaleCGNATIPv4(net.ParseIP("100.128.0.1")) {
		t.Fatal("outside 100.64.0.0/10 must be rejected")
	}
	if IsTailscaleCGNATIPv4(net.ParseIP("192.168.1.20")) {
		t.Fatal("RFC1918 LAN IP must not match Tailscale CGNAT")
	}

	var st TailscaleStatus
	sample := []byte(`{
		"BackendState": "Running",
		"CurrentTailnet": {"Name": "home-family.ts.net"},
		"Self": {
			"DNSName": "mac-mini.home-family.ts.net.",
			"TailscaleIPs": ["100.88.12.34", "fd7a:115c:a1e0::1"],
			"Online": true
		},
		"Peer": {"k1": {}, "k2": {}}
	}`)
	enrichTailscaleCLIJSON(&st, sample)
	if !st.Running || st.IPv4 != "100.88.12.34" || st.MagicDNS != "mac-mini.home-family.ts.net" || st.PeerCount != 2 {
		t.Fatalf("unexpected enriched Tailscale status: %+v", st)
	}
}
