package apps

import (
	"errors"
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
	if len(templates) != 7 {
		t.Fatalf("expected 7 official templates, got %d", len(templates))
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

	for _, id := range []string{"medicine-expiry", "utility-ledger", "baby-growth"} {
		app, installErr := mgr.InstallTemplateAt(id, "")
		if installErr != nil {
			t.Fatalf("InstallTemplateAt(%s) failed: %v", id, installErr)
		}
		if app.ID != id || app.PendingActivation || !app.Valid {
			t.Fatalf("unexpected installed template %s: %+v", id, app)
		}
	}
}
