package automation

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAgentEmailTemplateContentAndCustomModes(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "report", "echo done", true)
	taskPath := filepath.Join(dir, "task.json")
	original, err := os.ReadFile(taskPath)
	if err != nil {
		t.Fatal(err)
	}
	var task Task
	if err = json.Unmarshal(original, &task); err != nil {
		t.Fatal(err)
	}
	task.Name = "报表 <安全>"
	task.Notification.Email = &EmailTemplate{Mode: "content", File: "email.html", Subject: "执行结果"}
	raw, _ := json.Marshal(task)
	if err = os.WriteFile(taskPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "email.html"), []byte("<section>{{task.name}} / {{run.message}} / {{run.exitCode}}</section>"), 0600); err != nil {
		t.Fatal(err)
	}
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	html, err := m.renderTaskEmail(task, "success", 0, time.Unix(60, 0))
	if err != nil {
		t.Fatal(err)
	}
	if html != "<section>报表 &lt;安全&gt; / 执行成功 / 0</section>" {
		t.Fatalf("content template=%s", html)
	}
	// Changing scheduling through Web must preserve the Agent-owned email block.
	if err = m.Update("report", false, task.Schedule, Notification{Channels: []string{"email"}, Events: []string{"failure"}}); err != nil {
		t.Fatal(err)
	}
	updated, err := os.ReadFile(taskPath)
	if err != nil {
		t.Fatal(err)
	}
	var doc Task
	if err = json.Unmarshal(updated, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Notification.Email == nil || doc.Notification.Email.Mode != "content" || doc.Notification.Email.File != "email.html" {
		t.Fatalf("web wiped local email template: %+v", doc.Notification.Email)
	}
	doc.Notification.Email.Mode = "custom"
	full, _ := json.Marshal(doc)
	if err = os.WriteFile(taskPath, full, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "email.html"), []byte("<!doctype html><html><body>{{run.state}}</body></html>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = m.Reload(); err != nil {
		t.Fatal(err)
	}
	html, err = m.renderTaskEmail(doc, "failure", 2, time.Now())
	if err != nil || !strings.Contains(html, "<body>failure</body>") {
		t.Fatalf("custom template: %s %v", html, err)
	}
}

func TestEmailModeOnlyChangesThroughLocalTaskJSON(t *testing.T) {
	base := t.TempDir()
	firstDir := createTask(t, base, "agent-first", "echo first", false)
	secondDir := createTask(t, base, "agent-second", "echo second", false)
	firstPath := filepath.Join(firstDir, "task.json")
	raw, err := os.ReadFile(firstPath)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	doc["notification"] = map[string]any{
		"events": []string{"failure"}, "channels": []string{"email"},
		"agentExtra": "keep", "email": map[string]any{
			"mode": "content", "file": "email.html", "subject": "日报", "agentFlag": "keep",
		},
	}
	data, _ := json.Marshal(doc)
	if err := os.WriteFile(firstPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(firstDir, "email.html"), []byte("<p>content</p>"), 0600); err != nil {
		t.Fatal(err)
	}
	m, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	// The HTTP task editor must ignore attempts to send an email template.
	if err := m.Update("agent-first", true, Schedule{Cron: "30 3 * * *", Timezone: "UTC"},
		Notification{Events: []string{"failure", "timeout"}, Channels: []string{"email"},
			Email: &EmailTemplate{Mode: "custom", File: "forged.html", Subject: "override"}}); err != nil {
		t.Fatal(err)
	}
	updated, err := os.ReadFile(firstPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(updated, &doc); err != nil {
		t.Fatal(err)
	}
	note := doc["notification"].(map[string]any)
	email := note["email"].(map[string]any)
	if note["agentExtra"] != "keep" || email["mode"] != "content" ||
		email["file"] != "email.html" || email["subject"] != "日报" || email["agentFlag"] != "keep" {
		t.Fatalf("Web modified Agent-owned email settings: %+v", note)
	}
	secondJSON, err := os.ReadFile(filepath.Join(secondDir, "task.json"))
	if err != nil {
		t.Fatal(err)
	}
	var second Task
	if err := json.Unmarshal(secondJSON, &second); err != nil {
		t.Fatal(err)
	}
	if second.Notification.Email != nil {
		t.Fatal("changed unrelated script template")
	}
	// The local Agent *can* change only this script's mode by editing task.json.
	email["mode"] = "custom"
	data, _ = json.Marshal(doc)
	if err := os.WriteFile(firstPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.Reload(); err != nil {
		t.Fatal(err)
	}
	for _, item := range m.List() {
		if item.ID == "agent-first" && (item.Notification.Email == nil || item.Notification.Email.Mode != "custom") {
			t.Fatalf("local task.json mode was not reloaded: %+v", item)
		}
		if item.ID == "agent-second" && item.Notification.Email != nil {
			t.Fatalf("unrelated task inherited template: %+v", item)
		}
	}
}

func TestAgentDeletedEmailFileFallsBackToBrandedTemplate(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "vanishing-mail", "echo done", true)
	content, _ := os.ReadFile(filepath.Join(dir, "task.json"))
	var task Task
	if err := json.Unmarshal(content, &task); err != nil {
		t.Fatal(err)
	}
	task.Notification.Email = &EmailTemplate{Mode: "content", File: "email.html"}
	task.Notification.Events = []string{"success"}
	task.Notification.Channels = []string{"email"}
	updated, _ := json.Marshal(task)
	if err := os.WriteFile(filepath.Join(dir, "task.json"), updated, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "email.html"), []byte("<div>Hello</div>"), 0600); err != nil {
		t.Fatal(err)
	}
	notified := false
	m, err := New(base, func(delivered Task, state string, _ time.Time, _ int, html string) {
		notified = true
		if state != "success" || html != "" || delivered.Notification.Email == nil || delivered.Notification.Email.Mode != "builtin" || delivered.LastError == "" {
			t.Errorf("incorrect HTML failure fallback: %+v %q", delivered, html)
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	// Simulate the user removing a script-owned file after page refresh.
	if err := os.Remove(filepath.Join(dir, "email.html")); err != nil {
		t.Fatal(err)
	}
	m.run("vanishing-mail")
	if !notified {
		t.Fatal("missing custom template suppressed notification")
	}
}

func TestEmailTemplatesRejectTraversalAndOversized(t *testing.T) {
	base := t.TempDir()
	dir := createTask(t, base, "template", "echo test", true)
	raw, _ := os.ReadFile(filepath.Join(dir, "task.json"))
	var task Task
	if err := json.Unmarshal(raw, &task); err != nil {
		t.Fatal(err)
	}
	task.Notification.Email = &EmailTemplate{Mode: "custom", File: "../outside.html"}
	if err := validateTask(task, task.ID); err == nil {
		t.Fatal("accepted traversal HTML file")
	}
	task.Notification.Email.File = "custom.html"
	if err := os.WriteFile(filepath.Join(dir, "custom.html"), []byte(strings.Repeat("A", maxEmailTemplate+1)), 0600); err != nil {
		t.Fatal(err)
	}
	updated, _ := json.Marshal(task)
	if err := os.WriteFile(filepath.Join(dir, "task.json"), updated, 0600); err != nil {
		t.Fatal(err)
	}
	manager, err := New(base, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	tasks := manager.List()
	if len(tasks) != 1 || tasks[0].Enabled || tasks[0].LastError == "" {
		t.Fatalf("oversized HTML template accepted %+v", tasks)
	}
}
