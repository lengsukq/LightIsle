package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
)

type VerifyReport struct {
	Format        string `json:"format"`
	Files         int    `json:"files"`
	MetadataFiles int    `json:"metadataFiles"`
	Bytes         int64  `json:"bytes"`
	Verified      bool   `json:"verified"`
}

// VerifySnapshot independently checks all stored file and metadata checksums,
// and refuses internal symlinks, missing files and invalid manifests. It never
// changes the backup or the live share. Use before attempting an offline
// disaster recovery or during scheduled backup audit.
func VerifySnapshot(ctx context.Context, location string) (VerifyReport, error) {
	resolved, err := authorizedFolder(location)
	if err != nil {
		return VerifyReport{}, err
	}
	root, err := os.OpenRoot(resolved)
	if err != nil {
		return VerifyReport{}, err
	}
	defer root.Close()
	manifest, err := parseManifest(root)
	if err != nil {
		return VerifyReport{}, err
	}
	report := VerifyReport{Format: manifest.Format, Files: len(manifest.Files), MetadataFiles: len(manifest.Metadata)}
	for _, dir := range manifest.Dirs {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		info, err := root.Lstat(path.Join("data", dir))
		if err != nil {
			return report, err
		}
		if !info.IsDir() {
			return report, ErrInvalid
		}
	}
	for _, entry := range manifest.Files {
		if err := verifyEntry(ctx, root, path.Join("data", entry.Path), entry); err != nil {
			return report, fmt.Errorf("file %q: %w", entry.Path, err)
		}
		report.Bytes += entry.Size
	}
	for _, entry := range manifest.Metadata {
		if err := verifyEntry(ctx, root, path.Join("metadata", entry.Path), entry); err != nil {
			return report, fmt.Errorf("metadata %q: %w", entry.Path, err)
		}
		report.Bytes += entry.Size
	}
	report.Verified = true
	return report, nil
}

func verifyEntry(ctx context.Context, root *os.Root, relative string, entry File) error {
	info, err := root.Lstat(relative)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() != entry.Size {
		return ErrInvalid
	}
	f, err := root.Open(relative)
	if err != nil {
		return err
	}
	defer f.Close()
	digest := sha256.New()
	n, err := io.Copy(digest, io.LimitReader(cancellationReader{ctx: ctx, source: f}, entry.Size+1))
	if err != nil {
		return err
	}
	if n != entry.Size {
		return ErrInvalid
	}
	got := hex.EncodeToString(digest.Sum(nil))
	if !equalDigest(got, entry.SHA256) {
		return errors.New("backup_checksum_mismatch")
	}
	return nil
}

func equalDigest(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
