package cinema

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// ScanDirectory bounds this slice to 200 entries. Worker calls and filename
// parsing happen before the transaction so readers never wait for a decoder.
func (l *Library) indexScanBatch(ctx context.Context, share, physicalShare string, generation int64, entries []files.Entry) error {
	if len(entries) == 0 {
		return ctx.Err()
	}
	type previous struct {
		size, modified int64
		status         string
	}
	args := make([]any, 1, len(entries)+1)
	args[0] = share
	for _, e := range entries {
		args = append(args, e.Path)
	}
	rows, err := l.db.QueryContext(ctx, `SELECT path,size,modified,probe_status FROM films
		WHERE share=? AND path IN (`+strings.Repeat("?,", len(entries)-1)+`?)`, args...)
	if err != nil {
		return err
	}
	old := make(map[string]previous, len(entries))
	for rows.Next() {
		var path string
		var p previous
		if err := rows.Scan(&path, &p.size, &p.modified, &p.status); err != nil {
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
	type film struct {
		entry                 files.Entry
		title, kind, series   string
		season, episode, year int
		fresh                 bool
		probe                 filmProbe
	}
	batch := make([]film, 0, len(entries))
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		p, exists := old[e.Path]
		item := film{entry: e, fresh: exists && p.size == e.Size && p.modified == e.Modified.UnixNano() &&
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
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
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
			_, err = changed.ExecContext(ctx, share, e.Path, item.title, item.kind, item.series, item.season, item.episode, item.year, e.Size, e.Modified.UnixNano(), generation,
				p.ProbeStatus, p.BrowserPlayback, p.Container, p.VideoCodec, p.AudioCodec,
				p.DurationSeconds, p.Width, p.Height, p.CapturedAt)
		}
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

const scanFilmUpsert = `INSERT INTO films(share,path,title,kind,series,season,episode,year,size,modified,seen,probe_status,browser_playback,container,video_codec,audio_codec,duration_seconds,width,height,captured_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(share,path) DO UPDATE SET
      title=CASE WHEN manual_title=1 OR title_source<>'' THEN title ELSE excluded.title END,
      kind=excluded.kind,series=excluded.series,season=excluded.season,
      episode=excluded.episode,
      year=CASE WHEN year_source<>'' THEN year ELSE excluded.year END,
      size=excluded.size,
      modified=excluded.modified,seen=excluded.seen,probe_status=excluded.probe_status,
      browser_playback=excluded.browser_playback,container=excluded.container,video_codec=excluded.video_codec,
      audio_codec=excluded.audio_codec,duration_seconds=excluded.duration_seconds,width=excluded.width,
      height=excluded.height,captured_at=excluded.captured_at`
