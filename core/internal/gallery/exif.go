package gallery

import (
	"github.com/rwcarlsen/goexif/exif"
	"io"
	"path/filepath"
	"strings"
	"time"
)

func (l *Library) CaptureTime(p string, fallback time.Time) time.Time {
	ext := strings.ToLower(filepath.Ext(p))
	if ext != ".jpg" && ext != ".jpeg" && ext != ".tif" && ext != ".tiff" {
		return fallback
	}
	f, _, err := l.storage.Read(p)
	if err != nil {
		return fallback
	}
	defer f.Close()
	parsed, err := exif.Decode(io.LimitReader(f, 16<<20))
	if err != nil {
		return fallback
	}
	moment, err := parsed.DateTime()
	if err != nil || moment.IsZero() {
		return fallback
	}
	return moment
}
