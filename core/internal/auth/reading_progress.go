package auth

import (
	"database/sql"
	"errors"
	"math"
	"strings"
	"time"
)

const (
	maxReadingLocatorBytes = 512
	maxReadingProgressList = 100
)

// ReadingProgress stores cross-device reading position for an EPUB, comic
// archive (.cbz/.zip), Markdown, or text document bound to a physical root
// generation.
type ReadingProgress struct {
	RootID         string  `json:"rootId"`
	RootGeneration uint64  `json:"rootGeneration"`
	Path           string  `json:"path"`
	Locator        string  `json:"locator"`
	Percent        float64 `json:"percent"`
	UpdatedAt      int64   `json:"updatedAt"`
}

func (s *Store) GetReadingProgress(session, rootID string, generation uint64, relPath string) (ReadingProgress, bool, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validGrantPath(relPath) || relPath == "." {
		return ReadingProgress{}, false, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return ReadingProgress{}, false, ErrForbidden
	}
	var item ReadingProgress
	item.RootID = rootID
	item.RootGeneration = generation
	item.Path = relPath
	err := s.readDB().QueryRow(`
		SELECT locator, percent, updated_at
		FROM user_reading_progress
		WHERE user_id=? AND root_id=? AND root_generation=? AND relative_path=?`,
		user.ID, rootID, int64(generation), relPath).
		Scan(&item.Locator, &item.Percent, &item.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ReadingProgress{}, false, nil
	}
	if err != nil {
		return ReadingProgress{}, false, err
	}
	return item, true, nil
}

func (s *Store) ListReadingProgress(session, rootID string, generation uint64, limit int) ([]ReadingProgress, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if limit <= 0 || limit > maxReadingProgressList {
		limit = 50
	}
	rows, err := s.readDB().Query(`
		SELECT relative_path, locator, percent, updated_at
		FROM user_reading_progress
		WHERE user_id=? AND root_id=? AND root_generation=?
		ORDER BY updated_at DESC, relative_path ASC
		LIMIT ?`, user.ID, rootID, int64(generation), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ReadingProgress, 0, 8)
	for rows.Next() {
		var item ReadingProgress
		item.RootID = rootID
		item.RootGeneration = generation
		if err := rows.Scan(&item.Path, &item.Locator, &item.Percent, &item.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) UpsertReadingProgress(session, rootID string, generation uint64, relPath, locator string, percent float64) (ReadingProgress, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validGrantPath(relPath) || relPath == "." {
		return ReadingProgress{}, ErrInput
	}
	if len(locator) > maxReadingLocatorBytes || strings.ContainsRune(locator, 0) {
		return ReadingProgress{}, ErrInput
	}
	if math.IsNaN(percent) || math.IsInf(percent, 0) || percent < 0 || percent > 100 {
		return ReadingProgress{}, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return ReadingProgress{}, ErrForbidden
	}
	now := time.Now().Unix()
	if _, err := s.db.Exec(`
		INSERT INTO user_reading_progress
			(user_id, root_id, root_generation, relative_path, locator, percent, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, root_id, root_generation, relative_path)
		DO UPDATE SET locator=excluded.locator, percent=excluded.percent, updated_at=excluded.updated_at`,
		user.ID, rootID, int64(generation), relPath, locator, percent, now); err != nil {
		return ReadingProgress{}, err
	}
	return ReadingProgress{
		RootID:         rootID,
		RootGeneration: generation,
		Path:           relPath,
		Locator:        locator,
		Percent:        percent,
		UpdatedAt:      now,
	}, nil
}
