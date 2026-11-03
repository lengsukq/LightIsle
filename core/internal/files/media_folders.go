package files

import (
	"errors"
	"io/fs"
)

// Default media folders are real directories inside each verified NAS root.
// Keep these names stable: the Flutter upload routes and media scanners use
// the same layout. Existing media is never moved or renamed automatically.
const (
	MediaPhotosDir = "图库"
	MediaMoviesDir = "影视"
)

// ensureDefaultMediaFolders creates only missing directories. A pre-existing
// file or symbolic link is never overwritten or followed. Callers can keep a
// read-only or conflicting disk mounted while exposing an actionable warning.
func ensureDefaultMediaFolders(store *Store) error {
	for _, name := range []string{MediaPhotosDir, MediaMoviesDir} {
		info, err := store.Stat(name)
		if err == nil {
			if !info.IsDir() {
				return ErrType
			}
			continue
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		if err := store.Mkdir(name); err != nil {
			if !errors.Is(err, fs.ErrExist) {
				return err
			}
			info, err = store.Stat(name)
			if err != nil || !info.IsDir() {
				return ErrType
			}
		}
	}
	return nil
}
