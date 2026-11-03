package server

import (
	"crypto/rand"
	"crypto/sha256"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Diagnostics transfer only generated memory-backed bytes, never NAS files.
// The per-process admission limit prevents concurrent tests from consuming
// excessive bandwidth or memory on a low-power home server.
const (
	networkTestMinBytes    = 1
	maxNetworkTestBytes    = 16 * 1024 * 1024
	networkTestMaxBytes    = maxNetworkTestBytes
	networkTestBudgetBytes = 256 * 1024 * 1024
)

var networkTestSlots = make(chan struct{}, 2)
var networkTestCoreStarted = time.Now()
var networkTestBudgets = struct {
	sync.Mutex
	entries map[[32]byte]networkTestBudget
}{entries: make(map[[32]byte]networkTestBudget)}

type networkTestBudget struct {
	start time.Time
	bytes int64
}

// Keep one short-lived bandwidth budget per authenticated session. Only its
// SHA-256 digest is kept (never the cookie itself), and the table is bounded.
// Combined with the two-transfer semaphore this prevents a logged-in client
// from saturating a small family NAS with endless diagnostic downloads.
func networkTestAllowBytes(w http.ResponseWriter, r *http.Request, size int64) bool {
	key := sha256.Sum256([]byte(token(r)))
	now := time.Now()
	networkTestBudgets.Lock()
	defer networkTestBudgets.Unlock()
	bucket, found := networkTestBudgets.entries[key]
	if !found || now.Sub(bucket.start) >= 5*time.Minute {
		if len(networkTestBudgets.entries) >= 512 {
			for id, value := range networkTestBudgets.entries {
				if now.Sub(value.start) >= 5*time.Minute {
					delete(networkTestBudgets.entries, id)
				}
			}
		}
		if len(networkTestBudgets.entries) >= 512 && !found {
			w.Header().Set("Retry-After", "30")
			jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "network_test_busy"})
			return false
		}
		bucket = networkTestBudget{start: now}
	}
	if size > networkTestBudgetBytes-bucket.bytes {
		w.Header().Set("Retry-After", "300")
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "network_test_rate_limited"})
		return false
	}
	bucket.bytes += size
	networkTestBudgets.entries[key] = bucket
	return true
}

func networkTestAdmit(w http.ResponseWriter) bool {
	select {
	case networkTestSlots <- struct{}{}:
		return true
	default:
		w.Header().Set("Retry-After", "2")
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "network_test_busy"})
		return false
	}
}

func networkTestHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "private, no-store, no-transform")
	w.Header().Set("X-Content-Type-Options", "nosniff")
}

func (a *API) networkTestPing(w http.ResponseWriter, r *http.Request) {
	networkTestHeaders(w)
	jsonReply(w, http.StatusOK, map[string]any{
		"ok":         true,
		"status":     "ok",
		"serverTime": time.Now().UnixMilli(),
		// This is the current Go Core process uptime, not Mac uptime.
		"coreUptimeSeconds": int64(time.Since(networkTestCoreStarted).Seconds()),
	})
}

func (a *API) networkTestDownload(w http.ResponseWriter, r *http.Request) {
	networkTestHeaders(w)
	if !networkTestAdmit(w) {
		return
	}
	defer func() { <-networkTestSlots }()
	size := int64(2 * 1024 * 1024)
	if raw := r.URL.Query().Get("bytes"); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < networkTestMinBytes || parsed > networkTestMaxBytes {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_network_test_size"})
			return
		}
		size = parsed
	}
	if !networkTestAllowBytes(w, r, size) {
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.WriteHeader(http.StatusOK)
	// crypto/rand supplies noncompressible data in bounded io.Copy buffers.
	// A disconnected client terminates the copy, and no file is touched.
	_, _ = io.CopyN(w, rand.Reader, size)
}

func (a *API) networkTestUpload(w http.ResponseWriter, r *http.Request) {
	networkTestHeaders(w)
	if r.ContentLength < networkTestMinBytes ||
		r.ContentLength > networkTestMaxBytes {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_network_test_size"})
		return
	}
	if !networkTestAdmit(w) {
		return
	}
	defer func() { <-networkTestSlots }()
	if !networkTestAllowBytes(w, r, r.ContentLength) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, networkTestMaxBytes)
	defer r.Body.Close()
	written, err := io.CopyN(io.Discard, r.Body, r.ContentLength)
	if err != nil || written != r.ContentLength {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "network_test_incomplete"})
		return
	}
	// Verify that the fixed-length request contains no trailing data.
	var extra [1]byte
	if n, _ := r.Body.Read(extra[:]); n != 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_network_test_size"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"receivedBytes": written})
}
