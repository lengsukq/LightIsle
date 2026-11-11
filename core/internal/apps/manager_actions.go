package apps

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

// ActivateApp explicitly marks a plugin as administrator-approved, clearing
// PendingActivation in memory and persisting the approval to apps-config.json.
func (m *Manager) ActivateApp(appID string) {
	_, _ = m.ApproveApp(appID)
}

// ApproveApp explicitly clears PendingActivation for appID, persists the approval
// in apps-config.json (refusing to overwrite a corrupted config file), enables
// configured Cron schedules, and starts persistent Web processes.
func (m *Manager) ApproveApp(appID string) (PublicApp, error) {
	appID = strings.TrimSpace(appID)
	if !ValidPluginID(appID) {
		return PublicApp{}, ErrInvalid
	}

	var (
		hadPending     bool
		persistentInst *Instance
	)
	if err := func() error {
		m.mutation.Lock()
		defer m.mutation.Unlock()

		m.mu.RLock()
		_, exists := m.apps[appID]
		m.mu.RUnlock()
		if !exists {
			return ErrNotFound
		}

		cfg, err := readSystemConfigFile(m.configPath)
		if err != nil {
			return err
		}
		if slices.Contains(cfg.PendingApps, appID) || !slices.Contains(cfg.ActivatedApps, appID) {
			cfg.PendingApps = slices.DeleteFunc(cfg.PendingApps, func(s string) bool { return s == appID })
			cfg.ActivatedApps = uniqueSortedStrings(append(cfg.ActivatedApps, appID))
			cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			if err := writeSystemConfigFile(m.configPath, cfg); err != nil {
				return err
			}
		}

		m.mu.Lock()
		if rec, ok := m.apps[appID]; ok {
			hadPending = rec.pendingActivation
			rec.pendingActivation = false
			if hadPending && rec.valid && rec.manifest.Web != nil && rec.manifest.Web.Enabled && rec.manifest.Web.Mode == WebModePersistent {
				persistentInst = rec.instance
			}
		}
		m.mu.Unlock()
		return nil
	}(); err != nil {
		return PublicApp{}, err
	}

	if hadPending && m.automation != nil {
		m.syncAllCronTasks()
	}
	if persistentInst != nil {
		go func(target *Instance) {
			_, _, _ = target.Wake(context.Background())
		}(persistentInst)
	}
	return m.GetForUser(appID, 0, "admin")
}

// ExecuteAction runs a unified administrator lifecycle action on an app.
func (m *Manager) ExecuteAction(ctx context.Context, appID, action string) (PublicApp, error) {
	appID = strings.TrimSpace(appID)
	if !ValidPluginID(appID) {
		return PublicApp{}, ErrInvalid
	}
	switch strings.ToLower(strings.TrimSpace(action)) {
	case "start", "wake":
		return m.WakeApp(ctx, appID)
	case "stop":
		return m.StopApp(appID)
	case "restart":
		return m.RestartApp(ctx, appID)
	case "trigger-cron", "run_cron":
		if err := m.TriggerCron(appID); err != nil {
			return PublicApp{}, err
		}
		return m.GetForUser(appID, 0, "admin")
	case "approve", "activate":
		return m.ApproveApp(appID)
	default:
		return PublicApp{}, fmt.Errorf("%w: unsupported action %q", ErrInvalid, action)
	}
}

func (m *Manager) WakeApp(ctx context.Context, appID string) (PublicApp, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if !snap.valid || snap.instance == nil {
		return PublicApp{}, ErrInvalid
	}
	if snap.pendingActivation {
		return m.toPublicApp(&snap), ErrPendingActivation
	}
	if _, _, err := snap.instance.Wake(ctx); err != nil {
		return m.toPublicApp(&snap), err
	}
	return m.toPublicApp(&snap), nil
}

func (m *Manager) StopApp(appID string) (PublicApp, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if snap.instance != nil {
		_ = snap.instance.Stop(false)
	}
	return m.toPublicApp(&snap), nil
}

func (m *Manager) RestartApp(ctx context.Context, appID string) (PublicApp, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return PublicApp{}, ErrNotFound
	}
	if !snap.valid || snap.instance == nil {
		return PublicApp{}, ErrInvalid
	}
	if snap.pendingActivation {
		return m.toPublicApp(&snap), ErrPendingActivation
	}
	if err := snap.instance.Restart(ctx); err != nil {
		return m.toPublicApp(&snap), err
	}
	return m.toPublicApp(&snap), nil
}

func (m *Manager) GetWebLogs(appID string) (string, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return "", ErrNotFound
	}
	if snap.instance == nil {
		return "", nil
	}
	return snap.instance.Logs(), nil
}

func (m *Manager) GetCronRuns(appID string, limit int) ([]automation.TaskRun, error) {
	if _, ok := m.snapshotApp(appID); !ok {
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
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return ErrNotFound
	}
	if !snap.valid || snap.manifest.Cron == nil {
		return ErrInvalid
	}
	if snap.pendingActivation {
		return ErrPendingActivation
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
		if _, err := readSystemConfigFile(m.configPath); err != nil {
			return err
		}
		snap, ok := m.snapshotApp(appID)
		if !ok {
			return ErrNotFound
		}
		if req.RequireApproved && snap.pendingActivation {
			return ErrPendingActivation
		}
		root, err := os.OpenRoot(snap.pluginDir)
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
	cfg, cfgErr := readSystemConfigFile(m.configPath)
	if cfgErr != nil {
		m.mutation.Unlock()
		return cfgErr
	}
	m.mu.Lock()
	rec, ok := m.apps[appID]
	if !ok {
		m.mu.Unlock()
		m.mutation.Unlock()
		return ErrNotFound
	}
	snap := *rec
	delete(m.apps, appID)
	m.mu.Unlock()

	if snap.instance != nil {
		snap.instance.Close()
	}
	if err := os.RemoveAll(snap.pluginDir); err != nil {
		m.mutation.Unlock()
		_ = m.Reload()
		return err
	}
	if deleteData {
		_ = os.RemoveAll(snap.dataDir)
	}
	cfg.PendingApps = slices.DeleteFunc(cfg.PendingApps, func(s string) bool { return s == appID })
	cfg.ActivatedApps = slices.DeleteFunc(cfg.ActivatedApps, func(s string) bool { return s == appID })
	if err := writeSystemConfigFile(m.configPath, cfg); err != nil {
		m.mutation.Unlock()
		return err
	}
	m.mutation.Unlock()
	return m.Reload()
}
