package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/smbmgmt"
)

func TestWriteAPIErrorEnvelopeBackwardCompatible(t *testing.T) {
	rec := httptest.NewRecorder()
	writeAPIError(rec, http.StatusConflict, "smb_root_offline", "目标存储硬盘当前离线。", true, "请重新连接硬盘后重试。")

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("content-type = %q, want application/json", ct)
	}
	var payload struct {
		Error      string `json:"error"`
		Message    string `json:"message"`
		DataSafe   *bool  `json:"dataSafe"`
		NextAction string `json:"nextAction"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if payload.Error != "smb_root_offline" {
		t.Fatalf("error = %q, want smb_root_offline", payload.Error)
	}
	if payload.Message == "" || payload.NextAction == "" || payload.DataSafe == nil || !*payload.DataSafe {
		t.Fatalf("incomplete guidance fields: %+v", payload)
	}
}

func TestAppsAndSMBErrorRepliesNeverLeakRawInternalErrors(t *testing.T) {
	rec := httptest.NewRecorder()
	appsErrorReply(rec, errors.New("open /Users/secret/private.key: permission denied"))
	body := rec.Body.String()
	if strings.Contains(body, "/Users/secret") || strings.Contains(body, "permission denied") {
		t.Fatalf("appsErrorReply leaked internal error detail: %s", body)
	}
	var parsed APIError
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if parsed.Error != "app_operation_failed" || parsed.Message == "" || parsed.NextAction == "" {
		t.Fatalf("unexpected apps error envelope: %+v", parsed)
	}

	// Domain-wrapped app invalid error keeps Chinese explanation without raw prefix leak.
	recInvalid := httptest.NewRecorder()
	appsErrorReply(recInvalid, errors.Join(apps.ErrInvalid, errors.New("端口超出范围")))
	if recInvalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid app status = %d", recInvalid.Code)
	}

	recSMB := httptest.NewRecorder()
	writeSMBError(recSMB, smbmgmt.ErrPersonalGuest)
	var smbParsed APIError
	if err := json.Unmarshal(recSMB.Body.Bytes(), &smbParsed); err != nil {
		t.Fatalf("unmarshal smb error: %v", err)
	}
	if smbParsed.Error != "smb_personal_guest_forbidden" || smbParsed.Message == "" || smbParsed.NextAction == "" || smbParsed.DataSafe == nil || !*smbParsed.DataSafe {
		t.Fatalf("unexpected smb error envelope: %+v", smbParsed)
	}
}

func TestAPIErrorCatalogsAreCompleteAndDisjoint(t *testing.T) {
	check := func(name string, catalog map[string]apiErrorGuidance) {
		for code, g := range catalog {
			if strings.TrimSpace(code) == "" {
				t.Fatalf("%s has empty error code", name)
			}
			if strings.TrimSpace(g.message) == "" || strings.TrimSpace(g.nextAction) == "" {
				t.Fatalf("%s[%q] missing message or nextAction: %+v", name, code, g)
			}
			if strings.Contains(g.message+g.nextAction, "数据与存储") {
				t.Fatalf("%s[%q] uses outdated menu label: %+v", name, code, g)
			}
		}
	}
	check("apiErrorCatalog", apiErrorCatalog)
	check("apiErrorDomainCatalog", apiErrorDomainCatalog)
	for code := range apiErrorDomainCatalog {
		if _, dup := apiErrorCatalog[code]; dup {
			t.Fatalf("duplicate error code %q across apiErrorCatalog and apiErrorDomainCatalog", code)
		}
	}
}
