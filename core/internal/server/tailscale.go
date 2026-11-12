package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// TailscaleStatus summarizes local Tailscale installation, virtual interface
// IP (100.64.0.0/10 CGNAT), MagicDNS hostname, and reachable LightIsle URLs.
type TailscaleStatus struct {
	Installed    bool     `json:"installed"`
	Running      bool     `json:"running"`
	BackendState string   `json:"backendState,omitempty"`
	Interface    string   `json:"interface,omitempty"`
	IPv4         string   `json:"ipv4,omitempty"`
	MagicDNS     string   `json:"magicDns,omitempty"`
	TailnetName  string   `json:"tailnetName,omitempty"`
	PeerCount    int      `json:"peerCount,omitempty"`
	BoundURL     string   `json:"boundUrl,omitempty"`
	SuggestedURL string   `json:"suggestedUrl,omitempty"`
	ExtraSANs    []string `json:"extraSans,omitempty"`
	DownloadURL  string   `json:"downloadUrl"`
}

const tailscaleMacDownloadURL = "https://tailscale.com/download/mac"

var tailscaleBinaryCandidates = []string{
	"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	"/opt/homebrew/bin/tailscale",
	"/usr/local/bin/tailscale",
}

// IsTailscaleCGNATIPv4 reports whether ip falls within RFC 6598 100.64.0.0/10,
// the address range used by Tailscale / WireGuard utun interfaces on macOS.
func IsTailscaleCGNATIPv4(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	return ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127
}

func tailscaleIPv4FromInterfaces() (net.IP, string) {
	faces, err := net.Interfaces()
	if err != nil {
		return nil, ""
	}
	for _, face := range faces {
		if face.Flags&net.FlagUp == 0 || face.Flags&net.FlagLoopback != 0 {
			continue
		}
		if !strings.HasPrefix(face.Name, "utun") && !strings.HasPrefix(face.Name, "tailscale") {
			continue
		}
		addrs, err := face.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			if IsTailscaleCGNATIPv4(ip) {
				return ip.To4(), face.Name
			}
		}
	}
	return nil, ""
}

// DetectTailscale inspects local utun CGNAT interfaces and optional Tailscale
// CLI status JSON without requiring elevated privileges or external network I/O.
func DetectTailscale(ctx context.Context, port int, httpsActive bool, boundTailscaleURL string) TailscaleStatus {
	status := TailscaleStatus{
		DownloadURL: tailscaleMacDownloadURL,
		BoundURL:    boundTailscaleURL,
	}
	if _, err := os.Stat("/Applications/Tailscale.app"); err == nil {
		status.Installed = true
	}
	if ip, iface := tailscaleIPv4FromInterfaces(); ip != nil {
		status.Installed = true
		status.Running = true
		status.Interface = iface
		status.IPv4 = ip.String()
	}

	var cliPath string
	for _, candidate := range tailscaleBinaryCandidates {
		if st, err := os.Stat(candidate); err == nil && st.Mode().IsRegular() {
			cliPath = candidate
			status.Installed = true
			break
		}
	}
	if cliPath != "" {
		probeCtx, cancel := context.WithTimeout(ctx, 1200*time.Millisecond)
		out, err := exec.CommandContext(probeCtx, cliPath, "status", "--json").Output()
		cancel()
		if err == nil && len(out) > 0 {
			enrichTailscaleCLIJSON(&status, out)
		}
	}

	scheme := "http"
	if httpsActive || strings.HasPrefix(boundTailscaleURL, "https://") {
		scheme = "https"
	}
	if status.BoundURL != "" {
		status.SuggestedURL = status.BoundURL
	} else if status.IPv4 != "" && port > 0 {
		status.SuggestedURL = fmt.Sprintf("%s://%s:%d", scheme, status.IPv4, port)
	}
	if status.MagicDNS != "" {
		status.ExtraSANs = []string{status.MagicDNS}
	}
	return status
}

func enrichTailscaleCLIJSON(status *TailscaleStatus, raw []byte) {
	var doc struct {
		BackendState string `json:"BackendState"`
		MagicDNSSuffix string `json:"MagicDNSSuffix"`
		CurrentTailnet *struct {
			Name string `json:"Name"`
		} `json:"CurrentTailnet"`
		Self *struct {
			DNSName      string   `json:"DNSName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
			Online       bool     `json:"Online"`
		} `json:"Self"`
		Peer map[string]json.RawMessage `json:"Peer"`
	}
	if json.Unmarshal(raw, &doc) != nil {
		return
	}
	status.BackendState = strings.TrimSpace(doc.BackendState)
	if status.BackendState == "Running" {
		status.Running = true
	}
	if doc.CurrentTailnet != nil {
		status.TailnetName = strings.TrimSpace(doc.CurrentTailnet.Name)
	}
	if doc.Self != nil {
		dns := strings.TrimSuffix(strings.TrimSpace(doc.Self.DNSName), ".")
		if dns != "" {
			status.MagicDNS = dns
		}
		if status.IPv4 == "" {
			for _, candidate := range doc.Self.TailscaleIPs {
				if ip := net.ParseIP(strings.TrimSpace(candidate)); IsTailscaleCGNATIPv4(ip) {
					status.IPv4 = ip.To4().String()
					break
				}
			}
		}
	}
	status.PeerCount = len(doc.Peer)
}

func (a *API) adminTailscaleStatus(w http.ResponseWriter, r *http.Request) {
	port := 16666
	if _, p, err := net.SplitHostPort(r.Host); err == nil {
		if parsed, convErr := net.LookupPort("tcp", p); convErr == nil && parsed > 0 {
			port = parsed
		}
	}
	httpsActive := r.TLS != nil
	boundURL := ""
	if a.tailscaleBoundURL != nil {
		boundURL, httpsActive = a.tailscaleBoundURL()
	}
	st := DetectTailscale(r.Context(), port, httpsActive, boundURL)
	jsonReply(w, http.StatusOK, st)
}
