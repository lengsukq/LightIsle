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
	if len(templates) != 4 {
		t.Fatalf("expected 4 official templates, got %d", len(templates))
	}

	installed, err := mgr.InstallTemplate("family-subscriptions")
	if err != nil {
		t.Fatalf("InstallTemplate failed: %v", err)
	}
	if installed.ID != "family-subscriptions" || installed.PendingActivation || !installed.Valid {
		t.Fatalf("unexpected installed template app: %+v", installed)
	}

	if _, err := mgr.InstallTemplate("family-subscriptions"); !errors.Is(err, ErrAlreadyInstalled) {
		t.Fatalf("expected ErrAlreadyInstalled on duplicate install, got %v", err)
	}
}
