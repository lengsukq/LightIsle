package gallery

import (
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"path"
	"sort"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

const (
	burstMaxIntervalSeconds   int64   = 3
	burstMaxCosineDistance    float32 = 0.28
	similarMaxIntervalSeconds int64   = 1800
	similarMaxCosineDistance  float32 = 0.14
	maxSimilarScanRows                = 3000
)

type SimilarPhotoCandidate struct {
	AssetID       int64    `json:"assetId"`
	Path          string   `json:"path"`
	Name          string   `json:"name"`
	Size          int64    `json:"size"`
	TakenAt       int64    `json:"takenAt"`
	Width         int      `json:"width"`
	Height        int      `json:"height"`
	Sharpness     float32  `json:"sharpness"`
	QualityScore  float32  `json:"qualityScore"`
	Recommended   bool     `json:"recommended"`
	QualityBadges []string `json:"qualityBadges,omitempty"`
}

type SimilarPhotoGroup struct {
	GroupID            string                  `json:"groupId"`
	Kind               string                  `json:"kind"` // "burst" | "similar"
	TakenAt            int64                   `json:"takenAt"`
	RecommendedAssetID int64                   `json:"recommendedAssetId"`
	RecommendReason    string                  `json:"recommendReason"`
	ReclaimableBytes   int64                   `json:"reclaimableBytes"`
	Items              []SimilarPhotoCandidate `json:"items"`
}

type rawFeatureRow struct {
	assetID     int64
	relPath     string
	size        int64
	takenAt     int64
	modified    int64
	width       int
	height      int
	cameraModel string
	sharpness   float32
	aesthetics  float32
	faceQuality float32
	minEyeOpen  float32
	faceCount   int
	vec         []float32
}

func (l *Library) FindSimilarGroupsScoped(roots []string, maxGroups int) ([]SimilarPhotoGroup, error) {
	if maxGroups <= 0 || maxGroups > 100 {
		maxGroups = 50
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	args := append([]any{share}, scopedArgs...)
	args = append(args, maxSimilarScanRows)

	rows, err := l.db.Query(`
		SELECT
			a.id, a.path, a.size, a.taken_at, a.modified, a.width, a.height, a.camera_model,
			f.feature_print_f16, f.sharpness, f.aesthetics,
			COALESCE((SELECT MAX(af.quality) FROM asset_faces af WHERE af.asset_id=a.id), 0),
			COALESCE((SELECT MIN(af.eye_openness) FROM asset_faces af WHERE af.asset_id=a.id), 1),
			(SELECT COUNT(*) FROM asset_faces af WHERE af.asset_id=a.id)
		FROM assets a
		JOIN asset_features f ON f.asset_id = a.id
		WHERE a.share = ? AND a.missing_path = '' AND a.type = 'photo'`+fragment+`
		ORDER BY (CASE WHEN a.taken_at > 0 THEN a.taken_at ELSE a.modified / 1000000000 END) DESC, a.id DESC
		LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []rawFeatureRow
	for rows.Next() {
		var r rawFeatureRow
		var f16 []byte
		if err := rows.Scan(
			&r.assetID, &r.relPath, &r.size, &r.takenAt, &r.modified, &r.width, &r.height, &r.cameraModel,
			&f16, &r.sharpness, &r.aesthetics, &r.faceQuality, &r.minEyeOpen, &r.faceCount,
		); err != nil {
			return nil, err
		}
		if vec, ok := decodeFloat16Vector(f16); ok {
			r.vec = vec
			items = append(items, r)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return clusterSimilarPhotos(items, maxGroups), nil
}

func clusterSimilarPhotos(items []rawFeatureRow, maxGroups int) []SimilarPhotoGroup {
	n := len(items)
	if n < 2 {
		return []SimilarPhotoGroup{}
	}
	visited := make([]bool, n)
	groups := make([]SimilarPhotoGroup, 0)

	for i := 0; i < n && len(groups) < maxGroups; i++ {
		if visited[i] {
			continue
		}
		anchor := items[i]
		tsAnchor := effectiveTimestamp(anchor)
		members := []rawFeatureRow{anchor}
		isBurst := false

		for j := i + 1; j < n && len(members) < 20; j++ {
			if visited[j] {
				continue
			}
			cand := items[j]
			dt := tsAnchor - effectiveTimestamp(cand)
			if dt < 0 {
				dt = -dt
			}
			if dt > similarMaxIntervalSeconds {
				break
			}
			if len(anchor.vec) != len(cand.vec) {
				continue
			}
			dist := 1.0 - cosineSimilarity(anchor.vec, cand.vec)
			sameCam := anchor.cameraModel != "" && anchor.cameraModel == cand.cameraModel
			if dt <= burstMaxIntervalSeconds && (sameCam || anchor.cameraModel == "") && dist <= burstMaxCosineDistance {
				visited[j] = true
				members = append(members, cand)
				isBurst = true
			} else if dist <= similarMaxCosineDistance {
				visited[j] = true
				members = append(members, cand)
			}
		}
		if len(members) < 2 {
			continue
		}
		visited[i] = true
		kind := "similar"
		if isBurst {
			kind = "burst"
		}
		groups = append(groups, buildSimilarGroup(members, kind))
	}
	return groups
}

func buildSimilarGroup(members []rawFeatureRow, kind string) SimilarPhotoGroup {
	// Sort chronologically within group for natural side-by-side comparison.
	sort.Slice(members, func(i, j int) bool {
		ti, tj := effectiveTimestamp(members[i]), effectiveTimestamp(members[j])
		if ti == tj {
			return members[i].assetID < members[j].assetID
		}
		return ti < tj
	})

	var maxSharp float32
	for _, m := range members {
		if m.sharpness > maxSharp {
			maxSharp = m.sharpness
		}
	}

	bestIdx := 0
	var bestScore float32 = -999
	scores := make([]float32, len(members))
	for i, m := range members {
		s := scorePhotoCandidate(m)
		scores[i] = s
		if s > bestScore {
			bestScore = s
			bestIdx = i
		}
	}

	best := members[bestIdx]
	reason := "最佳推荐 · 综合画质最优"
	if best.faceCount > 0 && best.minEyeOpen >= 0.45 {
		reason = "最佳推荐 · 表情自然睁眼 · 画面清晰"
	} else if best.sharpness >= maxSharp*0.95 && best.sharpness > 0.25 {
		reason = "最佳推荐 · 对焦最清晰"
	}

	var reclaimable int64
	candidates := make([]SimilarPhotoCandidate, len(members))
	for i, m := range members {
		recommended := i == bestIdx
		var badges []string
		if recommended {
			badges = append(badges, "推荐保留")
		} else {
			reclaimable += m.size
			if m.faceCount > 0 && m.minEyeOpen < 0.28 {
				badges = append(badges, "疑似闭眼")
			}
			if maxSharp > 0.2 && m.sharpness < maxSharp*0.72 {
				badges = append(badges, "对焦较软")
			}
			if len(badges) == 0 {
				if kind == "burst" {
					badges = append(badges, "连拍近似")
				} else {
					badges = append(badges, "重复构图")
				}
			}
		}
		candidates[i] = SimilarPhotoCandidate{
			AssetID:       m.assetID,
			Path:          m.relPath,
			Name:          path.Base(m.relPath),
			Size:          m.size,
			TakenAt:       effectiveTimestamp(m),
			Width:         m.width,
			Height:        m.height,
			Sharpness:     m.sharpness,
			QualityScore:  scores[i],
			Recommended:   recommended,
			QualityBadges: badges,
		}
	}

	return SimilarPhotoGroup{
		GroupID:            fmt.Sprintf("%s-%d", kind, best.assetID),
		Kind:               kind,
		TakenAt:            effectiveTimestamp(best),
		RecommendedAssetID: best.assetID,
		RecommendReason:    reason,
		ReclaimableBytes:   reclaimable,
		Items:              candidates,
	}
}

func scorePhotoCandidate(m rawFeatureRow) float32 {
	aestheticsNorm := (m.aesthetics + 1.0) * 0.5 // [-1, 1] -> [0, 1]
	resNorm := float32(math.Min(1.0, float64(m.width*m.height)/12_000_000.0))
	score := m.sharpness*0.38 + aestheticsNorm*0.32 + resNorm*0.10
	if m.faceCount > 0 {
		eyeFactor := m.minEyeOpen
		if eyeFactor < 0.25 {
			score -= 0.22 // Penalize closed-eye shots strongly.
		}
		score += (m.faceQuality*0.6 + eyeFactor*0.4) * 0.20
	} else {
		score += m.sharpness * 0.20
	}
	return score
}

func effectiveTimestamp(r rawFeatureRow) int64 {
	if r.takenAt > 0 {
		return r.takenAt
	}
	return r.modified / 1_000_000_000
}

func decodeFloat16Vector(raw []byte) ([]float32, bool) {
	if len(raw) < 16 || len(raw)%2 != 0 {
		return nil, false
	}
	n := len(raw) / 2
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = float16BitsToFloat32(binary.LittleEndian.Uint16(raw[i*2 : (i+1)*2]))
	}
	return out, true
}

func float16BitsToFloat32(h uint16) float32 {
	sign := uint32(h&0x8000) << 16
	exp := uint32(h>>10) & 0x1F
	mant := uint32(h & 0x03FF)
	switch exp {
	case 0:
		if mant == 0 {
			return math.Float32frombits(sign)
		}
		for (mant & 0x0400) == 0 {
			mant <<= 1
			exp--
		}
		exp++
		mant &= ^uint32(0x0400)
		return math.Float32frombits(sign | ((exp + (127 - 15)) << 23) | (mant << 13))
	case 31:
		return 0
	default:
		return math.Float32frombits(sign | ((exp + (127 - 15)) << 23) | (mant << 13))
	}
}

// LookupAssetForTrash verifies the asset belongs to the mounted share so server
// handlers can enforce write permissions and move selected waste shots to trash.
func (l *Library) LookupAssetForTrash(assetID int64) (Asset, error) {
	if assetID <= 0 {
		return Asset{}, sql.ErrNoRows
	}
	return l.Asset(assetID)
}

// ReconcileRemovedAsset immediately hides or removes an asset row once its
// underlying file has been moved to .lightisle-trash, preserving favorites and
// album memberships in missing_path so restoring from trash recovers them.
func (l *Library) ReconcileRemovedAsset(assetID int64) error {
	share, err := l.share()
	if err != nil {
		return err
	}
	asset, err := l.Asset(assetID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}
	if _, statErr := l.storage.Stat(asset.Path); !errors.Is(statErr, fs.ErrNotExist) {
		return nil
	}
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	protected := `(favorite<>0 OR EXISTS(SELECT 1 FROM personal_favorites WHERE asset_id=assets.id)
		OR EXISTS(SELECT 1 FROM album_items WHERE asset_id=assets.id)
		OR EXISTS(SELECT 1 FROM private_album_items WHERE asset_id=assets.id))`
	if _, err := tx.Exec(
		`UPDATE assets SET missing_path=path,missing_reason='missing',path='.lightisle-missing/'||id WHERE share=? AND id=? AND missing_path='' AND `+protected,
		share, assetID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM assets WHERE share=? AND id=? AND missing_path=''`, share, assetID); err != nil {
		return err
	}
	return tx.Commit()
}
