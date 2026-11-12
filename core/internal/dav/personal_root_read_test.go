package dav

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// Simulates only the volume UUID. Directory identity is real so replacement at
// the same path is exercised without needing an external disk or diskutil.
type davTestIdentity struct{}

func (davTestIdentity) Capture(_ context.Context, name string) (storageidentity.Binding, error) {
	info, err := os.Stat(name)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, storageidentity.ErrIncomplete
	}
	return storageidentity.Binding{Path: name, VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: st.Ino, BirthSec: st.Birthtimespec.Sec, BirthNsec: st.Birthtimespec.Nsec,
		Generation: uint64(st.Gen)}, nil
}

func (p davTestIdentity) Verify(ctx context.Context, expected storageidentity.Binding) error {
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(actual, expected) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestRootDAVPersonalReadAndIsolation(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "disk")
	data := filepath.Join(base, "config")
	for _, dir := range []string{root, data} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(data, davTestIdentity{}, base)
	if err != nil {
		t.Fatal(err)
	}
	registered, err := registry.Add(context.Background(), "disk", root)
	if err != nil {
		t.Fatal(err)
	}
	store, err := auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Setup("owner", "owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "family", "family-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	other, err := store.CreateUser(admin, "other", "other-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	location, err := store.AssignUserStorage(admin, member.ID, auth.StorageVideos, registered.ID, registered.Generation)
	if err != nil {
		t.Fatal(err)
	}
	otherLocation, err := store.AssignUserStorage(admin, other.ID, auth.StorageVideos, registered.ID, registered.Generation)
	if err != nil {
		t.Fatal(err)
	}
	for _, loc := range []auth.StorageLocation{location, otherLocation} {
		dir := filepath.Join(root, filepath.FromSlash(loc.RelativePath))
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "movie.mp4"), []byte("0123456789"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, "public"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := store.SetRootGrant(admin, member.ID, registered.ID, ".", true); err != nil {
		t.Fatal(err)
	}
	session, err := store.Login("family", "family-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	_, password, err := store.CreateDAVCredential(session, "player")
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{root: root, service: NewRootRegistry(store, registry), memberName: "family", memberPass: password}
	own := "/dav/" + location.RelativePath + "/movie.mp4"
	otherPath := "/dav/" + otherLocation.RelativePath + "/movie.mp4"
	status, listing := f.propfind(t, "/dav/Users/", f.memberName, f.memberPass)
	if status != http.StatusMultiStatus || !strings.Contains(listing, fmt.Sprintf("u%d/", member.ID)) || strings.Contains(listing, fmt.Sprintf("u%d/", other.ID)) {
		t.Fatalf("private listing: %d %s", status, listing)
	}
	response := f.request(t, "GET", own, f.memberName, f.memberPass, nil, map[string]string{"Range": "bytes=1-3"})
	if response.Code != http.StatusPartialContent || response.Body.String() != "123" {
		t.Fatalf("range request: %d %q", response.Code, response.Body.String())
	}
	response = f.request(t, "HEAD", own, f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusOK || response.Header().Get("Content-Length") != "10" || response.Body.Len() != 0 {
		t.Fatalf("HEAD request: %d %v %q", response.Code, response.Header(), response.Body.String())
	}
	for _, method := range []string{"GET", "HEAD", "PROPFIND"} {
		response = f.request(t, method, otherPath, f.memberName, f.memberPass, nil, nil)
		if response.Code >= 200 && response.Code < 300 {
			t.Fatalf("%s accessed sibling: %d", method, response.Code)
		}
	}
	for _, tc := range []struct{ method, source, destination string }{
		{"PUT", own, ""},
		{"PROPPATCH", own, ""},
		{"MOVE", own, "/dav/public/moved.mp4"}, {"COPY", otherPath, "/dav/public/forbidden.mp4"},
		{"PUT", otherPath, ""}, {"DELETE", otherPath, ""}, {"MKCOL", "/dav/" + otherLocation.RelativePath + "/new", ""},
	} {
		headers := map[string]string{}
		if tc.destination != "" {
			headers["Destination"] = tc.destination
		}
		var body string
		switch tc.method {
		case "PUT":
			body = "payload"
		case "PROPPATCH":
			body = `<D:propertyupdate xmlns:D="DAV:"><D:set><D:prop><test xmlns="urn:test">value</test></D:prop></D:set></D:propertyupdate>`
		}
		response = f.request(t, tc.method, tc.source, f.memberName, f.memberPass, strings.NewReader(body), headers)
		if response.Code >= 200 && response.Code < 300 {
			t.Errorf("%s %s accepted: %d", tc.method, tc.source, response.Code)
		}
	}
	contents, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(location.RelativePath), "movie.mp4"))
	if err != nil || string(contents) != "0123456789" {
		t.Fatalf("source changed: %q %v", contents, err)
	}
	if _, err := os.Stat(filepath.Join(root, "public", "forbidden.mp4")); !os.IsNotExist(err) {
		t.Fatalf("another member's private copy created: %v", err)
	}
	if err := store.SetUserStorageRootQuota(admin, member.ID, registered.ID, registered.Generation, 6); err != nil {
		t.Fatal(err)
	}
	subCol := "/dav/" + location.RelativePath + "/new"
	if response = f.request(t, "MKCOL", subCol, f.memberName, f.memberPass, nil, nil); response.Code != http.StatusCreated {
		t.Fatalf("MKCOL personal folder: %d %s", response.Code, response.Body.String())
	}
	newFile := subCol + "/clip.mp4"
	if response = f.request(t, "PUT", newFile, f.memberName, f.memberPass, strings.NewReader("123456"), nil); response.Code != http.StatusCreated {
		t.Fatalf("PUT personal file: %d %s", response.Code, response.Body.String())
	}
	if meter, err := store.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 6 {
		t.Fatalf("PUT quota meter: %+v %v", meter, err)
	}
	if response = f.request(t, "PUT", subCol+"/extra.mp4", f.memberName, f.memberPass, strings.NewReader("7"), nil); response.Code != http.StatusInsufficientStorage {
		t.Fatalf("expected 507 on quota overflow, got %d %s", response.Code, response.Body.String())
	}
	renamedFile := subCol + "/renamed.mp4"
	if response = f.request(t, "MOVE", newFile, f.memberName, f.memberPass, nil, map[string]string{"Destination": renamedFile}); response.Code != http.StatusCreated {
		t.Fatalf("MOVE personal file: %d %s", response.Code, response.Body.String())
	}
	if ident, err := store.StorageFileIdentity(registered.ID, registered.Generation, location.RelativePath+"/new/renamed.mp4"); err != nil || ident == "" {
		t.Fatalf("MOVE personal file identity: %q %v", ident, err)
	}
	if response = f.request(t, "DELETE", renamedFile, f.memberName, f.memberPass, nil, nil); response.Code != http.StatusNoContent {
		t.Fatalf("DELETE personal file to trash: %d %s", response.Code, response.Body.String())
	}
	if err := store.SetUserStorageRootQuota(admin, member.ID, registered.ID, registered.Generation, 100); err != nil {
		t.Fatal(err)
	}
	scoped := fmt.Sprintf("/dav-roots/%s/%d/", registered.ID, registered.Generation)
	if err := os.WriteFile(filepath.Join(root, "public", "seed.mp4"), []byte("abc"), 0600); err != nil {
		t.Fatal(err)
	}
	collection := scoped + location.RelativePath + "/copied"
	response = f.request(t, "COPY", scoped+"public", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": collection, "Depth": "infinity"})
	if response.Code != http.StatusCreated {
		t.Fatalf("COPY private tree: %d %s", response.Code, response.Body.String())
	}
	copied := collection + "/seed.mp4"
	response = f.request(t, "GET", copied, f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusOK || response.Body.String() != "abc" {
		t.Fatalf("copied contents: %d %q", response.Code, response.Body.String())
	}
	response = f.request(t, "COPY", scoped+"public", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": collection, "Overwrite": "T"})
	if response.Code != http.StatusPreconditionFailed {
		t.Fatalf("directory overwrite did not preserve destination: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "PUT", copied, f.memberName, f.memberPass, strings.NewReader("xyz"), nil)
	if response.Code != http.StatusNoContent {
		t.Fatalf("PUT replacement: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "COPY", scoped+"public/seed.mp4", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": copied, "Overwrite": "F"})
	if response.Code != http.StatusPreconditionFailed {
		t.Fatalf("COPY Overwrite F: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "COPY", scoped+"public/seed.mp4", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": copied, "Overwrite": "T"})
	if response.Code != http.StatusNoContent {
		t.Fatalf("COPY replacement: %d %s", response.Code, response.Body.String())
	}
	moveFrom := collection + "/moved.mp4"
	if response = f.request(t, "PUT", moveFrom, f.memberName, f.memberPass, strings.NewReader("123"), nil); response.Code != http.StatusCreated {
		t.Fatalf("PUT MOVE source: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "MOVE", moveFrom, f.memberName, f.memberPass, nil, map[string]string{"Destination": copied})
	if response.Code != http.StatusNoContent {
		t.Fatalf("MOVE replacement: %d %s", response.Code, response.Body.String())
	}
	if meter, err := store.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 18 || meter.ReservedBytes != 0 {
		t.Fatalf("replacement quota including trash: %+v %v", meter, err)
	}
	archives, err := filepath.Glob(filepath.Join(root, ".lightisle-trash", "*.json"))
	if err != nil || len(archives) != 4 {
		t.Fatalf("trash entries after replacement: %v %v", archives, err)
	}
	secondDisk := filepath.Join(base, "second")
	if err := os.Mkdir(secondDisk, 0700); err != nil {
		t.Fatal(err)
	}
	second, err := registry.Add(context.Background(), "second", secondDisk)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.SetDefault(context.Background(), second.ID, second.Generation); err != nil {
		t.Fatal(err)
	}
	response = f.request(t, "GET", own, f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "dav_remount_required") {
		t.Fatalf("legacy mount followed another disk: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "GET", copied, f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusOK || response.Body.String() != "123" {
		t.Fatalf("explicit mount changed with the default: %d %s", response.Code, response.Body.String())
	}
	response = f.request(t, "PROPFIND", strings.TrimSuffix(scoped, "/"), f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusPermanentRedirect || response.Header().Get("Location") != scoped {
		t.Fatalf("mount root without trailing slash did not redirect to %s: %d %q", scoped, response.Code, response.Header().Get("Location"))
	}
	crossOwnerMove := f.request(t, "MOVE", copied, f.memberName, f.memberPass, nil, map[string]string{"Destination": scoped + "public/moved-out.mp4"})
	if crossOwnerMove.Code != http.StatusForbidden || !strings.Contains(crossOwnerMove.Body.String(), "dav_cross_owner_move") {
		t.Fatalf("expected 403 dav_cross_owner_move on personal-to-public move, got %d %s", crossOwnerMove.Code, crossOwnerMove.Body.String())
	}
	response = f.request(t, "PROPFIND", fmt.Sprintf("/dav-roots/%s/%d/", second.ID, second.Generation), f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusNotFound {
		t.Fatalf("unauthorized second mount: %d %s", response.Code, response.Body.String())
	}
	if err := store.RemoveRootGrant(admin, member.ID, registered.ID, "."); err != nil {
		t.Fatal(err)
	}
	if err := store.RemoveRootGrant(admin, member.ID, registered.ID, location.RelativePath); err != nil {
		t.Fatal(err)
	}
	response = f.request(t, "GET", scoped+location.RelativePath+"/movie.mp4", f.memberName, f.memberPass, nil, nil)
	if response.Code >= 200 && response.Code < 300 {
		t.Fatalf("revoked grant accepted: %d", response.Code)
	}
	if err := os.Rename(root, root+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := store.SetRootGrant(admin, member.ID, registered.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	response = f.request(t, "GET", scoped+location.RelativePath+"/movie.mp4", f.memberName, f.memberPass, nil, nil)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("replacement disk accepted: %d", response.Code)
	}
}
