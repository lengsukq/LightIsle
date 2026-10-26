package notify

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRobotProtocolsAndNamedChannelRouting(t *testing.T) {
	var wecomSeen, dingtalkSeen atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("invalid robot payload: %v", err)
		}
		if body["msgtype"] != "text" {
			t.Errorf("robot message type: %+v", body)
		}
		switch r.URL.Path {
		case "/wecom":
			wecomSeen.Add(1)
		case "/dingtalk":
			dingtalkSeen.Add(1)
			if r.URL.Query().Get("sign") == "" || r.URL.Query().Get("timestamp") == "" {
				t.Error("signed dingtalk robot missing timestamp/sign")
			}
		default:
			t.Errorf("unexpected robot path %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"errcode":0,"errmsg":"ok"}`))
	}))
	defer srv.Close()
	hub, err := New(Config{WecomWebhook: srv.URL + "/wecom", DingtalkWebhook: srv.URL + "/dingtalk", DingtalkSecret: "SECtest", AllowPrivateTargets: true})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	if strings.Join(hub.ConfiguredChannels(), ",") != "wecom,dingtalk" {
		t.Fatalf("configured %+v", hub.ConfiguredChannels())
	}
	event := Event{Code: "automation_failure", Title: "test", Body: "script failed", Severity: "warning"}
	if err := hub.deliver(hub.clientLocked(), hub.cfg, event, []string{"dingtalk"}); err != nil {
		t.Fatal(err)
	}
	if wecomSeen.Load() != 0 || dingtalkSeen.Load() != 1 {
		t.Fatal("per task channel selection not respected")
	}
	if err := hub.deliver(hub.clientLocked(), hub.cfg, event, nil); err != nil {
		t.Fatal(err)
	}
	if wecomSeen.Load() != 1 || dingtalkSeen.Load() != 2 {
		t.Fatal("global channels not delivered")
	}
}
func TestSMTPValidationRequiresTLSAndCredentials(t *testing.T) {
	cases := []Config{
		{SMTPHost: "smtp.example.com", SMTPPort: 25, SMTPUsername: "u", SMTPPassword: "p", SMTPFrom: "a@example.com", SMTPTo: "b@example.com"},
		{SMTPHost: "smtp.example.com", SMTPPort: 465, SMTPFrom: "a@example.com", SMTPTo: "b@example.com"},
		{SMTPHost: "smtp.example.com", SMTPPort: 587, SMTPUsername: "u", SMTPPassword: "p", SMTPFrom: "bad\r\nBCC:x@example.com", SMTPTo: "b@example.com"},
	}
	for _, tc := range cases {
		if _, err := ValidateConfig(tc); err == nil {
			t.Fatalf("accepted unsafe SMTP configuration %+v", tc)
		}
	}
	_, err := ValidateConfig(Config{SMTPHost: "smtp.example.com", SMTPPort: 465, SMTPUsername: "u", SMTPPassword: "p", SMTPFrom: "a@example.com", SMTPTo: "b@example.com"})
	if err != nil {
		t.Fatal(err)
	}
}
