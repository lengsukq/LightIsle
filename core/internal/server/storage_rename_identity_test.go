package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

type replaceBeforeRenameFiles struct {
	files.Access
	replace func()
}

func (f *replaceBeforeRenameFiles) Move(from, to string) error {
	f.replace()
	return f.Access.Move(from, to)
}

func TestAccountedRenameChecksOriginalIdentity(t *testing.T) {
	for _, when := range []string{"unchanged", "before", "during"} {
		t.Run(when, func(t *testing.T) {
			f := newRootRoutingFixture(t)
			category := assignFixtureMemberStorage(t, f)
			source, target := category+"/original.jpg", category+"/renamed.jpg"
			base := rootRoute(f.rootA.ID, "")
			if r := f.call(f.member, http.MethodPut, base+"/files/content?path="+source, "abc"); r.Code != http.StatusCreated {
				t.Fatalf("upload: %d %s", r.Code, r.Body.String())
			}
			identity, err := f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, source)
			if err != nil || identity == "" {
				t.Fatalf("upload identity: %q %v", identity, err)
			}
			filePath := filepath.Join(f.pathA, filepath.FromSlash(source))
			saved := filepath.Join(t.TempDir(), "saved.jpg")
			replace := func() {
				if err := os.Rename(filePath, saved); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filePath, []byte("xyz"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if when == "before" {
				replace()
			}
			if when == "during" {
				service := f.services[f.rootA.ID]
				service.Files = &replaceBeforeRenameFiles{Access: service.Files, replace: replace}
			}
			body, err := json.Marshal(map[string]string{"action": "move", "from": source, "to": target})
			if err != nil {
				t.Fatal(err)
			}
			r := f.call(f.member, http.MethodPost, base+"/files/operations", string(body))
			wantStatus, wantError := http.StatusOK, ""
			if when == "before" {
				wantStatus, wantError = http.StatusConflict, "storage_accounting_conflict"
			}
			if when == "during" {
				wantStatus, wantError = http.StatusInternalServerError, "storage_accounting_uncertain"
			}
			if r.Code != wantStatus || (wantError != "" && !strings.Contains(r.Body.String(), wantError)) {
				t.Fatalf("rename: %d %s", r.Code, r.Body.String())
			}
			identityPath := source
			if when == "unchanged" {
				identityPath = target
			}
			if got, err := f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, identityPath); err != nil || got != identity {
				t.Fatalf("identity moved incorrectly: %q %v", got, err)
			}
			pending, _, err := f.accounts.StoragePendingReservations(f.admin, f.memberID, "", 20)
			if err != nil {
				t.Fatal(err)
			}
			wantPending := 0
			if when == "during" {
				wantPending = 1
			}
			if len(pending) != wantPending {
				t.Fatalf("pending reservations: %+v", pending)
			}
			if when != "unchanged" {
				if data, err := os.ReadFile(saved); err != nil || string(data) != "abc" {
					t.Fatalf("original lost: %q %v", data, err)
				}
			}
			if when == "before" {
				if data, err := os.ReadFile(filePath); err != nil || string(data) != "xyz" {
					t.Fatalf("replacement changed: %q %v", data, err)
				}
			}
		})
	}
}
