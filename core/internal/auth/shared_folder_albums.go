package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"math"
	"path"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// SharedFolderAlbum represents a controlled symlink share of an owner's folder
// album (Users/u<owner>/photos/<albumName>) with another family member on the
// same physical root and generation.
type SharedFolderAlbum struct {
	ID             int64  `json:"id"`
	RootID         string `json:"rootId"`
	RootGeneration uint64 `json:"rootGeneration"`
	OwnerUserID    int64  `json:"ownerUserId"`
	OwnerUsername  string `json:"ownerUsername"`
	OwnerPath      string `json:"ownerPath"`
	AlbumName      string `json:"albumName"`
	MemberUserID   int64  `json:"memberUserId"`
	MemberUsername string `json:"memberUsername"`
	MemberPhotos   string `json:"-"`
	LinkName       string `json:"linkName"`
	CanWrite       bool   `json:"canWrite"`
	CreatedAt      int64  `json:"createdAt"`
}

// FolderAlbumShareTarget describes a family member who has personal photo
// storage assigned on the same physical root and generation.
type FolderAlbumShareTarget struct {
	UserID   int64  `json:"userId"`
	Username string `json:"username"`
}

func validFolderAlbumComponent(raw string) bool {
	name := strings.TrimSpace(raw)
	if name != raw || !utf8.ValidString(name) || len([]rune(name)) < 1 || len([]rune(name)) > 80 ||
		name == "." || name == ".." || strings.ContainsAny(name, "/\\\x00") ||
		strings.HasPrefix(strings.ToLower(name), ".lightisle-") {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// FolderAlbumShareTargets returns other enabled users who have personal photo
// storage assigned on the same (rootID, generation).
func (s *Store) FolderAlbumShareTargets(session, rootID string, generation uint64) ([]FolderAlbumShareTarget, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 {
		return nil, ErrInput
	}
	rows, err := s.db.Query(`SELECT u.id, u.username
		FROM users u
		JOIN user_storage_locations l ON l.user_id = u.id
		WHERE u.enabled = 1 AND u.id != ?
		  AND l.root_id = ? AND l.root_generation = ? AND l.category = ?
		ORDER BY u.username`,
		actor.ID, rootID, int64(generation), StoragePhotos)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	targets := make([]FolderAlbumShareTarget, 0)
	for rows.Next() {
		var t FolderAlbumShareTarget
		if err := rows.Scan(&t.UserID, &t.Username); err != nil {
			return nil, err
		}
		targets = append(targets, t)
	}
	return targets, rows.Err()
}

// InspectFolderAlbumShareTarget verifies that both the caller and target member
// have personal photo storage on (rootID, generation) and returns their photo
// root paths plus any existing link_name for idempotent updates.
func (s *Store) InspectFolderAlbumShareTarget(session, rootID string, generation uint64, albumName string, memberUserID int64) (ownerPhotos, memberPhotos, ownerUsername, existingLink string, err error) {
	actor, ok := s.Identity(session)
	if !ok {
		return "", "", "", "", ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validFolderAlbumComponent(albumName) || memberUserID <= 0 || memberUserID == actor.ID {
		return "", "", "", "", ErrInput
	}
	err = s.db.QueryRow(`SELECT relative_path FROM user_storage_locations
		WHERE user_id=? AND root_id=? AND root_generation=? AND category=?`,
		actor.ID, rootID, int64(generation), StoragePhotos).Scan(&ownerPhotos)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", "", ErrStorageUnassigned
	}
	if err != nil {
		return "", "", "", "", err
	}
	var memberEnabled int
	err = s.db.QueryRow(`SELECT u.enabled, l.relative_path
		FROM users u JOIN user_storage_locations l ON l.user_id = u.id
		WHERE u.id=? AND l.root_id=? AND l.root_generation=? AND l.category=?`,
		memberUserID, rootID, int64(generation), StoragePhotos).Scan(&memberEnabled, &memberPhotos)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", "", ErrStorageUnassigned
	}
	if err != nil {
		return "", "", "", "", err
	}
	if memberEnabled != 1 {
		return "", "", "", "", ErrForbidden
	}
	_ = s.db.QueryRow(`SELECT link_name FROM shared_folder_albums
		WHERE root_id=? AND root_generation=? AND owner_user_id=? AND album_name=? AND member_user_id=?`,
		rootID, int64(generation), actor.ID, albumName, memberUserID).Scan(&existingLink)
	return ownerPhotos, memberPhotos, actor.Username, existingLink, nil
}

// ShareFolderAlbum records or updates a controlled symlink folder album share.
func (s *Store) ShareFolderAlbum(session, rootID string, generation uint64, albumName, linkName string, memberUserID int64, canWrite bool) (SharedFolderAlbum, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return SharedFolderAlbum{}, ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validFolderAlbumComponent(albumName) || !validFolderAlbumComponent(linkName) ||
		memberUserID <= 0 || memberUserID == actor.ID {
		return SharedFolderAlbum{}, ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return SharedFolderAlbum{}, err
	}
	defer tx.Rollback()
	var ownerPhotos string
	err = tx.QueryRow(`SELECT relative_path FROM user_storage_locations
		WHERE user_id=? AND root_id=? AND root_generation=? AND category=?`,
		actor.ID, rootID, int64(generation), StoragePhotos).Scan(&ownerPhotos)
	if errors.Is(err, sql.ErrNoRows) {
		return SharedFolderAlbum{}, ErrStorageUnassigned
	}
	if err != nil {
		return SharedFolderAlbum{}, err
	}
	var memberUsername, memberPhotos string
	var memberEnabled int
	err = tx.QueryRow(`SELECT u.username, u.enabled, l.relative_path
		FROM users u JOIN user_storage_locations l ON l.user_id = u.id
		WHERE u.id=? AND l.root_id=? AND l.root_generation=? AND l.category=?`,
		memberUserID, rootID, int64(generation), StoragePhotos).Scan(&memberUsername, &memberEnabled, &memberPhotos)
	if errors.Is(err, sql.ErrNoRows) {
		return SharedFolderAlbum{}, ErrStorageUnassigned
	}
	if err != nil {
		return SharedFolderAlbum{}, err
	}
	if memberEnabled != 1 {
		return SharedFolderAlbum{}, ErrForbidden
	}
	writeInt := 0
	if canWrite {
		writeInt = 1
	}
	now := time.Now().Unix()
	if _, err := tx.Exec(`INSERT INTO shared_folder_albums(
			root_id, root_generation, owner_user_id, album_name, member_user_id, link_name, can_write, created_at
		) VALUES(?,?,?,?,?,?,?,?)
		ON CONFLICT(root_id, root_generation, owner_user_id, album_name, member_user_id)
		DO UPDATE SET can_write=excluded.can_write, link_name=excluded.link_name`,
		rootID, int64(generation), actor.ID, albumName, memberUserID, linkName, writeInt, now); err != nil {
		return SharedFolderAlbum{}, err
	}
	var item SharedFolderAlbum
	var createdAt int64
	if err := tx.QueryRow(`SELECT id, link_name, can_write, created_at FROM shared_folder_albums
		WHERE root_id=? AND root_generation=? AND owner_user_id=? AND album_name=? AND member_user_id=?`,
		rootID, int64(generation), actor.ID, albumName, memberUserID).Scan(&item.ID, &item.LinkName, &writeInt, &createdAt); err != nil {
		return SharedFolderAlbum{}, err
	}
	if err := tx.Commit(); err != nil {
		return SharedFolderAlbum{}, err
	}
	item.RootID = rootID
	item.RootGeneration = generation
	item.OwnerUserID = actor.ID
	item.OwnerUsername = actor.Username
	item.OwnerPath = path.Join(ownerPhotos, albumName)
	item.AlbumName = albumName
	item.MemberUserID = memberUserID
	item.MemberUsername = memberUsername
	item.MemberPhotos = memberPhotos
	item.CanWrite = writeInt == 1
	item.CreatedAt = createdAt
	return item, nil
}

// UnshareFolderAlbum removes a folder album share. The owner, the recipient
// member, or an administrator may remove the share.
func (s *Store) UnshareFolderAlbum(session, rootID string, generation uint64, ownerUserID int64, albumName string, memberUserID int64) (SharedFolderAlbum, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return SharedFolderAlbum{}, ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		!validFolderAlbumComponent(albumName) || ownerUserID <= 0 || memberUserID <= 0 {
		return SharedFolderAlbum{}, ErrInput
	}
	if actor.Role != RoleAdmin && actor.ID != ownerUserID && actor.ID != memberUserID {
		return SharedFolderAlbum{}, ErrForbidden
	}
	tx, err := s.db.Begin()
	if err != nil {
		return SharedFolderAlbum{}, err
	}
	defer tx.Rollback()
	var item SharedFolderAlbum
	var writeInt int
	err = tx.QueryRow(`SELECT s.id, s.link_name, s.can_write, s.created_at,
			COALESCE(ml.relative_path, '')
		FROM shared_folder_albums s
		LEFT JOIN user_storage_locations ml
		  ON ml.user_id = s.member_user_id AND ml.root_id = s.root_id
		 AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id=? AND s.root_generation=? AND s.owner_user_id=? AND s.album_name=? AND s.member_user_id=?`,
		StoragePhotos, rootID, int64(generation), ownerUserID, albumName, memberUserID).
		Scan(&item.ID, &item.LinkName, &writeInt, &item.CreatedAt, &item.MemberPhotos)
	if errors.Is(err, sql.ErrNoRows) {
		return SharedFolderAlbum{}, ErrNotFound
	}
	if err != nil {
		return SharedFolderAlbum{}, err
	}
	if _, err := tx.Exec(`DELETE FROM shared_folder_albums WHERE id=?`, item.ID); err != nil {
		return SharedFolderAlbum{}, err
	}
	if err := tx.Commit(); err != nil {
		return SharedFolderAlbum{}, err
	}
	item.RootID = rootID
	item.RootGeneration = generation
	item.OwnerUserID = ownerUserID
	item.AlbumName = albumName
	item.MemberUserID = memberUserID
	item.CanWrite = writeInt == 1
	return item, nil
}

// ListOwnedFolderAlbumShares returns all active shares for folder albums owned
// by the caller on (rootID, generation), keyed by albumName.
func (s *Store) ListOwnedFolderAlbumShares(session, rootID string, generation uint64) (map[string][]SharedFolderAlbum, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 {
		return nil, ErrInput
	}
	rows, err := s.db.Query(`SELECT s.id, s.album_name, s.member_user_id, mu.username,
			ml.relative_path, s.link_name, s.can_write, s.created_at, ol.relative_path
		FROM shared_folder_albums s
		JOIN users mu ON mu.id = s.member_user_id AND mu.enabled = 1
		JOIN user_storage_locations ol ON ol.user_id = s.owner_user_id
		  AND ol.root_id = s.root_id AND ol.root_generation = s.root_generation AND ol.category = ?
		JOIN user_storage_locations ml ON ml.user_id = s.member_user_id
		  AND ml.root_id = s.root_id AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id = ? AND s.root_generation = ? AND s.owner_user_id = ?
		ORDER BY s.album_name, mu.username`,
		StoragePhotos, StoragePhotos, rootID, int64(generation), actor.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string][]SharedFolderAlbum)
	for rows.Next() {
		var item SharedFolderAlbum
		var writeInt int
		var ownerPhotos string
		if err := rows.Scan(&item.ID, &item.AlbumName, &item.MemberUserID, &item.MemberUsername,
			&item.MemberPhotos, &item.LinkName, &writeInt, &item.CreatedAt, &ownerPhotos); err != nil {
			return nil, err
		}
		item.RootID = rootID
		item.RootGeneration = generation
		item.OwnerUserID = actor.ID
		item.OwnerUsername = actor.Username
		item.OwnerPath = path.Join(ownerPhotos, item.AlbumName)
		item.CanWrite = writeInt == 1
		out[item.AlbumName] = append(out[item.AlbumName], item)
	}
	return out, rows.Err()
}

// ListReceivedFolderAlbums returns all active folder albums shared with the
// caller on (rootID, generation).
func (s *Store) ListReceivedFolderAlbums(session, rootID string, generation uint64) ([]SharedFolderAlbum, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 {
		return nil, ErrInput
	}
	rows, err := s.db.Query(`SELECT s.id, s.owner_user_id, ou.username, ol.relative_path,
			s.album_name, ml.relative_path, s.link_name, s.can_write, s.created_at
		FROM shared_folder_albums s
		JOIN users ou ON ou.id = s.owner_user_id AND ou.enabled = 1
		JOIN user_storage_locations ol ON ol.user_id = s.owner_user_id
		  AND ol.root_id = s.root_id AND ol.root_generation = s.root_generation AND ol.category = ?
		JOIN user_storage_locations ml ON ml.user_id = s.member_user_id
		  AND ml.root_id = s.root_id AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id = ? AND s.root_generation = ? AND s.member_user_id = ?
		ORDER BY s.album_name, ou.username`,
		StoragePhotos, StoragePhotos, rootID, int64(generation), actor.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]SharedFolderAlbum, 0)
	for rows.Next() {
		var item SharedFolderAlbum
		var writeInt int
		var ownerPhotos string
		if err := rows.Scan(&item.ID, &item.OwnerUserID, &item.OwnerUsername, &ownerPhotos,
			&item.AlbumName, &item.MemberPhotos, &item.LinkName, &writeInt, &item.CreatedAt); err != nil {
			return nil, err
		}
		item.RootID = rootID
		item.RootGeneration = generation
		item.OwnerPath = path.Join(ownerPhotos, item.AlbumName)
		item.MemberUserID = actor.ID
		item.MemberUsername = actor.Username
		item.CanWrite = writeInt == 1
		out = append(out, item)
	}
	return out, rows.Err()
}

// hasSharedFolderAlbumAccess checks whether userID is granted access to relative
// via an active shared_folder_albums record on rootID.
func (s *Store) hasSharedFolderAlbumAccess(userID int64, rootID, relative string, write bool) bool {
	if !isPersonalHomePath(relative) {
		return false
	}
	rows, err := s.db.Query(`SELECT ol.relative_path, s.album_name, s.can_write
		FROM shared_folder_albums s
		JOIN users ou ON ou.id = s.owner_user_id AND ou.enabled = 1
		JOIN user_storage_locations ol ON ol.user_id = s.owner_user_id
		  AND ol.root_id = s.root_id AND ol.root_generation = s.root_generation AND ol.category = ?
		JOIN user_storage_locations ml ON ml.user_id = s.member_user_id
		  AND ml.root_id = s.root_id AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id = ? AND s.member_user_id = ?`,
		StoragePhotos, StoragePhotos, rootID, userID)
	if err != nil {
		return false
	}
	defer rows.Close()
	for rows.Next() {
		var ownerPhotos, albumName string
		var canWrite int
		if err := rows.Scan(&ownerPhotos, &albumName, &canWrite); err != nil {
			return false
		}
		albumPath := path.Join(ownerPhotos, albumName)
		if (relative == albumPath || strings.HasPrefix(relative, albumPath+"/")) && (!write || canWrite == 1) {
			return true
		}
	}
	return false
}

// sharedFolderAlbumSearchRoots returns active shared folder album subtrees on
// rootID that intersect with base.
func (s *Store) sharedFolderAlbumSearchRoots(userID int64, rootID, base string) ([]string, error) {
	rows, err := s.db.Query(`SELECT ol.relative_path, s.album_name
		FROM shared_folder_albums s
		JOIN users ou ON ou.id = s.owner_user_id AND ou.enabled = 1
		JOIN user_storage_locations ol ON ol.user_id = s.owner_user_id
		  AND ol.root_id = s.root_id AND ol.root_generation = s.root_generation AND ol.category = ?
		JOIN user_storage_locations ml ON ml.user_id = s.member_user_id
		  AND ml.root_id = s.root_id AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id = ? AND s.member_user_id = ?`,
		StoragePhotos, StoragePhotos, rootID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var ownerPhotos, albumName string
		if err := rows.Scan(&ownerPhotos, &albumName); err != nil {
			return nil, err
		}
		albumPath := path.Join(ownerPhotos, albumName)
		if albumPath == base || strings.HasPrefix(base, albumPath+"/") {
			out = append(out, base)
		} else if base == "." || strings.HasPrefix(albumPath, base+"/") {
			out = append(out, albumPath)
		}
	}
	return out, rows.Err()
}

// canMemberWriteSharedFolderAlbumTx checks whether actorID may write a file
// inside ownerID's shared folder album on (rootID, generation). Writes inside
// a shared folder album continue to charge ownerID's quota on that root.
func canMemberWriteSharedFolderAlbumTx(tx *sql.Tx, actorID int64, rootID string, generation uint64, ownerID int64, relativePath string) bool {
	if actorID <= 0 || ownerID <= 0 || actorID == ownerID {
		return false
	}
	prefix := fmt.Sprintf("Users/u%d/photos/", ownerID)
	if !strings.HasPrefix(relativePath, prefix) {
		return false
	}
	rest := strings.TrimPrefix(relativePath, prefix)
	slash := strings.IndexByte(rest, '/')
	if slash <= 0 {
		// Direct writes to Users/u<owner>/photos/<file> are not inside an album.
		return false
	}
	albumName := rest[:slash]
	var exists int
	err := tx.QueryRow(`SELECT 1 FROM shared_folder_albums s
		JOIN users ou ON ou.id = s.owner_user_id AND ou.enabled = 1
		JOIN users mu ON mu.id = s.member_user_id AND mu.enabled = 1
		JOIN user_storage_locations ol ON ol.user_id = s.owner_user_id
		  AND ol.root_id = s.root_id AND ol.root_generation = s.root_generation AND ol.category = ?
		JOIN user_storage_locations ml ON ml.user_id = s.member_user_id
		  AND ml.root_id = s.root_id AND ml.root_generation = s.root_generation AND ml.category = ?
		WHERE s.root_id = ? AND s.root_generation = ?
		  AND s.owner_user_id = ? AND s.album_name = ? AND s.member_user_id = ?
		  AND s.can_write = 1`,
		StoragePhotos, StoragePhotos, rootID, int64(generation), ownerID, albumName, actorID).Scan(&exists)
	return err == nil && exists == 1
}
