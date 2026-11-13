package apps

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func (m *Manager) prepareValidatedStorageLocation(kind, rawPath, rawName string, existing *AppsStorageSettings) (StoredAppLocation, error) {
	trimmed := strings.TrimSpace(rawPath)
	if trimmed == "" {
		return StoredAppLocation{}, fmt.Errorf("%w: 请选择存储目录路径", ErrInvalid)
	}
	if !filepath.IsAbs(trimmed) {
		return StoredAppLocation{}, fmt.Errorf("%w: 存储目录必须是绝对路径", ErrInvalid)
	}
	cleanPath := filepath.Clean(trimmed)
	if linfo, lerr := os.Lstat(cleanPath); lerr == nil && linfo.Mode()&os.ModeSymlink != 0 {
		return StoredAppLocation{}, fmt.Errorf("%w: 存储位置不能是符号链接（请直接选择真实磁盘目录）", ErrInvalid)
	}
	resolvedPath, err := resolvePathWithExistingParent(cleanPath)
	if err != nil {
		return StoredAppLocation{}, fmt.Errorf("%w: 解析存储路径失败: %v", ErrInvalid, err)
	}

	prefixes := m.getExternalPrefixes()
	inExternalClean := isUnderExternalPrefix(cleanPath, prefixes)
	inExternalResolved := isUnderExternalPrefix(resolvedPath, prefixes)

	if kind == AppStorageKindExternal {
		if !inExternalClean || !inExternalResolved {
			return StoredAppLocation{}, fmt.Errorf("%w: 其他盘路径必须位于已挂载的外接磁盘卷下（例如 /Volumes/磁盘名/LightIsleApps）", ErrInvalid)
		}
		if err := m.ensureExternalMountPointExists(cleanPath, prefixes); err != nil {
			return StoredAppLocation{}, err
		}
	} else {
		if inExternalClean || inExternalResolved {
			return StoredAppLocation{}, fmt.Errorf("%w: 内置盘位置不能选择 /Volumes 外接磁盘路径，请放在其他盘槽位中", ErrInvalid)
		}
	}

	// Guard against overlapping internal and external directories.
	if kind == AppStorageKindExternal {
		intSpec := m.effectiveInternalSpec(existing)
		if pathsOverlap(cleanPath, intSpec.Path) || pathsOverlap(cleanPath, m.dataDir) {
			return StoredAppLocation{}, fmt.Errorf("%w: 其他盘目录不能与内置盘应用目录重叠或包含", ErrInvalid)
		}
	} else if existing != nil && existing.External != nil && strings.TrimSpace(existing.External.Path) != "" {
		if pathsOverlap(cleanPath, existing.External.Path) {
			return StoredAppLocation{}, fmt.Errorf("%w: 内置盘目录不能与其他盘应用目录重叠或包含", ErrInvalid)
		}
	}

	if err := ensureStorageSubdirsAndWritable(cleanPath); err != nil {
		return StoredAppLocation{}, err
	}

	binding, err := m.getStorageProvider().Capture(context.Background(), cleanPath)
	if err != nil {
		return StoredAppLocation{}, fmt.Errorf("%w: 无法绑定磁盘唯一身份标识，请确认目录权限后重试: %v", ErrStorageOffline, err)
	}

	volumes := m.getAvailableVolumes()
	name := strings.TrimSpace(rawName)
	if name == "" {
		if kind == AppStorageKindExternal {
			name = inferExternalStorageName(cleanPath, volumes)
		} else {
			name = defaultInternalStorageName
		}
	}

	return StoredAppLocation{
		ID:        kind,
		Kind:      kind,
		Name:      name,
		Path:      cleanPath,
		Binding:   &binding,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *Manager) ensureExternalMountPointExists(cleanPath string, prefixes []string) error {
	for _, prefix := range prefixes {
		cleanPrefix := strings.TrimSuffix(prefix, string(filepath.Separator))
		if cleanPath == cleanPrefix {
			return fmt.Errorf("%w: 请选择具体外置磁盘下的子目录，不能直接选择 %s 根目录", ErrInvalid, cleanPrefix)
		}
		if !strings.HasPrefix(cleanPath, prefix) {
			continue
		}
		rel := strings.TrimPrefix(cleanPath, prefix)
		parts := strings.Split(rel, string(filepath.Separator))
		if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
			return fmt.Errorf("%w: 请选择具体外置磁盘卷路径", ErrInvalid)
		}
		mountRoot := filepath.Join(cleanPrefix, parts[0])
		info, err := os.Stat(mountRoot)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("%w: 未检测到外置磁盘卷 %s，请先连接或挂载该硬盘", ErrStorageOffline, mountRoot)
		}
		return nil
	}
	return fmt.Errorf("%w: 无效的外置磁盘路径", ErrInvalid)
}

func ensureStorageSubdirsAndWritable(root string) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return fmt.Errorf("%w: 无法创建应用存储根目录（请检查权限）: %v", ErrStorageOffline, err)
	}
	if err := probeWritableDir(root); err != nil {
		return fmt.Errorf("%w: 所选目录当前不可写入（请先在 macOS 隐私与安全性中授予读写权限）: %v", ErrStorageOffline, err)
	}
	for _, sub := range []string{"plugins", "plugin-data"} {
		subDir := filepath.Join(root, sub)
		if err := os.MkdirAll(subDir, 0700); err != nil {
			return fmt.Errorf("%w: 无法初始化 %s 目录: %v", ErrStorageOffline, sub, err)
		}
	}
	return nil
}

func probeWritableDir(dir string) error {
	f, err := os.CreateTemp(dir, ".lightisle-write-probe-*")
	if err != nil {
		return err
	}
	name := f.Name()
	_, writeErr := f.WriteString("ok")
	closeErr := f.Close()
	removeErr := os.Remove(name)
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return removeErr
}

func resolvePathWithExistingParent(cleanPath string) (string, error) {
	if resolved, err := filepath.EvalSymlinks(cleanPath); err == nil {
		return filepath.Clean(resolved), nil
	}
	suffixes := make([]string, 0, 4)
	cur := cleanPath
	for {
		parent := filepath.Dir(cur)
		base := filepath.Base(cur)
		if parent == cur {
			return cleanPath, nil
		}
		suffixes = append(suffixes, base)
		cur = parent
		if resolvedParent, err := filepath.EvalSymlinks(cur); err == nil {
			slices.Reverse(suffixes)
			parts := append([]string{resolvedParent}, suffixes...)
			return filepath.Clean(filepath.Join(parts...)), nil
		}
	}
}

func isUnderExternalPrefix(cleanPath string, prefixes []string) bool {
	for _, prefix := range prefixes {
		cleanPrefix := strings.TrimSuffix(prefix, string(filepath.Separator))
		if cleanPath == cleanPrefix || strings.HasPrefix(cleanPath, prefix) {
			return true
		}
	}
	return false
}

func pathsOverlap(a, b string) bool {
	ca := filepath.Clean(a)
	cb := filepath.Clean(b)
	if ra, err := resolvePathWithExistingParent(ca); err == nil {
		ca = ra
	}
	if rb, err := resolvePathWithExistingParent(cb); err == nil {
		cb = rb
	}
	if ca == cb {
		return true
	}
	return strings.HasPrefix(ca, caWithSep(cb)) || strings.HasPrefix(cb, caWithSep(ca))
}

func caWithSep(p string) string {
	if strings.HasSuffix(p, string(filepath.Separator)) {
		return p
	}
	return p + string(filepath.Separator)
}

func inferExternalStorageName(cleanPath string, volumes []AppStorageVolumeOption) string {
	if vol, ok := matchVolumeOption(cleanPath, volumes); ok && strings.TrimSpace(vol.Name) != "" {
		return vol.Name
	}
	if strings.HasPrefix(cleanPath, "/Volumes/") {
		rel := strings.TrimPrefix(cleanPath, "/Volumes/")
		parts := strings.Split(rel, string(filepath.Separator))
		if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" {
			return parts[0]
		}
	}
	base := filepath.Base(cleanPath)
	if base != "" && base != "." && base != string(filepath.Separator) {
		return base
	}
	return defaultExternalStorageName
}

func matchVolumeOption(cleanPath string, volumes []AppStorageVolumeOption) (AppStorageVolumeOption, bool) {
	bestLen := -1
	var best AppStorageVolumeOption
	for _, v := range volumes {
		mount := filepath.Clean(v.Mount)
		if mount == "" {
			continue
		}
		if cleanPath == mount || strings.HasPrefix(cleanPath, caWithSep(mount)) {
			if len(mount) > bestLen {
				bestLen = len(mount)
				best = v
			}
		}
	}
	return best, bestLen >= 0
}

func statfsBytes(path string) (total uint64, free uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	bsize := uint64(st.Bsize)
	return st.Blocks * bsize, st.Bavail * bsize, nil
}

// ResolveInstallTarget validates and returns the storage location where a new app should be installed.
func (m *Manager) ResolveInstallTarget(requestedID string) (storageScanRoot, error) {
	cfg, _ := readSystemConfigFile(m.configPath)
	return resolveInstallTargetWithProvider(m.dataDir, cfg, requestedID, m.getStorageProvider(), m.getAvailableVolumes())
}

func resolveInstallTargetWithProvider(dataDir string, cfg AppsSystemConfig, requestedID string, provider storageidentity.Provider, volumes []AppStorageVolumeOption) (storageScanRoot, error) {
	targetID := strings.ToLower(strings.TrimSpace(requestedID))
	if targetID == "" {
		targetID = normalizedDefaultLocationID(cfg.Storage)
	}
	if targetID != AppStorageIDInternal && targetID != AppStorageIDExternal {
		return storageScanRoot{}, fmt.Errorf("%w: 存储位置无效，请选择 internal（内置盘）或 external（其他盘）", ErrInvalid)
	}

	var spec StoredAppLocation
	if targetID == AppStorageIDExternal {
		if cfg.Storage == nil || cfg.Storage.External == nil || strings.TrimSpace(cfg.Storage.External.Path) == "" {
			return storageScanRoot{}, fmt.Errorf("%w: 尚未添加其他盘存储位置，请先在应用存储设置中添加外置磁盘目录", ErrInvalid)
		}
		spec = *cfg.Storage.External
		spec.ID = AppStorageIDExternal
		spec.Kind = AppStorageKindExternal
		spec.Path = filepath.Clean(spec.Path)
		if strings.TrimSpace(spec.Name) == "" {
			spec.Name = inferExternalStorageName(spec.Path, volumes)
		}
		if spec.Binding != nil {
			if err := provider.Verify(context.Background(), *spec.Binding); err != nil {
				return storageScanRoot{}, fmt.Errorf("%w: %s", ErrStorageOffline, describeStorageVerifyError(err, spec.Name))
			}
		}
	} else {
		if cfg.Storage != nil && cfg.Storage.Internal != nil && strings.TrimSpace(cfg.Storage.Internal.Path) != "" {
			spec = *cfg.Storage.Internal
			spec.ID = AppStorageIDInternal
			spec.Kind = AppStorageKindInternal
			spec.Path = filepath.Clean(spec.Path)
			if strings.TrimSpace(spec.Name) == "" {
				spec.Name = defaultInternalStorageName
			}
		} else {
			spec = StoredAppLocation{
				ID:   AppStorageIDInternal,
				Kind: AppStorageKindInternal,
				Name: defaultInternalStorageName,
				Path: filepath.Clean(dataDir),
			}
		}
	}

	if err := ensureStorageSubdirsAndWritable(spec.Path); err != nil {
		return storageScanRoot{}, err
	}
	return storageScanRoot{
		id:         spec.ID,
		kind:       spec.Kind,
		name:       spec.Name,
		path:       spec.Path,
		pluginsDir: filepath.Join(spec.Path, "plugins"),
		dataRoot:   filepath.Join(spec.Path, "plugin-data"),
	}, nil
}

func (m *Manager) listConfiguredScanRoots() []storageScanRoot {
	cfg, _ := readSystemConfigFile(m.configPath)
	return listConfiguredScanRootsWithConfig(m.dataDir, cfg, m.getStorageProvider(), m.getAvailableVolumes())
}

func listConfiguredScanRootsWithConfig(dataDir string, cfg AppsSystemConfig, provider storageidentity.Provider, volumes []AppStorageVolumeOption) []storageScanRoot {
	roots := make([]storageScanRoot, 0, 3)

	// 1. Primary internal location (custom or default m.dataDir).
	internalPath := filepath.Clean(dataDir)
	internalName := defaultInternalStorageName
	if cfg.Storage != nil && cfg.Storage.Internal != nil && strings.TrimSpace(cfg.Storage.Internal.Path) != "" {
		internalPath = filepath.Clean(cfg.Storage.Internal.Path)
		if strings.TrimSpace(cfg.Storage.Internal.Name) != "" {
			internalName = cfg.Storage.Internal.Name
		}
	}
	roots = append(roots, storageScanRoot{
		id:         AppStorageIDInternal,
		kind:       AppStorageKindInternal,
		name:       internalName,
		path:       internalPath,
		pluginsDir: filepath.Join(internalPath, "plugins"),
		dataRoot:   filepath.Join(internalPath, "plugin-data"),
	})

	// 2. External location (only when configured AND verified online).
	if cfg.Storage != nil && cfg.Storage.External != nil && strings.TrimSpace(cfg.Storage.External.Path) != "" {
		extSpec := *cfg.Storage.External
		extPath := filepath.Clean(extSpec.Path)
		extName := strings.TrimSpace(extSpec.Name)
		if extName == "" {
			extName = inferExternalStorageName(extPath, volumes)
		}
		verified := true
		if extSpec.Binding != nil && provider != nil {
			if err := provider.Verify(context.Background(), *extSpec.Binding); err != nil {
				verified = false
			}
		}
		if verified {
			if info, err := os.Stat(extPath); err == nil && info.IsDir() {
				roots = append(roots, storageScanRoot{
					id:         AppStorageIDExternal,
					kind:       AppStorageKindExternal,
					name:       extName,
					path:       extPath,
					pluginsDir: filepath.Join(extPath, "plugins"),
					dataRoot:   filepath.Join(extPath, "plugin-data"),
				})
			}
		}
	}

	// 3. Fallback system dataDir so legacy/default apps like network-pulse stay discoverable if internal was customized.
	defaultPath := filepath.Clean(dataDir)
	if internalPath != defaultPath {
		if info, err := os.Stat(filepath.Join(defaultPath, "plugins")); err == nil && info.IsDir() {
			roots = append(roots, storageScanRoot{
				id:         AppStorageIDInternal,
				kind:       AppStorageKindInternal,
				name:       defaultInternalStorageName,
				path:       defaultPath,
				pluginsDir: filepath.Join(defaultPath, "plugins"),
				dataRoot:   filepath.Join(defaultPath, "plugin-data"),
			})
		}
	}

	return roots
}

func fallbackString(val, def string) string {
	if strings.TrimSpace(val) == "" {
		return def
	}
	return val
}

func resolveScanRootsForMCP(dataDir string, mgr *Manager) []storageScanRoot {
	if mgr != nil {
		return mgr.listConfiguredScanRoots()
	}
	cfg, _ := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	return listConfiguredScanRootsWithConfig(dataDir, cfg, storageidentity.SystemProvider{}, nil)
}

func resolveInstallTargetForMCP(dataDir string, mgr *Manager, requestedID string) (storageScanRoot, error) {
	if mgr != nil {
		return mgr.ResolveInstallTarget(requestedID)
	}
	cfg, _ := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	return resolveInstallTargetWithProvider(dataDir, cfg, requestedID, storageidentity.SystemProvider{}, nil)
}

func findPluginAcrossScanRoots(dataDir string, mgr *Manager, appID string) (pluginDir string, dataRootDir string, scanRoot storageScanRoot, found bool) {
	if mgr != nil {
		if snap, ok := mgr.snapshotApp(appID); ok {
			return snap.pluginDir, snap.dataDir, storageScanRoot{
				id:         fallbackString(snap.locationID, AppStorageIDInternal),
				kind:       fallbackString(snap.locationKind, AppStorageKindInternal),
				name:       fallbackString(snap.locationName, defaultInternalStorageName),
				pluginsDir: filepath.Dir(snap.pluginDir),
				dataRoot:   filepath.Dir(snap.dataDir),
			}, true
		}
	}
	for _, root := range resolveScanRootsForMCP(dataDir, mgr) {
		cand := filepath.Join(root.pluginsDir, appID)
		if st, err := os.Lstat(cand); err == nil && st.IsDir() {
			return cand, filepath.Join(root.dataRoot, appID), root, true
		}
	}
	return "", "", storageScanRoot{}, false
}

func (m *Manager) appIDExistsAnywhere(appID string) bool {
	if _, ok := m.snapshotApp(appID); ok {
		return true
	}
	for _, root := range m.listConfiguredScanRoots() {
		if _, err := os.Stat(filepath.Join(root.pluginsDir, appID)); err == nil {
			return true
		}
	}
	return false
}
