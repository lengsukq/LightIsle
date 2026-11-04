package rootmigration

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMigrationPrivateJournalSurvivesRestartAsInterrupted(t *testing.T) {
	base := t.TempDir()
	s := NewWithStateDir(nil, base)
	s.mu.Lock()
	s.state = Status{
		Phase: "running", CopiedFiles: 4, CopiedBytes: 1234, StartedAt: 123,
		Preview: Preview{Selection: Selection{SourceRootID: "old", SourceGeneration: 1,
			TargetRootID: "new", TargetGeneration: 2}},
	}
	s.persistLocked()
	s.mu.Unlock()
	info, err := os.Stat(filepath.Join(base, "root-migration-status.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("migration status exposes filenames or identities to other local users: %s", info.Mode().Perm())
	}
	restored := NewWithStateDir(nil, base).Status()
	if restored.Phase != "interrupted" || restored.CopiedFiles != 4 ||
		restored.CopiedBytes != 1234 || restored.Error != "migration_interrupted_by_restart" ||
		restored.Preview.TargetRootID != "new" {
		t.Fatalf("partial migration restarted as success or lost progress: %+v", restored)
	}
}

func TestMigrationPreviewStatusRecoversAfterRestart(t *testing.T) {
	base := t.TempDir()
	s := NewWithStateDir(nil, base)
	s.mu.Lock()
	s.state = Status{Phase: "previewing", StartedAt: 99}
	s.persistLocked()
	s.mu.Unlock()
	if got := NewWithStateDir(nil, base).Status(); got.Phase != "interrupted" {
		t.Fatalf("preview interrupted by exit was reported as complete: %+v", got)
	}
}
