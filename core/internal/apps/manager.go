package apps

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/safego"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const (
	maxAppTickets    = 1024
	maxSessionGrants = 1024
)

type appRecord struct {
	id, pluginDir, dataDir, revision, validationError string
	locationID, locationKind, locationName            string
	manifest                                          PluginManifest
	valid, pendingActivation, hasIcon                 bool
	instance                                          *Instance
}

type ticketRecord struct {
	AppID     string
	User      UserIdentity
	ExpiresAt time.Time
}

type sessionGrant struct {
	sessionToken string
	expiresAt    time.Time
}

type Manager struct {
	dataDir, pluginsDir, pluginDataRoot, configPath, reloadTokenPath, execPath string
	automation                                                                 *automation.Manager
	channelsFn                                                                 func() []string
	endpointFn                                                                 func() (string, string)
	verifyUser                                                                 func(UserIdentity) (UserIdentity, bool)
	mcpHandler                                                                 func(context.Context, string, string, []byte) ([]byte, bool)
	storageProviderFn                                                          storageidentity.Provider
	externalVolumesFn                                                          func() []ExternalVolumeInfo
	externalPrefixes                                                           []string
	reminderNotifier                                                           func(code, title, body, severity string)
	reminderReadyCheck                                                         func() bool
	reminderScanInterval                                                       time.Duration
	reminderScannerStarted                                                     bool
	reminderMu                                                                 sync.Mutex
	kvLocksMu                                                                  sync.Mutex
	kvAppLocks                                                                 map[string]*sync.Mutex
	mu                                                                         sync.RWMutex
	mutation                                                                   sync.Mutex
	apps                                                                       map[string]*appRecord
	tickets                                                                    map[string]ticketRecord
	sessionGrants                                                              map[string]sessionGrant
	cookieSecret                                                               []byte
	reapInterval                                                               time.Duration
	sandboxBridgeEnabled                                                       bool
	bridgePaths                                                                []string
	stopCh                                                                     chan struct{}
	ctx                                                                        context.Context
	cancel                                                                     context.CancelFunc
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

	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{
		dataDir:         dataDir,
		pluginsDir:      pluginsDir,
		pluginDataRoot:  pluginDataRoot,
		configPath:      filepath.Join(dataDir, "apps-config.json"),
		reloadTokenPath: filepath.Join(dataDir, ".mcp-reload-token"),
		execPath:        execPath,
		automation:      autoMgr,
		apps:                 make(map[string]*appRecord),
		tickets:              make(map[string]ticketRecord),
		sessionGrants:        make(map[string]sessionGrant),
		kvAppLocks:           make(map[string]*sync.Mutex),
		cookieSecret:         secret,
		reapInterval:         5 * time.Second,
		reminderScanInterval: defaultReminderScanInterval,
		stopCh:               make(chan struct{}),
		ctx:             ctx,
		cancel:          cancel,
	}
	if cfg, err := readSystemConfigFile(m.configPath); err == nil && cfg.MCPEnabled {
		_ = ensureReloadTokenFile(m.reloadTokenPath)
	}
	m.wg.Add(1)
	safego.Go("apps-reap-loop", m.reapLoop)
	return m
}

func (m *Manager) DataDir() string        { return m.dataDir }
func (m *Manager) PluginsDir() string     { return m.pluginsDir }
func (m *Manager) PluginDataRoot() string { return m.pluginDataRoot }
func (m *Manager) ExecPath() string       { return m.execPath }

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

func (m *Manager) SetMCPHandler(fn func(context.Context, string, string, []byte) ([]byte, bool)) {
	m.mu.Lock()
	m.mcpHandler = fn
	m.mu.Unlock()
}

func (m *Manager) ConfiguredChannels() []string {
	m.mu.RLock()
	fn := m.channelsFn
	m.mu.RUnlock()
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
		m.mu.RLock()
		interval := m.reapInterval
		m.mu.RUnlock()
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
	type runningItem struct {
		inst       *Instance
		locationID string
		pluginDir  string
	}
	m.mu.Lock()
	var instances []runningItem
	for _, rec := range m.apps {
		if rec.instance != nil && rec.instance.IsRunning() {
			instances = append(instances, runningItem{
				inst:       rec.instance,
				locationID: rec.locationID,
				pluginDir:  rec.pluginDir,
			})
		}
	}
	for k, t := range m.tickets {
		if now.After(t.ExpiresAt) {
			delete(m.tickets, k)
		}
	}
	for k, g := range m.sessionGrants {
		if now.After(g.expiresAt) {
			delete(m.sessionGrants, k)
		}
	}
	m.mu.Unlock()

	cfg, cfgErr := readSystemConfigFile(m.configPath)
	for _, item := range instances {
		if cfgErr == nil {
			if offErr := m.verifyRecordStorageOnlineWithConfig(cfg, item.locationID, item.pluginDir); offErr != nil {
				_ = item.inst.Stop(false)
				continue
			}
		}
		item.inst.ReapIfIdle(now)
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
	if m.cancel != nil {
		m.cancel()
	}
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
	m.ClearSandboxBridge()
	return nil
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
	m.mu.RLock()
	cronRegs := make([]automation.PluginCronRegistration, 0, len(m.apps))
	for _, rec := range m.apps {
		if rec.valid && rec.manifest.Cron != nil {
			cronRegs = append(cronRegs, toCronReg(rec.id, rec.pluginDir, rec.dataDir, rec.manifest, rec.pendingActivation))
		}
	}
	m.mu.RUnlock()
	if err := m.automation.SyncPluginTasks(cronRegs); err != nil {
		slog.Warn("failed to sync plugin automation tasks", "count", len(cronRegs), "error", err)
	}
}

func (m *Manager) wakeInstanceAsync(target *Instance) {
	if target == nil {
		return
	}
	m.mu.RLock()
	if m.closed {
		m.mu.RUnlock()
		return
	}
	parentCtx := m.ctx
	if parentCtx == nil {
		parentCtx = context.Background()
	}
	m.wg.Add(1)
	m.mu.RUnlock()

	safego.Go("app-auto-wake:"+target.id, func() {
		defer m.wg.Done()
		if _, _, err := target.Wake(parentCtx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Warn("persistent app auto-wake failed", "app", target.id, "error", err)
		}
	})
}

func (m *Manager) Reload() error {
	return m.reloadInternal(false)
}

// ReloadFromMCP reloads the plugin inventory when triggered by an external AI Agent
// via MCP. Any newly discovered plugin is kept in PendingActivation state until the
// administrator explicitly approves it.
func (m *Manager) ReloadFromMCP() error {
	return m.reloadInternal(true)
}

type reloadPlan struct {
	nextApps    map[string]*appRecord
	cronRegs    []automation.PluginCronRegistration
	toStop      []*Instance
	toAutoStart []*Instance
	cfgDirty    bool
}

func (m *Manager) reloadInternal(fromMCP bool) error {
	m.mutation.Lock()
	defer m.mutation.Unlock()

	m.mu.RLock()
	if m.closed {
		m.mu.RUnlock()
		return ErrUnavailable
	}
	prevApps := make(map[string]appRecord, len(m.apps))
	for id, rec := range m.apps {
		prevApps[id] = *rec
	}
	m.mu.RUnlock()

	if err := os.MkdirAll(m.pluginsDir, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(m.pluginDataRoot, 0700); err != nil {
		return err
	}

	sysCfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		return err
	}

	scanRoots := listConfiguredScanRootsWithConfig(m.dataDir, sysCfg, m.getStorageProvider(), m.getAvailableVolumes())
	plan := reloadPlan{
		nextApps: make(map[string]*appRecord, 16),
	}
	for _, scanRoot := range scanRoots {
		if err := m.scanPluginRoot(scanRoot, prevApps, &sysCfg, fromMCP, &plan); err != nil {
			return err
		}
	}

	if plan.cfgDirty {
		if err := writeSystemConfigFile(m.configPath, sysCfg); err != nil {
			return err
		}
	}

	for id, prev := range prevApps {
		if _, kept := plan.nextApps[id]; !kept && prev.instance != nil {
			plan.toStop = append(plan.toStop, prev.instance)
		}
	}

	m.mu.Lock()
	m.apps = plan.nextApps
	m.mu.Unlock()

	for _, inst := range plan.toStop {
		_ = inst.Stop(false)
	}
	if m.automation != nil {
		if err := m.automation.SyncPluginTasks(plan.cronRegs); err != nil {
			slog.Warn("failed to sync plugin automation tasks on reload", "count", len(plan.cronRegs), "error", err)
		}
	}
	for _, inst := range plan.toAutoStart {
		m.wakeInstanceAsync(inst)
	}
	return nil
}

func (m *Manager) scanPluginRoot(
	scanRoot storageScanRoot,
	prevApps map[string]appRecord,
	sysCfg *AppsSystemConfig,
	fromMCP bool,
	plan *reloadPlan,
) error {
	isInternalRoot := scanRoot.id == AppStorageIDInternal && scanRoot.path == filepath.Clean(m.dataDir)
	if err := os.MkdirAll(scanRoot.pluginsDir, 0700); err != nil {
		if isInternalRoot {
			return err
		}
		return nil
	}
	if err := os.MkdirAll(scanRoot.dataRoot, 0700); err != nil {
		if isInternalRoot {
			return err
		}
		return nil
	}
	entries, err := os.ReadDir(scanRoot.pluginsDir)
	if err != nil {
		if isInternalRoot {
			return err
		}
		return nil
	}

	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		if !ValidPluginID(name) {
			continue
		}
		if _, exists := plan.nextApps[name]; exists {
			continue
		}
		loadPluginIntoPlan(name, scanRoot, prevApps, sysCfg, fromMCP, plan)
	}
	return nil
}

func loadPluginIntoPlan(
	name string,
	scanRoot storageScanRoot,
	prevApps map[string]appRecord,
	sysCfg *AppsSystemConfig,
	fromMCP bool,
	plan *reloadPlan,
) {
	pluginDir := filepath.Join(scanRoot.pluginsDir, name)
	dataDir := filepath.Join(scanRoot.dataRoot, name)

	manifest, rev, hasIcon, readErrMsg, valErr := loadPluginManifestFromDir(name, pluginDir)
	if readErrMsg != "" {
		plan.nextApps[name] = invalidAppRecordForRoot(name, pluginDir, dataDir, readErrMsg, scanRoot)
		return
	}
	if valErr != nil {
		if prev, ok := prevApps[name]; ok && prev.instance != nil {
			plan.toStop = append(plan.toStop, prev.instance)
		}
		rec := invalidAppRecordForRoot(name, pluginDir, dataDir, valErr.Error(), scanRoot)
		rec.revision = rev
		if manifest.Name != "" {
			rec.manifest.Name = manifest.Name
		}
		plan.nextApps[name] = rec
		return
	}

	inst, stopPrev := resolvePluginInstance(name, pluginDir, dataDir, manifest, prevApps)
	if stopPrev != nil {
		plan.toStop = append(plan.toStop, stopPrev)
	}

	pendingActivation, dirty := resolvePluginActivation(name, prevApps, sysCfg, fromMCP)
	if dirty {
		plan.cfgDirty = true
	}
	if !pendingActivation && manifest.Web != nil && manifest.Web.Enabled && manifest.Web.Mode == WebModePersistent {
		plan.toAutoStart = append(plan.toAutoStart, inst)
	}
	if manifest.Cron != nil {
		plan.cronRegs = append(plan.cronRegs, toCronReg(name, pluginDir, dataDir, manifest, pendingActivation))
	}

	plan.nextApps[name] = &appRecord{
		id:                name,
		pluginDir:         pluginDir,
		dataDir:           dataDir,
		locationID:        scanRoot.id,
		locationKind:      scanRoot.kind,
		locationName:      scanRoot.name,
		manifest:          manifest,
		revision:          rev,
		valid:             true,
		pendingActivation: pendingActivation,
		hasIcon:           hasIcon,
		instance:          inst,
	}
}

func loadPluginManifestFromDir(name, pluginDir string) (PluginManifest, string, bool, string, error) {
	root, err := os.OpenRoot(pluginDir)
	if err != nil {
		return PluginManifest{}, "", false, "无法打开插件目录，请检查本地权限", nil
	}
	defer root.Close()

	raw, _, readErr := readCheckedFile(root, "plugin.json", maxManifestBytes)
	if readErr != nil {
		return PluginManifest{}, "", false, "无法读取 plugin.json，请检查文件是否存在且为普通文件", nil
	}
	rev := manifestRevision(raw)
	manifest, valErr := ValidateManifest(root, name, raw)
	if valErr != nil {
		return manifest, rev, false, "", valErr
	}
	hasIcon := manifest.Icon != ""
	if !hasIcon {
		for _, candidate := range []string{"icon.svg", "icon.png"} {
			if st, err := root.Lstat(candidate); err == nil && st.Mode().IsRegular() {
				manifest.Icon = candidate
				hasIcon = true
				break
			}
		}
	}
	return manifest, rev, hasIcon, "", nil
}

func resolvePluginInstance(name, pluginDir, dataDir string, manifest PluginManifest, prevApps map[string]appRecord) (*Instance, *Instance) {
	prev, ok := prevApps[name]
	if !ok || prev.instance == nil {
		return newInstance(name, pluginDir, dataDir, manifest), nil
	}
	if prev.pluginDir != pluginDir || prev.dataDir != dataDir {
		return newInstance(name, pluginDir, dataDir, manifest), prev.instance
	}
	inst := prev.instance
	inst.mu.Lock()
	oldWeb := inst.manifest.Web
	inst.manifest = manifest
	inst.mu.Unlock()
	webChanged := manifest.Web == nil || !manifest.Web.Enabled || manifest.Web.Mode == WebModeStatic ||
		(oldWeb != nil && (oldWeb.Entry != manifest.Web.Entry || oldWeb.Port != manifest.Web.Port || oldWeb.Mode != manifest.Web.Mode))
	if webChanged {
		return newInstance(name, pluginDir, dataDir, manifest), inst
	}
	return inst, nil
}

func resolvePluginActivation(name string, prevApps map[string]appRecord, sysCfg *AppsSystemConfig, fromMCP bool) (bool, bool) {
	prevRec, existedBefore := prevApps[name]
	explicitPending := slices.Contains(sysCfg.PendingApps, name)
	isActivated := (!explicitPending && isOfficialTemplateID(name)) || slices.Contains(sysCfg.ActivatedApps, name)
	isPending := explicitPending || (existedBefore && prevRec.pendingActivation)
	if fromMCP && !isActivated && (!existedBefore || isPending) {
		isPending = true
	}
	cfgDirty := false
	if isPending && !slices.Contains(sysCfg.PendingApps, name) {
		sysCfg.PendingApps = uniqueSortedStrings(append(sysCfg.PendingApps, name))
		cfgDirty = true
	} else if !isPending && !isActivated && existedBefore {
		sysCfg.ActivatedApps = uniqueSortedStrings(append(sysCfg.ActivatedApps, name))
		cfgDirty = true
	}
	return isPending && !isActivated, cfgDirty
}

func invalidAppRecordForRoot(id, pluginDir, dataDir, errMsg string, scanRoot storageScanRoot) *appRecord {
	rec := invalidAppRecord(id, pluginDir, dataDir, errMsg)
	rec.locationID = scanRoot.id
	rec.locationKind = scanRoot.kind
	rec.locationName = scanRoot.name
	return rec
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

func canAccessRecord(rec appRecord, userID int64, role string) bool {
	if !rec.valid {
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

func (m *Manager) snapshotApp(appID string) (appRecord, bool) {
	m.mu.RLock()
	rec, ok := m.apps[appID]
	var snap appRecord
	if ok {
		snap = *rec
	}
	m.mu.RUnlock()
	return snap, ok
}

func (m *Manager) CanAccess(appID string, userID int64, role string) bool {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return false
	}
	return canAccessRecord(snap, userID, role)
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
		LocationID:        fallbackString(rec.locationID, AppStorageIDInternal),
		LocationKind:      fallbackString(rec.locationKind, AppStorageKindInternal),
		LocationName:      fallbackString(rec.locationName, defaultInternalStorageName),
		PluginsDir:        rec.pluginDir,
		PluginDataDir:     rec.dataDir,
		Access:            rec.manifest.Access,
		Cron:              PublicCronView{Events: []string{}, Channels: []string{}},
	}
	if pub.Access.AllowedUserIDs == nil {
		pub.Access.AllowedUserIDs = []int64{}
	}
	if rec.hasIcon {
		pub.IconURL = "/apps/" + rec.id + "/__lightisle_icon"
	}
	if !rec.valid {
		pub.LastError = rec.validationError
		pub.Diagnostic = buildValidationDiagnostic(rec.id, rec.validationError)
	}
	if rec.instance != nil {
		pub.Web = rec.instance.Snapshot()
		if pub.Web.LastError != "" && pub.LastError == "" {
			pub.LastError = pub.Web.LastError
			pub.Diagnostic = rec.instance.Diagnostic()
			if pub.Diagnostic == nil {
				entryName := "run-web.sh"
				if rec.manifest.Web != nil && rec.manifest.Web.Entry != "" {
					entryName = rec.manifest.Web.Entry
				}
				pub.Diagnostic = buildRuntimeCrashDiagnostic(rec.id, entryName, pub.Web.LastError, rec.instance.Logs())
			}
		}
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

// RedactPublicAppForRole strips host filesystem paths, process telemetry,
// peer member allowlists, and cron execution logs for non-admin accounts.
func RedactPublicAppForRole(pub PublicApp, role string) PublicApp {
	if role == "admin" {
		return pub
	}
	pub.Revision = ""
	pub.ValidationError = ""
	pub.LastError = ""
	pub.Diagnostic = nil
	pub.PluginsDir = ""
	pub.PluginDataDir = ""
	if pub.LocationKind == AppStorageKindExternal {
		pub.LocationName = defaultExternalStorageName
	} else {
		pub.LocationName = defaultInternalStorageName
	}
	pub.Access = AccessConfig{
		Policy:         pub.Access.Policy,
		AllowedUserIDs: []int64{},
	}
	pub.Web.Runtime = ""
	pub.Web.Port = 0
	pub.Web.PID = 0
	pub.Web.RSSBytes = 0
	pub.Web.ActiveStreams = 0
	pub.Web.LastActiveAt = 0
	pub.Web.LastError = ""
	pub.Cron = PublicCronView{
		Events:   []string{},
		Channels: []string{},
	}
	return pub
}

func (m *Manager) ListForUser(userID int64, role string) []PublicApp {
	m.mu.RLock()
	records := make([]appRecord, 0, len(m.apps))
	for _, rec := range m.apps {
		records = append(records, *rec)
	}
	m.mu.RUnlock()
	out := make([]PublicApp, 0, len(records))
	for i := range records {
		rec := &records[i]
		if role != "admin" && (!rec.valid || rec.manifest.Web == nil || !rec.manifest.Web.Enabled || !canAccessRecord(*rec, userID, role)) {
			continue
		}
		out = append(out, RedactPublicAppForRole(m.toPublicApp(rec), role))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (m *Manager) GetForUser(appID string, userID int64, role string) (PublicApp, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if role != "admin" && !canAccessRecord(snap, userID, role) {
		return PublicApp{}, ErrForbidden
	}
	return RedactPublicAppForRole(m.toPublicApp(&snap), role), nil
}
