package gallery

import (
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// TimelineMonth is a date jump target across the entire authorized root.
// FirstIndex uses the same taken_at DESC cursor ordering as ListScoped.
// Do not expose any filesystem path, file name or private album metadata.
type TimelineMonth struct {
	Year       int `json:"year"`
	Month      int `json:"month"`
	Count      int `json:"count"`
	FirstIndex int `json:"firstIndex"`
}

func (l *Library) TimelineScoped(roots []string) ([]TimelineMonth, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	fragment, scoped, err := mediascope.Clause("a.path", roots)
	if err != nil {
		return nil, err
	}
	args := append([]any{share}, scoped...)
	rows, err := l.db.Query(
		"SELECT CAST(strftime('%Y',a.taken_at,'unixepoch','localtime') AS INTEGER),"+
			"CAST(strftime('%m',a.taken_at,'unixepoch','localtime') AS INTEGER),"+
			"COUNT(*) FROM assets a WHERE a.share=? AND a.taken_at>0"+fragment+
			" GROUP BY 1,2 ORDER BY 1 DESC,2 DESC LIMIT 2400",
		args...,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	months := []TimelineMonth{}
	offset := 0
	for rows.Next() {
		var item TimelineMonth
		if err := rows.Scan(&item.Year, &item.Month, &item.Count); err != nil {
			return nil, err
		}
		if item.Year < 1900 || item.Year > 9999 || item.Month < 1 || item.Month > 12 {
			// Invalid capture dates must never become navigation targets.
			offset += item.Count
			continue
		}
		item.FirstIndex = offset
		offset += item.Count
		months = append(months, item)
	}
	return months, rows.Err()
}
