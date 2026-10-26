//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

var errRootPending = errors.New("root_registry_pending")

type nativeRootBackupPlan struct {
	RootID     string          `json:"rootID"`
	Generation uint64          `json:"generation"`
	Schedule   backup.Schedule `json:"schedule"`
}

func (c *rootControl) handleBackupPlan(ctx context.Context, operation string, request rootControlRequest) {
	requestID := validRootControlRequestID(request.RequestID)
	if c.rootPlans == nil {
		c.reply(requestID, operation, nil, roots.ErrNotAllowed)
		return
	}
	baseFields := []string{"requestID", "rootID", "generation"}
	if request.ID == "" || request.Generation == 0 || !request.present.id || !request.present.generation {
		c.reply(requestID, operation, nil, roots.ErrInvalid)
		return
	}
	switch operation {
	case "backup-plan-status":
		if !request.present.hasOnly(baseFields...) {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		schedule, err := c.rootPlans.Status(request.ID, request.Generation)
		if err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		c.reply(requestID, operation, nativeRootBackupPlan{RootID: request.ID, Generation: request.Generation, Schedule: schedule}, nil)
	case "backup-plan-set":
		if !request.present.hasOnly("requestID", "rootID", "generation", "path", "everyHours", "retentionCount") ||
			!request.present.path || !request.present.everyHours || !request.present.retentionCount ||
			request.EveryHours == nil || request.RetentionCount == nil || request.Path == "" {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		if (*request.EveryHours != 24 && *request.EveryHours != 168) || *request.RetentionCount < 0 || *request.RetentionCount > 30 {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		destination, err := canonicalRootPlanDestination(request.Path)
		if err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		if err := c.checkRootPlanDestination(destination); err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		if err := c.rootPlans.Configure(ctx, request.ID, request.Generation, destination, *request.EveryHours, *request.RetentionCount); err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		schedule, err := c.rootPlans.Status(request.ID, request.Generation)
		if err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		c.reply(requestID, operation, nativeRootBackupPlan{RootID: request.ID, Generation: request.Generation, Schedule: schedule}, nil)
	case "backup-plan-off":
		if !request.present.hasOnly(baseFields...) {
			c.reply(requestID, operation, nil, roots.ErrInvalid)
			return
		}
		if err := c.rootPlans.Disable(request.ID, request.Generation); err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		schedule, err := c.rootPlans.Status(request.ID, request.Generation)
		if err != nil {
			c.reply(requestID, operation, nil, err)
			return
		}
		c.reply(requestID, operation, nativeRootBackupPlan{RootID: request.ID, Generation: request.Generation, Schedule: schedule}, nil)
	default:
		c.reply(requestID, operation, nil, roots.ErrInvalid)
	}
}

func canonicalRootPlanDestination(name string) (string, error) {
	if !filepath.IsAbs(name) {
		return "", roots.ErrInvalid
	}
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return "", backup.ErrDestinationVolumeUnavailable
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", roots.ErrInvalid
	}
	return filepath.Clean(resolved), nil
}

func (c *rootControl) checkRootPlanDestination(destination string) error {
	for _, root := range c.registry.List() {
		rootPath, err := canonicalPathForOverlap(root.Path)
		if err != nil || rootPathsOverlap(destination, rootPath) {
			return roots.ErrOverlap
		}
	}
	return nil
}
