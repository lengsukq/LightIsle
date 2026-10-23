package server

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"testing"
)

func TestCinemaTMDBErrorReturnsStableCredentialCodes(t *testing.T) {
	tests := []struct {
		name       string
		upstream   string
		wantStatus int
		wantCode   string
	}{
		{name: "invalid token", upstream: "tmdb_upstream_status_401", wantStatus: 401, wantCode: "tmdb_auth_failed"},
		{name: "denied token", upstream: "tmdb_upstream_status_403", wantStatus: 403, wantCode: "tmdb_access_denied"},
		{name: "rate limited", upstream: "tmdb_upstream_status_429", wantStatus: 502, wantCode: "tmdb_upstream_failed"},
		{name: "transport failure", upstream: "tmdb_upstream_unavailable: timeout", wantStatus: 502, wantCode: "tmdb_upstream_failed"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			cinemaTMDBError(response, errors.New(tt.upstream))
			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, tt.wantStatus)
			}
			var body map[string]string
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if body["error"] != tt.wantCode {
				t.Fatalf("error = %q, want %q", body["error"], tt.wantCode)
			}
			if response.Body.String() == tt.upstream {
				t.Fatal("response exposed upstream error details")
			}
		})
	}
}
