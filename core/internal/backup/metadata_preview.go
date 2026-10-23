package backup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type MetadataCountDifference struct {
	Current *int64 `json:"current"`
	Staged  *int64 `json:"staged"`
	Delta   *int64 `json:"delta"`
}

// MetadataRecoveryPreview is deliberately count-only. It never contains
// database paths, usernames, hashes, session ids, or share-token material.
type MetadataRecoveryPreview struct {
	SchemaVersion  int                                `json:"schemaVersion"`
	Operation      string                             `json:"operation"`
	Status         string                             `json:"status"`
	Verified       bool                               `json:"verified"`
	ManifestSHA256 string                             `json:"manifestSHA256"`
	Counts         map[string]MetadataCountDifference `json:"counts"`
	Warnings       []string                           `json:"warnings"`
	Error          *MetadataPreviewError              `json:"error,omitempty"`
}

type MetadataPreviewError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type previewMetric struct {
	key   string
	table string
	where string
}

var previewMetrics = []previewMetric{
	{key: "accounts.users", table: "users"},
	{key: "accounts.fileGrants", table: "file_grants"},
	{key: "accounts.rootFileGrants", table: "root_file_grants"},
	{key: "accounts.rootFileShares", table: "root_file_shares"},
	{key: "gallery.privateAlbums", table: "private_albums"},
	{key: "gallery.privateAlbumItems", table: "private_album_items"},
	{key: "gallery.favorites", table: "personal_favorites"},
	{key: "gallery.manualAlbums", table: "albums"},
	{key: "gallery.indexedAssets", table: "assets"},
	{key: "cinema.manualTitles", table: "films", where: "manual_title<>0"},
	{key: "cinema.indexedFilms", table: "films"},
	{key: "tasks.journal", table: "task_journal"},
	{key: "tasks.history", table: "task_runs"},
}

// PreviewStagedMetadata verifies the staged snapshot, then performs bounded,
// read-only count queries against both the stage and the current databases.
// It intentionally does not take the Core data lock: query_only SQLite
// connections leave the live database unchanged while the server is running.
func PreviewStagedMetadata(ctx context.Context, dataDir, stage string) (MetadataRecoveryPreview, error) {
	result := MetadataRecoveryPreview{SchemaVersion: 1, Operation: "preview", Status: "failed",
		Counts: make(map[string]MetadataCountDifference, len(previewMetrics)), Warnings: []string{
			"previous_database_preserved",
			"files_and_metadata_snapshot_time_may_differ",
			"source_files_not_replaced",
			"media_indexes_rebuildable",
			"sessions_and_file_shares_cleared",
		}}
	if ctx == nil {
		ctx = context.Background()
	}
	bounded, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return result, err
	}
	entries, err := VerifyStagedMetadataContext(bounded, dataDir, stage)
	if err != nil {
		return result, err
	}
	manifestSHA, err := stagedManifestSHA256(dataDir, stage)
	if err != nil {
		return result, err
	}
	result.ManifestSHA256 = manifestSHA
	result.Verified = true
	result.Status = "ready"

	dataRoot, err := os.OpenRoot(dataDir)
	if err != nil {
		return MetadataRecoveryPreview{}, err
	}
	defer dataRoot.Close()
	currentIDs, _, currentRegistryErr := readRegisteredRootIDs(dataRoot)

	stageRoot, err := dataRoot.OpenRoot(stage)
	if err != nil {
		return MetadataRecoveryPreview{}, err
	}
	defer stageRoot.Close()
	stageIDs, _, stageRegistryErr := readRegisteredRootIDs(stageRoot)
	if stageRegistryErr != nil {
		return MetadataRecoveryPreview{}, ErrInvalid
	}
	stageFiles := make(map[string]bool, len(entries))
	for _, entry := range entries {
		stageFiles[entry.Path] = true
	}

	for _, metric := range previewMetrics {
		if err := bounded.Err(); err != nil {
			return MetadataRecoveryPreview{}, err
		}
		current, currentKnown, err := countMetricAcrossDatabases(bounded, dataRoot, currentIDs,
			currentRegistryErr != nil, nil, metric)
		if err != nil {
			return MetadataRecoveryPreview{}, err
		}
		staged, stagedKnown, err := countMetricAcrossDatabases(bounded, stageRoot, stageIDs,
			false, stageFiles, metric)
		if err != nil {
			return MetadataRecoveryPreview{}, err
		}
		item := MetadataCountDifference{}
		if currentKnown {
			item.Current = &current
		}
		if stagedKnown {
			item.Staged = &staged
		}
		if currentKnown && stagedKnown {
			delta := staged - current
			item.Delta = &delta
		}
		result.Counts[metric.key] = item
	}
	for _, item := range result.Counts {
		if item.Current == nil || item.Staged == nil {
			result.Warnings = append(result.Warnings, "some_counts_unknown_for_legacy_schema")
			break
		}
	}
	return result, nil
}

func stagedManifestSHA256(dataDir, stage string) (string, error) {
	if !validActivationName(stage, "LightIsle-RestoredMetadata-") {
		return "", ErrInvalid
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	info, err := root.Lstat(stage)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", ErrInvalid
	}
	staged, err := root.OpenRoot(stage)
	if err != nil {
		return "", err
	}
	defer staged.Close()
	raw, err := readRootFileBounded(staged, "metadata-manifest.json", maxMetadataManifestBytes)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:]), nil
}

func countMetricAcrossDatabases(ctx context.Context, root *os.Root, rootIDs []string,
	registryInvalid bool, stagedFiles map[string]bool, metric previewMetric) (int64, bool, error) {
	kind := ""
	switch {
	case strings.HasPrefix(metric.key, "gallery."):
		kind = "gallery"
	case strings.HasPrefix(metric.key, "cinema."):
		kind = "cinema"
	case strings.HasPrefix(metric.key, "tasks."):
		kind = "tasks"
	}
	if kind == "" {
		return countMetric(ctx, filepath.Join(root.Name(), "accounts.sqlite"), metric)
	}
	if registryInvalid {
		return 0, false, nil
	}
	names := make([]string, 0, len(rootIDs)+1)
	legacyName := kind + ".sqlite"
	if fileExistsRegular(root, legacyName, stagedFiles) {
		names = append(names, legacyName)
	}
	for _, id := range rootIDs {
		name := rootMetadataName(kind, id)
		if !fileExistsRegular(root, name, stagedFiles) {
			return 0, false, nil
		}
		names = append(names, name)
	}
	if len(names) == 0 {
		return 0, false, nil
	}
	var total int64
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return 0, false, err
		}
		value, known, err := countMetric(ctx, filepath.Join(root.Name(), name), metric)
		if err != nil {
			return 0, false, err
		}
		if !known || value > int64(^uint64(0)>>1)-total {
			return 0, false, nil
		}
		total += value
	}
	return total, true, nil
}

func fileExistsRegular(root *os.Root, name string, stagedFiles map[string]bool) bool {
	if stagedFiles != nil && !stagedFiles[name] {
		return false
	}
	info, err := root.Lstat(name)
	return err == nil && info.Mode().IsRegular()
}

func countMetric(ctx context.Context, file string, metric previewMetric) (int64, bool, error) {
	info, err := os.Lstat(file)
	if err != nil || !info.Mode().IsRegular() {
		return 0, false, nil
	}
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	db, err := sql.Open("sqlite3", uri+"?mode=ro&_query_only=1&_busy_timeout=500")
	if err != nil {
		return 0, false, nil
	}
	db.SetMaxOpenConns(1)
	defer db.Close()
	var exists int
	if err := db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", metric.table).Scan(&exists); err != nil {
		if ctx.Err() != nil {
			return 0, false, ctx.Err()
		}
		return 0, false, nil
	}
	if exists != 1 {
		return 0, false, nil
	}
	var count int64
	query := "SELECT COUNT(*) FROM " + metric.table
	if metric.where != "" {
		query += " WHERE " + metric.where
	}
	if err := db.QueryRowContext(ctx, query).Scan(&count); err != nil {
		if ctx.Err() != nil {
			return 0, false, ctx.Err()
		}
		return 0, false, nil
	}
	return count, true, nil
}
