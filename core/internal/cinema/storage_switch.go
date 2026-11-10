package cinema

import (
	"context"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

type switchFilm struct {
	name, title, kind, series, identity string
	size, modified, updatedAt           int64
	season, episode, year               int
	position, duration                  float64
	completed                           bool
}

func (l *Library) CopySwitchProgress(ctx context.Context, target *Library, owner int64, prefix string, verified map[string]files.SwitchMediaPair) error {
	sourceShare, err := l.share()
	if err != nil {
		return err
	}
	targetShare, err := target.share()
	if err != nil {
		return err
	}
	clause, scope, err := mediascope.Clause("f.path", []string{prefix})
	if err != nil {
		return err
	}
	rows, err := l.db.QueryContext(ctx, `SELECT f.path,f.title,f.kind,f.series,f.season,f.episode,f.year,f.file_identity,f.size,f.modified,
 p.position,p.duration,p.completed,p.updated_at
 FROM films f JOIN watch_progress p ON p.film_id=f.id WHERE p.user_id=? AND f.share=? AND f.missing_path=''`+clause, append([]any{owner, sourceShare}, scope...)...)
	if err != nil {
		return err
	}
	defer rows.Close()
	var items []switchFilm
	for rows.Next() {
		var film switchFilm
		if err := rows.Scan(&film.name, &film.title, &film.kind, &film.series, &film.season, &film.episode, &film.year,
			&film.identity, &film.size, &film.modified, &film.position, &film.duration, &film.completed, &film.updatedAt); err != nil {
			return err
		}
		if pair, ok := verified[film.name]; ok && film.identity == pair.Source.Identity && film.size == pair.Source.Size {
			items = append(items, film)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	for _, film := range items {
		pair := verified[film.name]
		if !l.files.MatchSwitchMediaVersion(film.name, pair.Source, film.modified) {
			continue
		}
		entry, err := target.files.VerifySwitchMedia(ctx, film.name, pair.Target)
		if err != nil {
			return err
		}
		if err := target.copySwitchFilm(ctx, targetShare, owner, entry, film); err != nil {
			return err
		}
	}
	return nil
}

func (l *Library) copySwitchFilm(ctx context.Context, share string, owner int64, entry files.Entry, film switchFilm) error {
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO films(share,path,title,kind,series,season,episode,year,size,modified,seen,file_identity)
 VALUES(?,?,?,?,?,?,?,?,?,?,0,?) ON CONFLICT(share,path) DO NOTHING`,
		share, entry.Path, film.title, film.kind, film.series, film.season, film.episode, film.year, entry.Size, entry.Modified.UnixNano(), entry.Identity); err != nil {
		return err
	}
	var id int64
	if err := tx.QueryRowContext(ctx, `SELECT id FROM films WHERE share=? AND path=? AND missing_path='' AND file_identity=? AND size=? AND modified=?`,
		share, entry.Path, entry.Identity, entry.Size, entry.Modified.UnixNano()).Scan(&id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO watch_progress(user_id,film_id,position,duration,completed,updated_at)
 VALUES(?,?,?,?,?,?) ON CONFLICT(user_id,film_id) DO UPDATE SET
 position=excluded.position,duration=excluded.duration,completed=excluded.completed,updated_at=excluded.updated_at
 WHERE excluded.updated_at>watch_progress.updated_at`,
		owner, id, film.position, film.duration, film.completed, film.updatedAt); err != nil {
		return err
	}
	if err := l.files.VerifyScannedMedia(entry); err != nil {
		return err
	}
	return tx.Commit()
}
