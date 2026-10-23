package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
)

// Hash only a bounded ordinary file already exposed through the authenticated
// file-read capability. This never follows or resolves client filesystem paths.
const maxVerifiedFileBytes int64 = 2 << 30

var processFileHashSlots = make(chan struct{}, 2)

type contextHashReader struct {
	ctx context.Context
	r   io.Reader
}

func (c contextHashReader) Read(buf []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(buf)
}

func (a *API) fileSHA256(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("path")
	if !a.allowFile(w, r, name, false) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if r.Context().Err() != nil {
		return
	}
	slots := a.fileHashSlots
	if slots == nil {
		slots = processFileHashSlots
	}
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	default:
		w.Header().Set("Retry-After", "1")
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "file_hash_busy"})
		return
	}
	first, before, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	defer first.Close()
	if !before.Mode().IsRegular() {
		jsonReply(w, 400, map[string]string{"error": "not_a_regular_file"})
		return
	}
	if before.Size() < 0 || before.Size() > maxVerifiedFileBytes {
		jsonReply(w, 413, map[string]string{"error": "verification_size_limit"})
		return
	}
	hasher := sha256.New()
	// A file may grow after the initial stat. Stop after the expected size
	// plus one byte rather than reading an actively growing file forever.
	copied, err := io.CopyBuffer(hasher, io.LimitReader(contextHashReader{ctx: r.Context(), r: first}, before.Size()+1), make([]byte, 128*1024))
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		jsonReply(w, 503, map[string]string{"error": "verification_read_failed"})
		return
	}
	changed, statErr := first.Stat()
	if statErr != nil || copied != before.Size() || !os.SameFile(before, changed) ||
		!changed.ModTime().Equal(before.ModTime()) || changed.Size() != before.Size() {
		jsonReply(w, 409, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	// Confirm this is still the object at the caller's authorized path and
	// that the underlying root is still online, not a replaced same-name disk.
	latest, latestInfo, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	latest.Close()
	if !os.SameFile(before, latestInfo) || latestInfo.Size() != before.Size() ||
		!latestInfo.ModTime().Equal(before.ModTime()) {
		jsonReply(w, 409, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	jsonReply(w, 200, map[string]any{
		"algorithm": "sha256",
		"sha256":    hex.EncodeToString(hasher.Sum(nil)),
		"size":      copied,
	})
}
