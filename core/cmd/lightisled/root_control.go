//go:build darwin && arm64

package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

var (
	errRootPermissionDenied = errors.New("root_permission_denied")
	errRootReadOnly         = errors.New("root_read_only")
)

// rootControl is reachable only over the native parent's private stdin pipe.
// Root registration, one-click default selection and old-file copying cannot
// be triggered by remote HTTP clients. Paths remain private to the Mac owner.
type rootControl struct {
	registry            *roots.Registry
	accounts            *auth.Store
	output              io.Writer
	backupDestinations  func() []string
	legacySharePath     func() string
	legacyBackupRunning func() bool
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
	ID          string                 `json:"rootID"`
	Generation  uint64                 `json:"generation"`
	Name        string                 `json:"name"`
	Path        string                 `json:"path"`
	Online      bool                   `json:"online"`
	Pending     bool                   `json:"pending"`
	IsDefault   bool                   `json:"isDefault"`
	Maintenance *tasks.RootMaintenance `json:"maintenance,omitempty"`
}

func (c *rootControl) rootMaintenance(root roots.Root) *tasks.RootMaintenance {
	if c.journal == nil {
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
	for _, known := range []error{errRootPermissionDenied, errRootReadOnly,
		roots.ErrInvalid, roots.ErrMissing, roots.ErrOffline, roots.ErrOverlap,
		roots.ErrBusy, roots.ErrStale, roots.ErrDifferentDirectory, roots.ErrNotAllowed, roots.ErrPersistence,
		backup.ErrInvalid, backup.ErrRootDestinationOverlap, backup.ErrRootChanged,
		backup.ErrDestinationConfirmationRequired, backup.ErrDestinationVolumeUnavailable,
		backup.ErrDestinationVolumeMismatch, backup.ErrDestinationFolderChanged,
		backup.ErrPrivateDestinationOverlap, backup.ErrRetentionInvalid} {
		if errors.Is(err, known) {
			return known.Error()
		}
	}
	if errors.Is(err, syscall.EROFS) {
		return errRootReadOnly.Error()
	}
	if errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM) {
		return errRootPermissionDenied.Error()
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "root_operation_timed_out"
	}
	return "root_operation_failed"
}

// verifyDaemonRootReadWrite forces macOS TCC removable-volume authorization and
// verifies real directory enumeration + file creation/sync/unlink inside the Go
// daemon right when the disk is added, rather than failing later when the owner
// is away from the Mac using Web or Flutter remotely.
func verifyDaemonRootReadWrite(dir string) error {
	if err := probeSingleDirectoryReadWrite(dir); err != nil {
		return err
	}
	for _, sub := range []string{"Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-appdata"} {
		subDir := filepath.Join(dir, sub)
		if info, err := os.Lstat(subDir); err == nil && info.IsDir() {
			if err := probeSingleDirectoryReadWrite(subDir); err != nil {
				return err
			}
		}
	}
	return nil
}

func probeSingleDirectoryReadWrite(dir string) error {
	if _, err := os.ReadDir(dir); err != nil {
		return classifyRootProbeError(err)
	}
	var token [6]byte
	if _, err := rand.Read(token[:]); err != nil {
		return err
	}
	probePath := filepath.Join(dir, ".lightisle-permcheck-"+hex.EncodeToString(token[:]))
	f, err := os.OpenFile(probePath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return classifyRootProbeError(err)
	}
	_, writeErr := f.Write([]byte("ok"))
	syncErr := f.Sync()
	closeErr := f.Close()
	removeErr := os.Remove(probePath)
	for _, stepErr := range []error{writeErr, syncErr, closeErr, removeErr} {
		if stepErr != nil {
			return classifyRootProbeError(stepErr)
		}
	}
	return nil
}

func classifyRootProbeError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, syscall.EROFS):
		return errRootReadOnly
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return errRootPermissionDenied
	default:
		return err
	}
}

// prewarmRegisteredRoot prepares and verifies on-volume internal directories
// (.lightisle-trash, .lightisle-parts, .lightisle-appdata, and default media
// folders) right when the root is registered, without eagerly opening or caching
// dataDir SQLite services in RootServer.runtimes.
func (c *rootControl) prewarmRegisteredRoot(ctx context.Context, record roots.Root) error {
	if c == nil || c.registry == nil || record.ID == "" {
		return nil
	}
	lease, err := c.registry.Acquire(ctx, record.ID)
	if err != nil {
		return classifyRootProbeError(err)
	}
	defer lease.Close()

	manager, err := files.NewPinnedManager(lease.Root, record.Binding)
	if err != nil {
		return classifyRootProbeError(err)
	}
	_ = manager.Close()

	for _, internalDir := range []string{".lightisle-parts", ".lightisle-appdata"} {
		full := filepath.Join(record.Path, internalDir)
		if err := os.MkdirAll(full, 0700); err != nil {
			return classifyRootProbeError(err)
		}
		if err := probeSingleDirectoryReadWrite(full); err != nil {
			return err
		}
	}
	return nil
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
		defaultRoot, hasDefault := c.registry.Default()
		for _, root := range c.registry.List() {
			online := false
			if ctx.Err() == nil {
				if lease, err := c.registry.Acquire(ctx, root.ID); err == nil {
					online = true
					lease.Close()
				}
			}
			items = append(items, nativeRoot{ID: root.ID, Generation: root.Generation, Name: root.Name,
				Path: root.Path, Online: online, Pending: root.Pending, IsDefault: hasDefault && defaultRoot.ID == root.ID, Maintenance: c.rootMaintenance(root)})
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
		defaultRoot, hasDefault := c.registry.Default()
		for _, root := range c.registry.List() {
			online := false
			if ctx.Err() == nil {
				if lease, err := c.registry.Acquire(ctx, root.ID); err == nil {
					online = true
					lease.Close()
				}
			}
			items = append(items, nativeRoot{ID: root.ID, Generation: root.Generation, Name: root.Name,
				Path: root.Path, Online: online, Pending: root.Pending, IsDefault: hasDefault && defaultRoot.ID == root.ID, Maintenance: c.rootMaintenance(root)})
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
	if strings.HasPrefix(operation, "backup-") || strings.HasPrefix(operation, "migration-") {
		c.reply(requestID, operation, nil, roots.ErrNotAllowed)
		return true
	}
	if operation != "add" && operation != "select-folder" && operation != "verify-access" {
		found := false
		for _, root := range c.registry.List() {
			if root.ID == request.ID {
				found = true
				if request.Generation == 0 || root.Generation != request.Generation {
					c.reply(requestID, operation, nil, roots.ErrStale)
					return true
				}
			}
		}
		if !found {
			c.reply(requestID, operation, nil, roots.ErrMissing)
			return true
		}
	}
	if operation == "verify-access" {
		if !request.present.hasOnly("requestID", "path") || !request.present.path {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return true
		}
		resolved, pathErr := filepath.EvalSymlinks(request.Path)
		if pathErr != nil {
			c.reply(requestID, operation, nil, classifyRootProbeError(pathErr))
			return true
		}
		resolved = filepath.Clean(resolved)
		if resolved == "/" || resolved == "/Volumes" {
			c.reply(requestID, operation, nil, roots.ErrNotAllowed)
			return true
		}
		if probeErr := verifyDaemonRootReadWrite(resolved); probeErr != nil {
			c.reply(requestID, operation, nil, probeErr)
			return true
		}
		for _, existing := range c.registry.List() {
			if existing.Path == resolved || strings.HasPrefix(existing.Path, resolved+string(filepath.Separator)) {
				if c.accounts != nil {
					_ = c.accounts.SyncVerifiedRootGeneration(existing.ID, existing.Generation)
				}
				_ = c.prewarmRegisteredRoot(ctx, existing)
			}
		}
		c.reply(requestID, operation, map[string]any{"path": resolved, "writable": true}, nil)
		return true
	}
	if operation == "add" || operation == "rebind" || operation == "select-folder" {
		if c.legacyBackupRunning != nil && c.legacyBackupRunning() {
			c.reply(requestID, operation, nil, roots.ErrBusy)
			return true
		}
		resolved, pathErr := filepath.EvalSymlinks(request.Path)
		if pathErr != nil {
			c.reply(requestID, operation, nil, roots.ErrNotAllowed)
			return true
		}
		// While the compatibility Manager still points at the imported
		// directory, allow only that rootID to explicitly rebind the exact
		// same folder. Any new/other root must not overlap the old handler.
		if c.legacySharePath != nil {
			if legacy := c.legacySharePath(); legacy != "" && rootPathsOverlap(resolved, legacy) {
				allowedRebind := false
				if operation == "rebind" && legacy == resolved {
					for _, existing := range c.registry.List() {
						if existing.ID == request.ID && existing.Path == resolved {
							allowedRebind = true
							break
						}
					}
				}
				if !allowedRebind {
					c.reply(requestID, operation, nil, roots.ErrOverlap)
					return true
				}
			}
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
	case "select-folder":
		if !request.present.hasOnly("requestID", "path", "name") ||
			!request.present.path || request.Name == "" {
			err = roots.ErrInvalid
			break
		}
		if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
			err = probeErr
			break
		}
		var found *roots.Root
		for _, existing := range c.registry.List() {
			if existing.Path == request.Path {
				match := existing
				found = &match
				break
			}
		}
		if found == nil {
			created, addErr := c.registry.Add(ctx, request.Name, request.Path)
			if addErr != nil {
				err = addErr
				break
			}
			found = &created
		}
		err = c.registry.SetDefault(ctx, found.ID, found.Generation)
		if err == nil {
			err = c.prewarmRegisteredRoot(ctx, *found)
		}
		result = found
	case "add":
		if !request.present.hasOnly("requestID", "name", "path") {
			err = roots.ErrInvalid
			break
		}
		if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
			err = probeErr
			break
		}
		created, addErr := c.registry.Add(ctx, request.Name, request.Path)
		if addErr != nil {
			err = addErr
			break
		}
		if prewarmErr := c.prewarmRegisteredRoot(ctx, created); prewarmErr != nil {
			_ = c.registry.Remove(created.ID)
			err = prewarmErr
			break
		}
		result = created
	case "rebind":
		if !request.present.hasOnly("requestID", "rootID", "generation", "path") ||
			!request.present.id || !request.present.generation || !request.present.path {
			err = roots.ErrInvalid
			break
		}
		if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
			err = probeErr
			break
		}
		var rebound roots.Root
		rebound, err = c.registry.Rebind(ctx, request.ID, request.Path)
		if err == nil {
			if c.accounts != nil {
				_ = c.accounts.SyncVerifiedRootGeneration(rebound.ID, rebound.Generation)
			}
			if prewarmErr := c.prewarmRegisteredRoot(ctx, rebound); prewarmErr != nil {
				err = prewarmErr
				break
			}
			if c.server != nil {
				c.server.QueueMediaRefresh(rebound.ID, "")
			}
			result = rebound
		}
	case "remove":
		if !request.present.hasOnly("requestID", "rootID", "generation") ||
			!request.present.id || !request.present.generation {
			err = roots.ErrInvalid
			break
		}
		err = c.registry.Remove(request.ID)
		result = map[string]string{"rootID": request.ID}
	case "set-default":
		if !request.present.hasOnly("requestID", "rootID", "generation") ||
			!request.present.id || !request.present.generation {
			err = roots.ErrInvalid
			break
		}
		err = c.registry.SetDefault(ctx, request.ID, request.Generation)
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
	// On macOS /var is an alias for /private/var; similarly a mounted
	// directory can have a linked ancestor. Compare canonical candidates so
	// callers cannot register the same root through two path spellings.
	if resolved, err := canonicalPathForOverlap(a); err == nil {
		a = resolved
	}
	if resolved, err := canonicalPathForOverlap(b); err == nil {
		b = resolved
	}
	a, b = filepath.Clean(a), filepath.Clean(b)
	return a == b || strings.HasPrefix(a, b+string(filepath.Separator)) || strings.HasPrefix(b, a+string(filepath.Separator))
}

// A default-share switch may coexist with the v2 root API provided it cannot
// accidentally expose the same physical directory under two authorization
// scopes. Invalid/offline targets are still rejected by the legacy manager.
func checkLegacyShareRootOverlap(target string, registered []roots.Root) error {
	resolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		return err
	}
	for _, root := range registered {
		if rootPathsOverlap(resolved, root.Path) {
			return roots.ErrOverlap
		}
	}
	return nil
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
