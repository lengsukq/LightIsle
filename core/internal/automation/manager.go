// Package automation schedules local owner-managed executable scripts.
// It does not edit script source or install interpreters/dependencies.
package automation

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
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
	ErrInvalid  = errors.New("automation_invalid_task")
	ErrNotFound = errors.New("automation_task_not_found")
	ErrBusy     = errors.New("automation_task_running")
	taskID      = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)
	parser      = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
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

// EmailTemplate is created and maintained by the external Agent, never by Web.
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
}
type Record struct {
	ID         int64  `json:"id"`
	TaskID     string `json:"taskID"`
	StartedAt  int64  `json:"startedAt"`
	FinishedAt int64  `json:"finishedAt"`
	State      string `json:"state"`
	ExitCode   int    `json:"exitCode"`
	Output     string `json:"output"`
}
type Notifier func(task Task, state string, finishedAt time.Time, exitCode int, html string)
type Manager struct {
	dir       string
	scripts   string
	db        *sql.DB
	mu        sync.Mutex
	tasks     map[string]Task
	running   map[string]context.CancelFunc
	scheduler *cron.Cron
	slots     chan struct{}
	wg        sync.WaitGroup
	closed    bool
	notify    Notifier
}

func New(dataDir string, notify Notifier) (*Manager, error) {
	dir := filepath.Join(dataDir, "automation")
	for _, path := range []string{dir, filepath.Join(dir, "scripts")} {
		if err := os.MkdirAll(path, 0700); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite3", filepath.Join(dir, "automation.sqlite"))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS runs(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 task_id TEXT NOT NULL,
 started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL,
 state TEXT NOT NULL, exit_code INTEGER NOT NULL, output TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS runs_task_id ON runs(task_id,id);`)
	if err != nil {
		db.Close()
		return nil, err
	}
	m := &Manager{dir: dir, scripts: filepath.Join(dir, "scripts"), db: db, tasks: make(map[string]Task), running: make(map[string]context.CancelFunc), slots: make(chan struct{}, 2), notify: notify}
	if err := m.Reload(); err != nil {
		db.Close()
		return nil, err
	}
	return m, nil
}
func (m *Manager) Close() error {
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
	return m.db.Close()
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
func validChild(value string) bool {
	return value != "" && value != "." && value != ".." && filepath.Base(value) == value && !strings.ContainsAny(value, "/\\")
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
	f, err := root.Open(relative)
	if err != nil {
		return nil, err
	}
	defer f.Close()
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
	entries, err := os.ReadDir(m.scripts)
	if err != nil {
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
		root, err := os.OpenRoot(filepath.Join(m.scripts, name))
		if err != nil {
			continue
		}
		raw, err := checkedFile(root, "task.json", maxTaskJSON)
		var task Task
		if err == nil {
			err = json.Unmarshal(raw, &task)
		}
		if err == nil {
			err = validateTask(task, name)
		}
		if err == nil {
			_, err = checkedFile(root, task.Entry, 2<<20) // validate executable is regular, not a link
		}
		if err == nil {
			stat, e := root.Stat(task.Entry)
			if e != nil || stat.Mode()&0111 == 0 {
				err = ErrInvalid
			}
		}
		if err == nil && task.EnvFile != "" {
			_, err = readEnv(root, task.EnvFile)
		}
		if err == nil && task.Notification.Email != nil && task.Notification.Email.File != "" {
			_, err = checkedFile(root, task.Notification.Email.File, maxEmailTemplate)
		}
		root.Close()
		if err != nil {
			task = Task{ID: name, Name: name, Enabled: false, LastError: "配置无效或入口不可执行：" + err.Error()}
		}
		next[name] = task
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return errors.New("automation_closed")
	}
	old := m.scheduler
	m.tasks = next
	scheduler := cron.New(cron.WithParser(parser))
	for id, task := range next {
		if !task.Enabled || task.LastError != "" {
			continue
		}
		loc, _ := time.LoadLocation(task.Schedule.Timezone)
		parsed, _ := validateCron(task.Schedule)
		nextRun := parsed.Next(time.Now().In(loc))
		task.NextRun = nextRun.Unix()
		m.tasks[id] = task
		taskID := id
		schedule := locationSchedule{Schedule: parsed, Location: loc}
		scheduler.Schedule(schedule, cron.FuncJob(func() { m.run(taskID) }))
	}
	m.scheduler = scheduler
	scheduler.Start()
	if old != nil {
		old.Stop()
	}
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

type limitedWriter struct{ bytes.Buffer }

func (w *limitedWriter) Write(p []byte) (int, error) {
	n := len(p)
	if w.Len() < maxOutput {
		remaining := maxOutput - w.Len()
		w.Buffer.Write(p[:min(len(p), remaining)])
	}
	return n, nil
}
func (m *Manager) run(id string) {
	m.mu.Lock()
	task, ok := m.tasks[id]
	if !ok || !task.Enabled || m.running[id] != nil || m.closed {
		m.mu.Unlock()
		return
	}
	select {
	case m.slots <- struct{}{}:
	default:
		m.mu.Unlock()
		return
	}
	duration := time.Duration(task.TimeoutSeconds) * time.Second
	if duration == 0 {
		duration = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	m.running[id] = cancel
	m.wg.Add(1)
	m.mu.Unlock()
	defer func() {
		defer m.wg.Done()
		cancel()
		<-m.slots
		m.mu.Lock()
		delete(m.running, id)
		m.mu.Unlock()
	}()
	started := time.Now().Unix()
	var output limitedWriter
	state := "success"
	code := 0
	root, err := os.OpenRoot(filepath.Join(m.scripts, id))
	if err == nil {
		_, err = checkedFile(root, "task.json", maxTaskJSON)
		if err == nil {
			_, err = checkedFile(root, task.Entry, 2<<20)
		}
	}
	env := map[string]string{}
	if err == nil && task.EnvFile != "" {
		env, err = readEnv(root, task.EnvFile)
	}
	if root != nil {
		root.Close()
	}
	if err == nil {
		command := exec.Command(filepath.Join(m.scripts, id, task.Entry), task.Args...)
		command.Dir = filepath.Join(m.scripts, id)
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		command.Env = []string{"PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + os.Getenv("HOME"), "TMPDIR=" + os.TempDir(), "LANG=en_US.UTF-8"}
		for k, v := range env {
			command.Env = append(command.Env, k+"="+v)
		}
		command.Stdout = &output
		command.Stderr = &output
		if err = command.Start(); err == nil {
			done := make(chan error, 1)
			go func() { done <- command.Wait() }()
			select {
			case err = <-done:
			case <-ctx.Done():
				if command.Process != nil {
					_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
				}
				<-done
				err = ctx.Err()
			}
		}
	}
	if err != nil {
		state = "failure"
		code = -1
		if errors.Is(err, context.DeadlineExceeded) {
			state = "timeout"
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		}
		output.Write([]byte("\nLightIsle: " + err.Error()))
	}
	_, _ = m.db.Exec(`INSERT INTO runs(task_id,started_at,finished_at,state,exit_code,output) VALUES(?,?,?,?,?,?)`, id, started, time.Now().Unix(), state, code, output.String())
	_, _ = m.db.Exec(`DELETE FROM runs WHERE task_id=? AND id NOT IN(SELECT id FROM runs WHERE task_id=? ORDER BY id DESC LIMIT 30)`, id, id)
	if m.notify != nil {
		for _, event := range task.Notification.Events {
			if event == state {
				finishedAt := time.Now()
				html := ""
				if task.Notification.Email != nil && task.Notification.Email.File != "" {
					var templateErr error
					html, templateErr = m.renderTaskEmail(task, state, code, finishedAt)
					if templateErr != nil {
						// The template could have disappeared after the last manual
						// refresh. Do not send an empty custom email silently.
						fallback := *task.Notification.Email
						fallback.Mode = "builtin"
						fallback.File = ""
						task.Notification.Email = &fallback
						task.LastError = "邮件 HTML 模板不可读取，本次通知已退回内置模板，请检查本地文件后刷新。"
					}
				}
				m.notify(task, state, finishedAt, code, html)
				break
			}
		}
	}
}
func (m *Manager) History(id string) ([]Record, error) {
	if !taskID.MatchString(id) {
		return nil, ErrInvalid
	}
	rows, err := m.db.Query(`SELECT id,task_id,started_at,finished_at,state,exit_code,output FROM runs WHERE task_id=? ORDER BY id DESC LIMIT 30`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]Record, 0)
	for rows.Next() {
		var record Record
		if err := rows.Scan(&record.ID, &record.TaskID, &record.StartedAt, &record.FinishedAt, &record.State, &record.ExitCode, &record.Output); err != nil {
			return nil, err
		}
		result = append(result, record)
	}
	return result, rows.Err()
}
func (m *Manager) Update(id string, enabled bool, schedule Schedule, notification Notification) error {
	if !taskID.MatchString(id) {
		return ErrInvalid
	}
	if _, err := validateCron(schedule); err != nil {
		return err
	}
	m.mu.Lock()
	task, ok := m.tasks[id]
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	task.Enabled = enabled
	task.Schedule = schedule
	// Changing Cron/notifications from Web must retain the external Agent-owned
	// HTML template reference and subject unchanged.
	notification.Email = task.Notification.Email
	task.Notification = notification
	if err := validateTask(task, id); err != nil {
		return err
	}
	return m.patchJSON(id, func(doc map[string]any) {
		doc["enabled"] = enabled
		doc["schedule"] = schedule
		doc["notification"] = notification
	})
}
func (m *Manager) patchJSON(id string, mutate func(map[string]any)) error {
	root, err := os.OpenRoot(filepath.Join(m.scripts, id))
	if err != nil {
		return err
	}
	defer root.Close()
	raw, err := checkedFile(root, "task.json", maxTaskJSON)
	if err != nil {
		return err
	}
	var doc map[string]any
	if json.Unmarshal(raw, &doc) != nil {
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
	if err = root.Rename(temp, "task.json"); err != nil {
		root.Remove(temp)
		return err
	}
	return m.Reload()
}
func (m *Manager) Delete(id string) error {
	if !taskID.MatchString(id) {
		return ErrInvalid
	}
	m.mu.Lock()
	if m.running[id] != nil {
		m.mu.Unlock()
		return ErrBusy
	}
	if _, ok := m.tasks[id]; !ok {
		m.mu.Unlock()
		return ErrNotFound
	}
	// Prevent a Cron callback from starting the task between the busy check
	// and deleting the folder. Reload re-registers it if deletion fails.
	delete(m.tasks, id)
	m.mu.Unlock()
	dir := filepath.Join(m.scripts, id)
	st, err := os.Lstat(dir)
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		_ = m.Reload()
		return ErrInvalid
	}
	if err := os.RemoveAll(dir); err != nil {
		_ = m.Reload()
		return err
	}
	return m.Reload()
}
