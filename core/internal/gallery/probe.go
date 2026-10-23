package gallery

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type assetProbe struct {
	ProbeStatus     string
	BrowserPlayback string
	MIME            string
	Container       string
	VideoCodec      string
	AudioCodec      string
	DurationSeconds float64
	Width           int
	Height          int
	Orientation     int
	CapturedAt      string
}

var ErrAssetChanged = errors.New("asset_changed_rescan_required")

type mediaWorker interface {
	Probe(context.Context, *os.File, string) (mediaworker.Metadata, error)
	Poster(context.Context, *os.File, string, string) (mediaworker.Metadata, error)
}

func ensureGalleryProbeColumns(db *sql.DB) error {
	columns := map[string]string{
		"probe_status":     `TEXT NOT NULL DEFAULT ''`,
		"browser_playback": `TEXT NOT NULL DEFAULT ''`,
		"mime":             `TEXT NOT NULL DEFAULT ''`,
		"container":        `TEXT NOT NULL DEFAULT ''`,
		"video_codec":      `TEXT NOT NULL DEFAULT ''`,
		"audio_codec":      `TEXT NOT NULL DEFAULT ''`,
		"duration_seconds": `REAL NOT NULL DEFAULT 0`,
		"width":            `INTEGER NOT NULL DEFAULT 0`,
		"height":           `INTEGER NOT NULL DEFAULT 0`,
		"orientation":      `INTEGER NOT NULL DEFAULT 0`,
		"captured_at":      `TEXT NOT NULL DEFAULT ''`,
	}
	rows, err := db.Query(`PRAGMA table_info(assets)`)
	if err != nil {
		return err
	}
	existing := map[string]bool{}
	for rows.Next() {
		var cid, notnull, primary int
		var name, dataType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &dataType, &notnull, &defaultValue, &primary); err != nil {
			rows.Close()
			return err
		}
		existing[name] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for name, declaration := range columns {
		if existing[name] {
			continue
		}
		if _, err := db.Exec(`ALTER TABLE assets ADD COLUMN ` + name + ` ` + declaration); err != nil {
			return err
		}
	}
	return nil
}

func (l *Library) SetMediaWorker(worker mediaWorker) { l.worker = worker }

func (l *Library) operationContext(parent context.Context) (context.Context, context.CancelFunc) {
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	stop := context.AfterFunc(l.ctx, cancel)
	return ctx, func() {
		stop()
		cancel()
	}
}

func (l *Library) assetProbe(share, assetPath string) (assetProbe, int64, int64, int64, bool) {
	var probe assetProbe
	var modified, size, taken int64
	err := l.db.QueryRow(`SELECT modified,size,taken_at,probe_status,browser_playback,mime,container,video_codec,audio_codec,duration_seconds,width,height,orientation,captured_at
 FROM assets WHERE share=? AND path=?`, share, assetPath).
		Scan(&modified, &size, &taken, &probe.ProbeStatus, &probe.BrowserPlayback, &probe.MIME, &probe.Container,
			&probe.VideoCodec, &probe.AudioCodec, &probe.DurationSeconds, &probe.Width, &probe.Height, &probe.Orientation, &probe.CapturedAt)
	return probe, modified, size, taken, err == nil
}

func isWorkerPhoto(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".heic", ".heif":
		return true
	default:
		return false
	}
}

func (l *Library) probeAsset(ctx context.Context, assetPath, name, kind string, size, modified int64, unchanged bool, old assetProbe) assetProbe {
	needsProbe := kind == "video" || kind == "photo" && isWorkerPhoto(name)
	if !needsProbe {
		return assetProbe{}
	}
	if unchanged && (old.ProbeStatus == "ready" || old.ProbeStatus == "unsupported") {
		return old
	}
	if l.worker == nil {
		return unavailableProbe(name, kind)
	}
	source, _, err := l.storage.Read(assetPath)
	if err != nil {
		return failedProbe(name, kind)
	}
	defer source.Close()
	before, err := source.Stat()
	if err != nil || !before.Mode().IsRegular() || before.Size() != size || before.ModTime().UnixNano() != modified {
		return failedProbe(name, kind)
	}
	metadata, err := l.worker.Probe(ctx, source, name)
	after, statErr := source.Stat()
	if statErr != nil || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return failedProbe(name, kind)
	}
	if errors.Is(err, mediaworker.ErrUnsupported) {
		return assetProbe{ProbeStatus: "unsupported", BrowserPlayback: "download-only"}
	}
	if errors.Is(err, mediaworker.ErrUnavailable) {
		return unavailableProbe(name, kind)
	}
	if err != nil || metadata.Kind != kind {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return failedProbe(name, kind)
		}
		return failedProbe(name, kind)
	}
	result := assetProbe{
		ProbeStatus: "ready", MIME: metadata.MIME, Container: metadata.Container,
		VideoCodec: metadata.VideoCodec, AudioCodec: metadata.AudioCodec,
		DurationSeconds: metadata.DurationSeconds, Width: metadata.Width,
		Height: metadata.Height, Orientation: metadata.Orientation, CapturedAt: metadata.CapturedAt,
	}
	if kind == "video" {
		result.BrowserPlayback = mediaworker.BrowserPlayback(name, metadata, true)
	}
	return result
}

func unavailableProbe(name, kind string) assetProbe {
	probe := assetProbe{ProbeStatus: "unavailable"}
	if kind == "video" {
		probe.BrowserPlayback = mediaworker.BrowserPlayback(name, mediaworker.Metadata{}, false)
	}
	return probe
}

func failedProbe(name, kind string) assetProbe {
	probe := assetProbe{ProbeStatus: "failed"}
	if kind == "video" {
		probe.BrowserPlayback = "download-only"
	}
	return probe
}

func capturedAtUnix(value string) int64 {
	if value == "" {
		return 0
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return 0
	}
	return parsed.Unix()
}
