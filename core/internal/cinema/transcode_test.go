package cinema

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

func TestParseTrackInfo(t *testing.T) {
	sample := `{"streams":[
		{"index":0,"codec_name":"hevc","codec_type":"video","height":2160},
		{"index":1,"codec_name":"aac","codec_type":"audio","channels":2,"tags":{"language":"chi","title":"国语"}},
		{"index":2,"codec_name":"ac3","codec_type":"audio","channels":6,"tags":{"language":"eng"}},
		{"index":3,"codec_name":"subrip","codec_type":"subtitle","tags":{"language":"chi"}},
		{"index":4,"codec_name":"hdmv_pgs_subtitle","codec_type":"subtitle","tags":{"language":"eng"}}
	],"format":{"duration":"5400.5"}}`
	info, err := parseTrackInfo([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	if info.VideoCodec != "hevc" || info.Height != 2160 || info.DurationSeconds != 5400.5 {
		t.Fatalf("basic fields: %+v", info)
	}
	if len(info.Audio) != 2 || info.Audio[0].AudioIndex != 0 || info.Audio[1].StreamIndex != 2 {
		t.Fatalf("audio tracks: %+v", info.Audio)
	}
	if len(info.Subtitles) != 2 || info.Subtitles[0].Extractable != true || info.Subtitles[1].Extractable != false {
		t.Fatalf("subtitle extractable flags: %+v", info.Subtitles)
	}
}

func TestDecideProfile(t *testing.T) {
	cases := []struct {
		name      string
		info      TrackInfo
		profile   string
		videoCopy bool
		audioCopy bool
		tagHevc   bool
	}{
		{"mkv h264 aac", TrackInfo{VideoCodec: "h264", Audio: []AudioTrack{{Codec: "aac"}}}, "remux", true, true, false},
		{"mkv hevc aac", TrackInfo{VideoCodec: "hevc", Audio: []AudioTrack{{Codec: "aac"}}}, "remux", true, true, true},
		{"dts audio re-encode", TrackInfo{VideoCodec: "h264", Audio: []AudioTrack{{Codec: "dts"}}}, "remux", true, false, false},
		{"mpeg2 avi", TrackInfo{VideoCodec: "mpeg2video", Audio: []AudioTrack{{Codec: "mp3"}}}, "transcode", false, true, false},
		{"prores mov", TrackInfo{VideoCodec: "prores", Audio: []AudioTrack{{Codec: "pcm_s16le"}}}, "transcode", false, false, false},
		{"no audio", TrackInfo{VideoCodec: "h264"}, "remux", true, true, false},
	}
	for _, c := range cases {
		profile, videoCopy, audioCopy, tagHevc := decideProfile(c.info)
		if profile != c.profile || videoCopy != c.videoCopy || audioCopy != c.audioCopy || tagHevc != c.tagHevc {
			t.Errorf("%s: got (%s %v %v %v)", c.name, profile, videoCopy, audioCopy, tagHevc)
		}
	}
}

func TestBitrateForVideo(t *testing.T) {
	if got := bitrateForVideo(2160); got != "16M" {
		t.Errorf("2160p bitrate = %s", got)
	}
	if got := bitrateForVideo(720); got != "2500k" {
		t.Errorf("720p bitrate = %s", got)
	}
	if bitrateNumber("2500k") != 2500000 || bitrateNumber("5M") != 5000000 {
		t.Error("bitrateNumber parse mismatch")
	}
	// The M suffix must actually parse; these tiers used to silently fall
	// back to the 5 Mbps default and under-estimated disk needs 1.8–3.2×.
	if bitrateNumber("9M") != 9000000 || bitrateNumber("16M") != 16000000 {
		t.Error("M-suffixed bitrates must parse instead of falling back to 5 Mbps")
	}
}

func TestBucketStartAndSessionKey(t *testing.T) {
	if bucketStart(-3) != 0 || bucketStart(3.9) != 0 || bucketStart(5) != 4 || bucketStart(122.6) != 120 {
		t.Error("bucketStart alignment mismatch")
	}
	film := Film{Path: "a.mkv", Size: 10, Modified: 5}
	if sessionKey("share", film, "remux", 0, "source", 0) != sessionKey("share", film, "remux", 0, "source", 0) {
		t.Error("session key must be deterministic")
	}
	if sessionKey("share", film, "remux", 0, "source", 0) == sessionKey("share", film, "transcode", 0, "source", 0) {
		t.Error("different profiles must not share a session")
	}
	// A replaced file gets a fresh identity key automatically.
	other := film
	other.Size = 11
	if identityKey("share", film) == identityKey("share", other) {
		t.Error("identity key must change with size")
	}
}

func TestEstimateOutputBytes(t *testing.T) {
	film := Film{Size: 10 << 30, MediaDuration: 1000, Height: 2160}
	info := TrackInfo{DurationSeconds: 1000}
	if got := estimateOutputBytes(film, info, "remux", 0, "source"); got != 10<<30 {
		t.Errorf("remux estimate = %d", got)
	}
	half := estimateOutputBytes(film, info, "remux", 500, "source")
	if half != 5<<30 {
		t.Errorf("remux half estimate = %d", half)
	}
	encode := estimateOutputBytes(film, info, "transcode", 0, "source")
	if encode <= 0 || encode > 40<<30 {
		t.Errorf("transcode estimate out of range: %d", encode)
	}
	// 2160p is billed at 16 Mbps: 16e6 bits/s × 1000 s / 8 = 2 GiB-ish bytes.
	if encode != 2_000_000_000 {
		t.Errorf("2160p transcode estimate = %d, want 2000000000", encode)
	}
}

func TestHLSFileRule(t *testing.T) {
	for _, ok := range []string{"index.m3u8", "init.mp4", "segment_00042.m4s"} {
		if !hlsFileRule.MatchString(ok) {
			t.Errorf("%s should be servable", ok)
		}
	}
	for _, bad := range []string{"../index.m3u8", "segment_1.m4s", "secret.mp4", "index.m3u8/x", "segment_000042.m4s"} {
		if hlsFileRule.MatchString(bad) {
			t.Errorf("%s must not be servable", bad)
		}
	}
}

func TestHLSArgs(t *testing.T) {
	s := &session{
		dir: "/cache/s1", profile: "remux", audioTrack: 1, start: 120,
		film: Film{Path: "a.mkv"},
	}
	args := hlsArgs(s, true, true, true, 2160, 0, "", "")
	joined := strings.Join(args, " ")
	for _, want := range []string{"-ss 120", "-map 0:v:0", "-map 0:a:1", "-c:v copy", "-tag:v hvc1", "-c:a copy",
		"-hls_segment_type fmp4", "/cache/s1/index.m3u8"} {
		if !strings.Contains(joined, want) {
			t.Errorf("remux args missing %q in %s", want, joined)
		}
	}
	s2 := &session{dir: "/cache/s2", profile: "transcode", audioTrack: 0, start: 0}
	args = hlsArgs(s2, false, false, false, 1080, 0, "", "")
	joined = strings.Join(args, " ")
	for _, want := range []string{"-c:v h264_videotoolbox", "-b:v 5M", "-c:a aac", "-ac 2", "-pix_fmt yuv420p"} {
		if !strings.Contains(joined, want) {
			t.Errorf("transcode args missing %q in %s", want, joined)
		}
	}
	// The software fallback replaces the encoder and adds the preset.
	args = hlsArgs(s2, false, false, false, 1080, 0, "libx264", "veryfast")
	joined = strings.Join(args, " ")
	if !strings.Contains(joined, "-c:v libx264 -b:v 5M -preset veryfast") {
		t.Errorf("software fallback args wrong: %s", joined)
	}
	if strings.Contains(joined, "videotoolbox") {
		t.Error("fallback must not reference videotoolbox")
	}
	// A scaled tier forces a re-encode with the even-height scale filter and
	// keeps the audio in the broadly compatible AAC lane.
	s3 := &session{dir: "/cache/s3", profile: "transcode", audioTrack: 0, quality: "720", start: 0}
	args = hlsArgs(s3, false, false, false, 2160, 720, "", "")
	joined = strings.Join(args, " ")
	if !strings.Contains(joined, "-vf scale=-2:720") || !strings.Contains(joined, "-b:v 2500k") {
		t.Errorf("scaled tier args wrong: %s", joined)
	}
	if strings.Contains(joined, "copy") {
		t.Errorf("scaled tier must re-encode: %s", joined)
	}
}

func TestQualityNormalizationAndTargets(t *testing.T) {
	for _, value := range []string{"", "source", "1080", "720", "480"} {
		if _, err := NormalizeQuality(value); err != nil {
			t.Errorf("quality %q rejected: %v", value, err)
		}
	}
	if _, err := NormalizeQuality("2160p"); err == nil {
		t.Error("unknown quality accepted")
	}
	if got, _ := NormalizeQuality(""); got != "source" {
		t.Errorf("empty quality = %q", got)
	}
	// A tier at or above the source height keeps the source profile.
	if targetHeightFor("720", 480) != 0 || targetHeightFor("720", 720) != 0 {
		t.Error("upscale must fall back to the source profile")
	}
	if targetHeightFor("720", 1080) != 720 || targetHeightFor("480", 1080) != 480 {
		t.Error("downscale target mismatch")
	}
}

func writeFakeProbe(t *testing.T, dir string) {
	t.Helper()
	script := `#!/bin/sh
cat <<'JSON'
{"streams":[
 {"index":0,"codec_name":"h264","codec_type":"video","height":1080},
 {"index":1,"codec_name":"aac","codec_type":"audio","channels":2,"tags":{"language":"eng"}},
 {"index":2,"codec_name":"subrip","codec_type":"subtitle","tags":{"language":"eng"}}
],"format":{"duration":"600.0"}}
JSON
`
	if err := os.WriteFile(filepath.Join(dir, "ffprobe"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func fakeFFmpegScript(t *testing.T, dir string, sleepSeconds int) {
	t.Helper()
	script := `#!/bin/sh
for last; do :; done
dir=$(dirname "$last")
printf 'EXTM3U\n' > "$dir/index.m3u8"
printf 'fake' > "$dir/init.mp4"
printf 'fake' > "$dir/segment_00000.m4s"
` + "sleep " + itoaTest(sleepSeconds) + `
`
	if err := os.WriteFile(filepath.Join(dir, "ffmpeg"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func itoaTest(n int) string {
	return strconv.Itoa(n)
}

func TestSessionLifecycleWithFakeMuxer(t *testing.T) {
	dir := t.TempDir()
	writeFakeProbe(t, dir)
	fakeFFmpegScript(t, dir, 60)
	tools := ffmpegbin.NewWithPaths(filepath.Join(dir, "ffmpeg"), filepath.Join(dir, "ffprobe"))
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()

	source := filepath.Join(dir, "movie.mkv")
	if err := os.WriteFile(source, []byte("fake-video-bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	opened, err := os.Open(source)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	film := Film{ID: 1, Path: "movie.mkv", Size: 16, Modified: time.Now().UnixNano(), MediaDuration: 600}
	info, err := transcoder.Session(opened, "share", film, 30.2, 0, "source")
	if err != nil {
		t.Fatalf("Session: %v", err)
	}
	if info.Profile != "remux" || info.Start != 28 || info.Ready {
		t.Fatalf("session info: %+v", info)
	}
	// The fake muxer writes the playlist within a moment; the file endpoints
	// then serve it.
	deadline := time.Now().Add(5 * time.Second)
	var file *os.File
	for time.Now().Before(deadline) {
		opened, _, _, err := transcoder.SessionFile("share", film, info.ID, "index.m3u8")
		if err == nil {
			file = opened
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("playlist fetch: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if file == nil {
		t.Fatal("playlist never became servable")
	}
	defer file.Close()
	// SessionFile rejects a mismatched film identity.
	if _, _, _, err := transcoder.SessionFile("share", Film{Path: "other.mkv", Size: 16, Modified: film.Modified}, info.ID, "index.m3u8"); err == nil {
		t.Fatal("cross-film session access must be rejected")
	}
	// Idle eviction kills the sleeping muxer and removes the directory.
	transcoder.mu.Lock()
	s := transcoder.sessions[info.ID]
	s.lastAccess.Store(time.Now().Add(-idleSessionTTL - time.Second).UnixNano())
	transcoder.mu.Unlock()
	transcoder.evictIdle()
	select {
	case <-s.done:
	case <-time.After(15 * time.Second):
		t.Fatal("evicted session did not terminate")
	}
	removed := false
	for started := time.Now(); time.Since(started) < 5*time.Second; {
		if _, err := os.Stat(s.dir); os.IsNotExist(err) {
			removed = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !removed {
		t.Fatal("session dir not removed after eviction")
	}
}

func TestSessionFailsHonestlyWithoutFFmpeg(t *testing.T) {
	dir := t.TempDir()
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), ffmpegbin.NewWithPaths("", ""))
	defer transcoder.Close()
	source, err := os.Create(filepath.Join(dir, "movie.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	film := Film{ID: 1, Path: "movie.mkv", Size: 4, Modified: 1, MediaDuration: 10}
	if _, err := transcoder.Session(source, "share", film, 0, 0, "source"); !errors.Is(err, ffmpegbin.ErrNotInstalled) {
		t.Fatalf("Session error = %v, want ErrNotInstalled", err)
	}
}

func TestSessionRejectsInvalidStart(t *testing.T) {
	dir := t.TempDir()
	writeFakeProbe(t, dir)
	fakeFFmpegScript(t, dir, 0)
	tools := ffmpegbin.NewWithPaths(filepath.Join(dir, "ffmpeg"), filepath.Join(dir, "ffprobe"))
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()
	source, err := os.Create(filepath.Join(dir, "movie.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	if _, err := source.WriteString("data"); err != nil {
		t.Fatal(err)
	}
	film := Film{ID: 1, Path: "movie.mkv", Size: 4, Modified: 1, MediaDuration: 600}
	if _, err := transcoder.Session(source, "share", film, 700, 0, "source"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("beyond-duration start error = %v", err)
	}
	if _, err := transcoder.Session(source, "share", film, 0, 9, "source"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("out-of-range audio track error = %v", err)
	}
}

func TestFailedTranscodeSessionIsDroppedImmediately(t *testing.T) {
	dir := t.TempDir()
	writeFakeProbe(t, dir)
	// The muxer exits 1 without writing any playlist.
	if err := os.WriteFile(filepath.Join(dir, "ffmpeg"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	tools := ffmpegbin.NewWithPaths(filepath.Join(dir, "ffmpeg"), filepath.Join(dir, "ffprobe"))
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()
	source, err := os.Create(filepath.Join(dir, "movie.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	if _, err := source.WriteString("data"); err != nil {
		t.Fatal(err)
	}
	film := Film{ID: 1, Path: "movie.mkv", Size: 4, Modified: time.Now().UnixNano(), MediaDuration: 600}
	info, err := transcoder.Session(source, "share", film, 0, 0, "source")
	if err != nil {
		t.Fatalf("Session: %v", err)
	}
	transcoder.mu.Lock()
	s := transcoder.sessions[info.ID]
	transcoder.mu.Unlock()
	if s == nil {
		t.Fatal("session not registered")
	}
	select {
	case <-s.done:
	case <-time.After(15 * time.Second):
		t.Fatal("failed muxer never exited")
	}
	// runSession drops the session from the table before done closes, so a
	// retry never reuses the dead entry for the remaining idle TTL.
	transcoder.mu.Lock()
	_, stillListed := transcoder.sessions[info.ID]
	transcoder.mu.Unlock()
	if stillListed {
		t.Fatal("failed session must leave the table immediately")
	}
	// removeLocked's goroutine deletes the directory asynchronously after
	// done closes, so poll for it instead of asserting immediately.
	removed := false
	for started := time.Now(); time.Since(started) < 5*time.Second; {
		if _, err := os.Stat(s.dir); os.IsNotExist(err) {
			removed = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !removed {
		t.Fatal("failed session dir must be removed")
	}
	// A retry for the same film registers a fresh session object under the
	// same deterministic key and runs its own (doomed) muxer again.
	second, err := transcoder.Session(source, "share", film, 0, 0, "source")
	if err != nil {
		t.Fatalf("retry Session: %v", err)
	}
	transcoder.mu.Lock()
	retry := transcoder.sessions[second.ID]
	transcoder.mu.Unlock()
	if retry == nil || retry == s {
		t.Fatal("retry must create a fresh session object, not the dead one")
	}
}

func TestSlotWaitDoesNotStallActiveSessions(t *testing.T) {
	dir := t.TempDir()
	writeFakeProbe(t, dir)
	fakeFFmpegScript(t, dir, 60)
	tools := ffmpegbin.NewWithPaths(filepath.Join(dir, "ffmpeg"), filepath.Join(dir, "ffprobe"))
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()

	open := func(name string) *os.File {
		t.Helper()
		source, err := os.Create(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { source.Close() })
		if _, err := source.WriteString("data"); err != nil {
			t.Fatal(err)
		}
		return source
	}
	// Fill both concurrency slots with sleeping muxers.
	first := Film{ID: 1, Path: "one.mkv", Size: 4, Modified: 1, MediaDuration: 600}
	second := Film{ID: 2, Path: "two.mkv", Size: 4, Modified: 1, MediaDuration: 600}
	firstInfo, err := transcoder.Session(open("one.mkv"), "share", first, 0, 0, "source")
	if err != nil {
		t.Fatalf("first session: %v", err)
	}
	if _, err := transcoder.Session(open("two.mkv"), "share", second, 0, 0, "source"); err != nil {
		t.Fatalf("second session: %v", err)
	}
	// Wait until the first playlist is servable so the timing below measures
	// lock contention, not muxer startup.
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, _, _, err := transcoder.SessionFile("share", first, firstInfo.ID, "index.m3u8")
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("playlist fetch: %v", err)
		}
		if time.Now().After(deadline) {
			t.Fatal("first playlist never became servable")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// A third viewer registers its session and then blocks on the full slot
	// pool; segment requests for the running session must stay responsive.
	third := Film{ID: 3, Path: "three.mkv", Size: 4, Modified: 1, MediaDuration: 600}
	busy := make(chan error, 1)
	go func() {
		_, err := transcoder.Session(open("three.mkv"), "share", third, 0, 0, "source")
		busy <- err
	}()
	time.Sleep(300 * time.Millisecond)
	started := time.Now()
	if _, _, _, err := transcoder.SessionFile("share", first, firstInfo.ID, "index.m3u8"); err != nil {
		t.Fatalf("SessionFile during slot wait: %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("SessionFile stalled %s behind the slot wait; the wait must not hold t.mu", elapsed)
	}
	select {
	case err := <-busy:
		if !errors.Is(err, ErrTranscodeBusy) {
			t.Fatalf("third viewer error = %v, want transcode_busy", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("third viewer never resolved")
	}
}

func TestRootIdleUseIncludesCompletedHlsSession(t *testing.T) {
	transcoder := NewTranscoder(t.TempDir(), nil)
	defer transcoder.Close()
	library := &Library{transcoder: transcoder}
	if library.InUse() {
		t.Fatal("empty runtime is busy")
	}
	_, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	close(done)
	transcoder.mu.Lock()
	transcoder.sessions["playing"] = &session{cancel: cancel, done: done}
	transcoder.mu.Unlock()
	if !library.InUse() {
		t.Fatal("completed encoder must retain a playable HLS session between requests")
	}
}

func TestSessionOwnsSourceAfterRequestReturns(t *testing.T) {
	// The HTTP-facing library closes its source as soon as Session returns.
	// Keep one runnable Go thread so the asynchronous muxer runs after that close.
	previous := runtime.GOMAXPROCS(1)
	defer runtime.GOMAXPROCS(previous)
	dir := t.TempDir()
	writeFakeProbe(t, dir)
	fakeFFmpegScript(t, dir, 0)
	tools := ffmpegbin.NewWithPaths(filepath.Join(dir, "ffmpeg"), filepath.Join(dir, "ffprobe"))
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()
	source, err := os.Create(filepath.Join(dir, "movie.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := source.WriteString("source bytes"); err != nil {
		source.Close()
		t.Fatal(err)
	}
	originalInfo, err := source.Stat()
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	film := Film{ID: 1, Path: "movie.mkv", Size: 12, Modified: time.Now().UnixNano(), MediaDuration: 600}
	info, err := transcoder.Session(source, "share", film, 0, 0, "source")
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	source.Close()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		file, _, _, err := transcoder.SessionFile("share", film, info.ID, "index.m3u8")
		if err == nil {
			file.Close()
			transcoder.Close()
			fdDirectory, err := os.Open("/dev/fd")
			if err != nil { t.Fatal(err) }
			fds, err := fdDirectory.Readdirnames(-1)
			fdDirectory.Close()
			if err != nil { t.Fatal(err) }
			for _, fd := range fds {
				if info, err := os.Stat(filepath.Join("/dev/fd", fd)); err == nil && os.SameFile(info, originalInfo) {
					t.Fatalf("completed muxer retained source descriptor %s", fd)
				}
			}
			return
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("request source close broke the asynchronous muxer: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("playlist never became available after the request released its file")
}

func TestTranscodeSourceDuplicatePinsIdentityAndClosesIndependently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "movie")
	if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	owned, err := duplicateTranscodeSource(source)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	source.Close()
	defer owned.Close()
	if err := os.Rename(path, path+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	bytes, err := io.ReadAll(owned)
	if err != nil || string(bytes) != "original" {
		t.Fatalf("async source was not pinned: %q %v", bytes, err)
	}
	if _, err := duplicateTranscodeSource(source); err == nil {
		t.Fatalf("closed source duplicate: %v", err)
	}
}
