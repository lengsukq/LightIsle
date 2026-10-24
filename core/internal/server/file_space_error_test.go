package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestInsufficientUploadSpaceReturnsActionableHTTPCode(t *testing.T) {
	response := httptest.NewRecorder()
	fileError(response, files.ErrInsufficientSpace)
	if response.Code != http.StatusInsufficientStorage || !strings.Contains(response.Body.String(), "insufficient_storage_space") {
		t.Fatalf("wrong space failure response: %d %s", response.Code, response.Body.String())
	}
}
