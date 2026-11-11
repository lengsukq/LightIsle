// Package dav serves a WebDAV endpoint for cross-platform clients (Finder,
// Windows, Infuse, rclone). Authentication uses its own generated,
// revocable Basic-auth credentials; it never accepts the web session cookie
// or the X-LightIsle-Request CSRF header, and every operation re-checks the
// same per-user directory grants as the web file API.
package dav

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/diagnostics"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

type contextKey int

const userKey contextKey = 1

const (
	authFailureWindow   = 15 * time.Minute
	authFailureLimit    = 30
	authFailureKeys     = 4096
	maxDAVMetadataBytes = 64 << 10
)

// Keep file writes and metadata requests from monopolizing each other.
var (
	davWriteSlots    = make(chan struct{}, 3)
	davMetadataSlots = make(chan struct{}, 4)
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
	registry  *roots.Registry
	handler   *webdav.Handler
	limiter   *authLimiter
	now       func() time.Time
	pathMu    sync.Mutex
	pathLocks map[string]*pathWriteLock
	lockMu    sync.Mutex
	lockNS    *lockNamespace
	rootLocks map[string]*lockNamespace
	onChange  func(rootID string, generation uint64, dirs []string)
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

// NewRootRegistry binds /dav/ to the active RootRegistry default. Each
// request owns a verified rootID/generation lease and checks root-specific
// account grants, never legacy path grants or the retired shared-root.json.
func NewRootRegistry(store *auth.Store, registry *roots.Registry, onChange ...func(rootID string, generation uint64, dirs []string)) *Service {
	s := New(store, nil, nil)
	s.registry = registry
	if len(onChange) > 0 {
		s.onChange = onChange[0]
	}
	return s
}

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/dav" {
		http.Redirect(w, r, defaultDAVPrefix, http.StatusPermanentRedirect)
		return
	}
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
	var uploadController *http.ResponseController
	var uploadDeadlineRefresh time.Time
	if r.Method == http.MethodPut {
		uploadController = http.NewResponseController(w)
		// An early rejection can also trigger net/http body cleanup.
		now := time.Now()
		_ = uploadController.SetReadDeadline(now.Add(time.Minute))
		uploadDeadlineRefresh = now.Add(15 * time.Second)
		if r.ContentLength > maxDAVUploadBytes {
			jsonError(w, http.StatusRequestEntityTooLarge, "dav_upload_too_large")
			return
		}
	}
	var slots chan struct{}
	switch r.Method {
	case "COPY", http.MethodPut:
		slots = davWriteSlots
	case "PROPFIND", "PROPPATCH", "LOCK":
		slots = davMetadataSlots
	}
	if slots != nil {
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			w.Header().Set("Retry-After", "2")
			jsonError(w, http.StatusServiceUnavailable, "dav_busy")
			return
		}
	}
	// XML methods buffer request data during parsing. Validate the whole body
	// before dispatch so a valid XML prefix cannot hide an oversized tail.
	switch r.Method {
	case "PROPFIND", "PROPPATCH", "LOCK":
		if r.ContentLength > maxDAVMetadataBytes {
			jsonError(w, http.StatusRequestEntityTooLarge, "dav_metadata_too_large")
			return
		}
		controller := http.NewResponseController(w)
		if r.Body != nil {
			if err := controller.SetReadDeadline(time.Now().Add(15 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return
			}
			data, err := io.ReadAll(io.LimitReader(r.Body, maxDAVMetadataBytes+1))
			if err != nil {
				jsonError(w, http.StatusBadRequest, "dav_invalid_metadata")
				return
			}
			if len(data) > maxDAVMetadataBytes {
				jsonError(w, http.StatusRequestEntityTooLarge, "dav_metadata_too_large")
				return
			}
			// Keep the deadline through the error paths above so net/http's
			// request-body cleanup cannot wait indefinitely for the sender.
			_ = controller.SetReadDeadline(time.Time{})
			r.Body = io.NopCloser(bytes.NewReader(data))
		}
		if err := controller.SetWriteDeadline(time.Now().Add(30 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return
		}
	}
	if r.Method == "PROPFIND" {
		switch r.Header.Get("Depth") {
		case "":
			// Default to a bounded listing for clients that omit Depth.
			r.Header.Set("Depth", "1")
		case "infinity":
			w.Header().Set("Content-Type", "application/xml; charset=utf-8")
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `<D:error xmlns:D="DAV:"><D:propfind-finite-depth/></D:error>`)
			return
		}
	}
	if r.Method == "LOCK" {
		r.Header.Set("Timeout", boundedLockTimeout(r.Header.Get("Timeout")))
	}
	mount, err := s.selectMount(r, user)
	if err != nil {
		writeMountError(w, err)
		return
	}
	root, err := s.openRequestRoot(r.Context(), mount)
	if err != nil {
		jsonError(w, http.StatusServiceUnavailable, "share_root_offline")
		return
	}
	defer root.close()
	var destination string
	if r.Method == "COPY" || r.Method == "MOVE" {
		destination, err = mount.destination(r)
		if err != nil {
			jsonError(w, http.StatusBadRequest, "dav_invalid_destination")
			return
		}
		if overlappingDAVPaths(root.file, mount.relative(r.URL.Path), destination) {
			jsonError(w, http.StatusForbidden, "dav_source_destination_overlap")
			return
		}
	}
	lockNS := s.lockNamespaceFor(root)
	if r.Body == nil {
		r.Body = http.NoBody
	}
	body := &trackedBody{body: r.Body, controller: uploadController, refreshDeadline: uploadDeadlineRefresh}
	state := &requestState{
		service: s, user: user, root: root, lockNS: lockNS, method: r.Method, mount: mount,
		body: body, contentLength: r.ContentLength, ctx: r.Context(),
	}
	state.sourceName, _ = normalizeDAVName(mount.relative(r.URL.Path))
	if root.replace != nil && r.Method == "MOVE" && r.Header.Get("Overwrite") == "" {
		r.Header.Set("Overwrite", "T")
	}
	ctx := context.WithValue(r.Context(), userKey, user)
	ctx = context.WithValue(ctx, requestStateKey{}, state)
	state.ctx = ctx
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
	handler.Prefix = mount.prefix
	handler.LockSystem = &ownedLockSystem{inner: lockNS.inner, namespace: lockNS, state: state, requestPath: state.mount.relative(r.URL.Path)}
	response := &statusRecorder{ResponseWriter: w, state: state}
	if !serveDirectoryCopy(response, r, &handler, state, destination) {
		handler.ServeHTTP(response, r)
	}
	if r.Method == "PROPFIND" && state.walkLimited {
		// x/net may have started a 207 before enumerating children.
		// Do not let an incomplete listing look like a complete success.
		panic(http.ErrAbortHandler)
	}
	if r.Method == "COPY" && response.statusCode() >= 400 {
		state.cleanupCreated()
	}
	if s.onChange != nil && root.rootID != "" && root.current() && response.statusCode() >= 200 && response.statusCode() < 300 {
		if dirs := mutationDirectories(r.Method, mount.relative(r.URL.Path), destination); len(dirs) > 0 {
			s.onChange(root.rootID, root.generation, dirs)
		}
	}
}

func (s *Service) checkLockPath(w http.ResponseWriter, r *http.Request, state *requestState) (int, bool) {
	if r.Method != "LOCK" && r.Method != "UNLOCK" {
		return 0, false
	}
	fs := &grantedFS{service: s}
	name, err := normalizeDAVName(state.mount.relative(r.URL.Path))
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
			(record.userID != state.user.ID || !strings.EqualFold(record.name, name) || !sameIdentity(record.root, state.root.info)) {
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
			if !ok || record.userID != state.user.ID || !strings.EqualFold(record.name, name) ||
				!sameIdentity(record.root, state.root.info) {
				w.WriteHeader(http.StatusForbidden)
				return http.StatusForbidden, true
			}
		}
		for _, token := range tokens {
			if record, ok := state.lockNS.owner(token, s.now()); ok {
				if record.userID != state.user.ID || !sameIdentity(record.root, state.root.info) ||
					(r.ContentLength == 0 && !strings.EqualFold(record.name, name)) {
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
	switch r.Method {
	case http.MethodPut, http.MethodDelete, "COPY", "MOVE", "MKCOL", "LOCK":
	default:
		return 0, false
	}
	if r.Header.Get("If-Match") == "" && r.Header.Get("If-None-Match") == "" && r.Header.Get("If-Unmodified-Since") == "" {
		return 0, false
	}
	name, err := normalizeDAVName(state.mount.relative(r.URL.Path))
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
	state       *requestState
	status      int
	customError bool
}

func (w *statusRecorder) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	if status >= 400 && w.state.writeStatus != 0 {
		status = w.state.writeStatus
	}
	if status == http.StatusCreated && w.state.replacedPut {
		status = http.StatusNoContent
	}
	if w.state.conditionFailed && status != http.StatusPreconditionFailed && status >= 400 {
		status = http.StatusPreconditionFailed
	}
	w.status = status
	if status >= 400 && w.state.writeCode != "" {
		w.customError = true
		jsonError(w.ResponseWriter, status, w.state.writeCode)
		return
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusRecorder) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.customError || w.status == http.StatusNoContent {
		return len(p), nil
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
	diagnostics.SetErrorCode(w, code)
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
	if entry, ok := l.entries[ip]; ok {
		return now.Before(entry.blockedUntil)
	}
	if len(l.entries) >= authFailureKeys {
		l.trim(now)
	}
	return len(l.entries) >= authFailureKeys
}

func (l *authLimiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.entries) >= authFailureKeys {
		l.trim(now)
	}
	entry, ok := l.entries[ip]
	if !ok && len(l.entries) >= authFailureKeys {
		return
	}
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
