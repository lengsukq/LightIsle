package cinema

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type mediaWorker interface {
	Probe(context.Context, *os.File, string) (mediaworker.Metadata, error)
}

type filmProbe struct {
	ProbeStatus     string
	BrowserPlayback string
	Container       string
	VideoCodec      string
	AudioCodec      string
	DurationSeconds float64
	Width           int
	Height          int
	CapturedAt      string
}

func ensureProbeColumns(db *sql.DB) error {
	columns := map[string]string{
		"probe_status":     `TEXT NOT NULL DEFAULT ''`,
		"browser_playback": `TEXT NOT NULL DEFAULT ''`,
		"container":        `TEXT NOT NULL DEFAULT ''`,
		"video_codec":      `TEXT NOT NULL DEFAULT ''`,
		"audio_codec":      `TEXT NOT NULL DEFAULT ''`,
		"duration_seconds": `REAL NOT NULL DEFAULT 0`,
		"width":            `INTEGER NOT NULL DEFAULT 0`,
		"height":           `INTEGER NOT NULL DEFAULT 0`,
		"captured_at":      `TEXT NOT NULL DEFAULT ''`,
	}
	rows, err := db.Query(`PRAGMA table_info(films)`)
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
		if _, err := db.Exec(`ALTER TABLE films ADD COLUMN ` + name + ` ` + declaration); err != nil {
			return err
		}
	}
	return nil
}

func (l *Library) SetMediaWorker(worker mediaWorker) { l.worker = worker }

func (l *Library) filmProbe(share, filmPath string) (filmProbe, int64, int64, bool) {
	var probe filmProbe
	var size, modified int64
	err := l.db.QueryRow(`SELECT size,modified,probe_status,browser_playback,container,video_codec,audio_codec,duration_seconds,width,height,captured_at
 FROM films WHERE share=? AND path=?`, share, filmPath).
		Scan(&size, &modified, &probe.ProbeStatus, &probe.BrowserPlayback, &probe.Container, &probe.VideoCodec,
			&probe.AudioCodec, &probe.DurationSeconds, &probe.Width, &probe.Height, &probe.CapturedAt)
	return probe, size, modified, err == nil
}

func (l *Library) probeFilm(ctx context.Context, filmPath, name string, size, modified int64, unchanged bool, old filmProbe) filmProbe {
	if unchanged && (old.ProbeStatus == "ready" || old.ProbeStatus == "unsupported") {
		return old
	}
	if l.worker == nil {
		return unavailableFilmProbe(name)
	}
	source, _, err := l.files.Read(filmPath)
	if err != nil {
		return failedFilmProbe()
	}
	defer source.Close()
	before, err := source.Stat()
	if err != nil || !before.Mode().IsRegular() || before.Size() != size || before.ModTime().UnixNano() != modified {
		return failedFilmProbe()
	}
	metadata, err := l.worker.Probe(ctx, source, name)
	after, statErr := source.Stat()
	if statErr != nil || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return failedFilmProbe()
	}
	if errors.Is(err, mediaworker.ErrUnsupported) {
		return filmProbe{ProbeStatus: "unsupported", BrowserPlayback: "download-only"}
	}
	if errors.Is(err, mediaworker.ErrUnavailable) {
		return unavailableFilmProbe(name)
	}
	if err != nil || metadata.Kind != "video" {
		return failedFilmProbe()
	}
	return filmProbe{
		ProbeStatus: "ready", BrowserPlayback: mediaworker.BrowserPlayback(name, metadata, true),
		Container: metadata.Container, VideoCodec: metadata.VideoCodec, AudioCodec: metadata.AudioCodec,
		DurationSeconds: metadata.DurationSeconds, Width: metadata.Width, Height: metadata.Height,
		CapturedAt: metadata.CapturedAt,
	}
}

func unavailableFilmProbe(name string) filmProbe {
	return filmProbe{
		ProbeStatus:     "unavailable",
		BrowserPlayback: mediaworker.BrowserPlayback(filepath.Base(name), mediaworker.Metadata{}, false),
	}
}

func failedFilmProbe() filmProbe {
	return filmProbe{ProbeStatus: "failed", BrowserPlayback: "download-only"}
}

func normalizedPlayback(path, playback string) string {
	switch playback {
	case "verified-direct", "unverified-direct", "download-only":
		return playback
	}
	return mediaworker.BrowserPlayback(path, mediaworker.Metadata{}, false)
}

func filmMime(path, probeStatus, browserPlayback, container string) string {
	if probeStatus == "ready" && browserPlayback == "verified-direct" {
		switch strings.ToLower(strings.TrimSpace(container)) {
		case "mp4", "mpeg-4", "mpeg4", "m4v":
			return "video/mp4"
		case "webm":
			return "video/webm"
		}
	}
	return FileMime(path)
}
