package gallery

import (
	"context"
	"database/sql"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

type switchPhoto struct {
	kind           string
	size, modified int64
	takenAt        int64
	identity       string
	favorite       bool
	albums         []string
}

// CopySwitchAssociations copies only the space owner's personal records for
// verified source objects. Source records remain available on the old root.
func (l *Library) CopySwitchAssociations(ctx context.Context, target *Library, owner int64, prefix string, verified map[string]files.SwitchMediaPair) error {
	sourceShare, err := l.share()
	if err != nil {
		return err
	}
	targetShare, err := target.share()
	if err != nil {
		return err
	}
	clause, scope, err := mediascope.Clause("a.path", []string{prefix})
	if err != nil {
		return err
	}
	args := append([]any{owner, owner, sourceShare}, scope...)
	rows, err := l.db.QueryContext(ctx, `SELECT a.path,a.type,a.size,a.modified,a.taken_at,a.file_identity,p.user_id IS NOT NULL,pa.name
 FROM assets a LEFT JOIN personal_favorites p ON p.asset_id=a.id AND p.user_id=?
 LEFT JOIN private_album_items i ON i.asset_id=a.id
 LEFT JOIN private_albums pa ON pa.id=i.album_id AND pa.user_id=? AND pa.share=a.share
 WHERE a.share=? AND a.missing_path='' AND (p.user_id IS NOT NULL OR pa.id IS NOT NULL)`+clause, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	items := make(map[string]switchPhoto)
	for rows.Next() {
		var name string
		var album sql.NullString
		var photo switchPhoto
		if err := rows.Scan(&name, &photo.kind, &photo.size, &photo.modified, &photo.takenAt, &photo.identity, &photo.favorite, &album); err != nil {
			return err
		}
		pair, ok := verified[name]
		if !ok || photo.identity != pair.Source.Identity || photo.size != pair.Source.Size {
			continue
		}
		photo.albums = items[name].albums
		if album.Valid {
			photo.albums = append(photo.albums, album.String)
		}
		items[name] = photo
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	for name, photo := range items {
		pair := verified[name]
		if !l.storage.MatchSwitchMediaVersion(name, pair.Source, photo.modified) {
			continue
		}
		entry, err := target.storage.VerifySwitchMedia(ctx, name, pair.Target)
		if err != nil {
			return err
		}
		if err := target.copySwitchPhoto(ctx, targetShare, owner, entry, photo); err != nil {
			return err
		}
	}
	return nil
}

func (l *Library) copySwitchPhoto(ctx context.Context, share string, owner int64, entry files.Entry, photo switchPhoto) error {
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO assets(share,path,type,size,modified,taken_at,file_identity)
 VALUES(?,?,?,?,?,?,?) ON CONFLICT(share,path) DO NOTHING`,
		share, entry.Path, photo.kind, entry.Size, entry.Modified.UnixNano(), photo.takenAt, entry.Identity); err != nil {
		return err
	}
	var id int64
	if err := tx.QueryRowContext(ctx, `SELECT id FROM assets WHERE share=? AND path=? AND missing_path='' AND file_identity=? AND size=? AND modified=?`,
		share, entry.Path, entry.Identity, entry.Size, entry.Modified.UnixNano()).Scan(&id); err != nil {
		return err
	}
	if photo.favorite {
		if _, err := tx.ExecContext(ctx, `INSERT INTO personal_favorites(user_id,asset_id) VALUES(?,?) ON CONFLICT DO NOTHING`, owner, id); err != nil {
			return err
		}
	}
	for _, album := range photo.albums {
		if _, err := tx.ExecContext(ctx, `INSERT INTO private_albums(share,user_id,name)
 SELECT ?,?,? WHERE (SELECT COUNT(*) FROM private_albums WHERE share=? AND user_id=?)<?
 ON CONFLICT DO NOTHING`, share, owner, album, share, owner, maxPrivateAlbumsPerUser); err != nil {
			return err
		}
		var albumID int64
		if err := tx.QueryRowContext(ctx, `SELECT id FROM private_albums WHERE share=? AND user_id=? AND name=?`, share, owner, album).Scan(&albumID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO private_album_items(album_id,asset_id) VALUES(?,?) ON CONFLICT DO NOTHING`, albumID, id); err != nil {
			return err
		}
	}
	if err := l.storage.VerifyScannedMedia(entry); err != nil {
		return err
	}
	return tx.Commit()
}
