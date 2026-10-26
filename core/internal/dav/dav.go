// Package dav serves a WebDAV endpoint for cross-platform clients (Finder,
// Windows, Infuse, rclone). Authentication uses its own generated,
// revocable Basic-auth credentials; it never accepts the web session cookie
// or the X-LightIsle-Request CSRF header, and every operation re-checks the
// same per-user directory grants as the web file API.
package dav

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
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
	store     *auth.Store
	root      func() (string, bool)
	trash     func(rel string) error
	lease     func() (*files.DAVRootLease, error)
	handler   *webdav.Handler
	limiter   *authLimiter
	now       func() time.Time
	pathMu    sync.Mutex
	pathLocks map[string]*pathWriteLock
	lockMu    sync.Mutex
	lockNS    *lockNamespace
}

type pathWriteLock struct {
	semaphore chan struct{}
	users     int
}

// New builds the WebDAV service. root returns the current share-root path
// and whether it is online; trash moves a relative path into the application
// trash instead of deleting it permanently (nil trashes nothing and DELETE
// is refused).
func New(store *auth.Store, root func() (string, bool), trash func(rel string) error,
	leaseProvider ...func() (*files.DAVRootLease, error)) *Service {
	s := &Service{
		store: store, root: root, trash: trash, limiter: newAuthLimiter(), now: time.Now,
		pathLocks: map[string]*pathWriteLock{},
	}
	if len(leaseProvider) > 0 {
		s.lease = leaseProvider[0]
	}
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
	root, err := s.openRequestRoot()
	if err != nil {
		jsonError(w, http.StatusServiceUnavailable, "share_root_offline")
		return
	}
	defer root.close()
	lockNS := s.lockNamespaceFor(root.info)
	if r.Body == nil {
		r.Body = http.NoBody
	}
	body := &trackedBody{body: r.Body}
	state := &requestState{service: s, user: user, root: root, lockNS: lockNS, method: r.Method, body: body}
	ctx := context.WithValue(r.Context(), userKey, user)
	ctx = context.WithValue(ctx, requestStateKey{}, state)
	r = r.WithContext(ctx)
	r.Body = body
	if status, handled := s.checkLockPath(w, r, state); handled {
		return
	} else if status != 0 {
		return
	}
	if status, handled := s.checkConditions(w, r, state); handled {
		return
	} else if status != 0 {
		return
	}
	handler := *s.handler
	handler.LockSystem = &ownedLockSystem{inner: lockNS.inner, namespace: lockNS, service: s, state: state, requestPath: requestPath(r.URL.Path)}
	response := &statusRecorder{ResponseWriter: w, state: state}
	handler.ServeHTTP(response, r)
	if r.Method == "COPY" && response.statusCode() >= 400 {
		state.cleanupCreated()
	}
}

func (s *Service) openRequestRoot() (*rootHandle, error) {
	if s.lease != nil {
		lease, err := s.lease()
		if err != nil || lease == nil || lease.Root == nil || !lease.IsCurrent() {
			if lease != nil {
				_ = lease.Close()
			}
			return nil, ErrUnavailable
		}
		return &rootHandle{
			path:     lease.Path,
			file:     lease.Root,
			info:     lease.Info,
			validate: lease.IsCurrent,
			trash:    lease.MoveToTrash,
			release:  func() { _ = lease.Close() },
		}, nil
	}
	if s.root == nil {
		return nil, ErrUnavailable
	}
	rootPath, online := s.root()
	if !online {
		return nil, ErrUnavailable
	}
	rootFile, err := openRootDirectory(rootPath)
	if err != nil {
		return nil, err
	}
	info, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		return nil, err
	}
	root := &rootHandle{path: rootPath, file: rootFile, info: info}
	root.validate = func() bool {
		currentPath, currentOnline := s.root()
		if !currentOnline || currentPath != rootPath {
			return false
		}
		current, openErr := openRootDirectory(rootPath)
		if openErr != nil {
			return false
		}
		defer current.Close()
		currentInfo, statErr := current.Stat()
		return statErr == nil && sameIdentity(info, currentInfo)
	}
	if !root.current() {
		root.close()
		return nil, ErrUnavailable
	}
	return root, nil
}

func requestPath(urlPath string) string {
	return strings.TrimPrefix(urlPath, "/dav/")
}

func (s *Service) checkLockPath(w http.ResponseWriter, r *http.Request, state *requestState) (int, bool) {
	if r.Method != "LOCK" && r.Method != "UNLOCK" {
		return 0, false
	}
	fs := &grantedFS{service: s}
	name, err := normalizeDAVName(requestPath(r.URL.Path))
	if err != nil {
		w.WriteHeader(http.StatusForbidden)
		return http.StatusForbidden, true
	}
	if _, _, err := fs.authorize(r.Context(), name, true); err != nil {
		w.WriteHeader(http.StatusForbidden)
		return http.StatusForbidden, true
	}
	var info os.FileInfo
	if name == "." {
		info, err = state.root.file.Stat()
	} else {
		info, err = secureStat(state.root.file, name)
	}
	if r.Method == "LOCK" && errors.Is(err, fsErrNotExist()) {
		return 0, false
	}
	if err != nil {
		status := http.StatusMethodNotAllowed
		if r.Method == "UNLOCK" && errors.Is(err, fsErrNotExist()) {
			status = http.StatusConflict
		}
		w.WriteHeader(status)
		return status, true
	}
	_ = info
	if r.Method == "UNLOCK" {
		token := strings.Trim(r.Header.Get("Lock-Token"), "<>")
		if record, ok := state.lockNS.owner(token, s.now()); ok &&
			(record.userID != state.user.ID || record.name != name || !sameIdentity(record.root, state.root.info)) {
			w.WriteHeader(http.StatusForbidden)
			return http.StatusForbidden, true
		}
	}
	if r.Method == "LOCK" {
		tokens := lockTokens(r.Header.Get("If"))
		if r.ContentLength == 0 {
			if len(tokens) != 1 {
				w.WriteHeader(http.StatusForbidden)
				return http.StatusForbidden, true
			}
			record, ok := state.lockNS.owner(tokens[0], s.now())
			if !ok || record.userID != state.user.ID || record.name != name ||
				!sameIdentity(record.root, state.root.info) {
				w.WriteHeader(http.StatusForbidden)
				return http.StatusForbidden, true
			}
		}
		for _, token := range tokens {
			if record, ok := state.lockNS.owner(token, s.now()); ok {
				if record.userID != state.user.ID || !sameIdentity(record.root, state.root.info) ||
					(r.ContentLength == 0 && record.name != name) {
					w.WriteHeader(http.StatusForbidden)
					return http.StatusForbidden, true
				}
			}
		}
	}
	return 0, false
}

func lockTokens(header string) []string {
	var tokens []string
	for len(header) > 0 {
		start := strings.IndexByte(header, '<')
		if start < 0 {
			break
		}
		header = header[start+1:]
		end := strings.IndexByte(header, '>')
		if end < 0 {
			break
		}
		if token := strings.TrimSpace(header[:end]); token != "" {
			tokens = append(tokens, token)
		}
		header = header[end+1:]
	}
	return tokens
}

// fsErrNotExist provides a single comparison point for wrapped filesystem
// errors without importing platform-specific errno values into this file.
func fsErrNotExist() error { return os.ErrNotExist }

func (s *Service) checkConditions(w http.ResponseWriter, r *http.Request, state *requestState) (int, bool) {
	if r.Header.Get("If-Match") == "" && r.Header.Get("If-None-Match") == "" && r.Header.Get("If-Unmodified-Since") == "" {
		return 0, false
	}
	name, err := normalizeDAVName(requestPath(r.URL.Path))
	if err != nil {
		return 0, false
	}
	write := r.Method != "COPY"
	fs := &grantedFS{service: s}
	if _, _, err := fs.authorize(r.Context(), name, write); err != nil {
		// Let the DAV handler preserve its usual authorization response.
		return 0, false
	}
	info, statErr := secureStat(state.root.file, name)
	exists := statErr == nil
	if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return 0, false
	}
	preconditions := &requestPreconditions{
		pathName:          name,
		ifMatch:           r.Header.Get("If-Match"),
		ifNoneMatch:       r.Header.Get("If-None-Match"),
		ifUnmodifiedSince: r.Header.Get("If-Unmodified-Since"),
		initialExists:     exists,
		initialInfo:       info,
	}
	if !validETagHeader(preconditions.ifMatch) || !validETagHeader(preconditions.ifNoneMatch) {
		w.WriteHeader(http.StatusBadRequest)
		return http.StatusBadRequest, true
	}
	if !preconditions.matches(info, exists) {
		w.WriteHeader(http.StatusPreconditionFailed)
		return http.StatusPreconditionFailed, true
	}
	state.preconditions = preconditions
	return 0, false
}

func davETag(info os.FileInfo) string {
	return fmt.Sprintf(`"%x%x"`, info.ModTime().UnixNano(), info.Size())
}

func validETagHeader(value string) bool {
	if value == "" {
		return true
	}
	for _, raw := range strings.Split(value, ",") {
		tag := strings.TrimSpace(raw)
		if tag == "*" {
			continue
		}
		if strings.HasPrefix(tag, "W/") {
			tag = strings.TrimPrefix(tag, "W/")
		}
		if len(tag) < 2 || tag[0] != '"' || tag[len(tag)-1] != '"' || strings.ContainsAny(tag[1:len(tag)-1], "\r\n") {
			return false
		}
	}
	return true
}

func etagListMatches(header, current string, weak bool) bool {
	for _, raw := range strings.Split(header, ",") {
		tag := strings.TrimSpace(raw)
		if tag == "*" {
			return true
		}
		if weak {
			tag = strings.TrimPrefix(tag, "W/")
		}
		if tag == current {
			return true
		}
	}
	return false
}

func (s *Service) lockPath(ctx context.Context, root *rootHandle, name string) (func(), error) {
	dev, ino, _, _, ok := fileIdentity(root.info)
	if !ok {
		return nil, ErrUnavailable
	}
	key := fmt.Sprintf("%s:%x:%x:%s", root.path, dev, ino, name)
	s.pathMu.Lock()
	lock := s.pathLocks[key]
	if lock == nil {
		lock = &pathWriteLock{semaphore: make(chan struct{}, 1)}
		lock.semaphore <- struct{}{}
		s.pathLocks[key] = lock
	}
	lock.users++
	s.pathMu.Unlock()
	select {
	case <-ctx.Done():
		s.releasePathRef(key, lock, false)
		return nil, ctx.Err()
	case <-lock.semaphore:
		return func() {
			lock.semaphore <- struct{}{}
			s.releasePathRef(key, lock, false)
		}, nil
	}
}

func (s *Service) releasePathRef(key string, lock *pathWriteLock, releaseToken bool) {
	if releaseToken {
		lock.semaphore <- struct{}{}
	}
	s.pathMu.Lock()
	lock.users--
	if lock.users == 0 {
		delete(s.pathLocks, key)
	}
	s.pathMu.Unlock()
}

type statusRecorder struct {
	http.ResponseWriter
	state  *requestState
	status int
}

func (w *statusRecorder) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	if w.state.conditionFailed && status != http.StatusPreconditionFailed && status >= 400 {
		status = http.StatusPreconditionFailed
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusRecorder) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(p)
}

func (w *statusRecorder) statusCode() int {
	if w.status == 0 {
		return http.StatusOK
	}
	return w.status
}

func (w *statusRecorder) Unwrap() http.ResponseWriter { return w.ResponseWriter }

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
