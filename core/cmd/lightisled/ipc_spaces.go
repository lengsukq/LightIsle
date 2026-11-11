//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

type nativeSpaceUser struct {
	User   auth.User          `json:"user"`
	Policy auth.StoragePolicy `json:"policy"`
}

type nativeSpaceRoot struct {
	ID                       string `json:"rootID"`
	Generation               uint64 `json:"generation"`
	Name                     string `json:"name"`
	Path                     string `json:"path"`
	Online                   bool   `json:"online"`
	IsDefault                bool   `json:"isDefault"`
	FilesystemTotalBytes     uint64 `json:"filesystemTotalBytes,omitempty"`
	FilesystemAvailableBytes uint64 `json:"filesystemAvailableBytes,omitempty"`
}

type nativeSpacesOverview struct {
	Users       []nativeSpaceUser                 `json:"users"`
	Roots       []nativeSpaceRoot                 `json:"roots"`
	CreatedUser *auth.User                        `json:"createdUser,omitempty"`
	Transfer    *server.SwitchUserStorageResponse `json:"transfer,omitempty"`
}

type spacesIPCRequest struct {
	RequestID        string   `json:"requestID,omitempty"`
	UserID           int64    `json:"userID,omitempty"`
	Username         string   `json:"username,omitempty"`
	Password         string   `json:"password,omitempty"`
	Role             string   `json:"role,omitempty"`
	Enabled          *bool    `json:"enabled,omitempty"`
	RootID           string   `json:"rootID,omitempty"`
	Generation       uint64   `json:"generation,omitempty"`
	QuotaBytes       *int64   `json:"quotaBytes,omitempty"`
	Categories       []string `json:"categories,omitempty"`
	Subdirectories   []string `json:"subdirectories,omitempty"`
	Category         string   `json:"category,omitempty"`
	SourceRootID     string   `json:"sourceRootID,omitempty"`
	SourceGeneration uint64   `json:"sourceGeneration,omitempty"`
	TargetRootID     string   `json:"targetRootID,omitempty"`
	TargetGeneration uint64   `json:"targetGeneration,omitempty"`
	TargetQuotaBytes *int64   `json:"targetQuotaBytes,omitempty"`
	Mode             string   `json:"mode,omitempty"`
	Phase            string   `json:"phase,omitempty"`
	TaskID           string   `json:"taskID,omitempty"`
}

func emitSpacesReply(requestID, operation string, result any, err error) {
	response := map[string]any{
		"schemaVersion": 1,
		"operation":     operation,
		"requestID":     requestID,
	}
	if result != nil {
		response["result"] = result
	}
	if err != nil {
		response["error"] = spacesErrorCode(err)
	}
	data, encodeErr := json.Marshal(response)
	if encodeErr != nil {
		data, _ = json.Marshal(map[string]any{
			"schemaVersion": 1,
			"operation":     operation,
			"requestID":     requestID,
			"error":         "spaces_response_encode_failed",
		})
	}
	writeStdoutLine("LIGHTISLE_SPACES " + base64.RawURLEncoding.EncodeToString(data))
}

func spacesErrorCode(err error) string {
	switch {
	case errors.Is(err, auth.ErrExists):
		return "account_already_exists"
	case errors.Is(err, auth.ErrInput):
		return "storage_invalid_request"
	case errors.Is(err, auth.ErrForbidden):
		return "storage_permission_denied"
	case errors.Is(err, auth.ErrNotFound):
		return "user_not_found"
	case errors.Is(err, auth.ErrStorageQuotaExceeded):
		return "storage_quota_exceeded"
	case errors.Is(err, auth.ErrStorageReassignmentRequiresMigration):
		return "storage_migration_required"
	case errors.Is(err, auth.ErrStorageLedgerConflict):
		return "storage_accounting_conflict"
	case errors.Is(err, auth.ErrStorageUnassigned):
		return "storage_destination_not_assigned"
	case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrStale):
		return "root_unavailable"
	case errors.Is(err, roots.ErrMissing):
		return "root_not_found"
	case errors.Is(err, files.ErrRootBusy):
		return "storage_switch_busy"
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EROFS), errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "storage_permission_os_denied"
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, files.ErrInsufficientSpace):
		return "storage_switch_disk_full"
	default:
		msg := err.Error()
		if msg != "" && !strings.ContainsAny(msg, " \t\n") {
			return msg
		}
		return "storage_operation_failed"
	}
}

func buildNativeSpacesOverview(ctx context.Context, accountStore *auth.Store, rootRegistry *roots.Registry) (nativeSpacesOverview, error) {
	spaceRoots := make([]nativeSpaceRoot, 0)
	if rootRegistry != nil {
		defaultRoot, hasDefault := rootRegistry.Default()
		for _, r := range rootRegistry.List() {
			online := false
			var totalBytes, availBytes uint64
			if ctx.Err() == nil {
				if lease, err := rootRegistry.Acquire(ctx, r.ID); err == nil {
					online = true
					if accountStore != nil {
						_ = accountStore.SyncVerifiedRootGeneration(r.ID, r.Generation)
					}
					var stat syscall.Statfs_t
					if syscall.Statfs(r.Path, &stat) == nil && stat.Bsize > 0 {
						totalBytes = uint64(stat.Blocks) * uint64(stat.Bsize)
						availBytes = uint64(stat.Bavail) * uint64(stat.Bsize)
					}
					_ = lease.Close()
				}
			}
			spaceRoots = append(spaceRoots, nativeSpaceRoot{
				ID:                       r.ID,
				Generation:               r.Generation,
				Name:                     r.Name,
				Path:                     r.Path,
				Online:                   online,
				IsDefault:                hasDefault && defaultRoot.ID == r.ID,
				FilesystemTotalBytes:     totalBytes,
				FilesystemAvailableBytes: availBytes,
			})
		}
	}
	users, err := accountStore.NativeListUsers()
	if err != nil {
		return nativeSpacesOverview{}, err
	}
	spaceUsers := make([]nativeSpaceUser, 0, len(users))
	for _, u := range users {
		policy, err := accountStore.NativeStoragePolicy(u.ID)
		if err != nil {
			return nativeSpacesOverview{}, err
		}
		spaceUsers = append(spaceUsers, nativeSpaceUser{User: u, Policy: policy})
	}
	return nativeSpacesOverview{Users: spaceUsers, Roots: spaceRoots}, nil
}

func decodeSpacesRequest(encoded string) (spacesIPCRequest, error) {
	if encoded == "" {
		return spacesIPCRequest{}, nil
	}
	if len(encoded) > 12000 {
		return spacesIPCRequest{}, auth.ErrInput
	}
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return spacesIPCRequest{}, auth.ErrInput
	}
	var req spacesIPCRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return spacesIPCRequest{}, auth.ErrInput
	}
	return req, nil
}

func handleSpacesIPC(
	parentCtx context.Context,
	command string,
	accountStore *auth.Store,
	rootRegistry *roots.Registry,
	rootServer *server.RootServer,
) bool {
	if !strings.HasPrefix(command, "spaces ") && command != "spaces" {
		return false
	}
	words := strings.Fields(command)
	operation := "list"
	if len(words) > 1 {
		operation = words[1]
	}
	var encoded string
	if len(words) > 2 {
		encoded = words[2]
	}
	req, err := decodeSpacesRequest(encoded)
	if err != nil {
		emitSpacesReply(req.RequestID, operation, nil, err)
		return true
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	switch operation {
	case "list":
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "create-user":
		overview, err := handleCreateSpaceUser(ctx, accountStore, rootRegistry, rootServer, req)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "set-user-enabled":
		if req.Enabled == nil {
			emitSpacesReply(req.RequestID, operation, nil, auth.ErrInput)
			return true
		}
		if err := accountStore.NativeSetUserEnabled(req.UserID, *req.Enabled); err != nil {
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "reset-user-password":
		if err := accountStore.NativeResetMemberPassword(req.UserID, req.Password); err != nil {
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "allocate":
		if rootServer == nil {
			emitSpacesReply(req.RequestID, operation, nil, errors.New("root_services_unavailable"))
			return true
		}
		_, err := rootServer.ExecuteAllocateUserStorage(
			ctx, "", true, req.UserID, req.RootID, req.Generation,
			req.QuotaBytes, req.Categories, req.Subdirectories,
		)
		if err != nil {
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "set-quota":
		if req.QuotaBytes == nil {
			emitSpacesReply(req.RequestID, operation, nil, auth.ErrInput)
			return true
		}
		if err := accountStore.NativeSetUserStorageRootQuota(req.UserID, req.RootID, req.Generation, *req.QuotaBytes); err != nil {
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	case "switch-root":
		if rootServer == nil {
			emitSpacesReply(req.RequestID, operation, nil, errors.New("root_services_unavailable"))
			return true
		}
		transferResp, err := rootServer.ExecuteSwitchUserStorage(ctx, "", true, req.UserID, server.SwitchUserStorageRequest{
			TaskID:           req.TaskID,
			Categories:       req.Categories,
			SourceRootID:     req.SourceRootID,
			SourceGeneration: req.SourceGeneration,
			TargetRootID:     req.TargetRootID,
			TargetGeneration: req.TargetGeneration,
			TargetQuotaBytes: req.TargetQuotaBytes,
			Mode:             req.Mode,
			Phase:            req.Phase,
		})
		if err != nil {
			if transferResp.TaskID != "" {
				if overview, ovErr := buildNativeSpacesOverview(ctx, accountStore, rootRegistry); ovErr == nil {
					overview.Transfer = &transferResp
					emitSpacesReply(req.RequestID, operation, overview, err)
					return true
				}
			}
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		if err != nil {
			emitSpacesReply(req.RequestID, operation, nil, err)
			return true
		}
		overview.Transfer = &transferResp
		emitSpacesReply(req.RequestID, operation, overview, nil)
		return true

	case "abandon":
		if rootRegistry != nil {
			for _, r := range rootRegistry.List() {
				if r.ID == req.RootID {
					emitSpacesReply(req.RequestID, operation, nil, errors.New("storage_remove_root_first"))
					return true
				}
			}
		}
		var abandonErr error
		if req.Category != "" {
			abandonErr = accountStore.NativeAbandonUserStorageLocation(req.UserID, req.Category, req.RootID, req.Generation)
		} else {
			abandonErr = accountStore.NativeAbandonUserStorageRoot(req.UserID, req.RootID, req.Generation)
		}
		if abandonErr != nil {
			emitSpacesReply(req.RequestID, operation, nil, abandonErr)
			return true
		}
		overview, err := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
		emitSpacesReply(req.RequestID, operation, overview, err)
		return true

	default:
		emitSpacesReply(req.RequestID, operation, nil, auth.ErrInput)
		return true
	}
}

func handleCreateSpaceUser(
	ctx context.Context,
	accountStore *auth.Store,
	rootRegistry *roots.Registry,
	rootServer *server.RootServer,
	req spacesIPCRequest,
) (*nativeSpacesOverview, error) {
	role := req.Role
	if role == "" {
		role = auth.RoleMember
	}
	created, err := accountStore.NativeCreateUser(req.Username, req.Password, role)
	if err != nil {
		return nil, err
	}
	var allocErr error
	if req.RootID != "" && req.Generation > 0 {
		if rootServer == nil {
			allocErr = errors.New("root_services_unavailable")
		} else {
			_, allocErr = rootServer.ExecuteAllocateUserStorage(
				ctx, "", true, created.ID, req.RootID, req.Generation,
				req.QuotaBytes, req.Categories, req.Subdirectories,
			)
		}
	}
	overview, overviewErr := buildNativeSpacesOverview(ctx, accountStore, rootRegistry)
	if overviewErr != nil {
		if allocErr != nil {
			return &nativeSpacesOverview{CreatedUser: &created}, allocErr
		}
		return &nativeSpacesOverview{CreatedUser: &created}, overviewErr
	}
	overview.CreatedUser = &created
	return &overview, allocErr
}
