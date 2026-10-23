//go:build !darwin

package backup

import "os"

// Snapshot rotation fails closed on platforms without the supported atomic
// no-replace rename primitive.
func retentionRenameNoReplace(root *os.Root, oldName, newName string) error {
	return ErrRetentionExclusiveRename
}
