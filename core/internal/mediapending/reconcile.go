package mediapending

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// MediaVerifier abstracts the subset of physical storage checks needed during
// batch media indexing and missing-media attachment.
type MediaVerifier interface {
	Stat(name string) (fs.FileInfo, error)
	VerifyScannedMedia(entry files.Entry) error
}

// IndexedRecord captures the common identity/freshness fields shared by indexed
// media rows (both gallery assets and cinema films).
type IndexedRecord struct {
	ID          int64
	Path        string
	Size        int64
	Modified    int64
	Identity    string
	MissingPath string
}

// Snapshot groups existing database rows for a single ScanDirectory batch by
// active path, missing path, and physical file identity.
type Snapshot[T any] struct {
	Active     map[string]T
	Missing    map[string][]T
	ByIdentity map[string][]T
}

// NewSnapshot allocates an empty batch lookup snapshot sized for batchLen entries.
func NewSnapshot[T any](batchLen int) Snapshot[T] {
	return Snapshot[T]{
		Active:     make(map[string]T, batchLen),
		Missing:    make(map[string][]T),
		ByIdentity: make(map[string][]T),
	}
}

// Add classifies a scanned row into Active, Missing, or ByIdentity buckets.
func (s *Snapshot[T]) Add(rec IndexedRecord, item T) {
	if rec.MissingPath != "" {
		s.Missing[rec.MissingPath] = append(s.Missing[rec.MissingPath], item)
		return
	}
	s.Active[rec.Path] = item
	if rec.Identity != "" {
		s.ByIdentity[rec.Identity] = append(s.ByIdentity[rec.Identity], item)
	}
}

// BuildBatchLookupQuery constructs the parameterized SELECT clause and argument
// slice for fetching active, missing, and identity-matched rows in one query.
func BuildBatchLookupQuery(table, columns, share string, entries []files.Entry) (string, []any) {
	args := make([]any, 1, len(entries)*3+1)
	args[0] = share
	for _, e := range entries {
		args = append(args, e.Path)
	}
	for _, e := range entries {
		args = append(args, e.Path)
	}
	for _, e := range entries {
		args = append(args, e.Identity)
	}
	placeholders := strings.Repeat("?,", len(entries)-1) + "?"
	query := fmt.Sprintf(
		`SELECT %s FROM %s WHERE share=? AND (path IN (%s) OR missing_path IN (%s) OR (missing_path='' AND file_identity<>'' AND file_identity IN (%s)))`,
		columns, table, placeholders, placeholders, placeholders,
	)
	return query, args
}

// IdentityChange records a detected file replacement, restoration at the same
// path, or single-link rename/move within a media share.
type IdentityChange[T any] struct {
	Entry        files.Entry
	Active       T
	ActiveRecord IndexedRecord
	HasActive    bool
	RestoreID    int64
	MoveID       int64
	MoveFrom     string
	Split        bool
}

// HasMutation reports whether this entry requires identity reconciliation SQL.
func (c IdentityChange[T]) HasMutation() bool {
	return c.Split || c.RestoreID != 0 || c.MoveID != 0
}

// DetectIdentityChange compares a scanned filesystem entry against the batch
// database snapshot to detect replacements, restores, or single-link moves.
func DetectIdentityChange[T any](
	entry files.Entry,
	snap Snapshot[T],
	extract func(T) IndexedRecord,
	verifier MediaVerifier,
) IdentityChange[T] {
	activeItem, exists := snap.Active[entry.Path]
	var activeRec IndexedRecord
	if exists {
		activeRec = extract(activeItem)
	}
	change := IdentityChange[T]{
		Entry:        entry,
		Active:       activeItem,
		ActiveRecord: activeRec,
		HasActive:    exists,
	}
	if exists && (activeRec.Identity == "" || entry.Identity == "" || activeRec.Identity != entry.Identity) {
		change.Split = true
	}
	modNano := entry.Modified.UnixNano()
	if entry.Identity != "" && (!exists || change.Split) {
		matches := 0
		for _, candidate := range snap.Missing[entry.Path] {
			rec := extract(candidate)
			if rec.Identity == entry.Identity && rec.Size == entry.Size && rec.Modified == modNano {
				matches++
				change.RestoreID = rec.ID
			}
		}
		if matches != 1 {
			change.RestoreID = 0
		}
	}
	if entry.Identity != "" && entry.SingleLink && change.RestoreID == 0 && (!exists || change.Split) {
		candidates := snap.ByIdentity[entry.Identity]
		if len(candidates) == 1 {
			rec := extract(candidates[0])
			if rec.Path != entry.Path && rec.Size == entry.Size && rec.Modified == modNano {
				if _, err := verifier.Stat(rec.Path); errors.Is(err, fs.ErrNotExist) {
					change.MoveID = rec.ID
					change.MoveFrom = rec.Path
				}
			}
		}
	}
	return change
}

// VerifyChangesPreTx re-verifies physical file identities and move sources
// immediately before opening the write transaction.
func VerifyChangesPreTx[T any](verifier MediaVerifier, changes []IdentityChange[T]) error {
	for _, item := range changes {
		if item.Entry.Identity != "" {
			if err := verifier.VerifyScannedMedia(item.Entry); err != nil {
				return err
			}
		}
		if item.MoveID != 0 {
			if _, err := verifier.Stat(item.MoveFrom); !errors.Is(err, fs.ErrNotExist) {
				return errors.New("media_move_source_changed")
			}
		}
	}
	return nil
}

// VerifyChangesPostTx re-verifies physical file identities, move sources, and
// single-link invariants right before committing the transaction.
func VerifyChangesPostTx[T any](verifier MediaVerifier, changes []IdentityChange[T]) error {
	for _, item := range changes {
		if item.Entry.Identity != "" {
			if err := verifier.VerifyScannedMedia(item.Entry); err != nil {
				return err
			}
		}
		if item.MoveID != 0 {
			if _, err := verifier.Stat(item.MoveFrom); !errors.Is(err, fs.ErrNotExist) {
				return errors.New("media_move_source_changed")
			}
			info, err := verifier.Stat(item.Entry.Path)
			if err != nil || !files.MediaFileHasSingleLink(info) {
				return errors.New("media_move_identity_ambiguous")
			}
		}
	}
	return nil
}

// ApplyIdentityChangesTx applies pending identity splits, restorations, and
// moves inside tx for the given media table ("assets" or "films").
func ApplyIdentityChangesTx[T any](
	ctx context.Context,
	tx *sql.Tx,
	table string,
	protectedPredicateSQL string,
	share string,
	changes []IdentityChange[T],
) error {
	checkSQL := fmt.Sprintf(`SELECT %s FROM %s WHERE share=? AND id=?`, protectedPredicateSQL, table)
	retireSQL := fmt.Sprintf(`UPDATE %s SET missing_path=path,missing_reason=?,path='.lightisle-missing/'||id WHERE share=? AND id=?`, table)
	deleteSQL := fmt.Sprintf(`DELETE FROM %s WHERE share=? AND id=?`, table)
	restoreSQL := fmt.Sprintf(`UPDATE %s SET path=?,missing_path='',missing_reason='' WHERE share=? AND id=? AND missing_path=? AND file_identity=?`, table)
	moveSQL := fmt.Sprintf(`UPDATE %s SET path=? WHERE share=? AND id=? AND path=? AND missing_path='' AND file_identity=?`, table)

	for _, item := range changes {
		if item.HasActive {
			var protected bool
			if err := tx.QueryRowContext(ctx, checkSQL, share, item.ActiveRecord.ID).Scan(&protected); err != nil {
				return err
			}
			if protected {
				reason := "identity_changed"
				if item.ActiveRecord.Identity == "" || item.Entry.Identity == "" {
					reason = "identity_unverified"
				}
				if _, err := tx.ExecContext(ctx, retireSQL, reason, share, item.ActiveRecord.ID); err != nil {
					return err
				}
			} else if item.RestoreID != 0 || item.MoveID != 0 {
				if _, err := tx.ExecContext(ctx, deleteSQL, share, item.ActiveRecord.ID); err != nil {
					return err
				}
			}
		}
		if item.RestoreID != 0 {
			if err := RequireOne(tx.ExecContext(ctx, restoreSQL, item.Entry.Path, share, item.RestoreID, item.Entry.Path, item.Entry.Identity)); err != nil {
				return err
			}
		}
		if item.MoveID != 0 {
			if err := RequireOne(tx.ExecContext(ctx, moveSQL, item.Entry.Path, share, item.MoveID, item.MoveFrom, item.Entry.Identity)); err != nil {
				return err
			}
		}
	}
	return nil
}

// ValidateMissingPage checks pagination parameters and trims limit+1 query rows
// into a page of items plus the next cursor ID.
func ValidateMissingPage(after int64, limit int) error {
	if after < 0 || limit < 1 || limit > 100 {
		return errors.New("invalid_page")
	}
	return nil
}

// FinalizeMissingPage trims a limit+1 slice to limit and computes next cursor.
func FinalizeMissingPage(items []Item, limit int) ([]Item, int64) {
	var next int64
	if len(items) > limit {
		items = items[:limit]
		next = items[len(items)-1].ID
	}
	return items, next
}

// VerifyAttachTarget resolves a verified active target media entry at originalPath.
func VerifyAttachTarget(
	verifier MediaVerifier,
	originalPath string,
	identity string,
	size int64,
	modifiedNano int64,
) (files.Entry, error) {
	if identity == "" {
		return files.Entry{}, ErrTargetUnavailable
	}
	entry := files.Entry{
		Path:     originalPath,
		Identity: identity,
		Size:     size,
		Modified: time.Unix(0, modifiedNano),
	}
	if err := verifier.VerifyScannedMedia(entry); err != nil {
		return files.Entry{}, ErrTargetUnavailable
	}
	return entry, nil
}

// DiscardMissingRow deletes a missing-media metadata record from table ("assets"
// or "films") under scope & guard protection without touching physical files.
func DiscardMissingRow(
	db *sql.DB,
	table string,
	alias string,
	share string,
	id int64,
	roots []string,
	guard Guard,
) error {
	clause, scope, err := mediascope.Clause(alias+".missing_path", roots)
	if err != nil {
		return err
	}
	args := append([]any{share, id}, scope...)
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var original string
	selectSQL := fmt.Sprintf(`SELECT %s.missing_path FROM %s %s WHERE %s.share=? AND %s.id=? AND %s.missing_path<>''%s`,
		alias, table, alias, alias, alias, alias, clause)
	if err := tx.QueryRow(selectSQL, args...).Scan(&original); err != nil {
		return err
	}
	if err := CheckGuard(guard, original); err != nil {
		return err
	}
	deleteSQL := fmt.Sprintf(`DELETE FROM %s AS %s WHERE %s.share=? AND %s.id=? AND %s.missing_path<>''%s`,
		table, alias, alias, alias, alias, clause)
	result, err := tx.Exec(deleteSQL, args...)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return sql.ErrNoRows
	}
	if err := CheckGuard(guard, original); err != nil {
		return err
	}
	return tx.Commit()
}
