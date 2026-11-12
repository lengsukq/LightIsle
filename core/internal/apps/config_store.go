package apps

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

var standaloneConfigMu sync.Mutex

func readSystemConfigFile(path string) (AppsSystemConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return AppsSystemConfig{MCPEnabled: false}, nil
		}
		return AppsSystemConfig{}, fmt.Errorf("读取 apps-config.json 失败: %w", err)
	}
	var cfg AppsSystemConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return AppsSystemConfig{}, fmt.Errorf("解析 apps-config.json 失败: %w", err)
	}
	return cfg, nil
}

func writeSystemConfigFile(path string, cfg AppsSystemConfig) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
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

func uniqueSortedStrings(items []string) []string {
	if len(items) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(items))
	out := make([]string, 0, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if _, ok := seen[item]; !ok {
			seen[item] = struct{}{}
			out = append(out, item)
		}
	}
	if len(out) == 0 {
		return nil
	}
	sort.Strings(out)
	return out
}

func markAppPendingInConfigLocked(cfgPath, appID string) error {
	if !ValidPluginID(appID) || isOfficialTemplateID(appID) {
		return nil
	}
	cfg, err := readSystemConfigFile(cfgPath)
	if err != nil {
		return err
	}
	if slices.Contains(cfg.ActivatedApps, appID) || slices.Contains(cfg.PendingApps, appID) {
		return nil
	}
	cfg.PendingApps = uniqueSortedStrings(append(cfg.PendingApps, appID))
	if cfg.UpdatedAt == "" {
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	return writeSystemConfigFile(cfgPath, cfg)
}

func markAppPendingInConfig(dataDir, appID string) error {
	standaloneConfigMu.Lock()
	defer standaloneConfigMu.Unlock()
	return markAppPendingInConfigLocked(filepath.Join(dataDir, "apps-config.json"), appID)
}

func (m *Manager) markAppPending(appID string) error {
	m.mutation.Lock()
	defer m.mutation.Unlock()
	return markAppPendingInConfigLocked(m.configPath, appID)
}

func ensureReloadTokenFile(path string) error {
	if raw, err := os.ReadFile(path); err == nil && len(strings.TrimSpace(string(raw))) >= 32 {
		return nil
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(hex.EncodeToString(buf)+"\n"), 0600)
}

func ensureBuiltInDemoApp(pluginsDir string) {
	marker := filepath.Join(pluginsDir, ".demo-initialized")
	if _, err := os.Lstat(marker); err == nil {
		return
	}
	entries, err := os.ReadDir(pluginsDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			_ = os.WriteFile(marker, []byte("initialized\n"), 0600)
			return
		}
	}
	appDir := filepath.Join(pluginsDir, "network-pulse")
	uiDir := filepath.Join(appDir, "ui")
	if err := os.MkdirAll(uiDir, 0700); err != nil {
		return
	}
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            "network-pulse",
		Name:          "轻屿网络与系统脉搏",
		Version:       "1.0.0",
		Author:        "LightIsle",
		Description:   "实时测量浏览器到家庭 NAS 的往返延迟、抖动与连接健康度（内置纯静态轻应用示例）",
		Category:      "system",
		Icon:          "icon.svg",
		Access:        AccessConfig{Policy: AccessAllMembers, AllowedUserIDs: []int64{}},
		Web: &WebConfig{
			Enabled:   true,
			Mode:      WebModeStatic,
			Runtime:   "static",
			StaticDir: "ui",
			BasePath:  "/apps/network-pulse",
		},
	}
	raw, _ := json.MarshalIndent(manifest, "", "  ")
	_ = os.WriteFile(filepath.Join(appDir, "plugin.json"), raw, 0600)
	_ = os.WriteFile(filepath.Join(appDir, "icon.svg"), []byte(builtInDemoIconSVG), 0600)
	_ = os.WriteFile(filepath.Join(uiDir, "index.html"), []byte(builtInDemoHTML), 0600)
	_ = os.WriteFile(marker, []byte("initialized\n"), 0600)
}

const builtInDemoIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#0A84FF"/>
  <path d="M12 34h10l6-14 8 28 6-14h10" stroke="#FFFFFF" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`

const builtInDemoHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>轻屿网络与系统脉搏</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card { background: #1c1c1e !important; border-color: rgba(255,255,255,0.1) !important; } }
  .wrap { max-width: 680px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; box-shadow: 0 4px 16px rgba(0,0,0,0.04); }
  h1 { margin: 0 0 6px; font-size: 20px; font-weight: 600; }
  p { margin: 0; font-size: 13px; opacity: 0.7; }
  .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-top: 16px; }
  .metric { padding: 14px; border-radius: 12px; background: rgba(10,132,255,0.08); }
  .metric .label { font-size: 12px; opacity: 0.75; }
  .metric .val { font-size: 24px; font-weight: 600; color: #0a84ff; margin-top: 4px; }
  button { margin-top: 16px; background: #0a84ff; color: #fff; border: none; border-radius: 10px; padding: 8px 16px; font-size: 13px; font-weight: 500; cursor: pointer; }
</style></head>
<body><div class="wrap"><div class="card">
  <h1>轻屿网络与系统脉搏</h1>
  <p>内置静态轻应用（Zero-RSS Static Mode）· 实时检测当前终端与 LightIsle 主机的局域网连接响应</p>
  <div class="metrics">
    <div class="metric"><div class="label">往返延迟 (RTT)</div><div class="val" id="rtt">-- ms</div></div>
    <div class="metric"><div class="label">平均抖动 (Jitter)</div><div class="val" id="jitter">-- ms</div></div>
    <div class="metric"><div class="label">探测状态</div><div class="val" id="state">就绪</div></div>
  </div>
  <button id="probeBtn">立即探测</button>
</div></div>
<script>
const samples = [];
async function probe() {
  const t0 = performance.now();
  try {
    await fetch(window.location.pathname, { cache: 'no-store', method: 'HEAD' });
    const ms = Math.max(1, Math.round(performance.now() - t0));
    samples.push(ms); if (samples.length > 8) samples.shift();
    document.getElementById('rtt').textContent = ms + ' ms';
    const avg = samples.reduce((a,b)=>a+b,0)/samples.length;
    const jit = Math.round(samples.reduce((a,b)=>a+Math.abs(b-avg),0)/samples.length);
    document.getElementById('jitter').textContent = jit + ' ms';
    document.getElementById('state').textContent = '在线';
  } catch (e) { document.getElementById('state').textContent = '离线'; }
}
document.getElementById('probeBtn').addEventListener('click', probe);
probe(); setInterval(probe, 5000);
</script></body></html>`
