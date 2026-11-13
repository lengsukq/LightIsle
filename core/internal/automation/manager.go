// Package automation schedules local owner-managed executable scripts.
// It does not edit script source or install interpreters/dependencies.
package automation

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/robfig/cron/v3"
)

var (
	ErrInvalid     = errors.New("automation_invalid_task")
	ErrNotFound    = errors.New("automation_task_not_found")
	ErrBusy        = errors.New("automation_task_running")
	ErrUnavailable = errors.New("automation_unavailable")
	ErrChanged     = errors.New("automation_task_changed")
	taskID         = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)
	parser         = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
)

const maxTaskJSON = 32 << 10
const maxEnvJSON = 32 << 10
const maxOutput = 64 << 10
const maxTasks = 120

type Schedule struct {
	Cron     string `json:"cron"`
	Timezone string `json:"timezone"`
}
type Notification struct {
	Events   []string       `json:"events,omitempty"`
	Channels []string       `json:"channels,omitempty"`
	Email    *EmailTemplate `json:"email,omitempty"`
}

// EmailTemplate is selected by the external Agent while writing task.json;
// the Web task manager never exposes or edits this configuration.
type EmailTemplate struct {
	Mode    string `json:"mode,omitempty"` // builtin, content, custom
	File    string `json:"file,omitempty"`
	Subject string `json:"subject,omitempty"`
}
type Task struct {
	SchemaVersion  int          `json:"schemaVersion"`
	ID             string       `json:"id"`
	Name           string       `json:"name"`
	Description    string       `json:"description,omitempty"`
	Enabled        bool         `json:"enabled"`
	Entry          string       `json:"entry"`
	Args           []string     `json:"args,omitempty"`
	EnvFile        string       `json:"envFile,omitempty"`
	Schedule       Schedule     `json:"schedule"`
	TimeoutSeconds int          `json:"timeoutSeconds,omitempty"`
	Notification   Notification `json:"notification,omitempty"`
	Running        bool         `json:"running"`
	NextRun        int64        `json:"nextRun,omitempty"`
	LastError      string       `json:"lastError,omitempty"`
	Revision       string       `json:"revision,omitempty"`
	LastRun        *RunSummary  `json:"lastRun,omitempty"`
	directory      os.FileInfo
}
type Record struct {
	ID         int64             `json:"id"`
	TaskID     string            `json:"taskID"`
	StartedAt  int64             `json:"startedAt"`
	FinishedAt int64             `json:"finishedAt"`
	State      string            `json:"state"`
	ExitCode   int               `json:"exitCode"`
	Output     string            `json:"output"`
	Deliveries map[string]string `json:"deliveries,omitempty"`
}
type Notifier func(task Task, state string, finishedAt time.Time, exitCode int, html string, report func(channel, status string))
type Manager struct {
	dir       string
	scripts   string
	db        *sql.DB
	mu        sync.Mutex
	mutation  sync.Mutex
	tasks     map[string]Task
	plugins   map[string]pluginTaskMeta
	running   map[string]context.CancelFunc
	scheduler *cron.Cron
	slots     chan struct{}
	wg        sync.WaitGroup
	closed    bool
	notify    Notifier
}

// Open returns a recoverable service. Reload may be retried after the local
// directory or history database is repaired.
func Open(dataDir string, notify Notifier) *Manager {
	dir := filepath.Join(dataDir, "automation")
	return &Manager{
		dir:     dir,
		scripts: filepath.Join(dir, "scripts"),
		tasks:   make(map[string]Task),
		plugins: make(map[string]pluginTaskMeta),
		running: make(map[string]context.CancelFunc),
		slots:   make(chan struct{}, 2),
		notify:  notify,
	}
}

func New(dataDir string, notify Notifier) (*Manager, error) {
	m := Open(dataDir, notify)
	if err := m.Reload(); err != nil {
		_ = m.Close()
		return nil, err
	}
	return m, nil
}

func (m *Manager) initialize() error {
	for _, folder := range []string{m.dir, m.scripts, filepath.Join(m.dir, "locks")} {
		if err := os.Mkdir(folder, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		info, err := os.Lstat(folder)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("invalid automation directory: %s", filepath.Base(folder))
		}
	}
	dbPath := filepath.Join(m.dir, "automation.sqlite")
	if info, err := os.Lstat(dbPath); err == nil && !info.Mode().IsRegular() || err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.New("invalid automation history file")
	}
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1&_cache_size=-512")
	if err != nil {
		return err
	}
	db.SetMaxOpenConns(1)
	if err := initializeHistory(db); err != nil {
		_ = db.Close()
		return err
	}
	m.mu.Lock()
	m.db = db
	m.mu.Unlock()
	return nil
}

func (m *Manager) Ready() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return !m.closed && m.scheduler != nil
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
	if m.scheduler != nil {
		m.scheduler.Stop()
	}
	for _, cancel := range m.running {
		cancel()
	}
	m.mu.Unlock()
	m.wg.Wait()
	if m.db != nil {
		return m.db.Close()
	}
	return nil
}
func (m *Manager) List() []Task {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Task, 0, len(m.tasks))
	for _, task := range m.tasks {
		task.Running = m.running[task.ID] != nil
		if task.Enabled && task.LastError == "" {
			loc, _ := time.LoadLocation(task.Schedule.Timezone)
			parsed, err := validateCron(task.Schedule)
			if err == nil && loc != nil {
				task.NextRun = parsed.Next(time.Now().In(loc)).Unix()
			}
		}
		out = append(out, task)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// ScriptsDir returns the host path holding standalone local script folders.
func (m *Manager) ScriptsDir() string {
	return m.scripts
}

// PublicTasks omits Agent-owned values and possible credentials in script arguments.
func (m *Manager) PublicTasks() []Task {
	tasks := m.List()
	summaries, err := m.lastRuns(tasks)
	if err != nil {
		slog.Warn("cannot read automation run summaries", "error", err)
	}
	for i := range tasks {
		tasks[i].LastRun = summaries[tasks[i].ID]
		tasks[i].Args = nil
		tasks[i].EnvFile = ""
		tasks[i].Notification.Email = nil
	}
	return tasks
}

// PublicScriptTasks returns public views for standalone automation/scripts tasks only,
// excluding plugin-backed cron tasks managed inside App Center.
func (m *Manager) PublicScriptTasks() []Task {
	all := m.PublicTasks()
	out := make([]Task, 0, len(all))
	for _, task := range all {
		if _, isPlugin := m.pluginMeta(task.ID); isPlugin {
			continue
		}
		out = append(out, task)
	}
	return out
}

func validChild(value string) bool {
	return value != "" && value != "." && value != ".." && filepath.Base(value) == value && !strings.ContainsAny(value, "/\\")
}
func openDirectoryRoot(path string, expected os.FileInfo) (*os.Root, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !info.IsDir() || (expected != nil && !os.SameFile(expected, info)) {
		return nil, nil, ErrInvalid
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, nil, err
	}
	opened, err := root.Stat(".")
	if err != nil || !os.SameFile(info, opened) {
		root.Close()
		return nil, nil, ErrInvalid
	}
	return root, opened, nil
}

func (m *Manager) openTaskRoot(id string, expected os.FileInfo) (*os.Root, error) {
	if !taskID.MatchString(id) {
		return nil, ErrInvalid
	}
	if meta, ok := m.pluginMeta(id); ok {
		root, _, err := openDirectoryRoot(meta.PluginDir, expected)
		return root, err
	}
	scripts, _, err := openDirectoryRoot(m.scripts, nil)
	if err != nil {
		return nil, err
	}
	defer scripts.Close()
	info, err := scripts.Lstat(id)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || (expected != nil && !os.SameFile(expected, info)) {
		return nil, ErrInvalid
	}
	root, _, err := openDirectoryRoot(filepath.Join(m.scripts, id), info)
	return root, err
}

func checkedFile(root *os.Root, relative string, limit int64) ([]byte, error) {
	if !validChild(relative) {
		return nil, ErrInvalid
	}
	st, err := root.Lstat(relative)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > limit {
		return nil, ErrInvalid
	}
	f, err := root.OpenFile(relative, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(st, opened) {
		return nil, ErrInvalid
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, ErrInvalid
	}
	return data, nil
}
func validateCron(s Schedule) (cron.Schedule, error) {
	if len(strings.Fields(s.Cron)) != 5 {
		return nil, ErrInvalid
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil {
		return nil, ErrInvalid
	}
	parsed, err := parser.Parse(s.Cron)
	if err != nil {
		return nil, ErrInvalid
	}
	return parsed, nil
}
func validateTask(t Task, directory string) error {
	if t.SchemaVersion != 1 || !taskID.MatchString(t.ID) || t.ID != directory ||
		len(t.Name) == 0 || len(t.Name) > 120 || !validChild(t.Entry) ||
		(t.EnvFile != "" && !validChild(t.EnvFile)) || len(t.Args) > 24 ||
		t.TimeoutSeconds < 0 || t.TimeoutSeconds > 3600 {
		return ErrInvalid
	}
	for _, arg := range t.Args {
		if len(arg) > 512 || strings.ContainsRune(arg, 0) {
			return ErrInvalid
		}
	}
	if len(t.Notification.Channels) > 8 || len(t.Notification.Events) > 3 {
		return ErrInvalid
	}
	for _, ch := range t.Notification.Channels {
		switch ch {
		case "bark", "webhook", "email", "wecom", "dingtalk":
		default:
			return ErrInvalid
		}
	}
	for _, event := range t.Notification.Events {
		switch event {
		case "success", "failure", "timeout":
		default:
			return ErrInvalid
		}
	}
	if email := t.Notification.Email; email != nil {
		if len(email.Subject) > 180 || strings.ContainsAny(email.Subject, "\r\n") {
			return ErrInvalid
		}
		switch email.Mode {
		case "", "builtin":
			if email.File != "" {
				return ErrInvalid
			}
		case "content", "custom":
			if !validChild(email.File) {
				return ErrInvalid
			}
		default:
			return ErrInvalid
		}
	}
	_, err := validateCron(t.Schedule)
	return err
}

// Reload reads disk only when called on startup, page opening, or explicit refresh.
// Malformed task JSON is shown with a disabled error entry, never dispatched.
func (m *Manager) Reload() error {
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
	return m.reload()
}

func (m *Manager) reload() error {
	scripts, scriptsInfo, err := openDirectoryRoot(m.scripts, nil)
	if err != nil {
		return err
	}
	defer scripts.Close()
	dir, err := scripts.Open(".")
	if err != nil {
		return err
	}
	entries, err := dir.ReadDir(maxTasks + 1)
	dir.Close()
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if len(entries) > maxTasks {
		return ErrInvalid
	}
	next := make(map[string]Task, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if !taskID.MatchString(name) || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		info, err := scripts.Lstat(name)
		if err != nil || !info.IsDir() {
			continue
		}
		root, directory, err := openDirectoryRoot(filepath.Join(m.scripts, name), info)
		if err != nil {
			continue
		}
		raw, err := checkedFile(root, "task.json", maxTaskJSON)
		if err != nil {
			err = errors.New("无法读取 task.json，请在 Mac 上核对文件和权限。")
		}
		var task Task
		if err == nil {
			if json.Unmarshal(raw, &task) != nil {
				err = errors.New("task.json 格式错误，请修正 JSON 后刷新。")
			}
		}
		if err == nil {
			err = validateTask(task, name)
			if err != nil {
				err = errors.New("任务设置无效，请检查 task.json 中的任务 ID、入口、Cron、时区和通知设置。")
			}
		}
		if err == nil {
			_, err = checkedFile(root, task.Entry, 2<<20) // validate executable is regular, not a link
			if err != nil {
				err = errors.New("找不到有效的脚本入口，请检查入口文件名、类型和权限。")
			}
		}
		if err == nil {
			stat, e := root.Stat(task.Entry)
			if e != nil || stat.Mode()&0111 == 0 {
				err = errors.New("脚本入口没有执行权限，请在 Mac 上修复权限后刷新。")
			}
		}
		if err == nil && task.EnvFile != "" {
			_, err = readEnv(root, task.EnvFile)
			if err != nil {
				err = errors.New("环境变量文件无效，请在 Mac 上核对文件和 JSON 格式。")
			}
		}
		if err == nil && task.Notification.Email != nil && task.Notification.Email.File != "" {
			_, err = checkedFile(root, task.Notification.Email.File, maxEmailTemplate)
			if err != nil {
				err = errors.New("邮件模板无法读取，请在 Mac 上检查本地模板后刷新。")
			}
		}
		root.Close()
		if err != nil {
			task = Task{ID: name, Name: name, Enabled: false, LastError: err.Error()}
		}
		task.directory = directory
		task.Revision = taskRevision(raw)
		next[name] = task
	}
	current, err := os.Lstat(m.scripts)
	if err != nil || !os.SameFile(scriptsInfo, current) {
		return ErrInvalid
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return errors.New("automation_closed")
	}
	for id, meta := range m.plugins {
		next[id] = meta.Task
	}
	m.tasks = next
	m.syncSchedulerLocked()
	return nil
}

type locationSchedule struct {
	cron.Schedule
	Location *time.Location
}

func (s locationSchedule) Next(now time.Time) time.Time { return s.Schedule.Next(now.In(s.Location)) }

func readEnv(root *os.Root, file string) (map[string]string, error) {
	raw, err := checkedFile(root, file, maxEnvJSON)
	if err != nil {
		return nil, err
	}
	var values map[string]string
	if json.Unmarshal(raw, &values) != nil {
		return nil, ErrInvalid
	}
	for k, v := range values {
		if !regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`).MatchString(k) || len(v) > 2048 || strings.ContainsRune(v, 0) {
			return nil, ErrInvalid
		}
	}
	return values, nil
}

func (m *Manager) Update(id string, enabled bool, schedule Schedule, notification Notification) error {
	return m.UpdateRevision(id, enabled, schedule, notification, "")
}

func (m *Manager) UpdateRevision(id string, enabled bool, schedule Schedule, notification Notification, revision string) error {
	if !taskID.MatchString(id) {
		return ErrInvalid
	}
	if _, err := validateCron(schedule); err != nil {
		return err
	}
	m.mutation.Lock()
	defer m.mutation.Unlock()
	m.mu.Lock()
	task, ok := m.tasks[id]
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	task.Enabled = enabled
	task.Schedule = schedule
	// The mail template belongs to the local script author, not the Web API.
	// Ignore any email block sent in a task settings request.
	notification.Email = task.Notification.Email
	task.Notification = notification
	if err := validateTask(task, id); err != nil {
		return err
	}
	if revision == "" {
		revision = task.Revision
	}
	return m.patchJSON(id, task.directory, revision, func(doc map[string]any) {
		doc["enabled"] = enabled
		scheduleDoc, ok := doc["schedule"].(map[string]any)
		if !ok {
			scheduleDoc = make(map[string]any)
		}
		scheduleDoc["cron"], scheduleDoc["timezone"] = schedule.Cron, schedule.Timezone
		doc["schedule"] = scheduleDoc
		// Preserve all local Agent-owned fields, including notification.email
		// and any fields that this older version of LightIsle does not know.
		notificationDoc, ok := doc["notification"].(map[string]any)
		if !ok {
			notificationDoc = make(map[string]any)
		}
		notificationDoc["events"] = notification.Events
		notificationDoc["channels"] = notification.Channels
		doc["notification"] = notificationDoc
	})
}
func taskRevision(raw []byte) string { return fmt.Sprintf("%x", sha256.Sum256(raw)) }

func (m *Manager) patchJSON(id string, directory os.FileInfo, revision string, mutate func(map[string]any)) error {
	root, err := m.openTaskRoot(id, directory)
	if err != nil {
		return err
	}
	defer root.Close()
	raw, err := checkedFile(root, "task.json", maxTaskJSON)
	if err != nil {
		return err
	}
	if taskRevision(raw) != revision {
		return ErrChanged
	}
	var doc map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&doc) != nil {
		return ErrInvalid
	}
	mutate(doc)
	updated, err := json.MarshalIndent(doc, "", "  ")
	if err != nil || len(updated) > maxTaskJSON {
		return ErrInvalid
	}
	temp := "task.json." + fmt.Sprint(time.Now().UnixNano()) + ".tmp"
	file, err := root.OpenFile(temp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(updated)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		root.Remove(temp)
		return ErrInvalid
	}
	current, err := checkedFile(root, "task.json", maxTaskJSON)
	if err != nil || !bytes.Equal(raw, current) {
		_ = root.Remove(temp)
		return ErrChanged
	}
	if err = root.Rename(temp, "task.json"); err != nil {
		root.Remove(temp)
		return err
	}
	return m.reload()
}
func (m *Manager) Delete(id string) error {
	if !taskID.MatchString(id) {
		return ErrInvalid
	}
	m.mutation.Lock()
	defer m.mutation.Unlock()
	m.mu.Lock()
	if m.running[id] != nil {
		m.mu.Unlock()
		return ErrBusy
	}
	task, ok := m.tasks[id]
	if !ok {
		m.mu.Unlock()
		return ErrNotFound
	}
	// Prevent a Cron callback from starting the task between the busy check
	// and deleting the folder. Reload re-registers it if deletion fails.
	delete(m.tasks, id)
	m.mu.Unlock()
	scripts, _, err := openDirectoryRoot(m.scripts, nil)
	if err != nil {
		return err
	}
	defer scripts.Close()
	info, err := scripts.Lstat(id)
	if err != nil || !info.IsDir() || !os.SameFile(task.directory, info) {
		_ = m.reload()
		return ErrInvalid
	}
	if err := scripts.RemoveAll(id); err != nil {
		_ = m.reload()
		return err
	}
	return m.reload()
}
