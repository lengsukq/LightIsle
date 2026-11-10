package automation

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestScriptTimeoutTerminatesTaskAndRecordsFailure(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "slow-script", "sleep 10", true)
	content, err := os.ReadFile(filepath.Join(dir, "task.json"))
	if err != nil {
		t.Fatal(err)
	}
	var task Task
	if err = json.Unmarshal(content, &task); err != nil {
		t.Fatal(err)
	}
	task.TimeoutSeconds = 1
	raw, _ := json.Marshal(task)
	if err = os.WriteFile(filepath.Join(dir, "task.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	manager, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	started := time.Now()
	manager.run("slow-script")
	if elapsed := time.Since(started); elapsed > 4*time.Second {
		t.Fatalf("script timeout did not terminate process group: %s", elapsed)
	}
	runs, err := manager.History("slow-script")
	if err != nil || len(runs) != 1 || runs[0].State != "timeout" {
		t.Fatalf("expected one timeout run, got %+v: %v", runs, err)
	}
}

func createTask(t *testing.T, base, id, script string, enabled bool) string {
	t.Helper()
	dir := filepath.Join(base, "automation", "scripts", id)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "run.sh"), []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	task := Task{SchemaVersion: 1, ID: id, Name: id, Enabled: enabled, Entry: "run.sh", Schedule: Schedule{Cron: "0 2 * * *", Timezone: "Asia/Shanghai"}, Notification: Notification{Events: []string{"failure", "timeout"}, Channels: []string{"bark"}}}
	raw, _ := json.Marshal(task)
	if err := os.WriteFile(filepath.Join(dir, "task.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	return dir
}
func TestLocalScriptReloadEditAndHistory(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "sample", "echo lightisle-script-ok", true)
	if err := os.WriteFile(filepath.Join(dir, "env.json"), []byte(`{"SAMPLE":"secret"}`), 0600); err != nil {
		t.Fatal(err)
	}
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	tasks := m.List()
	if len(tasks) != 1 || !tasks[0].Enabled || tasks[0].NextRun == 0 {
		t.Fatalf("unexpected tasks %+v", tasks)
	}
	m.run("sample")
	records, err := m.History("sample")
	if err != nil || len(records) != 1 || records[0].State != "success" || !strings.Contains(records[0].Output, "lightisle-script-ok") {
		t.Fatalf("unexpected history %+v: %v", records, err)
	}
	if err = m.Update("sample", false, Schedule{Cron: "5 3 * * *", Timezone: "UTC"}, Notification{Events: []string{"timeout"}, Channels: []string{"email"}}); err != nil {
		t.Fatal(err)
	}
	if m.List()[0].Enabled || m.List()[0].Schedule.Cron != "5 3 * * *" {
		t.Fatal("task config not updated")
	}
	code, _ := os.ReadFile(filepath.Join(dir, "run.sh"))
	if !strings.Contains(string(code), "lightisle-script-ok") {
		t.Fatal("web edit changed script source")
	}
	if err = m.Delete("sample"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("deleted task still exists: %v", err)
	}
	if len(m.List()) != 0 {
		t.Fatal("deleted task still registered")
	}
}
func TestRejectInvalidScriptAndNoSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "unsafe", "echo unsafe", true)
	outside := filepath.Join(base, "outside.sh")
	if err := os.WriteFile(outside, []byte("#!/bin/sh\necho should-never-run"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, "run.sh")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "run.sh")); err != nil {
		t.Fatal(err)
	}
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	entries := m.List()
	if len(entries) != 1 || entries[0].Enabled || entries[0].LastError == "" {
		t.Fatalf("symlink script accepted: %+v", entries)
	}
	if err := m.Update("../outside", true, Schedule{Cron: "0 0 * * *", Timezone: "UTC"}, Notification{}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("path traversal accepted: %v", err)
	}
	if err := m.Delete("../outside"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("path traversal delete accepted: %v", err)
	}
	if err := m.Reload(); err != nil {
		t.Fatal(err)
	}
	if len(m.List()) != 1 || m.List()[0].Enabled {
		t.Fatal("invalid task unexpectedly enabled")
	}
}
func TestCronTimezonesAndTaskNotificationValidation(t *testing.T) {
	base := t.TempDir()
	createTask(t, base, "daily", "echo ok", false)
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	bad := []Schedule{{Cron: "@every 1s", Timezone: "UTC"}, {Cron: "* * * * * *", Timezone: "UTC"}, {Cron: "* * * * *", Timezone: "No/SuchZone"}}
	for _, item := range bad {
		if err := m.Update("daily", true, item, Notification{}); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid Cron accepted %+v: %v", item, err)
		}
	}
	if err := m.Update("daily", true, Schedule{Cron: "* * * * *", Timezone: "UTC"}, Notification{Channels: []string{"unknown"}}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("unknown notify channel accepted: %v", err)
	}
}

func TestLoadedTaskDirectoryCannotBeReplacedBySymlink(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "sample", "echo original", true)
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	external := t.TempDir()
	other := createTask(t, external, "sample", "echo replacement-executed", true)
	if err := os.Rename(dir, dir+"-original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, dir); err != nil {
		t.Fatal(err)
	}
	m.run("sample")
	records, err := m.History("sample")
	if err != nil || len(records) != 1 || records[0].State != "failure" || strings.Contains(records[0].Output, "replacement-executed") {
		t.Fatalf("replacement directory was used: %+v %v", records, err)
	}
	original, err := os.ReadFile(filepath.Join(other, "task.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Update("sample", false, Schedule{Cron: "0 9 * * *", Timezone: "UTC"}, Notification{}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("settings accepted replaced task: %v", err)
	}
	current, err := os.ReadFile(filepath.Join(other, "task.json"))
	if err != nil || string(current) != string(original) {
		t.Fatalf("external task was modified: %v", err)
	}
}

func TestPublicTasksOmitsLocalScriptSettings(t *testing.T) {
	m := &Manager{tasks: map[string]Task{
		"sample": {
			ID: "sample", Entry: "run.sh", Args: []string{"secret"},
			EnvFile: "env.json", Notification: Notification{
				Events: []string{"failure"}, Email: &EmailTemplate{File: "email.html"},
			},
		},
	}}
	tasks := m.PublicTasks()
	if len(tasks) != 1 || tasks[0].Entry != "run.sh" || len(tasks[0].Notification.Events) != 1 ||
		len(tasks[0].Args) != 0 || tasks[0].EnvFile != "" || tasks[0].Notification.Email != nil {
		t.Fatalf("public settings expose local data or hide scheduling fields: %+v", tasks)
	}
}

func TestAutomationHistoryFailureRecoversAndKeepsInterruptedRecord(t *testing.T) {
	base := t.TempDir()
	createTask(t, base, "recoverable", "echo ready", true)
	database := filepath.Join(base, "automation", "automation.sqlite")
	if err := os.WriteFile(database, []byte("not a database"), 0600); err != nil {
		t.Fatal(err)
	}
	manager := Open(base, nil)
	if err := manager.Reload(); err == nil || manager.Ready() {
		t.Fatalf("invalid history passed startup: %v", err)
	}
	if err := os.Remove(database); err != nil {
		t.Fatal(err)
	}
	if err := manager.Reload(); err != nil || !manager.Ready() {
		t.Fatalf("history repair did not recover: %v", err)
	}
	if _, err := manager.beginRun("recoverable", time.Now().Unix()); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	restarted, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	runs, err := restarted.History("recoverable")
	if err != nil || len(runs) != 1 || runs[0].State != "interrupted" || runs[0].FinishedAt == 0 {
		t.Fatalf("missing interrupted execution after restart: %+v %v", runs, err)
	}
}

func TestAutomationRejectsStaleEditAndRecordsSkippedRunAndDelivery(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "daily", "echo done", true)
	filename := filepath.Join(dir, "task.json")
	manager, err := New(base, func(_ Task, _ string, _ time.Time, _ int, _ string, report func(string, string)) {
		report("bark", "backoff")
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	task := manager.List()[0]
	original, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	localEdit := append(original, '\n')
	if err := os.WriteFile(filename, localEdit, 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.UpdateRevision(task.ID, false, task.Schedule, task.Notification, task.Revision); !errors.Is(err, ErrChanged) {
		t.Fatalf("stale settings edit was not rejected: %v", err)
	}
	if current, err := os.ReadFile(filename); err != nil || string(current) != string(localEdit) {
		t.Fatalf("stale edit changed local task.json: %v", err)
	}
	if err := manager.Reload(); err != nil {
		t.Fatal(err)
	}
	task = manager.List()[0]
	if err := manager.UpdateRevision(task.ID, true, task.Schedule, Notification{Events: []string{"success"}, Channels: []string{"bark"}}, task.Revision); err != nil {
		t.Fatal(err)
	}
	lock, err := manager.lockScript(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	manager.run(task.ID)
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	manager.run(task.ID)
	runs, err := manager.History(task.ID)
	if err != nil || len(runs) != 2 || runs[0].State != "success" || runs[0].Deliveries["bark"] != "backoff" || runs[1].State != "skipped" {
		t.Fatalf("unexpected run and delivery records: %+v %v", runs, err)
	}
}
