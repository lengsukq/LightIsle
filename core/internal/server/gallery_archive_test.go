package server

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type interruptSelectedArchiveFiles struct {
	files.Access
	reads     int
	interrupt func()
}

func (f *interruptSelectedArchiveFiles) Read(name string) (*os.File, os.FileInfo, error) {
	file, info, err := f.Access.Read(name)
	if err == nil {
		f.reads++
		if f.reads == 2 {
			f.interrupt()
		}
	}
	return file, info, err
}

func TestSelectedPhotoArchiveAbortsIfAccessOrRootChangesDuringStream(t *testing.T) {
	for _, change := range []string{"permission", "root"} {
		t.Run(change, func(t *testing.T) {
			f := newRootRoutingFixture(t)
			category := assignFixtureMemberStorage(t, f)
			name := category + "/photo.jpg"
			if err := os.WriteFile(filepath.Join(f.pathA, filepath.FromSlash(name)), []byte("photo"), 0600); err != nil {
				t.Fatal(err)
			}
			startRootScans(t, f, f.rootA.ID)
			assets, _, err := f.services[f.rootA.ID].Gallery.List(0, 20, 0, false)
			if err != nil || len(assets) != 1 {
				t.Fatalf("assets: %+v %v", assets, err)
			}
			service := f.services[f.rootA.ID]
			service.Files = &interruptSelectedArchiveFiles{Access: service.Files, interrupt: func() {
				if change == "permission" {
					if err := f.accounts.RemoveRootGrant(f.admin, f.memberID, f.rootA.ID, category); err != nil {
						t.Fatal(err)
					}
				} else {
					if err := os.Rename(f.pathA, f.pathA+"-old"); err != nil {
						t.Fatal(err)
					}
					if err := os.Mkdir(f.pathA, 0700); err != nil {
						t.Fatal(err)
					}
				}
			}}
			defer func() {
				if got := recover(); got != http.ErrAbortHandler {
					t.Fatalf("incomplete archive was not aborted: %v", got)
				}
			}()
			f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/archive?ids="+strconv.FormatInt(assets[0].ID, 10)), "")
		})
	}
}

func TestSelectedPhotoArchiveChecksOwnerAndFileIdentity(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	other, err := f.accounts.CreateUser(f.admin, "other", "other-archive-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	assignment := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/users/"+strconv.FormatInt(other.ID, 10)+"/storage/photos"), "")
	if assignment.Code != http.StatusOK {
		t.Fatalf("other assignment: %d %s", assignment.Code, assignment.Body.String())
	}
	otherPath := "Users/u" + strconv.FormatInt(other.ID, 10) + "/photos/secret.jpg"
	paths := []string{category + "/one/duplicate.jpg", category + "/two/duplicate.jpg", otherPath}
	for i, name := range paths {
		full := filepath.Join(f.pathA, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte{"a"[0] + byte(i), 'x', 'x'}, 0600); err != nil {
			t.Fatal(err)
		}
	}
	startRootScans(t, f, f.rootA.ID)
	assets, _, err := f.services[f.rootA.ID].Gallery.List(0, 20, 0, false)
	if err != nil || len(assets) != 3 {
		t.Fatalf("indexed assets: %+v %v", assets, err)
	}
	ids := map[string]int64{}
	for _, item := range assets {
		ids[item.Path] = item.ID
	}
	query := func(names ...string) string {
		var idsText []string
		for _, name := range names {
			idsText = append(idsText, strconv.FormatInt(ids[name], 10))
		}
		return rootRoute(f.rootA.ID, "/photos/archive?ids="+strings.Join(idsText, ","))
	}
	url := query(paths[0], paths[1])
	head := f.call(f.member, http.MethodHead, url, "")
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD: %d %s", head.Code, head.Body.String())
	}
	response := f.call(f.member, http.MethodGet, url, "")
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("archive: %d %s", response.Code, response.Body.String())
	}
	reader, err := zip.NewReader(bytes.NewReader(response.Body.Bytes()), int64(response.Body.Len()))
	if err != nil || len(reader.File) != 2 {
		t.Fatalf("zip: %+v %v", reader, err)
	}
	for i, item := range reader.File {
		wantName := strconv.Itoa(i + 1)
		if !strings.HasPrefix(item.Name, "0"+wantName+"_duplicate.jpg") {
			t.Fatalf("unexpected entry %q", item.Name)
		}
		file, err := item.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(file)
		_ = file.Close()
		if err != nil || string(data) != string([]byte{'a' + byte(i), 'x', 'x'}) {
			t.Fatalf("entry %q: %q %v", item.Name, data, err)
		}
	}
	if denied := f.call(f.member, http.MethodGet, query(paths[0], otherPath), ""); denied.Code != http.StatusNotFound {
		t.Fatalf("other member's media exposed: %d %s", denied.Code, denied.Body.String())
	}
	if repeated := f.call(f.member, http.MethodGet, query(paths[0], paths[0]), ""); repeated.Code != http.StatusBadRequest {
		t.Fatalf("duplicate IDs accepted: %d %s", repeated.Code, repeated.Body.String())
	}
	db, err := sql.Open("sqlite3", filepath.Join(f.dataDir, "gallery-root-"+f.rootA.ID+".sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE assets SET size=? WHERE id=?`, archiveMaxBytes, ids[paths[1]]); err != nil {
		t.Fatal(err)
	}
	if tooLarge := f.call(f.member, http.MethodHead, url, ""); tooLarge.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized selection accepted: %d %s", tooLarge.Code, tooLarge.Body.String())
	}
	if _, err := db.Exec(`UPDATE assets SET size=3 WHERE id=?`, ids[paths[1]]); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	full := filepath.Join(f.pathA, filepath.FromSlash(paths[0]))
	info, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(full, filepath.Join(t.TempDir(), "old.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(full, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if changed := f.call(f.member, http.MethodHead, url, ""); changed.Code != http.StatusConflict {
		t.Fatalf("same-size replacement accepted: %d %s", changed.Code, changed.Body.String())
	}
}
