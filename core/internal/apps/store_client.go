package apps

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	storeCacheFilename = "apps-store-cache.json"
	storeIconsDirname  = "apps-store-icons"
	storeFetchTimeout  = 20 * time.Second
	storeMaxRedirects  = 5
)

var hexSHA256Pattern = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

type storeCacheFile struct {
	RegistryURL  string                `json:"registryUrl"`
	EffectiveURL string                `json:"effectiveUrl"`
	FetchedAt    string                `json:"fetchedAt"`
	Document     StoreRegistryDocument `json:"document"`
}

func (m *Manager) storeCachePath() string {
	return filepath.Join(m.dataDir, storeCacheFilename)
}

func (m *Manager) storeIconsDir() string {
	return filepath.Join(m.dataDir, storeIconsDirname)
}

// SetStoreTestConfigForTesting configures an HTTP test server registry URL and enables loopback fetches in tests.
func (m *Manager) SetStoreTestConfigForTesting(registryURL string, treatAsOfficial ...bool) {
	m.storeMu.Lock()
	m.allowStoreLoopbackForTest = true
	m.storeTreatOfficialForTest = len(treatAsOfficial) > 0 && treatAsOfficial[0]
	m.storeCache = nil
	m.storeMu.Unlock()

	m.mutation.Lock()
	cfg, err := readSystemConfigFile(m.configPath)
	if err == nil {
		cfg.Store = &AppStoreConfig{
			RegistryURL: strings.TrimSpace(registryURL),
			UpdatedAt:   time.Now().UTC().Format(time.RFC3339),
		}
		cfg.UpdatedAt = cfg.Store.UpdatedAt
		_ = writeSystemConfigFile(m.configPath, cfg)
	}
	m.mutation.Unlock()
	_ = os.Remove(m.storeCachePath())
}

func (m *Manager) readStoreConfig() (registryURL, mirrorPrefix string, isOfficial bool) {
	cfg, err := readSystemConfigFile(m.configPath)
	if err == nil && cfg.Store != nil {
		registryURL = strings.TrimSpace(cfg.Store.RegistryURL)
		mirrorPrefix = strings.TrimSpace(cfg.Store.MirrorPrefix)
	}
	if registryURL == "" {
		registryURL = DefaultOfficialStoreURL
	}
	m.storeMu.Lock()
	treatOfficial := m.storeTreatOfficialForTest
	m.storeMu.Unlock()
	isOfficial = treatOfficial || strings.EqualFold(registryURL, DefaultOfficialStoreURL)
	return registryURL, mirrorPrefix, isOfficial
}

func ValidateStoreRegistryURL(raw string, allowLoopback bool) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil
	}
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("%w: 商店索引地址格式无效", ErrStoreInvalidConfig)
	}
	if u.User != nil {
		return "", fmt.Errorf("%w: 商店索引地址不能包含明文账号密码", ErrStoreInvalidConfig)
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())
	isLoopbackHost := isLoopbackHostname(host)
	if scheme != "https" {
		if !(allowLoopback && scheme == "http" && isLoopbackHost) {
			return "", fmt.Errorf("%w: 商店索引地址必须使用 HTTPS 协议", ErrStoreInvalidConfig)
		}
	}
	if isLoopbackHost && !allowLoopback {
		return "", fmt.Errorf("%w: 不允许将本机回环地址作为在线商店源", ErrStoreInvalidConfig)
	}
	if isBlockedStoreHost(host) {
		return "", fmt.Errorf("%w: 不允许访问保留或元数据地址", ErrStoreInvalidConfig)
	}
	return u.String(), nil
}

func ValidateStoreMirrorPrefix(raw string, allowLoopback bool) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil
	}
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("%w: 镜像前缀格式无效，请输入完整的 https:// 地址", ErrStoreInvalidConfig)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("%w: 镜像前缀不能包含账号信息、查询参数或锚点", ErrStoreInvalidConfig)
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())
	if scheme != "https" && !(allowLoopback && scheme == "http" && isLoopbackHostname(host)) {
		return "", fmt.Errorf("%w: 镜像前缀必须使用 HTTPS 协议", ErrStoreInvalidConfig)
	}
	if isLoopbackHostname(host) && !allowLoopback {
		return "", fmt.Errorf("%w: 不允许将本机回环地址作为镜像前缀", ErrStoreInvalidConfig)
	}
	if isBlockedStoreHost(host) {
		return "", fmt.Errorf("%w: 镜像地址不允许指向保留或元数据网段", ErrStoreInvalidConfig)
	}
	return strings.TrimRight(u.String(), "/") + "/", nil
}

func isLoopbackHostname(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap().IsLoopback()
	}
	return false
}

func isBlockedStoreHost(host string) bool {
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return isBlockedStoreIP(ip)
}

func isBlockedStoreIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	return ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast()
}

func isGitHubAssetHost(host string) bool {
	switch strings.ToLower(host) {
	case "raw.githubusercontent.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com":
		return true
	default:
		return false
	}
}

// ApplyStoreMirror rewrites GitHub raw/release URLs through the configured HTTPS mirror prefix.
func ApplyStoreMirror(targetURL, mirrorPrefix string) string {
	mirrorPrefix = strings.TrimSpace(mirrorPrefix)
	if mirrorPrefix == "" {
		return targetURL
	}
	prefix := strings.TrimRight(mirrorPrefix, "/") + "/"
	if strings.HasPrefix(targetURL, prefix) {
		return targetURL
	}
	u, err := url.Parse(targetURL)
	if err != nil || !isGitHubAssetHost(u.Hostname()) {
		return targetURL
	}
	return prefix + targetURL
}

// ResolveStoreAssetURL resolves a relative asset path from registry.json against the registry base URL.
func ResolveStoreAssetURL(registryURL, assetPath string, allowLoopback bool) (string, error) {
	assetPath = strings.TrimSpace(assetPath)
	if assetPath == "" {
		return "", fmt.Errorf("%w: 商店条目缺少资源路径", ErrStoreUnavailable)
	}
	base, err := url.Parse(registryURL)
	if err != nil || base.Host == "" {
		return "", fmt.Errorf("%w: 商店基础地址无效", ErrStoreInvalidConfig)
	}
	ref, err := url.Parse(assetPath)
	if err != nil {
		return "", fmt.Errorf("%w: 插件资源路径格式无效", ErrStoreUnavailable)
	}
	if ref.IsAbs() {
		return ValidateStoreRegistryURL(ref.String(), allowLoopback)
	}
	cleaned := path.Clean("/" + strings.ReplaceAll(assetPath, "\\", "/"))
	if strings.Contains(cleaned, "..") {
		return "", fmt.Errorf("%w: 插件资源路径包含非法目录穿越", ErrStoreUnavailable)
	}
	resolved := base.ResolveReference(&url.URL{Path: strings.TrimPrefix(cleaned, "/")})
	return ValidateStoreRegistryURL(resolved.String(), allowLoopback)
}

func (m *Manager) getStoreHTTPClient(timeout time.Duration) *http.Client {
	m.storeMu.Lock()
	allowLoopback := m.allowStoreLoopbackForTest
	m.storeMu.Unlock()

	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          8,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
			if err != nil || len(ips) == 0 {
				return nil, fmt.Errorf("无法解析商店主机地址 %s", host)
			}
			var allowed []netip.Addr
			for _, ip := range ips {
				ip = ip.Unmap()
				if isBlockedStoreIP(ip) {
					continue
				}
				if ip.IsLoopback() && !allowLoopback {
					continue
				}
				allowed = append(allowed, ip)
			}
			if len(allowed) == 0 {
				return nil, fmt.Errorf("已拦截指向受限地址的商店请求 (%s)", host)
			}
			var lastErr error
			for _, ip := range allowed {
				conn, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
				if dialErr == nil {
					return conn, nil
				}
				lastErr = dialErr
			}
			return nil, lastErr
		},
	}

	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= storeMaxRedirects {
				return errors.New("商店跳转次数过多")
			}
			if _, err := ValidateStoreRegistryURL(req.URL.String(), allowLoopback); err != nil {
				return err
			}
			return nil
		},
	}
}

func (m *Manager) loadStoreCacheLocked(expectedRegistryURL string) *storeCacheFile {
	if m.storeCache != nil && strings.EqualFold(m.storeCache.RegistryURL, expectedRegistryURL) {
		return m.storeCache
	}
	raw, err := os.ReadFile(m.storeCachePath())
	if err != nil {
		return nil
	}
	var cached storeCacheFile
	if err := json.Unmarshal(raw, &cached); err != nil {
		return nil
	}
	if !strings.EqualFold(cached.RegistryURL, expectedRegistryURL) {
		return nil
	}
	m.storeCache = &cached
	return m.storeCache
}

func (m *Manager) saveStoreCacheLocked(cache *storeCacheFile) error {
	m.storeCache = cache
	raw, err := json.MarshalIndent(cache, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(m.dataDir, 0700); err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d.tmp", m.storeCachePath(), time.Now().UnixNano())
	if err := os.WriteFile(tmp, raw, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, m.storeCachePath()); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func (m *Manager) buildStoreSnapshot(cache *storeCacheFile, source, errMsg string) AppStoreSnapshot {
	registryURL, mirrorPrefix, isOfficial := m.readStoreConfig()
	effectiveURL := ApplyStoreMirror(registryURL, mirrorPrefix)

	snap := AppStoreSnapshot{
		StoreName:     DefaultOfficialStoreName,
		RepositoryURL: DefaultOfficialStoreRepo,
		RegistryURL:   registryURL,
		EffectiveURL:  effectiveURL,
		DefaultURL:    DefaultOfficialStoreURL,
		MirrorPrefix:  mirrorPrefix,
		IsOfficial:    isOfficial,
		Source:        source,
		Error:         errMsg,
		Plugins:       []StorePluginView{},
	}
	if !isOfficial {
		snap.StoreName = "自定义 Git 插件商店"
		snap.RepositoryURL = ""
	}
	if cache == nil {
		return snap
	}
	if name := strings.TrimSpace(cache.Document.StoreName); name != "" {
		snap.StoreName = name
	}
	if repo := strings.TrimSpace(cache.Document.Repository); repo != "" {
		snap.RepositoryURL = repo
	}
	snap.FetchedAt = cache.FetchedAt
	snap.UpdatedAt = cache.Document.UpdatedAt

	m.mu.RLock()
	installedMap := make(map[string]struct {
		version    string
		locationID string
	}, len(m.apps))
	for id, rec := range m.apps {
		installedMap[id] = struct {
			version    string
			locationID string
		}{version: rec.manifest.Version, locationID: rec.locationID}
	}
	m.mu.RUnlock()

	views := make([]StorePluginView, 0, len(cache.Document.Plugins))
	for _, entry := range cache.Document.Plugins {
		inst, installed := installedMap[entry.ID]
		mode := strings.TrimSpace(entry.Mode)
		if mode == "" {
			mode = WebModeStatic
		}
		category := strings.TrimSpace(entry.Category)
		if category == "" {
			category = "utility"
		}
		iconURL := ""
		if strings.TrimSpace(entry.IconPath) != "" {
			iconURL = "/api/v2/apps/store/" + url.PathEscape(entry.ID) + "/icon"
		}
		updateAvail := installed && CompareSemver(entry.Version, inst.version) > 0
		views = append(views, StorePluginView{
			ID:               entry.ID,
			Name:             entry.Name,
			Version:          entry.Version,
			Author:           entry.Author,
			Category:         category,
			Mode:             mode,
			DefaultScope:     entry.DefaultScope,
			Description:      entry.Description,
			Tags:             entry.Tags,
			IconURL:          iconURL,
			SizeBytes:        entry.SizeBytes,
			SHA256:           strings.ToLower(strings.TrimSpace(entry.SHA256)),
			Installed:        installed,
			InstalledVersion: inst.version,
			UpdateAvailable:  updateAvail,
			LocationID:       inst.locationID,
		})
	}
	snap.Plugins = views
	return snap
}

// GetStoreSnapshot returns the current cached online store catalog overlaid with live installed state.
func (m *Manager) GetStoreSnapshot() AppStoreSnapshot {
	registryURL, _, _ := m.readStoreConfig()
	m.storeMu.Lock()
	cache := m.loadStoreCacheLocked(registryURL)
	m.storeMu.Unlock()
	if cache == nil {
		return m.buildStoreSnapshot(nil, "empty", "")
	}
	return m.buildStoreSnapshot(cache, "cache", "")
}

// ListTemplates projects the cached online store catalog for legacy clients expecting /api/v2/apps/templates.
func (m *Manager) ListTemplates() []OfficialAppTemplate {
	snap := m.GetStoreSnapshot()
	out := make([]OfficialAppTemplate, 0, len(snap.Plugins))
	for _, p := range snap.Plugins {
		out = append(out, OfficialAppTemplate{
			ID:           p.ID,
			Name:         p.Name,
			Version:      p.Version,
			Category:     p.Category,
			Description:  p.Description,
			DefaultScope: p.DefaultScope,
			Installed:    p.Installed,
		})
	}
	return out
}

func validateStoreRegistryDocument(doc *StoreRegistryDocument) error {
	if doc.SchemaVersion != StoreSchemaVersion {
		return fmt.Errorf("%w: 不支持的商店清单版本 %d", ErrStoreUnavailable, doc.SchemaVersion)
	}
	seen := make(map[string]bool, len(doc.Plugins))
	valid := make([]StorePluginEntry, 0, len(doc.Plugins))
	for _, item := range doc.Plugins {
		id := strings.TrimSpace(item.ID)
		if !ValidPluginID(id) || seen[id] {
			continue
		}
		if strings.TrimSpace(item.Name) == "" || strings.TrimSpace(item.Version) == "" {
			continue
		}
		if strings.TrimSpace(item.PackagePath) == "" || !hexSHA256Pattern.MatchString(strings.TrimSpace(item.SHA256)) {
			continue
		}
		seen[id] = true
		item.ID = id
		item.SHA256 = strings.ToLower(strings.TrimSpace(item.SHA256))
		valid = append(valid, item)
	}
	doc.Plugins = valid
	return nil
}

// RefreshStore fetches the latest registry.json from the configured Git store URL and updates the local disk cache.
func (m *Manager) RefreshStore(ctx context.Context) (AppStoreSnapshot, error) {
	registryURL, mirrorPrefix, _ := m.readStoreConfig()
	m.storeMu.Lock()
	allowLoopback := m.allowStoreLoopbackForTest
	prevCache := m.loadStoreCacheLocked(registryURL)
	m.storeMu.Unlock()

	if _, err := ValidateStoreRegistryURL(registryURL, allowLoopback); err != nil {
		return m.buildStoreSnapshot(prevCache, "unavailable", err.Error()), err
	}
	effectiveURL := ApplyStoreMirror(registryURL, mirrorPrefix)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, effectiveURL, nil)
	if err != nil {
		return m.buildStoreSnapshot(prevCache, "unavailable", "商店请求地址构造失败"), fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	req.Header.Set("User-Agent", "LightIsle-Store/1.0")
	req.Header.Set("Accept", "application/json")

	resp, err := m.getStoreHTTPClient(storeFetchTimeout).Do(req)
	if err != nil {
		msg := "无法连接在线插件商店，请检查网络或配置镜像前缀后重试"
		return m.buildStoreSnapshot(prevCache, "unavailable", msg), fmt.Errorf("%w: %s (%v)", ErrStoreUnavailable, msg, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg := fmt.Sprintf("在线插件商店返回 HTTP %d，请检查仓库地址或分支路径", resp.StatusCode)
		return m.buildStoreSnapshot(prevCache, "unavailable", msg), fmt.Errorf("%w: %s", ErrStoreUnavailable, msg)
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxStoreRegistryBytes+1))
	if err != nil || int64(len(raw)) > maxStoreRegistryBytes {
		msg := "商店清单读取失败或超过 2 MiB 大小限制"
		return m.buildStoreSnapshot(prevCache, "unavailable", msg), fmt.Errorf("%w: %s", ErrStoreUnavailable, msg)
	}
	var doc StoreRegistryDocument
	if err := json.Unmarshal(raw, &doc); err != nil {
		msg := "商店 registry.json 格式无效"
		return m.buildStoreSnapshot(prevCache, "unavailable", msg), fmt.Errorf("%w: %s", ErrStoreUnavailable, msg)
	}
	if err := validateStoreRegistryDocument(&doc); err != nil {
		return m.buildStoreSnapshot(prevCache, "unavailable", err.Error()), err
	}

	nextCache := &storeCacheFile{
		RegistryURL:  registryURL,
		EffectiveURL: effectiveURL,
		FetchedAt:    time.Now().UTC().Format(time.RFC3339),
		Document:     doc,
	}
	m.storeMu.Lock()
	_ = m.saveStoreCacheLocked(nextCache)
	m.storeMu.Unlock()
	return m.buildStoreSnapshot(nextCache, "remote", ""), nil
}

// UpdateStoreConfig updates the persisted Git store URL / mirror prefix and refreshes the catalog.
func (m *Manager) UpdateStoreConfig(ctx context.Context, req AppStoreConfigRequest) (AppStoreSnapshot, error) {
	m.storeMu.Lock()
	allowLoopback := m.allowStoreLoopbackForTest
	m.storeMu.Unlock()

	nextRegistry := ""
	nextMirror := ""
	if !req.ResetDefault {
		var err error
		nextRegistry, err = ValidateStoreRegistryURL(req.RegistryURL, allowLoopback)
		if err != nil {
			return m.GetStoreSnapshot(), err
		}
		if strings.EqualFold(nextRegistry, DefaultOfficialStoreURL) {
			nextRegistry = ""
		}
		nextMirror, err = ValidateStoreMirrorPrefix(req.MirrorPrefix, allowLoopback)
		if err != nil {
			return m.GetStoreSnapshot(), err
		}
	}

	m.mutation.Lock()
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		m.mutation.Unlock()
		return m.GetStoreSnapshot(), err
	}
	prevRegistry := ""
	if cfg.Store != nil {
		prevRegistry = cfg.Store.RegistryURL
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if nextRegistry == "" && nextMirror == "" {
		cfg.Store = nil
	} else {
		cfg.Store = &AppStoreConfig{
			RegistryURL:  nextRegistry,
			MirrorPrefix: nextMirror,
			UpdatedAt:    now,
		}
	}
	cfg.UpdatedAt = now
	writeErr := writeSystemConfigFile(m.configPath, cfg)
	m.mutation.Unlock()
	if writeErr != nil {
		return m.GetStoreSnapshot(), writeErr
	}

	if !strings.EqualFold(prevRegistry, nextRegistry) {
		m.storeMu.Lock()
		m.storeCache = nil
		_ = os.Remove(m.storeCachePath())
		_ = os.RemoveAll(m.storeIconsDir())
		m.storeMu.Unlock()
	}

	snap, refreshErr := m.RefreshStore(ctx)
	return snap, refreshErr
}

// ServeStoreIcon serves a safely cached store plugin icon fetched via the active Git store/mirror.
func (m *Manager) ServeStoreIcon(w http.ResponseWriter, r *http.Request, pluginID string) {
	if !ValidPluginID(pluginID) {
		http.NotFound(w, r)
		return
	}
	registryURL, mirrorPrefix, _ := m.readStoreConfig()
	m.storeMu.Lock()
	allowLoopback := m.allowStoreLoopbackForTest
	cache := m.loadStoreCacheLocked(registryURL)
	m.storeMu.Unlock()

	if cache == nil {
		http.NotFound(w, r)
		return
	}
	var iconPath string
	for _, entry := range cache.Document.Plugins {
		if entry.ID == pluginID {
			iconPath = strings.TrimSpace(entry.IconPath)
			break
		}
	}
	if iconPath == "" {
		http.NotFound(w, r)
		return
	}
	ext := strings.ToLower(path.Ext(iconPath))
	contentType := ""
	switch ext {
	case ".svg":
		contentType = "image/svg+xml"
	case ".png":
		contentType = "image/png"
	default:
		http.NotFound(w, r)
		return
	}

	iconCachePath := filepath.Join(m.storeIconsDir(), pluginID+ext)
	data, err := os.ReadFile(iconCachePath)
	if err != nil || len(data) == 0 {
		rawURL, resolveErr := ResolveStoreAssetURL(registryURL, iconPath, allowLoopback)
		if resolveErr != nil {
			http.NotFound(w, r)
			return
		}
		fetchURL := ApplyStoreMirror(rawURL, mirrorPrefix)
		req, reqErr := http.NewRequestWithContext(r.Context(), http.MethodGet, fetchURL, nil)
		if reqErr != nil {
			http.NotFound(w, r)
			return
		}
		req.Header.Set("User-Agent", "LightIsle-Store/1.0")
		resp, doErr := m.getStoreHTTPClient(10 * time.Second).Do(req)
		if doErr != nil || resp == nil {
			http.NotFound(w, r)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			http.NotFound(w, r)
			return
		}
		data, err = io.ReadAll(io.LimitReader(resp.Body, maxStoreIconBytes+1))
		if err != nil || len(data) == 0 || int64(len(data)) > maxStoreIconBytes {
			http.NotFound(w, r)
			return
		}
		_ = os.MkdirAll(m.storeIconsDir(), 0700)
		_ = os.WriteFile(iconCachePath, data, 0600)
	}

	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
