package apps

import (
	"context"
	"crypto/rand"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

const (
	maxAppTickets    = 1024
	maxSessionGrants = 1024
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
	mu                                                                         sync.RWMutex
	mutation                                                                   sync.Mutex
	apps                                                                       map[string]*appRecord
	tickets                                                                    map[string]ticketRecord
	sessionGrants                                                              map[string]sessionGrant
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
		sessionGrants:   make(map[string]sessionGrant),
		cookieSecret:    secret,
		reapInterval:    5 * time.Second,
		stopCh:          make(chan struct{}),
	}
	if cfg, err := readSystemConfigFile(m.configPath); err == nil && cfg.MCPEnabled {
		_ = ensureReloadTokenFile(m.reloadTokenPath)
	}
	m.wg.Add(1)
	go m.reapLoop()
	return m
}

func (m *Manager) DataDir() string    { return m.dataDir }
func (m *Manager) PluginsDir() string { return m.pluginsDir }
func (m *Manager) ExecPath() string   { return m.execPath }

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
	m.mu.Lock()
	var instances []*Instance
	for _, rec := range m.apps {
		if rec.instance != nil && rec.instance.IsRunning() {
			instances = append(instances, rec.instance)
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
	_ = m.automation.SyncPluginTasks(cronRegs)
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

	entries, err := os.ReadDir(m.pluginsDir)
	if err != nil {
		return err
	}

	sysCfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		return err
	}
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
		isPending := slices.Contains(sysCfg.PendingApps, name) || (existedBefore && prevRec.pendingActivation)
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
		if err := writeSystemConfigFile(m.configPath, sysCfg); err != nil {
			return err
		}
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
		pub := m.toPublicApp(rec)
		if role != "admin" {
			pub.ValidationError = ""
			pub.LastError = ""
			pub.Web.LastError = ""
			pub.Diagnostic = nil
		}
		out = append(out, pub)
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
	pub := m.toPublicApp(&snap)
	if role != "admin" {
		pub.ValidationError = ""
		pub.LastError = ""
		pub.Web.LastError = ""
		pub.Diagnostic = nil
	}
	return pub, nil
}
