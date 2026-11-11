package auth

import (
	"math"
	"strings"
	"time"
)

// SyncVerifiedRootGeneration advances personal storage bindings, per-root
// quotas, accounted file rows (cascading to file identities), active upload
// reservations, and shared folder albums for an online root whose physical
// VolumeUUID and directory inode/birthtime have been verified by RootRegistry.
//
// Pre-rebind share links in root_file_shares are intentionally left untouched
// so external links issued before an explicit rebind remain invalidated.
func (s *Store) SyncVerifiedRootGeneration(rootID string, currentGeneration uint64) error {
	if !validRootID(rootID) || rootID != strings.ToLower(rootID) ||
		currentGeneration == 0 || currentGeneration > math.MaxInt64 {
		return ErrInput
	}
	if currentGeneration == 1 {
		return nil
	}
	gen := int64(currentGeneration)
	var hasStale bool
	err := s.db.QueryRow(`SELECT EXISTS(
		SELECT 1 FROM user_storage_locations WHERE root_id=? AND root_generation<?
		UNION ALL SELECT 1 FROM user_storage_root_quotas WHERE root_id=? AND root_generation<?
		UNION ALL SELECT 1 FROM user_storage_files WHERE root_id=? AND root_generation<?
		UNION ALL SELECT 1 FROM user_storage_reservations WHERE root_id=? AND root_generation<?
		UNION ALL SELECT 1 FROM shared_folder_albums WHERE root_id=? AND root_generation<?
	)`, rootID, gen, rootID, gen, rootID, gen, rootID, gen, rootID, gen).Scan(&hasStale)
	if err != nil || !hasStale {
		return err
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().Unix()

	if _, err := tx.Exec(`UPDATE user_storage_locations
		SET root_generation=?, updated_at=?
		WHERE root_id=? AND root_generation<?`, gen, now, rootID, gen); err != nil {
		return err
	}

	if _, err := tx.Exec(`INSERT INTO user_storage_root_quotas(user_id,root_id,root_generation,quota_bytes,updated_at)
		SELECT q.user_id, q.root_id, ?, q.quota_bytes, ?
		FROM user_storage_root_quotas q
		WHERE q.root_id=? AND q.root_generation<?
		  AND q.root_generation=(
		    SELECT MAX(q2.root_generation) FROM user_storage_root_quotas q2
		    WHERE q2.user_id=q.user_id AND q2.root_id=q.root_id AND q2.root_generation<?
		  )
		ON CONFLICT(user_id,root_id,root_generation) DO NOTHING`,
		gen, now, rootID, gen, gen); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM user_storage_root_quotas WHERE root_id=? AND root_generation<?`,
		rootID, gen); err != nil {
		return err
	}

	if _, err := tx.Exec(`DELETE FROM user_storage_files
		WHERE root_id=? AND root_generation<?
		  AND EXISTS(
		    SELECT 1 FROM user_storage_files newer
		    WHERE newer.root_id=user_storage_files.root_id
		      AND newer.relative_path=user_storage_files.relative_path
		      AND newer.root_generation>user_storage_files.root_generation
		      AND newer.root_generation<=?
		  )`, rootID, gen, gen); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE user_storage_files
		SET root_generation=?
		WHERE root_id=? AND root_generation<?`, gen, rootID, gen); err != nil {
		return err
	}

	if _, err := tx.Exec(`UPDATE user_storage_reservations
		SET root_generation=?
		WHERE root_id=? AND root_generation<?`, gen, rootID, gen); err != nil {
		return err
	}

	if _, err := tx.Exec(`DELETE FROM shared_folder_albums
		WHERE root_id=? AND root_generation<?
		  AND EXISTS(
		    SELECT 1 FROM shared_folder_albums newer
		    WHERE newer.root_id=shared_folder_albums.root_id
		      AND newer.root_generation>shared_folder_albums.root_generation
		      AND newer.root_generation<=?
		      AND (
		        (newer.owner_user_id=shared_folder_albums.owner_user_id
		          AND newer.album_name=shared_folder_albums.album_name
		          AND newer.member_user_id=shared_folder_albums.member_user_id)
		        OR
		        (newer.member_user_id=shared_folder_albums.member_user_id
		          AND newer.link_name=shared_folder_albums.link_name)
		      )
		  )`, rootID, gen, gen); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE shared_folder_albums
		SET root_generation=?
		WHERE root_id=? AND root_generation<?`, gen, rootID, gen); err != nil {
		return err
	}

	return tx.Commit()
}
