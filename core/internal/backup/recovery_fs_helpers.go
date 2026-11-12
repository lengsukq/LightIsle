package backup

import (
	"errors"
	"os"
	"strings"
)

type fileDigest struct {
	sha  string
	size int64
}

func syncPrivateDir(root *os.Root) error {
	f, err := root.Open(".")
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

// openOwnedPrivateSubroot validates that dirName under root is a non-symlink
// 0700 directory owned by the current effective UID before opening it as an os.Root.
func openOwnedPrivateSubroot(
	root *os.Root,
	dirName string,
	invalidDirCode string,
	notOwnedCode string,
) (*os.Root, error) {
	info, err := root.Lstat(dirName)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New(invalidDirCode)
	}
	if notOwnedCode != "" {
		uid, ok := currentUID(info)
		if !ok || uid != uint32(os.Geteuid()) {
			return nil, errors.New(notOwnedCode)
		}
	}
	return root.OpenRoot(dirName)
}

// renameAndSyncDirs renames srcPath to dstPath within root and fsyncs
// firstSyncRoot before secondSyncRoot so an untimely crash never loses both links.
func renameAndSyncDirs(
	root *os.Root,
	srcPath string,
	dstPath string,
	firstSyncRoot *os.Root,
	secondSyncRoot *os.Root,
) error {
	if err := root.Rename(srcPath, dstPath); err != nil {
		return err
	}
	if err := syncPrivateDir(firstSyncRoot); err != nil {
		return err
	}
	return syncPrivateDir(secondSyncRoot)
}

// ensureNoLiveSQLiteSidecars verifies that neither -wal nor -shm files exist
// alongside a SQLite database file in root.
func ensureNoLiveSQLiteSidecars(root *os.Root, fileName string, errMessage string) error {
	if !strings.HasSuffix(fileName, ".sqlite") {
		return nil
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, err := root.Lstat(fileName + suffix); err == nil {
			return errors.New(errMessage)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// finalizeMetadataJournalState writes the active transaction pointer, marks
// recovery session revocation, removes any temporary install directory if
// requested, and durably deletes the recovery journal.
func finalizeMetadataJournalState(
	root *os.Root,
	activeTransactionID string,
	installDirToRemove string,
	removeJournalFirst bool,
) error {
	if err := writeActiveMetadata(root, activeTransactionID); err != nil {
		return err
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		return err
	}
	if removeJournalFirst {
		if err := root.Remove(activationJournalName); err != nil {
			return err
		}
		if installDirToRemove != "" {
			if err := root.RemoveAll(installDirToRemove); err != nil {
				return err
			}
		}
		return syncPrivateDir(root)
	}
	if installDirToRemove != "" {
		if err := root.RemoveAll(installDirToRemove); err != nil {
			return err
		}
		if err := syncPrivateDir(root); err != nil {
			return err
		}
	}
	if err := root.Remove(activationJournalName); err != nil {
		return err
	}
	return syncPrivateDir(root)
}
