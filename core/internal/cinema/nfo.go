package cinema

import (
	"database/sql"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"strings"
	"unicode/utf8"
)

const maxNFOBytes = 256 << 10

type nfoDetail struct {
	XMLName xml.Name `xml:""`
	Title   string   `xml:"title"`
	Plot    string   `xml:"plot"`
	Rating  float64  `xml:"rating"`
}

func ensureCinemaMetadataColumns(db *sql.DB) error {
	var fields = []struct{ name, ddl string }{
		{"overview", "TEXT NOT NULL DEFAULT ''"},
		{"rating", "REAL NOT NULL DEFAULT 0"},
		{"metadata_source", "TEXT NOT NULL DEFAULT ''"},
		{"title_source", "TEXT NOT NULL DEFAULT ''"},
		{"year_source", "TEXT NOT NULL DEFAULT ''"},
		{"poster_path", "TEXT NOT NULL DEFAULT ''"},
	}
	rows, err := db.Query("PRAGMA table_info(films)")
	if err != nil {
		return err
	}
	exists := make(map[string]bool)
	for rows.Next() {
		var cid, notnull, primary int
		var name, kind string
		var defaultValue any
		if err = rows.Scan(&cid, &name, &kind, &notnull, &defaultValue, &primary); err != nil {
			break
		}
		exists[name] = true
	}
	if err == nil {
		err = rows.Err()
	}
	if closeErr := rows.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	for _, column := range fields {
		if !exists[column.name] {
			if _, err := db.Exec("ALTER TABLE films ADD COLUMN " + column.name + " " + column.ddl); err != nil {
				return err
			}
		}
	}
	// Beta databases may already contain confirmed metadata. A migration
	// preserves the confirmed title on later automatic filename rescans.
	if _, err := db.Exec(`UPDATE films SET title_source=
		CASE WHEN metadata_source LIKE 'douban-suggest:%' THEN metadata_source
		ELSE 'legacy-confirmed' END
		WHERE manual_title=0 AND title_source='' AND metadata_source<>''`); err != nil {
		return err
	}
	if _, err := db.Exec(`UPDATE films SET title_source='manual'
		WHERE manual_title=1 AND title_source<>'manual'`); err != nil {
		return err
	}
	if _, err := db.Exec(`UPDATE films SET year_source=metadata_source
		WHERE year>0 AND year_source='' AND metadata_source LIKE 'douban-suggest:%'`); err != nil {
		return err
	}
	// Legacy search suggestions were recorded in the rich-metadata field.
	// Retain their per-field provenance, but do not label absent plots,
	// posters or ratings as imported Douban rich metadata.
	if _, err := db.Exec(`UPDATE films SET metadata_source=''
		WHERE metadata_source LIKE 'douban-suggest:%'
		AND overview='' AND rating=0 AND poster_path=''`); err != nil {
		return err
	}
	return nil
}

func parseNFO(source io.Reader) (nfoDetail, error) {
	var detail nfoDetail
	decoder := xml.NewDecoder(io.LimitReader(source, maxNFOBytes+1))
	decoder.Strict = true
	if err := decoder.Decode(&detail); err != nil {
		return detail, ErrInvalid
	}
	if detail.XMLName.Local != "movie" && detail.XMLName.Local != "episodedetails" {
		return nfoDetail{}, ErrInvalid
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return nfoDetail{}, ErrInvalid
	}
	detail.Title = strings.TrimSpace(detail.Title)
	detail.Plot = strings.TrimSpace(detail.Plot)
	if !utf8.ValidString(detail.Title) || !utf8.ValidString(detail.Plot) ||
		len([]rune(detail.Title)) > 150 || len([]rune(detail.Plot)) > 5000 ||
		math.IsNaN(detail.Rating) || math.IsInf(detail.Rating, 0) ||
		detail.Rating < 0 || detail.Rating > 10 || detail.Title == "" {
		return nfoDetail{}, ErrInvalid
	}
	return detail, nil
}

// ImportLocalNFO only reads alongside the film path inside the configured
// shared root. It never fetches remote URLs, executes NFO instructions or
// touches video bytes. Explicit invocation avoids expensive scan I/O.
func (l *Library) ImportLocalNFO(filmID int64) (Film, error) {
	share, err := l.share()
	if err != nil {
		return Film{}, err
	}
	var filmPath string
	if err := l.db.QueryRow("SELECT path FROM films WHERE share=? AND id=?", share, filmID).Scan(&filmPath); err != nil {
		return Film{}, err
	}
	stem := strings.TrimSuffix(filmPath, path.Ext(filmPath))
	candidates := []string{stem + ".nfo"}
	if path.Base(path.Dir(filmPath)) != "." {
		candidates = append(candidates, path.Join(path.Dir(filmPath), "movie.nfo"))
	}
	for _, candidate := range candidates {
		file, info, err := l.files.Read(candidate)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			// Do not silently fall back if the sidecar is a symlink or was
			// rejected by the safe file-handle layer.
			return Film{}, err
		}
		if !info.Mode().IsRegular() || info.Size() > maxNFOBytes || info.Size() < 15 {
			file.Close()
			return Film{}, ErrInvalid
		}
		detail, err := parseNFO(file)
		if closeErr := file.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return Film{}, fmt.Errorf("invalid_nfo: %w", err)
		}
		// A manual title wins. This import never changes paths, files, dates
		// or playback progress. The metadata source remains auditable.
		_, err = l.db.Exec(`UPDATE films
		 SET title=CASE WHEN manual_title=1 THEN title ELSE ? END,
		 title_source=CASE WHEN manual_title=1 THEN title_source ELSE ? END,
		 overview=?, rating=?, metadata_source=?
		 WHERE share=? AND id=? AND path=?`,
			detail.Title, "nfo:"+candidate, detail.Plot, detail.Rating, "nfo:"+candidate, share, filmID, filmPath)
		if err != nil {
			return Film{}, err
		}
		return l.Get(filmID, 0)
	}
	return Film{}, os.ErrNotExist
}
