package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestUnknownUploadEntriesRequireAdminAndExposeOnlyNames(t *testing.T) {
	f := newRootRoutingFixture(t)
	staging := filepath.Join(f.pathA, ".lightisle-parts")
	if err := os.Mkdir(staging, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"unknown-a", "unknown-b"} {
		if err := os.WriteFile(filepath.Join(staging, name), []byte("retain"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	route := rootRoute(f.rootA.ID, "/admin/uploads/unrecognized")
	member := f.call(f.member, http.MethodGet, route, "")
	if member.Code != http.StatusForbidden && member.Code != http.StatusNotFound {
		t.Fatalf("member could inspect administrative staging: %d %s", member.Code, member.Body.String())
	}
	response := f.call(f.admin, http.MethodGet, route+"?limit=1", "")
	if response.Code != http.StatusOK {
		t.Fatalf("admin list: %d %s", response.Code, response.Body.String())
	}
	var page struct {
		Items []struct {
			Name string `json:"name"`
		} `json:"items"`
		Next string `json:"nextCursor"`
		Dir  string `json:"directory"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || len(page.Items) != 1 || page.Items[0].Name != "unknown-a" || page.Next == "" || page.Dir != ".lightisle-parts" {
		t.Fatalf("unexpected page %+v %v", page, err)
	}
	response = f.call(f.admin, http.MethodGet, route+"?limit=1&after="+page.Next, "")
	if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || response.Code != http.StatusOK || len(page.Items) != 1 || page.Items[0].Name != "unknown-b" || page.Next != "" {
		t.Fatalf("unexpected next page %+v status=%d err=%v", page, response.Code, err)
	}
	response = f.call(f.admin, http.MethodGet, route+"?after=***", "")
	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid cursor accepted: %d", response.Code)
	}
	if data, err := os.ReadFile(filepath.Join(staging, "unknown-a")); err != nil || string(data) != "retain" {
		t.Fatalf("listing changed staging data: %q %v", data, err)
	}
}
