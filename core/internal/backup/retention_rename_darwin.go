//go:build darwin

package backup

import (
	"os"
	"path"

	"golang.org/x/sys/unix"
)

func retentionRenameNoReplace(root *os.Root, oldName, newName string) error {
	if !retentionLeafName(oldName) || !retentionLeafName(newName) {
		return ErrInvalid
	}
	directory, err := root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	return unix.RenameatxNp(int(directory.Fd()), oldName, int(directory.Fd()), newName, unix.RENAME_EXCL)
}

func retentionLeafName(name string) bool {
	return name != "" && name != "." && name != ".." && path.Base(name) == name
}
