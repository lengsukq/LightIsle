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
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

// rootControl is reachable only over the native parent's private stdin pipe.
// The entire surface stays disabled without the explicit developer preview.
// Paths are returned solely to that parent, never through root discovery.
type rootControl struct {
	registry            *roots.Registry
	output              io.Writer
	backupDestinations  func() []string
	legacyBackupRunning func() bool
	server              *server.RootServer
	mu                  sync.Mutex
	active              *rootBackupJob
}

type rootBackupJob struct {
	rootID      string
	destination string
	lease       *server.RootServicesLease
	done        chan struct{}
}

type rootControlRequest struct {
	ID         string `json:"rootID,omitempty"`
	Generation uint64 `json:"generation,omitempty"`
	Name       string `json:"name,omitempty"`
	Path       string `json:"path,omitempty"`
	RequestID  string `json:"requestID,omitempty"`
}

type nativeRoot struct {
	ID            string `json:"rootID"`
	Generation    uint64 `json:"generation"`
	Name          string `json:"name"`
	Path          string `json:"path"`
	Online        bool   `json:"online"`
	Pending       bool   `json:"pending"`
	Compatibility bool   `json:"compatibility"`
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
		roots.ErrBusy, roots.ErrStale, roots.ErrNotAllowed, roots.ErrPersistence, backup.ErrRootDestinationOverlap} {
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
				Path: root.Path, Online: online, Pending: root.Pending, Compatibility: root.Compatibility})
		}
		c.reply("", operation, items, nil)
		return true
	}
	if operation == "list" && len(words) == 3 {
		request, err := decodeRootControlRequest(words[2])
		requestID := validRootControlRequestID(request.RequestID)
		if err != nil || request.ID != "" || request.Generation != 0 || request.Name != "" || request.Path != "" {
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
				Path: root.Path, Online: online, Pending: root.Pending, Compatibility: root.Compatibility})
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
	if strings.HasPrefix(operation, "backup-") {
		c.handleBackup(ctx, operation, request)
		return true
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
		c.mu.Lock()
		if c.active != nil {
			targets = append(targets, c.active.destination)
		}
		c.mu.Unlock()
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
		if request.ID != "" || request.Generation != 0 {
			err = roots.ErrInvalid
			break
		}
		result, err = c.registry.Add(ctx, request.Name, request.Path)
	case "rebind":
		if request.Name != "" {
			err = roots.ErrInvalid
			break
		}
		result, err = c.registry.Rebind(ctx, request.ID, request.Path)
	case "remove":
		if request.Path != "" || request.Name != "" {
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

func (c *rootControl) handleBackup(ctx context.Context, operation string, request rootControlRequest) {
	requestID := validRootControlRequestID(request.RequestID)
	if c.server == nil || request.Name != "" {
		c.reply(requestID, operation, nil, roots.ErrNotAllowed)
		return
	}
	location := ""
	if operation == "backup-start" || operation == "backup-restore" {
		var err error
		location, err = filepath.EvalSymlinks(request.Path)
		if err != nil || !filepath.IsAbs(request.Path) {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		for _, root := range c.registry.List() {
			if rootPathsOverlap(location, root.Path) {
				c.reply(requestID, operation, nil, roots.ErrOverlap)
				return
			}
		}
	}
	lease, err := c.server.AcquireRootServices(ctx, request.ID)
	if err != nil {
		c.reply(requestID, operation, nil, err)
		return
	}
	if lease.Root.Generation != request.Generation || lease.Services.Backup == nil {
		lease.Close()
		c.reply(requestID, operation, nil, roots.ErrStale)
		return
	}
	service := lease.Services.Backup
	response := func() any {
		return map[string]any{"rootID": request.ID, "generation": request.Generation, "status": service.Status()}
	}
	switch operation {
	case "backup-status":
		defer lease.Close()
		if request.Path != "" {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		c.reply(requestID, operation, response(), nil)
	case "backup-cancel":
		defer lease.Close()
		if request.Path != "" {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		service.Cancel()
		c.reply(requestID, operation, response(), nil)
	case "backup-start", "backup-restore":
		c.mu.Lock()
		if c.active != nil {
			c.mu.Unlock()
			lease.Close()
			c.reply(requestID, operation, nil, roots.ErrBusy)
			return
		}
		job := &rootBackupJob{rootID: request.ID, destination: location, lease: lease, done: make(chan struct{})}
		c.active = job
		c.mu.Unlock()
		if operation == "backup-start" {
			err = service.StartBackup(location)
		} else {
			err = service.StartRestore(location)
		}
		if err != nil {
			lease.Close()
			c.mu.Lock()
			c.active = nil
			close(job.done)
			c.mu.Unlock()
			c.reply(requestID, operation, nil, err)
			return
		}
		c.reply(requestID, operation, response(), nil)
		go func() {
			ticker := time.NewTicker(50 * time.Millisecond)
			defer ticker.Stop()
			for service.Status().Running {
				<-ticker.C
			}
			// Keep the source root busy through the complete asynchronous job.
			lease.Close()
			c.mu.Lock()
			if c.active == job {
				c.active = nil
			}
			close(job.done)
			c.mu.Unlock()
		}()
	default:
		lease.Close()
		c.reply(requestID, operation, nil, roots.ErrInvalid)
	}
}

func (c *rootControl) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	job := c.active
	c.mu.Unlock()
	if job != nil {
		job.lease.Services.Backup.Cancel()
		<-job.done
	}
}

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
