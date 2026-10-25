package server

import (
	"context"
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func (a *API) systemHistory(w http.ResponseWriter, r *http.Request) {
	if a.journal == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "metrics_history_unavailable"})
		return
	}
	limit := 180
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 2880 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_page_size"})
			return
		}
		limit = n
	}
	history, err := a.journal.MetricHistory(limit)
	if err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "metrics_history_unavailable"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"samples": history, "intervalSeconds": 60, "retentionHours": 48})
}

type networkInterfaceInfo struct {
	Name      string   `json:"name"`
	Up        bool     `json:"up"`
	Addresses []string `json:"addresses"`
}

// Diagnostic data is read-only and strictly local. No user-supplied URLs,
// hostnames, ping targets, arbitrary commands or outbound HTTP are accepted.
// Admin-only because private LAN addresses should not be exposed to members.
func (a *API) systemDiagnostics(w http.ResponseWriter, r *http.Request) {
	if r.URL.RawQuery != "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "unsupported_diagnostic_parameters"})
		return
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "network_interfaces_unavailable"})
		return
	}
	result := make([]networkInterfaceInfo, 0, 12)
	for _, item := range interfaces {
		if item.Flags&net.FlagLoopback != 0 || item.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		if len(result) >= 24 {
			break
		}
		if !(strings.HasPrefix(item.Name, "en") || strings.HasPrefix(item.Name, "bridge") || strings.HasPrefix(item.Name, "utun")) {
			continue
		}
		ips := make([]string, 0, 2)
		if addresses, e := item.Addrs(); e == nil {
			for _, addr := range addresses {
				ip, _, parseErr := net.ParseCIDR(addr.String())
				if parseErr != nil || ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					continue
				}
				if len(ips) >= 8 {
					break
				}
				ips = append(ips, ip.String())
			}
		}
		result = append(result, networkInterfaceInfo{Name: item.Name, Up: item.Flags&net.FlagUp != 0, Addresses: ips})
	}
	gateway, routeInterface := "", ""
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	// Constant argv and bounded execution; a missing route utility is a soft
	// diagnostic absence, never an API failure or speculative connectivity.
	command := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "default")
	if output, err := command.Output(); err == nil && len(output) <= 8192 {
		for _, line := range strings.Split(string(output), "\n") {
			fields := strings.Fields(strings.TrimSpace(line))
			if len(fields) != 2 {
				continue
			}
			switch fields[0] {
			case "gateway:":
				if net.ParseIP(fields[1]) != nil {
					gateway = fields[1]
				}
			case "interface:":
				if len(fields[1]) < 32 {
					routeInterface = fields[1]
				}
			}
		}
	}
	transport := "HTTP（当前请求未使用 TLS；仅能证明当前连接）"
	if r.TLS != nil {
		transport = "HTTPS（当前请求已使用 TLS）"
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"interfaces":       result,
		"gatewayIPv4":      gateway,
		"defaultInterface": routeInterface,
		"requestTransport": transport,
		"observedAt":       time.Now().UTC().Format(time.RFC3339),
		"tips": []string{
			"这里只检查 Mac 的本地接口和默认网关，不探测公网可达性或远程 Tunnel 状态。",
			"没有 LAN 地址时，请检查 Mac Wi-Fi/以太网、路由器和系统网络权限。",
			"公网访问失败时先检查 Mac 客户端已开启远程 HTTPS、证书是否被信任，再检查隧道/DNS。",
		},
	})
}
