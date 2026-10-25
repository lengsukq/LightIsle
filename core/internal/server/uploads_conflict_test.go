package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

// Repeated collisions always produce movie (2), movie (3), not nested suffixes.
func TestUploadConflictRenameUsesOriginalNameAndNeverOverwrites(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	session, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Mkdir("family"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"movie.txt", "movie (2).txt"} {
		if err := os.WriteFile(filepath.Join(dir, "SharedFiles", "family", name), []byte("original"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	handler := New("", accounts, store)
	call := func(body string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads", bytes.NewBufferString(body))
		req.Header.Set("X-LightIsle-Request", "1")
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		return rr
	}
	if r := call("{\"path\":\"family/movie.txt\",\"size\":4}"); r.Code != http.StatusConflict {
		t.Fatalf("default conflict should refuse: %d %s", r.Code, r.Body.String())
	}
	if r := call("{\"path\":\"family/movie.txt\",\"size\":4,\"onConflict\":\"skip\"}"); r.Code != http.StatusBadRequest {
		t.Fatalf("skip is not a supported upload policy: %d %s", r.Code, r.Body.String())
	}
	r := call("{\"path\":\"family/movie.txt\",\"size\":4,\"onConflict\":\"rename\"}")
	if r.Code != http.StatusCreated {
		t.Fatalf("rename upload: %d %s", r.Code, r.Body.String())
	}
	var result files.UploadState
	if err := json.Unmarshal(r.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Path != "family/movie (3).txt" {
		t.Fatalf("wrong collision candidate: %s", result.Path)
	}
	for _, name := range []string{"movie.txt", "movie (2).txt"} {
		data, err := os.ReadFile(filepath.Join(dir, "SharedFiles", "family", name))
		if err != nil || string(data) != "original" {
			t.Fatalf("existing file %s was altered: %q %v", name, data, err)
		}
	}
}
