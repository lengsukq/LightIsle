package cinema

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

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

func duplicateTranscodeSource(source *os.File) (*os.File, error) {
	raw, err := source.SyscallConn()
	if err != nil {
		return nil, err
	}
	var fd int
	var duplicateErr error
	if err := raw.Control(func(sourceFD uintptr) {
		// Set close-on-exec atomically; only ExtraFiles may pass this handle
		// to the chosen FFmpeg child while other workers start concurrently.
		fd, duplicateErr = unix.FcntlInt(sourceFD, unix.F_DUPFD_CLOEXEC, 0)
	}); err != nil {
		return nil, err
	}
	if duplicateErr != nil {
		return nil, duplicateErr
	}
	return os.NewFile(uintptr(fd), source.Name()), nil
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
		"-protocol_whitelist", "file", "-format_whitelist", videoInputFormats, "-i", "/dev/fd/3",
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
		"-hls_playlist_type", "event",
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
	if scaled := targetHeightFor(quality, height); scaled > 0 {
		height = scaled
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
	defer source.Close()

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
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
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
