//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

func TestHandleAppsIPCAutomationLifecycleAndPreservesEmail(t *testing.T) {
	dataDir := t.TempDir()
	scriptDir := filepath.Join(dataDir, "automation", "scripts", "daily-check")
	if err := os.MkdirAll(scriptDir, 0700); err != nil {
		t.Fatal(err)
	}
	scriptBody := "#!/bin/sh\necho 'ok'\n"
	if err := os.WriteFile(filepath.Join(scriptDir, "run.sh"), []byte(scriptBody), 0700); err != nil {
		t.Fatal(err)
	}
	emailHTML := "<p>{{task.name}} - {{run.state}}</p>"
	if err := os.WriteFile(filepath.Join(scriptDir, "email.html"), []byte(emailHTML), 0600); err != nil {
		t.Fatal(err)
	}
	taskJSON := `{
  "schemaVersion": 1,
  "id": "daily-check",
  "name": "每日巡检",
  "description": "检查存储与备份状态",
  "enabled": false,
  "entry": "run.sh",
  "schedule": {"cron": "0 8 * * *", "timezone": "Asia/Shanghai"},
  "timeoutSeconds": 60,
  "notification": {
    "events": ["failure"],
    "channels": ["email"],
    "email": {"mode": "content", "file": "email.html", "subject": "巡检报告"}
  }
}`
	if err := os.WriteFile(filepath.Join(scriptDir, "task.json"), []byte(taskJSON), 0600); err != nil {
		t.Fatal(err)
	}

	// Register a plugin cron task to ensure it is excluded from standalone AutomationTasks.
	pluginDir := filepath.Join(dataDir, "plugins", "demo-plug")
	if err := os.MkdirAll(pluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "run-cron.sh"), []byte("#!/bin/sh\necho plug\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte(`{"id":"demo-plug"}`), 0600); err != nil {
		t.Fatal(err)
	}

	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()
	if err := autoMgr.SyncPluginTasks([]automation.PluginCronRegistration{{
		PluginID:  "demo-plug",
		PluginDir: pluginDir,
		Spec: automation.TaskSpec{
			Name:     "插件任务",
			Enabled:  true,
			Entry:    "run-cron.sh",
			Schedule: automation.Schedule{Cron: "*/5 * * * *", Timezone: "Asia/Shanghai"},
		},
	}}); err != nil {
		t.Fatal(err)
	}

	ov := buildNativeAppsOverview(nil, autoMgr, nil)
	if ov.AutomationScriptsDir != filepath.Join(dataDir, "automation", "scripts") {
		t.Fatalf("unexpected automationScriptsDir: %q", ov.AutomationScriptsDir)
	}
	if len(ov.AutomationTasks) != 1 || ov.AutomationTasks[0].ID != "daily-check" {
		t.Fatalf("expected only standalone script task daily-check, got %+v", ov.AutomationTasks)
	}
	if ov.AutomationTasks[0].Notification.Email != nil {
		t.Fatalf("expected public task email config to remain hidden, got %+v", ov.AutomationTasks[0].Notification.Email)
	}
	rev := ov.AutomationTasks[0].Revision

	// Update via handleAppsIPC and verify stdout envelope + email template preservation.
	encodeReq := func(req appsIPCRequest) string {
		raw, _ := json.Marshal(req)
		return base64.RawURLEncoding.EncodeToString(raw)
	}

	runIPC := func(op string, req appsIPCRequest) map[string]any {
		oldOut := os.Stdout
		r, w, pipeErr := os.Pipe()
		if pipeErr != nil {
			t.Fatal(pipeErr)
		}
		os.Stdout = w
		handled := handleAppsIPC(context.Background(), "apps "+op+" "+encodeReq(req), nil, autoMgr, nil)
		_ = w.Close()
		os.Stdout = oldOut
		if !handled {
			t.Fatalf("expected handleAppsIPC to handle %s", op)
		}
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(r)
		_ = r.Close()
		line := strings.TrimSpace(buf.String())
		const prefix = "LIGHTISLE_APPS "
		if !strings.HasPrefix(line, prefix) {
			t.Fatalf("unexpected IPC line for %s: %q", op, line)
		}
		payloadRaw, decErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(line, prefix))
		if decErr != nil {
			t.Fatal(decErr)
		}
		var env map[string]any
		if jsonErr := json.Unmarshal(payloadRaw, &env); jsonErr != nil {
			t.Fatal(jsonErr)
		}
		return env
	}

	updateEnv := runIPC("automation-update", appsIPCRequest{
		RequestID:        "req-upd-1",
		AutomationTaskID: "daily-check",
		AutomationUpdate: &nativeAutomationUpdateRequest{
			Enabled:  true,
			Revision: rev,
			Schedule: automation.Schedule{Cron: "15 9 * * *", Timezone: "Asia/Shanghai"},
			Notification: automation.Notification{
				Events:   []string{"success", "failure"},
				Channels: []string{"bark"},
			},
		},
	})
	if errVal, _ := updateEnv["error"].(string); errVal != "" {
		t.Fatalf("automation-update failed: %s", errVal)
	}
	diskRaw, err := os.ReadFile(filepath.Join(scriptDir, "task.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(diskRaw), `"mode": "content"`) || !strings.Contains(string(diskRaw), `"subject": "巡检报告"`) {
		t.Fatalf("expected task.json email block preserved, got:\n%s", string(diskRaw))
	}

	// Stale revision should return friendly Chinese conflict error.
	staleEnv := runIPC("automation-update", appsIPCRequest{
		RequestID:        "req-upd-stale",
		AutomationTaskID: "daily-check",
		AutomationUpdate: &nativeAutomationUpdateRequest{
			Enabled:  false,
			Revision: rev, // old revision
			Schedule: automation.Schedule{Cron: "15 9 * * *", Timezone: "Asia/Shanghai"},
		},
	})
	if errVal, _ := staleEnv["error"].(string); errVal == "" {
		t.Fatal("expected stale revision error")
	}

	// Trigger immediate run and confirm runs history captures it.
	runEnv := runIPC("automation-run", appsIPCRequest{
		RequestID:        "req-run-1",
		AutomationTaskID: "daily-check",
	})
	if errVal, _ := runEnv["error"].(string); errVal != "" {
		t.Fatalf("automation-run failed: %s", errVal)
	}
	deadline := time.Now().Add(3 * time.Second)
	var runsList []any
	for time.Now().Before(deadline) {
		runsEnv := runIPC("automation-runs", appsIPCRequest{
			RequestID:        "req-runs",
			AutomationTaskID: "daily-check",
		})
		res, _ := runsEnv["result"].(map[string]any)
		ar, _ := res["automationRuns"].(map[string]any)
		runs, _ := ar["runs"].([]any)
		if len(runs) > 0 {
			first, _ := runs[0].(map[string]any)
			if st, _ := first["state"].(string); st == "success" {
				runsList = runs
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(runsList) == 0 {
		t.Fatal("expected completed automation run in history")
	}

	// Delete removes the task directory.
	delEnv := runIPC("automation-delete", appsIPCRequest{
		RequestID:        "req-del-1",
		AutomationTaskID: "daily-check",
	})
	if errVal, _ := delEnv["error"].(string); errVal != "" {
		t.Fatalf("automation-delete failed: %s", errVal)
	}
	if _, statErr := os.Stat(scriptDir); !os.IsNotExist(statErr) {
		t.Fatalf("expected script directory to be deleted, stat err=%v", statErr)
	}
}
