package dav

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInterruptedPUTPreservesOldFileAndCleansStage(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass,
		&interruptedReader{data: []byte("partial replacement")}, nil)
	if rec.Code == http.StatusCreated {
		t.Fatalf("interrupted PUT unexpectedly succeeded: %s", rec.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "in photos" {
		t.Fatalf("original changed after interrupted PUT: %q, %v", contents, err)
	}
	entries, err := os.ReadDir(filepath.Join(f.root, "photos"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("interrupted PUT left a staged artifact %q", entry.Name())
		}
	}

	rec = f.request(t, "PUT", "/dav/photos/interrupted-new.txt", f.memberName, f.memberPass,
		&interruptedReader{data: []byte("partial new file")}, nil)
	if rec.Code == http.StatusCreated {
		t.Fatalf("interrupted new-file PUT unexpectedly succeeded")
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "interrupted-new.txt")); !os.IsNotExist(err) {
		t.Errorf("interrupted PUT left a new partial target: %v", err)
	}
}

func TestPUTPublishesCompleteOverwrite(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader("complete replacement"), nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("complete overwrite status = %d: %s", rec.Code, rec.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "complete replacement" {
		t.Fatalf("overwrite contents = %q, %v", contents, err)
	}
}

func TestCopyPublishesEveryCompletedFileInDirectory(t *testing.T) {
	f, _ := newFixture(t)
	source := filepath.Join(f.root, "photos", "source")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	for name, contents := range map[string]string{"one.txt": "first", "two.txt": "second"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	rec := f.request(t, "COPY", "/dav/photos/source", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": "/dav/photos/copied", "Depth": "infinity"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("COPY directory status = %d: %s", rec.Code, rec.Body.String())
	}
	for name, want := range map[string]string{"one.txt": "first", "two.txt": "second"} {
		got, err := os.ReadFile(filepath.Join(f.root, "photos", "copied", name))
		if err != nil || string(got) != want {
			t.Errorf("copied %s = %q, %v", name, got, err)
		}
	}
}

func TestMoveFileWithinGrant(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "MOVE", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": "/dav/photos/moved.txt"})
	if rec.Code != http.StatusCreated && rec.Code != http.StatusNoContent {
		t.Fatalf("MOVE status = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "a.txt")); !os.IsNotExist(err) {
		t.Fatalf("MOVE left source in place: %v", err)
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "moved.txt"))
	if err != nil || string(contents) != "in photos" {
		t.Fatalf("MOVE destination = %q, %v", contents, err)
	}
}

func TestDeleteDirectoryMovesWholeTreeToTrash(t *testing.T) {
	f, _ := newFixture(t)
	directory := filepath.Join(f.root, "photos", "folder")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "inside.txt"), []byte("inside"), 0600); err != nil {
		t.Fatal(err)
	}
	rec := f.request(t, "DELETE", "/dav/photos/folder", f.memberName, f.memberPass, nil, nil)
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("DELETE directory status = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("directory remained after DELETE: %v", err)
	}
	if len(f.trashed) == 0 || f.trashed[len(f.trashed)-1] != "photos/folder" {
		t.Fatalf("directory trash callback = %v", f.trashed)
	}
}

func TestCopyAndMoveRefuseOverwriteWithoutChangingEitherFile(t *testing.T) {
	f, _ := newFixture(t)
	for name, contents := range map[string]string{"source.txt": "new copy", "target.txt": "old target"} {
		if err := os.WriteFile(filepath.Join(f.root, "photos", name), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, method := range []string{"COPY", "MOVE"} {
		rec := f.request(t, method, "/dav/photos/source.txt", f.memberName, f.memberPass, nil,
			map[string]string{"Destination": "/dav/photos/target.txt", "Overwrite": "T"})
		if rec.Code != http.StatusPreconditionFailed {
			t.Fatalf("%s overwrite: %d %s", method, rec.Code, rec.Body.String())
		}
	}
	for name, want := range map[string]string{"source.txt": "new copy", "target.txt": "old target"} {
		got, err := os.ReadFile(filepath.Join(f.root, "photos", name))
		if err != nil || string(got) != want {
			t.Fatalf("%s changed: %q %v", name, got, err)
		}
	}
	if len(f.trashed) != 0 {
		t.Fatalf("refused replacement sent files to the trash: %v", f.trashed)
	}
}

func TestCopySourceReadFailureNeverPublishesPartialTarget(t *testing.T) {
	f, _ := newFixture(t)
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	defer root.close()
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  "COPY",
		body:    &trackedBody{body: http.NoBody},
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	file, err := (&grantedFS{service: f.service}).OpenFile(ctx, "photos/partial-copy.txt",
		os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write([]byte("partial source bytes")); err != nil {
		t.Fatal(err)
	}
	state.noteCopyRead(errors.New("injected source read failure"))
	if err := file.Close(); err == nil {
		t.Fatal("COPY transaction committed after source read failure")
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "partial-copy.txt")); !os.IsNotExist(err) {
		t.Errorf("failed COPY left a partial destination: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(f.root, "photos"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("failed COPY left a staging artifact %q", entry.Name())
		}
	}
}

func TestFailedCopyCleansCreatedDirectoryAfterChild(t *testing.T) {
	f, _ := newFixture(t)
	if err := os.WriteFile(filepath.Join(f.root, "photos", "copy-source.txt"), []byte("copied"), 0600); err != nil {
		t.Fatal(err)
	}
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	defer root.close()
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  "COPY",
		body:    &trackedBody{body: http.NoBody},
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	fs := &grantedFS{service: f.service}
	if err := fs.Mkdir(ctx, "photos/partial-copy", 0700); err != nil {
		t.Fatal(err)
	}
	source, err := fs.OpenFile(ctx, "photos/copy-source.txt", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	target, err := fs.OpenFile(ctx, "photos/partial-copy/copied.txt",
		os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		t.Fatal(err)
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
	state.noteCopyRead(errors.New("injected later COPY failure"))
	state.cleanupCreated()
	if _, err := os.Stat(filepath.Join(f.root, "photos", "partial-copy")); !os.IsNotExist(err) {
		t.Fatalf("failed COPY left its empty destination directory: %v", err)
	}
}

func newPUTWriteTxn(t *testing.T, f *fixture) *writeTxn {
	t.Helper()
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	t.Cleanup(root.close)
	body := &trackedBody{body: http.NoBody, eof: true}
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  http.MethodPut,
		body:    body,
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	file, err := (&grantedFS{service: f.service}).OpenFile(ctx, "photos/a.txt",
		os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatal(err)
	}
	txn, ok := file.(*writeTxn)
	if !ok {
		t.Fatalf("OpenFile returned %T, want *writeTxn", file)
	}
	if _, err := txn.Write([]byte("new bytes")); err != nil {
		t.Fatal(err)
	}
	return txn
}

func TestPUTRollbackExchangeFailureRetainsOriginalStage(t *testing.T) {
	f, _ := newFixture(t)
	txn := newPUTWriteTxn(t, f)
	stageName := txn.stageName
	exchangeCalls := 0
	txn.exchangeAtFn = func(sourceName, destinationName string) error {
		exchangeCalls++
		if exchangeCalls == 2 {
			return errors.New("injected reverse exchange failure")
		}
		return exchangeAt(txn.parent, sourceName, txn.parent, destinationName)
	}
	syncCalls := 0
	txn.syncParentFn = func() error {
		syncCalls++
		if syncCalls == 1 {
			return errors.New("injected publish directory sync failure")
		}
		return nil
	}

	if err := txn.Close(); err == nil {
		t.Fatal("PUT committed after publish sync and rollback both failed")
	}
	if exchangeCalls != 2 {
		t.Fatalf("exchange calls = %d, want publish and failed rollback", exchangeCalls)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt")); err != nil || string(got) != "new bytes" {
		t.Errorf("published target = %q, %v; want complete replacement", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", stageName)); err != nil || string(got) != "in photos" {
		t.Errorf("staging recovery copy = %q, %v; want original bytes preserved", got, err)
	}
}

func TestPUTCleanupSyncFailureKeepsPublishedReplacementSuccessful(t *testing.T) {
	f, _ := newFixture(t)
	txn := newPUTWriteTxn(t, f)
	stageName := txn.stageName
	syncCalls := 0
	txn.syncParentFn = func() error {
		syncCalls++
		if syncCalls == 2 {
			return errors.New("injected post-cleanup directory sync failure")
		}
		return nil
	}

	if err := txn.Close(); err != nil {
		t.Fatalf("published PUT reported cleanup sync failure: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt")); err != nil || string(got) != "new bytes" {
		t.Errorf("published target = %q, %v; want complete replacement", got, err)
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", stageName)); !os.IsNotExist(err) {
		t.Errorf("prior-file staging entry remained after successful cleanup: %v", err)
	}
}

func TestMemberCannotFollowSymlinksAcrossGrantOrRoot(t *testing.T) {
	f, _ := newFixture(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "outside.txt"), []byte("outside secret"), 0600); err != nil {
		t.Fatal(err)
	}
	photos := filepath.Join(f.root, "photos")
	links := []struct {
		name   string
		target string
	}{
		{name: "private-link", target: filepath.Join("..", "private", "b.txt")},
		{name: "outside-link", target: filepath.Join(outside, "outside.txt")},
		{name: "private-dir", target: filepath.Join("..", "private")},
		{name: "outside-dir", target: outside},
	}
	for _, link := range links {
		if err := os.Symlink(link.target, filepath.Join(photos, link.name)); err != nil {
			t.Fatal(err)
		}
	}

	for _, target := range []string{"/dav/photos/private-link", "/dav/photos/outside-link"} {
		rec := f.request(t, "GET", target, f.memberName, f.memberPass, nil, nil)
		if rec.Code == http.StatusOK {
			t.Errorf("GET followed symlink %s", target)
		}
		rec = f.request(t, "PUT", target, f.memberName, f.memberPass, strings.NewReader("overwrite"), nil)
		if rec.Code == http.StatusCreated {
			t.Errorf("PUT followed symlink %s", target)
		}
	}
	for _, target := range []string{"/dav/photos/private-dir/b.txt", "/dav/photos/outside-dir/outside.txt"} {
		rec := f.request(t, "GET", target, f.memberName, f.memberPass, nil, nil)
		if rec.Code == http.StatusOK {
			t.Errorf("GET traversed symlink parent %s", target)
		}
		rec = f.request(t, "PUT", target, f.memberName, f.memberPass, strings.NewReader("overwrite"), nil)
		if rec.Code == http.StatusCreated {
			t.Errorf("PUT traversed symlink parent %s", target)
		}
	}

	for _, method := range []string{"PROPFIND", "DELETE", "MOVE", "COPY"} {
		target := "/dav/photos/private-link"
		headers := map[string]string{}
		if method == "MOVE" || method == "COPY" {
			headers["Destination"] = "/dav/photos/copied-link"
		}
		rec := f.request(t, method, target, f.memberName, f.memberPass, nil, headers)
		if rec.Code >= 200 && rec.Code < 300 {
			t.Errorf("%s unexpectedly accepted symlink target: %d", method, rec.Code)
		}
	}
	private, err := os.ReadFile(filepath.Join(f.root, "private", "b.txt"))
	if err != nil || string(private) != "secret" {
		t.Errorf("private target changed: %q, %v", private, err)
	}
	outsideContent, err := os.ReadFile(filepath.Join(outside, "outside.txt"))
	if err != nil || string(outsideContent) != "outside secret" {
		t.Errorf("outside target changed: %q, %v", outsideContent, err)
	}
	if _, err := os.Stat(filepath.Join(photos, "copied-link")); !os.IsNotExist(err) {
		t.Errorf("COPY/MOVE left an unauthorized result: %v", err)
	}
}

type gateReader struct {
	started chan struct{}
	resume  chan struct{}
	data    []byte
	read    bool
}

func (r *gateReader) Read(p []byte) (int, error) {
	if r.read {
		return 0, io.EOF
	}
	r.read = true
	close(r.started)
	<-r.resume
	return copy(p, r.data), nil
}

func TestDirectoryReplacementCannotRedirectPUT(t *testing.T) {
	f, _ := newFixture(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "sentinel.txt"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("do not publish")}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/raced.txt", f.memberName, f.memberPass, reader, nil)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not reach its request body")
	}
	photos := filepath.Join(f.root, "photos")
	moved := filepath.Join(f.root, "photos-original")
	if err := os.Rename(photos, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, photos); err != nil {
		t.Fatal(err)
	}
	close(reader.resume)
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not finish after releasing its body")
	}
	if rec.Code == http.StatusCreated {
		t.Fatal("PUT succeeded after its authorized parent was replaced")
	}
	if _, err := os.Stat(filepath.Join(outside, "raced.txt")); !os.IsNotExist(err) {
		t.Errorf("directory replacement redirected PUT outside the share: %v", err)
	}
	if _, err := os.Stat(filepath.Join(moved, "raced.txt")); !os.IsNotExist(err) {
		t.Errorf("PUT published under a detached directory: %v", err)
	}
	entries, err := os.ReadDir(moved)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("directory replacement left a staged artifact %q", entry.Name())
		}
	}
	if data, err := os.ReadFile(filepath.Join(outside, "sentinel.txt")); err != nil || string(data) != "keep" {
		t.Errorf("outside sentinel changed: %q, %v", data, err)
	}
}

func TestShareRootSwitchAbortsInFlightPUT(t *testing.T) {
	f, _ := newFixture(t)
	newRoot := t.TempDir()
	currentRoot := f.root
	f.service.root = func() (string, bool) { return currentRoot, true }
	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("must not publish")}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/root-switch.txt", f.memberName, f.memberPass, reader, nil)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not reach its request body")
	}
	currentRoot = newRoot
	close(reader.resume)
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not finish after the root changed")
	}
	if rec.Code == http.StatusCreated {
		t.Fatal("PUT published after the configured share root changed")
	}
	for _, target := range []string{
		filepath.Join(f.root, "photos", "root-switch.txt"),
		filepath.Join(newRoot, "photos", "root-switch.txt"),
	} {
		if _, err := os.Stat(target); !os.IsNotExist(err) {
			t.Errorf("root switch left a target at %s: %v", target, err)
		}
	}
}

func TestPUTConditionsAreCheckedBeforeAndDuringPublication(t *testing.T) {
	f, _ := newFixture(t)
	oldInfo, err := os.Stat(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil {
		t.Fatal(err)
	}
	wrong := map[string]string{"If-Match": `"not-current"`}
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader("no"), wrong)
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("stale If-Match status = %d", rec.Code)
	}
	ifNone := map[string]string{"If-None-Match": "*"}
	rec = f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader("no"), ifNone)
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("If-None-Match wildcard status = %d", rec.Code)
	}

	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("stale conditional body")}
	headers := map[string]string{"If-Match": davETag(oldInfo)}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, reader, headers)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("conditional PUT did not reach its body")
	}
	if err := os.WriteFile(filepath.Join(f.root, "photos", "a.txt"), []byte("external update"), 0600); err != nil {
		t.Fatal(err)
	}
	close(reader.resume)
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("conditional PUT did not finish")
	}
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("If-Match changed during upload status = %d", rec.Code)
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "external update" {
		t.Fatalf("conditional PUT overwrote changed target: %q, %v", contents, err)
	}
}

func TestReadOnlyGrantCannotLockAndLockOwnerPathIsEnforced(t *testing.T) {
	f, _ := newFixture(t)
	adminSession, err := f.service.store.Login("boss", "correct-horse-1")
	if err != nil {
		t.Fatal(err)
	}
	users, err := f.service.store.ListUsers(adminSession)
	if err != nil {
		t.Fatal(err)
	}
	var memberID int64
	for _, user := range users {
		if user.Username == "leo" {
			memberID = user.ID
		}
	}
	if memberID == 0 {
		t.Fatal("member not found")
	}
	if err := f.service.store.SetFileGrant(adminSession, memberID, "photos", false); err != nil {
		t.Fatal(err)
	}
	lockBody := `<?xml version="1.0"?><d:lockinfo xmlns:d="DAV:"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype><d:owner>qa</d:owner></d:lockinfo>`
	rec := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader(lockBody), map[string]string{"Timeout": "Second-600"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("read-only grant LOCK status = %d", rec.Code)
	}
	if err := f.service.store.SetFileGrant(adminSession, memberID, "photos", true); err != nil {
		t.Fatal(err)
	}
	rec = f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader(lockBody), map[string]string{"Timeout": "Second-600"})
	if rec.Code != http.StatusOK {
		t.Fatalf("writable member LOCK status = %d: %s", rec.Code, rec.Body.String())
	}
	token := rec.Header().Get("Lock-Token")
	if token == "" {
		t.Fatal("LOCK response missing token")
	}
	if err := os.WriteFile(filepath.Join(f.root, "photos", "other.txt"), []byte("other"), 0600); err != nil {
		t.Fatal(err)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/other.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("wrong-path UNLOCK status = %d", rec.Code)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.adminName, f.adminPassword, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other-account UNLOCK status = %d", rec.Code)
	}
	rec = f.request(t, "LOCK", "/dav/photos/a.txt", f.adminName, f.adminPassword, nil,
		map[string]string{"If": "(<" + strings.Trim(token, "<>") + ">)", "Timeout": "Second-600"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other-account lock refresh status = %d", rec.Code)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("owner UNLOCK status = %d", rec.Code)
	}
}

func TestDAVLocksHavePerAccountLimitAndExpire(t *testing.T) {
	f, _ := newFixture(t)
	lockBody := `<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>`
	for i := 0; i <= maxDAVLocksPerUser; i++ {
		path := fmt.Sprintf("/dav/photos/lock-%03d", i)
		got := f.request(t, "LOCK", path, f.memberName, f.memberPass, strings.NewReader(lockBody),
			map[string]string{"Timeout": "Infinite", "Depth": "0"})
		if i == maxDAVLocksPerUser {
			if got.Code != http.StatusLocked {
				t.Fatalf("over-budget LOCK returned %d: %s", got.Code, got.Body.String())
			}
			break
		}
		if got.Code != http.StatusCreated || !strings.Contains(got.Body.String(), "Second-1800") {
			t.Fatalf("LOCK returned %d without finite expiration: %s", got.Code, got.Body.String())
		}
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", fmt.Sprintf("lock-%03d", maxDAVLocksPerUser))); !os.IsNotExist(err) {
		t.Fatalf("over-budget LOCK created a file: %v", err)
	}
	ns := f.service.lockNS
	ns.mu.Lock()
	defer ns.mu.Unlock()
	ns.cleanupExpiredLocked(time.Now().Add(time.Hour))
	if len(ns.owners) != 0 {
		t.Fatalf("expired locks retained: %d", len(ns.owners))
	}
}

func TestDAVLockCannotBeBypassedByCaseAlias(t *testing.T) {
	f, _ := newFixture(t)
	lockBody := `<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>`
	got := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader(lockBody), nil)
	if got.Code != http.StatusOK {
		t.Fatalf("LOCK: %d %s", got.Code, got.Body.String())
	}
	got = f.request(t, http.MethodPut, "/dav/photos/A.TXT", f.adminName, f.adminPassword, strings.NewReader("replacement"), nil)
	if got.Code != http.StatusLocked {
		t.Fatalf("case alias write bypassed lock: %d %s", got.Code, got.Body.String())
	}
}
