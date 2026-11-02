package frpclient

import (
	"os/exec"
	"strings"
	"sync"
)

// configuredProxyCount counts only active top-level proxy declarations,
// never commented examples in the generated starter configuration.
func configuredProxyCount(config string) int {
	count := 0
	for _, line := range strings.Split(config, "\n") {
		if strings.TrimSpace(line) == "[[proxies]]" {
			count++
		}
	}
	return count
}

// frpLogWatcher is deliberately not a general-purpose process logger.
// frpc output may contain tokens, query strings, hostnames and user paths.
// It is parsed inside Core and only fixed, translated event summaries and
// stable error codes are allowed to escape over the Mac's private IPC.
type frpLogWatcher struct {
	manager *Manager
	command *exec.Cmd
	mu      sync.Mutex
	partial []byte
}

func (w *frpLogWatcher) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, b := range p {
		if b == '\n' {
			w.manager.observeFRPLog(w.command, string(w.partial))
			w.partial = w.partial[:0]
			continue
		}
		// Truncate a line rather than retain unlimited third-party output.
		if len(w.partial) < 4096 {
			w.partial = append(w.partial, b)
		}
	}
	return len(p), nil
}

func (m *Manager) observeFRPLog(cmd *exec.Cmd, raw string) {
	line := strings.ToLower(raw)
	var connection, code, summary string
	ready := false
	switch {
	case strings.Contains(line, "login to server success"):
		connection, summary = "connected", "已登录 FRP 服务端，等待代理注册。"
	case strings.Contains(line, "start proxy success"):
		connection, ready, summary = "connected", true, "代理注册成功；仍需从外网确认实际可访问。"
	case strings.Contains(line, "start proxy error"), strings.Contains(line, "start proxy failed"):
		connection, code, summary = "degraded", "frpc_proxy_register_failed", "代理注册失败，请检查远端端口、域名和 frps 配置。"
	case strings.Contains(line, "login to server failed"):
		connection, code, summary = "failed", "frpc_login_failed", "服务端登录失败，请检查地址、端口、Token 和服务端状态。"
		if strings.Contains(line, "authorization") || strings.Contains(line, "authentication") {
			code, summary = "frpc_auth_failed", "FRP 身份认证失败，请核对服务端 Token。"
		}
	case strings.Contains(line, "connect to server error"),
		strings.Contains(line, "connect server error"):
		connection, code, summary = "failed", "frpc_server_unreachable", "无法连接 FRP 服务端，请检查网络、域名及端口。"
	case strings.Contains(line, "connection closed"),
		strings.Contains(line, "connection lost"):
		connection, code, summary = "failed", "frpc_connection_lost", "FRP 服务端连接已中断，等待自动重连。"
	case strings.Contains(line, "parse config error"),
		strings.Contains(line, "invalid configuration"):
		connection, code, summary = "failed", "frpc_config_invalid", "FRP 配置格式错误，请检查 frpc.toml。"
	default:
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	// Stop/restart can race with buffered messages from an older frpc.
	if m.cmd != cmd || m.state.Status != "running" {
		return
	}
	if connection == "connected" && !ready {
		// Login after a disconnect begins a fresh proxy registration cycle.
		m.state.ProxyReady = 0
	}
	if ready && m.state.ProxyReady < m.state.ProxyCount {
		m.state.ProxyReady++
	}
	if connection == "failed" {
		m.state.ProxyReady = 0
	}
	m.state.Connection, m.state.Error, m.state.LastLine = connection, code, summary
	m.emitLocked()
}
