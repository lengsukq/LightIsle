//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/backup"
)

type inventoryResult struct {
	inventory backup.SnapshotInventory
	err       error
}

func emitBackupInventoryOutcome(result inventoryResult) {
	if result.err != nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+result.err.Error())
		return
	}
	payload, err := json.Marshal(result.inventory)
	if err != nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR backup_inventory_encode_failed")
	} else {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_INVENTORY "+base64.RawURLEncoding.EncodeToString(payload))
	}
}

func handleBackupIPC(
	ctx context.Context,
	command string,
	backupService *backup.Service,
	backupSchedule *backup.Scheduler,
	inventoryActive *bool,
	inventoryDone chan<- inventoryResult,
) bool {
	if backupSchedule == nil && (command == "backup schedule status" || command == "backup schedule off" || strings.HasPrefix(command, "backup schedule set ")) {
		if command == "backup schedule status" {
			payload, _ := json.Marshal(backup.Schedule{LastError: "backup_schedule_unavailable"})
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE "+base64.RawURLEncoding.EncodeToString(payload))
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR backup_schedule_unavailable")
		}
		return true
	}
	if strings.HasPrefix(command, "backup inventory ") {
		if *inventoryActive {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR backup_inventory_already_running")
			return true
		}
		raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "backup inventory "))
		if decodeErr != nil || len(raw) == 0 || len(raw) >= 4096 {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_backup_location_or_manifest")
			return true
		}
		*inventoryActive = true
		go func(destination string) {
			scanCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			inventory, err := backupService.ListSnapshots(scanCtx, destination)
			select {
			case inventoryDone <- inventoryResult{inventory: inventory, err: err}:
			case <-ctx.Done():
			}
		}(string(raw))
		return true
	}
	if command == "backup cancel" {
		if backupService.Cancel() {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_CANCEL_REQUESTED")
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR task_not_running")
		}
		return true
	}
	if command == "backup schedule status" {
		payload, _ := json.Marshal(backupSchedule.Status())
		fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE "+base64.RawURLEncoding.EncodeToString(payload))
		return true
	}
	if command == "backup schedule off" {
		if err := backupSchedule.Disable(); err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+err.Error())
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE_CHANGED")
		}
		return true
	}
	if strings.HasPrefix(command, "backup schedule set ") {
		parts := strings.Fields(strings.TrimPrefix(command, "backup schedule set "))
		if len(parts) != 4 {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_schedule")
			return true
		}
		hours, e := strconv.Atoi(parts[0])
		retentionCount := 0
		encodedPath := parts[len(parts)-1]
		if e == nil {
			retentionCount, e = strconv.Atoi(parts[1])
		}
		metadataOnly := parts[2] == backup.MetadataBackupType
		if !metadataOnly || hours != 168 || retentionCount != 5 {
			e = backup.ErrInvalid
		}
		var data []byte
		if e == nil {
			data, e = base64.RawURLEncoding.DecodeString(encodedPath)
		}
		if e == nil && len(data) > 0 && len(data) < 4096 {
			e = backupSchedule.ConfigureMetadataWeekly(string(data), retentionCount)
		} else if e == nil {
			e = backup.ErrInvalid
		}
		if e != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+e.Error())
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE_CHANGED")
		}
		return true
	}
	if command == "backup status" {
		data, err := json.Marshal(backupService.Status())
		if err == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_STATUS "+base64.RawURLEncoding.EncodeToString(data))
		}
		return true
	}
	if strings.HasPrefix(command, "backup start ") {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR full_file_backup_not_supported")
		return true
	}
	if strings.HasPrefix(command, "backup metadata start ") || strings.HasPrefix(command, "backup restore ") {
		kind := "backup start "
		if strings.HasPrefix(command, "backup metadata start ") {
			kind = "backup metadata start "
		}
		if strings.HasPrefix(command, "backup restore ") {
			kind = "backup restore "
		}
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, kind))
		if err == nil && len(raw) > 0 && len(raw) < 4096 {
			if kind == "backup metadata start " {
				err = backupService.StartMetadataBackup(string(raw))
			} else {
				err = backupService.StartMetadataRestore(string(raw))
			}
		} else {
			err = backup.ErrInvalid
		}
		if err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+err.Error())
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_STARTED")
		}
		return true
	}
	return false
}
