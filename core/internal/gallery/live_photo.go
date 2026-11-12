package gallery

import (
	"context"
	"database/sql"
	"math"
	"path"
	"strings"
)

const (
	maxLivePhotoDurationSeconds = 6.5
	maxLivePhotoCaptureDeltaSec = 12
)

func ensureLivePhotoColumns(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(assets)`)
	if err != nil {
		return err
	}
	existing := map[string]bool{}
	for rows.Next() {
		var cid, notnull, primary int
		var name, dataType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &dataType, &notnull, &defaultValue, &primary); err != nil {
			rows.Close()
			return err
		}
		existing[name] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	_ = rows.Close()

	for _, col := range []struct{ name, ddl string }{
		{"live_video_asset_id", "INTEGER NOT NULL DEFAULT 0"},
		{"is_live_companion", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if existing[col.name] {
			continue
		}
		if _, err := db.Exec("ALTER TABLE assets ADD COLUMN " + col.name + " " + col.ddl); err != nil {
			return err
		}
	}
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS assets_live_companion ON assets(share, is_live_companion) WHERE is_live_companion<>0`)
	return err
}

func isLivePhotoStillCandidate(p string) bool {
	switch strings.ToLower(path.Ext(p)) {
	case ".heic", ".heif", ".jpg", ".jpeg", ".png", ".webp", ".dng":
		return true
	default:
		return false
	}
}

func isLivePhotoVideoCandidate(p string, duration float64, size int64) bool {
	ext := strings.ToLower(path.Ext(p))
	if ext != ".mov" && ext != ".mp4" && ext != ".m4v" {
		return false
	}
	if duration > maxLivePhotoDurationSeconds {
		return false
	}
	// When MediaWorker has not probed duration yet (duration == 0), bound size
	// to 40 MiB so full-length movies with matching names are never folded as Live Photos.
	if duration <= 0 && size > 40<<20 {
		return false
	}
	return true
}

func normalizeLivePhotoStem(relPath string) string {
	dir := path.Dir(relPath)
	base := path.Base(relPath)
	ext := path.Ext(base)
	stem := strings.ToLower(strings.TrimSuffix(base, ext))
	// Strip iOS backup Raw/Live companion prefixes if exported side-by-side (e.g. "lp.IMG_0001" or "IMG_0001_HEVC").
	stem = strings.TrimPrefix(stem, "lp.")
	stem = strings.TrimSuffix(stem, "_hevc")
	return dir + "/" + stem
}

type liveCandidateRow struct {
	id          int64
	path        string
	kind        string
	size        int64
	takenAt     int64
	durationSec float64
	liveVideoID int64
	isCompanion int
}

// reconcileLivePhotoPairs links same-directory still photos and short companion
// MOV/MP4 clips (e.g. IMG_1234.HEIC + IMG_1234.MOV) after a gallery scan completes.
func (l *Library) reconcileLivePhotoPairs(ctx context.Context, share string) error {
	rows, err := l.db.QueryContext(ctx, `
		SELECT id, path, type, size, taken_at, duration_seconds, live_video_asset_id, is_live_companion
		FROM assets
		WHERE share=? AND missing_path=''`, share)
	if err != nil {
		return err
	}
	var all []liveCandidateRow
	for rows.Next() {
		var r liveCandidateRow
		if err := rows.Scan(&r.id, &r.path, &r.kind, &r.size, &r.takenAt, &r.durationSec, &r.liveVideoID, &r.isCompanion); err != nil {
			rows.Close()
			return err
		}
		all = append(all, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	_ = rows.Close()

	type stemBucket struct {
		photos []liveCandidateRow
		videos []liveCandidateRow
	}
	buckets := make(map[string]*stemBucket)
	for _, r := range all {
		if r.kind == "photo" && isLivePhotoStillCandidate(r.path) {
			key := normalizeLivePhotoStem(r.path)
			b := buckets[key]
			if b == nil {
				b = &stemBucket{}
				buckets[key] = b
			}
			b.photos = append(b.photos, r)
		} else if r.kind == "video" && isLivePhotoVideoCandidate(r.path, r.durationSec, r.size) {
			key := normalizeLivePhotoStem(r.path)
			b := buckets[key]
			if b == nil {
				b = &stemBucket{}
				buckets[key] = b
			}
			b.videos = append(b.videos, r)
		}
	}

	desiredPhotoVideo := make(map[int64]int64)
	desiredCompanions := make(map[int64]bool)
	for _, b := range buckets {
		if len(b.photos) == 0 || len(b.videos) == 0 {
			continue
		}
		usedVideos := make(map[int64]bool)
		for _, photo := range b.photos {
			var bestVideoID int64
			bestDelta := int64(math.MaxInt64)
			for _, video := range b.videos {
				if usedVideos[video.id] {
					continue
				}
				delta := photo.takenAt - video.takenAt
				if delta < 0 {
					delta = -delta
				}
				// Same-directory exact stem match is canonical on iOS export;
				// allow wider delta when one side fell back to file mtime.
				if len(b.photos) > 1 && delta > maxLivePhotoCaptureDeltaSec {
					continue
				}
				if delta < bestDelta {
					bestDelta = delta
					bestVideoID = video.id
				}
			}
			if bestVideoID > 0 {
				usedVideos[bestVideoID] = true
				desiredPhotoVideo[photo.id] = bestVideoID
				desiredCompanions[bestVideoID] = true
			}
		}
	}

	var changed bool
	for _, r := range all {
		wantVid := desiredPhotoVideo[r.id]
		wantComp := 0
		if desiredCompanions[r.id] {
			wantComp = 1
		}
		if r.liveVideoID != wantVid || r.isCompanion != wantComp {
			changed = true
			break
		}
	}
	if !changed {
		return nil
	}

	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, r := range all {
		wantVid := desiredPhotoVideo[r.id]
		wantComp := 0
		if desiredCompanions[r.id] {
			wantComp = 1
		}
		if r.liveVideoID == wantVid && r.isCompanion == wantComp {
			continue
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE assets SET live_video_asset_id=?, is_live_companion=? WHERE id=? AND share=?`,
			wantVid, wantComp, r.id, share); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// LiveVideoCompanion returns the paired motion video asset for a Live Photo.
func (l *Library) LiveVideoCompanion(photoID int64) (Asset, Asset, error) {
	photo, err := l.Asset(photoID)
	if err != nil {
		return Asset{}, Asset{}, err
	}
	if photo.LiveVideoAssetID <= 0 {
		return photo, Asset{}, sql.ErrNoRows
	}
	video, err := l.Asset(photo.LiveVideoAssetID)
	if err != nil {
		return photo, Asset{}, err
	}
	return photo, video, nil
}
