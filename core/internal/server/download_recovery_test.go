package server

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

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/downloads"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestDownloadHistoryAndLocalRecoveryWithoutAria2(t *testing.T) {
	data := t.TempDir()
	accounts, err := auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "download-owner-password"); err != nil {
		t.Fatal(err)
	}
	session, err := accounts.Login("owner", "download-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	identity, ok := accounts.Identity(session)
	if !ok {
		t.Fatal("owner session missing")
	}
	store, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	center, err := downloads.New(downloads.Options{DataDir: data, Publisher: store, CanImport: func(int64, string) bool { return true }})
	if err != nil {
		t.Fatal(err)
	}
	defer center.Close()
	if available, _ := center.Available(); available {
		t.Fatal("test must not launch aria2")
	}
	binding, err := store.DownloadRootBinding()
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(binding)
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", filepath.Join(data, "downloads.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	seed := func(id string, owner int64, phase, status string) {
		t.Helper()
		_, err := db.Exec(`INSERT INTO download_tasks(id,owner,url,destination,status,phase,root_binding,created_at,updated_at)
		 VALUES(?,?,'https://example.invalid/fixture','.',?,?,?,1,1)`, id, owner, status, phase, string(encoded))
		if err != nil {
			t.Fatal(err)
		}
	}
	seed("recover", identity.ID, "publishing", "failed")
	seed("discard", identity.ID, "publishing", "failed")
	seed("cancel", identity.ID, "download", "queued")
	seed("foreign", identity.ID+999, "download", "completed")
	seed("budget", identity.ID, "publishing", "failed")
	if _, err := db.Exec("UPDATE download_tasks SET max_bytes=4 WHERE id='budget'"); err != nil {
		t.Fatal(err)
	}
	budgetStage := filepath.Join(data, "downloads-staging", "budget")
	if err := os.MkdirAll(budgetStage, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"budget-a.bin", "budget-b.bin"} {
		if err := os.WriteFile(filepath.Join(budgetStage, name), []byte("123"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"recover", "discard"} {
		if err := os.MkdirAll(filepath.Join(data, "downloads-staging", id), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(data, "downloads-staging", id, "result.txt"), []byte("original bytes"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO download_publications(task_id,source_path,target_path,size,sha256,state,updated_at)
	 VALUES('discard','result.txt','keep.txt',1,'fixture','publishing',1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Upload("keep.txt", strings.NewReader("keep shared original")); err != nil {
		t.Fatal(err)
	}
	handler := NewWithDownloads("", accounts, store, nil, nil, nil, nil, center)
	call := func(method, path, body string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		r.Header.Set("X-LightIsle-Request", "1")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	list := call("GET", "/api/v1/downloads", "")
	if list.Code != 200 || !strings.Contains(list.Body.String(), `"recover"`) || strings.Contains(list.Body.String(), `"foreign"`) {
		t.Fatalf("offline journal visibility: %d %s", list.Code, list.Body.String())
	}
	budgetResult := call("POST", "/api/v1/downloads/budget/actions", `{"action":"retry"}`)
	if budgetResult.Code != 200 || !strings.Contains(budgetResult.Body.String(), `"error":"download_exceeds_limit"`) {
		t.Fatalf("aggregate budget not enforced: %d %s", budgetResult.Code, budgetResult.Body.String())
	}
	for _, name := range []string{"budget-a.bin", "budget-b.bin"} {
		if _, err := store.Stat(name); !os.IsNotExist(err) {
			t.Fatalf("over-budget task published %s: %v", name, err)
		}
	}
	for _, limit := range []int64{-1, (1 << 40) + 1} {
		if _, err := center.Create(identity.ID, "https://example.invalid/large", ".", limit); !errors.Is(err, downloads.ErrInput) {
			t.Fatalf("invalid budget silently became unlimited: %d %v", limit, err)
		}
	}
	for _, action := range []struct {
		id, action string
		status     int
	}{{"recover", "retry", 200}, {"cancel", "cancel", 200}} {
		res := call("POST", "/api/v1/downloads/"+action.id+"/actions", `{"action":"`+action.action+`"}`)
		if res.Code != action.status {
			t.Fatalf("%s: %d %s", action.action, res.Code, res.Body.String())
		}
		if action.id == "recover" && !strings.Contains(res.Body.String(), `"status":"completed"`) {
			t.Fatalf("local publication not completed: %s", res.Body.String())
		}
	}
	file, _, err := store.Read("result.txt")
	if err != nil {
		t.Fatal(err)
	}
	bytes, err := io.ReadAll(file)
	file.Close()
	if err != nil || string(bytes) != "original bytes" {
		t.Fatalf("recovered publication: %q %v", bytes, err)
	}
	if res := call("DELETE", "/api/v1/downloads/foreign", ""); res.Code != 404 {
		t.Fatalf("foreign task deletion = %d", res.Code)
	}
	if res := call("DELETE", "/api/v1/downloads/discard", ""); res.Code != 200 {
		t.Fatalf("discard = %d %s", res.Code, res.Body.String())
	}
	if _, err := os.Stat(filepath.Join(data, "downloads-staging", "discard")); !os.IsNotExist(err) {
		t.Fatalf("abandoned staging retained: %v", err)
	}
	var rows int
	if err := db.QueryRow("SELECT count(*) FROM download_publications WHERE task_id='discard'").Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("orphan publication journal: %d %v", rows, err)
	}
	kept, _, err := store.Read("keep.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer kept.Close()
	bytes, err = io.ReadAll(kept)
	if err != nil || string(bytes) != "keep shared original" {
		t.Fatalf("delete touched published file: %q %v", bytes, err)
	}
	if res := call("POST", "/api/v1/downloads", `{"url":"https://example.invalid/new","destination":"."}`); res.Code != 503 {
		t.Fatalf("new network download accepted without aria2: %d", res.Code)
	}
}
