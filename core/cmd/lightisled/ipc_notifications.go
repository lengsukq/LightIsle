//go:build darwin && arm64

package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/notify"
)

// handleNotificationIPC owns the private, in-memory channel configuration.
// Never persist owner-supplied secrets or echo them back over the IPC pipe.
// The event loop alone owns testActive; the goroutine only writes completion.
func handleNotificationIPC(command string, hub *notify.Hub, testActive *bool, testDone chan<- error) bool {
	if !strings.HasPrefix(command, "notify ") {
		return false
	}
	subject := strings.TrimPrefix(command, "notify ")
	switch {
	case strings.HasPrefix(subject, "set "):
		raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(subject, "set ")))
		var config notify.Config
		if decodeErr != nil || len(raw) > 8192 || json.Unmarshal(raw, &config) != nil {
			writeStdoutLine("LIGHTISLE_NOTIFY_ERROR invalid_notify_config")
			return true
		}
		if err := hub.Update(config); err != nil {
			writeStdoutLine("LIGHTISLE_NOTIFY_ERROR " + sanitizeIPCText(err.Error()))
		} else {
			writeStdoutLine("LIGHTISLE_NOTIFY_ON")
		}
	case subject == "forget":
		if err := hub.Update(notify.Config{}); err != nil {
			writeStdoutLine("LIGHTISLE_NOTIFY_ERROR " + sanitizeIPCText(err.Error()))
		} else {
			writeStdoutLine("LIGHTISLE_NOTIFY_OFF")
		}
	case subject == "status":
		if payload, err := json.Marshal(hub.Stats()); err == nil {
			writeStdoutLine("LIGHTISLE_NOTIFY_STATUS " + base64.RawURLEncoding.EncodeToString(payload))
		}
	case subject == "test":
		if *testActive {
			writeStdoutLine("LIGHTISLE_NOTIFY_TEST_ERROR notify_test_busy")
			return true
		}
		*testActive = true
		go func() { testDone <- hub.TestSend() }()
	default:
		writeStdoutLine("LIGHTISLE_NOTIFY_ERROR unknown_notify_command")
	}
	return true
}
