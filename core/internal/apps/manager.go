package apps

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

type appRecord struct {
	id, pluginDir, dataDir, revision, validationError string
	manifest                                          PluginManifest
	valid, pendingActivation, hasIcon                 bool
	instance                                          *Instance
}

type ticketRecord struct {
	AppID     string
	User      UserIdentity
	ExpiresAt time.Time
}

type Manager struct {
	dataDir, pluginsDir, pluginDataRoot, configPath, reloadTokenPath, execPath string
	automation                                                                 *automation.Manager
	channelsFn                                                                 func() []string
	verifyUser                                                                 func(UserIdentity) (UserIdentity, bool)
	mu, mutation                                                               sync.Mutex
	apps                                                                       map[string]*appRecord
	tickets                                                                    map[string]ticketRecord
	sessionGrants                                                              map[string]string
	cookieSecret                                                               []byte
	reapInterval                                                               time.Duration
	stopCh                                                                     chan struct{}
	wg                                                                         sync.WaitGroup
	closed                                                                     bool
}

func NewManager(dataDir, execPath string, autoMgr *automation.Manager) *Manager {
	pluginsDir := filepath.Join(dataDir, "plugins")
	pluginDataRoot := filepath.Join(dataDir, "plugin-data")
	_ = os.MkdirAll(pluginsDir, 0700)
	_ = os.MkdirAll(pluginDataRoot, 0700)
	ensureBuiltInDemoApp(pluginsDir)

	secret := make([]byte, 32)
	_, _ = rand.Read(secret)

	m := &Manager{
		dataDir:         dataDir,
		pluginsDir:      pluginsDir,
		pluginDataRoot:  pluginDataRoot,
		configPath:      filepath.Join(dataDir, "apps-config.json"),
		reloadTokenPath: filepath.Join(dataDir, ".mcp-reload-token"),
		execPath:        execPath,
		automation:      autoMgr,
		apps:            make(map[string]*appRecord),
		tickets:         make(map[string]ticketRecord),
		sessionGrants:   make(map[string]string),
		cookieSecret:    secret,
		reapInterval:    5 * time.Second,
		stopCh:          make(chan struct{}),
	}
	// Sync reload token state with persisted apps-config.json on startup
	_ = m.GetSystemConfig()
	m.wg.Add(1)
	go m.reapLoop()
	return m
}

func (m *Manager) PluginsDir() string     { return m.pluginsDir }
func (m *Manager) PluginDataRoot() string { return m.pluginDataRoot }

func (m *Manager) MCPCommand() string {
	bin := m.execPath
	if bin == "" {
		bin = "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
	}
	return fmt.Sprintf("%s mcp --data-dir %q", bin, m.dataDir)
}

func (m *Manager) MCPBootstrapPrompt() string {
	bin := m.execPath
	if bin == "" {
		bin = "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
	}
	return fmt.Sprintf("请帮我将当前 Mac 上的「LightIsle（轻屿）开发者 MCP Server」安装并注册到你的 MCP 配置文件中：\n\n- MCP 服务名称：lightisle-dev\n- 传输方式：stdio\n- 可执行命令：%s\n- 命令参数：[\"mcp\", \"--data-dir\", %q]\n\n操作要求：\n1. 请自动检测你当前所处的 Agent 环境（如 Claude Code、Codex、Cursor 或 Antigravity MCP 配置），写入上述 lightisle-dev MCP 配置；\n2. 配置完成后，请立即调用 lightisle_get_environment 工具和读取 lightisle://specs/plugin-v2 资源，验证连接是否成功；\n3. 今后当我让你为 LightIsle 开发或改造“应用 / 插件 / 定时脚本”时，请始终优先通过该 MCP 读取规范、创建脚手架并触发热重载。", bin, m.dataDir)
}

func (m *Manager) SetConfiguredChannels(fn func() []string) {
	m.mu.Lock()
	m.channelsFn = fn
	m.mu.Unlock()
}

func (m *Manager) SetUserVerifier(fn func(UserIdentity) (UserIdentity, bool)) {
	m.mu.Lock()
	m.verifyUser = fn
	m.mu.Unlock()
}

func (m *Manager) ConfiguredChannels() []string {
	m.mu.Lock()
	fn := m.channelsFn
	m.mu.Unlock()
	if fn != nil {
		if ch := fn(); ch != nil {
			return ch
		}
	}
	return []string{}
}

func (m *Manager) SetReapInterval(d time.Duration) {
	if d > 0 {
		m.mu.Lock()
		m.reapInterval = d
		m.mu.Unlock()
	}
}

func (m *Manager) reapLoop() {
	defer m.wg.Done()
	for {
		m.mu.Lock()
		interval := m.reapInterval
		m.mu.Unlock()
		if interval <= 0 {
			interval = 5 * time.Second
		}
		select {
		case <-m.stopCh:
			return
		case now := <-time.After(interval):
			m.reapOnce(now)
		}
	}
}

func (m *Manager) reapOnce(now time.Time) {
	m.mu.Lock()
	instances := make([]*Instance, 0, len(m.apps))
	for _, rec := range m.apps {
		if rec.instance != nil {
			instances = append(instances, rec.instance)
		}
	}
	for k, t := range m.tickets {
		if now.After(t.ExpiresAt) {
			delete(m.tickets, k)
		}
	}
	m.mu.Unlock()
	for _, inst := range instances {
		inst.ReapIfIdle(now)
	}
}

func (m *Manager) Close() error {
	m.mutation.Lock()
	defer m.mutation.Unlock()
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil
	}
	m.closed = true
	close(m.stopCh)
	instances := make([]*Instance, 0, len(m.apps))
	for _, rec := range m.apps {
		if rec.instance != nil {
			instances = append(instances, rec.instance)
		}
	}
	m.mu.Unlock()
	for _, inst := range instances {
		inst.Close()
	}
	m.wg.Wait()
	return nil
}

func (m *Manager) GetSystemConfig() AppsSystemConfig {
	cfg := readSystemConfigFile(m.configPath)
	if cfg.MCPEnabled {
		_ = ensureReloadTokenFile(m.reloadTokenPath)
	}
	return cfg
}

func (m *Manager) MCPEnabled() bool { return m.GetSystemConfig().MCPEnabled }

func (m *Manager) SetMCPEnabled(enabled bool) error {
	m.mutation.Lock()
	defer m.mutation.Unlock()
	cfg := readSystemConfigFile(m.configPath)
	cfg.MCPEnabled = enabled
	cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := writeSystemConfigFile(m.configPath, cfg); err != nil {
		return err
	}
	if enabled {
		return ensureReloadTokenFile(m.reloadTokenPath)
	}
	_ = os.Remove(m.reloadTokenPath)
	return nil
}

// ActivateApp explicitly marks a plugin as administrator-approved, clearing
// PendingActivation in memory and persisting the approval to apps-config.json.
func (m *Manager) ActivateApp(appID string) {
	m.activateApp(appID)
}

func (m *Manager) activateApp(appID string) {
	if !ValidPluginID(appID) {
		return
	}
	m.mutation.Lock()
	defer m.mutation.Unlock()

	cfg := readSystemConfigFile(m.configPath)
	if slices.Contains(cfg.PendingApps, appID) || !slices.Contains(cfg.ActivatedApps, appID) {
		cfg.PendingApps = slices.DeleteFunc(cfg.PendingApps, func(s string) bool { return s == appID })
		cfg.ActivatedApps = uniqueSortedStrings(append(cfg.ActivatedApps, appID))
		_ = writeSystemConfigFile(m.configPath, cfg)
	}

	m.mu.Lock()
	rec, ok := m.apps[appID]
	hadPending := ok && rec.pendingActivation
	if hadPending {
		rec.pendingActivation = false
	}
	m.mu.Unlock()

	if hadPending && m.automation != nil {
		m.syncAllCronTasks()
	}
}

func toCronReg(id, pluginDir, dataDir string, manifest PluginManifest, pending bool) automation.PluginCronRegistration {
	return automation.PluginCronRegistration{
		PluginID:  id,
		PluginDir: pluginDir,
		DataDir:   dataDir,
		Spec: automation.TaskSpec{
			SchemaVersion:  1,
			ID:             "app-" + id,
			Name:           manifest.Name,
			Description:    manifest.Description,
			Enabled:        manifest.Cron.Enabled && !pending,
			Entry:          manifest.Cron.Entry,
			Schedule:       manifest.Cron.Schedule,
			TimeoutSeconds: manifest.Cron.TimeoutSeconds,
			Notification:   manifest.Cron.Notification,
		},
	}
}

func (m *Manager) syncAllCronTasks() {
	if m.automation == nil {
		return
	}
	m.mu.Lock()
	cronRegs := make([]automation.PluginCronRegistration, 0, len(m.apps))
	for _, rec := range m.apps {
		if rec.valid && rec.manifest.Cron != nil {
			cronRegs = append(cronRegs, toCronReg(rec.id, rec.pluginDir, rec.dataDir, rec.manifest, rec.pendingActivation))
		}
	}
	m.mu.Unlock()
	_ = m.automation.SyncPluginTasks(cronRegs)
}

func (m *Manager) VerifyReloadToken(token string) bool {
	token = strings.TrimSpace(token)
	if token == "" || !m.MCPEnabled() {
		return false
	}
	raw, err := os.ReadFile(m.reloadTokenPath)
	if err != nil {
		return false
	}
	expected := strings.TrimSpace(string(raw))
	if expected == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1
}

func (m *Manager) Reload() error {
	return m.reloadInternal(false)
}

// ReloadFromMCP reloads the plugin inventory when triggered by an external AI Agent
// via MCP. Any newly discovered plugin is kept in PendingActivation state so that
// neither background Cron schedules nor persistent daemons auto-execute until the
// administrator explicitly activates, starts, or saves the plugin in the App Center.
func (m *Manager) ReloadFromMCP() error {
	return m.reloadInternal(true)
}

func (m *Manager) reloadInternal(fromMCP bool) error {
	m.mutation.Lock()
	defer m.mutation.Unlock()

	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return ErrUnavailable
	}
	prevApps := m.apps
	m.mu.Unlock()

	if err := os.MkdirAll(m.pluginsDir, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(m.pluginDataRoot, 0700); err != nil {
		return err
	}

	entries, err := os.ReadDir(m.pluginsDir)
	if err != nil {
		return err
	}

	sysCfg := readSystemConfigFile(m.configPath)
	cfgDirty := false

	nextApps := make(map[string]*appRecord, len(entries))
	cronRegs := make([]automation.PluginCronRegistration, 0)
	toStop := make([]*Instance, 0)
	toAutoStart := make([]*Instance, 0)

	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		if !ValidPluginID(name) {
			continue
		}
		pluginDir := filepath.Join(m.pluginsDir, name)
		dataDir := filepath.Join(m.pluginDataRoot, name)

		root, err := os.OpenRoot(pluginDir)
		if err != nil {
			nextApps[name] = invalidAppRecord(name, pluginDir, dataDir, "无法打开插件目录，请检查本地权限")
			continue
		}
		raw, _, readErr := readCheckedFile(root, "plugin.json", maxManifestBytes)
		if readErr != nil {
			root.Close()
			nextApps[name] = invalidAppRecord(name, pluginDir, dataDir, "无法读取 plugin.json，请检查文件是否存在且为普通文件")
			continue
		}
		manifest, valErr := ValidateManifest(root, name, raw)
		hasIcon := false
		if valErr == nil {
			if manifest.Icon == "" {
				for _, candidate := range []string{"icon.svg", "icon.png"} {
					if st, err := root.Lstat(candidate); err == nil && st.Mode().IsRegular() {
						manifest.Icon = candidate
						hasIcon = true
						break
					}
				}
			} else {
				hasIcon = true
			}
		}
		root.Close()

		rev := manifestRevision(raw)
		if valErr != nil {
			if prev, ok := prevApps[name]; ok && prev.instance != nil {
				toStop = append(toStop, prev.instance)
			}
			rec := invalidAppRecord(name, pluginDir, dataDir, valErr.Error())
			rec.revision = rev
			if manifest.Name != "" {
				rec.manifest.Name = manifest.Name
			}
			nextApps[name] = rec
			continue
		}

		var inst *Instance
		if prev, ok := prevApps[name]; ok && prev.instance != nil {
			inst = prev.instance
			inst.mu.Lock()
			oldWeb := inst.manifest.Web
			inst.manifest = manifest
			inst.mu.Unlock()
			if manifest.Web == nil || !manifest.Web.Enabled || manifest.Web.Mode == WebModeStatic ||
				(oldWeb != nil && (oldWeb.Entry != manifest.Web.Entry || oldWeb.Port != manifest.Web.Port || oldWeb.Mode != manifest.Web.Mode)) {
				toStop = append(toStop, inst)
				inst = newInstance(name, pluginDir, dataDir, manifest)
			}
		} else {
			inst = newInstance(name, pluginDir, dataDir, manifest)
		}

		prevRec, existedBefore := prevApps[name]
		isActivated := name == "network-pulse" || slices.Contains(sysCfg.ActivatedApps, name)
		isPending := slices.Contains(sysCfg.PendingApps, name) || (prevRec != nil && prevRec.pendingActivation)
		if fromMCP && !isActivated && (!existedBefore || isPending) {
			isPending = true
		}
		if isPending && !slices.Contains(sysCfg.PendingApps, name) {
			sysCfg.PendingApps = uniqueSortedStrings(append(sysCfg.PendingApps, name))
			cfgDirty = true
		} else if !isPending && !isActivated && existedBefore {
			sysCfg.ActivatedApps = uniqueSortedStrings(append(sysCfg.ActivatedApps, name))
			cfgDirty = true
		}
		pendingActivation := isPending && !isActivated

		if !pendingActivation && manifest.Web != nil && manifest.Web.Enabled && manifest.Web.Mode == WebModePersistent {
			toAutoStart = append(toAutoStart, inst)
		}

		if manifest.Cron != nil {
			cronRegs = append(cronRegs, toCronReg(name, pluginDir, dataDir, manifest, pendingActivation))
		}

		nextApps[name] = &appRecord{
			id:                name,
			pluginDir:         pluginDir,
			dataDir:           dataDir,
			manifest:          manifest,
			revision:          rev,
			valid:             true,
			pendingActivation: pendingActivation,
			hasIcon:           hasIcon,
			instance:          inst,
		}
	}

	if cfgDirty {
		_ = writeSystemConfigFile(m.configPath, sysCfg)
	}

	for id, prev := range prevApps {
		if _, kept := nextApps[id]; !kept && prev.instance != nil {
			toStop = append(toStop, prev.instance)
		}
	}

	m.mu.Lock()
	m.apps = nextApps
	m.mu.Unlock()

	for _, inst := range toStop {
		_ = inst.Stop(false)
	}
	if m.automation != nil {
		_ = m.automation.SyncPluginTasks(cronRegs)
	}
	for _, inst := range toAutoStart {
		go func(target *Instance) {
			_, _, _ = target.Wake(context.Background())
		}(inst)
	}
	return nil
}

func invalidAppRecord(id, pluginDir, dataDir, errMsg string) *appRecord {
	return &appRecord{
		id:        id,
		pluginDir: pluginDir,
		dataDir:   dataDir,
		manifest: PluginManifest{
			SchemaVersion: 2,
			ID:            id,
			Name:          id,
			Version:       "0.0.0",
			Access:        AccessConfig{Policy: AccessAdminOnly, AllowedUserIDs: []int64{}},
		},
		valid:           false,
		validationError: errMsg,
	}
}

func (m *Manager) CanAccess(appID string, userID int64, role string) bool {
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok || !rec.valid {
		return false
	}
	if rec.pendingActivation {
		return role == "admin"
	}
	if role == "admin" {
		return true
	}
	switch normalizeAccessPolicy(rec.manifest.Access.Policy) {
	case AccessAllMembers:
		return true
	case AccessSelectedMembers:
		return slices.Contains(rec.manifest.Access.AllowedUserIDs, userID)
	default:
		return false
	}
}

func (m *Manager) toPublicApp(rec *appRecord) PublicApp {
	pub := PublicApp{
		ID:                rec.id,
		Name:              rec.manifest.Name,
		Version:           rec.manifest.Version,
		Author:            rec.manifest.Author,
		Description:       rec.manifest.Description,
		Category:          rec.manifest.Category,
		HasIcon:           rec.hasIcon,
		LaunchPath:        "/apps/" + rec.id,
		Revision:          rec.revision,
		Valid:             rec.valid,
		ValidationError:   rec.validationError,
		PendingActivation: rec.pendingActivation,
		Access:            rec.manifest.Access,
		Cron:              PublicCronView{Events: []string{}, Channels: []string{}},
	}
	if pub.Access.AllowedUserIDs == nil {
		pub.Access.AllowedUserIDs = []int64{}
	}
	if rec.hasIcon {
		pub.IconURL = "/apps/" + rec.id + "/__lightisle_icon"
	}
	if rec.instance != nil {
		pub.Web = rec.instance.Snapshot()
	} else {
		pub.Web = PublicWebView{Enabled: false, Mode: "none", Status: StatusDisabled}
	}
	if rec.manifest.Cron != nil {
		c := rec.manifest.Cron
		events := c.Notification.Events
		if events == nil {
			events = []string{}
		}
		channels := c.Notification.Channels
		if channels == nil {
			channels = []string{}
		}
		taskID := "app-" + rec.id
		cronView := PublicCronView{
			HasCron:        true,
			TaskID:         taskID,
			Enabled:        c.Enabled && !rec.pendingActivation,
			Cron:           c.Schedule.Cron,
			Timezone:       c.Schedule.Timezone,
			TimeoutSeconds: c.TimeoutSeconds,
			Events:         events,
			Channels:       channels,
		}
		if m.automation != nil {
			if view, ok := m.automation.GetTaskView(taskID); ok {
				cronView.Running = view.Running
				cronView.NextRunAt = view.NextRun
				cronView.LastRun = view.LastRun
			}
		}
		pub.Cron = cronView
	}
	return pub
}

func (m *Manager) ListForUser(userID int64, role string) []PublicApp {
	m.mu.Lock()
	records := make([]*appRecord, 0, len(m.apps))
	for _, rec := range m.apps {
		records = append(records, rec)
	}
	m.mu.Unlock()
	out := make([]PublicApp, 0, len(records))
	for _, rec := range records {
		if role != "admin" && (!rec.valid || rec.manifest.Web == nil || !rec.manifest.Web.Enabled || !m.CanAccess(rec.id, userID, role)) {
			continue
		}
		out = append(out, m.toPublicApp(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (m *Manager) GetForUser(appID string, userID int64, role string) (PublicApp, error) {
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if role != "admin" && !m.CanAccess(appID, userID, role) {
		return PublicApp{}, ErrForbidden
	}
	return m.toPublicApp(rec), nil
}

func (m *Manager) WakeApp(ctx context.Context, appID string) (PublicApp, error) {
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if !rec.valid || rec.instance == nil {
		return PublicApp{}, ErrInvalid
	}
	if rec.pendingActivation {
		return m.toPublicApp(rec), ErrPendingActivation
	}
	if _, _, err := rec.instance.Wake(ctx); err != nil {
		return m.toPublicApp(rec), err
	}
	return m.toPublicApp(rec), nil
}

func (m *Manager) StopApp(appID string) (PublicApp, error) {
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if rec.instance != nil {
		_ = rec.instance.Stop(false)
	}
	return m.toPublicApp(rec), nil
}

func (m *Manager) RestartApp(ctx context.Context, appID string) (PublicApp, error) {
	m.activateApp(appID)
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if !rec.valid || rec.instance == nil {
		return PublicApp{}, ErrInvalid
	}
	if err := rec.instance.Restart(ctx); err != nil {
		return m.toPublicApp(rec), err
	}
	return m.toPublicApp(rec), nil
}

func (m *Manager) GetWebLogs(appID string) (string, error) {
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return "", ErrNotFound
	}
	if rec.instance == nil {
		return "", nil
	}
	return rec.instance.Logs(), nil
}

func (m *Manager) GetCronRuns(appID string, limit int) ([]automation.TaskRun, error) {
	m.mu.Lock()
	_, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return nil, ErrNotFound
	}
	if m.automation == nil {
		return []automation.TaskRun{}, nil
	}
	runs, err := m.automation.ListRuns("app-"+appID, limit)
	if err != nil {
		return []automation.TaskRun{}, nil
	}
	return runs, nil
}

func (m *Manager) TriggerCron(appID string) error {
	m.activateApp(appID)
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	if !rec.valid || rec.manifest.Cron == nil {
		return ErrInvalid
	}
	if m.automation == nil {
		return ErrUnavailable
	}
	return m.automation.RunNow("app-" + appID)
}

func (m *Manager) UpdateApp(appID string, req AppUpdateRequest) (PublicApp, error) {
	if !ValidPluginID(appID) {
		return PublicApp{}, ErrInvalid
	}
	err := func() error {
		m.mutation.Lock()
		defer m.mutation.Unlock()
		m.mu.Lock()
		rec, ok := m.apps[appID]
		m.mu.Unlock()
		if !ok {
			return ErrNotFound
		}
		root, err := os.OpenRoot(rec.pluginDir)
		if err != nil {
			return err
		}
		defer root.Close()
		raw, _, err := readCheckedFile(root, "plugin.json", maxManifestBytes)
		if err != nil {
			return ErrInvalid
		}
		if req.Revision != "" && manifestRevision(raw) != req.Revision {
			return ErrChanged
		}
		updatedRaw, err := patchManifestBytes(raw, req)
		if err != nil {
			return err
		}
		if _, err := ValidateManifest(root, appID, updatedRaw); err != nil {
			return ErrInvalid
		}
		tmpName := fmt.Sprintf("plugin.json.%d.tmp", time.Now().UnixNano())
		f, err := root.OpenFile(tmpName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, writeErr := f.Write(updatedRaw)
		if writeErr == nil {
			writeErr = f.Sync()
		}
		if closeErr := f.Close(); writeErr != nil || closeErr != nil {
			_ = root.Remove(tmpName)
			return ErrInvalid
		}
		if err := root.Rename(tmpName, "plugin.json"); err != nil {
			_ = root.Remove(tmpName)
			return err
		}
		return nil
	}()
	if err != nil {
		return PublicApp{}, err
	}
	m.activateApp(appID)
	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	return m.GetForUser(appID, 0, "admin")
}

func (m *Manager) DeleteApp(appID string, deleteData bool) error {
	if !ValidPluginID(appID) {
		return ErrInvalid
	}
	m.mutation.Lock()
	m.mu.Lock()
	rec, ok := m.apps[appID]
	if !ok {
		m.mu.Unlock()
		m.mutation.Unlock()
		return ErrNotFound
	}
	delete(m.apps, appID)
	m.mu.Unlock()

	if rec.instance != nil {
		rec.instance.Close()
	}
	if err := os.RemoveAll(rec.pluginDir); err != nil {
		m.mutation.Unlock()
		_ = m.Reload()
		return err
	}
	if deleteData {
		_ = os.RemoveAll(rec.dataDir)
	}
	cfg := readSystemConfigFile(m.configPath)
	cfg.PendingApps = slices.DeleteFunc(cfg.PendingApps, func(s string) bool { return s == appID })
	cfg.ActivatedApps = slices.DeleteFunc(cfg.ActivatedApps, func(s string) bool { return s == appID })
	_ = writeSystemConfigFile(m.configPath, cfg)
	m.mutation.Unlock()
	return m.Reload()
}
