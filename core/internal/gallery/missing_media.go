package gallery

import (
	"database/sql"
	"errors"

	"github.com/lengsukq/lightisle/core/internal/mediapending"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// MissingMedia lists only the owner's bound paths (or all paths for an
// administrator). The original path is retained separately from the hidden
// index path so ordinary media queries cannot expose stale files.
func (l *Library) MissingMedia(roots []string, after int64, limit int) ([]mediapending.Item, int64, error) {
	if err := mediapending.ValidateMissingPage(after, limit); err != nil {
		return nil, 0, err
	}
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	clause, scope, err := mediascope.Clause("a.missing_path", roots)
	if err != nil {
		return nil, 0, err
	}
	args := append([]any{share, after}, scope...)
	args = append(args, limit+1)
	rows, err := l.readDB().Query(`SELECT a.id,a.missing_path,a.missing_reason,a.favorite<>0,
		EXISTS(SELECT 1 FROM personal_favorites p WHERE p.asset_id=a.id),
		EXISTS(SELECT 1 FROM album_items i WHERE i.asset_id=a.id),
		EXISTS(SELECT 1 FROM private_album_items i WHERE i.asset_id=a.id)
		FROM assets a WHERE a.share=? AND a.id>? AND a.missing_path<>''`+clause+` ORDER BY a.id LIMIT ?`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := []mediapending.Item{}
	for rows.Next() {
		var item mediapending.Item
		var favorite, personal, album, private bool
		if err := rows.Scan(&item.ID, &item.Path, &item.Reason, &favorite, &personal, &album, &private); err != nil {
			return nil, 0, err
		}
		item.Data = []string{}
		if favorite || personal {
			item.Data = append(item.Data, "favorites")
		}
		if album || private {
			item.Data = append(item.Data, "albums")
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	page, next := mediapending.FinalizeMissingPage(items, limit)
	return page, next, nil
}

// AttachMissing deliberately merges old user data into the current file at
// the same original path. It is available only after explicit owner consent;
// a current file must be indexed and its physical identity verified twice.
func (l *Library) AttachMissing(id int64, roots []string) error {
	return l.AttachMissingGuarded(id, roots, nil)
}

func (l *Library) AttachMissingGuarded(id int64, roots []string, guard mediapending.Guard) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	clause, scope, err := mediascope.Clause("a.missing_path", roots)
	if err != nil {
		return err
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var original string
	args := append([]any{share, id}, scope...)
	if err := tx.QueryRow(`SELECT a.missing_path FROM assets a WHERE a.share=? AND a.id=? AND a.missing_path<>''`+clause, args...).Scan(&original); err != nil {
		return err
	}
	if err := mediapending.CheckGuard(guard, original); err != nil {
		return err
	}

	var target, size, modified int64
	var identity string
	err = tx.QueryRow(`SELECT id,file_identity,size,modified FROM assets WHERE share=? AND path=? AND missing_path=''`, share, original).Scan(&target, &identity, &size, &modified)
	if errors.Is(err, sql.ErrNoRows) {
		return mediapending.ErrTargetUnavailable
	}
	if err != nil {
		return err
	}
	entry, err := mediapending.VerifyAttachTarget(l.storage, original, identity, size, modified)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE assets SET favorite=MAX(favorite,(SELECT favorite FROM assets WHERE id=?)) WHERE share=? AND id=?`, id, share, target); err != nil {
		return err
	}
	for _, query := range []string{
		`INSERT INTO personal_favorites(user_id,asset_id) SELECT user_id,? FROM personal_favorites WHERE asset_id=? ON CONFLICT DO NOTHING`,
		`INSERT INTO album_items(album_id,asset_id) SELECT album_id,? FROM album_items WHERE asset_id=? ON CONFLICT DO NOTHING`,
		`INSERT INTO private_album_items(album_id,asset_id) SELECT album_id,? FROM private_album_items WHERE asset_id=? ON CONFLICT DO NOTHING`,
	} {
		if _, err := tx.Exec(query, target, id); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM assets WHERE share=? AND id=? AND missing_path<>''`, share, id); err != nil {
		return err
	}
	if err := l.storage.VerifyScannedMedia(entry); err != nil {
		return mediapending.ErrTargetUnavailable
	}
	if err := mediapending.CheckGuard(guard, original); err != nil {
		return err
	}
	return tx.Commit()
}

// DiscardMissingGuarded deletes retained application metadata only, never a file.
// The scope predicate is evaluated by SQLite in the same delete operation.
func (l *Library) DiscardMissingGuarded(id int64, roots []string, guard mediapending.Guard) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	return mediapending.DiscardMissingRow(l.db, "assets", "a", share, id, roots, guard)
}
