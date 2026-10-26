package server

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

// Simulates a sync acknowledgement failure AFTER the file manager has
// atomically published the destination. The reservation must survive it.
type uncertainCopyFiles struct {
	files.Access
	reportUncertain bool
}

func (f *uncertainCopyFiles) CopyContextWithOptions(ctx context.Context, from, to, conflict string) (string, bool, error) {
	inner := f.Access.(interface {
		CopyContextWithOptions(context.Context, string, string, string) (string, bool, error)
	})
	name, skipped, err := inner.CopyContextWithOptions(ctx, from, to, conflict)
	if err == nil && f.reportUncertain {
		return "", false, files.ErrPublishedSync
	}
	return name, skipped, err
}

func TestScopedPersonalFileCopyReservesAccountsAndNeverOverwrites(t *testing.T) {
	base := t.TempDir()
	volume, private := filepath.Join(base, "volume"), filepath.Join(base, "private")
	rootPath := filepath.Join(volume, "share")
	for _, dir := range []string{volume, private, rootPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Home", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "storage-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "storage-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "member", "storage-member-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("member", "storage-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	sibling, err := accounts.CreateUser(admin, "sibling", "storage-sibling-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	guarded := &uncertainCopyFiles{}
	server := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			manager, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			guarded.Access = manager
			return &RootServices{Files: guarded, Close: manager.Close}, nil
		})
	defer server.Close()
	baseURL := "/api/v2/roots/" + root.ID
	call := func(method, url, session, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, strings.NewReader(body))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		r.Header.Set(rootGenerationHeader, strconv.FormatUint(root.Generation, 10))
		r.Header.Set("X-LightIsle-Request", "1")
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		return w
	}
	assign := func(memberID int64) {
		r := call("PUT", baseURL+"/users/"+strconv.FormatInt(memberID, 10)+"/storage/files", admin, "")
		if r.Code != 200 {
			t.Fatalf("assign member %d: %d %s", memberID, r.Code, r.Body.String())
		}
	}
	assign(member.ID)
	assign(sibling.ID)
	if err := accounts.SetUserStorageQuota(admin, member.ID, 5); err != nil {
		t.Fatal(err)
	}
	prefix := "Users/u" + strconv.FormatInt(member.ID, 10) + "/files/"
	otherPrefix := "Users/u" + strconv.FormatInt(sibling.ID, 10) + "/files/"
	if r := call("PUT", baseURL+"/files/content?path="+prefix+"a.txt", memberSession, "ab"); r.Code != 201 {
		t.Fatalf("seed personal upload: %d %s", r.Code, r.Body.String())
	}
	copyFile := func(from, to, conflict, session string) *httptest.ResponseRecorder {
		return call("POST", baseURL+"/files/operations", session, `{"action":"copy","from":"`+from+`","to":"`+to+`","conflict":"`+conflict+`"}`)
	}
	if r := copyFile(prefix+"a.txt", prefix+"b.txt", "", memberSession); r.Code != 200 {
		t.Fatalf("metered copy: %d %s", r.Code, r.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(rootPath, filepath.FromSlash(prefix+"b.txt"))); err != nil || !bytes.Equal(data, []byte("ab")) {
		t.Fatalf("copy bytes: %q %v", data, err)
	}
	if meter, err := accounts.StorageMeter(memberSession, member.ID); err != nil || meter.UsedBytes != 4 || meter.ReservedBytes != 0 {
		t.Fatalf("successful copy not credited: %+v %v", meter, err)
	}
	// Give the conflict check spare budget: with an already-exhausted quota,
	// 507 is also an expected conservative response before destination lookup.
	if err := accounts.SetUserStorageQuota(admin, member.ID, 6); err != nil {
		t.Fatal(err)
	}
	if r := copyFile(prefix+"a.txt", prefix+"b.txt", "", memberSession); r.Code != http.StatusConflict {
		t.Fatalf("duplicate publication: %d %s", r.Code, r.Body.String())
	}
	if err := accounts.SetUserStorageQuota(admin, member.ID, 5); err != nil {
		t.Fatal(err)
	}
	if r := copyFile(prefix+"a.txt", prefix+"c.txt", "", memberSession); r.Code != http.StatusInsufficientStorage {
		t.Fatalf("quota overrun: %d %s", r.Code, r.Body.String())
	}
	if _, err := os.Stat(filepath.Join(rootPath, filepath.FromSlash(prefix+"c.txt"))); !os.IsNotExist(err) {
		t.Fatalf("quota-bypassing copy reached disk: %v", err)
	}
	for _, conflict := range []string{"skip", "rename"} {
		if r := copyFile(prefix+"a.txt", prefix+"renamed.txt", conflict, memberSession); r.Code != http.StatusConflict || !strings.Contains(r.Body.String(), "storage_copy_conflict_strategy_pending") {
			t.Fatalf("conflict policy %s: %d %s", conflict, r.Code, r.Body.String())
		}
	}
	if r := copyFile(otherPrefix+"private.txt", prefix+"leak.txt", "", memberSession); r.Code != http.StatusForbidden {
		t.Fatalf("sibling private read leaked: %d %s", r.Code, r.Body.String())
	}
	if r := copyFile(prefix+"a.txt", otherPrefix+"cross.txt", "", memberSession); r.Code != http.StatusForbidden {
		t.Fatalf("sibling private write leaked: %d %s", r.Code, r.Body.String())
	}
	if r := copyFile(strings.TrimSuffix(prefix, "/"), prefix+"directory", "", memberSession); r.Code != http.StatusConflict || !strings.Contains(r.Body.String(), "storage_copy_regular_file_required") {
		t.Fatalf("directory copy allowed: %d %s", r.Code, r.Body.String())
	}
	if r := call("PUT", baseURL+"/files/content?path=legacy.txt", admin, "z"); r.Code != 201 {
		t.Fatalf("legacy seed: %d %s", r.Code, r.Body.String())
	}
	if r := copyFile("legacy.txt", prefix+"from-legacy.txt", "", admin); r.Code != 200 {
		t.Fatalf("admin copy into member folder: %d %s", r.Code, r.Body.String())
	}
	if meter, err := accounts.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 5 || meter.ReservedBytes != 0 {
		t.Fatalf("admin copy not charged to destination owner: %+v %v", meter, err)
	}
	reservationID, tracked, err := accounts.ReserveStorageUpload(memberSession, root.ID, root.Generation, prefix+"pending.dat", 0)
	if err != nil || !tracked {
		t.Fatalf("recovery test reservation: %v %v", tracked, err)
	}
	request := httptest.NewRequest("GET", "/api/v1/users/"+strconv.FormatInt(member.ID, 10)+"/storage/reservations?limit=1", nil)
	request.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	response := httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), reservationID) {
		t.Fatalf("administrator cannot inspect pending storage: %d %s", response.Code, response.Body.String())
	}
	request = httptest.NewRequest("GET", "/api/v1/users/"+strconv.FormatInt(member.ID, 10)+"/storage/reservations?limit=1", nil)
	request.AddCookie(&http.Cookie{Name: sessionCookie, Value: memberSession})
	response = httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("member accessed administrator reservation list: %d", response.Code)
	}
	if err := accounts.SetUserStorageQuota(admin, member.ID, 8); err != nil {
		t.Fatal(err)
	}
	guarded.reportUncertain = true
	if r := copyFile("legacy.txt", prefix+"uncertain.txt", "", admin); r.Code != http.StatusInternalServerError || !strings.Contains(r.Body.String(), "storage_accounting_uncertain") {
		t.Fatalf("published but unacknowledged copy response: %d %s", r.Code, r.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(rootPath, filepath.FromSlash(prefix+"uncertain.txt"))); err != nil || string(data) != "z" {
		t.Fatalf("copy was not durably published: %q %v", data, err)
	}
	if meter, err := accounts.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 5 || meter.ReservedBytes != 1 {
		t.Fatalf("uncertain copy reservation was lost: %+v %v", meter, err)
	}
	guarded.reportUncertain = false
	if r := copyFile("legacy.txt", prefix+"uncertain.txt", "", admin); r.Code != http.StatusConflict {
		t.Fatalf("unacknowledged publication overwritten on retry: %d %s", r.Code, r.Body.String())
	}
}
