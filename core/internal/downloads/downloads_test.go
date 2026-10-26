package downloads

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func TestInterruptedPublicationVerifiesExistingBytesWithoutMakingDuplicates(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Mkdir("dl"); err != nil {
		t.Fatal(err)
	}
	publisher := newTestDownloadPublisher(store).(*testDownloadPublisher)
	manager, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()

	bindingJSON, err := json.Marshal(publisher.binding)
	if err != nil {
		t.Fatal(err)
	}
	_, err = manager.db.Exec("INSERT INTO download_tasks(id,owner,url,destination,max_bytes,status,phase,root_binding,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
		"crash-1", 7, "https://example.org/movie.txt", "dl", 0, StatusFailed, phasePublishing, string(bindingJSON), 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(dir, "movie.txt")
	if err := os.WriteFile(source, []byte("original bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	size, digest, err := hashStaged(source)
	if err != nil {
		t.Fatal(err)
	}
	task := Task{ID: "crash-1", Owner: 7, Destination: "dl", Phase: phasePublishing,
		rootBinding: publisher.binding, rootBound: true}
	target, err := manager.publishOne(task, "movie.txt", source, "dl/movie.txt", size, digest)
	if err != nil || target != "dl/movie.txt" {
		t.Fatalf("first publication: %q %v", target, err)
	}
	// Simulate a process crash after the file is durably published but
	// before the publication journal transitions to "published".
	_, err = manager.db.Exec("UPDATE download_publications SET state='publishing' WHERE task_id='crash-1'")
	if err != nil {
		t.Fatal(err)
	}
	target, err = manager.publishOne(task, "movie.txt", source, "dl/movie.txt", size, digest)
	if err != nil || target != "dl/movie.txt" {
		t.Fatalf("crash recovery: %q %v", target, err)
	}
	if _, _, err = store.Read("dl/movie (2).txt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("retry must not produce a duplicate copy: %v", err)
	}
	if err := os.WriteFile(source, []byte("corrupted bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	changedSize, changedDigest, err := hashStaged(source)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.publishOne(task, "movie.txt", source, "dl/movie.txt", changedSize, changedDigest); !errors.Is(err, errRecoveryRequired) {
		t.Fatalf("changed source must not silently replace a published file: %v", err)
	}
}

// The production publisher is a files.Manager with a durable physical-root
// binding. Isolated Store tests use this deterministic narrow contract.
type testDownloadPublisher struct {
	store   *files.Store
	binding storageidentity.Binding
}

func newTestDownloadPublisher(store *files.Store) Publisher {
	return &testDownloadPublisher{
		store: store,
		binding: storageidentity.Binding{
			Path: "/test/share", VolumeUUID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
			DirectoryID: 1, BirthSec: 1,
		},
	}
}

func (p *testDownloadPublisher) DownloadRootBinding() (storageidentity.Binding, error) {
	return p.binding, nil
}

func (p *testDownloadPublisher) PublishDownload(expected storageidentity.Binding, target string, source io.Reader, beforeCommit func() error) (int64, error) {
	if expected != p.binding {
		return 0, files.ErrDownloadRootChanged
	}
	if err := beforeCommit(); err != nil {
		return 0, err
	}
	return p.store.Upload(target, source)
}

func (p *testDownloadPublisher) InspectDownload(expected storageidentity.Binding, target string, inspect func(io.Reader, int64) error) error {
	if expected != p.binding {
		return files.ErrDownloadRootChanged
	}
	f, info, err := p.store.Read(target)
	if err != nil {
		return err
	}
	defer f.Close()
	return inspect(f, info.Size())
}

func testOptions(t *testing.T, dataDir string, publisher *files.Store) Options {
	t.Helper()
	return Options{
		DataDir:   dataDir,
		Publisher: newTestDownloadPublisher(publisher),
		CanImport: func(int64, string) bool { return true },
		OnAlert:   func(bool) {},
	}
}

func TestValidateURLProtocolAllowlist(t *testing.T) {
	valid := []string{
		"https://example.com/file.iso",
		"http://example.com:8080/a/b.zip",
		"ftp://mirror.example.org/pub/data.tar",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
		"magnet:?xt=urn:btih:MPC2H7UJHWT6JFG3FGWIHXOIVD4BH7UI&dn=ubuntu",
	}
	for _, url := range valid {
		if err := ValidateURL(url); err != nil {
			t.Errorf("valid URL rejected: %s (%v)", url, err)
		}
	}
	invalid := []string{
		"file:///etc/passwd",
		"data:text/html,hello",
		"ftp://user:pass@example.com/f", // credentials never reach the journal
		"magnet:?xt=urn:btih:SHORT",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567/../../etc",
		"http://" + strings.Repeat("a", 2048) + ".example.com",
		"smb://nas/share",
		"javascript:alert(1)",
		"",
	}
	for _, url := range invalid {
		if err := ValidateURL(url); err == nil {
			t.Errorf("invalid URL accepted: %s", url)
		}
	}
}

func TestValidateDestinationStaysInsideShare(t *testing.T) {
	for _, destination := range []string{".", "Downloads", "media/iso"} {
		if err := ValidateDestination(destination); err != nil {
			t.Errorf("valid destination rejected: %s", destination)
		}
	}
	for _, destination := range []string{"", "/etc", "..", "a/../b", "a//b", `a\b`} {
		if err := ValidateDestination(destination); err == nil {
			t.Errorf("invalid destination accepted: %q", destination)
		}
	}
}

func TestManagerHonestWithoutBinary(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	manager, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if available, reason := manager.Available(); available || reason != "aria2_not_installed" {
		t.Fatalf("availability = %v %q", available, reason)
	}
	if _, err := manager.Create(1, "https://example.com/x", ".", 0); !errors.Is(err, ErrNotAvailable) {
		t.Fatalf("create without binary = %v", err)
	}
}

func TestRestartRetiresInFlightTasksHonestly(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", filepath.Join(dir, "downloads.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO download_tasks(id,owner,url,destination,max_bytes,status,gid,created_at,updated_at)
		VALUES('task-1',1,'https://example.com/x','.',0,'running','gid-1',1,1)`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	tasks, err := second.List(1)
	if err != nil || len(tasks) != 1 {
		t.Fatalf("list after restart: %+v %v", tasks, err)
	}
	if tasks[0].Status != StatusFailed || tasks[0].Error != ErrRootUnbound.Error() {
		t.Fatalf("legacy task without a verified physical-root binding must not resume: %+v", tasks[0])
	}
}

func realAria2Path(t *testing.T) string {
	t.Helper()
	for _, candidate := range []string{"/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	t.Skip("Homebrew aria2c not installed; run brew install aria2 to exercise this test")
	return ""
}

// TestRealAria2DownloadLifecycle runs the full pipeline against the actual
// Homebrew aria2c: create → download from a local HTTP server → publish
// through the safe file API (with conflict rename) → cancel a slow task.
func TestRealAria2DownloadLifecycle(t *testing.T) {
	binary := realAria2Path(t)
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Mkdir("dl"); err != nil {
		t.Fatal(err)
	}
	payload := strings.Repeat("lightisle-download-payload\n", 512)
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, payload)
	}))
	defer source.Close()
	slow := make(chan struct{})
	slowServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-slow
	}))
	defer slowServer.Close()
	// LIFO: the channel must release the stalled handler before the test
	// server's Close() waits on it, or the cleanup itself deadlocks.
	defer close(slow)

	manager, err := New(Options{
		DataDir:   dir,
		Binary:    binary,
		Publisher: newTestDownloadPublisher(store),
		CanImport: func(int64, string) bool { return true },
		OnAlert:   func(bool) {},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if err := manager.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor := func(id string, status string) Task {
		t.Helper()
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			tasks, listErr := manager.List(7)
			if listErr != nil {
				t.Fatal(listErr)
			}
			for _, task := range tasks {
				if task.ID == id {
					if task.Status == status {
						return task
					}
					if task.Status == StatusFailed {
						t.Fatalf("task %s failed early: %+v", id, task)
					}
				}
			}
			time.Sleep(300 * time.Millisecond)
		}
		t.Fatalf("task %s never reached %s", id, status)
		return Task{}
	}

	task, err := manager.Create(7, source.URL+"/payload.bin", "dl", 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	if done := waitFor(task.ID, StatusCompleted); done.Filename != "payload.bin" {
		t.Fatalf("unexpected filename: %+v", done)
	}
	handle, info, err := store.Read("dl/payload.bin")
	if err != nil {
		t.Fatalf("published file missing: %v", err)
	}
	content, readErr := io.ReadAll(handle)
	handle.Close()
	if readErr != nil || string(content) != payload || info.Size() != int64(len(payload)) {
		t.Fatal("published payload mismatch")
	}

	// A second identical download must not overwrite the first.
	again, err := manager.Create(7, source.URL+"/payload.bin", "dl", 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(again.ID, StatusCompleted)
	if _, _, err := store.Read("dl/payload (2).bin"); err != nil {
		t.Fatalf("conflict rename missing: %v", err)
	}

	// Grant revocation must stop the import, not smuggle files in.
	revoked, err := manager.Create(7, source.URL+"/revoked.bin", "dl", 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	manager.opts.CanImport = func(int64, string) bool { return false }
	waitFor(revoked.ID, StatusFailed)

	// A slow download can be cancelled mid-flight.
	stalled, err := manager.Create(7, slowServer.URL+"/stalled.bin", "dl", 0)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(stalled.ID, StatusRunning)
	cancelled, err := manager.Cancel(7, stalled.ID)
	if err != nil || cancelled.Status != StatusCancelled {
		t.Fatalf("cancel = %+v %v", cancelled, err)
	}
	if _, err := manager.Action(7, stalled.ID, "retry"); err != nil {
		t.Fatalf("retry after cancel: %v", err)
	}
	if err := manager.Delete(7, stalled.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if tasks, _ := manager.List(7); len(tasks) != 3 {
		t.Fatalf("journal should keep three terminal tasks, got %+v", tasks)
	}
}
