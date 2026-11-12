package cinema

import (
	"context"
	"database/sql"
	"errors"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

type scannedFilmRow struct {
	rec    mediapending.IndexedRecord
	status string
}

func (r scannedFilmRow) record() mediapending.IndexedRecord { return r.rec }

const protectedFilmPredicate = `manual_title<>0 OR title_source<>'' OR year_source<>'' OR metadata_source<>''
	OR EXISTS(SELECT 1 FROM watch_progress WHERE film_id=films.id)
	OR EXISTS(SELECT 1 FROM series s WHERE s.id=films.series_id AND (s.tmdb_id<>0 OR s.metadata_source<>''))`

type filmBatchItem struct {
	entry                 files.Entry
	title, kind, series   string
	season, episode, year int
	fresh                 bool
	probe                 filmProbe
}

// ScanDirectory bounds this slice to 200 entries. Worker calls and filename
// parsing happen before the transaction so readers never wait for a decoder.
func (l *Library) indexScanBatch(ctx context.Context, share, physicalShare string, generation int64, entries []files.Entry) error {
	if len(entries) == 0 {
		return ctx.Err()
	}
	snap, err := l.loadScanBatchSnapshot(ctx, share, entries)
	if err != nil {
		return err
	}

	var identities []mediapending.IdentityChange[scannedFilmRow]
	batch := make([]filmBatchItem, 0, len(entries))
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		change := mediapending.DetectIdentityChange(e, snap, scannedFilmRow.record, l.files)
		if change.HasMutation() {
			identities = append(identities, change)
		}
		fresh := change.HasActive && !change.HasMutation() &&
			change.ActiveRecord.Size == e.Size &&
			change.ActiveRecord.Modified == e.Modified.UnixNano() &&
			(change.Active.status == "ready" || change.Active.status == "unsupported")

		item := filmBatchItem{entry: e, fresh: fresh}
		item.title, item.kind, item.series, item.season, item.episode, item.year = IdentifyPath(e.Path)
		if !item.fresh {
			item.probe = l.probeFilm(ctx, e.Path, e.Name, e.Size, e.Modified.UnixNano())
		}
		batch = append(batch, item)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if current, online := l.files.State(); !online || current != physicalShare {
		return errors.New("share_changed")
	}
	if err := mediapending.VerifyChangesPreTx(l.files, identities); err != nil {
		return err
	}

	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := mediapending.ApplyIdentityChangesTx(ctx, tx, "films", protectedFilmPredicate, share, identities); err != nil {
		return err
	}
	if err := upsertScannedFilmsTx(ctx, tx, share, generation, batch); err != nil {
		return err
	}
	if err := mediapending.VerifyChangesPostTx(l.files, identities); err != nil {
		return err
	}
	return tx.Commit()
}

func (l *Library) loadScanBatchSnapshot(ctx context.Context, share string, entries []files.Entry) (mediapending.Snapshot[scannedFilmRow], error) {
	query, args := mediapending.BuildBatchLookupQuery(
		"films",
		"path,id,size,modified,probe_status,file_identity,missing_path",
		share,
		entries,
	)
	rows, err := l.db.QueryContext(ctx, query, args...)
	if err != nil {
		return mediapending.Snapshot[scannedFilmRow]{}, err
	}
	defer rows.Close()

	snap := mediapending.NewSnapshot[scannedFilmRow](len(entries))
	for rows.Next() {
		var row scannedFilmRow
		if err := rows.Scan(
			&row.rec.Path, &row.rec.ID, &row.rec.Size, &row.rec.Modified,
			&row.status, &row.rec.Identity, &row.rec.MissingPath,
		); err != nil {
			return mediapending.Snapshot[scannedFilmRow]{}, err
		}
		snap.Add(row.rec, row)
	}
	if err := rows.Err(); err != nil {
		return mediapending.Snapshot[scannedFilmRow]{}, err
	}
	return snap, nil
}

func upsertScannedFilmsTx(ctx context.Context, tx *sql.Tx, share string, generation int64, batch []filmBatchItem) error {
	var freshStmt, changedStmt *sql.Stmt
	defer func() {
		if freshStmt != nil {
			_ = freshStmt.Close()
		}
		if changedStmt != nil {
			_ = changedStmt.Close()
		}
	}()
	for _, item := range batch {
		e, p := item.entry, item.probe
		var err error
		if item.fresh {
			if freshStmt == nil {
				freshStmt, err = tx.PrepareContext(ctx, scanFilmFreshUpdate)
				if err != nil {
					return err
				}
			}
			_, err = freshStmt.ExecContext(ctx, item.title, item.kind, item.series, item.season, item.episode, item.year, generation, share, e.Path)
		} else {
			if changedStmt == nil {
				changedStmt, err = tx.PrepareContext(ctx, scanFilmUpsert)
				if err != nil {
					return err
				}
			}
			_, err = changedStmt.ExecContext(ctx, share, e.Path, item.title, item.kind, item.series, item.season, item.episode, item.year, e.Size, e.Modified.UnixNano(), generation, e.Identity,
				p.ProbeStatus, p.BrowserPlayback, p.Container, p.VideoCodec, p.AudioCodec,
				p.DurationSeconds, p.Width, p.Height, p.CapturedAt)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

const scanFilmFreshUpdate = `UPDATE films SET
	title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE ? END,
	kind=?,
	series=CASE WHEN EXISTS(SELECT 1 FROM series s WHERE s.id=films.series_id AND (s.tmdb_id<>0 OR s.metadata_source<>'')) THEN series ELSE ? END,
	season=?,episode=?,year=CASE WHEN year_source<>'' THEN year ELSE ? END,
	seen=? WHERE share=? AND path=?`

const scanFilmUpsert = `INSERT INTO films(share,path,title,kind,series,season,episode,year,size,modified,seen,file_identity,probe_status,browser_playback,container,video_codec,audio_codec,duration_seconds,width,height,captured_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET
      title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE excluded.title END,
      kind=excluded.kind,
      series=CASE WHEN EXISTS(SELECT 1 FROM series s WHERE s.id=films.series_id AND (s.tmdb_id<>0 OR s.metadata_source<>'')) THEN films.series ELSE excluded.series END,
      season=excluded.season,
      episode=excluded.episode,
      year=CASE WHEN year_source<>'' THEN year ELSE excluded.year END,
      size=excluded.size,
      modified=excluded.modified,seen=excluded.seen,file_identity=excluded.file_identity,probe_status=excluded.probe_status,
      browser_playback=excluded.browser_playback,container=excluded.container,video_codec=excluded.video_codec,
      audio_codec=excluded.audio_codec,duration_seconds=excluded.duration_seconds,width=excluded.width,
      height=excluded.height,captured_at=excluded.captured_at`
