//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// rootControl is reachable only over the native parent's private stdin pipe.
// The entire surface stays disabled without the explicit developer preview.
// Paths are returned solely to that parent, never through root discovery.
type rootControl struct {
	registry            *roots.Registry
	output              io.Writer
	backupDestinations  func() []string
	legacyBackupRunning func() bool
	verifyLegacyRoot    func(context.Context, string, uint64) (roots.Root, error)
	server              *server.RootServer
	journal             *tasks.Journal
}

type rootControlRequest struct {
	ID             string                     `json:"rootID,omitempty"`
	Generation     uint64                     `json:"generation,omitempty"`
	Name           string                     `json:"name,omitempty"`
	Path           string                     `json:"path,omitempty"`
	RequestID      string                     `json:"requestID,omitempty"`
	EveryHours     *int                       `json:"everyHours,omitempty"`
	RetentionCount *int                       `json:"retentionCount,omitempty"`
	present        rootControlRequestPresence `json:"-"`
}

type rootControlRequestPresence struct {
	id, generation, name, path, requestID, everyHours, retentionCount bool
}

func (p rootControlRequestPresence) hasOnly(allowed ...string) bool {
	allowedFields := make(map[string]bool, len(allowed))
	for _, field := range allowed {
		allowedFields[field] = true
	}
	for field, set := range map[string]bool{
		"rootID": p.id, "generation": p.generation, "name": p.name, "path": p.path,
		"requestID": p.requestID, "everyHours": p.everyHours, "retentionCount": p.retentionCount,
	} {
		if set && !allowedFields[field] {
			return false
		}
	}
	return true
}

type nativeRoot struct {
	ID            string                 `json:"rootID"`
	Generation    uint64                 `json:"generation"`
	Name          string                 `json:"name"`
	Path          string                 `json:"path"`
	Online        bool                   `json:"online"`
	Pending       bool                   `json:"pending"`
	Compatibility bool                   `json:"compatibility"`
	Maintenance   *tasks.RootMaintenance `json:"maintenance,omitempty"`
}

func (c *rootControl) rootMaintenance(root roots.Root) *tasks.RootMaintenance {
	if c.journal == nil || root.Compatibility {
		return nil
	}
	info, err := c.journal.RootMaintenanceStatus(root.ID, root.Generation)
	if err != nil {
		return nil
	}
	return &info
}

func (c *rootControl) reply(requestID, operation string, value any, err error) {
	response := map[string]any{"schemaVersion": 1, "operation": operation, "requestID": requestID}
	if err != nil {
		response["error"] = rootControlError(err)
	} else {
		response["result"] = value
	}
	data, encodeErr := json.Marshal(response)
	if encodeErr != nil || len(data) > 128<<10 {
		data, _ = json.Marshal(map[string]any{
			"schemaVersion": 1, "operation": operation, "requestID": requestID,
			"error": "invalid_root_response",
		})
	}
	fmt.Fprintln(c.output, "LIGHTISLE_ROOTS "+base64.RawURLEncoding.EncodeToString(data))
}

func rootControlError(err error) string {
	for _, known := range []error{roots.ErrInvalid, roots.ErrMissing, roots.ErrOffline, roots.ErrOverlap,
		roots.ErrBusy, roots.ErrStale, roots.ErrDifferentDirectory, roots.ErrNotAllowed, roots.ErrPersistence,
		backup.ErrInvalid, backup.ErrRootDestinationOverlap, backup.ErrRootChanged, backup.ErrRootPlanUnavailable,
		backup.ErrRootPlanConfigInvalid, backup.ErrRootPlanConfigUnsafe, backup.ErrRootPlanArchiveFailed,
		backup.ErrDestinationConfirmationRequired, backup.ErrDestinationVolumeUnavailable,
		backup.ErrDestinationVolumeMismatch, backup.ErrDestinationFolderChanged,
		backup.ErrPrivateDestinationOverlap, backup.ErrRetentionInvalid} {
		if errors.Is(err, known) {
			return known.Error()
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "root_operation_timed_out"
	}
	return "root_operation_failed"
}

func (c *rootControl) handle(ctx context.Context, command string) bool {
	if !strings.HasPrefix(command, "roots ") {
		return false
	}
	words := strings.Fields(command)
	operation := "request"
	if len(words) > 1 {
		operation = words[1]
	}
	if c == nil {
		return true
	}
	if c.registry == nil {
		c.reply(rootControlRequestIDFromWords(words), operation, nil, roots.ErrNotAllowed)
		return true
	}
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	if operation == "list" && len(words) == 2 {
		items := make([]nativeRoot, 0)
		for _, root := range c.registry.List() {
			online := false
			if ctx.Err() == nil {
				if lease, err := c.registry.Acquire(ctx, root.ID); err == nil {
					online = true
					lease.Close()
				}
			}
			items = append(items, nativeRoot{ID: root.ID, Generation: root.Generation, Name: root.Name,
				Path: root.Path, Online: online, Pending: root.Pending, Compatibility: root.Compatibility, Maintenance: c.rootMaintenance(root)})
		}
		c.reply("", operation, items, nil)
		return true
	}
	if operation == "list" && len(words) == 3 {
		request, err := decodeRootControlRequest(words[2])
		requestID := validRootControlRequestID(request.RequestID)
		if err != nil || !request.present.hasOnly("requestID") {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return true
		}
		items := make([]nativeRoot, 0)
		for _, root := range c.registry.List() {
			online := false
			if ctx.Err() == nil {
				if lease, err := c.registry.Acquire(ctx, root.ID); err == nil {
					online = true
					lease.Close()
				}
			}
			items = append(items, nativeRoot{ID: root.ID, Generation: root.Generation, Name: root.Name,
				Path: root.Path, Online: online, Pending: root.Pending, Compatibility: root.Compatibility, Maintenance: c.rootMaintenance(root)})
		}
		c.reply(requestID, operation, items, nil)
		return true
	}
	if len(words) != 3 || len(words[2]) > 8192 {
		c.reply(rootControlRequestIDFromWords(words), operation, nil, roots.ErrInvalid)
		return true
	}
	request, err := decodeRootControlRequest(words[2])
	requestID := validRootControlRequestID(request.RequestID)
	if err != nil {
		c.reply(requestID, operation, nil, roots.ErrInvalid)
		return true
	}
	// Family edition does not provide whole-disk snapshot, per-root backup
	// schedules, or legacy migration analysis. Reject old IPC callers too.
	if operation == "migration-preview" || strings.HasPrefix(operation, "backup-") {
		c.reply(requestID, operation, nil, roots.ErrNotAllowed)
		return true
	}
	if operation == "legacy-verify" {
		if request.ID == "" || request.Generation == 0 || !request.present.hasOnly("requestID", "rootID", "generation") ||
			!request.present.id || !request.present.generation || c.verifyLegacyRoot == nil {
			c.reply(requestID, operation, nil, roots.ErrNotAllowed)
			return true
		}
		item, err := c.verifyLegacyRoot(ctx, request.ID, request.Generation)
		c.reply(requestID, operation, item, err)
		return true
	}
	if operation != "add" {
		found := false
		for _, root := range c.registry.List() {
			if root.ID == request.ID {
				found = true
				if request.Generation == 0 || root.Generation != request.Generation {
					c.reply(requestID, operation, nil, roots.ErrStale)
					return true
				}
				// The legacy v1 surface is still owned by the original native
				// single-folder flow. Preview cannot mutate its compatibility root.
				if root.Compatibility {
					c.reply(requestID, operation, nil, roots.ErrNotAllowed)
					return true
				}
			}
		}
		if !found {
			c.reply(requestID, operation, nil, roots.ErrMissing)
			return true
		}
	}
	if operation == "add" || operation == "rebind" {
		if c.legacyBackupRunning != nil && c.legacyBackupRunning() {
			c.reply(requestID, operation, nil, roots.ErrBusy)
			return true
		}
		resolved, pathErr := filepath.EvalSymlinks(request.Path)
		if pathErr != nil {
			c.reply(requestID, operation, nil, roots.ErrNotAllowed)
			return true
		}
		targets := []string{}
		if c.backupDestinations != nil {
			targets = append(targets, c.backupDestinations()...)
		}
		for _, target := range targets {
			if target == "" {
				continue
			}
			canonical, err := canonicalPathForOverlap(target)
			if err != nil {
				c.reply(requestID, operation, nil, roots.ErrOverlap)
				return true
			}
			if rootPathsOverlap(resolved, canonical) {
				c.reply(requestID, operation, nil, roots.ErrOverlap)
				return true
			}
		}
		request.Path = resolved
	}
	var result any
	switch operation {
	case "add":
		if !request.present.hasOnly("requestID", "name", "path") {
			err = roots.ErrInvalid
			break
		}
		result, err = c.registry.Add(ctx, request.Name, request.Path)
	case "rebind":
		if !request.present.hasOnly("requestID", "rootID", "generation", "path") ||
			!request.present.id || !request.present.generation || !request.present.path {
			err = roots.ErrInvalid
			break
		}
		result, err = c.registry.Rebind(ctx, request.ID, request.Path)
	case "remove":
		if !request.present.hasOnly("requestID", "rootID", "generation") ||
			!request.present.id || !request.present.generation {
			err = roots.ErrInvalid
			break
		}
		err = c.registry.Remove(request.ID)
		result = map[string]string{"rootID": request.ID}
	default:
		err = roots.ErrInvalid
	}
	c.reply(requestID, operation, result, err)
	return true
}

func decodeRootControlRequest(raw string) (rootControlRequest, error) {
	var request rootControlRequest
	if len(raw) == 0 || len(raw) > 8192 {
		return request, roots.ErrInvalid
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || len(data) > 6144 {
		return request, roots.ErrInvalid
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, roots.ErrInvalid
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return request, roots.ErrInvalid
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return request, roots.ErrInvalid
	}
	_, request.present.id = fields["rootID"]
	_, request.present.generation = fields["generation"]
	_, request.present.name = fields["name"]
	_, request.present.path = fields["path"]
	_, request.present.requestID = fields["requestID"]
	_, request.present.everyHours = fields["everyHours"]
	_, request.present.retentionCount = fields["retentionCount"]
	if len(request.RequestID) > 64 {
		return request, roots.ErrInvalid
	}
	return request, nil
}

func validRootControlRequestID(requestID string) string {
	if len(requestID) > 64 {
		return ""
	}
	return requestID
}

func rootControlRequestIDFromWords(words []string) string {
	if len(words) < 3 || len(words[2]) > 8192 {
		return ""
	}
	request, _ := decodeRootControlRequest(words[2])
	return validRootControlRequestID(request.RequestID)
}

func (c *rootControl) Close() {}

func rootPathsOverlap(a, b string) bool {
	a, b = filepath.Clean(a), filepath.Clean(b)
	return a == b || strings.HasPrefix(a, b+string(filepath.Separator)) || strings.HasPrefix(b, a+string(filepath.Separator))
}

// canonicalPathForOverlap resolves existing symlink ancestors even when a
// scheduled destination directory has temporarily gone offline or has not yet
// been created. That keeps root registration checks stable across remounts.
func canonicalPathForOverlap(name string) (string, error) {
	if name == "" || !filepath.IsAbs(name) {
		return "", roots.ErrInvalid
	}
	name = filepath.Clean(name)
	if resolved, err := filepath.EvalSymlinks(name); err == nil {
		return resolved, nil
	}
	var suffix []string
	for current := name; ; current = filepath.Dir(current) {
		parent := filepath.Dir(current)
		if parent == current {
			resolved, err := filepath.EvalSymlinks(current)
			if err != nil {
				return "", err
			}
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return filepath.Clean(resolved), nil
		}
		suffix = append(suffix, filepath.Base(current))
		if resolved, err := filepath.EvalSymlinks(parent); err == nil {
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return filepath.Clean(resolved), nil
		}
	}
}
