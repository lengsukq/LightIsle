package cinema

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
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
	// Accept self-contained video containers, never playlist/concat demuxers.
	videoInputFormats = "mov,mp4,m4a,3gp,3g2,mj2,m4v,matroska,webm,avi,mpegts,mpegtsraw"
)

// Probe and subtitle workers are independent of HLS sessions and can be
// triggered by any member with video access. Bound them across all roots.
var mediaInspectionSlots = make(chan struct{}, 2)

func tryMediaInspection() bool {
	select {
	case mediaInspectionSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

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
	Width           int             `json:"width,omitempty"`
	Height          int             `json:"height,omitempty"`
	DurationSeconds float64         `json:"durationSeconds,omitempty"`
	Audio           []AudioTrack    `json:"audio"`
	Subtitles       []SubtitleTrack `json:"subtitles"`
}

type SessionInfo struct {
	ID              string  `json:"sessionId"`
	Start           float64 `json:"start"`
	DurationSeconds float64 `json:"durationSeconds,omitempty"`
	Profile         string  `json:"profile"` // remux | transcode
	AudioTrack      int     `json:"audioTrack"`
	Quality         string  `json:"quality"` // source | 1080 | 720 | 480
	Ready           bool    `json:"ready"`
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
	duration   float64
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

// Session validates the request against a fresh ffprobe of the opened
// source, then starts (or joins) the HLS muxer. The source file may be
// closed once this returns; the muxer child keeps its own duplicated
// descriptor. Clients poll the playlist for readiness.
func (t *Transcoder) Session(source *os.File, share string, film Film, requestedStart float64, audioTrack int, quality string, replaceSessionID ...string) (SessionInfo, error) {
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
	if len(replaceSessionID) > 0 && replaceSessionID[0] != "" && replaceSessionID[0] != key {
		t.CancelSession(share, film, replaceSessionID[0])
	}

	t.mu.Lock()
	if existing, ok := t.sessions[key]; ok {
		existing.lastAccess.Store(time.Now().UnixNano())
		if existing.duration <= 0 && duration > 0 {
			existing.duration = duration
		}
		t.mu.Unlock()
		return sessionInfo(existing), nil
	}
	dir := filepath.Join(t.cacheDir, key)
	sessionCtx, cancel := context.WithCancel(t.ctx)
	s := &session{
		id: key, dir: dir, share: share, film: film,
		profile: profile, audioTrack: audioTrack, quality: quality, start: start, duration: duration,
		cancel: cancel, done: make(chan struct{}),
	}
	s.lastAccess.Store(time.Now().UnixNano())
	t.sessions[key] = s
	t.mu.Unlock()

	// Bounded concurrency: a third simultaneous viewer waits briefly for a
	// slot instead of saturating the machine, then receives transcode_busy.
	// If the caller is scrubbing the same film, cancel its own older muxer first.
	acquired := false
	select {
	case t.slots <- struct{}{}:
		acquired = true
	default:
		t.evictOldestRunningSameFilm(share, film, key)
	}
	if !acquired {
		select {
		case t.slots <- struct{}{}:
		case <-time.After(slotWaitTimeout):
			t.abortStarting(key, s, false)
			return SessionInfo{}, ErrTranscodeBusy
		case <-t.ctx.Done():
			t.abortStarting(key, s, false)
			return SessionInfo{}, t.ctx.Err()
		}
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

	// The request owns source and closes it when this method returns. Pin the
	// same open inode for the asynchronous encoder, including software retry;
	// never reopen the pathname after the request's identity check.
	ownedSource, err := duplicateTranscodeSource(source)
	if err != nil {
		t.abortStarting(key, s, true)
		return SessionInfo{}, fmt.Errorf("%w: source handle unavailable", ErrTranscodeFailed)
	}
	go t.runSession(sessionCtx, s, ownedSource, info, videoCopy, audioCopy, tagHevc)
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
	info := SessionInfo{
		ID: s.id, Start: s.start, DurationSeconds: s.duration,
		Profile: s.profile, AudioTrack: s.audioTrack, Quality: s.quality,
	}
	if s.written.Load() {
		info.Ready = true
	}
	return info
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

func (t *Transcoder) snapshotSessions() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	ids := make([]string, 0, len(t.sessions))
	for id := range t.sessions {
		ids = append(ids, id)
	}
	return ids
}
