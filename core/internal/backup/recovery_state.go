package backup

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
)

const activeMetadataName = ".lightisle-active-metadata.json"
const revokeRecoverySessionsName = ".lightisle-revoke-recovery-sessions.json"

type activeMetadataPointer struct {
	Version       int    `json:"version"`
	TransactionID string `json:"transactionId"`
}

func readRecoveryState(root *os.Root, name string, target any) (bool, error) {
	info, err := validatePrivateOwnedRegularFile(root, name)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Size() > 4096 {
		return false, ErrInvalid
	}
	f, err := root.Open(name)
	if err != nil {
		return false, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return false, ErrInvalid
	}
	decoder := json.NewDecoder(io.LimitReader(f, 4097))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return false, err
	}
	var trailing any
	if !errors.Is(decoder.Decode(&trailing), io.EOF) {
		return false, ErrInvalid
	}
	return true, nil
}

func readActiveMetadata(root *os.Root) (string, error) {
	var pointer activeMetadataPointer
	exists, err := readRecoveryState(root, activeMetadataName, &pointer)
	if err != nil || !exists {
		return "", err
	}
	if pointer.Version != 1 || (pointer.TransactionID != "" && !validTransactionID(pointer.TransactionID)) {
		return "", ErrInvalid
	}
	return pointer.TransactionID, nil
}

func writeActiveMetadata(root *os.Root, transactionID string) error {
	if transactionID != "" && !validTransactionID(transactionID) {
		return ErrInvalid
	}
	raw, err := json.Marshal(activeMetadataPointer{Version: 1, TransactionID: transactionID})
	if err != nil {
		return err
	}
	return atomicWritePrivate(root, activeMetadataName, raw)
}

func markRecoverySessionRevocation(root *os.Root) error {
	return atomicWritePrivate(root, revokeRecoverySessionsName, []byte(`{"version":1}`))
}

// FinalizeRecoverySessions runs under the data-directory lock, before Core
// opens its HTTP listener. Its durable marker survives any crash between
// restoring account bytes and removing old browser sessions. Recovery copies
// and their receipt hashes remain unchanged.
func FinalizeRecoverySessions(dataDir string) error {
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return err
	}
	defer root.Close()
	var marker struct {
		Version int `json:"version"`
	}
	exists, err := readRecoveryState(root, revokeRecoverySessionsName, &marker)
	if err != nil || !exists {
		return err
	}
	if marker.Version != 1 {
		return ErrInvalid
	}
	if info, err := root.Lstat("accounts.sqlite"); err == nil {
		if !info.Mode().IsRegular() {
			return ErrInvalid
		}
		uri := (&url.URL{Scheme: "file", Path: filepath.Join(dataDir, "accounts.sqlite")}).String()
		db, err := sql.Open("sqlite3", uri+"?mode=rw&_busy_timeout=3000&_synchronous=FULL")
		if err != nil {
			return err
		}
		for _, table := range transientCapabilityTables {
			var count int
			err = db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&count)
			if err != nil {
				break
			}
			if count != 0 {
				// A restored database must never reactivate credentials,
				// including unauthenticated file download links.
				_, err = db.Exec("DELETE FROM " + table)
				if err != nil {
					break
				}
			}
		}
		closeErr := db.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := root.Remove(revokeRecoverySessionsName); err != nil {
		return err
	}
	return syncPrivateDir(root)
}
