package gallery

import (
	"database/sql"
	"errors"
	"math"
	"strings"
	"time"
)

var ErrInvalidMetadataOverride = errors.New("invalid_metadata_override")

// MetadataOverridePatch carries user-supplied corrections for old or
// EXIF-stripped photos (such as scanned prints or chat-forwarded images).
// Corrections live in the derived SQLite index so original files remain
// untouched on disk while timelines, memories, and the footprint map reflect
// the corrected date and location immediately.
type MetadataOverridePatch struct {
	TakenAt       *int64   `json:"takenAt,omitempty"`
	CapturedAt    *string  `json:"capturedAt,omitempty"`
	Latitude      *float64 `json:"latitude,omitempty"`
	Longitude     *float64 `json:"longitude,omitempty"`
	ClearLocation bool     `json:"clearLocation,omitempty"`
	Reset         bool     `json:"reset,omitempty"`
}

func ensureMetadataOverrideTable(db *sql.DB) error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS asset_metadata_overrides(
		asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
		taken_at INTEGER,
		captured_at TEXT NOT NULL DEFAULT '',
		gps_lat REAL,
		gps_lon REAL,
		clear_location INTEGER NOT NULL DEFAULT 0,
		updated_at INTEGER NOT NULL
	)`)
	return err
}

func validateMetadataOverridePatch(p MetadataOverridePatch) error {
	if p.Reset {
		return nil
	}
	hasDate := p.TakenAt != nil
	hasLoc := p.Latitude != nil || p.Longitude != nil
	if !hasDate && !hasLoc && !p.ClearLocation {
		return ErrInvalidMetadataOverride
	}
	if p.TakenAt != nil && *p.TakenAt <= 0 {
		return ErrInvalidMetadataOverride
	}
	if hasLoc {
		if p.Latitude == nil || p.Longitude == nil {
			return ErrInvalidMetadataOverride
		}
		lat, lon := *p.Latitude, *p.Longitude
		if math.IsNaN(lat) || math.IsInf(lat, 0) || math.IsNaN(lon) || math.IsInf(lon, 0) {
			return ErrInvalidMetadataOverride
		}
		if lat < -90 || lat > 90 || lon < -180 || lon > 180 {
			return ErrInvalidMetadataOverride
		}
	}
	return nil
}

// ApplyMetadataOverrides applies a non-destructive date/location correction (or
// resets overrides back to file EXIF) for up to 100 assets in a single
// transaction.
func (l *Library) ApplyMetadataOverrides(ids []int64, patch MetadataOverridePatch) (int, error) {
	if len(ids) == 0 || len(ids) > 100 {
		return 0, ErrInvalidMetadataOverride
	}
	if err := validateMetadataOverridePatch(patch); err != nil {
		return 0, err
	}
	share, err := l.share()
	if err != nil {
		return 0, err
	}
	now := time.Now().Unix()

	tx, err := l.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	updated := 0
	for _, id := range ids {
		if id <= 0 {
			return 0, ErrInvalidMetadataOverride
		}
		var exists int
		if err := tx.QueryRow("SELECT 1 FROM assets WHERE share=? AND id=? AND missing_path=''", share, id).Scan(&exists); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			return 0, err
		}
		if patch.Reset {
			if _, err := tx.Exec("DELETE FROM asset_metadata_overrides WHERE asset_id=?", id); err != nil {
				return 0, err
			}
			// Mark exif_version=0 so backfillLoop restores file EXIF/mtime cleanly.
			if _, err := tx.Exec("UPDATE assets SET exif_version=0 WHERE share=? AND id=?", share, id); err != nil {
				return 0, err
			}
			updated++
			continue
		}

		// Load existing override so partial edits (e.g. only date or only location)
		// preserve the other corrected field.
		var curTaken sql.NullInt64
		var curCaptured string
		var curLat, curLon sql.NullFloat64
		var curClear int
		_ = tx.QueryRow(
			"SELECT taken_at, captured_at, gps_lat, gps_lon, clear_location FROM asset_metadata_overrides WHERE asset_id=?",
			id,
		).Scan(&curTaken, &curCaptured, &curLat, &curLon, &curClear)

		if patch.TakenAt != nil {
			curTaken = sql.NullInt64{Int64: *patch.TakenAt, Valid: true}
			if patch.CapturedAt != nil && strings.TrimSpace(*patch.CapturedAt) != "" {
				curCaptured = strings.TrimSpace(*patch.CapturedAt)
			} else {
				curCaptured = time.Unix(*patch.TakenAt, 0).UTC().Format(time.RFC3339)
			}
		}
		if patch.ClearLocation {
			curLat = sql.NullFloat64{}
			curLon = sql.NullFloat64{}
			curClear = 1
		} else if patch.Latitude != nil && patch.Longitude != nil {
			curLat = sql.NullFloat64{Float64: *patch.Latitude, Valid: true}
			curLon = sql.NullFloat64{Float64: *patch.Longitude, Valid: true}
			curClear = 0
		}

		if _, err := tx.Exec(`INSERT INTO asset_metadata_overrides(asset_id,taken_at,captured_at,gps_lat,gps_lon,clear_location,updated_at)
			VALUES(?,?,?,?,?,?,?)
			ON CONFLICT(asset_id) DO UPDATE SET
				taken_at=excluded.taken_at,
				captured_at=excluded.captured_at,
				gps_lat=excluded.gps_lat,
				gps_lon=excluded.gps_lon,
				clear_location=excluded.clear_location,
				updated_at=excluded.updated_at`,
			id, curTaken, curCaptured, curLat, curLon, curClear, now); err != nil {
			return 0, err
		}

		if patch.TakenAt != nil {
			if _, err := tx.Exec("UPDATE assets SET taken_at=?, captured_at=? WHERE share=? AND id=?",
				curTaken.Int64, curCaptured, share, id); err != nil {
				return 0, err
			}
		}
		if patch.ClearLocation {
			if _, err := tx.Exec("UPDATE assets SET gps_lat=NULL, gps_lon=NULL WHERE share=? AND id=?", share, id); err != nil {
				return 0, err
			}
		} else if patch.Latitude != nil && patch.Longitude != nil {
			if _, err := tx.Exec("UPDATE assets SET gps_lat=?, gps_lon=? WHERE share=? AND id=?",
				curLat.Float64, curLon.Float64, share, id); err != nil {
				return 0, err
			}
		}
		updated++
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return updated, nil
}
