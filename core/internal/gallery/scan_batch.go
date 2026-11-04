package gallery

import (
	"context"
	"errors"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// The caller supplies one bounded ScanDirectory batch (at most 200 entries).
// Read only freshness fields, probe outside the database transaction, then
// commit one short batch. Unchanged assets need only a seen marker: loading
// and rewriting all EXIF fields also rewrites the timeline/geo indexes.
func (l *Library) indexScanBatch(ctx context.Context, share, physicalShare string, generation int64, entries []files.Entry) error {
	if len(entries) == 0 {
		return ctx.Err()
	}
	type previous struct {
		id, size, modified int64
		kind, status       string
		version            int
	}
	args := make([]any, 1, len(entries)+1)
	args[0] = share
	for _, e := range entries {
		args = append(args, e.Path)
	}
	rows, err := l.db.QueryContext(ctx, `SELECT path,id,size,modified,type,probe_status,exif_version
		FROM assets WHERE share=? AND path IN (`+strings.Repeat("?,", len(entries)-1)+`?)`, args...)
	if err != nil {
		return err
	}
	old := make(map[string]previous, len(entries))
	for rows.Next() {
		var path string
		var p previous
		if err := rows.Scan(&path, &p.id, &p.size, &p.modified, &p.kind, &p.status, &p.version); err != nil {
			rows.Close()
			return err
		}
		old[path] = p
	}
	readErr := rows.Err()
	rows.Close()
	if readErr != nil {
		return readErr
	}
	type changedAsset struct {
		entry files.Entry
		probe assetProbe
		taken int64
	}
	var changed []changedAsset
	seen := make([]any, 2, len(entries)+2)
	seen[0], seen[1] = generation, share
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		p, exists := old[e.Path]
		kind := mediaType(e.Name)
		if exists && p.size == e.Size && p.modified == e.Modified.UnixNano() && p.kind == kind &&
			p.version >= exifSchemaVersion && p.status != "failed" {
			seen = append(seen, p.id)
			continue
		}
		probe, taken := l.captureForAsset(ctx, e.Path, e.Name, kind, e.Size, e.Modified.UnixNano())
		changed = append(changed, changedAsset{entry: e, probe: probe, taken: taken})
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if current, online := l.storage.State(); !online || current != physicalShare {
		return errors.New("share_changed_or_offline")
	}
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if len(seen) > 2 {
		if _, err := tx.ExecContext(ctx, `UPDATE assets SET seen=? WHERE share=? AND id IN (`+
			strings.Repeat("?,", len(seen)-3)+`?)`, seen...); err != nil {
			return err
		}
	}
	if len(changed) > 0 {
		stmt, err := tx.PrepareContext(ctx, scanAssetUpsert)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for _, item := range changed {
			e, p := item.entry, item.probe
			if _, err := stmt.ExecContext(ctx, share, e.Path, mediaType(e.Name), e.Size, e.Modified.UnixNano(), item.taken, generation,
				p.ProbeStatus, p.BrowserPlayback, p.MIME, p.Container, p.VideoCodec, p.AudioCodec,
				p.DurationSeconds, p.Width, p.Height, p.Orientation, p.CapturedAt,
				p.Latitude, p.Longitude, p.CameraMake, p.CameraModel, p.ExifJSON, p.ExifVersion); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

const scanAssetUpsert = `INSERT INTO assets(share,path,type,size,modified,taken_at,seen,probe_status,browser_playback,mime,container,video_codec,audio_codec,duration_seconds,width,height,orientation,captured_at,gps_lat,gps_lon,camera_make,camera_model,exif_json,exif_version)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET type=excluded.type,size=excluded.size,
      modified=excluded.modified,taken_at=excluded.taken_at,seen=excluded.seen,
      probe_status=excluded.probe_status,browser_playback=excluded.browser_playback,mime=excluded.mime,
      container=excluded.container,video_codec=excluded.video_codec,audio_codec=excluded.audio_codec,
      duration_seconds=excluded.duration_seconds,width=excluded.width,height=excluded.height,
      orientation=excluded.orientation,captured_at=excluded.captured_at,
      gps_lat=excluded.gps_lat,gps_lon=excluded.gps_lon,camera_make=excluded.camera_make,
      camera_model=excluded.camera_model,exif_json=excluded.exif_json,exif_version=excluded.exif_version`
