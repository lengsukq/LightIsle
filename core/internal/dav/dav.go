// Package dav serves a WebDAV endpoint for cross-platform clients (Finder,
// Windows, Infuse, rclone). Authentication uses its own generated,
// revocable Basic-auth credentials; it never accepts the web session cookie
// or the X-LightIsle-Request CSRF header, and every operation re-checks the
// same per-user directory grants as the web file API.
package dav

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type contextKey int

const userKey contextKey = 1

const (
	authFailureWindow = 15 * time.Minute
	authFailureLimit  = 30
)

// ErrUnavailable reports an offline share root; ErrDenied reports an
// authorization failure.
var (
	ErrUnavailable = errors.New("share root offline")
	ErrDenied      = errors.New("dav access denied")
)

type Service struct {
	store   *auth.Store
	root    func() (string, bool)
	trash   func(rel string) error
	handler *webdav.Handler
	limiter *authLimiter
	now     func() time.Time
}

// New builds the WebDAV service. root returns the current share-root path
// and whether it is online; trash moves a relative path into the application
// trash instead of deleting it permanently (nil trashes nothing and DELETE
// is refused).
func New(store *auth.Store, root func() (string, bool), trash func(rel string) error) *Service {
	s := &Service{store: store, root: root, trash: trash, limiter: newAuthLimiter(), now: time.Now}
	s.handler = &webdav.Handler{
		Prefix:     "/dav/",
		FileSystem: &grantedFS{service: s},
		LockSystem: webdav.NewMemLS(),
	}
	return s
}

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	username, password, ok := r.BasicAuth()
	if !ok || username == "" || password == "" {
		s.challenge(w)
		return
	}
	ip := clientIP(r)
	if s.limiter.blocked(ip, s.now()) {
		s.challenge(w)
		return
	}
	user, err := s.store.VerifyDAVCredential(username, password)
	if err != nil {
		s.limiter.fail(ip, s.now())
		if !errors.Is(err, auth.ErrForbidden) {
			slog.Warn("dav credential lookup failed", "error", err)
		}
		s.challenge(w)
		return
	}
	if _, online := s.root(); !online {
		jsonError(w, http.StatusServiceUnavailable, "share_root_offline")
		return
	}
	ctx := context.WithValue(r.Context(), userKey, user)
	s.handler.ServeHTTP(w, r.WithContext(ctx))
}

func (s *Service) challenge(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Basic realm="LightIsle WebDAV", charset="UTF-8"`)
	jsonError(w, http.StatusUnauthorized, "dav_unauthorized")
}

func jsonError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"error":"` + code + `"}`))
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// authLimiter throttles repeated Basic-auth failures per client address,
// mirroring the login limiter discipline for a non-interactive transport.
type authLimiter struct {
	mu      sync.Mutex
	entries map[string]*authFailure
}

type authFailure struct {
	count        int
	windowStart  time.Time
	blockedUntil time.Time
}

func newAuthLimiter() *authLimiter {
	return &authLimiter{entries: map[string]*authFailure{}}
}

func (l *authLimiter) blocked(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry, ok := l.entries[ip]
	if !ok {
		return false
	}
	return now.Before(entry.blockedUntil)
}

func (l *authLimiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.entries) > 4096 {
		l.trim(now)
	}
	entry, ok := l.entries[ip]
	if !ok || now.Sub(entry.windowStart) > authFailureWindow {
		l.entries[ip] = &authFailure{count: 1, windowStart: now}
		return
	}
	entry.count++
	if entry.count >= authFailureLimit {
		entry.blockedUntil = now.Add(authFailureWindow)
	}
}

func (l *authLimiter) trim(now time.Time) {
	for ip, entry := range l.entries {
		if now.Sub(entry.windowStart) > authFailureWindow && now.After(entry.blockedUntil) {
			delete(l.entries, ip)
		}
	}
}

// userFrom returns the authenticated account attached by the service.
func userFrom(ctx context.Context) (auth.User, bool) {
	user, ok := ctx.Value(userKey).(auth.User)
	return user, ok
}

// relativePath converts a webdav name ("/a/b") into the grant/manager path
// format ("a/b", root is ".").
func relativePath(name string) string {
	trimmed := strings.TrimPrefix(name, "/")
	if trimmed == "" {
		return "."
	}
	return trimmed
}
