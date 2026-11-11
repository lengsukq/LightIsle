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
	return l.StartHLSSessionReplacing(filmID, requestedStart, audioTrack, quality, "")
}

// StartHLSSessionReplacing behaves like StartHLSSession and, when
// replaceSessionID names a distinct active session of the same film, cancels
// that prior session immediately so scrubbing does not pin extra muxers.
func (l *Library) StartHLSSessionReplacing(filmID int64, requestedStart float64, audioTrack int, quality, replaceSessionID string) (SessionInfo, error) {
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
	session, err := l.transcoder.Session(file, share, film, requestedStart, audioTrack, quality, replaceSessionID)
	if err != nil {
		return SessionInfo{}, err
	}
	if cached, ok := l.transcoder.cachedTracks(share, film); ok {
		l.backfillFilmProbeFromTracks(share, film, cached)
	}
	return session, nil
}

// StopHLSSession cancels one HLS session belonging to filmID. Missing or
// already-evicted session IDs succeed idempotently.
func (l *Library) StopHLSSession(filmID int64, sessionID string) error {
	if sessionID == "" || len(sessionID) > 128 {
		return ErrInvalid
	}
	film, err := l.Get(filmID, 0)
	if err != nil {
		return err
	}
	share, err := l.share()
	if err != nil {
		return err
	}
	l.transcoder.CancelSession(share, film, sessionID)
	return nil
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
	tracks, err := l.transcoder.ProbeTracks(file, share, film)
	if err != nil {
		return TrackInfo{}, err
	}
	l.backfillFilmProbeFromTracks(share, film, tracks)
	return tracks, nil
}

func (t *Transcoder) cachedTracks(share string, film Film) (TrackInfo, bool) {
	t.probeMu.Lock()
	defer t.probeMu.Unlock()
	hit, ok := t.probeCache[identityKey(share, film)]
	return hit, ok
}

// backfillFilmProbeFromTracks persists container duration and stream dimensions
// discovered by ffprobe onto films that AVFoundation marked unsupported (such
// as Matroska), without altering probe_status or browser_playback.
func (l *Library) backfillFilmProbeFromTracks(share string, film Film, info TrackInfo) {
	if l.db == nil {
		return
	}
	audioCodec := ""
	if len(info.Audio) > 0 {
		audioCodec = info.Audio[0].Codec
	}
	needDuration := film.MediaDuration <= 0 && info.DurationSeconds > 0
	needVideo := (film.VideoCodec == "" && info.VideoCodec != "") || (film.Height <= 0 && info.Height > 0) || (film.Width <= 0 && info.Width > 0)
	needAudio := film.AudioCodec == "" && audioCodec != ""
	if !needDuration && !needVideo && !needAudio {
		return
	}
	_, _ = l.db.Exec(`UPDATE films SET
		duration_seconds = CASE WHEN duration_seconds <= 0 AND ? > 0 THEN ? ELSE duration_seconds END,
		width = CASE WHEN width <= 0 AND ? > 0 THEN ? ELSE width END,
		height = CASE WHEN height <= 0 AND ? > 0 THEN ? ELSE height END,
		video_codec = CASE WHEN video_codec = '' AND ? <> '' THEN ? ELSE video_codec END,
		audio_codec = CASE WHEN audio_codec = '' AND ? <> '' THEN ? ELSE audio_codec END
		WHERE share = ? AND id = ? AND path = ? AND size = ? AND modified = ? AND missing_path = ''`,
		info.DurationSeconds, info.DurationSeconds,
		info.Width, info.Width,
		info.Height, info.Height,
		info.VideoCodec, info.VideoCodec,
		audioCodec, audioCodec,
		share, film.ID, film.Path, film.Size, film.Modified)
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
