package server

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
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
			var body APIError
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if body.Error != tt.wantCode {
				t.Fatalf("error = %q, want %q", body.Error, tt.wantCode)
			}
			if body.Message == "" || body.NextAction == "" || body.DataSafe == nil || !*body.DataSafe {
				t.Fatalf("incomplete guidance in response: %+v", body)
			}
			if strings.Contains(response.Body.String(), tt.upstream) {
				t.Fatal("response exposed upstream error details")
			}
		})
	}
}
