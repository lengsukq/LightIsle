package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

// ComputerFolder binds an explicit grant to a directory object on a volume.
type ComputerFolder struct {
	Path     string `json:"path"`
	Identity string `json:"identity"`
}

type ComputerFileGrant struct {
	Mode     string           `json:"mode"`
	Folders  []ComputerFolder `json:"folders"`
	Revision int64            `json:"-"`
}

// ComputerFilesEnabled fails closed when the setting is absent or unreadable.
func (s *Store) ComputerFilesEnabled() bool {
	enabled, _ := s.ComputerFilesState()
	return enabled
}

func (s *Store) ComputerFilesState() (bool, int64) {
	var enabled int
	var revision int64
	if s == nil || s.readDB().QueryRow(`SELECT enabled,revision FROM computer_file_settings WHERE id=1`).Scan(&enabled, &revision) != nil {
		return false, 0
	}
	return enabled == 1, revision
}

// SetComputerFilesEnabled is only called by the Mac app's private IPC path.
func (s *Store) SetComputerFilesEnabled(enabled bool) error {
	value := 0
	if enabled {
		value = 1
	}
	_, err := s.db.Exec(`INSERT INTO computer_file_settings(id,enabled) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled, revision=computer_file_settings.revision+1`, value)
	if err == nil {
		s.bumpAccessEpoch()
	}
	return err
}

func (s *Store) ComputerFileGrant(userID int64) (ComputerFileGrant, error) {
	g := ComputerFileGrant{Mode: "none", Folders: []ComputerFolder{}}
	var data string
	err := s.readDB().QueryRow(`SELECT mode,folders,revision FROM computer_file_grants WHERE user_id=?`, userID).Scan(&g.Mode, &data, &g.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return g, nil
	}
	if err != nil {
		return g, err
	}
	if err = json.Unmarshal([]byte(data), &g.Folders); err != nil {
		return ComputerFileGrant{}, err
	}
	return g, nil
}

// SetComputerFileGrant revalidates the administrator session in the write.
func (s *Store) SetComputerFileGrant(actorToken string, userID int64, grant ComputerFileGrant) error {
	if grant.Mode != "none" && grant.Mode != "all" && grant.Mode != "folders" {
		return ErrInput
	}
	if grant.Mode == "folders" && (len(grant.Folders) == 0 || len(grant.Folders) > 32) {
		return ErrInput
	}
	if grant.Mode != "folders" {
		grant.Folders = []ComputerFolder{}
	}
	data, err := json.Marshal(grant.Folders)
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(actorToken))
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var allowed int
	err = tx.QueryRow(`SELECT 1 FROM sessions ss JOIN users a ON a.id=ss.user_id JOIN users u ON u.id=? WHERE ss.id=? AND ss.expires_at>? AND a.enabled=1 AND a.role='admin' AND u.role='member'`, userID, digest[:], time.Now().Unix()).Scan(&allowed)
	if err != nil {
		return ErrForbidden
	}
	_, err = tx.Exec(`INSERT INTO computer_file_grants(user_id,mode,folders) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET mode=excluded.mode,folders=excluded.folders,revision=computer_file_grants.revision+1`, userID, grant.Mode, string(data))
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.bumpAccessEpoch()
	return nil
}
