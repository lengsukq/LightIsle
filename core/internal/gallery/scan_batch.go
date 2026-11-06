package gallery

import (
	"context"
	"errors"
	"io/fs"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
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
		id, size, modified                        int64
		path, kind, status, identity, missingPath string
		version                                   int
	}
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
	rows, err := l.db.QueryContext(ctx, `SELECT path,id,size,modified,type,probe_status,exif_version,file_identity,missing_path
		FROM assets WHERE share=? AND (path IN (`+placeholders+`) OR missing_path IN (`+placeholders+`) OR (missing_path='' AND file_identity<>'' AND file_identity IN (`+placeholders+`)))`, args...)
	if err != nil {
		return err
	}
	old := make(map[string]previous, len(entries))
	missing := make(map[string][]previous)
	byIdentity := make(map[string][]previous)
	for rows.Next() {
		var path string
		var p previous
		if err := rows.Scan(&path, &p.id, &p.size, &p.modified, &p.kind, &p.status, &p.version, &p.identity, &p.missingPath); err != nil {
			rows.Close()
			return err
		}
		if p.missingPath != "" {
			missing[p.missingPath] = append(missing[p.missingPath], p)
		} else {
			p.path = path
			old[path] = p
			if p.identity != "" {
				byIdentity[p.identity] = append(byIdentity[p.identity], p)
			}
		}
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
	type identityChange struct {
		entry     files.Entry
		active    previous
		hasActive bool
		restoreID int64
		moveID    int64
		moveFrom  string
		split     bool
	}
	var identities []identityChange
	var changed []changedAsset
	seen := make([]any, 2, len(entries)+2)
	seen[0], seen[1] = generation, share
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		p, exists := old[e.Path]
		change := identityChange{entry: e, active: p, hasActive: exists}
		// Even when both sides lack identity, a matching name does not prove
		// this is the same file. Keep user metadata separately for review.
		if exists && (p.identity == "" || e.Identity == "" || p.identity != e.Identity) {
			change.split = true
		}
		if e.Identity != "" && (!exists || change.split) {
			matches := 0
			for _, candidate := range missing[e.Path] {
				if candidate.identity == e.Identity && candidate.size == e.Size && candidate.modified == e.Modified.UnixNano() {
					matches++
					change.restoreID = candidate.id
				}
			}
			if matches != 1 {
				change.restoreID = 0
			}
		}
		if e.Identity != "" && e.SingleLink && change.restoreID == 0 && (!exists || change.split) {
			candidates := byIdentity[e.Identity]
			if len(candidates) == 1 {
				candidate := candidates[0]
				if candidate.path != e.Path && candidate.size == e.Size && candidate.modified == e.Modified.UnixNano() {
					if _, err := l.storage.Stat(candidate.path); errors.Is(err, fs.ErrNotExist) {
						change.moveID, change.moveFrom = candidate.id, candidate.path
					}
				}
			}
		}
		if change.split || change.restoreID != 0 || change.moveID != 0 {
			identities = append(identities, change)
		}
		kind := mediaType(e.Name)
		if exists && !change.split && change.restoreID == 0 && change.moveID == 0 && p.size == e.Size && p.modified == e.Modified.UnixNano() && p.kind == kind &&
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
	for _, item := range identities {
		if item.entry.Identity != "" {
			if err := l.storage.VerifyScannedMedia(item.entry); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if _, err := l.storage.Stat(item.moveFrom); !errors.Is(err, fs.ErrNotExist) {
				return errors.New("media_move_source_changed")
			}
		}
	}
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, item := range identities {
		if item.hasActive {
			var protected bool
			err := tx.QueryRowContext(ctx, `SELECT favorite<>0 OR EXISTS(SELECT 1 FROM personal_favorites WHERE asset_id=assets.id)
				OR EXISTS(SELECT 1 FROM album_items WHERE asset_id=assets.id)
				OR EXISTS(SELECT 1 FROM private_album_items WHERE asset_id=assets.id)
				FROM assets WHERE share=? AND id=?`, share, item.active.id).Scan(&protected)
			if err != nil {
				return err
			}
			if protected {
				reason := "identity_changed"
				if item.active.identity == "" || item.entry.Identity == "" {
					reason = "identity_unverified"
				}
				if _, err := tx.ExecContext(ctx, `UPDATE assets SET missing_path=path,missing_reason=?,path='.lightisle-missing/'||id WHERE share=? AND id=?`, reason, share, item.active.id); err != nil {
					return err
				}
			} else if item.restoreID != 0 || item.moveID != 0 {
				if _, err := tx.ExecContext(ctx, `DELETE FROM assets WHERE share=? AND id=?`, share, item.active.id); err != nil {
					return err
				}
			}
		}
		if item.restoreID != 0 {
			if err := mediapending.RequireOne(tx.ExecContext(ctx, `UPDATE assets SET path=?,missing_path='',missing_reason='' WHERE share=? AND id=? AND missing_path=? AND file_identity=?`, item.entry.Path, share, item.restoreID, item.entry.Path, item.entry.Identity)); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if err := mediapending.RequireOne(tx.ExecContext(ctx, `UPDATE assets SET path=? WHERE share=? AND id=? AND path=? AND missing_path='' AND file_identity=?`, item.entry.Path, share, item.moveID, item.moveFrom, item.entry.Identity)); err != nil {
				return err
			}
		}
	}
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
			if _, err := stmt.ExecContext(ctx, share, e.Path, mediaType(e.Name), e.Size, e.Modified.UnixNano(), item.taken, generation, e.Identity,
				p.ProbeStatus, p.BrowserPlayback, p.MIME, p.Container, p.VideoCodec, p.AudioCodec,
				p.DurationSeconds, p.Width, p.Height, p.Orientation, p.CapturedAt,
				p.Latitude, p.Longitude, p.CameraMake, p.CameraModel, p.ExifJSON, p.ExifVersion); err != nil {
				return err
			}
		}
	}
	for _, item := range identities {
		if item.entry.Identity != "" {
			if err := l.storage.VerifyScannedMedia(item.entry); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if _, err := l.storage.Stat(item.moveFrom); !errors.Is(err, fs.ErrNotExist) {
				return errors.New("media_move_source_changed")
			}
			info, err := l.storage.Stat(item.entry.Path)
			if err != nil || !files.MediaFileHasSingleLink(info) {
				return errors.New("media_move_identity_ambiguous")
			}
		}
	}
	return tx.Commit()
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
