//go:build darwin && arm64

// LightIsle recovery is deliberately a local offline maintenance command. It
// is not registered as an HTTP route. The native app performs owner
// authentication and stops Core before invoking mutating operations.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/backup"
)

const parentWatchInterval = 150 * time.Millisecond

type jsonError struct {
	SchemaVersion   int    `json:"schemaVersion"`
	Operation       string `json:"operation"`
	Status          string `json:"status"`
	RecoveryPending bool   `json:"recoveryPending"`
	Error           struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, os.Getppid, os.Exit))
}

func run(args []string, stdout, stderr io.Writer, getParentPID func() int, exitProcess func(int)) int {
	flags := flag.NewFlagSet("lightisle-recovery", flag.ContinueOnError)
	flags.SetOutput(stderr)
	dataDir := flags.String("data-dir", "", "macOS private LightIsle data directory")
	stage := flags.String("stage", "", "basename of LightIsle-RestoredMetadata-* folder")
	operation := flags.String("operation", "verify", "preview, verify, activate, recover, inspect, list or rollback")
	confirm := flags.String("confirm", "", "explicit acknowledgement for offline metadata changes")
	transactionID := flags.String("transaction-id", "", "eligible offline activation transaction id to roll back")
	parentPID := flags.Int("parent-pid", 0, "optional native app parent process id")
	expectedManifestSHA := flags.String("expected-manifest-sha256", "", "manifest digest confirmed by native recovery preview")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *parentPID != 0 {
		if *parentPID <= 1 {
			writeJSONError(stdout, *operation, "blocked", "invalid_parent_pid", "parent pid must be greater than 1", false)
			return 2
		}
		if getParentPID == nil {
			getParentPID = os.Getppid
		}
		if getParentPID() != *parentPID {
			pending := false
			if *dataDir != "" {
				pending = backup.RecoveryPending(*dataDir)
			}
			writeJSONError(stdout, *operation, "blocked", "parent_process_mismatch", "recovery helper was not started by the expected native app", pending)
			return 125
		}
		done := make(chan struct{})
		defer close(done)
		if exitProcess == nil {
			exitProcess = os.Exit
		}
		go monitorParent(*parentPID, getParentPID, exitProcess, done, parentWatchInterval)
	}
	if *dataDir == "" {
		config, err := os.UserConfigDir()
		if err != nil {
			return runError(stdout, *operation, "data_directory_unavailable", err, false)
		}
		*dataDir = filepath.Join(config, "LightIsle")
	}

	switch *operation {
	case "preview":
		if *parentPID == 0 {
			writePreviewError(stdout, "owner_process_required", "recovery preview must be started by the native Mac app")
			return 2
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		result, err := backup.PreviewStagedMetadata(ctx, *dataDir, *stage)
		if err != nil {
			code, message := "preview_unavailable", "无法安全读取恢复预览；当前数据库未修改。"
			if errors.Is(err, context.DeadlineExceeded) {
				code, message = "preview_timed_out", "恢复预览超过安全检查时限；当前数据库未修改。"
			}
			writePreviewError(stdout, code, message)
			return 2
		}
		if err := writeJSON(stdout, result); err != nil {
			return 2
		}
		return 0
	case "inspect":
		result, err := backup.InspectOfflineRecovery(*dataDir)
		if err != nil {
			return runError(stdout, *operation, "inspection_failed", err, backup.RecoveryPending(*dataDir))
		}
		_ = writeJSON(stdout, result)
		return 0
	case "list":
		result, err := backup.ListMetadataRollbacks(*dataDir)
		if err != nil {
			return runError(stdout, *operation, "inventory_failed", err, backup.RecoveryPending(*dataDir))
		}
		encoded, err := marshalBoundedList(result)
		if err != nil {
			return runError(stdout, *operation, "inventory_encode_failed", err, result.RecoveryPending)
		}
		_, _ = stdout.Write(append(encoded, '\n'))
		return 0
	case "rollback":
		if *confirm != "ROLLBACK_OFFLINE_METADATA" {
			writeJSONError(stdout, *operation, "blocked", "confirmation_required", "rollback requires explicit native owner confirmation", backup.RecoveryPending(*dataDir))
			return 2
		}
		result, err := backup.RollbackMetadata(*dataDir, *transactionID)
		if err != nil {
			status := "failed"
			code := "rollback_failed"
			if errors.Is(err, backup.ErrAppRunning) {
				status, code = "blocked", "core_running"
			} else if strings.Contains(err.Error(), "interrupted_recovery_pending") {
				status, code = "blocked", "interrupted_recovery_pending"
			} else if strings.Contains(err.Error(), "rollback_not_eligible") || strings.Contains(err.Error(), "receipt") || strings.Contains(err.Error(), "invalid_transaction_id") {
				status, code = "blocked", "transaction_not_eligible"
			}
			result.Status = status
			result.RecoveryPending = backup.RecoveryPending(*dataDir)
			result.Error = &struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			}{Code: code, Message: err.Error()}
			_ = writeJSON(stdout, result)
			return 2
		}
		_ = writeJSON(stdout, result)
		return 0
	case "verify":
		entries, err := backup.VerifyStagedMetadata(*dataDir, *stage)
		if err != nil {
			return fatal(stderr, err)
		}
		fmt.Fprintf(stdout, "Offline recovery snapshot verified: %d metadata objects. Current databases unchanged.\n", len(entries))
		return 0
	case "activate":
		if *confirm != "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT" {
			return fatal(stderr, fmt.Errorf("activation requires --confirm I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT"))
		}
		rollback, err := backup.ActivateStagedMetadataWithManifestSHA256(*dataDir, *stage, *expectedManifestSHA)
		if err != nil {
			return fatal(stderr, err)
		}
		fmt.Fprintf(stdout, "Offline metadata activated; all previous versions preserved at %s\n", rollback)
		fmt.Fprintln(stdout, "Start LightIsle and confirm new account/settings. Keep the rollback folder and original snapshot.")
		return 0
	case "recover":
		if *confirm != "RESTORE_PREVIOUS_METADATA" {
			return fatal(stderr, fmt.Errorf("interrupted recovery requires --confirm RESTORE_PREVIOUS_METADATA"))
		}
		if err := backup.RecoverInterruptedActivation(*dataDir); err != nil {
			return fatal(stderr, err)
		}
		fmt.Fprintln(stdout, "Interrupted offline metadata transaction recovered; Core may be started again.")
		return 0
	default:
		return fatal(stderr, fmt.Errorf("unknown operation; expected preview, verify, activate, recover, inspect, list or rollback"))
	}
}

func writePreviewError(output io.Writer, code, message string) {
	_ = writeJSON(output, backup.MetadataRecoveryPreview{
		SchemaVersion: 1, Operation: "preview", Status: "failed", Verified: false,
		Counts: map[string]backup.MetadataCountDifference{}, Warnings: []string{},
		Error: &backup.MetadataPreviewError{Code: code, Message: message},
	})
}

func monitorParent(expectedPID int, getParentPID func() int, exitProcess func(int), done <-chan struct{}, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			if getParentPID() != expectedPID {
				exitProcess(125)
				return
			}
		}
	}
}

func marshalBoundedList(result backup.OfflineRollbackList) ([]byte, error) {
	for {
		encoded, err := json.Marshal(result)
		if err != nil {
			return nil, err
		}
		if len(encoded) <= 256<<10 {
			return encoded, nil
		}
		if len(result.Transactions) == 0 {
			return nil, errors.New("rollback_list_output_too_large")
		}
		result.Transactions = result.Transactions[:len(result.Transactions)-1]
		result.Truncated = true
	}
}

func runError(stdout io.Writer, operation, code string, err error, pending bool) int {
	writeJSONError(stdout, operation, "failed", code, err.Error(), pending)
	return 2
}

func writeJSONError(output io.Writer, operation, status, code, message string, pending bool) {
	result := jsonError{SchemaVersion: 1, Operation: operation, Status: status, RecoveryPending: pending}
	result.Error.Code = code
	result.Error.Message = message
	_ = writeJSON(output, result)
}

func writeJSON(output io.Writer, value any) error {
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func fatal(output io.Writer, err error) int {
	fmt.Fprintln(output, "LightIsle offline recovery:", err)
	return 2
}
