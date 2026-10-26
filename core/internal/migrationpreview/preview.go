// Package migrationpreview provides a read-only, Mac-owner-only inventory of
// v1 metadata that must be reviewed before enabling the multi-root preview.
// It NEVER copies data, grants permissions, or promotes a compatibility root.
package migrationpreview

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	_ "github.com/mattn/go-sqlite3"
)

type Counts struct {
	Members           int64 `json:"members"`
	FileGrants        int64 `json:"fileGrants"`
	FileShares        int64 `json:"fileShares"`
	RootGrants        int64 `json:"rootGrants"`
	Photos            int64 `json:"photos"`
	SharedAlbums      int64 `json:"sharedAlbums"`
	PrivateAlbums     int64 `json:"privateAlbums"`
	PrivateAlbumItems int64 `json:"privateAlbumItems"`
	PersonalFavorites int64 `json:"personalFavorites"`
	Films             int64 `json:"films"`
	WatchProgress     int64 `json:"watchProgress"`
}

// ScopedMediaCounts only describes the currently verified physical legacy
// share. Unbound rows belong to older/disconnected shares and must never be
// automatically imported into this root even if their relative paths match.
type ScopedMediaCounts struct {
	Photos            int64 `json:"photos"`
	SharedAlbums      int64 `json:"sharedAlbums"`
	PrivateAlbums     int64 `json:"privateAlbums"`
	PrivateAlbumItems int64 `json:"privateAlbumItems"`
	PersonalFavorites int64 `json:"personalFavorites"`
	Films             int64 `json:"films"`
	WatchProgress     int64 `json:"watchProgress"`
	OtherPhotos       int64 `json:"otherPhotos"`
	OtherFilms        int64 `json:"otherFilms"`
}

type Report struct {
	CompatibilityRootID  string             `json:"compatibilityRootID,omitempty"`
	LegacyRootFound      bool               `json:"legacyRootFound"`
	PhysicalRootVerified bool               `json:"physicalRootVerified"`
	Pending              bool               `json:"pending"`
	Counts               Counts             `json:"counts"`
	Scoped               *ScopedMediaCounts `json:"scoped,omitempty"`
	Blockers             []string           `json:"blockers"`
	CanApply             bool               `json:"canApply"`
}

// Build reads database counts across the three live SQLite databases. Counts
// cover ALL historical v1 share paths; they are an impact inventory, not
// evidence that every media record belongs to the currently attached disk.
// Each DB has its own read transaction and may change while Core is running.
// A future migration must recheck the physical binding and fresh counts after
// explicit owner approval, before any write. For now CanApply is always false.
func Build(ctx context.Context, dataDir string, registry *roots.Registry, fileStore *files.Manager) (Report, error) {
	if ctx == nil || dataDir == "" || registry == nil || fileStore == nil {
		return Report{}, errors.New("legacy_migration_preview_unavailable")
	}
	report := Report{Blockers: []string{}}
	var rootLease *roots.Lease
	var verifiedSharePath string
	defer func() {
		if rootLease != nil {
			_ = rootLease.Close()
		}
	}()
	for _, item := range registry.List() {
		if !item.Compatibility {
			continue
		}
		// There can only be one v1 source. Refuse ambiguous registry state.
		if report.LegacyRootFound {
			return Report{}, errors.New("multiple_legacy_compatibility_roots")
		}
		report.LegacyRootFound = true
		report.CompatibilityRootID = item.ID
		report.Pending = item.Pending
		if item.Pending {
			continue
		}
		path, online := fileStore.State()
		active, bound := fileStore.RootBinding()
		if !online || !bound || path == "" || !storageidentity.SameObject(active, item.Binding) {
			continue
		}
		lease, err := registry.Acquire(ctx, item.ID)
		if err != nil {
			continue
		}
		report.PhysicalRootVerified = storageidentity.SameObject(lease.Binding, active) && lease.Valid(ctx)
		if report.PhysicalRootVerified {
			// Pin the same original directory while collecting the scoped
			// inventory and check its identity again before returning.
			rootLease = lease
			verifiedSharePath = path
		} else {
			_ = lease.Close()
		}
	}

	for _, db := range []struct {
		filename string
		queries  []struct {
			out *int64
			sql string
		}
	}{
		{"accounts.sqlite", []struct {
			out *int64
			sql string
		}{
			{&report.Counts.Members, "SELECT COUNT(*) FROM users WHERE role='member'"},
			{&report.Counts.FileGrants, "SELECT COUNT(*) FROM file_grants"},
			{&report.Counts.FileShares, "SELECT COUNT(*) FROM file_shares"},
			{&report.Counts.RootGrants, "SELECT COUNT(*) FROM root_file_grants"},
		}},
		{"gallery.sqlite", []struct {
			out *int64
			sql string
		}{
			{&report.Counts.Photos, "SELECT COUNT(*) FROM assets"},
			{&report.Counts.SharedAlbums, "SELECT COUNT(*) FROM albums"},
			{&report.Counts.PrivateAlbums, "SELECT COUNT(*) FROM private_albums"},
			{&report.Counts.PrivateAlbumItems, "SELECT COUNT(*) FROM private_album_items"},
			{&report.Counts.PersonalFavorites, "SELECT COUNT(*) FROM personal_favorites"},
		}},
		{"cinema.sqlite", []struct {
			out *int64
			sql string
		}{
			{&report.Counts.Films, "SELECT COUNT(*) FROM films"},
			{&report.Counts.WatchProgress, "SELECT COUNT(*) FROM watch_progress"},
		}},
	} {
		if err := countReadOnly(ctx, filepath.Join(dataDir, db.filename), db.queries); err != nil {
			// A missing/corrupt database MUST NOT become a false all-zero
			// approval inventory; fail closed instead.
			return Report{}, fmt.Errorf("legacy_inventory_%s: %w", db.filename, err)
		}
	}
	if report.PhysicalRootVerified {
		scoped := &ScopedMediaCounts{}
		if err := countReadOnly(ctx, filepath.Join(dataDir, "gallery.sqlite"), []struct {
			out *int64
			sql string
		}{
			{&scoped.Photos, "SELECT COUNT(*) FROM assets WHERE share=?"},
			{&scoped.SharedAlbums, "SELECT COUNT(*) FROM albums WHERE share=?"},
			{&scoped.PrivateAlbums, "SELECT COUNT(*) FROM private_albums WHERE share=?"},
			{&scoped.PrivateAlbumItems, "SELECT COUNT(*) FROM private_album_items i JOIN private_albums a ON a.id=i.album_id WHERE a.share=?"},
			{&scoped.PersonalFavorites, "SELECT COUNT(*) FROM personal_favorites f JOIN assets a ON a.id=f.asset_id WHERE a.share=?"},
			{&scoped.OtherPhotos, "SELECT COUNT(*) FROM assets WHERE share<>?"},
		}, verifiedSharePath); err != nil {
			return Report{}, fmt.Errorf("legacy_scoped_gallery: %w", err)
		}
		if err := countReadOnly(ctx, filepath.Join(dataDir, "cinema.sqlite"), []struct {
			out *int64
			sql string
		}{
			{&scoped.Films, "SELECT COUNT(*) FROM films WHERE share=?"},
			{&scoped.WatchProgress, "SELECT COUNT(*) FROM watch_progress p JOIN films f ON f.id=p.film_id WHERE f.share=?"},
			{&scoped.OtherFilms, "SELECT COUNT(*) FROM films WHERE share<>?"},
		}, verifiedSharePath); err != nil {
			return Report{}, fmt.Errorf("legacy_scoped_cinema: %w", err)
		}
		if rootLease.Valid(ctx) {
			report.Scoped = scoped
		} else {
			report.PhysicalRootVerified = false
		}
	}
	if !report.LegacyRootFound {
		report.Blockers = append(report.Blockers, "legacy_registry_missing")
	} else if !report.PhysicalRootVerified {
		report.Blockers = append(report.Blockers, "legacy_physical_root_unverified")
	}
	// Explicitly block all unattended promotion until the full per-user
	// grant/media/path remapping and rollback plan are implemented.
	report.Blockers = append(report.Blockers, "legacy_mapping_and_owner_approval_required")
	return report, nil
}

func countReadOnly(ctx context.Context, path string, queries []struct {
	out *int64
	sql string
}, parameters ...any) error {
	dsn := &url.URL{Scheme: "file", Path: path}
	q := dsn.Query()
	q.Set("mode", "ro")
	q.Set("_busy_timeout", "3000")
	dsn.RawQuery = q.Encode()
	db, err := sql.Open("sqlite3", dsn.String())
	if err != nil {
		return err
	}
	defer db.Close()
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, query := range queries {
		if err := tx.QueryRowContext(ctx, query.sql, parameters...).Scan(query.out); err != nil {
			return err
		}
	}
	return tx.Commit()
}
