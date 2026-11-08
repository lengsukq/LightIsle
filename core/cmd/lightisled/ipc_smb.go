package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/smbmgmt"
)

func configureSMBRootProvider(registry *roots.Registry) {
	smbmgmt.Shared().SetRootProvider(func() []smbmgmt.RootInfo {
		if registry == nil {
			return nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		list := registry.List()
		out := make([]smbmgmt.RootInfo, 0, len(list))
		for _, r := range list {
			online := false
			if ctx.Err() == nil {
				if lease, err := registry.Acquire(ctx, r.ID); err == nil {
					online = true
					_ = lease.Close()
				}
			}
			out = append(out, smbmgmt.RootInfo{
				ID:     r.ID,
				Name:   r.Name,
				Path:   r.Path,
				Online: online,
			})
		}
		return out
	})
}

type smbIPCAction struct {
	Action      string `json:"action"`
	Enabled     bool   `json:"enabled"`
	RecordName  string `json:"recordName"`
	RootID      string `json:"rootId"`
	Subpath     string `json:"subpath"`
	Path        string `json:"path"`
	SMBName     string `json:"smbName"`
	Shared      bool   `json:"shared"`
	GuestAccess bool   `json:"guestAccess"`
	ReadOnly    bool   `json:"readOnly"`
	Sealed      bool   `json:"sealed"`
}

func isSMBCommand(command string) bool {
	return command == "smb status" || command == "smb state" || strings.HasPrefix(command, "smb action ")
}

func handleSMBCommand(ctx context.Context, command string) bool {
	if !isSMBCommand(command) {
		return false
	}
	if command == "smb status" {
		if smbmgmt.Shared().ServiceEnabledQuick(ctx) {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 1")
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 0")
		}
		return true
	}
	if command == "smb state" {
		status, err := smbmgmt.Shared().Status(ctx)
		if err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_ERROR "+smbErrorCode(err))
			return true
		}
		emitSMBState(status)
		return true
	}
	if strings.HasPrefix(command, "smb action ") {
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(command, "smb action ")))
		if err != nil || len(raw) == 0 || len(raw) > 4096 {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_ERROR invalid_smb_request")
			return true
		}
		var req smbIPCAction
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_ERROR invalid_smb_request")
			return true
		}
		var status smbmgmt.Status
		var actErr error
		switch req.Action {
		case "service":
			status, actErr = smbmgmt.Shared().SetService(ctx, req.Enabled)
		case "add":
			status, actErr = smbmgmt.Shared().AddShare(ctx, smbmgmt.AddRequest{
				RootID:      req.RootID,
				Subpath:     req.Subpath,
				Path:        req.Path,
				SMBName:     req.SMBName,
				GuestAccess: req.GuestAccess,
				ReadOnly:    req.ReadOnly,
				Sealed:      req.Sealed,
			})
		case "update":
			status, actErr = smbmgmt.Shared().UpdateShare(ctx, req.RecordName, smbmgmt.UpdateRequest{
				SMBName:     req.SMBName,
				Shared:      req.Shared,
				GuestAccess: req.GuestAccess,
				ReadOnly:    req.ReadOnly,
				Sealed:      req.Sealed,
			})
		case "remove":
			status, actErr = smbmgmt.Shared().RemoveShare(ctx, req.RecordName)
		default:
			actErr = smbmgmt.ErrInvalid
		}
		if actErr != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_ERROR "+smbErrorCode(actErr))
			return true
		}
		emitSMBState(status)
		return true
	}
	return true
}

func emitSMBState(status smbmgmt.Status) {
	if status.ServiceEnabled {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 1")
	} else {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 0")
	}
	if payload, err := json.Marshal(status); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATE "+base64.RawURLEncoding.EncodeToString(payload))
	}
}

func smbErrorCode(err error) string {
	switch {
	case errors.Is(err, smbmgmt.ErrInvalid):
		return "invalid_smb_request"
	case errors.Is(err, smbmgmt.ErrNotFound):
		return "smb_share_not_found"
	case errors.Is(err, smbmgmt.ErrAlreadyExists):
		return "smb_share_already_exists"
	case errors.Is(err, smbmgmt.ErrElevationRequired):
		return "smb_elevation_required"
	case errors.Is(err, smbmgmt.ErrProtectedPath):
		return "smb_protected_path_rejected"
	case errors.Is(err, smbmgmt.ErrRootOffline):
		return "smb_root_offline"
	default:
		return "smb_operation_failed"
	}
}
