package cinema

import (
	"database/sql"
	"path/filepath"
)

func openReadOnlyCinemaPool(dataDir, databaseName string) (*sql.DB, error) {
	rdb, err := sql.Open("sqlite3", "file:"+filepath.Join(dataDir, databaseName)+"?mode=ro&_query_only=1&_busy_timeout=5000&_cache_size=-1024")
	if err != nil {
		return nil, err
	}
	rdb.SetMaxOpenConns(4)
	return rdb, nil
}

func (l *Library) readDB() *sql.DB {
	if l != nil && l.rdb != nil {
		return l.rdb
	}
	if l != nil {
		return l.db
	}
	return nil
}

func (l *Library) closeDatabases() error {
	if l.rdb != nil {
		_ = l.rdb.Close()
	}
	return l.db.Close()
}
