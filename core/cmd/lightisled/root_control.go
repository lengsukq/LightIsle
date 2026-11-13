//go:build darwin && arm64

package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
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

const (
	maxRootIPCResponseBytes = 128 << 10
	maxRootEncodedArgBytes  = 8192
	maxRootDecodedJSONBytes = 6144
	maxRootRequestIDChars   = 64
	rootControlTimeout      = 12 * time.Second
)

var (
	errRootPermissionDenied = errors.New("root_permission_denied")
	errRootReadOnly         = errors.New("root_read_only")
)

// rootControl is reachable only over the native parent's private stdin pipe.
// Root registration, one-click default selection and old-file copying cannot
// be triggered by remote HTTP clients. Paths remain private to the Mac owner.
type rootControl struct {
	dataDir             string
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
	var errMsg string
	includeResult := err == nil
	if err != nil {
		errMsg = rootControlError(err)
	}
	writeIPCEnvelope(ipcEnvelopeOptions{
		Output:        c.output,
		Prefix:        "LIGHTISLE_ROOTS",
		RequestID:     requestID,
		Operation:     operation,
		Result:        value,
		IncludeResult: includeResult,
		ErrorMessage:  errMsg,
		FallbackError: "invalid_root_response",
		MaxJSONBytes:  maxRootIPCResponseBytes,
	})
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

func externalVolumeMountRoot(dir string) string {
	clean := filepath.Clean(dir)
	if !strings.HasPrefix(clean, "/Volumes/") {
		return ""
	}
	rest := strings.TrimPrefix(clean, "/Volumes/")
	if rest == "" {
		return ""
	}
	parts := strings.SplitN(rest, string(filepath.Separator), 2)
	if parts[0] == "" {
		return ""
	}
	return filepath.Join("/Volumes", parts[0])
}

// verifyDaemonRootReadWrite forces macOS TCC removable-volume authorization and
// verifies real whole-volume + directory enumeration + file creation/sync/unlink
// inside the Go daemon right when the disk is added, rather than failing later
// when the owner is away from the Mac or migrating data across disks.
func verifyDaemonRootReadWrite(dir string) error {
	cleanDir := filepath.Clean(dir)
	if mountRoot := externalVolumeMountRoot(cleanDir); mountRoot != "" && mountRoot != cleanDir {
		if err := probeSingleDirectoryReadWrite(mountRoot); err != nil {
			return err
		}
	}
	if err := probeSingleDirectoryReadWrite(cleanDir); err != nil {
		return err
	}
	for _, sub := range []string{"Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-uploads", ".lightisle-appdata"} {
		subDir := filepath.Join(cleanDir, sub)
		info, err := os.Lstat(subDir)
		if err != nil || !info.IsDir() {
			continue
		}
		if err := probeSingleDirectoryReadWrite(subDir); err != nil {
			return err
		}
		if sub == "Users" {
			if err := verifyNestedUserDirectoriesWritable(subDir); err != nil {
				return err
			}
		}
	}
	return nil
}

func verifyNestedUserDirectoriesWritable(usersDir string) error {
	entries, err := os.ReadDir(usersDir)
	if err != nil {
		return classifyRootProbeError(err)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		userPath := filepath.Join(usersDir, entry.Name())
		if err := probeSingleDirectoryReadWrite(userPath); err != nil {
			return err
		}
		catEntries, err := os.ReadDir(userPath)
		if err != nil {
			return classifyRootProbeError(err)
		}
		for _, cat := range catEntries {
			if !cat.IsDir() {
				continue
			}
			if err := probeSingleDirectoryReadWrite(filepath.Join(userPath, cat.Name())); err != nil {
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

	for _, internalDir := range []string{"Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-uploads", ".lightisle-appdata"} {
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
	ctx, cancel := context.WithTimeout(ctx, rootControlTimeout)
	defer cancel()

	if operation == "list" && (len(words) == 2 || len(words) == 3) {
		c.handleListCommand(ctx, words)
		return true
	}
	if len(words) != 3 || len(words[2]) > maxRootEncodedArgBytes {
		c.reply(rootControlRequestIDFromWords(words), operation, nil, roots.ErrInvalid)
		return true
	}
	request, err := decodeRootControlRequest(words[2])
	requestID := validRootControlRequestID(request.RequestID)
	if err != nil {
		c.reply(requestID, operation, nil, roots.ErrInvalid)
		return true
	}
	if isRetiredRootOperation(operation) {
		c.reply(requestID, operation, nil, roots.ErrNotAllowed)
		return true
	}
	if requiresExistingRootGeneration(operation) {
		if genErr := c.verifyRootGeneration(request.ID, request.Generation); genErr != nil {
			c.reply(requestID, operation, nil, genErr)
			return true
		}
	}
	if operation == "verify-access" {
		c.handleVerifyAccess(ctx, requestID, request)
		return true
	}
	if operation == "add" || operation == "rebind" || operation == "select-folder" {
		resolved, prepErr := c.prepareTargetRootPath(operation, request)
		if prepErr != nil {
			c.reply(requestID, operation, nil, prepErr)
			return true
		}
		request.Path = resolved
	}
	result, mutErr := c.executeMutation(ctx, operation, request)
	c.reply(requestID, operation, result, mutErr)
	return true
}

func isRetiredRootOperation(operation string) bool {
	// Family edition does not provide whole-disk snapshot, per-root backup
	// schedules, or legacy migration analysis. Reject old IPC callers too.
	return strings.HasPrefix(operation, "backup-") || strings.HasPrefix(operation, "migration-")
}

func requiresExistingRootGeneration(operation string) bool {
	return operation != "add" && operation != "select-folder" && operation != "verify-access"
}

func (c *rootControl) listNativeRoots(ctx context.Context) []nativeRoot {
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
		items = append(items, nativeRoot{
			ID:          root.ID,
			Generation:  root.Generation,
			Name:        root.Name,
			Path:        root.Path,
			Online:      online,
			Pending:     root.Pending,
			IsDefault:   hasDefault && defaultRoot.ID == root.ID,
			Maintenance: c.rootMaintenance(root),
		})
	}
	return items
}

func (c *rootControl) handleListCommand(ctx context.Context, words []string) {
	requestID := ""
	if len(words) == 3 {
		request, err := decodeRootControlRequest(words[2])
		requestID = validRootControlRequestID(request.RequestID)
		if err != nil || !request.present.hasOnly("requestID") {
			c.reply(requestID, "list", nil, roots.ErrInvalid)
			return
		}
	}
	c.reply(requestID, "list", c.listNativeRoots(ctx), nil)
}

func (c *rootControl) verifyRootGeneration(rootID string, generation uint64) error {
	for _, root := range c.registry.List() {
		if root.ID == rootID {
			if generation == 0 || root.Generation != generation {
				return roots.ErrStale
			}
			return nil
		}
	}
	return roots.ErrMissing
}

func (c *rootControl) handleVerifyAccess(ctx context.Context, requestID string, request rootControlRequest) {
	if !request.present.hasOnly("requestID", "path") || !request.present.path {
		c.reply(requestID, "verify-access", nil, roots.ErrInvalid)
		return
	}
	resolved, pathErr := filepath.EvalSymlinks(request.Path)
	if pathErr != nil {
		c.reply(requestID, "verify-access", nil, classifyRootProbeError(pathErr))
		return
	}
	resolved = filepath.Clean(resolved)
	if resolved == "/" || resolved == "/Volumes" {
		c.reply(requestID, "verify-access", nil, roots.ErrNotAllowed)
		return
	}
	if probeErr := verifyDaemonRootReadWrite(resolved); probeErr != nil {
		c.reply(requestID, "verify-access", nil, probeErr)
		return
	}
	for _, existing := range c.registry.List() {
		if existing.Path == resolved || strings.HasPrefix(existing.Path, resolved+string(filepath.Separator)) {
			if c.accounts != nil {
				_ = c.accounts.SyncVerifiedRootGeneration(existing.ID, existing.Generation)
			}
			_ = c.prewarmRegisteredRoot(ctx, existing)
		}
	}
	c.reply(requestID, "verify-access", map[string]any{"path": resolved, "writable": true}, nil)
}

func (c *rootControl) prepareTargetRootPath(operation string, request rootControlRequest) (string, error) {
	if c.legacyBackupRunning != nil && c.legacyBackupRunning() {
		return "", roots.ErrBusy
	}
	resolved, pathErr := filepath.EvalSymlinks(request.Path)
	if pathErr != nil {
		return "", roots.ErrNotAllowed
	}
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
				return "", roots.ErrOverlap
			}
		}
	}
	if c.backupDestinations != nil {
		for _, target := range c.backupDestinations() {
			if target == "" {
				continue
			}
			canonical, err := canonicalPathForOverlap(target)
			if err != nil || rootPathsOverlap(resolved, canonical) {
				return "", roots.ErrOverlap
			}
		}
	}
	return resolved, nil
}

func (c *rootControl) executeMutation(ctx context.Context, operation string, request rootControlRequest) (any, error) {
	switch operation {
	case "select-folder":
		return c.mutateSelectFolder(ctx, request)
	case "add":
		return c.mutateAddRoot(ctx, request)
	case "rebind":
		return c.mutateRebindRoot(ctx, request)
	case "remove":
		if !request.present.hasOnly("requestID", "rootID", "generation") || !request.present.id || !request.present.generation {
			return nil, roots.ErrInvalid
		}
		if err := c.registry.Remove(request.ID); err != nil {
			return nil, err
		}
		if c.server != nil {
			_ = c.server.EvictRootRuntime(request.ID)
		}
		retireRemovedRootSQLite(c.dataDir, request.ID)
		return map[string]string{"rootID": request.ID}, nil
	case "set-default":
		if !request.present.hasOnly("requestID", "rootID", "generation") || !request.present.id || !request.present.generation {
			return nil, roots.ErrInvalid
		}
		return map[string]string{"rootID": request.ID}, c.registry.SetDefault(ctx, request.ID, request.Generation)
	default:
		return nil, roots.ErrInvalid
	}
}

func (c *rootControl) mutateSelectFolder(ctx context.Context, request rootControlRequest) (any, error) {
	if !request.present.hasOnly("requestID", "path", "name") || !request.present.path || request.Name == "" {
		return nil, roots.ErrInvalid
	}
	if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
		return nil, probeErr
	}
	prevDefault, hadDefault := c.registry.Default()
	var found *roots.Root
	wasCreated := false
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
			return nil, addErr
		}
		found = &created
		wasCreated = true
	}
	if prewarmErr := c.prewarmRegisteredRoot(ctx, *found); prewarmErr != nil {
		if wasCreated {
			_ = c.registry.Remove(found.ID)
		}
		return nil, prewarmErr
	}
	if err := c.registry.SetDefault(ctx, found.ID, found.Generation); err != nil {
		if wasCreated {
			_ = c.registry.Remove(found.ID)
			if hadDefault {
				_ = c.registry.SetDefault(ctx, prevDefault.ID, prevDefault.Generation)
			}
		}
		return nil, err
	}
	return found, nil
}

func (c *rootControl) mutateAddRoot(ctx context.Context, request rootControlRequest) (any, error) {
	if !request.present.hasOnly("requestID", "name", "path") {
		return nil, roots.ErrInvalid
	}
	if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
		return nil, probeErr
	}
	created, addErr := c.registry.Add(ctx, request.Name, request.Path)
	if addErr != nil {
		return nil, addErr
	}
	if prewarmErr := c.prewarmRegisteredRoot(ctx, created); prewarmErr != nil {
		_ = c.registry.Remove(created.ID)
		return nil, prewarmErr
	}
	return created, nil
}

func (c *rootControl) mutateRebindRoot(ctx context.Context, request rootControlRequest) (any, error) {
	if !request.present.hasOnly("requestID", "rootID", "generation", "path") ||
		!request.present.id || !request.present.generation || !request.present.path {
		return nil, roots.ErrInvalid
	}
	if probeErr := verifyDaemonRootReadWrite(request.Path); probeErr != nil {
		return nil, probeErr
	}
	rebound, err := c.registry.Rebind(ctx, request.ID, request.Path)
	if err != nil {
		return nil, err
	}
	if c.accounts != nil {
		_ = c.accounts.SyncVerifiedRootGeneration(rebound.ID, rebound.Generation)
	}
	if prewarmErr := c.prewarmRegisteredRoot(ctx, rebound); prewarmErr != nil {
		return nil, prewarmErr
	}
	if c.server != nil {
		c.server.QueueMediaRefresh(rebound.ID, "")
	}
	return rebound, nil
}

func decodeRootControlRequest(raw string) (rootControlRequest, error) {
	var request rootControlRequest
	if len(raw) == 0 || len(raw) > maxRootEncodedArgBytes {
		return request, roots.ErrInvalid
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || len(data) > maxRootDecodedJSONBytes {
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
	if len(request.RequestID) > maxRootRequestIDChars {
		return request, roots.ErrInvalid
	}
	return request, nil
}

func validRootControlRequestID(requestID string) string {
	if len(requestID) > maxRootRequestIDChars {
		return ""
	}
	return requestID
}

func rootControlRequestIDFromWords(words []string) string {
	if len(words) < 3 || len(words[2]) > maxRootEncodedArgBytes {
		return ""
	}
	request, _ := decodeRootControlRequest(words[2])
	return validRootControlRequestID(request.RequestID)
}

func (c *rootControl) Close() {}

func rootPathsOverlap(a, b string) bool {
	if resolved, err := canonicalPathForOverlap(a); err == nil {
		a = resolved
	}
	if resolved, err := canonicalPathForOverlap(b); err == nil {
		b = resolved
	}
	a, b = filepath.Clean(a), filepath.Clean(b)
	return a == b || strings.HasPrefix(a, b+string(filepath.Separator)) || strings.HasPrefix(b, a+string(filepath.Separator))
}

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
