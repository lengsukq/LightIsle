package backup

import (
	"context"
	"database/sql"
	"net/url"

	_ "github.com/mattn/go-sqlite3"
)

var transientCapabilityTables = []string{"sessions", "file_shares", "root_file_shares"}

// clearTransientCapabilities is only used on a private backup/activation
// copy. The live account database is never opened writable by this helper.
func clearTransientCapabilities(ctx context.Context, file string) error {
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	db, err := sql.Open("sqlite3", uri+"?_journal_mode=DELETE&_busy_timeout=1000")
	if err != nil {
		return err
	}
	db.SetMaxOpenConns(1)
	defer db.Close()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, table := range transientCapabilityTables {
		var exists int
		if err := tx.QueryRowContext(ctx,
			"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			if _, err := tx.ExecContext(ctx, "DELETE FROM "+table); err != nil {
				return err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if err := db.Close(); err != nil {
		return err
	}
	if err := checkSQLiteContext(ctx, file, ""); err != nil {
		return err
	}
	return nil
}
