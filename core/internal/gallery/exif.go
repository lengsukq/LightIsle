package gallery

import (
	"encoding/json"
	"io"
	"math"
	"path/filepath"
	"strings"
	"time"

	"github.com/rwcarlsen/goexif/exif"
)

// exifSchemaVersion marks which extraction pass last populated the capture
// columns. Bumping it makes existing rows eligible for the background backfill
// even when mtime+size are unchanged.
const exifSchemaVersion = 2

// captureExif is the in-process extraction result for JPEG/TIFF files. The
// native worker reports the same fields for other formats; (0,0) coordinates
// are treated as absent everywhere.
type captureExif struct {
	CapturedAt   time.Time
	HasTime      bool
	Latitude     float64
	Longitude    float64
	HasLocation  bool
	CameraMake   string
	CameraModel  string
	LensModel    string
	ISO          int
	FNumber      float64
	ExposureSecs float64
	FocalLength  float64
}

// exifDecodable reports whether the in-process decoder understands the
// container. Everything else (HEIC, WebP, PNG eXIf, video) is handled by the
// native worker probe.
func exifDecodable(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".jpeg", ".tif", ".tiff":
		return true
	}
	return false
}

func decodeCaptureExif(p string, read func(string) (io.ReadCloser, error)) (captureExif, bool) {
	if !exifDecodable(p) {
		return captureExif{}, false
	}
	f, err := read(p)
	if err != nil {
		return captureExif{}, false
	}
	defer f.Close()
	parsed, err := exif.Decode(io.LimitReader(f, 16<<20))
	if err != nil {
		return captureExif{}, false
	}
	return exifFromTags(parsed), true
}

// exifDetails is the JSON payload stored in assets.exif_json and flattened
// into API responses. Lens and exposure fields live here rather than as
// columns because they are display-only.
type exifDetails struct {
	LensModel       string  `json:"lensModel,omitempty"`
	ISO             int     `json:"iso,omitempty"`
	FNumber         float64 `json:"fNumber,omitempty"`
	ExposureSeconds float64 `json:"exposureSeconds,omitempty"`
	FocalLength     float64 `json:"focalLength,omitempty"`
}

func captureDetailsJSON(details exifDetails) string {
	if details == (exifDetails{}) {
		return ""
	}
	encoded, err := json.Marshal(details)
	if err != nil {
		return ""
	}
	return string(encoded)
}

func (c captureExif) detailsJSON() string {
	return captureDetailsJSON(exifDetails{
		LensModel: c.LensModel, ISO: c.ISO, FNumber: c.FNumber,
		ExposureSeconds: c.ExposureSecs, FocalLength: c.FocalLength,
	})
}

func decodeExifDetails(value string) exifDetails {
	var details exifDetails
	if value == "" {
		return details
	}
	_ = json.Unmarshal([]byte(value), &details)
	return details
}

func exifFromTags(parsed *exif.Exif) captureExif {
	var out captureExif
	if moment, err := parsed.DateTime(); err == nil && !moment.IsZero() {
		out.CapturedAt = moment
		out.HasTime = true
	}
	if lat, lon, err := parsed.LatLong(); err == nil && validCoordinate(lat, lon) {
		out.Latitude, out.Longitude, out.HasLocation = lat, lon, true
	}
	out.CameraMake = tagString(parsed, exif.Make)
	out.CameraModel = tagString(parsed, exif.Model)
	out.LensModel = tagString(parsed, exif.LensModel)
	out.ISO = tagInt(parsed, exif.ISOSpeedRatings)
	out.FNumber = tagRational(parsed, exif.FNumber)
	out.ExposureSecs = tagRational(parsed, exif.ExposureTime)
	out.FocalLength = tagRational(parsed, exif.FocalLength)
	return out
}

func validCoordinate(lat, lon float64) bool {
	if lat == 0 && lon == 0 {
		return false
	}
	return math.Abs(lat) <= 90 && math.Abs(lon) <= 180
}

func tagString(parsed *exif.Exif, field exif.FieldName) string {
	tag, err := parsed.Get(field)
	if err != nil || tag == nil {
		return ""
	}
	value, err := tag.StringVal()
	if err != nil {
		return ""
	}
	value = strings.TrimSpace(value)
	if len(value) > 128 {
		return ""
	}
	return value
}

func tagInt(parsed *exif.Exif, field exif.FieldName) int {
	tag, err := parsed.Get(field)
	if err != nil || tag == nil {
		return 0
	}
	value, err := tag.Int(0)
	if err != nil || value < 0 || value > 1<<20 {
		return 0
	}
	return value
}

func tagRational(parsed *exif.Exif, field exif.FieldName) float64 {
	tag, err := parsed.Get(field)
	if err != nil || tag == nil {
		return 0
	}
	value, err := tag.Rat(0)
	if err != nil {
		return 0
	}
	result, _ := value.Float64()
	if result < 0 || result > 3600 {
		return 0
	}
	return result
}
