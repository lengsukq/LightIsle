package gallery

import "database/sql"

const aiSchemaVersion = 1

func ensureGalleryAISchema(db *sql.DB) error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS ai_index_state (
			asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
			source_size INTEGER NOT NULL,
			source_modified INTEGER NOT NULL,
			ai_version INTEGER NOT NULL DEFAULT 0,
			status TEXT NOT NULL DEFAULT 'pending',
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS ai_index_state_version ON ai_index_state(ai_version, status)`,
		`CREATE TABLE IF NOT EXISTS asset_ocr (
			asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
			raw_text TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS asset_search_tokens (
			token TEXT NOT NULL,
			source TEXT NOT NULL,
			asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
			score REAL NOT NULL DEFAULT 1.0,
			PRIMARY KEY(token, source, asset_id)
		) WITHOUT ROWID`,
		`CREATE INDEX IF NOT EXISTS asset_search_tokens_by_asset ON asset_search_tokens(asset_id)`,
		`CREATE TABLE IF NOT EXISTS asset_scene_tags (
			asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
			label TEXT NOT NULL,
			confidence REAL NOT NULL,
			PRIMARY KEY(asset_id, label)
		) WITHOUT ROWID`,
		`CREATE TABLE IF NOT EXISTS asset_faces (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
			box_x REAL NOT NULL,
			box_y REAL NOT NULL,
			box_w REAL NOT NULL,
			box_h REAL NOT NULL,
			quality REAL NOT NULL,
			eye_openness REAL NOT NULL DEFAULT 1.0,
			model_version TEXT NOT NULL,
			embedding BLOB NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS asset_faces_by_asset ON asset_faces(asset_id)`,
		`CREATE TABLE IF NOT EXISTS persons (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			share TEXT NOT NULL,
			user_id INTEGER NOT NULL,
			model_version TEXT NOT NULL,
			name TEXT NOT NULL DEFAULT '',
			cover_face_id INTEGER REFERENCES asset_faces(id) ON DELETE SET NULL,
			centroid BLOB NOT NULL,
			face_count INTEGER NOT NULL DEFAULT 0,
			is_hidden INTEGER NOT NULL DEFAULT 0,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS persons_by_user ON persons(share, user_id, is_hidden, face_count DESC, id ASC)`,
		`CREATE TABLE IF NOT EXISTS person_face_links (
			user_id INTEGER NOT NULL,
			face_id INTEGER NOT NULL REFERENCES asset_faces(id) ON DELETE CASCADE,
			person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
			PRIMARY KEY(user_id, face_id)
		) WITHOUT ROWID`,
		`CREATE INDEX IF NOT EXISTS person_face_links_by_person ON person_face_links(person_id, user_id)`,
		`CREATE TABLE IF NOT EXISTS asset_features (
			asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
			feature_print_f16 BLOB NOT NULL,
			sharpness REAL NOT NULL DEFAULT 0,
			aesthetics REAL NOT NULL DEFAULT 0,
			is_utility INTEGER NOT NULL DEFAULT 0
		)`,
	}
	for _, stmt := range statements {
		if _, err := db.Exec(stmt); err != nil {
			return err
		}
	}
	return nil
}
