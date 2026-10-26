package dav

import (
	"net/http"
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
