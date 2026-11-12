package gallery

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

type scannedAssetRow struct {
	rec     mediapending.IndexedRecord
	kind    string
	status  string
	version int
}

func (r scannedAssetRow) record() mediapending.IndexedRecord { return r.rec }

const protectedAssetPredicate = `favorite<>0 OR EXISTS(SELECT 1 FROM personal_favorites WHERE asset_id=assets.id)
	OR EXISTS(SELECT 1 FROM album_items WHERE asset_id=assets.id)
	OR EXISTS(SELECT 1 FROM private_album_items WHERE asset_id=assets.id)`

type changedAssetBatchItem struct {
	entry files.Entry
	probe assetProbe
	taken int64
}

// The caller supplies one bounded ScanDirectory batch (at most 200 entries).
// Read only freshness fields, probe outside the database transaction, then
// commit one short batch. Unchanged assets need only a seen marker: loading
// and rewriting all EXIF fields also rewrites the timeline/geo indexes.
func (l *Library) indexScanBatch(ctx context.Context, share, physicalShare string, generation int64, entries []files.Entry) error {
	if len(entries) == 0 {
		return ctx.Err()
	}
	snap, err := l.loadScanBatchSnapshot(ctx, share, entries)
	if err != nil {
		return err
	}

	var identities []mediapending.IdentityChange[scannedAssetRow]
	var changed []changedAssetBatchItem
	seenArgs := make([]any, 2, len(entries)+2)
	seenArgs[0], seenArgs[1] = generation, share

	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		// Even when both sides lack identity, a matching name does not prove
		// this is the same file. Keep user metadata separately for review.
		change := mediapending.DetectIdentityChange(e, snap, scannedAssetRow.record, l.storage)
		if change.HasMutation() {
			identities = append(identities, change)
		}
		kind := mediaType(e.Name)
		if change.HasActive && !change.HasMutation() &&
			change.ActiveRecord.Size == e.Size &&
			change.ActiveRecord.Modified == e.Modified.UnixNano() &&
			change.Active.kind == kind &&
			change.Active.version >= exifSchemaVersion &&
			change.Active.status != "failed" {
			seenArgs = append(seenArgs, change.ActiveRecord.ID)
			continue
		}
		probe, taken := l.captureForAsset(ctx, e.Path, e.Name, kind, e.Size, e.Modified.UnixNano())
		changed = append(changed, changedAssetBatchItem{entry: e, probe: probe, taken: taken})
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if current, online := l.storage.State(); !online || current != physicalShare {
		return errors.New("share_changed_or_offline")
	}
	if err := mediapending.VerifyChangesPreTx(l.storage, identities); err != nil {
		return err
	}

	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := mediapending.ApplyIdentityChangesTx(ctx, tx, "assets", protectedAssetPredicate, share, identities); err != nil {
		return err
	}
	if len(seenArgs) > 2 {
		if _, err := tx.ExecContext(ctx, `UPDATE assets SET seen=? WHERE share=? AND id IN (`+
			strings.Repeat("?,", len(seenArgs)-3)+`?)`, seenArgs...); err != nil {
			return err
		}
	}
	if err := upsertChangedAssetsTx(ctx, tx, share, generation, changed); err != nil {
		return err
	}
	if err := mediapending.VerifyChangesPostTx(l.storage, identities); err != nil {
		return err
	}
	return tx.Commit()
}

func (l *Library) loadScanBatchSnapshot(ctx context.Context, share string, entries []files.Entry) (mediapending.Snapshot[scannedAssetRow], error) {
	query, args := mediapending.BuildBatchLookupQuery(
		"assets",
		"path,id,size,modified,type,probe_status,exif_version,file_identity,missing_path",
		share,
		entries,
	)
	rows, err := l.db.QueryContext(ctx, query, args...)
	if err != nil {
		return mediapending.Snapshot[scannedAssetRow]{}, err
	}
	defer rows.Close()

	snap := mediapending.NewSnapshot[scannedAssetRow](len(entries))
	for rows.Next() {
		var row scannedAssetRow
		if err := rows.Scan(
			&row.rec.Path, &row.rec.ID, &row.rec.Size, &row.rec.Modified,
			&row.kind, &row.status, &row.version, &row.rec.Identity, &row.rec.MissingPath,
		); err != nil {
			return mediapending.Snapshot[scannedAssetRow]{}, err
		}
		snap.Add(row.rec, row)
	}
	if err := rows.Err(); err != nil {
		return mediapending.Snapshot[scannedAssetRow]{}, err
	}
	return snap, nil
}

func upsertChangedAssetsTx(ctx context.Context, tx *sql.Tx, share string, generation int64, changed []changedAssetBatchItem) error {
	if len(changed) == 0 {
		return nil
	}
	stmt, err := tx.PrepareContext(ctx, scanAssetUpsert)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, item := range changed {
		e, p := item.entry, item.probe
		if _, err := stmt.ExecContext(ctx, share, e.Path, mediaType(e.Name), e.Size, e.Modified.UnixNano(), item.taken, generation, e.Identity,
			p.ProbeStatus, p.BrowserPlayback, p.MIME, p.Container, p.VideoCodec, p.AudioCodec,
			p.DurationSeconds, p.Width, p.Height, p.Orientation, p.CapturedAt,
			p.Latitude, p.Longitude, p.CameraMake, p.CameraModel, p.ExifJSON, p.ExifVersion); err != nil {
			return err
		}
	}
	return nil
}

const scanAssetUpsert = `INSERT INTO assets(share,path,type,size,modified,taken_at,seen,file_identity,probe_status,browser_playback,mime,container,video_codec,audio_codec,duration_seconds,width,height,orientation,captured_at,gps_lat,gps_lon,camera_make,camera_model,exif_json,exif_version)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET type=excluded.type,size=excluded.size,
      modified=excluded.modified,taken_at=excluded.taken_at,seen=excluded.seen,file_identity=excluded.file_identity,
      probe_status=excluded.probe_status,browser_playback=excluded.browser_playback,mime=excluded.mime,
      container=excluded.container,video_codec=excluded.video_codec,audio_codec=excluded.audio_codec,
      duration_seconds=excluded.duration_seconds,width=excluded.width,height=excluded.height,
      orientation=excluded.orientation,captured_at=excluded.captured_at,
      gps_lat=excluded.gps_lat,gps_lon=excluded.gps_lon,camera_make=excluded.camera_make,
      camera_model=excluded.camera_model,exif_json=excluded.exif_json,exif_version=excluded.exif_version`
