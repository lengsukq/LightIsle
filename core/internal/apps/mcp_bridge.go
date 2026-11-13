package apps

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type mcpBridgePayload struct {
	LocalURL  string `json:"localUrl"`
	Token     string `json:"token"`
	PID       int    `json:"pid,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"`
}

func defaultSandboxBridgePaths() []string {
	var paths []string
	seen := make(map[string]struct{}, 4)
	add := func(p string) {
		p = strings.TrimSpace(p)
		if p == "" {
			return
		}
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		paths = append(paths, p)
	}
	if custom := strings.TrimSpace(os.Getenv("LIGHTISLE_MCP_BRIDGE_FILE")); custom != "" {
		add(custom)
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		add(filepath.Join(home, ".cache", "lightisle", "mcp-bridge.json"))
	}
	if cacheDir, err := os.UserCacheDir(); err == nil && cacheDir != "" {
		add(filepath.Join(cacheDir, "lightisle", "mcp-bridge.json"))
	}
	add(filepath.Join(os.TempDir(), fmt.Sprintf("lightisle-mcp-%d", os.Geteuid()), "bridge.json"))
	return paths
}

func isLoopbackBridgeURL(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return false
	}
	host := u.Hostname()
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func isOwnedByCurrentUser(info os.FileInfo) bool {
	if info == nil {
		return false
	}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid) == os.Geteuid()
	}
	return true
}

func writeBridgeFileAtomic(path string, payload mcpBridgePayload) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	_ = os.Chmod(dir, 0700)
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d.tmp", path, time.Now().UnixNano())
	if err := os.WriteFile(tmp, raw, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func readSandboxBridgeTargets() []mcpBridgePayload {
	candidates := defaultSandboxBridgePaths()
	var targets []mcpBridgePayload
	seen := make(map[string]struct{}, len(candidates))
	for _, path := range candidates {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || !isOwnedByCurrentUser(info) {
			continue
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var payload mcpBridgePayload
		if json.Unmarshal(raw, &payload) != nil {
			continue
		}
		payload.LocalURL = strings.TrimRight(strings.TrimSpace(payload.LocalURL), "/")
		payload.Token = strings.TrimSpace(payload.Token)
		if payload.LocalURL == "" || payload.Token == "" || !isLoopbackBridgeURL(payload.LocalURL) {
			continue
		}
		key := payload.LocalURL + "|" + payload.Token
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		targets = append(targets, payload)
	}
	return targets
}

// EnableSandboxBridge allows Manager to publish loopback discovery files under ~/.cache/lightisle
// and /tmp/lightisle-mcp-<uid> so sandboxed MCP clients (such as Gemini Desktop) can bridge to the
// running lightisled daemon even when direct reads of Application Support are restricted.
func (m *Manager) EnableSandboxBridge() {
	m.mu.Lock()
	m.sandboxBridgeEnabled = true
	m.mu.Unlock()
	m.SyncSandboxBridge()
}

// SetBridgePathsForTest overrides bridge descriptor output paths for isolated unit tests.
func (m *Manager) SetBridgePathsForTest(paths ...string) {
	m.mu.Lock()
	m.bridgePaths = append([]string(nil), paths...)
	m.sandboxBridgeEnabled = len(paths) > 0
	m.mu.Unlock()
	m.SyncSandboxBridge()
}

func (m *Manager) configuredBridgePaths() []string {
	m.mu.RLock()
	enabled := m.sandboxBridgeEnabled
	custom := append([]string(nil), m.bridgePaths...)
	m.mu.RUnlock()
	if len(custom) > 0 {
		return custom
	}
	if enabled {
		return defaultSandboxBridgePaths()
	}
	if envPath := strings.TrimSpace(os.Getenv("LIGHTISLE_MCP_BRIDGE_FILE")); envPath != "" {
		return []string{envPath}
	}
	return nil
}

// SyncSandboxBridge writes or clears sandbox-accessible MCP bridge descriptors to match MCPEnabled.
func (m *Manager) SyncSandboxBridge() {
	paths := m.configuredBridgePaths()
	if len(paths) == 0 {
		return
	}
	cfg := m.GetSystemConfig()
	localBase, _ := m.Endpoints()
	token := m.ReadMCPToken()
	if !cfg.MCPEnabled || localBase == "" || token == "" || !isLoopbackBridgeURL(localBase) {
		m.ClearSandboxBridge()
		return
	}
	payload := mcpBridgePayload{
		LocalURL:  strings.TrimRight(localBase, "/"),
		Token:     token,
		PID:       os.Getpid(),
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	for _, p := range paths {
		_ = writeBridgeFileAtomic(p, payload)
	}
}

// ClearSandboxBridge removes any published sandbox bridge descriptors.
func (m *Manager) ClearSandboxBridge() {
	for _, p := range m.configuredBridgePaths() {
		_ = os.Remove(p)
	}
}
