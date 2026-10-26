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
