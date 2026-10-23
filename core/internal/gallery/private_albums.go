package gallery

import (
	"database/sql"
	"errors"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// Private albums are separate from existing family albums. No automatic
// migration is performed: all old albums remain shared and admin-managed.
const maxPrivateAlbumsPerUser = 100

func (l *Library) PrivateAlbumsScoped(userID int64, roots []string) ([]Album, error) {
	if userID <= 0 {
		return nil, sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	clause, args, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	rows, err := l.db.Query(`SELECT pa.id,pa.name,
  (SELECT COUNT(*) FROM private_album_items pai
   JOIN assets a ON a.id=pai.asset_id AND a.share=pa.share
   WHERE pai.album_id=pa.id`+clause+`) AS visible_count
  FROM private_albums pa WHERE pa.share=? AND pa.user_id=?
  ORDER BY pa.name COLLATE NOCASE,pa.id`, append(args, share, userID)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Album{}
	for rows.Next() {
		var album Album
		if err := rows.Scan(&album.ID, &album.Name, &album.Count); err != nil {
			return nil, err
		}
		result = append(result, album)
	}
	return result, rows.Err()
}

func (l *Library) CreatePrivateAlbum(userID int64, name string) (Album, error) {
	if userID <= 0 {
		return Album{}, sql.ErrNoRows
	}
	name, err := normalizeAlbumName(name)
	if err != nil {
		return Album{}, err
	}
	share, err := l.share()
	if err != nil {
		return Album{}, err
	}
	tx, err := l.db.Begin()
	if err != nil {
		return Album{}, err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRow("SELECT COUNT(*) FROM private_albums WHERE share=? AND user_id=?", share, userID).Scan(&count); err != nil {
		return Album{}, err
	}
	if count >= maxPrivateAlbumsPerUser {
		return Album{}, ErrPrivateAlbumLimit
	}
	result, err := tx.Exec("INSERT INTO private_albums(share,user_id,name) VALUES(?,?,?)", share, userID, name)
	if err != nil {
		return Album{}, albumWriteError(err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		return Album{}, err
	}
	if err := tx.Commit(); err != nil {
		return Album{}, err
	}
	return Album{ID: id, Name: name}, nil
}

var ErrPrivateAlbumLimit = errors.New("private_album_limit")

func (l *Library) RenamePrivateAlbum(userID, id int64, name string) (Album, error) {
	if userID <= 0 || id <= 0 {
		return Album{}, sql.ErrNoRows
	}
	name, err := normalizeAlbumName(name)
	if err != nil {
		return Album{}, err
	}
	share, err := l.share()
	if err != nil {
		return Album{}, err
	}
	result, err := l.db.Exec("UPDATE private_albums SET name=? WHERE share=? AND user_id=? AND id=?", name, share, userID, id)
	if err := albumAffected(result, albumWriteError(err)); err != nil {
		return Album{}, err
	}
	return Album{ID: id, Name: name}, nil
}

func (l *Library) DeletePrivateAlbum(userID, id int64) error {
	if userID <= 0 || id <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	result, err := l.db.Exec("DELETE FROM private_albums WHERE share=? AND user_id=? AND id=?", share, userID, id)
	return albumAffected(result, err)
}

func (l *Library) AddToPrivateAlbum(userID, id, assetID int64) error {
	if userID <= 0 || id <= 0 || assetID <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	// Atomic guards prevent a stale album or different-share asset from being
	// attached. The HTTP layer additionally checks the user's read grant.
	result, err := l.db.Exec(`INSERT INTO private_album_items(album_id,asset_id)
 SELECT pa.id,a.id FROM private_albums pa,assets a
 WHERE pa.id=? AND pa.user_id=? AND pa.share=? AND a.id=? AND a.share=pa.share
 ON CONFLICT(album_id,asset_id) DO NOTHING`, id, userID, share, assetID)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		var exists int
		if err := l.db.QueryRow(`SELECT 1 FROM private_albums pa JOIN private_album_items pai ON pai.album_id=pa.id
    JOIN assets a ON a.id=pai.asset_id AND a.share=pa.share
    WHERE pa.id=? AND pa.user_id=? AND pa.share=? AND pai.asset_id=?`, id, userID, share, assetID).Scan(&exists); err != nil {
			return sql.ErrNoRows
		}
	}
	return nil
}

func (l *Library) RemoveFromPrivateAlbum(userID, id, assetID int64) error {
	if userID <= 0 || id <= 0 || assetID <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	result, err := l.db.Exec(`DELETE FROM private_album_items WHERE album_id=? AND asset_id=?
 AND EXISTS(SELECT 1 FROM private_albums WHERE id=? AND user_id=? AND share=?)
 AND EXISTS(SELECT 1 FROM assets WHERE id=? AND share=?)`,
		id, assetID, id, userID, share, assetID, share)
	return albumAffected(result, err)
}
