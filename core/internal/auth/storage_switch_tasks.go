package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

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

func (s *Store) StorageSwitchShareCount(req SwitchUserStorageCategoriesRequest) (int, error) {
	var count int
	for _, category := range req.Categories {
		prefix := fmt.Sprintf("Users/u%d/%s", req.TargetUserID, category)
		var fileShares int
		if err := s.db.QueryRow(`SELECT COUNT(*) FROM root_file_shares WHERE root_id=? AND root_generation=?
			AND (lower(file_path)=lower(?) OR substr(lower(file_path),1,length(?)+1)=lower(?)||'/'
				OR (kind='folder' AND (file_path='.' OR substr(lower(?),1,length(file_path)+1)=lower(file_path)||'/')))`,
			req.SourceRootID, req.SourceGeneration, prefix, prefix, prefix, prefix).Scan(&fileShares); err != nil {
			return 0, err
		}
		count += fileShares
		if category == StoragePhotos {
			var albums int
			if err := s.db.QueryRow(`SELECT COUNT(*) FROM shared_folder_albums WHERE root_id=? AND root_generation=?
				AND (owner_user_id=? OR member_user_id=?)`, req.SourceRootID, req.SourceGeneration, req.TargetUserID, req.TargetUserID).Scan(&albums); err != nil {
				return 0, err
			}
			count += albums
		}
	}
	return count, nil
}
