package gallery

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

var (
	ErrInvalidPersonShare = errors.New("invalid_person_share")
)

// PersonShareView represents a read-only virtual family album dynamically backed
// by an owner's local Vision person cluster within explicitly authorized roots.
type PersonShareView struct {
	ID            int64  `json:"id"`
	OwnerUserID   int64  `json:"ownerUserId"`
	OwnerUsername string `json:"ownerUsername,omitempty"`
	MemberUserID  int64  `json:"memberUserId"`
	MemberName    string `json:"memberUsername,omitempty"`
	PersonID      int64  `json:"personId"`
	PersonName    string `json:"personName"`
	Label         string `json:"label"`
	SinceTakenAt  int64  `json:"sinceTakenAt,omitempty"`
	PhotoCount    int    `json:"photoCount"`
	CoverFaceID   int64  `json:"coverFaceId,omitempty"`
	CoverAssetID  int64  `json:"coverAssetId,omitempty"`
	CreatedAt     int64  `json:"createdAt"`
	Direction     string `json:"direction"` // "outgoing" | "incoming"
}

func ensurePersonSharesTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS person_shares (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			share TEXT NOT NULL,
			owner_user_id INTEGER NOT NULL,
			person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
			member_user_id INTEGER NOT NULL,
			label TEXT NOT NULL DEFAULT '',
			since_taken_at INTEGER NOT NULL DEFAULT 0,
			allowed_roots_json TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			UNIQUE(share, owner_user_id, person_id, member_user_id)
		);
		CREATE INDEX IF NOT EXISTS person_shares_member ON person_shares(share, member_user_id);
		CREATE INDEX IF NOT EXISTS person_shares_owner ON person_shares(share, owner_user_id);
	`)
	return err
}

// CreateOrUpdatePersonShare creates or updates a read-only person stream share
// from ownerUserID to memberUserID, strictly pinned to ownerAllowedRoots.
func (l *Library) CreateOrUpdatePersonShare(ownerUserID, personID, memberUserID int64, label string, sinceTakenAt int64, ownerAllowedRoots []string) (PersonShareView, error) {
	if ownerUserID <= 0 || personID <= 0 || memberUserID <= 0 || ownerUserID == memberUserID || len(ownerAllowedRoots) == 0 {
		return PersonShareView{}, ErrInvalidPersonShare
	}
	if sinceTakenAt < 0 {
		return PersonShareView{}, ErrInvalidPersonShare
	}
	label = strings.TrimSpace(label)
	if utf8.RuneCountInString(label) > 48 || strings.ContainsAny(label, "\r\n\x00") {
		return PersonShareView{}, ErrInvalidPersonShare
	}
	if _, _, err := mediascope.Clause("a.path", ownerAllowedRoots); err != nil {
		return PersonShareView{}, ErrInvalidPersonShare
	}
	share, err := l.share()
	if err != nil {
		return PersonShareView{}, err
	}

	var personName string
	if err := l.readDB().QueryRow(`SELECT name FROM persons WHERE id=? AND share=? AND user_id=?`,
		personID, share, ownerUserID).Scan(&personName); err != nil {
		return PersonShareView{}, err
	}
	if label == "" {
		if personName != "" {
			label = personName + " 的成长相册"
		} else {
			label = "家人人物共享"
		}
	}
	rootsJSON, err := json.Marshal(ownerAllowedRoots)
	if err != nil {
		return PersonShareView{}, err
	}
	nowUnix := l.currentTime().Unix()
	_, err = l.db.Exec(`
		INSERT INTO person_shares(share, owner_user_id, person_id, member_user_id, label, since_taken_at, allowed_roots_json, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(share, owner_user_id, person_id, member_user_id) DO UPDATE SET
			label=excluded.label,
			since_taken_at=excluded.since_taken_at,
			allowed_roots_json=excluded.allowed_roots_json`,
		share, ownerUserID, personID, memberUserID, label, sinceTakenAt, string(rootsJSON), nowUnix)
	if err != nil {
		return PersonShareView{}, err
	}

	var shareID int64
	if err := l.readDB().QueryRow(`SELECT id FROM person_shares WHERE share=? AND owner_user_id=? AND person_id=? AND member_user_id=?`,
		share, ownerUserID, personID, memberUserID).Scan(&shareID); err != nil {
		return PersonShareView{}, err
	}
	return l.getPersonShareSummary(share, shareID, ownerUserID)
}

// DeletePersonShare allows either the owner (revoke) or the recipient (leave)
// to remove a person share immediately.
func (l *Library) DeletePersonShare(actorUserID, shareID int64) error {
	if actorUserID <= 0 || shareID <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	res, err := l.db.Exec(`DELETE FROM person_shares WHERE id=? AND share=? AND (owner_user_id=? OR member_user_id=?)`,
		shareID, share, actorUserID, actorUserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (l *Library) ListPersonSharesForUser(userID int64) ([]PersonShareView, error) {
	if userID <= 0 {
		return nil, ErrInvalidPersonShare
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	rows, err := l.readDB().Query(`
		SELECT ps.id
		FROM person_shares ps
		JOIN persons p ON p.id = ps.person_id
		WHERE ps.share=? AND (ps.owner_user_id=? OR ps.member_user_id=?)
		ORDER BY ps.created_at DESC, ps.id DESC
		LIMIT 100`, share, userID, userID)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	_ = rows.Close()

	out := make([]PersonShareView, 0, len(ids))
	for _, id := range ids {
		if view, err := l.getPersonShareSummary(share, id, userID); err == nil {
			out = append(out, view)
		}
	}
	return out, nil
}

func (l *Library) getPersonShareSummary(share string, shareID, viewerID int64) (PersonShareView, error) {
	var v PersonShareView
	var rootsJSON string
	err := l.readDB().QueryRow(`
		SELECT ps.id, ps.owner_user_id, ps.member_user_id, ps.person_id, p.name, ps.label, ps.since_taken_at, ps.allowed_roots_json, ps.created_at
		FROM person_shares ps
		JOIN persons p ON p.id = ps.person_id
		WHERE ps.id=? AND ps.share=? AND (ps.owner_user_id=? OR ps.member_user_id=?)`,
		shareID, share, viewerID, viewerID).Scan(
		&v.ID, &v.OwnerUserID, &v.MemberUserID, &v.PersonID, &v.PersonName, &v.Label, &v.SinceTakenAt, &rootsJSON, &v.CreatedAt)
	if err != nil {
		return PersonShareView{}, err
	}
	if v.OwnerUserID == viewerID {
		v.Direction = "outgoing"
	} else {
		v.Direction = "incoming"
	}
	var roots []string
	if json.Unmarshal([]byte(rootsJSON), &roots) != nil || len(roots) == 0 {
		return v, nil
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return v, nil
	}
	args := []any{v.OwnerUserID, v.PersonID, share, v.SinceTakenAt}
	args = append(args, scopedArgs...)
	_ = l.readDB().QueryRow(`
		SELECT COUNT(DISTINCT a.id), COALESCE(MAX(a.id), 0)
		FROM person_face_links pfl
		JOIN asset_faces af ON af.id = pfl.face_id
		JOIN assets a ON a.id = af.asset_id
		WHERE pfl.user_id=? AND pfl.person_id=? AND a.share=? AND a.missing_path='' AND a.taken_at>=?`+fragment,
		args...).Scan(&v.PhotoCount, &v.CoverAssetID)
	return v, nil
}

// ListPersonShareAssets returns paginated read-only assets for an authorized
// person share viewer (either owner or recipient).
func (l *Library) ListPersonShareAssets(viewerID, shareID, cursor int64, limit int) ([]Asset, int64, PersonShareView, error) {
	if limit < 1 || limit > 120 || cursor < 0 {
		return nil, 0, PersonShareView{}, errors.New("invalid_limit")
	}
	share, err := l.share()
	if err != nil {
		return nil, 0, PersonShareView{}, err
	}
	var rootsJSON string
	var summary PersonShareView
	err = l.readDB().QueryRow(`
		SELECT ps.id, ps.owner_user_id, ps.member_user_id, ps.person_id, p.name, ps.label, ps.since_taken_at, ps.allowed_roots_json, ps.created_at
		FROM person_shares ps
		JOIN persons p ON p.id = ps.person_id
		WHERE ps.id=? AND ps.share=? AND (ps.owner_user_id=? OR ps.member_user_id=?)`,
		shareID, share, viewerID, viewerID).Scan(
		&summary.ID, &summary.OwnerUserID, &summary.MemberUserID, &summary.PersonID, &summary.PersonName, &summary.Label, &summary.SinceTakenAt, &rootsJSON, &summary.CreatedAt)
	if err != nil {
		return nil, 0, PersonShareView{}, err
	}
	if summary.OwnerUserID == viewerID {
		summary.Direction = "outgoing"
	} else {
		summary.Direction = "incoming"
	}
	var roots []string
	if json.Unmarshal([]byte(rootsJSON), &roots) != nil || len(roots) == 0 {
		return []Asset{}, 0, summary, nil
	}
	// Refresh owner's face links so newly indexed photos automatically appear!
	_ = l.syncUserPersons(share, summary.OwnerUserID, roots)

	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, 0, summary, err
	}
	query := `SELECT DISTINCT a.id,a.path,a.type,a.size,a.modified,a.taken_at,a.favorite,a.probe_status,a.browser_playback,a.mime,a.container,a.video_codec,a.audio_codec,a.duration_seconds,a.width,a.height,a.orientation,a.captured_at,a.gps_lat,a.gps_lon,a.camera_make,a.camera_model,a.exif_json,a.live_video_asset_id
		FROM assets a
		WHERE a.share=? AND a.missing_path='' AND a.is_live_companion=0 AND a.taken_at>=?
		  AND EXISTS (
		    SELECT 1 FROM asset_faces af
		    JOIN person_face_links pfl ON pfl.face_id = af.id
		    WHERE af.asset_id = a.id AND pfl.user_id = ? AND pfl.person_id = ?
		  )` + fragment + `
		ORDER BY a.taken_at DESC, a.id DESC LIMIT ? OFFSET ?`
	args := []any{share, summary.SinceTakenAt, summary.OwnerUserID, summary.PersonID}
	args = append(args, scopedArgs...)
	args = append(args, limit+1, cursor)

	rows, err := l.readDB().Query(query, args...)
	if err != nil {
		return nil, 0, summary, err
	}
	defer rows.Close()

	out := make([]Asset, 0)
	for rows.Next() {
		var a Asset
		var favorite int
		var latitude, longitude sql.NullFloat64
		var cameraMake, cameraModel, exifJSON string
		if err := rows.Scan(&a.ID, &a.Path, &a.Type, &a.Size, &a.Modified, &a.TakenAt, &favorite, &a.ProbeStatus, &a.BrowserPlayback, &a.MIME, &a.Container, &a.VideoCodec, &a.AudioCodec, &a.DurationSeconds, &a.Width, &a.Height, &a.Orientation, &a.CapturedAt, &latitude, &longitude, &cameraMake, &cameraModel, &exifJSON, &a.LiveVideoAssetID); err != nil {
			return nil, 0, summary, err
		}
		applyCaptureColumns(&a, latitude, longitude, cameraMake, cameraModel, exifJSON)
		a.Favorite = favorite != 0
		a.Name = basePathName(a.Path)
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, summary, err
	}
	next := int64(0)
	if len(out) > limit {
		out = out[:limit]
		next = cursor + int64(limit)
	}
	return out, next, summary, nil
}

// AuthorizePersonShareAssetWithOwner verifies that viewerID has access to assetID
// through person shareID and returns both the Asset and the share owner's user ID.
func (l *Library) AuthorizePersonShareAssetWithOwner(viewerID, shareID, assetID int64) (Asset, int64, error) {
	share, err := l.share()
	if err != nil {
		return Asset{}, 0, err
	}
	var ownerID, personID, sinceTakenAt int64
	var rootsJSON string
	err = l.readDB().QueryRow(`
		SELECT owner_user_id, person_id, since_taken_at, allowed_roots_json
		FROM person_shares
		WHERE id=? AND share=? AND (owner_user_id=? OR member_user_id=?)`,
		shareID, share, viewerID, viewerID).Scan(&ownerID, &personID, &sinceTakenAt, &rootsJSON)
	if err != nil {
		return Asset{}, 0, err
	}
	var roots []string
	if json.Unmarshal([]byte(rootsJSON), &roots) != nil || len(roots) == 0 {
		return Asset{}, 0, sql.ErrNoRows
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return Asset{}, 0, sql.ErrNoRows
	}
	args := []any{assetID, share, sinceTakenAt, ownerID, personID}
	args = append(args, scopedArgs...)
	var matchedID int64
	err = l.readDB().QueryRow(`
		SELECT a.id FROM assets a
		WHERE a.id=? AND a.share=? AND a.missing_path='' AND a.taken_at>=?
		  AND EXISTS (
		    SELECT 1 FROM asset_faces af
		    JOIN person_face_links pfl ON pfl.face_id = af.id
		    WHERE af.asset_id = a.id AND pfl.user_id = ? AND pfl.person_id = ?
		  )`+fragment, args...).Scan(&matchedID)
	if err != nil {
		return Asset{}, 0, err
	}
	asset, err := l.Asset(matchedID)
	if err != nil {
		return Asset{}, 0, err
	}
	return asset, ownerID, nil
}

func basePathName(p string) string {
	idx := strings.LastIndexByte(p, '/')
	if idx < 0 {
		return p
	}
	return p[idx+1:]
}
