package cinema

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

// TestTranscoderRealFFmpeg exercises the full pipeline against the real
// Homebrew FFmpeg: it synthesizes tiny samples, remuxes an MKV to fMP4 HLS,
// re-encodes an incompatible video, extracts an embedded subtitle and checks
// audio track selection. Without FFmpeg installed the test skips honestly —
// install it with `brew install ffmpeg` to run this smoke.
func TestTranscoderRealFFmpeg(t *testing.T) {
	tools := ffmpegbin.New()
	if _, err := tools.FFmpeg(); err != nil {
		t.Skipf("跳过真实转码冒烟：%v（安装 Homebrew ffmpeg 后重跑）", err)
	}
	dir := t.TempDir()
	transcoder := NewTranscoder(filepath.Join(dir, "cache"), tools)
	defer transcoder.Close()
	share := filepath.Join(dir, "SharedFiles")
	if err := os.MkdirAll(share, 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		t.Helper()
		bin, err := tools.FFmpeg()
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(bin, append([]string{"-hide_banner", "-loglevel", "error", "-y"}, args...)...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("ffmpeg %v: %v\n%s", args, err, output)
		}
	}

	// Sample 1: h264+aac inside MKV — the canonical remux case.
	mkvPath := filepath.Join(share, "sample-remux.mkv")
	run("-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=10",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=3",
		"-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
		"-metadata:s:a:0", "language=eng",
		"-f", "matroska", mkvPath)

	// Sample 2: MPEG-4 part 2 video — needs the transcode profile. Two audio
	// streams so track switching is exercised.
	aviPath := filepath.Join(share, "sample-transcode.mkv")
	run("-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=10",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=2",
		"-f", "lavfi", "-i", "sine=frequency=880:duration=2",
		"-c:v", "mpeg4", "-q:v", "8", "-c:a", "aac", "-map", "0:v", "-map", "1:a", "-map", "2:a",
		"-f", "matroska", aviPath)

	// Sample 3: h264 with an embedded SRT subtitle.
	subPath := filepath.Join(share, "sample-subs.mkv")
	srt := filepath.Join(dir, "subs.srt")
	if err := os.WriteFile(srt, []byte("1\n00:00:00,000 --> 00:00:02,000\n你好，LightIsle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	run("-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=10",
		"-i", srt,
		"-c:v", "libx264", "-preset", "ultrafast", "-c:s", "srt",
		"-metadata:s:s:0", "language=chi",
		"-f", "matroska", subPath)

	openSample := func(name string, size int64, duration float64) (*os.File, Film) {
		t.Helper()
		file, err := os.Open(filepath.Join(share, name))
		if err != nil {
			t.Fatal(err)
		}
		info, err := file.Stat()
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { file.Close() })
		return file, Film{ID: 1, Path: name, Size: info.Size(), Modified: info.ModTime().UnixNano(), MediaDuration: duration}
	}
	waitPlaylist := func(film Film, info SessionInfo) string {
		t.Helper()
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			file, _, _, err := transcoder.SessionFile(share, film, info.ID, "index.m3u8")
			if err == nil {
				defer file.Close()
				content := make([]byte, 4096)
				n, _ := file.Read(content)
				return string(content[:n])
			}
			if !os.IsNotExist(err) {
				t.Fatalf("playlist fetch: %v", err)
			}
			select {
			case <-transcoder.ctx.Done():
				t.Fatal("transcoder closed")
			case <-time.After(100 * time.Millisecond):
			}
		}
		t.Fatal("playlist never appeared within 30s")
		return ""
	}

	t.Run("RemuxMKV", func(t *testing.T) {
		source, film := openSample("sample-remux.mkv", 0, 3)
		info, err := transcoder.Session(source, share, film, 0, 0, "source")
		if err != nil {
			t.Fatalf("remux session: %v", err)
		}
		if info.Profile != "remux" {
			t.Fatalf("profile = %s, want remux", info.Profile)
		}
		playlist := waitPlaylist(film, info)
		if !strings.Contains(playlist, "#EXTM3U") {
			t.Fatalf("playlist head: %q", playlist)
		}
		if !strings.Contains(playlist, "segment_") {
			t.Fatalf("no segments listed: %q", playlist)
		}
		segment, _, _, err := transcoder.SessionFile(share, film, info.ID, "segment_00000.m4s")
		if err != nil {
			t.Fatalf("segment: %v", err)
		}
		defer segment.Close()
		stat, err := segment.Stat()
		if err != nil || stat.Size() == 0 {
			t.Fatalf("empty segment: %v", err)
		}
		tracks, err := transcoder.ProbeTracks(source, share, film)
		if err != nil || len(tracks.Audio) != 1 || tracks.Audio[0].Codec != "aac" {
			t.Fatalf("probe: %+v %v", tracks, err)
		}
	})

	t.Run("TranscodeMPEG4", func(t *testing.T) {
		source, film := openSample("sample-transcode.mkv", 0, 2)
		info, err := transcoder.Session(source, share, film, 0, 1, "source")
		if err != nil {
			t.Fatalf("transcode session: %v", err)
		}
		if info.Profile != "transcode" || info.AudioTrack != 1 {
			t.Fatalf("session info: %+v", info)
		}
		playlist := waitPlaylist(film, info)
		if !strings.Contains(playlist, "#EXTM3U") {
			t.Fatalf("playlist head: %q", playlist)
		}
	})

	t.Run("EmbeddedSubtitleExtraction", func(t *testing.T) {
		source, film := openSample("sample-subs.mkv", 0, 3)
		tracks, err := transcoder.ProbeTracks(source, share, film)
		if err != nil || len(tracks.Subtitles) != 1 || !tracks.Subtitles[0].Extractable {
			t.Fatalf("tracks: %+v %v", tracks, err)
		}
		file, extension, err := transcoder.ExtractSubtitle(source, share, film, tracks.Subtitles[0])
		if err != nil {
			t.Fatalf("extract: %v", err)
		}
		defer file.Close()
		if extension != ".srt" {
			t.Fatalf("extension = %s", extension)
		}
		content := make([]byte, 512)
		n, _ := file.Read(content)
		if !strings.Contains(string(content[:n]), "你好，LightIsle") {
			t.Fatalf("extracted subtitle: %q", string(content[:n]))
		}
		// Second request replays the cache.
		cached, _, err := transcoder.ExtractSubtitle(source, share, film, tracks.Subtitles[0])
		if err != nil {
			t.Fatalf("cached extract: %v", err)
		}
		cached.Close()
	})

	t.Run("StatusReportsVersion", func(t *testing.T) {
		available, version, reason, _ := transcoderStatusForTest(t, tools)
		if !available || version == "" || reason != "" {
			t.Fatalf("status: %v %q %q", available, version, reason)
		}
	})
}

func transcoderStatusForTest(t *testing.T, tools *ffmpegbin.Tools) (bool, string, string, int) {
	t.Helper()
	version, err := tools.Version(context.Background())
	if err != nil {
		return false, "", "ffmpeg_failed", 0
	}
	return true, version, "", 0
}
