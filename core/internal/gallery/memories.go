package gallery

import (
	"database/sql"
	"fmt"
	"sort"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// MemoryCollection represents a dynamically clustered photo/video highlight card
// (weekend footprints, travel bursts, Live Photo moments, or yearly highlights)
// strictly scoped to the caller's authorized roots with zero file duplication.
type MemoryCollection struct {
	ID           string  `json:"id"`
	Kind         string  `json:"kind"` // "trip" | "weekend" | "live" | "yearly"
	Title        string  `json:"title"`
	Subtitle     string  `json:"subtitle"`
	Count        int     `json:"count"`
	CoverAssetID int64   `json:"coverAssetId"`
	AssetIDs     []int64 `json:"assetIds,omitempty"`
	TakenFrom    int64   `json:"takenFrom,omitempty"`
	TakenTo      int64   `json:"takenTo,omitempty"`
}

type memorySeedRow struct {
	id          int64
	takenAt     int64
	favorite    bool
	hasLocation bool
	isLive      bool
}

// MemoriesScoped builds up to 8 smart memory highlight cards from the caller's
// readable timeline assets.
func (l *Library) MemoriesScoped(userID int64, roots []string) ([]MemoryCollection, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	args := make([]any, 0, len(scopedArgs)+2)
	args = append(args, userID, share)
	args = append(args, scopedArgs...)

	rows, err := l.readDB().Query(`
		SELECT a.id, a.taken_at,
		       (CASE WHEN a.favorite<>0 OR EXISTS(SELECT 1 FROM personal_favorites pf WHERE pf.user_id=? AND pf.asset_id=a.id) THEN 1 ELSE 0 END) AS fav,
		       (CASE WHEN a.gps_lat IS NOT NULL THEN 1 ELSE 0 END) AS has_geo,
		       (CASE WHEN a.live_video_asset_id>0 THEN 1 ELSE 0 END) AS is_live
		FROM assets a
		WHERE a.share=? AND a.missing_path='' AND a.is_live_companion=0`+fragment+`
		ORDER BY a.taken_at DESC, a.id DESC
		LIMIT 2400`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []memorySeedRow
	for rows.Next() {
		var r memorySeedRow
		var fav, geo, live int
		if err := rows.Scan(&r.id, &r.takenAt, &fav, &geo, &live); err != nil {
			return nil, err
		}
		r.favorite = fav != 0
		r.hasLocation = geo != 0
		r.isLive = live != 0
		items = append(items, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return []MemoryCollection{}, nil
	}

	out := make([]MemoryCollection, 0, 8)

	// 1. Live Photo Moments ("实况动态瞬间")
	var liveIDs []int64
	var liveCover int64
	for _, it := range items {
		if it.isLive {
			if liveCover == 0 || (it.favorite && len(liveIDs) < 6) {
				liveCover = it.id
			}
			if len(liveIDs) < 120 {
				liveIDs = append(liveIDs, it.id)
			}
		}
	}
	if len(liveIDs) > 0 {
		out = append(out, MemoryCollection{
			ID:           "live-moments",
			Kind:         "live",
			Title:        "实况鲜活瞬间",
			Subtitle:     fmt.Sprintf("%d 张动态实况照片", len(liveIDs)),
			Count:        len(liveIDs),
			CoverAssetID: liveCover,
			AssetIDs:     liveIDs,
		})
	}

	// 2. Contiguous Weekend / Trip Bursts (>= 4 photos within 36h gaps)
	type burstCluster struct {
		rows     []memorySeedRow
		geoCount int
		favCover int64
	}
	var bursts []burstCluster
	var current burstCluster
	for _, it := range items {
		if it.takenAt <= 0 {
			continue
		}
		if len(current.rows) == 0 {
			current = burstCluster{rows: []memorySeedRow{it}}
			if it.hasLocation {
				current.geoCount = 1
			}
			if it.favorite {
				current.favCover = it.id
			}
			continue
		}
		prev := current.rows[len(current.rows)-1]
		if prev.takenAt-it.takenAt <= int64((36 * time.Hour).Seconds()) {
			current.rows = append(current.rows, it)
			if it.hasLocation {
				current.geoCount++
			}
			if it.favorite && current.favCover == 0 {
				current.favCover = it.id
			}
		} else {
			if len(current.rows) >= 4 {
				bursts = append(bursts, current)
			}
			current = burstCluster{rows: []memorySeedRow{it}}
			if it.hasLocation {
				current.geoCount = 1
			}
			if it.favorite {
				current.favCover = it.id
			}
		}
	}
	if len(current.rows) >= 4 {
		bursts = append(bursts, current)
	}

	sort.SliceStable(bursts, func(i, j int) bool {
		scoreI := len(bursts[i].rows) + bursts[i].geoCount*2
		scoreJ := len(bursts[j].rows) + bursts[j].geoCount*2
		return scoreI > scoreJ
	})

	for idx, b := range bursts {
		if idx >= 4 {
			break
		}
		latest := b.rows[0].takenAt
		earliest := b.rows[len(b.rows)-1].takenAt
		tStart := time.Unix(earliest, 0)
		tEnd := time.Unix(latest, 0)
		kind := "weekend"
		label := fmt.Sprintf("%d年%d月 周末拾光", tStart.Year(), int(tStart.Month()))
		if b.geoCount >= 2 {
			kind = "trip"
			label = fmt.Sprintf("%d.%02d.%02d 足迹漫游", tStart.Year(), int(tStart.Month()), tStart.Day())
		}
		cover := b.rows[0].id
		if b.favCover > 0 {
			cover = b.favCover
		}
		ids := make([]int64, 0, min(len(b.rows), 120))
		for _, r := range b.rows {
			if len(ids) >= 120 {
				break
			}
			ids = append(ids, r.id)
		}
		sub := fmt.Sprintf("%d月%d日 · %d 项影像", int(tStart.Month()), tStart.Day(), len(b.rows))
		if tStart.YearDay() != tEnd.YearDay() {
			sub = fmt.Sprintf("%d月%d日–%d月%d日 · %d 项影像", int(tStart.Month()), tStart.Day(), int(tEnd.Month()), tEnd.Day(), len(b.rows))
		}
		out = append(out, MemoryCollection{
			ID:           fmt.Sprintf("burst-%d-%d", earliest, latest),
			Kind:         kind,
			Title:        label,
			Subtitle:     sub,
			Count:        len(b.rows),
			CoverAssetID: cover,
			AssetIDs:     ids,
			TakenFrom:    earliest,
			TakenTo:      latest,
		})
	}

	// 3. Yearly Growth Highlights ("年度回忆")
	type yearBucket struct {
		year     int
		count    int
		coverID  int64
		fromUnix int64
		toUnix   int64
	}
	byYear := make(map[int]*yearBucket)
	var years []int
	for _, it := range items {
		if it.takenAt <= 0 {
			continue
		}
		y := time.Unix(it.takenAt, 0).Year()
		if y < 1990 || y > 2100 {
			continue
		}
		yb := byYear[y]
		if yb == nil {
			loc := time.Now().Location()
			yb = &yearBucket{
				year:     y,
				coverID:  it.id,
				fromUnix: time.Date(y, 1, 1, 0, 0, 0, 0, loc).Unix(),
				toUnix:   time.Date(y, 12, 31, 23, 59, 59, 0, loc).Unix(),
			}
			byYear[y] = yb
			years = append(years, y)
		}
		yb.count++
		if it.favorite {
			yb.coverID = it.id
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(years)))
	for _, y := range years {
		if len(out) >= 8 {
			break
		}
		yb := byYear[y]
		if yb.count < 3 {
			continue
		}
		out = append(out, MemoryCollection{
			ID:           fmt.Sprintf("year-%d", y),
			Kind:         "yearly",
			Title:        fmt.Sprintf("%d 年度回忆", y),
			Subtitle:     fmt.Sprintf("全年收录 %d 项珍贵影像", yb.count),
			Count:        yb.count,
			CoverAssetID: yb.coverID,
			TakenFrom:    yb.fromUnix,
			TakenTo:      yb.toUnix,
		})
	}
	return out, nil
}

// Ensure sql import stays referenced if extended.
var _ = sql.ErrNoRows
