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

type afterUploadRemovalFiles struct {
	files.Access
	uploadID   string
	after      func()
	unverified bool
}

func (f *afterUploadRemovalFiles) AbortUploadWithAccounting(id string, owner int64) (bool, error) {
	safe, err := f.Access.(interface {
		AbortUploadWithAccounting(string, int64) (bool, error)
	}).AbortUploadWithAccounting(id, owner)
	if err == nil {
		f.after()
	}
	if f.unverified {
		safe = false
	}
	return safe, err
}

func (f *afterUploadRemovalFiles) CancelUploadWithAccounting(id string) (bool, error) {
	safe, err := f.Access.(interface{ CancelUploadWithAccounting(string) (bool, error) }).CancelUploadWithAccounting(id)
	if err == nil {
		f.after()
	}
	if f.unverified {
		safe = false
	}
	return safe, err
}

func (f *afterUploadRemovalFiles) CleanupExpiredUploads(_ int64) ([]string, int, bool, error) {
	safe, err := f.Access.(interface{ CancelUploadWithAccounting(string) (bool, error) }).CancelUploadWithAccounting(f.uploadID)
	if err != nil {
		return nil, 0, false, err
	}
	if !safe {
		return nil, 1, false, nil
	}
	f.after()
	return []string{f.uploadID}, 0, false, nil
}

func TestManualUploadCleanupRechecksRootAndDestination(t *testing.T) {
	for _, method := range []string{"owner", "admin", "expired"} {
		for _, change := range []string{"none", "destination", "root", "unverified"} {
			if method == "expired" && change == "unverified" {
				continue
			}
			t.Run(method+"/"+change, func(t *testing.T) {
				f := newRootRoutingFixture(t)
				category := assignFixtureMemberStorage(t, f)
				name := category + "/pending.jpg"
				base := rootRoute(f.rootA.ID, "")
				begin := f.call(f.member, http.MethodPost, base+"/uploads", `{"path":"`+name+`","size":3}`)
				if begin.Code != http.StatusCreated {
					t.Fatalf("begin: %d %s", begin.Code, begin.Body.String())
				}
				var upload files.UploadState
				if err := json.Unmarshal(begin.Body.Bytes(), &upload); err != nil || upload.ID == "" {
					t.Fatalf("upload: %+v %v", upload, err)
				}
				service := f.services[f.rootA.ID]
				service.Files = &afterUploadRemovalFiles{Access: service.Files, uploadID: upload.ID, unverified: change == "unverified", after: func() {
					switch change {
					case "destination":
						if err := os.WriteFile(filepath.Join(f.pathA, filepath.FromSlash(name)), []byte("new"), 0600); err != nil {
							t.Fatal(err)
						}
					case "root":
						if err := os.Rename(f.pathA, f.pathA+"-old"); err != nil {
							t.Fatal(err)
						}
						if err := os.Mkdir(f.pathA, 0700); err != nil {
							t.Fatal(err)
						}
					}
				}}
				var responseCode int
				var responseBody string
				if method == "expired" {
					r := f.call(f.admin, http.MethodPost, base+"/admin/uploads/cleanup-expired", `{"inactiveForSeconds":604800}`)
					responseCode, responseBody = r.Code, r.Body.String()
				} else {
					actor, route := f.member, base+"/uploads/"+upload.ID
					if method == "admin" {
						actor, route = f.admin, base+"/admin/uploads/"+upload.ID
					}
					r := f.call(actor, http.MethodDelete, route, "")
					responseCode, responseBody = r.Code, r.Body.String()
				}
				wantCode, contains := http.StatusOK, ""
				if change == "root" || change == "unverified" || (change == "destination" && method != "expired") {
					wantCode, contains = http.StatusServiceUnavailable, "upload_cleanup_accounting_uncertain"
				}
				if change == "destination" && method == "expired" {
					contains = `"pendingReservations":1`
				}
				if responseCode != wantCode || (contains != "" && !strings.Contains(responseBody, contains)) {
					t.Fatalf("cleanup: %d %s", responseCode, responseBody)
				}
				meter, err := f.accounts.StorageMeter(f.admin, f.memberID)
				wantReserved := int64(3)
				if change == "none" {
					wantReserved = 0
				}
				if err != nil || meter.ReservedBytes != wantReserved || meter.UsedBytes != 0 {
					t.Fatalf("meter: %+v %v", meter, err)
				}
			})
		}
	}
}
