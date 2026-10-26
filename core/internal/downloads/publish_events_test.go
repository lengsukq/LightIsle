package downloads

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// A fully published task reports its basename exactly once; the callback is
// the outbound notification hook and must never carry a path.
func TestPublishStagedReportsTaskDoneWithBaseName(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Mkdir("dl"); err != nil {
		t.Fatal(err)
	}
	var done []string
	manager, err := New(Options{
		DataDir:    dir,
		Publisher:  newTestDownloadPublisher(store),
		CanImport:  func(int64, string) bool { return true },
		OnAlert:    func(bool) {},
		OnTaskDone: func(filename string) { done = append(done, filename) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()

	staging := manager.stagingDir("done-1")
	if err := os.MkdirAll(staging, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, "ubuntu.iso"), []byte("iso bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	binding, err := manager.opts.Publisher.DownloadRootBinding()
	if err != nil {
		t.Fatal(err)
	}
	bindingJSON, err := json.Marshal(binding)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	if _, err := manager.db.Exec(`INSERT INTO download_tasks(id,owner,url,destination,max_bytes,status,phase,root_binding,created_at,updated_at)
		VALUES('done-1',7,'https://example.org/ubuntu.iso','dl',0,'running','download',?,?,?)`,
		string(bindingJSON), now, now); err != nil {
		t.Fatal(err)
	}
	manager.importDownloadLocked("done-1")

	tasks, err := manager.List(7)
	if err != nil || len(tasks) != 1 || tasks[0].Status != StatusCompleted {
		t.Fatalf("task not completed: %+v %v", tasks, err)
	}
	if len(done) != 1 || done[0] != "ubuntu.iso" {
		t.Fatalf("OnTaskDone = %v", done)
	}
	if _, _, err := store.Read("dl/ubuntu.iso"); err != nil {
		t.Fatalf("published file missing: %v", err)
	}
}
