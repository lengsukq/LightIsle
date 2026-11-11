//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/diskhealth"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
)

func emitDiskError(reason string) {
	msg := sanitizeIPCText(reason)
	if msg == "" {
		msg = "disk_operation_failed"
	}
	writeStdoutLine("LIGHTISLE_DISKS_ERROR " + msg)
}

// handleDiskIPC is called only from the Mac owner's private IPC channel.
// Keep potentially privileged disk operations isolated from the main
// service event loop, preserving its existing response protocol.
func handleDiskIPC(ctx context.Context, command string) bool {
	switch {
	case command == "disk list":
		disks, err := diskmgmt.Shared().List(ctx)
		if err != nil {
			emitDiskError(err.Error())
		} else if data, err := json.Marshal(disks); err == nil {
			writeStdoutLine("LIGHTISLE_DISKS " + base64.RawURLEncoding.EncodeToString(data))
		}
		return true
	case strings.HasPrefix(command, "disk action "):
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "disk action "))
		var request diskmgmt.Request
		if err != nil || len(raw) == 0 || len(raw) > 2048 || json.Unmarshal(raw, &request) != nil {
			emitDiskError("invalid_drive_request")
			return true
		}
		disks, err := diskmgmt.Shared().Do(ctx, request)
		if err != nil {
			emitDiskError(err.Error())
		} else if data, err := json.Marshal(disks); err == nil {
			writeStdoutLine("LIGHTISLE_DISKS " + base64.RawURLEncoding.EncodeToString(data))
		}
		return true
	case strings.HasPrefix(command, "disk smart "):
		id := strings.TrimPrefix(command, "disk smart ")
		if strings.HasPrefix(id, "report ") {
			// Trusted Mac App pushed a user-authorized elevated SMART
			// result; cache it so the Web view benefits too.
			raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(id, "report "))
			var request struct {
				Device string          `json:"device"`
				Report json.RawMessage `json:"report"`
			}
			if decodeErr != nil || len(raw) == 0 || len(raw) > 76800 || json.Unmarshal(raw, &request) != nil {
				emitDiskError("invalid_drive_request")
				return true
			}
			report, err := diskhealth.Shared().IngestReport(request.Device, request.Report)
			if err != nil {
				emitDiskError("invalid_drive_request")
				return true
			}
			if data, err := json.Marshal(report); err == nil {
				writeStdoutLine("LIGHTISLE_DISK_SMART " + base64.RawURLEncoding.EncodeToString(data))
			}
			return true
		}
		report, err := diskhealth.Shared().Report(ctx, id)
		if err != nil {
			emitDiskError("invalid_drive_request")
		} else if data, err := json.Marshal(report); err == nil {
			writeStdoutLine("LIGHTISLE_DISK_SMART " + base64.RawURLEncoding.EncodeToString(data))
		}
		return true
	}
	return false
}
