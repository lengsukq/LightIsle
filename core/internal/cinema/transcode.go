package cinema

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

// Reason codes are stable machine strings; web and native clients map them
// to localized explanations. Nothing here fakes success: when FFmpeg is
// absent the HTTP surface reports transcode_unavailable and clients keep the
// existing download + external player guidance.
var (
	ErrTranscodeUnavailable = errors.New("transcode_unavailable")
	ErrTranscodeBusy        = errors.New("transcode_busy")
	ErrTranscodeFailed      = errors.New("transcode_failed")
	ErrTranscodeSpace       = errors.New("transcode_insufficient_space")
	ErrSubtitleExtract      = errors.New("subtitle_extract_failed")
	ErrSubtitleTooLarge     = errors.New("subtitle_too_large")
)

const (
	hlsSegmentSeconds  = 4
	sessionStartBucket = 4
	idleSessionTTL     = 5 * time.Minute
	sweepInterval      = time.Minute
	maxSessions        = 6
	defaultConcurrency = 2
	slotWaitTimeout    = 3 * time.Second
	probeTimeout       = 30 * time.Second
	subtitleTimeout    = 3 * time.Minute
	maxSubtitleBytes   = 2 << 20
	spaceReserveBytes  = int64(64 << 20)
	maxSourceDuration  = 86400 * 48
	probeCacheEntries  = 128
)

// HLS file names produced by the muxer. Anything else in a session directory
// is never served.
var hlsFileRule = regexp.MustCompile(`^(?:index\.m3u8|init\.mp4|segment_[0-9]{5}\.m4s)$`)

// Text subtitle codecs ffprobe can report. Bitmap subtitles (PGS, DVB) stay
// listed but are marked extractable=false instead of failing mid-request.
var textSubtitleCodecs = map[string]bool{
	"subrip": true, "srt": true, "ass": true, "ssa": true,
	"mov_text": true, "webvtt": true, "text": true,
}

// Video codecs every HLS-capable browser can decode when copied into fMP4.
// Everything else must be re-encoded.
func videoCopyable(codec string) bool {
	switch codec {
	case "h264", "avc", "hevc", "hvc1":
		return true
	}
	return false
}

// Audio codecs that survive a copy into fMP4/HLS on Safari and Chromium.
// DTS/AC3/PCM and friends are re-encoded to AAC instead of producing a
// stream some clients cannot play.
func audioCopyable(codec string) bool {
	switch codec {
	case "aac", "mp3", "opus":
		return true
	}
	return false
}

type AudioTrack struct {
	StreamIndex int    `json:"streamIndex"`
	AudioIndex  int    `json:"audioIndex"`
	Codec       string `json:"codec,omitempty"`
	Language    string `json:"language,omitempty"`
	Title       string `json:"title,omitempty"`
	Channels    int    `json:"channels,omitempty"`
}

type SubtitleTrack struct {
	StreamIndex int    `json:"streamIndex"`
	Codec       string `json:"codec,omitempty"`
	Language    string `json:"language,omitempty"`
	Title       string `json:"title,omitempty"`
	Extractable bool   `json:"extractable"`
}

type TrackInfo struct {
	VideoCodec      string          `json:"videoCodec,omitempty"`
	Height          int             `json:"height,omitempty"`
	DurationSeconds float64         `json:"durationSeconds,omitempty"`
	Audio           []AudioTrack    `json:"audio"`
	Subtitles       []SubtitleTrack `json:"subtitles"`
}

type SessionInfo struct {
	ID         string  `json:"sessionId"`
	Start      float64 `json:"start"`
	Profile    string  `json:"profile"` // remux | transcode
	AudioTrack int     `json:"audioTrack"`
	Quality    string  `json:"quality"` // source | 1080 | 720 | 480
	Ready      bool    `json:"ready"`
}

// Quality tiers for on-demand transcoding. An empty value and "source" both
// mean "keep the source resolution"; the numeric tiers request a scaled
// transcode capped by the source height.
var qualityHeights = map[string]int{"source": 0, "1080": 1080, "720": 720, "480": 480}

// NormalizeQuality validates the client-supplied tier and maps "" to source.
func NormalizeQuality(quality string) (string, error) {
	if quality == "" {
		return "source", nil
	}
	if _, ok := qualityHeights[quality]; !ok {
		return "", ErrInvalid
	}
	return quality, nil
}

// targetHeightFor reports the scaled long-edge ceiling for a tier, or 0 when
// the source profile applies (tier at or above the source height).
func targetHeightFor(quality string, sourceHeight int) int {
	ceiling, ok := qualityHeights[quality]
	if !ok || ceiling == 0 || sourceHeight <= 0 || sourceHeight <= ceiling {
		return 0
	}
	return ceiling
}

type session struct {
	id         string
	dir        string
	share      string
	film       Film
	profile    string
	audioTrack int
	quality    string
	start      float64
	cancel     context.CancelFunc
	done       chan struct{}
	exitErr    error
	lastAccess atomic.Int64
	// written flips once index.m3u8 exists so a failed muxer is reported as
	// a failure instead of an endless "not ready".
	written atomic.Bool
}

type Transcoder struct {
	cacheDir string
	tools    *ffmpegbin.Tools

	mu       sync.Mutex
	sessions map[string]*session
	slots    chan struct{}

	probeMu    sync.Mutex
	probeCache map[string]TrackInfo

	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	detachWG sync.WaitGroup
}

func NewTranscoder(cacheDir string, tools *ffmpegbin.Tools) *Transcoder {
	if tools == nil {
		tools = ffmpegbin.New()
	}
	ctx, cancel := context.WithCancel(context.Background())
	t := &Transcoder{
		cacheDir:   cacheDir,
		tools:      tools,
		sessions:   map[string]*session{},
		slots:      make(chan struct{}, defaultConcurrency),
		probeCache: map[string]TrackInfo{},
		ctx:        ctx,
		cancel:     cancel,
	}
	// Sessions are regenerable caches; anything left from a previous Core
	// process has no owner anymore.
	_ = os.RemoveAll(cacheDir)
	t.wg.Add(1)
	go t.sweep()
	return t
}

func (t *Transcoder) Close() {
	t.cancel()
	t.mu.Lock()
	sessions := make([]*session, 0, len(t.sessions))
	for _, s := range t.sessions {
		sessions = append(sessions, s)
	}
	t.mu.Unlock()
	for _, s := range sessions {
		s.cancel()
		<-s.done
	}
	t.wg.Wait()
	// Evicted sessions detached by removeLocked also die with t.ctx; wait
	// for their cleanup goroutines to keep tests deterministic.
	t.detachWG.Wait()
}

func (t *Transcoder) sweep() {
	defer t.wg.Done()
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-t.ctx.Done():
			return
		case <-ticker.C:
			t.evictIdle()
		}
	}
}

func (t *Transcoder) evictIdle() {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	for id, s := range t.sessions {
		if now.UnixNano()-s.lastAccess.Load() > idleSessionTTL.Nanoseconds() {
			t.removeLocked(id, s)
		}
	}
	// A hard cap keeps a runaway client from pinning unbounded sessions.
	for len(t.sessions) > maxSessions {
		oldestID := ""
		var oldest int64 = math.MaxInt64
		for id, s := range t.sessions {
			if at := s.lastAccess.Load(); at < oldest {
				oldest, oldestID = at, id
			}
		}
		if oldestID == "" {
			break
		}
		t.removeLocked(oldestID, t.sessions[oldestID])
	}
}

// removeLocked detaches the session and kills its muxer without holding
// t.mu through the kill, so playlist and segment requests never stall behind
// an eviction. The regenerable directory is removed once the muxer exits.
func (t *Transcoder) removeLocked(id string, s *session) {
	delete(t.sessions, id)
	s.cancel()
	t.detachWG.Add(1)
	go func() {
		defer t.detachWG.Done()
		<-s.done
		_ = os.RemoveAll(s.dir)
	}()
}

func sessionKey(share string, film Film, profile string, audioTrack int, quality string, start float64) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%d|%d|%s|%d|%s|%.3f",
		share, film.Path, film.Size, film.Modified, profile, audioTrack, quality, start)))
	return hex.EncodeToString(hash[:])
}

func identityKey(share string, film Film) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%d|%d", share, film.Path, film.Size, film.Modified)))
	return hex.EncodeToString(hash[:16])
}

func bucketStart(start float64) float64 {
	if start < 0 {
		return 0
	}
	return math.Floor(start/sessionStartBucket) * sessionStartBucket
}

// bitrateForVideo picks a VideoToolbox target rate from the source height.
func bitrateForVideo(height int) string {
	switch {
	case height <= 0:
		return "4M"
	case height <= 480:
		return "1200k"
	case height <= 720:
		return "2500k"
	case height <= 1080:
		return "5M"
	case height <= 1440:
		return "9M"
	default:
		return "16M"
	}
}

func bitrateNumber(bitrate string) float64 {
	switch {
	case strings.HasSuffix(bitrate, "M"):
		if value, err := strconv.ParseFloat(strings.TrimSuffix(bitrate, "M"), 64); err == nil {
			return value * 1_000_000
		}
	case strings.HasSuffix(bitrate, "k"):
		if value, err := strconv.ParseFloat(strings.TrimSuffix(bitrate, "k"), 64); err == nil {
			return value * 1000
		}
	}
	return 5_000_000
}

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

	ctx, cancel := context.WithTimeout(t.ctx, probeTimeout)
	defer cancel()
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return TrackInfo{}, err
	}
	cmd := exec.CommandContext(ctx, probePath,
		"-v", "quiet", "-print_format", "json", "-show_streams", "-show_format",
		"-i", "/dev/fd/3")
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
		Height    int    `json:"height"`
		Tags      struct {
			Language string `json:"language"`
			Title    string `json:"title"`
		} `json:"tags"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

func parseTrackInfo(data []byte) (TrackInfo, error) {
	var out ffprobeOutput
	if err := json.Unmarshal(data, &out); err != nil {
		return TrackInfo{}, err
	}
	info := TrackInfo{Audio: []AudioTrack{}, Subtitles: []SubtitleTrack{}}
	audioIndex := 0
	for _, stream := range out.Streams {
		switch stream.CodecType {
		case "video":
			if info.VideoCodec == "" {
				info.VideoCodec = stream.CodecName
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
	if seconds, err := strconv.ParseFloat(strings.TrimSpace(out.Format.Duration), 64); err == nil && seconds > 0 {
		info.DurationSeconds = seconds
	}
	return info, nil
}

// Session validates the request against a fresh ffprobe of the opened
// source, then starts (or joins) the HLS muxer. The source file may be
// closed once this returns; the muxer child keeps its own duplicated
// descriptor. Clients poll the playlist for readiness.
func (t *Transcoder) Session(source *os.File, share string, film Film, requestedStart float64, audioTrack int, quality string) (SessionInfo, error) {
	quality, err := NormalizeQuality(quality)
	if err != nil {
		return SessionInfo{}, err
	}
	if _, err := t.tools.FFmpeg(); err != nil {
		return SessionInfo{}, err // ErrNotInstalled → transcode_unavailable
	}
	info, err := t.ProbeTracks(source, share, film)
	if err != nil {
		return SessionInfo{}, err
	}
	duration := film.MediaDuration
	if info.DurationSeconds > 0 {
		duration = info.DurationSeconds
	}
	if requestedStart < 0 || requestedStart > maxSourceDuration ||
		(duration > 0 && requestedStart >= duration) {
		return SessionInfo{}, ErrInvalid
	}
	if len(info.Audio) == 0 {
		audioTrack = -1
	} else if audioTrack < 0 {
		audioTrack = 0
	} else if audioTrack >= len(info.Audio) {
		return SessionInfo{}, ErrInvalid
	}
	profile, videoCopy, audioCopy, tagHevc := decideProfile(info)
	targetHeight := targetHeightFor(quality, info.Height)
	if targetHeight > 0 {
		// A scaled tier is always a re-encode, whatever the source is.
		profile, videoCopy, tagHevc = "transcode", false, false
		audioCopy = false
	}

	start := bucketStart(requestedStart)
	if duration > 0 && start >= duration {
		start = math.Max(0, duration-hlsSegmentSeconds)
	}
	key := sessionKey(share, film, profile, audioTrack, quality, start)

	t.mu.Lock()
	if existing, ok := t.sessions[key]; ok {
		existing.lastAccess.Store(time.Now().UnixNano())
		t.mu.Unlock()
		return sessionInfo(existing), nil
	}
	dir := filepath.Join(t.cacheDir, key)
	sessionCtx, cancel := context.WithCancel(t.ctx)
	s := &session{
		id: key, dir: dir, share: share, film: film,
		profile: profile, audioTrack: audioTrack, quality: quality, start: start,
		cancel: cancel, done: make(chan struct{}),
	}
	s.lastAccess.Store(time.Now().UnixNano())
	t.sessions[key] = s
	t.mu.Unlock()

	// Bounded concurrency: a third simultaneous viewer waits briefly for a
	// slot instead of saturating the machine, then receives transcode_busy.
	// The wait happens outside t.mu: SessionFile, evictIdle and snapshots
	// for already-playing sessions must never stall behind it.
	select {
	case t.slots <- struct{}{}:
	case <-time.After(slotWaitTimeout):
		t.abortStarting(key, s, false)
		return SessionInfo{}, ErrTranscodeBusy
	case <-t.ctx.Done():
		t.abortStarting(key, s, false)
		return SessionInfo{}, t.ctx.Err()
	}
	t.mu.Lock()
	current, stillOurs := t.sessions[key]
	t.mu.Unlock()
	if !stillOurs || current != s {
		// Evicted (session cap or shutdown) while waiting for the slot; the
		// evictor's cleanup is already waiting on s.done.
		t.abortStarting(key, s, true)
		return SessionInfo{}, ErrTranscodeBusy
	}

	go t.runSession(sessionCtx, s, source, info, videoCopy, audioCopy, tagHevc)
	return sessionInfo(s), nil
}

// abortStarting unwinds a registered session whose muxer never launched.
// runSession is the only other closer of s.done, so this path must close it
// itself: Close() and evictIdle's cleanup goroutines block on it.
func (t *Transcoder) abortStarting(key string, s *session, holdSlot bool) {
	if holdSlot {
		<-t.slots
	}
	close(s.done)
	s.cancel()
	t.mu.Lock()
	if cur, ok := t.sessions[key]; ok && cur == s {
		delete(t.sessions, key)
	}
	t.mu.Unlock()
	_ = os.RemoveAll(s.dir)
}

func sessionInfo(s *session) SessionInfo {
	info := SessionInfo{ID: s.id, Start: s.start, Profile: s.profile, AudioTrack: s.audioTrack, Quality: s.quality}
	if s.written.Load() {
		info.Ready = true
	}
	return info
}

// decideProfile classifies the source after ffprobe. Copyable video is
// muxed into fMP4 untouched; incompatible audio is re-encoded to AAC while
// the video stays untouched (cheap and broadly compatible).
func decideProfile(info TrackInfo) (profile string, videoCopy, audioCopy, tagHevc bool) {
	videoCopy = videoCopyable(info.VideoCodec)
	audioCopy = len(info.Audio) == 0 || audioCopyable(info.Audio[0].Codec)
	tagHevc = info.VideoCodec == "hevc" || info.VideoCodec == "hvc1"
	if videoCopy {
		return "remux", videoCopy, audioCopy, tagHevc
	}
	return "transcode", videoCopy, audioCopy, false
}

func hlsArgs(s *session, videoCopy, audioCopy, tagHevc bool, height, targetHeight int, encoder, preset string) []string {
	args := []string{
		"-hide_banner", "-loglevel", "error", "-nostdin",
		"-ss", strconv.FormatFloat(s.start, 'f', 3, 64),
		"-i", "/dev/fd/3",
		"-map", "0:v:0",
	}
	if s.audioTrack >= 0 {
		args = append(args, "-map", fmt.Sprintf("0:a:%d", s.audioTrack))
	}
	if videoCopy {
		args = append(args, "-c:v", "copy")
		if tagHevc {
			args = append(args, "-tag:v", "hvc1")
		}
	} else {
		if encoder == "" {
			encoder = "h264_videotoolbox"
		}
		// A scaled tier is billed at the target height, not the source's.
		rateHeight := height
		if targetHeight > 0 {
			rateHeight = targetHeight
		}
		args = append(args, "-c:v", encoder, "-b:v", bitrateForVideo(rateHeight))
		if preset != "" {
			args = append(args, "-preset", preset)
		}
		if targetHeight > 0 {
			// Even-height scaling keeps the chroma subsampling valid; only
			// downscale, never upscale beyond the source.
			args = append(args, "-vf", fmt.Sprintf("scale=-2:%d", targetHeight))
		}
		args = append(args, "-pix_fmt", "yuv420p")
	}
	if s.audioTrack >= 0 {
		if audioCopy {
			args = append(args, "-c:a", "copy")
		} else {
			args = append(args, "-c:a", "aac", "-b:a", "192k", "-ac", "2")
		}
	}
	return append(args,
		"-f", "hls",
		"-hls_time", strconv.Itoa(hlsSegmentSeconds),
		"-hls_list_size", "0",
		"-hls_flags", "independent_segments+temp_file",
		"-hls_segment_type", "fmp4",
		"-hls_segment_filename", filepath.Join(s.dir, "segment_%05d.m4s"),
		filepath.Join(s.dir, "index.m3u8"))
}

// estimateOutputBytes bounds the disk the muxer may consume for the
// remaining duration. ffmpeg transcodes as fast as the source allows, so the
// full remainder is written up front and must fit.
func estimateOutputBytes(film Film, info TrackInfo, profile string, start float64, quality string) int64 {
	duration := film.MediaDuration
	if info.DurationSeconds > 0 {
		duration = info.DurationSeconds
	}
	if duration <= 0 {
		return 0
	}
	remaining := duration - start
	if remaining <= 0 {
		return 0
	}
	if profile == "remux" && film.Size > 0 {
		return int64(float64(film.Size) * remaining / duration)
	}
	height := info.Height
	if height <= 0 {
		height = film.Height
	}
	return int64(bitrateNumber(bitrateForVideo(height)) * remaining / 8)
}

// availableCacheBytes follows the upload staging rule: check the opened
// cache directory's own volume, never a pathname an external process could
// remount or replace.
func availableCacheBytes(dir *os.File) (int64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Fstatfs(int(dir.Fd()), &stat); err != nil {
		return 0, fmt.Errorf("transcode storage availability check: %w", err)
	}
	blocks, size := int64(stat.Bavail), int64(stat.Bsize)
	if blocks < 0 || size <= 0 {
		return 0, ErrTranscodeSpace
	}
	if blocks > math.MaxInt64/size {
		return math.MaxInt64, nil
	}
	return blocks * size, nil
}

func (t *Transcoder) checkSpace(estimate int64) error {
	if estimate <= 0 {
		return nil
	}
	opened, err := os.Open(t.cacheDir)
	if err != nil {
		return err
	}
	defer opened.Close()
	free, err := availableCacheBytes(opened)
	if err != nil {
		return err
	}
	if free < spaceReserveBytes || estimate > free-spaceReserveBytes {
		return ErrTranscodeSpace
	}
	return nil
}

func (t *Transcoder) runSession(ctx context.Context, s *session, source *os.File, info TrackInfo, videoCopy, audioCopy, tagHevc bool) {
	// The slot was acquired by Session; hold it until the muxer exits.
	defer func() { <-t.slots }()
	defer close(s.done)

	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		s.exitErr = ErrTranscodeFailed
		slog.Warn("transcode cache mkdir failed", "error", err)
		return
	}
	if err := t.checkSpace(estimateOutputBytes(s.film, info, s.profile, s.start, s.quality)); err != nil {
		s.exitErr = err
		_ = os.RemoveAll(s.dir)
		return
	}
	targetHeight := targetHeightFor(s.quality, info.Height)
	s.exitErr = t.spawnMuxer(ctx, s, source, videoCopy, audioCopy, tagHevc, info, targetHeight, "", "")
	// A Homebrew build without the VideoToolbox encoder fails before any
	// playlist is written; retry once with the software encoder so the
	// capability still works instead of reporting a hard failure.
	if errors.Is(s.exitErr, ErrTranscodeFailed) && !s.written.Load() && !videoCopy {
		if _, err := source.Seek(0, io.SeekStart); err == nil {
			slog.Warn("retrying transcode with software encoder", "film", s.film.Path)
			if err := t.spawnMuxer(ctx, s, source, false, audioCopy, false, info, targetHeight, "libx264", "veryfast"); err == nil {
				s.exitErr = nil
			}
		}
	}
	if s.exitErr != nil {
		slog.Warn("transcode session ended", "film", s.film.Path, "error", s.exitErr)
		// Drop the failed session immediately: Session() would otherwise keep
		// handing back this never-ready entry until the idle TTL evicts it.
		// removeLocked's goroutine removes the directory once done closes.
		t.mu.Lock()
		if cur, ok := t.sessions[s.id]; ok && cur == s {
			t.removeLocked(s.id, s)
		}
		t.mu.Unlock()
	}
}

func (t *Transcoder) spawnMuxer(ctx context.Context, s *session, source *os.File, videoCopy, audioCopy, tagHevc bool, info TrackInfo, targetHeight int, encoder, preset string) error {
	bin, err := t.tools.FFmpeg()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrTranscodeUnavailable, err)
	}
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return ErrTranscodeFailed
	}
	cmd := exec.CommandContext(ctx, bin, hlsArgs(s, videoCopy, audioCopy, tagHevc, info.Height, targetHeight, encoder, preset)...)
	cmd.ExtraFiles = []*os.File{source}
	cmd.WaitDelay = 5 * time.Second
	stderr := &limitedBuffer{limit: 8 << 10}
	cmd.Stderr = stderr

	watchStop := make(chan struct{})
	defer close(watchStop)
	go func() {
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-watchStop:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, err := os.Stat(filepath.Join(s.dir, "index.m3u8")); err == nil {
					s.written.Store(true)
					return
				}
			}
		}
	}()

	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			// Cancelled (idle eviction/shutdown) is not a muxer failure.
			return nil
		}
		slog.Warn("ffmpeg exited with error", "stderr", stderr.Bytes())
		return fmt.Errorf("%w: muxer_failed", ErrTranscodeFailed)
	}
	s.written.Store(true)
	return nil
}

// SessionFile serves one playlist/init/segment file for an existing session.
// The session must belong to the requested film identity, which keeps a user
// with access to film A from pulling bytes of film B through a guessed id.
func (t *Transcoder) SessionFile(share string, film Film, sessionID, name string) (*os.File, os.FileInfo, string, error) {
	if !hlsFileRule.MatchString(name) {
		return nil, nil, "", ErrInvalid
	}
	t.mu.Lock()
	s, ok := t.sessions[sessionID]
	if !ok {
		t.mu.Unlock()
		return nil, nil, "", os.ErrNotExist
	}
	if s.share != share || s.film.Path != film.Path || s.film.Size != film.Size || s.film.Modified != film.Modified {
		t.mu.Unlock()
		return nil, nil, "", ErrInvalid
	}
	s.lastAccess.Store(time.Now().UnixNano())
	t.mu.Unlock()

	file, err := os.Open(filepath.Join(s.dir, name))
	if err != nil {
		select {
		case <-s.done:
			if s.exitErr != nil {
				return nil, nil, "", s.exitErr
			}
		default:
		}
		return nil, nil, "", os.ErrNotExist
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, "", os.ErrNotExist
	}
	contentType := "application/vnd.apple.mpegurl"
	switch {
	case strings.HasSuffix(name, ".m4s"):
		contentType = "video/iso.segment"
	case strings.HasSuffix(name, ".mp4"):
		contentType = "video/mp4"
	}
	return file, info, contentType, nil
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
	if err := t.checkSpace(4 << 20); err != nil {
		return nil, "", err
	}
	tmp := target + ".tmp"
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
		"-hide_banner", "-loglevel", "error", "-nostdin",
		"-i", "/dev/fd/3",
		"-map", fmt.Sprintf("0:%d", track.StreamIndex),
		"-f", format,
		tmp)
	cmd.ExtraFiles = []*os.File{source}
	cmd.WaitDelay = 5 * time.Second
	cmd.Stderr = &limitedBuffer{limit: 8 << 10}
	if err := cmd.Run(); err != nil {
		_ = os.Remove(tmp)
		if ctx.Err() != nil {
			return nil, "", fmt.Errorf("%w: timeout", ErrSubtitleExtract)
		}
		slog.Warn("subtitle extraction failed", "error", err)
		return nil, "", ErrSubtitleExtract
	}
	info, err := os.Stat(tmp)
	if err != nil || !info.Mode().IsRegular() {
		_ = os.Remove(tmp)
		return nil, "", ErrSubtitleExtract
	}
	if info.Size() > maxSubtitleBytes {
		_ = os.Remove(tmp)
		return nil, "", ErrSubtitleTooLarge
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Remove(tmp)
		return nil, "", ErrSubtitleExtract
	}
	file, err := os.Open(target)
	if err != nil {
		return nil, "", ErrSubtitleExtract
	}
	return file, extension, nil
}

func (t *Transcoder) snapshotSessions() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	ids := make([]string, 0, len(t.sessions))
	for id := range t.sessions {
		ids = append(ids, id)
	}
	return ids
}
