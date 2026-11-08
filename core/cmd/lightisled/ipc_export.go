//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync/atomic"

	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

type exportResult struct {
	path string
	err  error
}

func emitExportOutcome(result exportResult, externalTransferRunning *atomic.Bool) {
	externalTransferRunning.Store(false)
	if result.err != nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(result.err.Error())))
	} else {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_OK "+base64.RawURLEncoding.EncodeToString([]byte(result.path)))
	}
}

func handleExportIPC(
	ctx context.Context,
	command string,
	rootRegistry *roots.Registry,
	rootServer *server.RootServer,
	exportCancel *context.CancelFunc,
	externalTransferRunning *atomic.Bool,
	exportDone chan<- exportResult,
) bool {
	if command == "export history" {
		var data []byte
		err := withDefaultManager(ctx, rootRegistry, rootServer, func(manager *files.Manager) error {
			items, err := manager.ListTransfers()
			if err != nil {
				return err
			}
			data, err = json.Marshal(items)
			return err
		})
		if err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_HISTORY_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(err.Error())))
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_HISTORY "+base64.RawURLEncoding.EncodeToString(data))
		}
		return true
	}
	if command == "export cancel" {
		if *exportCancel != nil {
			(*exportCancel)()
		}
		return true
	}
	if strings.HasPrefix(command, "export start ") {
		if *exportCancel != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("export_already_running")))
			return true
		}
		raw, e := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "export start "))
		var request struct {
			Source      string `json:"source"`
			Destination string `json:"destination"`
			Mode        string `json:"mode"`
		}
		if e != nil || len(raw) > 8192 || json.Unmarshal(raw, &request) != nil || request.Source == "" || request.Destination == "" || (request.Mode != "" && request.Mode != "copy" && request.Mode != "move") {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("invalid_export_request")))
			return true
		}
		if request.Mode == "move" && nativeMoveTouchesPersonalHome(request.Source) {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("personal_move_accounting_pending_use_copy")))
			return true
		}
		registeredPaths := make([]string, 0)
		for _, root := range rootRegistry.List() {
			registeredPaths = append(registeredPaths, root.Path)
		}
		if nativeExportOverlapsRegisteredRoot(request.Destination, registeredPaths) {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("export_destination_is_a_managed_nas_root")))
			return true
		}
		job, cancel := context.WithCancel(ctx)
		if err := diskmgmt.WithStorageTransition(func() error {
			externalTransferRunning.Store(true)
			return nil
		}); err != nil {
			cancel()
			fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(err.Error())))
			return true
		}
		*exportCancel = cancel
		fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_STARTED")
		go func() {
			defer cancel()
			var path string
			var err error
			err = withDefaultManager(job, rootRegistry, rootServer, func(manager *files.Manager) error {
				if request.Mode == "move" {
					receipt, transferErr := manager.MoveOut(job, request.Source, request.Destination)
					path = receipt.Destination
					return transferErr
				}
				var transferErr error
				path, transferErr = manager.CopyOut(job, request.Source, request.Destination)
				return transferErr
			})
			select {
			case exportDone <- exportResult{path: path, err: err}:
			case <-ctx.Done():
			}
		}()
		return true
	}
	return false
}
