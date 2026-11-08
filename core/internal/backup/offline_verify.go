package backup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

func validActivationName(name, prefix string) bool {
	return strings.HasPrefix(name, prefix) && len(name) > len(prefix) && path.Base(name) == name &&
		!strings.ContainsAny(name, "/\\\x00")
}

func regularFile(root *os.Root, name string) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, ErrInvalid
	}
	return info, nil
}

func verifyDigest(root *os.Root, name, hexSHA string, size int64) error {
	return verifyDigestContext(context.Background(), root, name, hexSHA, size)
}

func verifyDigestContext(ctx context.Context, root *os.Root, name, hexSHA string, size int64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := regularFile(root, name)
	if err != nil {
		return err
	}
	if info.Size() != size {
		return errors.New("metadata_size_mismatch")
	}
	f, err := root.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	copied, err := io.Copy(h, io.LimitReader(cancellationReader{ctx: ctx, source: f}, size+1))
	if err != nil {
		return err
	}
	if copied != size || hex.EncodeToString(h.Sum(nil)) != hexSHA {
		return errors.New("metadata_checksum_mismatch")
	}
	return nil
}

func checkSQLite(file string, requiredTable string) error {
	return checkSQLiteContext(context.Background(), file, requiredTable)
}

func checkSQLiteContext(ctx context.Context, file string, requiredTable string) error {
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	// Use read-only direct SQLite URI. No schema migrations are performed
	// until the normal application starts with the newly activated files.
	db, err := sql.Open("sqlite3", uri+"?mode=ro&_query_only=1&_busy_timeout=500")
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var result string
	if err := db.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return fmt.Errorf("sqlite_integrity_failed: %s", result)
	}
	if requiredTable != "" {
		var count int
		if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", requiredTable).Scan(&count); err != nil {
			return err
		}
		if count != 1 {
			return fmt.Errorf("sqlite_required_table_missing: %s", requiredTable)
		}
	}
	return nil
}

// VerifyStagedMetadata is side-effect free. Stage must be the trusted basename
// of the recovery folder previously created inside this app's private data
// directory. This is intentionally not a public HTTP endpoint.
func VerifyStagedMetadata(dataDir, stage string) ([]File, error) {
	return VerifyStagedMetadataContext(context.Background(), dataDir, stage)
}

// VerifyStagedMetadataContext is the cancellable form used by owner-facing
// preview. It hashes each staged object and checks every staged SQLite file
// without opening the current database or changing either side.
func VerifyStagedMetadataContext(ctx context.Context, dataDir, stage string) ([]File, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if !validActivationName(stage, "LightIsle-RestoredMetadata-") {
		return nil, ErrInvalid
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	info, err := root.Lstat(stage)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, ErrInvalid
	}
	staged, err := root.OpenRoot(stage)
	if err != nil {
		return nil, err
	}
	defer staged.Close()
	raw, err := readRootFileBounded(staged, "metadata-manifest.json", maxMetadataManifestBytes)
	if err != nil {
		return nil, err
	}
	var entries []File
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, ErrInvalid
	}
	rootIDs, registryPresent, err := readRegisteredRootIDs(staged)
	if err != nil {
		return nil, err
	}
	if err := validateMetadataCatalog(entries, rootIDs); err != nil {
		return nil, err
	}
	registered := registeredIDSet(rootIDs)
	seen := map[string]bool{}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		_, ok := metadataTableForName(entry.Path, registered)
		if !ok || seen[entry.Path] {
			return nil, ErrInvalid
		}
		seen[entry.Path] = true
		if err := verifyDigestContext(ctx, staged, entry.Path, entry.SHA256, entry.Size); err != nil {
			return nil, err
		}
		if strings.HasSuffix(entry.Path, ".sqlite") {
			// Older valid stages can predate a table or migration. Integrity is
			// required here; the preview reports missing count tables as unknown.
			if err := checkSQLiteContext(ctx, filepath.Join(dataDir, stage, entry.Path), ""); err != nil {
				return nil, err
			}
		} else {
			raw, err := readRootFileBounded(staged, entry.Path, 4<<20)
			if err != nil {
				return nil, err
			}
			var obj map[string]any
			if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
				return nil, ErrInvalid
			}
		}
	}
	if registryPresent && !seen["shared-roots.json"] {
		return nil, ErrInvalid
	}
	return entries, nil
}
