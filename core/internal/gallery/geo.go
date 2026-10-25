package gallery

import (
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// maxGeoPoints caps the map payload; total still reports the true located
// count so clients can label a truncated view honestly.
const maxGeoPoints = 20000

type GeoPoint struct {
	ID      int64   `json:"id"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	TakenAt int64   `json:"takenAt"`
	Type    string  `json:"type"`
}

// GeoScoped returns located assets newest-first. Paths stay out of the
// payload: the map only needs ids and coordinates to request thumbnails.
func (l *Library) GeoScoped(roots []string) (points []GeoPoint, total int, err error) {
	share, err := l.share()
	if err != nil {
		return nil, 0, err
	}
	fragment, args, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, 0, err
	}
	parameters := append([]any{share}, args...)
	if err := l.db.QueryRow(
		"SELECT COUNT(*) FROM assets a WHERE a.share=? AND a.gps_lat IS NOT NULL AND a.gps_lon IS NOT NULL"+fragment,
		parameters...).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := l.db.Query(
		"SELECT a.id,a.gps_lat,a.gps_lon,a.taken_at,a.type FROM assets a WHERE a.share=? AND a.gps_lat IS NOT NULL AND a.gps_lon IS NOT NULL"+fragment+
			" ORDER BY a.taken_at DESC,a.id DESC LIMIT ?",
		append(parameters, maxGeoPoints)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	points = []GeoPoint{}
	for rows.Next() {
		var point GeoPoint
		if err := rows.Scan(&point.ID, &point.Lat, &point.Lon, &point.TakenAt, &point.Type); err != nil {
			return nil, 0, err
		}
		points = append(points, point)
	}
	return points, total, rows.Err()
}
