package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"path"
	"strings"
	"time"
)

// StorageSwitchAlbumLink is the exact on-disk link that must be handled when
// either end of a shared folder album leaves this physical root. Persist this
// snapshot in the migration task before switching the SQLite bindings, so a
// crash after commit can finish the unlink without guessing at file paths.
type StorageSwitchAlbumLink struct {
	MemberPhotos   string `json:"memberPhotos"`
	LinkName       string `json:"linkName"`
	ExpectedTarget string `json:"expectedTarget"`
}

func (s *Store) StorageSwitchAlbumLinks(userID int64, rootID string, generation uint64) ([]StorageSwitchAlbumLink, error) {
	return storageSwitchAlbumLinksQuery(s.db, userID, rootID, generation)
}

func storageSwitchAlbumLinksQuery(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, userID int64, rootID string, generation uint64) ([]StorageSwitchAlbumLink, error) {
	rows, err := q.Query(`SELECT owner_user_id,album_name,member_user_id,link_name
		FROM shared_folder_albums WHERE root_id=? AND root_generation=?
		AND (owner_user_id=? OR member_user_id=?)
		ORDER BY owner_user_id,album_name,member_user_id,link_name`,
		rootID, int64(generation), userID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var links []StorageSwitchAlbumLink
	for rows.Next() {
		var owner, member int64
		var album, name string
		if err := rows.Scan(&owner, &album, &member, &name); err != nil {
			return nil, err
		}
		if owner <= 0 || member <= 0 || !validFolderAlbumComponent(album) || !validFolderAlbumComponent(name) {
			return nil, ErrStorageLedgerConflict
		}
		links = append(links, StorageSwitchAlbumLink{
			MemberPhotos:   fmt.Sprintf("Users/u%d/photos", member),
			LinkName:       name,
			ExpectedTarget: fmt.Sprintf("../../u%d/photos/%s", owner, album),
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Two database rows must never claim the same filesystem entry with
	// incompatible targets. Refuse instead of unlinking one user's file.
	seen := make(map[string]string, len(links))
	for _, link := range links {
		name := path.Join(link.MemberPhotos, link.LinkName)
		if existing, ok := seen[name]; ok && existing != link.ExpectedTarget {
			return nil, ErrStorageLedgerConflict
		}
		seen[name] = link.ExpectedTarget
	}
	return links, nil
}

type StorageSwitchTask struct {
	ID                string
	Request, Progress []byte
	Committed         bool
}

func (s *Store) LoadStorageSwitchTask(userID int64, id string) (StorageSwitchTask, error) {
	var task StorageSwitchTask
	err := s.db.QueryRow(`SELECT id,request,progress,committed FROM storage_switch_tasks
		WHERE user_id=? AND (?='' OR id=?) ORDER BY created_at DESC,rowid DESC LIMIT 1`, userID, id, id).
		Scan(&task.ID, &task.Request, &task.Progress, &task.Committed)
	if errors.Is(err, sql.ErrNoRows) {
		return task, ErrNotFound
	}
	return task, err
}

func (s *Store) CreateStorageSwitchTask(userID int64, task StorageSwitchTask) error {
	_, err := s.db.Exec(`INSERT INTO storage_switch_tasks(id,user_id,request,progress,created_at) VALUES(?,?,?,?,?)`,
		task.ID, userID, task.Request, task.Progress, time.Now().Unix())
	return err
}

func (s *Store) SaveStorageSwitchTask(id string, progress []byte) error {
	_, err := s.db.Exec("UPDATE storage_switch_tasks SET progress=? WHERE id=?", progress, id)
	return err
}

func (s *Store) ReserveStorageSwitch(id string, req SwitchUserStorageCategoriesRequest, size int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=? AND enabled=1", req.TargetUserID).Scan(&role); err != nil {
		return err
	}
	if role != RoleAdmin && size != 0 {
		quota, err := rootQuotaTx(tx, req.TargetUserID, req.TargetRootID, req.TargetGeneration)
		if err != nil {
			return err
		}
		if req.TargetQuotaBytes != nil {
			quota = *req.TargetQuotaBytes
		}
		used, reserved, err := rootQuotaUsageTx(tx, req.TargetUserID, req.TargetRootID, req.TargetGeneration)
		if err != nil {
			return err
		}
		if used > quota || reserved > quota-used || size > quota-used-reserved {
			return ErrStorageQuotaExceeded
		}
	}
	if _, err := tx.Exec(`INSERT INTO user_storage_reservations
		(id,user_id,root_id,root_generation,relative_path,size_bytes,created_at) VALUES(?,?,?,?,?,?,?)`,
		id, req.TargetUserID, req.TargetRootID, req.TargetGeneration, ".lightisle-switch-"+id, size, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ReleaseStorageSwitch(id string) error {
	_, err := s.db.Exec(`DELETE FROM user_storage_reservations WHERE id=? AND relative_path=? AND upload_id IS NULL`, id, ".lightisle-switch-"+id)
	return err
}

type StorageSwitchShare struct {
	Kind     string `json:"kind"`
	Path     string `json:"path"`
	OwnerID  int64  `json:"ownerID"`
	MemberID int64  `json:"memberID,omitempty"`
}

// StorageSwitchShares reports affected entries without exposing link secrets.
func (s *Store) StorageSwitchShares(req SwitchUserStorageCategoriesRequest) ([]StorageSwitchShare, int, error) {
	if len(req.Categories) == 0 {
		return nil, 0, ErrInput
	}
	values := make([]string, 0, len(req.Categories))
	args := make([]any, 0, len(req.Categories)+8)
	for _, category := range req.Categories {
		values = append(values, "(?,?)")
		args = append(args, fmt.Sprintf("Users/u%d/%s", req.TargetUserID, category), category)
	}
	args = append(args, req.SourceRootID, req.SourceGeneration, time.Now().Unix(),
		req.SourceRootID, req.SourceGeneration, req.TargetUserID, req.TargetUserID)
	rows, err := s.db.Query(`WITH selected(prefix,category) AS (VALUES `+strings.Join(values, ",")+`),
 affected(kind,path,owner_id,member_id) AS (
  SELECT kind,file_path,user_id,0 FROM root_file_shares WHERE root_id=? AND root_generation=? AND expires_at>?
  AND EXISTS(SELECT 1 FROM selected WHERE lower(file_path)=lower(prefix)
   OR substr(lower(file_path),1,length(prefix)+1)=lower(prefix)||'/'
   OR (kind='folder' AND (file_path='.' OR substr(lower(prefix),1,length(file_path)+1)=lower(file_path)||'/')))
  UNION ALL
  SELECT 'album',album_name,owner_user_id,member_user_id FROM shared_folder_albums
  WHERE root_id=? AND root_generation=? AND (owner_user_id=? OR member_user_id=?)
   AND EXISTS(SELECT 1 FROM selected WHERE category='photos'))
 SELECT kind,path,owner_id,member_id,COUNT(*) OVER() FROM affected ORDER BY kind,path,owner_id,member_id LIMIT 50`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var shares []StorageSwitchShare
	var total int
	for rows.Next() {
		var share StorageSwitchShare
		if err := rows.Scan(&share.Kind, &share.Path, &share.OwnerID, &share.MemberID, &total); err != nil {
			return nil, 0, err
		}
		shares = append(shares, share)
	}
	return shares, total, rows.Err()
}
