package cinema

import (
	"database/sql"
	"errors"

	"github.com/lengsukq/lightisle/core/internal/mediapending"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

func (l *Library) MissingMedia(roots []string, after int64, limit int) ([]mediapending.Item, int64, error) {
	if err := mediapending.ValidateMissingPage(after, limit); err != nil {
		return nil, 0, err
	}
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	clause, scope, err := mediascope.Clause("f.missing_path", roots)
	if err != nil {
		return nil, 0, err
	}
	args := append([]any{share, after}, scope...)
	args = append(args, limit+1)
	rows, err := l.db.Query(`SELECT f.id,f.missing_path,f.missing_reason,
		EXISTS(SELECT 1 FROM watch_progress p WHERE p.film_id=f.id),
		(f.manual_title<>0 OR f.title_source<>'' OR f.year_source<>'' OR f.metadata_source<>''),
		EXISTS(SELECT 1 FROM series s WHERE s.id=f.series_id AND (s.tmdb_id<>0 OR s.metadata_source<>''))
		FROM films f WHERE f.share=? AND f.id>? AND f.missing_path<>''`+clause+` ORDER BY f.id LIMIT ?`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := []mediapending.Item{}
	for rows.Next() {
		var item mediapending.Item
		var progress, metadata, series bool
		if err := rows.Scan(&item.ID, &item.Path, &item.Reason, &progress, &metadata, &series); err != nil {
			return nil, 0, err
		}
		item.Data = []string{}
		if progress {
			item.Data = append(item.Data, "progress")
		}
		if metadata || series {
			item.Data = append(item.Data, "metadata")
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	page, next := mediapending.FinalizeMissingPage(items, limit)
	return page, next, nil
}

// AttachMissing merges the old progress into the indexed file at the same
// path after owner confirmation. Conflicts remain pending rather than
// overwriting anyone's newer progress or confirmed film/series metadata.
func (l *Library) AttachMissing(id int64, roots []string) error {
	return l.AttachMissingGuarded(id, roots, nil)
}

func (l *Library) AttachMissingGuarded(id int64, roots []string, guard mediapending.Guard) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	clause, scope, err := mediascope.Clause("f.missing_path", roots)
	if err != nil {
		return err
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var original string
	var oldSeries int64
	var oldMetadata bool
	args := append([]any{share, id}, scope...)
	err = tx.QueryRow(`SELECT f.missing_path,f.series_id,(f.manual_title<>0 OR f.title_source<>'' OR f.year_source<>'' OR f.metadata_source<>'')
		FROM films f WHERE f.share=? AND f.id=? AND f.missing_path<>''`+clause, args...).Scan(&original, &oldSeries, &oldMetadata)
	if err != nil {
		return err
	}
	if err := mediapending.CheckGuard(guard, original); err != nil {
		return err
	}

	var target, size, modified, targetSeries int64
	var identity string
	var targetMetadata bool
	err = tx.QueryRow(`SELECT id,file_identity,size,modified,series_id,(manual_title<>0 OR title_source<>'' OR year_source<>'' OR metadata_source<>'')
		FROM films WHERE share=? AND path=? AND missing_path=''`, share, original).Scan(&target, &identity, &size, &modified, &targetSeries, &targetMetadata)
	if errors.Is(err, sql.ErrNoRows) {
		return mediapending.ErrTargetUnavailable
	}
	if err != nil {
		return err
	}
	entry, err := mediapending.VerifyAttachTarget(l.files, original, identity, size, modified)
	if err != nil {
		return err
	}
	if err := checkFilmAttachConflicts(tx, id, target, oldSeries, targetSeries, oldMetadata, targetMetadata); err != nil {
		return err
	}
	if err := mergeMissingFilmMetadataAndProgress(tx, share, id, target, oldMetadata); err != nil {
		return err
	}
	if err := l.files.VerifyScannedMedia(entry); err != nil {
		return mediapending.ErrTargetUnavailable
	}
	if err := mediapending.CheckGuard(guard, original); err != nil {
		return err
	}
	return tx.Commit()
}

func checkFilmAttachConflicts(tx *sql.Tx, sourceID, targetID, oldSeries, targetSeries int64, oldMetadata, targetMetadata bool) error {
	var progressConflict bool
	if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM watch_progress old JOIN watch_progress current ON current.user_id=old.user_id
		WHERE old.film_id=? AND current.film_id=?)`, sourceID, targetID).Scan(&progressConflict); err != nil {
		return err
	}
	if progressConflict || (oldMetadata && targetMetadata) {
		return mediapending.ErrConflict
	}
	if oldSeries != targetSeries && oldSeries != 0 {
		var seriesMetadata bool
		if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM series WHERE id=? AND (tmdb_id<>0 OR metadata_source<>''))`, oldSeries).Scan(&seriesMetadata); err != nil {
			return err
		}
		if seriesMetadata {
			return mediapending.ErrConflict
		}
	}
	return nil
}

func mergeMissingFilmMetadataAndProgress(tx *sql.Tx, share string, sourceID, targetID int64, copyMetadata bool) error {
	if copyMetadata {
		if _, err := tx.Exec(`UPDATE films SET
			title=(SELECT title FROM films WHERE id=?),manual_title=(SELECT manual_title FROM films WHERE id=?),
			year=(SELECT year FROM films WHERE id=?),title_source=(SELECT title_source FROM films WHERE id=?),
			year_source=(SELECT year_source FROM films WHERE id=?),overview=(SELECT overview FROM films WHERE id=?),
			rating=(SELECT rating FROM films WHERE id=?),metadata_source=(SELECT metadata_source FROM films WHERE id=?),
			poster_path=(SELECT poster_path FROM films WHERE id=?) WHERE share=? AND id=?`,
			sourceID, sourceID, sourceID, sourceID, sourceID, sourceID, sourceID, sourceID, sourceID, share, targetID); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`INSERT INTO watch_progress(user_id,film_id,position,duration,completed,updated_at)
		SELECT user_id,?,position,duration,completed,updated_at FROM watch_progress WHERE film_id=?`, targetID, sourceID); err != nil {
		return err
	}
	_, err := tx.Exec(`DELETE FROM films WHERE share=? AND id=? AND missing_path<>''`, share, sourceID)
	return err
}

func (l *Library) DiscardMissing(id int64, roots []string) error {
	return l.DiscardMissingGuarded(id, roots, nil)
}

func (l *Library) DiscardMissingGuarded(id int64, roots []string, guard mediapending.Guard) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	return mediapending.DiscardMissingRow(l.db, "films", "f", share, id, roots, guard)
}
