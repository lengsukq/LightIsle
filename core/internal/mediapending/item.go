// Package mediapending contains the shared, path-scoped representation of
// missing media whose user-created data is retained for its owner.
package mediapending

import (
	"database/sql"
	"errors"
)

// RequireOne fails a scan if its database snapshot changed before an
// association was updated, instead of silently attaching stale metadata.
func RequireOne(result sql.Result, err error) error {
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count != 1 {
		return errors.New("media_record_changed_during_scan")
	}
	return nil
}

var (
	ErrTargetUnavailable = errors.New("missing_media_target_unavailable")
	ErrConflict          = errors.New("missing_media_metadata_conflict")
)

type Item struct {
	ID        int64    `json:"id"`
	Path      string   `json:"path"`
	Reason    string   `json:"reason"`
	Data      []string `json:"data"`
	CanManage bool     `json:"canManage"`
}
