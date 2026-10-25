package cinema

import (
	"context"
	"os"

	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

// StartHLSSession starts (or joins) an HLS session. verified-direct sources
// are refused at the source quality — the plain stream endpoint is strictly
// better for them — but an explicit lower quality tier is allowed for any
// film, so directly playable sources can still be downscaled on demand.
func (l *Library) StartHLSSession(filmID int64, requestedStart float64, audioTrack int, quality string) (SessionInfo, error) {
	quality, err := NormalizeQuality(quality)
	if err != nil {
		return SessionInfo{}, err
	}
	film, err := l.Get(filmID, 0)
	if err != nil {
		return SessionInfo{}, err
	}
	if quality == "source" && film.BrowserPlayback == "verified-direct" {
		return SessionInfo{}, ErrInvalid
	}
	share, err := l.share()
	if err != nil {
		return SessionInfo{}, err
	}
	file, _, film, err := l.Read(filmID, 0)
	if err != nil {
		return SessionInfo{}, err
	}
	defer file.Close()
	return l.transcoder.Session(file, share, film, requestedStart, audioTrack, quality)
}

// HLSFile serves one playlist/init/segment file of a session that belongs to
// the requested film.
func (l *Library) HLSFile(filmID int64, sessionID, name string) (*os.File, os.FileInfo, string, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return nil, nil, "", err
	}
	share, err := l.share()
	if err != nil {
		return nil, nil, "", err
	}
	return l.transcoder.SessionFile(share, film, sessionID, name)
}

// FilmTracks reports audio and text-subtitle tracks from ffprobe. It works
// for any film: direct-playback clients use it for display, HLS clients use
// it to pick audio and subtitles.
func (l *Library) FilmTracks(filmID int64) (TrackInfo, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return TrackInfo{}, err
	}
	share, err := l.share()
	if err != nil {
		return TrackInfo{}, err
	}
	file, _, film, err := l.Read(filmID, 0)
	if err != nil {
		return TrackInfo{}, err
	}
	defer file.Close()
	return l.transcoder.ProbeTracks(file, share, film)
}

// EmbeddedSubtitleFile extracts (or replays from cache) one embedded text
// subtitle track as SRT/WebVTT on disk.
func (l *Library) EmbeddedSubtitleFile(filmID int64, streamIndex int) (*os.File, string, error) {
	film, err := l.Get(filmID, 0)
	if err != nil {
		return nil, "", err
	}
	share, err := l.share()
	if err != nil {
		return nil, "", err
	}
	file, _, film, err := l.Read(filmID, 0)
	if err != nil {
		return nil, "", err
	}
	defer file.Close()
	tracks, err := l.transcoder.ProbeTracks(file, share, film)
	if err != nil {
		return nil, "", err
	}
	for _, track := range tracks.Subtitles {
		if track.StreamIndex == streamIndex {
			return l.transcoder.ExtractSubtitle(file, share, film, track)
		}
	}
	return nil, "", ErrInvalid
}

// TranscodeStatus summarizes FFmpeg availability for the status endpoint.
// It never returns a fabricated "available" when the binary is missing.
func (l *Library) TranscodeStatus(ctx context.Context) (available bool, version string, reason string, activeSessions int) {
	version, err := l.transcoder.tools.Version(ctx)
	switch {
	case err == nil:
		return true, version, "", len(l.transcoder.snapshotSessions())
	case err == ffmpegbin.ErrNotInstalled:
		return false, "", "ffmpeg_not_installed", len(l.transcoder.snapshotSessions())
	default:
		return false, "", "ffmpeg_failed", len(l.transcoder.snapshotSessions())
	}
}
