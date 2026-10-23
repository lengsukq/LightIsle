package server

import (
	"archive/zip"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestFolderArchiveRequiresAccessAndExportsOnlySharedFiles(t *testing.T) {
	root := t.TempDir()
	accounts, err := auth.Open(filepath.Join(root, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	store, err := files.Open(filepath.Join(root, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := accounts.Setup("owner", "strong-password-owner"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "strong-password-owner")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "family-user", "strong-password-member", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	guest, err := accounts.Login("family-user", "strong-password-member")
	if err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"family", "family/子目录", "family/空文件夹", "secret"} {
		if err := store.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	for file, content := range map[string]string{
		"family/子目录/note.txt": "hello",
		"family/中文.txt":       "你好",
		"secret/private.txt":  "never export",
	} {
		if _, err := store.Upload(file, strings.NewReader(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := accounts.SetFileGrant(admin, member.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	h := New("", accounts, store)
	call := func(url, session string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, url, nil)
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	for _, tc := range []struct {
		url, session string
		status       int
	}{
		{"/api/v1/files/archive?path=family", "", 401},
		{"/api/v1/files/archive?path=secret", guest, 403},
		{"/api/v1/files/archive?path=.", admin, 400},
		{"/api/v1/files/archive?path=absent", admin, 404},
	} {
		if w := call(tc.url, tc.session); w.Code != tc.status {
			t.Fatalf("%s: %d %s", tc.url, w.Code, w.Body.String())
		}
	}
	w := call("/api/v1/files/archive?path=family", guest)
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("archive: %d %s", w.Code, w.Body.String())
	}
	reader, err := zip.NewReader(bytes.NewReader(w.Body.Bytes()), int64(w.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, item := range reader.File {
		if strings.HasPrefix(item.Name, "/") || strings.Contains(item.Name, "..") {
			t.Fatalf("unsafe archive name: %q", item.Name)
		}
		if item.FileInfo().IsDir() {
			got[item.Name] = "(directory)"
			continue
		}
		f, err := item.Open()
		if err != nil {
			t.Fatal(err)
		}
		content, readErr := io.ReadAll(f)
		closeErr := f.Close()
		if readErr != nil || closeErr != nil {
			t.Fatalf("read %q: %v %v", item.Name, readErr, closeErr)
		}
		got[item.Name] = string(content)
	}
	for key, expected := range map[string]string{
		"family/":             "(directory)",
		"family/子目录/":         "(directory)",
		"family/空文件夹/":        "(directory)",
		"family/子目录/note.txt": "hello",
		"family/中文.txt":       "你好",
	} {
		if got[key] != expected {
			t.Fatalf("archive entry %q = %q; all=%v", key, got[key], got)
		}
	}
	if len(got) != 5 {
		t.Fatalf("unexpected entries: %v", got)
	}
	{
		req := httptest.NewRequest(http.MethodHead, "/api/v1/files/archive?path=family", nil)
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: guest})
		head := httptest.NewRecorder()
		h.ServeHTTP(head, req)
		if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Type") != "application/zip" {
			t.Fatalf("archive HEAD: %d len=%d", head.Code, head.Body.Len())
		}
	}
	if err := accounts.RemoveFileGrant(admin, member.ID, "family"); err != nil {
		t.Fatal(err)
	}
	if w := call("/api/v1/files/archive?path=family", guest); w.Code != 403 {
		t.Fatalf("revoked member = %d", w.Code)
	}
	if w := call("/api/v1/files/archive?path=family", admin); w.Code != 200 {
		t.Fatalf("admin = %d %s", w.Code, w.Body.String())
	}
}

func TestFolderArchiveRejectsOversizedFolderBeforeWritingZip(t *testing.T) {
	root := t.TempDir()
	accounts, err := auth.Open(filepath.Join(root, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	store, err := files.Open(filepath.Join(root, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := accounts.Setup("owner", "strong-password-owner"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "strong-password-owner")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Mkdir("heavy"); err != nil {
		t.Fatal(err)
	}
	// A sparse file exercises the size limit without allocating huge storage.
	name := filepath.Join(root, "SharedFiles", "heavy", "large.data")
	if err := os.WriteFile(name, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(name, archiveMaxBytes+1); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/v1/files/archive?path=heavy", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	w := httptest.NewRecorder()
	New("", accounts, store).ServeHTTP(w, req)
	if w.Code != http.StatusRequestEntityTooLarge || !strings.Contains(w.Body.String(), "archive_limit_exceeded") {
		t.Fatalf("oversize archive: %d %s", w.Code, w.Body.String())
	}
}

func TestFolderArchiveIgnoresSymlinksAndInternalData(t *testing.T) {
	root := t.TempDir()
	accounts, err := auth.Open(filepath.Join(root, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	store, err := files.Open(filepath.Join(root, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := accounts.Setup("owner", "strong-password-owner"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "strong-password-owner")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Mkdir("downloads"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Upload("downloads/public.txt", strings.NewReader("safe")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "accounts.sqlite"), filepath.Join(root, "SharedFiles", "downloads", "private")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "SharedFiles", "downloads", ".lightisle-secret"), []byte("hidden"), 0600); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/v1/files/archive?path=downloads", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	w := httptest.NewRecorder()
	New("", accounts, store).ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("archive returned %d %s", w.Code, w.Body.String())
	}
	reader, err := zip.NewReader(bytes.NewReader(w.Body.Bytes()), int64(w.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range reader.File {
		if strings.Contains(item.Name, "private") || strings.Contains(item.Name, ".lightisle") {
			t.Fatalf("internal/symlink content leaked: %q", item.Name)
		}
	}
}
