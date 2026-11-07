package server

import (
	"database/sql"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

type afterBeginFiles struct {
	files.Access
	after     func()
	uncertain bool
}

func (f *afterBeginFiles) BeginUpload(name string, size, owner int64) (files.UploadState, error) {
	state, err := f.Access.BeginUpload(name, size, owner)
	if err == nil {
		f.after()
		if f.uncertain {
			return files.UploadState{}, files.ErrUploadBeginUncertain
		}
	}
	return state, err
}

func (f *afterBeginFiles) AbortUploadWithAccounting(id string, owner int64) (bool, error) {
	return f.Access.(interface {
		AbortUploadWithAccounting(string, int64) (bool, error)
	}).AbortUploadWithAccounting(id, owner)
}

func TestUploadBeginPreservesUncertainReservations(t *testing.T) {
	for _, scenario := range []string{"root_swap", "begin_rollback_uncertain", "link_failure", "link_failure_root_swap"} {
		t.Run(scenario, func(t *testing.T) {
			f := newRootRoutingFixture(t)
			category := assignFixtureMemberStorage(t, f)
			base := rootRoute(f.rootA.ID, "")
			if strings.HasPrefix(scenario, "link_failure") {
				db, err := sql.Open("sqlite3", filepath.Join(f.base, "accounts.sqlite"))
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				if _, err := db.Exec(`CREATE TRIGGER fail_upload_link BEFORE UPDATE OF upload_id ON user_storage_reservations BEGIN SELECT RAISE(ABORT,'injected link failure'); END`); err != nil {
					t.Fatal(err)
				}
			}
			service := f.services[f.rootA.ID]
			service.Files = &afterBeginFiles{Access: service.Files, uncertain: scenario == "begin_rollback_uncertain", after: func() {
				if scenario == "root_swap" || scenario == "link_failure_root_swap" {
					if err := os.Rename(f.pathA, f.pathA+"-old"); err != nil {
						t.Fatal(err)
					}
					if err := os.Mkdir(f.pathA, 0700); err != nil {
						t.Fatal(err)
					}
				}
			}}
			r := f.call(f.member, http.MethodPost, base+"/uploads", `{"path":"`+category+`/begin.jpg","size":3}`)
			if scenario == "link_failure" {
				if r.Code != http.StatusInternalServerError {
					t.Fatalf("link failure: %d %s", r.Code, r.Body.String())
				}
			} else if r.Code != http.StatusServiceUnavailable || !strings.Contains(r.Body.String(), "upload_begin_uncertain") {
				t.Fatalf("uncertain begin: %d %s", r.Code, r.Body.String())
			}
			meter, err := f.accounts.StorageMeter(f.admin, f.memberID)
			wantReserved := int64(3)
			if scenario == "link_failure" {
				wantReserved = 0
			}
			if err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != wantReserved {
				t.Fatalf("meter: %+v %v", meter, err)
			}
			pending, _, err := f.accounts.StoragePendingReservations(f.admin, f.memberID, "", 10)
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "root_swap" && (len(pending) != 1 || pending[0].UploadID == "") {
				t.Fatalf("lost staged task reference: %+v", pending)
			}
		})
	}
}
