//go:build darwin && arm64

// LightIsle recovery is deliberately a local offline maintenance command.
// It is not registered as an HTTP route and cannot be run while Core is active.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/backup"
)

func main() {
	dataDir := flag.String("data-dir", "", "macOS private LightIsle data directory")
	stage := flag.String("stage", "", "basename of LightIsle-RestoredMetadata-* folder")
	operation := flag.String("operation", "verify", "verify, activate or recover")
	confirm := flag.String("confirm", "", "explicit owner acknowledgement for offline database activation")
	flag.Parse()
	if *dataDir == "" {
		config, err := os.UserConfigDir()
		if err != nil {
			fatal(err)
		}
		*dataDir = filepath.Join(config, "LightIsle")
	}
	switch *operation {
	case "verify":
		entries, err := backup.VerifyStagedMetadata(*dataDir, *stage)
		if err != nil {
			fatal(err)
		}
		fmt.Printf("Offline recovery snapshot verified: %d metadata objects. Current databases unchanged.\n", len(entries))
	case "activate":
		if *confirm != "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT" {
			fatal(fmt.Errorf("activation requires --confirm I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT"))
		}
		rollback, err := backup.ActivateStagedMetadata(*dataDir, *stage)
		if err != nil {
			fatal(err)
		}
		fmt.Printf("Offline metadata activated; all previous versions preserved at %s\n", rollback)
		fmt.Println("Start LightIsle and confirm new account/settings. Keep the rollback folder and original snapshot.")
	case "recover":
		if *confirm != "RESTORE_PREVIOUS_METADATA" {
			fatal(fmt.Errorf("interrupted recovery requires --confirm RESTORE_PREVIOUS_METADATA"))
		}
		if err := backup.RecoverInterruptedActivation(*dataDir); err != nil {
			fatal(err)
		}
		fmt.Println("Interrupted offline activation rolled back; old metadata restored, rejected replacements quarantined.")
	default:
		fatal(fmt.Errorf("unknown operation; expected verify, activate or recover"))
	}
}
func fatal(err error) {
	fmt.Fprintln(os.Stderr, "LightIsle offline recovery:", err)
	os.Exit(2)
}
