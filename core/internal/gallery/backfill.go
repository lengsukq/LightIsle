package gallery

import (
	"path"
	"time"
)

// backfillBatchSize bounds how many rows one pass upgrades before re-checking
// scan state. backfillPollInterval is how long an idle loop waits before
// looking for newly eligible rows again; backfillRetryDelay paces an active
// pass and the deferral while a scan is running.
const (
	backfillBatchSize    = 100
	backfillPollInterval = 5 * time.Minute
	backfillRetryDelay   = 3 * time.Second
)

// backfillLoop upgrades rows written by older extraction passes (or before
// capture columns existed) so locations and camera metadata surface without
// waiting for a rescan. It always defers to running scans, tolerates offline
// shares, and exits when the library closes.
func (l *Library) backfillLoop() {
	defer l.wg.Done()
	for {
		_, active := l.backfillTick()
		delay := backfillPollInterval
		if active {
			delay = backfillRetryDelay
		}
		select {
		case <-l.ctx.Done():
			return
		case <-time.After(delay):
		}
	}
}

// backfillTick processes up to one batch and reports whether work remains
// (rows still eligible, or a running scan paused the pass).
func (l *Library) backfillTick() (int, bool) {
	if l.Status().Running {
		return 0, true
	}
	share, err := l.share()
	if err != nil {
		return 0, false
	}
	rows, err := l.db.Query(`SELECT id,path,type,size,modified FROM assets
 WHERE share=? AND exif_version<? AND type IN ('photo','video') ORDER BY id LIMIT ?`,
		share, exifSchemaVersion, backfillBatchSize)
	if err != nil {
		return 0, false
	}
	type pending struct {
		id             int64
		path, kind     string
		size, modified int64
	}
	batch := []pending{}
	for rows.Next() {
		var item pending
		if err := rows.Scan(&item.id, &item.path, &item.kind, &item.size, &item.modified); err != nil {
			rows.Close()
			return 0, false
		}
		batch = append(batch, item)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, false
	}
	if len(batch) == 0 {
		l.refreshBackfillStatus(share)
		return 0, false
	}
	// A scan may have started between the eligibility check and now; rows it
	// rewrites win, so re-check before each row and stop the batch when a
	// scan takes over.
	processed := 0
	for _, item := range batch {
		if l.ctx.Err() != nil || l.Status().Running {
			break
		}
		if l.backfillRow(share, item.id, item.path, path.Base(item.path), item.kind, item.size, item.modified) {
			processed++
		}
	}
	l.refreshBackfillStatus(share)
	return processed, true
}

// backfillRow re-derives one row's capture columns. Failures still stamp the
// schema version: a file that cannot be read now would fail identically in the
// next pass, and rescans re-extract when mtime or size actually changes. The
// modified/size guards keep the update from racing a concurrent rescan.
func (l *Library) backfillRow(share string, id int64, assetPath, name, kind string, size, modified int64) bool {
	ctx, cancel := l.operationContext(nil)
	defer cancel()
	probe, taken := l.captureForAsset(ctx, assetPath, name, kind, size, modified, assetProbe{})
	result, err := l.db.Exec(`UPDATE assets SET taken_at=?,probe_status=?,browser_playback=?,mime=?,container=?,video_codec=?,audio_codec=?,duration_seconds=?,width=?,height=?,orientation=?,captured_at=?,gps_lat=?,gps_lon=?,camera_make=?,camera_model=?,exif_json=?,exif_version=?
 WHERE share=? AND id=? AND modified=? AND size=?`,
		taken, probe.ProbeStatus, probe.BrowserPlayback, probe.MIME, probe.Container, probe.VideoCodec, probe.AudioCodec,
		probe.DurationSeconds, probe.Width, probe.Height, probe.Orientation, probe.CapturedAt,
		probe.Latitude, probe.Longitude, probe.CameraMake, probe.CameraModel, probe.ExifJSON, probe.ExifVersion,
		share, id, modified, size)
	if err != nil {
		return false
	}
	affected, _ := result.RowsAffected()
	return affected > 0
}

// refreshBackfillStatus publishes the remaining counter. Total stays fixed at
// the peak queue size so processed progress is meaningful, and resets when the
// queue drains. The l.mu lock pairs with Status().
func (l *Library) refreshBackfillStatus(share string) {
	var remaining int
	if err := l.db.QueryRow(
		`SELECT COUNT(*) FROM assets WHERE share=? AND exif_version<? AND type IN ('photo','video')`,
		share, exifSchemaVersion).Scan(&remaining); err != nil {
		return
	}
	l.mu.Lock()
	if remaining == 0 {
		l.backfill = BackfillStatus{}
	} else if remaining > l.backfill.Total || l.backfill.Total == 0 {
		l.backfill = BackfillStatus{Running: true, Remaining: remaining, Total: remaining}
	} else {
		current := l.backfill
		current.Running = true
		current.Remaining = remaining
		l.backfill = current
	}
	l.mu.Unlock()
}
