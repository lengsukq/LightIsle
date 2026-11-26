package apps

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuiltInOfficialTemplates(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	templates := mgr.ListTemplates()
	if len(templates) != 10 {
		t.Fatalf("expected 10 official templates, got %d", len(templates))
	}

	installed, err := mgr.InstallTemplateAt("family-subscriptions", "")
	if err != nil {
		t.Fatalf("InstallTemplateAt failed: %v", err)
	}
	if installed.ID != "family-subscriptions" || installed.PendingActivation || !installed.Valid {
		t.Fatalf("unexpected installed template app: %+v", installed)
	}

	if _, err := mgr.InstallTemplateAt("family-subscriptions", ""); !errors.Is(err, ErrAlreadyInstalled) {
		t.Fatalf("expected ErrAlreadyInstalled on duplicate install, got %v", err)
	}

	reminderTemplates := map[string]bool{
		"family-subscriptions": true,
		"warranty-vault":       true,
		"medicine-expiry":      true,
		"weekly-menu":          true,
		"pet-care":             true,
	}

	allFamilyIDs := []string{
		"warranty-vault",
		"family-board",
		"medicine-expiry",
		"utility-ledger",
		"baby-growth",
		"house-info",
		"weekly-menu",
		"pet-care",
	}
	for _, id := range allFamilyIDs {
		app, installErr := mgr.InstallTemplateAt(id, "")
		if installErr != nil {
			t.Fatalf("InstallTemplateAt(%s) failed: %v", id, installErr)
		}
		if app.ID != id || app.PendingActivation || !app.Valid {
			t.Fatalf("unexpected installed template %s: %+v", id, app)
		}
	}

	for _, id := range append([]string{"family-subscriptions"}, allFamilyIDs...) {
		htmlPath := filepath.Join(dataDir, "plugins", id, "ui", "index.html")
		raw, readErr := os.ReadFile(htmlPath)
		if readErr != nil {
			t.Fatalf("read index.html for %s: %v", id, readErr)
		}
		html := string(raw)
		if strings.Contains(html, templateSharedCSSPlaceholder) || strings.Contains(html, templateSharedJSPlaceholder) {
			t.Fatalf("template %s has unresolved shared placeholder", id)
		}
		if !strings.Contains(html, "LightIsleKV.createStore") || !strings.Contains(html, "./__lightisle_kv/") {
			t.Fatalf("template %s missing LightIsleKV host bridge integration", id)
		}
		if reminderTemplates[id] && !strings.Contains(html, "buildReminders") {
			t.Fatalf("template %s expected buildReminders integration for _reminders", id)
		}
	}

	spec, ok := ReadSpecResource("lightisle://specs/plugin-v2")
	if !ok || !strings.Contains(spec, "/__lightisle_kv") || !strings.Contains(spec, "_reminders") {
		t.Fatalf("expected plugin-v2 spec to document __lightisle_kv and _reminders")
	}
}
