package gallery

import (
	"database/sql"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

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
