package auth

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"math"
	"path"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxCollectLinks           = 50
	MaxCollectHours           = 720 // 30 days
	MaxCollectFilesLimit      = 10000
	MaxCollectSingleFileBytes = int64(32) << 30
	MaxCollectTotalBytes      = int64(1) << 40
	maxCollectTitleRunes      = 120
	maxCollectAllowedExts     = 32
)

var (
	ErrCollectLimitReached = errors.New("collect_limit_reached")
	collectExtRule         = regexp.MustCompile(`^\.[a-z0-9]{1,16}$`)
)

// CollectLink is the owner-facing metadata for a write-only public dropbox
// link. The password verifier never leaves the server, and the capability
// token is returned only once at creation time.
type CollectLink struct {
	ID             string   `json:"id"`
	RootID         string   `json:"rootId"`
	RootGeneration uint64   `json:"rootGeneration"`
	TargetPath     string   `json:"targetPath"`
	Title          string   `json:"title"`
	HasPassword    bool     `json:"hasPassword"`
	MaxFiles       int      `json:"maxFiles"`
	MaxFileBytes   int64    `json:"maxFileBytes"`
	MaxTotalBytes  int64    `json:"maxTotalBytes"`
	UploadedFiles  int      `json:"uploadedFiles"`
	UploadedBytes  int64    `json:"uploadedBytes"`
	AllowedExts    []string `json:"allowedExts,omitempty"`
	CreatedAt      int64    `json:"createdAt"`
	ExpiresAt      int64    `json:"expiresAt"`
}

// CollectLinkPolicy holds optional limits and access rules selected by the
// creator when issuing a write-only collect link.
type CollectLinkPolicy struct {
	Title         string
	Password      string
	MaxFiles      int
	MaxFileBytes  int64
	MaxTotalBytes int64
	AllowedExts   []string
}

// CollectLinkAccess is the server-internal capability resolved from a bearer
// token for public write-only upload endpoints.
type CollectLinkAccess struct {
	UserID         int64
	RootID         string
	RootGeneration uint64
	TargetPath     string
	DirIdentity    string
	Title          string
	Digest         []byte
	PasswordHash   []byte
	MaxFiles       int
	MaxFileBytes   int64
	MaxTotalBytes  int64
	UploadedFiles  int
	UploadedBytes  int64
	AllowedExts    []string
	ExpiresAt      int64
}

func normalizeCollectPolicy(targetPath string, p CollectLinkPolicy) (CollectLinkPolicy, string, error) {
	title := strings.TrimSpace(p.Title)
	if title == "" {
		title = path.Base(targetPath)
	}
	if strings.ContainsRune(title, 0) || utf8.RuneCountInString(title) < 1 || utf8.RuneCountInString(title) > maxCollectTitleRunes {
		return CollectLinkPolicy{}, "", ErrInput
	}
	if p.Password != "" {
		if utf8.RuneCountInString(p.Password) < 4 || len(p.Password) > maxSharePasswordChars {
			return CollectLinkPolicy{}, "", ErrInput
		}
	}
	if p.MaxFiles < 0 || p.MaxFiles > MaxCollectFilesLimit {
		return CollectLinkPolicy{}, "", ErrInput
	}
	if p.MaxFileBytes < 0 || p.MaxFileBytes > MaxCollectSingleFileBytes {
		return CollectLinkPolicy{}, "", ErrInput
	}
	if p.MaxTotalBytes < 0 || p.MaxTotalBytes > MaxCollectTotalBytes {
		return CollectLinkPolicy{}, "", ErrInput
	}
	if len(p.AllowedExts) > maxCollectAllowedExts {
		return CollectLinkPolicy{}, "", ErrInput
	}
	seen := make(map[string]bool, len(p.AllowedExts))
	cleanExts := make([]string, 0, len(p.AllowedExts))
	for _, raw := range p.AllowedExts {
		ext := strings.ToLower(strings.TrimSpace(raw))
		if ext == "" {
			continue
		}
		if !strings.HasPrefix(ext, ".") {
			ext = "." + ext
		}
		if !collectExtRule.MatchString(ext) {
			return CollectLinkPolicy{}, "", ErrInput
		}
		if seen[ext] {
			continue
		}
		seen[ext] = true
		cleanExts = append(cleanExts, ext)
	}
	out := CollectLinkPolicy{
		Title:         title,
		Password:      p.Password,
		MaxFiles:      p.MaxFiles,
		MaxFileBytes:  p.MaxFileBytes,
		MaxTotalBytes: p.MaxTotalBytes,
		AllowedExts:   cleanExts,
	}
	return out, strings.Join(cleanExts, ","), nil
}

func parseAllowedExtsCSV(csv string) []string {
	if strings.TrimSpace(csv) == "" {
		return nil
	}
	parts := strings.Split(csv, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// CreateRootCollectLink publishes a write-only collect capability isolated in
// root_file_collect_links. Authorization (write permission, enabled user, live
// session) is rechecked inside the INSERT transaction.
func (s *Store) CreateRootCollectLink(
	ctx context.Context,
	session, rootID string,
	rootGeneration uint64,
	targetPath, dirIdentity string,
	expiresAt int64,
	policy CollectLinkPolicy,
) (CollectLink, string, error) {
	if ctx == nil || !validRootID(rootID) || rootGeneration == 0 || rootGeneration > math.MaxInt64 ||
		!validGrantPath(targetPath) || targetPath == "." ||
		!strings.HasPrefix(dirIdentity, "d:") || len(dirIdentity) > 1024 {
		return CollectLink{}, "", ErrInput
	}
	cleanPolicy, extsCSV, err := normalizeCollectPolicy(targetPath, policy)
	if err != nil {
		return CollectLink{}, "", ErrInput
	}
	now := time.Now().Unix()
	if expiresAt <= now || expiresAt > now+int64(MaxCollectHours)*3600 {
		return CollectLink{}, "", ErrInput
	}
	verifier := []byte{}
	if cleanPolicy.Password != "" {
		encoded, encErr := encodeSharePassword(cleanPolicy.Password)
		if encErr != nil {
			return CollectLink{}, "", encErr
		}
		verifier = encoded
	}
	user, ok := s.Identity(session)
	if !ok || !s.CanAccessRoot(session, rootID, targetPath, true, false) {
		return CollectLink{}, "", ErrForbidden
	}
	if user.Role != RoleAdmin && (denyPersonalHomeForMember(targetPath, user.ID, true) ||
		(isPersonalHomePath(targetPath) && s.detachedHomeIntersects(rootID, targetPath, false))) {
		return CollectLink{}, "", ErrForbidden
	}
	secret, err := random(32)
	if err != nil {
		return CollectLink{}, "", err
	}
	token := base64.RawURLEncoding.EncodeToString(secret)
	digest := sha256.Sum256([]byte(token))
	sessionID := sha256.Sum256([]byte(session))

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CollectLink{}, "", err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `DELETE FROM root_file_collect_links WHERE expires_at<=?`, now); err != nil {
		return CollectLink{}, "", err
	}
	var count int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM root_file_collect_links WHERE user_id=? AND expires_at>?`,
		user.ID, now).Scan(&count); err != nil {
		return CollectLink{}, "", err
	}
	if count >= MaxCollectLinks {
		return CollectLink{}, "", ErrExists
	}

	result, err := tx.ExecContext(ctx, `
		INSERT INTO root_file_collect_links
			(id, user_id, root_id, root_generation, target_path, dir_identity, title,
			 password_hash, max_files, max_file_bytes, max_total_bytes,
			 uploaded_files, uploaded_bytes, allowed_exts, created_at, expires_at)
		SELECT ?, u.id, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?
		FROM users u JOIN sessions ss ON ss.user_id=u.id
		WHERE u.id=? AND u.enabled=1 AND ss.id=? AND ss.expires_at>?
		  AND (u.role=? OR EXISTS(
		      SELECT 1 FROM root_file_grants g
		      WHERE g.user_id=u.id AND g.root_id=? AND g.can_write=1
		        AND (g.path='.' OR g.path=? OR substr(?,1,length(g.path)+1)=g.path||'/')
		  ))`,
		digest[:], rootID, int64(rootGeneration), targetPath, dirIdentity, cleanPolicy.Title,
		verifier, cleanPolicy.MaxFiles, cleanPolicy.MaxFileBytes, cleanPolicy.MaxTotalBytes,
		extsCSV, now, expiresAt,
		user.ID, sessionID[:], time.Now().Unix(), RoleAdmin, rootID, targetPath, targetPath)
	if err != nil {
		return CollectLink{}, "", err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return CollectLink{}, "", err
	}
	if affected != 1 {
		return CollectLink{}, "", ErrForbidden
	}
	if err := tx.Commit(); err != nil {
		return CollectLink{}, "", err
	}
	return CollectLink{
		ID:             hex.EncodeToString(digest[:]),
		RootID:         rootID,
		RootGeneration: rootGeneration,
		TargetPath:     targetPath,
		Title:          cleanPolicy.Title,
		HasPassword:    cleanPolicy.Password != "",
		MaxFiles:       cleanPolicy.MaxFiles,
		MaxFileBytes:   cleanPolicy.MaxFileBytes,
		MaxTotalBytes:  cleanPolicy.MaxTotalBytes,
		AllowedExts:    cleanPolicy.AllowedExts,
		CreatedAt:      now,
		ExpiresAt:      expiresAt,
	}, token, nil
}

func (s *Store) ListRootCollectLinks(session, rootID string) ([]CollectLink, error) {
	if !validRootID(rootID) {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	sessionID := sha256.Sum256([]byte(session))
	now := time.Now().Unix()
	rows, err := s.readDB().Query(`
		SELECT id, root_generation, target_path, title,
		       COALESCE(password_hash,'')<>'', max_files, max_file_bytes, max_total_bytes,
		       uploaded_files, uploaded_bytes, allowed_exts, created_at, expires_at
		FROM root_file_collect_links
		WHERE user_id=? AND root_id=? AND expires_at>?
		  AND EXISTS(
		      SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
		      WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1
		  )
		ORDER BY created_at DESC LIMIT 100`,
		user.ID, rootID, now, sessionID[:], user.ID, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]CollectLink, 0, 8)
	for rows.Next() {
		var digest []byte
		var extsCSV string
		var item CollectLink
		if err := rows.Scan(
			&digest, &item.RootGeneration, &item.TargetPath, &item.Title,
			&item.HasPassword, &item.MaxFiles, &item.MaxFileBytes, &item.MaxTotalBytes,
			&item.UploadedFiles, &item.UploadedBytes, &extsCSV, &item.CreatedAt, &item.ExpiresAt,
		); err != nil {
			return nil, err
		}
		if len(digest) != sha256.Size {
			return nil, ErrInput
		}
		item.ID = hex.EncodeToString(digest)
		item.RootID = rootID
		item.AllowedExts = parseAllowedExtsCSV(extsCSV)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) RevokeRootCollectLink(ctx context.Context, session, rootID, linkID string) error {
	if ctx == nil || !validRootID(rootID) || len(linkID) != sha256.Size*2 {
		return ErrInput
	}
	digest, err := hex.DecodeString(linkID)
	if err != nil {
		return ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	sessionID := sha256.Sum256([]byte(session))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
		DELETE FROM root_file_collect_links
		WHERE id=? AND root_id=? AND (user_id=? OR ?=?)
		  AND EXISTS(
		      SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
		      WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1
		  )`,
		digest, rootID, user.ID, user.Role, RoleAdmin, sessionID[:], user.ID, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

// ResolveRootCollectLink validates a bearer token against root_file_collect_links
// and verifies the creator is still enabled and holds write access to the target
// directory. It never consults root_file_shares.
func (s *Store) ResolveRootCollectLink(token string) (CollectLinkAccess, error) {
	var item CollectLinkAccess
	if len(token) != 43 {
		return item, ErrNotFound
	}
	secret, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(secret) != 32 {
		return item, ErrNotFound
	}
	digest := sha256.Sum256([]byte(token))
	var role, extsCSV string
	err = s.readDB().QueryRow(`
		SELECT l.user_id, u.role, l.root_id, l.root_generation, l.target_path, l.dir_identity,
		       l.title, l.id, COALESCE(l.password_hash,''), l.max_files, l.max_file_bytes,
		       l.max_total_bytes, l.uploaded_files, l.uploaded_bytes, l.allowed_exts, l.expires_at
		FROM root_file_collect_links l
		JOIN users u ON u.id=l.user_id
		WHERE l.id=? AND l.expires_at>? AND u.enabled=1`,
		digest[:], time.Now().Unix()).
		Scan(&item.UserID, &role, &item.RootID, &item.RootGeneration, &item.TargetPath, &item.DirIdentity,
			&item.Title, &item.Digest, &item.PasswordHash, &item.MaxFiles, &item.MaxFileBytes,
			&item.MaxTotalBytes, &item.UploadedFiles, &item.UploadedBytes, &extsCSV, &item.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && (!validRootID(item.RootID) || item.RootGeneration == 0)) {
		return CollectLinkAccess{}, ErrNotFound
	}
	if err != nil {
		return CollectLinkAccess{}, err
	}
	canWrite, writeErr := s.UserCanWriteRoot(item.UserID, item.RootID, item.TargetPath)
	if writeErr != nil || !canWrite {
		return CollectLinkAccess{}, ErrNotFound
	}
	if role != RoleAdmin &&
		(denyPersonalHomeForMember(item.TargetPath, item.UserID, true) ||
			(isPersonalHomePath(item.TargetPath) && s.detachedHomeIntersects(item.RootID, item.TargetPath, false))) {
		return CollectLinkAccess{}, ErrNotFound
	}
	item.AllowedExts = parseAllowedExtsCSV(extsCSV)
	return item, nil
}

// ConsumeRootCollectUpload atomically increments uploaded_files and
// uploaded_bytes while enforcing the link's expiry, file count limit, and total
// byte budget under SQLite's write lock.
func (s *Store) ConsumeRootCollectUpload(digest []byte, fileBytes int64) error {
	if len(digest) != sha256.Size || fileBytes < 0 {
		return ErrInput
	}
	now := time.Now().Unix()
	res, err := s.db.Exec(`
		UPDATE root_file_collect_links
		SET uploaded_files = uploaded_files + 1,
		    uploaded_bytes = uploaded_bytes + ?
		WHERE id = ? AND expires_at > ?
		  AND (max_files = 0 OR uploaded_files < max_files)
		  AND (max_total_bytes = 0 OR uploaded_bytes + ? <= max_total_bytes)`,
		fileBytes, digest, now, fileBytes)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		var exists int
		qErr := s.readDB().QueryRow(`SELECT 1 FROM root_file_collect_links WHERE id=? AND expires_at>?`, digest, now).Scan(&exists)
		if qErr == nil {
			return ErrCollectLimitReached
		}
		return ErrNotFound
	}
	return nil
}

// RefundRootCollectUpload rolls back a counter increment if a staged file
// failed before publication.
func (s *Store) RefundRootCollectUpload(digest []byte, fileBytes int64) error {
	if len(digest) != sha256.Size || fileBytes < 0 {
		return ErrInput
	}
	_, err := s.db.Exec(`
		UPDATE root_file_collect_links
		SET uploaded_files = CASE WHEN uploaded_files > 0 THEN uploaded_files - 1 ELSE 0 END,
		    uploaded_bytes = CASE WHEN uploaded_bytes >= ? THEN uploaded_bytes - ? ELSE 0 END
		WHERE id = ?`,
		fileBytes, fileBytes, digest)
	return err
}

// ReservationForRootUploadForUser is the user-authenticated counterpart to
// ReservationForRootUpload, used by write-only collect links where the creator
// owns the target storage quota without an active visitor browser session.
func (s *Store) ReservationForRootUploadForUser(uploadID string, actor User, expectedRootID string, expectedGeneration uint64, expectedPath string) (string, error) {
	if !actor.Enabled || actor.ID <= 0 {
		return "", ErrForbidden
	}
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var id, rootID, relPath string
	var owner, gen int64
	err = tx.QueryRow(`SELECT id, user_id, root_id, root_generation, relative_path
		FROM user_storage_reservations WHERE upload_id=?`, uploadID).
		Scan(&id, &owner, &rootID, &gen, &relPath)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrStorageReservationMissing
	}
	if err != nil {
		return "", err
	}
	if expectedRootID != "" && (rootID != expectedRootID || gen < 1 ||
		uint64(gen) != expectedGeneration || relPath != expectedPath) {
		return "", ErrStorageReservationMissing
	}
	if actor.Role != RoleAdmin && actor.ID != owner &&
		(gen <= 0 || !canMemberWriteSharedFolderAlbumTx(tx, actor.ID, rootID, uint64(gen), owner, relPath)) {
		return "", ErrStorageReservationMissing
	}
	return id, nil
}
