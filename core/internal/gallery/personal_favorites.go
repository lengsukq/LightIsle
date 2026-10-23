package gallery

import "database/sql"

// PersonalFavorite is independent of the shared Favorite. HTTP handlers
// check the actual asset's READ authorization before calling this method.
func (l *Library) PersonalFavorite(userID, assetID int64, on bool) error {
	if userID <= 0 || assetID <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var present int
	if err := tx.QueryRow("SELECT 1 FROM assets WHERE share=? AND id=?", share, assetID).Scan(&present); err != nil {
		return err
	}
	if on {
		_, err = tx.Exec("INSERT INTO personal_favorites(user_id,asset_id) VALUES(?,?) ON CONFLICT DO NOTHING", userID, assetID)
	} else {
		_, err = tx.Exec("DELETE FROM personal_favorites WHERE user_id=? AND asset_id=?", userID, assetID)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}
