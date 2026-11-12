package gallery

import (
	"database/sql"
	"strings"
	"unicode"
)

const (
	ocrBigramVersion    = 1
	maxOCRTokensPerItem = 256
	maxOCRQueryTokens   = 8
)

func isAlphaNumTokenRune(r rune) bool {
	return unicode.IsLetter(r) && !unicode.Is(unicode.Han, r) || unicode.IsDigit(r) || r == '-' || r == '_'
}

// extractOCRIndexTokens emits normalized non-CJK words (>= 2 runes) and CJK
// 2-character bigrams so substring searches over Chinese and English OCR text
// hit the clustered WITHOUT ROWID index on asset_search_tokens(token, source, asset_id).
func extractOCRIndexTokens(raw string) []string {
	lower := strings.ToLower(strings.TrimSpace(raw))
	if lower == "" {
		return nil
	}
	seen := make(map[string]struct{}, 32)
	out := make([]string, 0, 32)
	add := func(tok string) bool {
		tok = strings.Trim(tok, "-_")
		if len(tok) < 2 || len(tok) > 64 {
			return true
		}
		if _, dup := seen[tok]; !dup {
			seen[tok] = struct{}{}
			out = append(out, tok)
		}
		return len(out) < maxOCRTokensPerItem
	}

	runes := []rune(lower)
	for i := 0; i < len(runes); {
		switch {
		case unicode.Is(unicode.Han, runes[i]):
			start := i
			for i < len(runes) && unicode.Is(unicode.Han, runes[i]) {
				i++
			}
			seg := runes[start:i]
			for j := 0; j+1 < len(seg); j++ {
				if !add(string(seg[j : j+2])) {
					return out
				}
			}
		case isAlphaNumTokenRune(runes[i]):
			start := i
			for i < len(runes) && isAlphaNumTokenRune(runes[i]) {
				i++
			}
			word := string(runes[start:i])
			if !add(word) {
				return out
			}
			if strings.ContainsAny(word, "-_") {
				for _, part := range strings.FieldsFunc(word, func(r rune) bool { return r == '-' || r == '_' }) {
					if !add(part) {
						return out
					}
				}
			}
		default:
			i++
		}
	}
	return out
}

func extractOCRQueryTokens(raw string) []string {
	tokens := extractOCRIndexTokens(raw)
	if len(tokens) > maxOCRQueryTokens {
		return tokens[:maxOCRQueryTokens]
	}
	return tokens
}

func ensureOCRTokenBackfill(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS ai_ocr_ngram_backfill (version INTEGER PRIMARY KEY)`); err != nil {
		return err
	}
	var done int
	if err := db.QueryRow(`SELECT 1 FROM ai_ocr_ngram_backfill WHERE version=?`, ocrBigramVersion).Scan(&done); err == nil && done == 1 {
		return nil
	}
	type ocrRow struct {
		assetID int64
		text    string
	}
	rows, err := db.Query(`SELECT asset_id, raw_text FROM asset_ocr WHERE raw_text<>''`)
	if err != nil {
		return err
	}
	var existing []ocrRow
	for rows.Next() {
		var r ocrRow
		if err := rows.Scan(&r.assetID, &r.text); err != nil {
			rows.Close()
			return err
		}
		existing = append(existing, r)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, r := range existing {
		for _, tok := range extractOCRIndexTokens(r.text) {
			if _, err := tx.Exec(`INSERT OR IGNORE INTO asset_search_tokens(token, source, asset_id, score) VALUES(?, 'ocr', ?, 1.0)`, tok, r.assetID); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(`INSERT OR REPLACE INTO ai_ocr_ngram_backfill(version) VALUES(?)`, ocrBigramVersion); err != nil {
		return err
	}
	return tx.Commit()
}
