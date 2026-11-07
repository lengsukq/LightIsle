package gallery

import (
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// PhotoFacets summarizes distinct camera models and capture years available
// within the caller's authorized media roots.
type PhotoFacets struct {
	Cameras []string `json:"cameras"`
	Years   []int    `json:"years"`
}

func (l *Library) FacetsScoped(roots []string) (PhotoFacets, error) {
	share, err := l.share()
	if err != nil {
		return PhotoFacets{}, err
	}
	fragment, scopedArgs, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return PhotoFacets{}, err
	}
	args := append([]any{share}, scopedArgs...)

	camRows, err := l.db.Query(`SELECT DISTINCT trim(a.camera_model)
		FROM assets a
		WHERE a.share=? AND a.missing_path='' AND trim(a.camera_model)<>''`+fragment+`
		ORDER BY trim(a.camera_model) LIMIT 50`, args...)
	if err != nil {
		return PhotoFacets{}, err
	}
	defer camRows.Close()
	cameras := make([]string, 0)
	for camRows.Next() {
		var model string
		if err := camRows.Scan(&model); err != nil {
			return PhotoFacets{}, err
		}
		if model != "" {
			cameras = append(cameras, model)
		}
	}
	if err := camRows.Err(); err != nil {
		return PhotoFacets{}, err
	}

	yearRows, err := l.db.Query(`SELECT DISTINCT CAST(strftime('%Y', a.taken_at, 'unixepoch', 'localtime') AS INTEGER) AS yr
		FROM assets a
		WHERE a.share=? AND a.missing_path='' AND a.taken_at>0`+fragment+`
		ORDER BY yr DESC LIMIT 100`, args...)
	if err != nil {
		return PhotoFacets{}, err
	}
	defer yearRows.Close()
	years := make([]int, 0)
	for yearRows.Next() {
		var yr int
		if err := yearRows.Scan(&yr); err != nil {
			return PhotoFacets{}, err
		}
		if yr >= 1970 && yr <= 2100 {
			years = append(years, yr)
		}
	}
	if err := yearRows.Err(); err != nil {
		return PhotoFacets{}, err
	}
	return PhotoFacets{Cameras: cameras, Years: years}, nil
}
