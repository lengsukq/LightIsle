package cinema

import (
	"database/sql"
	"os"
	"path"
	"strings"
)

func subtitleLangSuffixes(lang string) ([]string, bool) {
	switch lang {
	case "":
		return []string{"", ".zh", ".chs", ".sc", ".zh-cn", ".zh-hans", ".cht", ".tc", ".zh-tw", ".zh-hant", ".en", ".eng"}, true
	case "zh":
		return []string{".zh", ".chs", ".sc", ".zh-cn", ".zh-hans", ".cht", ".tc", ".zh-tw", ".zh-hant", ""}, true
	case "en":
		return []string{".en", ".eng"}, true
	default:
		return nil, false
	}
}

func (l *Library) FindSubtitle(film Film, lang string) (*os.File, string, error) {
	suffixes, ok := subtitleLangSuffixes(lang)
	if !ok {
		return nil, "", ErrInvalid
	}
	ext := path.Ext(film.Path)
	stem := strings.TrimSuffix(film.Path, ext)
	formats := []string{".vtt", ".srt", ".ass", ".ssa"}
	for _, langSuffix := range suffixes {
		for _, format := range formats {
			candidate := stem + langSuffix + format
			f, info, err := l.files.Read(candidate)
			if err == nil {
				if info.Size() > 2<<20 {
					f.Close()
					return nil, "", ErrInvalid
				}
				return f, format, nil
			}
		}
	}
	return nil, "", sql.ErrNoRows
}
