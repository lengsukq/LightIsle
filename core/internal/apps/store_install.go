package apps

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const storePackageDownloadTimeout = 90 * time.Second

func (m *Manager) resolveStorePluginEntry(ctx context.Context, pluginID string, forceRefreshIfMissing bool) (StorePluginEntry, string, string, bool, error) {
	if !ValidPluginID(pluginID) {
		return StorePluginEntry{}, "", "", false, ErrInvalid
	}
	registryURL, mirrorPrefix, isOfficial := m.readStoreConfig()
	m.storeMu.Lock()
	cache := m.loadStoreCacheLocked(registryURL)
	m.storeMu.Unlock()

	if cache != nil {
		for _, item := range cache.Document.Plugins {
			if item.ID == pluginID {
				return item, registryURL, mirrorPrefix, isOfficial, nil
			}
		}
	}
	if !forceRefreshIfMissing {
		return StorePluginEntry{}, registryURL, mirrorPrefix, isOfficial, ErrStorePluginNotFound
	}
	if _, err := m.RefreshStore(ctx); err != nil {
		return StorePluginEntry{}, registryURL, mirrorPrefix, isOfficial, err
	}
	m.storeMu.Lock()
	cache = m.loadStoreCacheLocked(registryURL)
	m.storeMu.Unlock()
	if cache != nil {
		for _, item := range cache.Document.Plugins {
			if item.ID == pluginID {
				return item, registryURL, mirrorPrefix, isOfficial, nil
			}
		}
	}
	return StorePluginEntry{}, registryURL, mirrorPrefix, isOfficial, ErrStorePluginNotFound
}

func (m *Manager) downloadAndVerifyStorePackage(
	ctx context.Context,
	entry StorePluginEntry,
	registryURL, mirrorPrefix, stageDir string,
) (PluginManifest, error) {
	m.storeMu.Lock()
	allowLoopback := m.allowStoreLoopbackForTest
	m.storeMu.Unlock()

	expectedSHA := strings.ToLower(strings.TrimSpace(entry.SHA256))
	if !hexSHA256Pattern.MatchString(expectedSHA) {
		return PluginManifest{}, fmt.Errorf("%w: 商店清单缺少合法 SHA-256 校验值", ErrStoreChecksumMismatch)
	}
	rawURL, err := ResolveStoreAssetURL(registryURL, entry.PackagePath, allowLoopback)
	if err != nil {
		return PluginManifest{}, err
	}
	downloadURL := ApplyStoreMirror(rawURL, mirrorPrefix)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, downloadURL, nil)
	if err != nil {
		return PluginManifest{}, fmt.Errorf("%w: 插件包下载地址无效", ErrStoreUnavailable)
	}
	req.Header.Set("User-Agent", "LightIsle-Store/1.0")

	resp, err := m.getStoreHTTPClient(storePackageDownloadTimeout).Do(req)
	if err != nil {
		return PluginManifest{}, fmt.Errorf("%w: 下载插件包失败，请检查网络或镜像设置 (%v)", ErrStoreUnavailable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return PluginManifest{}, fmt.Errorf("%w: 插件包下载返回 HTTP %d", ErrStoreUnavailable, resp.StatusCode)
	}

	tmpFile, err := os.CreateTemp("", "lightisle-store-pkg-*.liapp.zip")
	if err != nil {
		return PluginManifest{}, err
	}
	tmpPath := tmpFile.Name()
	defer func() {
		_ = tmpFile.Close()
		_ = os.Remove(tmpPath)
	}()

	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(tmpFile, hasher), io.LimitReader(resp.Body, maxPackageArchiveBytes+1))
	if err != nil {
		return PluginManifest{}, fmt.Errorf("%w: 读取插件包内容失败 (%v)", ErrStoreUnavailable, err)
	}
	if written <= 0 {
		return PluginManifest{}, fmt.Errorf("%w: 下载到的插件包为空", ErrStoreUnavailable)
	}
	if written > maxPackageArchiveBytes {
		return PluginManifest{}, fmt.Errorf("%w: 插件包超过 64 MiB 安全限制", ErrInvalid)
	}

	actualSHA := hex.EncodeToString(hasher.Sum(nil))
	if !strings.EqualFold(actualSHA, expectedSHA) {
		return PluginManifest{}, fmt.Errorf("%w: 下载包 SHA-256 校验不匹配（期望 %s，实际 %s）", ErrStoreChecksumMismatch, expectedSHA[:12], actualSHA[:12])
	}

	zr, err := zip.NewReader(tmpFile, written)
	if err != nil {
		return PluginManifest{}, fmt.Errorf("%w: 插件包归档损坏 (%v)", ErrInvalid, err)
	}
	manifest, err := extractAndVerifyPackageZip(ctx, zr, stageDir)
	if err != nil {
		return PluginManifest{}, err
	}
	if manifest.ID != entry.ID {
		return PluginManifest{}, fmt.Errorf("%w: 插件包内 ID (%q) 与商店条目 (%q) 不一致", ErrInvalid, manifest.ID, entry.ID)
	}
	return manifest, nil
}

func isAutoTrustedStorePlugin(isOfficial bool, manifest PluginManifest) bool {
	return isOfficial &&
		manifest.Web != nil &&
		manifest.Web.Mode == WebModeStatic &&
		manifest.Cron == nil
}

// InstallStorePlugin downloads, SHA-256 verifies, and installs a plugin from the configured Git store.
func (m *Manager) InstallStorePlugin(ctx context.Context, pluginID, locationID string) (PublicApp, error) {
	if !ValidPluginID(pluginID) {
		return PublicApp{}, ErrInvalid
	}
	if m.appIDExistsAnywhere(pluginID) {
		return PublicApp{}, ErrAlreadyInstalled
	}
	entry, registryURL, mirrorPrefix, isOfficial, err := m.resolveStorePluginEntry(ctx, pluginID, true)
	if err != nil {
		return PublicApp{}, err
	}
	target, err := m.ResolveInstallTarget(locationID)
	if err != nil {
		return PublicApp{}, err
	}
	if err := os.MkdirAll(target.pluginsDir, 0700); err != nil {
		return PublicApp{}, err
	}

	stageDir, err := os.MkdirTemp(target.pluginsDir, ".store-install-*")
	if err != nil {
		return PublicApp{}, err
	}
	stageMoved := false
	defer func() {
		if !stageMoved {
			_ = os.RemoveAll(stageDir)
		}
	}()

	manifest, err := m.downloadAndVerifyStorePackage(ctx, entry, registryURL, mirrorPrefix, stageDir)
	if err != nil {
		return PublicApp{}, err
	}

	m.mutation.Lock()
	if m.appIDExistsAnywhere(manifest.ID) {
		m.mutation.Unlock()
		return PublicApp{}, ErrAlreadyInstalled
	}
	destDir := filepath.Join(target.pluginsDir, manifest.ID)
	if _, err := os.Lstat(destDir); err == nil {
		m.mutation.Unlock()
		return PublicApp{}, ErrAlreadyInstalled
	}
	if err := os.Rename(stageDir, destDir); err != nil {
		m.mutation.Unlock()
		return PublicApp{}, err
	}
	stageMoved = true
	_ = os.MkdirAll(filepath.Join(target.dataRoot, manifest.ID), 0700)

	cfg, cfgErr := readSystemConfigFile(m.configPath)
	if cfgErr == nil {
		if isAutoTrustedStorePlugin(isOfficial, manifest) {
			cfg.PendingApps = removeString(cfg.PendingApps, manifest.ID)
			if !slices.Contains(cfg.ActivatedApps, manifest.ID) {
				cfg.ActivatedApps = uniqueSortedStrings(append(cfg.ActivatedApps, manifest.ID))
			}
		} else {
			cfg.ActivatedApps = removeString(cfg.ActivatedApps, manifest.ID)
			if !slices.Contains(cfg.PendingApps, manifest.ID) {
				cfg.PendingApps = uniqueSortedStrings(append(cfg.PendingApps, manifest.ID))
			}
		}
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		_ = writeSystemConfigFile(m.configPath, cfg)
	}
	m.mutation.Unlock()

	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	return m.GetForUser(manifest.ID, 0, "admin")
}

// UpgradeStorePlugin upgrades an installed plugin in-place from the Git store while strictly preserving
// plugin-data/<id> (KV store, SQLite DBs), env.json, and user access/runtime/cron settings.
func (m *Manager) UpgradeStorePlugin(ctx context.Context, pluginID string) (PublicApp, error) {
	if !ValidPluginID(pluginID) {
		return PublicApp{}, ErrInvalid
	}
	snap, ok := m.snapshotApp(pluginID)
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if err := m.verifyRecordStorageOnline(snap.locationID, snap.pluginDir); err != nil {
		return PublicApp{}, err
	}
	entry, registryURL, mirrorPrefix, isOfficial, err := m.resolveStorePluginEntry(ctx, pluginID, true)
	if err != nil {
		return PublicApp{}, err
	}
	if CompareSemver(entry.Version, snap.manifest.Version) <= 0 {
		return PublicApp{}, ErrStoreNoUpdate
	}

	parentDir := filepath.Dir(snap.pluginDir)
	stageDir, err := os.MkdirTemp(parentDir, ".store-upgrade-*")
	if err != nil {
		return PublicApp{}, err
	}
	stageMoved := false
	defer func() {
		if !stageMoved {
			_ = os.RemoveAll(stageDir)
		}
	}()

	nextManifest, err := m.downloadAndVerifyStorePackage(ctx, entry, registryURL, mirrorPrefix, stageDir)
	if err != nil {
		return PublicApp{}, err
	}
	if err := mergePreservedPluginSettings(snap.pluginDir, snap.manifest, stageDir, &nextManifest); err != nil {
		return PublicApp{}, err
	}

	m.mutation.Lock()
	liveSnap, ok := m.snapshotApp(pluginID)
	if !ok {
		m.mutation.Unlock()
		return PublicApp{}, ErrNotFound
	}
	if liveSnap.instance != nil {
		_ = liveSnap.instance.Stop(false)
	}
	backupDir := filepath.Join(parentDir, fmt.Sprintf(".store-backup-%s-%d", pluginID, time.Now().UnixNano()))
	if err := os.Rename(liveSnap.pluginDir, backupDir); err != nil {
		m.mutation.Unlock()
		return PublicApp{}, err
	}
	if err := os.Rename(stageDir, liveSnap.pluginDir); err != nil {
		_ = os.Rename(backupDir, liveSnap.pluginDir)
		m.mutation.Unlock()
		return PublicApp{}, err
	}
	stageMoved = true
	_ = os.RemoveAll(backupDir)

	cfg, cfgErr := readSystemConfigFile(m.configPath)
	if cfgErr == nil {
		if isAutoTrustedStorePlugin(isOfficial, nextManifest) && !liveSnap.pendingActivation {
			cfg.PendingApps = removeString(cfg.PendingApps, nextManifest.ID)
			if !slices.Contains(cfg.ActivatedApps, nextManifest.ID) {
				cfg.ActivatedApps = uniqueSortedStrings(append(cfg.ActivatedApps, nextManifest.ID))
			}
		} else {
			cfg.ActivatedApps = removeString(cfg.ActivatedApps, nextManifest.ID)
			if !slices.Contains(cfg.PendingApps, nextManifest.ID) {
				cfg.PendingApps = uniqueSortedStrings(append(cfg.PendingApps, nextManifest.ID))
			}
		}
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		_ = writeSystemConfigFile(m.configPath, cfg)
	}
	m.mutation.Unlock()

	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	return m.GetForUser(nextManifest.ID, 0, "admin")
}

func mergePreservedPluginSettings(oldPluginDir string, oldManifest PluginManifest, stageDir string, nextManifest *PluginManifest) error {
	// 1. Preserve local env.json secrets if present.
	oldEnvPath := filepath.Join(oldPluginDir, "env.json")
	if rawEnv, err := os.ReadFile(oldEnvPath); err == nil {
		if writeErr := os.WriteFile(filepath.Join(stageDir, "env.json"), rawEnv, 0600); writeErr != nil {
			return writeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	// 2. Preserve user access policy & allowlist.
	nextManifest.Access = AccessConfig{
		Policy:         normalizeAccessPolicy(oldManifest.Access.Policy),
		AllowedUserIDs: slices.Clone(oldManifest.Access.AllowedUserIDs),
	}
	if nextManifest.Access.AllowedUserIDs == nil {
		nextManifest.Access.AllowedUserIDs = []int64{}
	}

	// 3. Preserve compatible web & cron user settings.
	if oldManifest.Web != nil && nextManifest.Web != nil {
		nextManifest.Web.Enabled = oldManifest.Web.Enabled
		if oldManifest.Web.Mode == nextManifest.Web.Mode {
			if oldManifest.Web.IdleTimeoutSeconds > 0 {
				nextManifest.Web.IdleTimeoutSeconds = oldManifest.Web.IdleTimeoutSeconds
			}
			nextManifest.Web.AutoRestart = oldManifest.Web.AutoRestart
		}
	}
	if oldManifest.Cron != nil && nextManifest.Cron != nil {
		nextManifest.Cron.Enabled = oldManifest.Cron.Enabled
		if strings.TrimSpace(oldManifest.Cron.Schedule.Cron) != "" {
			nextManifest.Cron.Schedule = oldManifest.Cron.Schedule
		}
		nextManifest.Cron.Notification = oldManifest.Cron.Notification
	}

	raw, err := json.MarshalIndent(nextManifest, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(stageDir, "plugin.json"), raw, 0600); err != nil {
		return err
	}
	root, err := os.OpenRoot(stageDir)
	if err != nil {
		return err
	}
	defer root.Close()
	validated, err := ValidateManifest(root, nextManifest.ID, raw)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	*nextManifest = validated
	return nil
}
