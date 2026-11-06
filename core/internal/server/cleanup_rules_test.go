package server

import (
	"net/http"
	"testing"
)

func TestCleanupRulesAreAdminOnlyAndValidated(t *testing.T) {
	f := newRootRoutingFixture(t)
	route := "/api/v2/admin/cleanup-rules"
	if response := f.call(f.member, http.MethodGet, route, ""); response.Code != http.StatusForbidden {
		t.Fatalf("member read rules: %d", response.Code)
	}
	if response := f.call(f.member, http.MethodPut, route, `{"uploadRetentionDays":1}`); response.Code != http.StatusForbidden {
		t.Fatalf("member changed rules: %d", response.Code)
	}
	if response := f.call(f.admin, http.MethodGet, route, ""); response.Code != http.StatusOK || response.Body.String() != "{\"uploadRetentionDays\":30}\n" {
		t.Fatalf("default: %d %s", response.Code, response.Body.String())
	}
	for _, body := range []string{`{}`, `{"uploadRetentionDays":-1}`, `{"uploadRetentionDays":3651}`, `{"uploadRetentionDays":7,"extra":true}`} {
		if response := f.call(f.admin, http.MethodPut, route, body); response.Code != http.StatusBadRequest {
			t.Fatalf("invalid rules accepted: %s -> %d", body, response.Code)
		}
	}
	if response := f.call(f.admin, http.MethodPut, route, `{"uploadRetentionDays":0}`); response.Code != http.StatusOK {
		t.Fatalf("disable failed: %d %s", response.Code, response.Body.String())
	}
	if days, err := f.accounts.UploadRetentionDays(); err != nil || days != 0 {
		t.Fatalf("setting not stored: %d %v", days, err)
	}
}
