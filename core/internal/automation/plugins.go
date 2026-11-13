package automation

import (
	"errors"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

type TaskSpec = Task
type TaskView = Task
type TaskRun = Record

// PluginCronRegistration registers a plugin-backed scheduled task ("app-<plugin-id>")
// whose scripts, env.json, email templates, and lock file live directly inside PluginDir.
type PluginCronRegistration struct {
	PluginID  string
	PluginDir string
	DataDir   string
	Spec      TaskSpec
}

type pluginTaskMeta struct {
	PluginID  string
	PluginDir string
	DataDir   string
	Task      Task
}

func (m *Manager) pluginMeta(id string) (pluginTaskMeta, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.plugins == nil {
		return pluginTaskMeta{}, false
	}
	meta, ok := m.plugins[id]
	return meta, ok
}

func (m *Manager) syncSchedulerLocked() {
	old := m.scheduler
	scheduler := cron.New(cron.WithParser(parser))
	for id, task := range m.tasks {
		if !task.Enabled || task.LastError != "" {
			task.NextRun = 0
			m.tasks[id] = task
			continue
		}
		loc, err := time.LoadLocation(task.Schedule.Timezone)
		if err != nil || loc == nil {
			continue
		}
		parsed, err := validateCron(task.Schedule)
		if err != nil {
			continue
		}
		nextRun := parsed.Next(time.Now().In(loc))
		task.NextRun = nextRun.Unix()
		m.tasks[id] = task
		taskID := id
		schedule := locationSchedule{Schedule: parsed, Location: loc}
		var entryID cron.EntryID
		entryID = scheduler.Schedule(schedule, cron.FuncJob(func() {
			m.runScheduled(taskID, scheduler, scheduler.Entry(entryID).Prev)
		}))
	}
	m.scheduler = scheduler
	scheduler.Start()
	if old != nil {
		old.Stop()
	}
}

// SyncPluginTasks replaces the set of registered "app-<plugin-id>" tasks and
// updates the live cron scheduler without touching standalone automation/scripts tasks.
func (m *Manager) SyncPluginTasks(regs []PluginCronRegistration) error {
	m.mutation.Lock()
	defer m.mutation.Unlock()

	m.mu.Lock()
	closed, db := m.closed, m.db
	m.mu.Unlock()
	if closed {
		return ErrUnavailable
	}
	if db == nil {
		if err := m.initialize(); err != nil {
			return err
		}
	}

	nextPlugins := make(map[string]pluginTaskMeta, len(regs))
	for _, reg := range regs {
		pluginID := strings.TrimSpace(reg.PluginID)
		if pluginID == "" {
			continue
		}
		id := "app-" + pluginID
		if !taskID.MatchString(id) {
			continue
		}
		root, directory, err := openDirectoryRoot(reg.PluginDir, nil)
		if err != nil {
			task := Task{
				SchemaVersion: 1,
				ID:            id,
				Name:          reg.Spec.Name,
				Enabled:       false,
				LastError:     "无法访问插件目录，请检查本地文件与权限。",
			}
			if task.Name == "" {
				task.Name = pluginID
			}
			nextPlugins[id] = pluginTaskMeta{
				PluginID:  pluginID,
				PluginDir: reg.PluginDir,
				DataDir:   reg.DataDir,
				Task:      task,
			}
			continue
		}

		task := reg.Spec
		if task.SchemaVersion == 0 {
			task.SchemaVersion = 1
		}
		task.ID = id
		if task.Name == "" {
			task.Name = pluginID
		}
		if task.EnvFile == "" {
			if st, envErr := root.Lstat("env.json"); envErr == nil && st.Mode().IsRegular() {
				task.EnvFile = "env.json"
			}
		}

		var valErr error
		if validateTask(task, id) != nil {
			valErr = errors.New("插件定时任务设置无效，请检查入口、Cron、时区和通知配置。")
		}
		if valErr == nil {
			if _, e := checkedFile(root, task.Entry, 2<<20); e != nil {
				valErr = errors.New("找不到有效的插件定时脚本入口，请检查文件名与类型。")
			}
		}
		if valErr == nil {
			if stat, e := root.Stat(task.Entry); e != nil || stat.Mode()&0111 == 0 {
				valErr = errors.New("插件定时脚本入口没有执行权限（需 chmod 0700）。")
			}
		}
		if valErr == nil && task.EnvFile != "" {
			if _, e := readEnv(root, task.EnvFile); e != nil {
				valErr = errors.New("插件 env.json 格式无效，请检查环境变量配置。")
			}
		}
		if valErr == nil && task.Notification.Email != nil && task.Notification.Email.File != "" {
			if _, e := checkedFile(root, task.Notification.Email.File, maxEmailTemplate); e != nil {
				valErr = errors.New("插件邮件模板无法读取，请检查本地 HTML 模板文件。")
			}
		}
		rawManifest, _ := checkedFile(root, "plugin.json", maxTaskJSON)
		root.Close()

		if valErr != nil {
			task.Enabled = false
			task.LastError = valErr.Error()
		}
		task.directory = directory
		if len(rawManifest) > 0 {
			task.Revision = taskRevision(rawManifest)
		}
		nextPlugins[id] = pluginTaskMeta{
			PluginID:  pluginID,
			PluginDir: reg.PluginDir,
			DataDir:   reg.DataDir,
			Task:      task,
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return ErrUnavailable
	}
	for oldID := range m.plugins {
		delete(m.tasks, oldID)
	}
	if m.plugins == nil {
		m.plugins = make(map[string]pluginTaskMeta, len(nextPlugins))
	} else {
		clear(m.plugins)
	}
	for id, meta := range nextPlugins {
		m.plugins[id] = meta
		m.tasks[id] = meta.Task
	}
	m.syncSchedulerLocked()
	return nil
}

// GetTaskView returns the live scheduling state and latest run summary for a task.
func (m *Manager) GetTaskView(id string) (TaskView, bool) {
	m.mu.Lock()
	task, ok := m.tasks[id]
	if !ok {
		m.mu.Unlock()
		return TaskView{}, false
	}
	task.Running = m.running[task.ID] != nil
	if task.Enabled && task.LastError == "" {
		loc, _ := time.LoadLocation(task.Schedule.Timezone)
		parsed, err := validateCron(task.Schedule)
		if err == nil && loc != nil {
			task.NextRun = parsed.Next(time.Now().In(loc)).Unix()
		}
	}
	m.mu.Unlock()

	if summaries, err := m.lastRuns([]Task{task}); err == nil {
		task.LastRun = summaries[task.ID]
	}
	return task, true
}

// ListRuns returns recent execution records for a task (up to limit, max 30).
func (m *Manager) ListRuns(id string, limit int) ([]TaskRun, error) {
	runs, err := m.History(id)
	if err != nil {
		return nil, err
	}
	if limit > 0 && len(runs) > limit {
		runs = runs[:limit]
	}
	return runs, nil
}

// ScriptTaskHistory returns recent execution records for standalone local scripts only,
// rejecting plugin-backed cron tasks managed inside App Center.
func (m *Manager) ScriptTaskHistory(id string) ([]Record, error) {
	if _, isPlugin := m.pluginMeta(id); isPlugin {
		return nil, ErrNotFound
	}
	return m.History(id)
}

// ListScriptRuns returns recent execution records for a standalone local script task.
func (m *Manager) ListScriptRuns(id string, limit int) ([]TaskRun, error) {
	if _, isPlugin := m.pluginMeta(id); isPlugin {
		return nil, ErrNotFound
	}
	return m.ListRuns(id, limit)
}

// RunSync executes a task synchronously (used by manual triggers and tests).
func (m *Manager) RunSync(id string) error {
	m.mu.Lock()
	_, ok := m.tasks[id]
	closed := m.closed
	m.mu.Unlock()
	if closed {
		return ErrUnavailable
	}
	if !ok {
		return ErrNotFound
	}
	m.run(id)
	return nil
}

// RunScriptTaskNow triggers an asynchronous immediate execution of a local
// script task in automation/scripts/ (excluding plugin-backed tasks, which
// execute through the App Center cron endpoint after activation checks).
func (m *Manager) RunScriptTaskNow(id string) error {
	if _, isPlugin := m.pluginMeta(id); isPlugin {
		return ErrNotFound
	}
	return m.RunNow(id)
}

// RunNow triggers an asynchronous immediate execution of a registered task.
func (m *Manager) RunNow(id string) error {
	m.mu.Lock()
	task, ok := m.tasks[id]
	if !ok {
		m.mu.Unlock()
		return ErrNotFound
	}
	if m.closed {
		m.mu.Unlock()
		return ErrUnavailable
	}
	if m.running[id] != nil {
		m.mu.Unlock()
		return ErrBusy
	}
	if !task.Enabled {
		// Allow manual run even if schedule is paused by temporarily running via runForce
		m.mu.Unlock()
		go m.runForce(id)
		return nil
	}
	m.mu.Unlock()
	go m.run(id)
	return nil
}

func (m *Manager) runForce(id string) {
	m.mu.Lock()
	task, ok := m.tasks[id]
	if !ok || m.closed {
		m.mu.Unlock()
		return
	}
	wasEnabled := task.Enabled
	if !wasEnabled {
		task.Enabled = true
		m.tasks[id] = task
	}
	m.mu.Unlock()
	m.run(id)
	if !wasEnabled {
		m.mu.Lock()
		if cur, exists := m.tasks[id]; exists {
			cur.Enabled = false
			m.tasks[id] = cur
		}
		m.mu.Unlock()
	}
}
