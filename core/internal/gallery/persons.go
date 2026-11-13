package gallery

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

const (
	faceClusterCosineThreshold = 0.68
	minClusterSeedQuality      = 0.28
	maxPersonNameRunes         = 40
)

var (
	ErrInvalidPersonName = errors.New("invalid_person_name")
	ErrCannotMergeSame   = errors.New("cannot_merge_same_person")
)

type PersonSummary struct {
	ID           int64  `json:"id"`
	Name         string `json:"name"`
	PhotoCount   int    `json:"photoCount"`
	FaceCount    int    `json:"faceCount"`
	CoverFaceID  int64  `json:"coverFaceId,omitempty"`
	CoverAssetID int64  `json:"coverAssetId,omitempty"`
	Hidden       bool   `json:"hidden"`
}

type faceRecord struct {
	id           int64
	assetID      int64
	quality      float32
	eyeOpenness  float32
	modelVersion string
	vec          []float32
}

type personClusterState struct {
	id           int64
	modelVersion string
	centroid     []float32
	faceCount    int
}

// ListPersonsScoped synchronizes newly extracted faces within the caller's
// authorized roots into user-private person clusters, then returns only clusters
// backed by currently readable assets.
func (l *Library) ListPersonsScoped(userID int64, includeHidden bool, roots []string) ([]PersonSummary, error) {
	if userID <= 0 {
		return nil, errors.New("authentication_required")
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	if err := l.syncUserPersons(share, userID, roots); err != nil {
		return nil, err
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	hiddenFilter := " AND p.is_hidden=0"
	if includeHidden {
		hiddenFilter = ""
	}
	args := append([]any{}, scopedArgs...)
	args = append(args, userID, share, userID)
	args = append(args, scopedArgs...)
	rows, err := l.readDB().Query(`
		SELECT
			sub.id,
			sub.name,
			sub.is_hidden,
			sub.photo_cnt,
			sub.face_cnt,
			sub.best_face_id,
			COALESCE(cf.asset_id, 0)
		FROM (
			SELECT
				p.id,
				p.name,
				p.is_hidden,
				COUNT(DISTINCT a.id) AS photo_cnt,
				COUNT(af.id) AS face_cnt,
				COALESCE((
					SELECT af2.id FROM person_face_links pfl2
					JOIN asset_faces af2 ON af2.id = pfl2.face_id
					JOIN assets a2 ON a2.id = af2.asset_id
					WHERE pfl2.user_id = p.user_id AND pfl2.person_id = p.id
					  AND a2.share = p.share AND a2.missing_path = ''`+strings.ReplaceAll(fragment, "a.path", "a2.path")+`
					ORDER BY (af2.quality * (0.5 + 0.5 * af2.eye_openness)) DESC, af2.id ASC
					LIMIT 1
				), 0) AS best_face_id
			FROM persons p
			JOIN person_face_links pfl ON pfl.person_id = p.id AND pfl.user_id = ?
			JOIN asset_faces af ON af.id = pfl.face_id
			JOIN assets a ON a.id = af.asset_id
			WHERE p.share = ? AND p.user_id = ? AND a.share = p.share AND a.missing_path = ''`+hiddenFilter+fragment+`
			GROUP BY p.id
			HAVING photo_cnt > 0
			ORDER BY (CASE WHEN p.name<>'' THEN 0 ELSE 1 END) ASC, photo_cnt DESC, p.id ASC
			LIMIT 200
		) sub
		LEFT JOIN asset_faces cf ON cf.id = sub.best_face_id
		ORDER BY (CASE WHEN sub.name<>'' THEN 0 ELSE 1 END) ASC, sub.photo_cnt DESC, sub.id ASC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PersonSummary, 0)
	for rows.Next() {
		var item PersonSummary
		var hiddenInt int
		if err := rows.Scan(&item.ID, &item.Name, &hiddenInt, &item.PhotoCount, &item.FaceCount, &item.CoverFaceID, &item.CoverAssetID); err != nil {
			return nil, err
		}
		item.Hidden = hiddenInt != 0
		out = append(out, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (l *Library) syncUserPersons(share string, userID int64, roots []string) error {
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return err
	}
	queryArgs := append([]any{share}, scopedArgs...)
	queryArgs = append(queryArgs, userID)
	rows, err := l.readDB().Query(`
		SELECT af.id, af.asset_id, af.quality, af.eye_openness, af.model_version, af.embedding
		FROM asset_faces af
		JOIN assets a ON a.id = af.asset_id
		WHERE a.share = ? AND a.missing_path = ''`+fragment+`
		  AND NOT EXISTS (SELECT 1 FROM person_face_links pfl WHERE pfl.user_id = ? AND pfl.face_id = af.id)
		ORDER BY af.quality DESC, af.id ASC
		LIMIT 500`, queryArgs...)
	if err != nil {
		return err
	}
	var unassigned []faceRecord
	for rows.Next() {
		var r faceRecord
		var raw []byte
		if err := rows.Scan(&r.id, &r.assetID, &r.quality, &r.eyeOpenness, &r.modelVersion, &raw); err != nil {
			rows.Close()
			return err
		}
		vec, ok := decodeFloat32Vector(raw)
		if ok {
			r.vec = vec
			unassigned = append(unassigned, r)
		}
	}
	rows.Close()
	if len(unassigned) == 0 {
		return nil
	}

	existingRows, err := l.db.Query(`
		SELECT id, model_version, centroid, face_count
		FROM persons WHERE share=? AND user_id=?`, share, userID)
	if err != nil {
		return err
	}
	var clusters []personClusterState
	for existingRows.Next() {
		var c personClusterState
		var raw []byte
		if err := existingRows.Scan(&c.id, &c.modelVersion, &raw, &c.faceCount); err != nil {
			existingRows.Close()
			return err
		}
		if vec, ok := decodeFloat32Vector(raw); ok {
			c.centroid = vec
			clusters = append(clusters, c)
		}
	}
	existingRows.Close()

	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	nowUnix := l.currentTime().Unix()

	for _, face := range unassigned {
		bestIdx := -1
		bestSim := float32(faceClusterCosineThreshold)
		for i := range clusters {
			if clusters[i].modelVersion != face.modelVersion || len(clusters[i].centroid) != len(face.vec) {
				continue
			}
			sim := cosineSimilarity(clusters[i].centroid, face.vec)
			if sim >= bestSim {
				bestSim = sim
				bestIdx = i
			}
		}
		if bestIdx >= 0 {
			target := &clusters[bestIdx]
			target.centroid = mergeWeightedCentroid(target.centroid, target.faceCount, face.vec, 1)
			target.faceCount++
			if _, err := tx.Exec(`UPDATE persons SET centroid=?, face_count=?, updated_at=? WHERE id=?`,
				encodeFloat32Vector(target.centroid), target.faceCount, nowUnix, target.id); err != nil {
				return err
			}
			if _, err := tx.Exec(`INSERT OR IGNORE INTO person_face_links(user_id, face_id, person_id) VALUES(?, ?, ?)`,
				userID, face.id, target.id); err != nil {
				return err
			}
			continue
		}
		if face.quality < minClusterSeedQuality {
			continue
		}
		res, err := tx.Exec(`
			INSERT INTO persons(share, user_id, model_version, name, cover_face_id, centroid, face_count, is_hidden, updated_at)
			VALUES(?, ?, ?, '', ?, ?, 1, 0, ?)`,
			share, userID, face.modelVersion, face.id, encodeFloat32Vector(face.vec), nowUnix)
		if err != nil {
			return err
		}
		personID, err := res.LastInsertId()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT OR IGNORE INTO person_face_links(user_id, face_id, person_id) VALUES(?, ?, ?)`,
			userID, face.id, personID); err != nil {
			return err
		}
		clusters = append(clusters, personClusterState{
			id: personID, modelVersion: face.modelVersion, centroid: face.vec, faceCount: 1,
		})
	}
	return tx.Commit()
}

func (l *Library) UpdatePerson(userID, personID int64, name *string, hidden *bool) error {
	if userID <= 0 || personID <= 0 {
		return sql.ErrNoRows
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	if name != nil {
		trimmed := strings.TrimSpace(*name)
		if utf8.RuneCountInString(trimmed) > maxPersonNameRunes || strings.ContainsAny(trimmed, "\r\n\x00") {
			return ErrInvalidPersonName
		}
		res, err := l.db.Exec(`UPDATE persons SET name=?, updated_at=? WHERE id=? AND share=? AND user_id=?`,
			trimmed, l.currentTime().Unix(), personID, share, userID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return sql.ErrNoRows
		}
	}
	if hidden != nil {
		h := 0
		if *hidden {
			h = 1
		}
		res, err := l.db.Exec(`UPDATE persons SET is_hidden=?, updated_at=? WHERE id=? AND share=? AND user_id=?`,
			h, l.currentTime().Unix(), personID, share, userID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return sql.ErrNoRows
		}
	}
	return nil
}

func (l *Library) MergePersons(userID, sourcePersonID, targetPersonID int64) error {
	if userID <= 0 || sourcePersonID <= 0 || targetPersonID <= 0 {
		return sql.ErrNoRows
	}
	if sourcePersonID == targetPersonID {
		return ErrCannotMergeSame
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var srcRaw, dstRaw []byte
	var srcCount, dstCount int
	var srcName, dstName string
	if err := tx.QueryRow(`SELECT name, centroid, face_count FROM persons WHERE id=? AND share=? AND user_id=?`,
		sourcePersonID, share, userID).Scan(&srcName, &srcRaw, &srcCount); err != nil {
		return err
	}
	if err := tx.QueryRow(`SELECT name, centroid, face_count FROM persons WHERE id=? AND share=? AND user_id=?`,
		targetPersonID, share, userID).Scan(&dstName, &dstRaw, &dstCount); err != nil {
		return err
	}
	mergedCentroid := dstRaw
	if sv, ok1 := decodeFloat32Vector(srcRaw); ok1 {
		if dv, ok2 := decodeFloat32Vector(dstRaw); ok2 && len(sv) == len(dv) {
			mergedCentroid = encodeFloat32Vector(mergeWeightedCentroid(dv, dstCount, sv, srcCount))
		}
	}
	finalName := dstName
	if finalName == "" && srcName != "" {
		finalName = srcName
	}
	if _, err := tx.Exec(`UPDATE person_face_links SET person_id=? WHERE user_id=? AND person_id=?`,
		targetPersonID, userID, sourcePersonID); err != nil {
		return err
	}
	var totalFaces int
	_ = tx.QueryRow(`SELECT COUNT(*) FROM person_face_links WHERE user_id=? AND person_id=?`, userID, targetPersonID).Scan(&totalFaces)
	if _, err := tx.Exec(`UPDATE persons SET name=?, centroid=?, face_count=?, is_hidden=0, updated_at=? WHERE id=? AND share=? AND user_id=?`,
		finalName, mergedCentroid, totalFaces, l.currentTime().Unix(), targetPersonID, share, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM persons WHERE id=? AND share=? AND user_id=?`, sourcePersonID, share, userID); err != nil {
		return err
	}
	return tx.Commit()
}

// FaceCropJPEG crops an expanded avatar square from the cached upright 512px
// thumbnail. Caller must verify asset path access via allowMediaAsset first.
func (l *Library) FaceAssetAndBox(faceID int64) (Asset, [4]float32, error) {
	var assetID int64
	var box [4]float32
	err := l.readDB().QueryRow(`SELECT asset_id, box_x, box_y, box_w, box_h FROM asset_faces WHERE id=?`, faceID).
		Scan(&assetID, &box[0], &box[1], &box[2], &box[3])
	if err != nil {
		return Asset{}, box, err
	}
	asset, err := l.Asset(assetID)
	return asset, box, err
}

const maxFaceAvatarCacheEntries = 128

// FaceAvatarKey returns a deterministic content key for a cropped face avatar
// so HTTP handlers can negotiate ETag/304 without decoding the source JPEG.
func FaceAvatarKey(faceID int64, asset Asset, box [4]float32) string {
	raw := fmt.Sprintf("face:v1:%d:%d:%d:%d:%.4f:%.4f:%.4f:%.4f",
		faceID, asset.ID, asset.Size, asset.Modified, box[0], box[1], box[2], box[3])
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:16])
}

func (l *Library) RenderFaceAvatarJPEG(ctx context.Context, assetID int64, box [4]float32) ([]byte, error) {
	asset, err := l.Asset(assetID)
	if err != nil {
		return nil, err
	}
	cacheKey := FaceAvatarKey(0, asset, box)
	l.faceMu.Lock()
	if cached, ok := l.faceCache[cacheKey]; ok {
		l.faceMu.Unlock()
		return cached, nil
	}
	l.faceMu.Unlock()

	thumbFile, err := l.ThumbnailContext(ctx, assetID)
	if err != nil {
		return nil, err
	}
	defer thumbFile.Close()
	img, err := jpeg.Decode(thumbFile)
	if err != nil {
		return nil, err
	}
	bounds := img.Bounds()
	w := float64(bounds.Dx())
	h := float64(bounds.Dy())
	cx := (float64(box[0]) + float64(box[2])*0.5) * w
	cy := (float64(box[1]) + float64(box[3])*0.5) * h
	side := math.Max(float64(box[2])*w, float64(box[3])*h) * 1.65
	side = math.Max(48, math.Min(side, math.Min(w, h)))
	half := side * 0.5
	x0 := int(math.Round(math.Max(0, math.Min(w-side, cx-half)))) + bounds.Min.X
	y0 := int(math.Round(math.Max(0, math.Min(h-side, cy-half)))) + bounds.Min.Y
	cropRect := image.Rect(x0, y0, x0+int(math.Round(side)), y0+int(math.Round(side))).Intersect(bounds)

	type subImager interface {
		SubImage(r image.Rectangle) image.Image
	}
	cropped := img
	if sub, ok := img.(subImager); ok && !cropRect.Empty() {
		cropped = sub.SubImage(cropRect)
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, cropped, &jpeg.Options{Quality: 86}); err != nil {
		return nil, err
	}
	encoded := append([]byte(nil), buf.Bytes()...)

	l.faceMu.Lock()
	if l.faceCache == nil {
		l.faceCache = map[string][]byte{}
	}
	if _, exists := l.faceCache[cacheKey]; !exists {
		if len(l.faceOrder) >= maxFaceAvatarCacheEntries {
			evict := l.faceOrder[0]
			l.faceOrder = l.faceOrder[1:]
			delete(l.faceCache, evict)
		}
		l.faceOrder = append(l.faceOrder, cacheKey)
	}
	l.faceCache[cacheKey] = encoded
	l.faceMu.Unlock()
	return encoded, nil
}

func decodeFloat32Vector(raw []byte) ([]float32, bool) {
	if len(raw) < 16 || len(raw)%4 != 0 {
		return nil, false
	}
	n := len(raw) / 4
	vec := make([]float32, n)
	for i := 0; i < n; i++ {
		vec[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4 : (i+1)*4]))
	}
	return vec, true
}

func encodeFloat32Vector(vec []float32) []byte {
	raw := make([]byte, len(vec)*4)
	for i, v := range vec {
		binary.LittleEndian.PutUint32(raw[i*4:(i+1)*4], math.Float32bits(v))
	}
	return raw
}

func cosineSimilarity(a, b []float32) float32 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, normA, normB float64
	for i := range a {
		av, bv := float64(a[i]), float64(b[i])
		dot += av * bv
		normA += av * av
		normB += bv * bv
	}
	denom := math.Sqrt(normA * normB)
	if denom < 1e-9 {
		return 0
	}
	return float32(dot / denom)
}

func mergeWeightedCentroid(a []float32, weightA int, b []float32, weightB int) []float32 {
	out := make([]float32, len(a))
	wa, wb := float64(max(1, weightA)), float64(max(1, weightB))
	var normSq float64
	for i := range a {
		v := float64(a[i])*wa + float64(b[i])*wb
		out[i] = float32(v)
		normSq += v * v
	}
	norm := math.Sqrt(normSq)
	if norm > 1e-9 {
		for i := range out {
			out[i] = float32(float64(out[i]) / norm)
		}
	}
	return out
}
