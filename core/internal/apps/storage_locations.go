package apps

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const (
	defaultInternalStorageName = "Mac 内置盘"
	defaultExternalStorageName = "外置其他盘"
)

// ExternalVolumeInfo describes a mounted non-boot volume available for app storage.
type ExternalVolumeInfo struct {
	Name       string
	Mount      string
	Filesystem string
	TotalBytes uint64
	FreeBytes  uint64
	ReadOnly   bool
}

type storageScanRoot struct {
	id         string
	kind       string
	name       string
	path       string
	pluginsDir string
	dataRoot   string
}

func (m *Manager) SetExternalVolumesProvider(fn func() []ExternalVolumeInfo) {
	m.mu.Lock()
	m.externalVolumesFn = fn
	m.mu.Unlock()
}

// SetStoragePolicyForTesting overrides identity provider and external volume prefixes for unit tests.
func (m *Manager) SetStoragePolicyForTesting(p storageidentity.Provider, externalPrefixes []string) {
	m.mu.Lock()
	m.storageProviderFn = p
	if externalPrefixes != nil {
		normalized := make([]string, 0, len(externalPrefixes)*2)
		addPrefix := func(raw string) {
			clean := filepath.Clean(strings.TrimSpace(raw))
			if clean == "" || clean == "." {
				return
			}
			if !strings.HasSuffix(clean, string(filepath.Separator)) {
				clean += string(filepath.Separator)
			}
			if !slices.Contains(normalized, clean) {
				normalized = append(normalized, clean)
			}
		}
		for _, prefix := range externalPrefixes {
			addPrefix(prefix)
			if resolved, err := resolvePathWithExistingParent(filepath.Clean(strings.TrimSpace(prefix))); err == nil {
				addPrefix(resolved)
			}
		}
		m.externalPrefixes = normalized
	}
	m.mu.Unlock()
}

func (m *Manager) getStorageProvider() storageidentity.Provider {
	m.mu.RLock()
	p := m.storageProviderFn
	m.mu.RUnlock()
	if p != nil {
		return p
	}
	return storageidentity.SystemProvider{}
}

func (m *Manager) getExternalPrefixes() []string {
	m.mu.RLock()
	prefixes := append([]string(nil), m.externalPrefixes...)
	m.mu.RUnlock()
	if len(prefixes) == 0 {
		return []string{"/Volumes/"}
	}
	return prefixes
}

func (m *Manager) getAvailableVolumes() []AppStorageVolumeOption {
	m.mu.RLock()
	fn := m.externalVolumesFn
	m.mu.RUnlock()
	if fn == nil {
		return []AppStorageVolumeOption{}
	}
	raw := fn()
	out := make([]AppStorageVolumeOption, 0, len(raw))
	for _, v := range raw {
		mount := filepath.Clean(strings.TrimSpace(v.Mount))
		if mount == "" || mount == "/" || mount == "/System/Volumes/Data" {
			continue
		}
		name := strings.TrimSpace(v.Name)
		if name == "" {
			name = filepath.Base(mount)
		}
		out = append(out, AppStorageVolumeOption{
			Name:       name,
			Mount:      mount,
			Suggested:  filepath.Join(mount, "LightIsleApps"),
			Filesystem: v.Filesystem,
			TotalBytes: v.TotalBytes,
			FreeBytes:  v.FreeBytes,
			ReadOnly:   v.ReadOnly,
		})
	}
	provider := m.getStorageProvider()
	if len(out) == 1 {
		if b, err := provider.Capture(context.Background(), out[0].Mount); err == nil {
			out[0].VolumeUUID = b.VolumeUUID
		}
	} else if len(out) > 1 {
		var wg sync.WaitGroup
		for i := range out {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				if b, err := provider.Capture(context.Background(), out[idx].Mount); err == nil {
					out[idx].VolumeUUID = b.VolumeUUID
				}
			}(i)
		}
		wg.Wait()
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func readAppsStorageSnapshotFromConfig(dataDir string) AppStorageSnapshot {
	cfg, _ := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	mgr := &Manager{
		dataDir:        dataDir,
		pluginsDir:     filepath.Join(dataDir, "plugins"),
		pluginDataRoot: filepath.Join(dataDir, "plugin-data"),
		configPath:     filepath.Join(dataDir, "apps-config.json"),
		apps:           map[string]*appRecord{},
	}
	return mgr.buildStorageSnapshot(cfg, false)
}

func (m *Manager) GetStorageSnapshot() AppStorageSnapshot {
	cfg, _ := readSystemConfigFile(m.configPath)
	return m.buildStorageSnapshot(cfg, true)
}

func (m *Manager) buildStorageSnapshot(cfg AppsSystemConfig, includeAppCounts bool) AppStorageSnapshot {
	volumes := m.getAvailableVolumes()
	counts := map[string]int{}
	if includeAppCounts {
		m.mu.RLock()
		for _, rec := range m.apps {
			locID := rec.locationID
			if locID == "" {
				locID = AppStorageIDInternal
			}
			counts[locID]++
		}
		m.mu.RUnlock()
	}

	defaultID := normalizedDefaultLocationID(cfg.Storage)
	internalSpec := m.effectiveInternalSpec(cfg.Storage)
	internalLoc := m.inspectLocation(internalSpec, defaultID == AppStorageIDInternal, cfg.Storage != nil && cfg.Storage.Internal != nil && filepath.Clean(cfg.Storage.Internal.Path) != filepath.Clean(m.dataDir), volumes, counts[AppStorageIDInternal])

	locations := []AppStorageLocation{internalLoc}
	hasExternal := cfg.Storage != nil && cfg.Storage.External != nil && strings.TrimSpace(cfg.Storage.External.Path) != ""
	if hasExternal {
		extSpec := *cfg.Storage.External
		extSpec.ID = AppStorageIDExternal
		extSpec.Kind = AppStorageKindExternal
		if strings.TrimSpace(extSpec.Name) == "" {
			extSpec.Name = inferExternalStorageName(extSpec.Path, volumes)
		}
		extLoc := m.inspectLocation(extSpec, defaultID == AppStorageIDExternal, true, volumes, counts[AppStorageIDExternal])
		locations = append(locations, extLoc)
	}

	return AppStorageSnapshot{
		DefaultLocationID: defaultID,
		MaxInternal:       1,
		MaxExternal:       1,
		MaxLocations:      2,
		HasExternal:       hasExternal,
		Locations:         locations,
		AvailableVolumes:  volumes,
	}
}

func normalizedDefaultLocationID(storage *AppsStorageSettings) string {
	if storage != nil && storage.DefaultLocationID == AppStorageIDExternal && storage.External != nil && strings.TrimSpace(storage.External.Path) != "" {
		return AppStorageIDExternal
	}
	return AppStorageIDInternal
}

func (m *Manager) effectiveInternalSpec(storage *AppsStorageSettings) StoredAppLocation {
	if storage != nil && storage.Internal != nil && strings.TrimSpace(storage.Internal.Path) != "" {
		spec := *storage.Internal
		spec.ID = AppStorageIDInternal
		spec.Kind = AppStorageKindInternal
		spec.Path = filepath.Clean(spec.Path)
		if strings.TrimSpace(spec.Name) == "" {
			spec.Name = defaultInternalStorageName
		}
		return spec
	}
	return StoredAppLocation{
		ID:   AppStorageIDInternal,
		Kind: AppStorageKindInternal,
		Name: defaultInternalStorageName,
		Path: filepath.Clean(m.dataDir),
	}
}

func (m *Manager) inspectLocation(spec StoredAppLocation, isDefault, isCustomPath bool, volumes []AppStorageVolumeOption, appCount int) AppStorageLocation {
	cleanPath := filepath.Clean(spec.Path)
	out := AppStorageLocation{
		ID:            spec.ID,
		Kind:          spec.Kind,
		Name:          spec.Name,
		Path:          cleanPath,
		PluginsDir:    filepath.Join(cleanPath, "plugins"),
		PluginDataDir: filepath.Join(cleanPath, "plugin-data"),
		IsDefault:     isDefault,
		IsCustomPath:  isCustomPath,
		AppCount:      appCount,
	}

	if vol, ok := matchVolumeOption(cleanPath, volumes); ok {
		out.VolumeName = vol.Name
		out.VolumeMount = vol.Mount
		out.VolumeUUID = vol.VolumeUUID
		out.FreeBytes = vol.FreeBytes
		out.TotalBytes = vol.TotalBytes
	}
	if spec.Binding != nil && out.VolumeUUID == "" {
		out.VolumeUUID = spec.Binding.VolumeUUID
	}

	if spec.Kind == AppStorageKindExternal && spec.Binding != nil {
		if err := m.getStorageProvider().Verify(context.Background(), *spec.Binding); err != nil {
			out.Online = false
			out.Writable = false
			out.Error = describeStorageVerifyError(err, out.Name)
			return out
		}
	}

	info, err := os.Stat(cleanPath)
	if err != nil {
		out.Online = false
		out.Writable = false
		if spec.Kind == AppStorageKindExternal {
			out.Error = fmt.Sprintf("其他盘位置不可达，请确认外置硬盘（%s）已连接：%v", out.Name, err)
		} else {
			out.Error = fmt.Sprintf("内置盘应用目录不存在或无权访问：%v", err)
		}
		return out
	}
	if !info.IsDir() {
		out.Online = false
		out.Writable = false
		out.Error = "所选存储路径不是有效文件夹"
		return out
	}

	if total, free, err := statfsBytes(cleanPath); err == nil {
		out.TotalBytes = total
		out.FreeBytes = free
	}

	out.Online = true
	if err := probeWritableDir(cleanPath); err != nil {
		out.Writable = false
		out.Error = fmt.Sprintf("存储目录当前不可写，请在系统设置中检查磁盘/文件夹读写权限：%v", err)
		return out
	}
	out.Writable = true
	return out
}

func describeStorageVerifyError(err error, name string) string {
	switch {
	case errors.Is(err, storageidentity.ErrMismatch), errors.Is(err, storageidentity.ErrMountPoint):
		return fmt.Sprintf("检测到「%s」对应目录或物理硬盘标识已发生变化，为防止错认同名硬盘，已暂停访问。如需使用新硬盘请先移除旧登记后再添加。", name)
	case os.IsNotExist(err), errors.Is(err, storageidentity.ErrNotDirectory):
		return fmt.Sprintf("其他盘「%s」当前处于离线状态或目录不存在，请检查硬盘连接或供电是否正常。", name)
	default:
		return fmt.Sprintf("其他盘「%s」身份校验未通过：%v", name, err)
	}
}

func (m *Manager) MutateStorageLocation(req AppStorageMutationRequest) (AppStorageSnapshot, error) {
	action := strings.ToLower(strings.TrimSpace(req.Action))
	kind := strings.ToLower(strings.TrimSpace(req.Kind))

	var (
		snapshot AppStorageSnapshot
		toStop   []*Instance
	)

	m.mutation.Lock()
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil && !os.IsNotExist(err) {
		m.mutation.Unlock()
		return AppStorageSnapshot{}, fmt.Errorf("%w: 读取应用存储配置失败: %v", ErrInvalid, err)
	}
	if cfg.Storage == nil {
		cfg.Storage = &AppsStorageSettings{DefaultLocationID: AppStorageIDInternal}
	}

	switch action {
	case "set_default":
		targetID := strings.ToLower(strings.TrimSpace(req.DefaultLocationID))
		if targetID != AppStorageIDInternal && targetID != AppStorageIDExternal {
			m.mutation.Unlock()
			return AppStorageSnapshot{}, fmt.Errorf("%w: 默认位置仅支持 internal（内置盘）或 external（其他盘）", ErrInvalid)
		}
		if targetID == AppStorageIDExternal && (cfg.Storage.External == nil || strings.TrimSpace(cfg.Storage.External.Path) == "") {
			m.mutation.Unlock()
			return AppStorageSnapshot{}, fmt.Errorf("%w: 尚未添加其他盘存储位置，无法设为主选默认位置", ErrInvalid)
		}
		cfg.Storage.DefaultLocationID = targetID
		if err := m.writeStorageConfig(&cfg); err != nil {
			m.mutation.Unlock()
			return AppStorageSnapshot{}, err
		}

	case "reset_internal":
		if cfg.Storage.Internal != nil {
			toStop = append(toStop, m.detachRunningByLocation(AppStorageIDInternal)...)
			cfg.Storage.Internal = nil
			if cfg.Storage.DefaultLocationID == "" {
				cfg.Storage.DefaultLocationID = AppStorageIDInternal
			}
			if err := m.writeStorageConfig(&cfg); err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}
		}

	case "remove_external":
		if cfg.Storage.External != nil {
			// Safe detach: stop running apps hosted on external disk without deleting any files on disk.
			toStop = append(toStop, m.detachRunningByLocation(AppStorageIDExternal)...)
			cfg.Storage.External = nil
			if cfg.Storage.DefaultLocationID == AppStorageIDExternal {
				cfg.Storage.DefaultLocationID = AppStorageIDInternal
			}
			if err := m.writeStorageConfig(&cfg); err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}
		}

	case "add", "set":
		switch kind {
		case AppStorageKindInternal:
			if action == "add" {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, fmt.Errorf("%w: 内置盘仅支持 1 个存储位置，请直接修改内置盘路径或恢复默认路径", ErrStorageSlotLimit)
			}
			spec, err := m.prepareValidatedStorageLocation(AppStorageKindInternal, req.Path, req.Name, cfg.Storage)
			if err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}
			oldInternal := m.effectiveInternalSpec(cfg.Storage)
			if filepath.Clean(oldInternal.Path) != filepath.Clean(spec.Path) {
				toStop = append(toStop, m.detachRunningByLocation(AppStorageIDInternal)...)
			}
			if filepath.Clean(spec.Path) == filepath.Clean(m.dataDir) {
				cfg.Storage.Internal = nil
			} else {
				cfg.Storage.Internal = &spec
			}
			if req.SetDefault {
				cfg.Storage.DefaultLocationID = AppStorageIDInternal
			}
			if err := m.writeStorageConfig(&cfg); err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}

		case AppStorageKindExternal:
			if action == "add" && cfg.Storage.External != nil && strings.TrimSpace(cfg.Storage.External.Path) != "" {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, fmt.Errorf("%w: 已存在 1 个其他盘存储位置，总计最多仅支持 1 个内置盘和 1 个其他盘。如需更换，请先移除或替换现有其他盘位置。", ErrStorageSlotLimit)
			}
			spec, err := m.prepareValidatedStorageLocation(AppStorageKindExternal, req.Path, req.Name, cfg.Storage)
			if err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}
			if cfg.Storage.External != nil && filepath.Clean(cfg.Storage.External.Path) != filepath.Clean(spec.Path) {
				toStop = append(toStop, m.detachRunningByLocation(AppStorageIDExternal)...)
			}
			cfg.Storage.External = &spec
			if req.SetDefault || strings.TrimSpace(cfg.Storage.DefaultLocationID) == "" {
				if req.SetDefault {
					cfg.Storage.DefaultLocationID = AppStorageIDExternal
				} else {
					cfg.Storage.DefaultLocationID = normalizedDefaultLocationID(cfg.Storage)
				}
			}
			if err := m.writeStorageConfig(&cfg); err != nil {
				m.mutation.Unlock()
				return AppStorageSnapshot{}, err
			}

		default:
			m.mutation.Unlock()
			return AppStorageSnapshot{}, fmt.Errorf("%w: 存储类型必须为 internal（内置盘）或 external（其他盘）", ErrInvalid)
		}

	default:
		m.mutation.Unlock()
		return AppStorageSnapshot{}, fmt.Errorf("%w: 不支持的存储操作: %s", ErrInvalid, req.Action)
	}
	m.mutation.Unlock()

	for _, inst := range toStop {
		_ = inst.Stop(false)
	}
	if err := m.Reload(); err != nil {
		return AppStorageSnapshot{}, err
	}
	snapshot = m.GetStorageSnapshot()
	return snapshot, nil
}

func (m *Manager) writeStorageConfig(cfg *AppsSystemConfig) error {
	cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if cfg.Storage != nil {
		cfg.Storage.DefaultLocationID = normalizedDefaultLocationID(cfg.Storage)
	}
	if err := writeSystemConfigFile(m.configPath, *cfg); err != nil {
		return fmt.Errorf("%w: 保存应用存储配置失败: %v", ErrInvalid, err)
	}
	return nil
}

func (m *Manager) detachRunningByLocation(locationID string) []*Instance {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var list []*Instance
	for _, rec := range m.apps {
		if rec.locationID == locationID && rec.instance != nil && rec.instance.IsRunning() {
			list = append(list, rec.instance)
		}
	}
	return list
}

func (m *Manager) verifyRecordStorageOnline(locationID, pluginDir string) error {
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%w: 读取应用存储配置失败: %v", ErrInvalid, err)
	}
	return m.verifyRecordStorageOnlineWithConfig(cfg, locationID, pluginDir)
}

func (m *Manager) verifyRecordStorageOnlineWithConfig(cfg AppsSystemConfig, locationID, pluginDir string) error {
	if locationID == AppStorageIDExternal {
		if cfg.Storage == nil || cfg.Storage.External == nil || strings.TrimSpace(cfg.Storage.External.Path) == "" {
			return fmt.Errorf("%w: 其他盘应用存储位置尚未登记或已移除，原盘数据未受影响", ErrStorageOffline)
		}
		ext := *cfg.Storage.External
		name := fallbackString(ext.Name, defaultExternalStorageName)
		if ext.Binding != nil {
			if err := m.getStorageProvider().Verify(context.Background(), *ext.Binding); err != nil {
				return fmt.Errorf("%w: %s", ErrStorageOffline, describeStorageVerifyError(err, name))
			}
		}
		cleanPath := filepath.Clean(ext.Path)
		if info, err := os.Stat(cleanPath); err != nil || !info.IsDir() {
			return fmt.Errorf("%w: 其他盘「%s」当前处于离线状态或目录不存在，原盘数据未受影响；请检查硬盘连接后重试", ErrStorageOffline, name)
		}
		return nil
	}
	if cfg.Storage != nil && cfg.Storage.Internal != nil && strings.TrimSpace(cfg.Storage.Internal.Path) != "" {
		customClean := filepath.Clean(cfg.Storage.Internal.Path)
		if pluginDir == "" || filepath.Clean(pluginDir) == customClean ||
			strings.HasPrefix(filepath.Clean(pluginDir), customClean+string(filepath.Separator)) {
			name := fallbackString(cfg.Storage.Internal.Name, defaultInternalStorageName)
			if cfg.Storage.Internal.Binding != nil {
				if err := m.getStorageProvider().Verify(context.Background(), *cfg.Storage.Internal.Binding); err != nil {
					return fmt.Errorf("%w: %s", ErrStorageOffline, describeStorageVerifyError(err, name))
				}
			}
			if info, err := os.Stat(customClean); err != nil || !info.IsDir() {
				return fmt.Errorf("%w: 内置盘应用目录「%s」当前不可达，请检查目录是否存在及访问权限", ErrStorageOffline, name)
			}
		}
	}
	return nil
}

// ProtectedHostDirs returns host directories containing plugin secrets (env.json)
// and private plugin data across both internal and external app storage slots.
func (m *Manager) ProtectedHostDirs() []string {
	if m == nil {
		return nil
	}
	var dirs []string
	addDir := func(raw string) {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			return
		}
		clean := filepath.Clean(trimmed)
		if clean == "." || clean == "/" {
			return
		}
		if !slices.Contains(dirs, clean) {
			dirs = append(dirs, clean)
		}
	}
	addDir(m.dataDir)
	cfg, err := readSystemConfigFile(m.configPath)
	if err == nil && cfg.Storage != nil {
		if cfg.Storage.Internal != nil {
			addDir(cfg.Storage.Internal.Path)
		}
		if cfg.Storage.External != nil {
			addDir(cfg.Storage.External.Path)
		}
	}
	return dirs
}

// ProtectedVolumeUUIDs returns physical volume UUIDs bound to external app storage.
func (m *Manager) ProtectedVolumeUUIDs() []string {
	if m == nil {
		return nil
	}
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil || cfg.Storage == nil || cfg.Storage.External == nil || cfg.Storage.External.Binding == nil {
		return nil
	}
	uuid := strings.TrimSpace(cfg.Storage.External.Binding.VolumeUUID)
	if uuid == "" {
		return nil
	}
	return []string{uuid}
}
