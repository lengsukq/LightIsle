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
