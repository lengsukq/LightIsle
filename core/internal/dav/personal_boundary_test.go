package dav

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLegacyDAVHidesPrivateHomesAndRefusesWrites(t *testing.T) {
	fixture, _ := newFixture(t)
	secret := filepath.Join(fixture.root, "Users", "u2", "files", "private.txt")
	if err := os.MkdirAll(filepath.Dir(secret), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secret, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	status, body := fixture.propfind(t, "/dav/", fixture.adminName, fixture.adminPassword)
	if status != http.StatusMultiStatus || strings.Contains(body, "/dav/Users") {
		t.Fatalf("DAV root revealed private directory: %d %s", status, body)
	}
	for _, tc := range []struct{ method, path string }{
		{"PROPFIND", "/dav/Users/u2/files/"},
		{"GET", "/dav/Users/u2/files/private.txt"},
		{"GET", "/dav/users/u2/files/private.txt"},
		{"PUT", "/dav/Users/u2/files/evil.txt"},
		{"PUT", "/dav/USERS/u2/files/evil.txt"},
		{"DELETE", "/dav/Users/u2/files/private.txt"},
	} {
		got := fixture.request(t, tc.method, tc.path, fixture.adminName, fixture.adminPassword, strings.NewReader("evil"), nil)
		if got.Code >= 200 && got.Code < 300 {
			t.Fatalf("DAV %s %s accepted: %d", tc.method, tc.path, got.Code)
		}
	}
	data, err := os.ReadFile(secret)
	if err != nil || string(data) != "secret" {
		t.Fatalf("private file changed: %q %v", data, err)
	}
}

func TestDAVRejectsInternalCaseAliasesAndOversizedXML(t *testing.T) {
	f, _ := newFixture(t)
	private := filepath.Join(f.root, ".LIGHTISLE-private.txt")
	if err := os.WriteFile(private, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	response := f.request(t, http.MethodGet, "/dav/.LIGHTISLE-private.txt", f.adminName, f.adminPassword, nil, nil)
	if response.Code < 400 {
		t.Fatalf("internal alias readable via DAV: %d", response.Code)
	}
	status, body := f.propfind(t, "/dav/", f.adminName, f.adminPassword)
	if status != http.StatusMultiStatus || strings.Contains(body, "LIGHTISLE-private.txt") {
		t.Fatalf("internal alias listed via DAV: %d %s", status, body)
	}

	for _, method := range []string{"PROPFIND", "PROPPATCH", "LOCK"} {
		// An unknown Content-Length exercises the streaming limit, including a
		// valid prefix that an XML decoder could accept before reading the tail.
		payload := struct{ io.Reader }{strings.NewReader(`<propfind xmlns="DAV:"><allprop/></propfind>` + strings.Repeat(" ", maxDAVMetadataBytes))}
		response := f.request(t, method, "/dav/top.txt", f.adminName, f.adminPassword, payload, nil)
		if response.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("%s accepted oversized metadata: %d", method, response.Code)
		}
	}
}

func TestDAVOverlappingCopyMovePreserveSource(t *testing.T) {
	f, _ := newFixture(t)
	for _, tc := range []struct{ method, source, target string }{
		{"COPY", "/dav/photos", "/dav/photos/nested"},
		{"COPY", "/dav/photos/a.txt", "/dav/photos"},
		{"MOVE", "/dav/photos/a.txt", "/dav/PHOTOS"},
	} {
		response := f.request(t, tc.method, tc.source, f.adminName, f.adminPassword, nil,
			map[string]string{"Destination": tc.target, "Overwrite": "T"})
		if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "dav_source_destination_overlap") {
			t.Fatalf("%s %s -> %s: %d %s", tc.method, tc.source, tc.target, response.Code, response.Body.String())
		}
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "a.txt")); err != nil || len(f.trashed) != 0 {
		t.Fatalf("overlapping requests changed the source: trash=%v, error=%v", f.trashed, err)
	}
}

func TestDAVPropfindInfiniteDepthRejected(t *testing.T) {
	f, _ := newFixture(t)
	response := f.request(t, "PROPFIND", "/dav/", f.adminName, f.adminPassword, nil,
		map[string]string{"Depth": "infinity"})
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "propfind-finite-depth") {
		t.Fatalf("recursive listing response: %d %s", response.Code, response.Body.String())
	}
}

func TestDAVRejectsOversizedPutBeforeTouchingDestination(t *testing.T) {
	f, _ := newFixture(t)
	target := filepath.Join(f.root, "photos", "a.txt")
	original, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPut, "/dav/photos/a.txt", nil)
	req.ContentLength = maxDAVUploadBytes + 1
	req.SetBasicAuth(f.memberName, f.memberPass)
	rec := httptest.NewRecorder()
	f.service.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized PUT returned %d: %s", rec.Code, rec.Body.String())
	}
	current, err := os.ReadFile(target)
	if err != nil || string(current) != string(original) {
		t.Fatalf("oversized PUT touched destination: %q %v", current, err)
	}
}

func TestDAVWalkBudgetRejectsRatherThanReturningPartialEntries(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "file"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	dir, err := os.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	state := &requestState{method: "COPY", walkEntries: maxDAVWalkEntries}
	reader := &safeFile{file: dir, state: state, name: "."}
	entries, err := reader.Readdir(-1)
	if err == nil || len(entries) != 0 || !state.walkLimited {
		t.Fatalf("over-budget walk exposed partial results: %v %v", entries, err)
	}
}
