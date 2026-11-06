package cinema

import (
	"context"
	"database/sql"
	"errors"
	"io/fs"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

// ScanDirectory bounds this slice to 200 entries. Worker calls and filename
// parsing happen before the transaction so readers never wait for a decoder.
func (l *Library) indexScanBatch(ctx context.Context, share, physicalShare string, generation int64, entries []files.Entry) error {
	if len(entries) == 0 {
		return ctx.Err()
	}
	type previous struct {
		id                                  int64
		size, modified                      int64
		path, status, identity, missingPath string
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
	rows, err := l.db.QueryContext(ctx, `SELECT path,id,size,modified,probe_status,file_identity,missing_path FROM films
		WHERE share=? AND (path IN (`+placeholders+`) OR missing_path IN (`+placeholders+`) OR (missing_path='' AND file_identity<>'' AND file_identity IN (`+placeholders+`)))`, args...)
	if err != nil {
		return err
	}
	old := make(map[string]previous, len(entries))
	missing := make(map[string][]previous)
	byIdentity := make(map[string][]previous)
	for rows.Next() {
		var path string
		var p previous
		if err := rows.Scan(&path, &p.id, &p.size, &p.modified, &p.status, &p.identity, &p.missingPath); err != nil {
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
	type film struct {
		entry                 files.Entry
		title, kind, series   string
		season, episode, year int
		fresh                 bool
		probe                 filmProbe
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
	batch := make([]film, 0, len(entries))
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		p, exists := old[e.Path]
		change := identityChange{entry: e, active: p, hasActive: exists}
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
					if _, err := l.files.Stat(candidate.path); errors.Is(err, fs.ErrNotExist) {
						change.moveID, change.moveFrom = candidate.id, candidate.path
					}
				}
			}
		}
		if change.split || change.restoreID != 0 || change.moveID != 0 {
			identities = append(identities, change)
		}
		item := film{entry: e, fresh: exists && !change.split && change.restoreID == 0 && change.moveID == 0 && p.size == e.Size && p.modified == e.Modified.UnixNano() &&
			(p.status == "ready" || p.status == "unsupported")}
		item.title, item.kind, item.series, item.season, item.episode, item.year = Identify(e.Name)
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
	for _, item := range identities {
		if item.entry.Identity != "" {
			if err := l.files.VerifyScannedMedia(item.entry); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if _, err := l.files.Stat(item.moveFrom); !errors.Is(err, fs.ErrNotExist) {
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
			err := tx.QueryRowContext(ctx, `SELECT manual_title<>0 OR title_source<>'' OR year_source<>'' OR metadata_source<>''
				OR EXISTS(SELECT 1 FROM watch_progress WHERE film_id=films.id)
				OR EXISTS(SELECT 1 FROM series s WHERE s.id=films.series_id AND (s.tmdb_id<>0 OR s.metadata_source<>''))
				FROM films WHERE share=? AND id=?`, share, item.active.id).Scan(&protected)
			if err != nil {
				return err
			}
			if protected {
				reason := "identity_changed"
				if item.active.identity == "" || item.entry.Identity == "" {
					reason = "identity_unverified"
				}
				if _, err := tx.ExecContext(ctx, `UPDATE films SET missing_path=path,missing_reason=?,path='.lightisle-missing/'||id WHERE share=? AND id=?`, reason, share, item.active.id); err != nil {
					return err
				}
			} else if item.restoreID != 0 || item.moveID != 0 {
				if _, err := tx.ExecContext(ctx, `DELETE FROM films WHERE share=? AND id=?`, share, item.active.id); err != nil {
					return err
				}
			}
		}
		if item.restoreID != 0 {
			if err := mediapending.RequireOne(tx.ExecContext(ctx, `UPDATE films SET path=?,missing_path='',missing_reason='' WHERE share=? AND id=? AND missing_path=? AND file_identity=?`, item.entry.Path, share, item.restoreID, item.entry.Path, item.entry.Identity)); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if err := mediapending.RequireOne(tx.ExecContext(ctx, `UPDATE films SET path=? WHERE share=? AND id=? AND path=? AND missing_path='' AND file_identity=?`, item.entry.Path, share, item.moveID, item.moveFrom, item.entry.Identity)); err != nil {
				return err
			}
		}
	}
	var fresh, changed *sql.Stmt
	defer func() {
		if fresh != nil {
			fresh.Close()
		}
		if changed != nil {
			changed.Close()
		}
	}()
	for _, item := range batch {
		e, p := item.entry, item.probe
		if item.fresh {
			if fresh == nil {
				fresh, err = tx.PrepareContext(ctx, `UPDATE films SET
					title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE ? END,
					kind=?,series=?,season=?,episode=?,year=CASE WHEN year_source<>'' THEN year ELSE ? END,
					seen=? WHERE share=? AND path=?`)
				if err != nil {
					return err
				}
			}
			_, err = fresh.ExecContext(ctx, item.title, item.kind, item.series, item.season, item.episode, item.year, generation, share, e.Path)
		} else {
			if changed == nil {
				changed, err = tx.PrepareContext(ctx, scanFilmUpsert)
				if err != nil {
					return err
				}
			}
			_, err = changed.ExecContext(ctx, share, e.Path, item.title, item.kind, item.series, item.season, item.episode, item.year, e.Size, e.Modified.UnixNano(), generation, e.Identity,
				p.ProbeStatus, p.BrowserPlayback, p.Container, p.VideoCodec, p.AudioCodec,
				p.DurationSeconds, p.Width, p.Height, p.CapturedAt)
		}
		if err != nil {
			return err
		}
	}
	for _, item := range identities {
		if item.entry.Identity != "" {
			if err := l.files.VerifyScannedMedia(item.entry); err != nil {
				return err
			}
		}
		if item.moveID != 0 {
			if _, err := l.files.Stat(item.moveFrom); !errors.Is(err, fs.ErrNotExist) {
				return errors.New("media_move_source_changed")
			}
			info, err := l.files.Stat(item.entry.Path)
			if err != nil || !files.MediaFileHasSingleLink(info) {
				return errors.New("media_move_identity_ambiguous")
			}
		}
	}
	return tx.Commit()
}

const scanFilmUpsert = `INSERT INTO films(share,path,title,kind,series,season,episode,year,size,modified,seen,file_identity,probe_status,browser_playback,container,video_codec,audio_codec,duration_seconds,width,height,captured_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET
      title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE excluded.title END,
      kind=excluded.kind,series=excluded.series,season=excluded.season,
      episode=excluded.episode,
      year=CASE WHEN year_source<>'' THEN year ELSE excluded.year END,
      size=excluded.size,
      modified=excluded.modified,seen=excluded.seen,file_identity=excluded.file_identity,probe_status=excluded.probe_status,
      browser_playback=excluded.browser_playback,container=excluded.container,video_codec=excluded.video_codec,
      audio_codec=excluded.audio_codec,duration_seconds=excluded.duration_seconds,width=excluded.width,
      height=excluded.height,captured_at=excluded.captured_at`
