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
	if !ValidPluginID(appID) {
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
