package gallery

import (
	"database/sql"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
	"github.com/mattn/go-sqlite3"
)

var (
	ErrAlbumName      = errors.New("invalid_album_name")
	ErrAlbumDuplicate = errors.New("album_name_exists")
)

func normalizeAlbumName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 60 {
		return "", ErrAlbumName
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return "", ErrAlbumName
		}
	}
	return name, nil
}

func albumWriteError(err error) error {
	var sqliteError sqlite3.Error
	if errors.As(err, &sqliteError) && sqliteError.ExtendedCode == sqlite3.ErrConstraintUnique {
		return ErrAlbumDuplicate
	}
	return err
}

func (l *Library) Albums() ([]Album, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	rows, err := l.db.Query(`SELECT al.id,al.name,COUNT(a.id),COALESCE(MAX(a.id),0)
  FROM albums al LEFT JOIN album_items ai ON ai.album_id=al.id
  LEFT JOIN assets a ON a.id=ai.asset_id AND a.share=al.share AND a.missing_path=''
  WHERE al.share=? GROUP BY al.id ORDER BY al.name`, share)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Album{}
	for rows.Next() {
		var a Album
		if err := rows.Scan(&a.ID, &a.Name, &a.Count, &a.CoverAssetID); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (l *Library) AlbumsScoped(roots []string) ([]Album, error) {
	if len(roots) == 1 && roots[0] == "." {
		return l.Albums()
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, args, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	q := `SELECT al.id,al.name,COUNT(a.id),COALESCE(MAX(a.id),0)
	 FROM albums al JOIN album_items ai ON ai.album_id=al.id
	 JOIN assets a ON a.id=ai.asset_id
	 WHERE al.share=? AND a.share=al.share AND a.missing_path=''` + fragment + ` GROUP BY al.id ORDER BY al.name`
	parameters := append([]any{share}, args...)
	rows, err := l.db.Query(q, parameters...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Album{}
	for rows.Next() {
		var item Album
		if err := rows.Scan(&item.ID, &item.Name, &item.Count, &item.CoverAssetID); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (l *Library) CreateAlbum(name string) (Album, error) {
	share, err := l.share()
	if err != nil {
		return Album{}, err
	}
	name, err = normalizeAlbumName(name)
	if err != nil {
		return Album{}, err
	}
	res, err := l.db.Exec("INSERT INTO albums(share,name) VALUES(?,?)", share, name)
	if err != nil {
		return Album{}, albumWriteError(err)
	}
	id, err := res.LastInsertId()
	return Album{ID: id, Name: name, Count: 0}, err
}

func (l *Library) AddToAlbum(albumID, assetID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	var count int
	if err := l.db.QueryRow("SELECT COUNT(*) FROM albums WHERE share=? AND id=?", share, albumID).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	if err := l.db.QueryRow("SELECT COUNT(*) FROM assets WHERE share=? AND id=? AND missing_path=''", share, assetID).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	_, err = l.db.Exec("INSERT OR IGNORE INTO album_items(album_id,asset_id) VALUES(?,?)", albumID, assetID)
	return err
}

// RenameAlbum changes only the current share's album metadata. It never
// renames an original photo or alters its shared favorite flag.
func (l *Library) RenameAlbum(id int64, name string) (Album, error) {
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
	result, err := tx.Exec("UPDATE albums SET name=? WHERE share=? AND id=?", name, share, id)
	if err != nil {
		return Album{}, albumWriteError(err)
	}
	if count, err := result.RowsAffected(); err != nil {
		return Album{}, err
	} else if count == 0 {
		return Album{}, sql.ErrNoRows
	}
	album := Album{ID: id, Name: name}
	if err := tx.QueryRow("SELECT COUNT(*) FROM album_items WHERE album_id=?", id).Scan(&album.Count); err != nil {
		return Album{}, err
	}
	if err := tx.Commit(); err != nil {
		return Album{}, err
	}
	return album, nil
}

// DeleteAlbum deletes the collection and its membership rows through SQLite's
// foreign key cascade. The original files, asset index, and favorites remain.
func (l *Library) DeleteAlbum(id int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	result, err := l.db.Exec("DELETE FROM albums WHERE share=? AND id=?", share, id)
	return albumAffected(result, err)
}

func (l *Library) RemoveFromAlbum(albumID, assetID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	result, err := l.db.Exec(`DELETE FROM album_items WHERE album_id=? AND asset_id=?
		AND EXISTS(SELECT 1 FROM albums WHERE id=? AND share=?)
		AND EXISTS(SELECT 1 FROM assets WHERE id=? AND share=?)`, albumID, assetID, albumID, share, assetID, share)
	return albumAffected(result, err)
}

func albumAffected(result sql.Result, err error) error {
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	return nil
}
