package files

import (
	"context"
	"encoding/hex"
	"errors"
	"path"
	"time"
)

// SwitchMediaPair links the original object to the independently verified copy.
type SwitchMediaPair struct {
	Source StorageSwitchFile
	Target StorageSwitchFile
}

func (m *Manager) VerifySwitchMedia(ctx context.Context, name string, expected StorageSwitchFile) (Entry, error) {
	var entry Entry
	err := m.withRead(func(s *Store) error {
		file, err := s.openFileNoFollow(name)
		if err != nil {
			return err
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || !MediaFileHasSingleLink(info) ||
			MediaFileIdentity(info) != expected.Identity || info.Size() != expected.Size {
			return ErrExists
		}
		digest, err := hashStableFile(ctx, file, info)
		if err != nil || expected.Digest == "" || hex.EncodeToString(digest[:]) != expected.Digest {
			return errors.Join(ErrExists, err)
		}
		entry = Entry{
			Name: path.Base(name), Path: name, Type: "file", Size: info.Size(),
			Modified: info.ModTime(), Identity: expected.Identity, SingleLink: true,
		}
		return nil
	})
	return entry, err
}

func (m *Manager) MatchSwitchMediaVersion(name string, expected StorageSwitchFile, modified int64) bool {
	if expected.Identity == "" {
		return false
	}
	return m.VerifyScannedMedia(Entry{
		Path: name, Identity: expected.Identity, Size: expected.Size, Modified: time.Unix(0, modified),
	}) == nil
}
