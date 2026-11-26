package auth

import (
	"math"
	"path"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxFilePinsPerRoot = 100
	maxFilePinLabelLen = 80
)

// FilePin represents a user-pinned folder or starred file bound to a specific
// physical root generation. Callers must re-check real-time read access and
// existence on disk before displaying pins.
type FilePin struct {
	RootID         string `json:"rootId"`
	RootGeneration uint64 `json:"rootGeneration"`
	Path           string `json:"path"`
	Kind           string `json:"kind"`
	Label          string `json:"label"`
	PinnedAt       int64  `json:"pinnedAt"`
}

func validFilePinKind(kind string) bool {
	return kind == "file" || kind == "folder"
}

func (s *Store) ListFilePins(session, rootID string, generation uint64) ([]FilePin, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	rows, err := s.readDB().Query(`
		SELECT relative_path, kind, label, pinned_at
		FROM user_file_pins
		WHERE user_id=? AND root_id=? AND root_generation=?
		ORDER BY pinned_at DESC, relative_path ASC
		LIMIT ?`, user.ID, rootID, int64(generation), MaxFilePinsPerRoot)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]FilePin, 0, 8)
	for rows.Next() {
		var p FilePin
		p.RootID = rootID
		p.RootGeneration = generation
		if err := rows.Scan(&p.Path, &p.Kind, &p.Label, &p.PinnedAt); err != nil {
			return nil, err
		}
		if p.Label == "" {
			p.Label = path.Base(p.Path)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) UpsertFilePin(session, rootID string, generation uint64, relPath, kind, label string) (FilePin, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validGrantPath(relPath) || relPath == "." || !validFilePinKind(kind) {
		return FilePin{}, ErrInput
	}
	cleanLabel := strings.TrimSpace(label)
	if cleanLabel == "" {
		cleanLabel = path.Base(relPath)
	}
	if strings.ContainsRune(cleanLabel, 0) || utf8.RuneCountInString(cleanLabel) > maxFilePinLabelLen {
		return FilePin{}, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return FilePin{}, ErrForbidden
	}
	now := time.Now().Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return FilePin{}, err
	}
	defer tx.Rollback()

	var existing int
	err = tx.QueryRow(`SELECT 1 FROM user_file_pins
		WHERE user_id=? AND root_id=? AND root_generation=? AND relative_path=?`,
		user.ID, rootID, int64(generation), relPath).Scan(&existing)
	if err != nil {
		var count int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM user_file_pins
			WHERE user_id=? AND root_id=? AND root_generation=?`,
			user.ID, rootID, int64(generation)).Scan(&count); err != nil {
			return FilePin{}, err
		}
		if count >= MaxFilePinsPerRoot {
			return FilePin{}, ErrExists
		}
	}
	if _, err := tx.Exec(`INSERT INTO user_file_pins
		(user_id, root_id, root_generation, relative_path, kind, label, pinned_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, root_id, root_generation, relative_path)
		DO UPDATE SET kind=excluded.kind, label=excluded.label, pinned_at=excluded.pinned_at`,
		user.ID, rootID, int64(generation), relPath, kind, cleanLabel, now); err != nil {
		return FilePin{}, err
	}
	if err := tx.Commit(); err != nil {
		return FilePin{}, err
	}
	return FilePin{
		RootID:         rootID,
		RootGeneration: generation,
		Path:           relPath,
		Kind:           kind,
		Label:          cleanLabel,
		PinnedAt:       now,
	}, nil
}

func (s *Store) DeleteFilePin(session, rootID string, generation uint64, relPath string) error {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validGrantPath(relPath) || relPath == "." {
		return ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	_, err := s.db.Exec(`DELETE FROM user_file_pins
		WHERE user_id=? AND root_id=? AND root_generation=? AND relative_path=?`,
		user.ID, rootID, int64(generation), relPath)
	return err
}
