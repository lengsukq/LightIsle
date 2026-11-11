package cinema

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ProbeTracks runs ffprobe against the opened source and returns audio and
// text-subtitle tracks. Results are cached per film identity; a replaced or
// re-scanned film gets a new identity key automatically.
func (t *Transcoder) ProbeTracks(source *os.File, share string, film Film) (TrackInfo, error) {
	probePath, err := t.tools.FFprobe()
	if err != nil {
		return TrackInfo{}, err
	}
	key := identityKey(share, film)
	t.probeMu.Lock()
	if hit, ok := t.probeCache[key]; ok {
		t.probeMu.Unlock()
		return hit, nil
	}
	full := len(t.probeCache) >= probeCacheEntries
	t.probeMu.Unlock()
	if full {
		t.probeMu.Lock()
		t.probeCache = map[string]TrackInfo{}
		t.probeMu.Unlock()
	}

	if !tryMediaInspection() {
		return TrackInfo{}, ErrTranscodeBusy
	}
	defer func() { <-mediaInspectionSlots }()
	ctx, cancel := context.WithTimeout(t.ctx, probeTimeout)
	defer cancel()
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return TrackInfo{}, err
	}
	cmd := exec.CommandContext(ctx, probePath,
		"-v", "quiet", "-print_format", "json", "-show_streams", "-show_format",
		"-protocol_whitelist", "file", "-format_whitelist", videoInputFormats, "-i", "/dev/fd/3")
	cmd.ExtraFiles = []*os.File{source}
	buf := &limitedBuffer{limit: 1 << 20}
	cmd.Stdout = buf
	cmd.Stderr = &limitedBuffer{limit: 8 << 10}
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return TrackInfo{}, ErrTranscodeFailed
		}
		slog.Warn("ffprobe tracks failed", "error", err)
		return TrackInfo{}, fmt.Errorf("%w: ffprobe_failed", ErrTranscodeFailed)
	}
	info, err := parseTrackInfo(buf.Bytes())
	if err != nil {
		return TrackInfo{}, fmt.Errorf("%w: ffprobe_invalid_output", ErrTranscodeFailed)
	}
	t.probeMu.Lock()
	t.probeCache[key] = info
	t.probeMu.Unlock()
	return info, nil
}

type limitedBuffer struct {
	limit int
	data  []byte
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if len(b.data)+len(p) > b.limit {
		b.data = append(b.data, p[:max(0, b.limit-len(b.data))]...)
		return len(p), nil
	}
	b.data = append(b.data, p...)
	return len(p), nil
}

func (b *limitedBuffer) Bytes() []byte { return b.data }

type ffprobeOutput struct {
	Streams []struct {
		Index     int    `json:"index"`
		CodecName string `json:"codec_name"`
		CodecType string `json:"codec_type"`
		Channels  int    `json:"channels"`
		Width     int    `json:"width"`
		Height    int    `json:"height"`
		Duration  string `json:"duration"`
		Tags      struct {
			Language string `json:"language"`
			Title    string `json:"title"`
			Duration string `json:"DURATION"`
		} `json:"tags"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

func parseFFprobeDuration(raw string) float64 {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || strings.EqualFold(trimmed, "N/A") {
		return 0
	}
	if seconds, err := strconv.ParseFloat(trimmed, 64); err == nil && seconds > 0 && !isNaNOrInf(seconds) {
		return seconds
	}
	parts := strings.Split(trimmed, ":")
	if len(parts) != 3 {
		return 0
	}
	hours, errH := strconv.ParseFloat(parts[0], 64)
	minutes, errM := strconv.ParseFloat(parts[1], 64)
	seconds, errS := strconv.ParseFloat(parts[2], 64)
	if errH != nil || errM != nil || errS != nil || hours < 0 || minutes < 0 || seconds < 0 {
		return 0
	}
	total := hours*3600 + minutes*60 + seconds
	if total <= 0 || isNaNOrInf(total) {
		return 0
	}
	return total
}

func isNaNOrInf(v float64) bool { return v != v || v > 1e308 || v < -1e308 }

func parseTrackInfo(data []byte) (TrackInfo, error) {
	var out ffprobeOutput
	if err := json.Unmarshal(data, &out); err != nil {
		return TrackInfo{}, err
	}
	info := TrackInfo{Audio: []AudioTrack{}, Subtitles: []SubtitleTrack{}}
	audioIndex := 0
	var streamDuration float64
	for _, stream := range out.Streams {
		if d := parseFFprobeDuration(stream.Duration); d > streamDuration {
			streamDuration = d
		} else if d := parseFFprobeDuration(stream.Tags.Duration); d > streamDuration {
			streamDuration = d
		}
		switch stream.CodecType {
		case "video":
			if info.VideoCodec == "" {
				info.VideoCodec = stream.CodecName
				info.Width = stream.Width
				info.Height = stream.Height
			}
		case "audio":
			info.Audio = append(info.Audio, AudioTrack{
				StreamIndex: stream.Index, AudioIndex: audioIndex,
				Codec: stream.CodecName, Language: stream.Tags.Language,
				Title: stream.Tags.Title, Channels: stream.Channels,
			})
			audioIndex++
		case "subtitle":
			info.Subtitles = append(info.Subtitles, SubtitleTrack{
				StreamIndex: stream.Index,
				Codec:       stream.CodecName, Language: stream.Tags.Language,
				Title: stream.Tags.Title, Extractable: textSubtitleCodecs[stream.CodecName],
			})
		}
	}
	if seconds := parseFFprobeDuration(out.Format.Duration); seconds > 0 {
		info.DurationSeconds = seconds
	} else if streamDuration > 0 {
		info.DurationSeconds = streamDuration
	}
	return info, nil
}

// CancelSession stops and removes one session owned by the given film identity.
func (t *Transcoder) CancelSession(share string, film Film, sessionID string) bool {
	if sessionID == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	s, ok := t.sessions[sessionID]
	if !ok || !sameSessionFilm(s, share, film) {
		return false
	}
	t.removeLocked(sessionID, s)
	return true
}

func sameSessionFilm(s *session, share string, film Film) bool {
	return s.share == share && s.film.Path == film.Path && s.film.Size == film.Size && s.film.Modified == film.Modified
}

// evictOldestRunningSameFilm frees one active muxer slot held by an earlier
// seek of the exact same film so rapid scrubbing does not fail with busy.
func (t *Transcoder) evictOldestRunningSameFilm(share string, film Film, keepID string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	oldestID := ""
	var oldestAccess int64 = 1<<63 - 1
	for id, s := range t.sessions {
		if id == keepID || !sameSessionFilm(s, share, film) {
			continue
		}
		select {
		case <-s.done:
			continue
		default:
		}
		if access := s.lastAccess.Load(); access < oldestAccess {
			oldestAccess, oldestID = access, id
		}
	}
	if oldestID == "" {
		return false
	}
	t.removeLocked(oldestID, t.sessions[oldestID])
	return true
}

// ExtractSubtitle extracts one embedded text subtitle to the regenerable
// subtitle cache and returns the cached file. ffmpeg converts mov_text and
// ASS to SRT on the fly; WebVTT sources pass through untouched.
func (t *Transcoder) ExtractSubtitle(source *os.File, share string, film Film, track SubtitleTrack) (*os.File, string, error) {
	if !track.Extractable {
		return nil, "", ErrSubtitleExtract
	}
	bin, err := t.tools.FFmpeg()
	if err != nil {
		return nil, "", err
	}
	subsDir := filepath.Join(t.cacheDir, "subs")
	if err := os.MkdirAll(subsDir, 0o700); err != nil {
		return nil, "", err
	}
	extension := ".srt"
	if track.Codec == "webvtt" {
		extension = ".vtt"
	}
	target := filepath.Join(subsDir, identityKey(share, film)+"-"+strconv.Itoa(track.StreamIndex)+extension)
	if file, err := os.Open(target); err == nil {
		if info, statErr := file.Stat(); statErr == nil && info.Size() > 0 && info.Size() <= maxSubtitleBytes {
			return file, extension, nil
		}
		file.Close()
		_ = os.Remove(target)
	}
	if !tryMediaInspection() {
		return nil, "", ErrTranscodeBusy
	}
	defer func() { <-mediaInspectionSlots }()
	if err := t.checkSpace(4 << 20); err != nil {
		return nil, "", err
	}
	stage, err := os.CreateTemp(subsDir, ".subtitle-*.tmp")
	if err != nil {
		return nil, "", err
	}
	tmp := stage.Name()
	defer os.Remove(tmp)
	if err := stage.Close(); err != nil {
		return nil, "", err
	}
	ctx, cancel := context.WithTimeout(t.ctx, subtitleTimeout)
	defer cancel()
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return nil, "", err
	}
	format := "srt"
	if extension == ".vtt" {
		format = "webvtt"
	}
	cmd := exec.CommandContext(ctx, bin,
		"-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-protocol_whitelist", "file", "-format_whitelist", videoInputFormats, "-i", "/dev/fd/3",
		"-map", fmt.Sprintf("0:%d", track.StreamIndex),
		"-f", format,
		tmp)
	cmd.ExtraFiles = []*os.File{source}
	cmd.WaitDelay = 5 * time.Second
	cmd.Stderr = &limitedBuffer{limit: 8 << 10}
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, "", fmt.Errorf("%w: timeout", ErrSubtitleExtract)
		}
		slog.Warn("subtitle extraction failed", "error", err)
		return nil, "", ErrSubtitleExtract
	}
	info, err := os.Stat(tmp)
	if err != nil || !info.Mode().IsRegular() {
		return nil, "", ErrSubtitleExtract
	}
	if info.Size() > maxSubtitleBytes {
		return nil, "", ErrSubtitleTooLarge
	}
	if err := os.Rename(tmp, target); err != nil {
		return nil, "", ErrSubtitleExtract
	}
	file, err := os.Open(target)
	if err != nil {
		return nil, "", ErrSubtitleExtract
	}
	return file, extension, nil
}
