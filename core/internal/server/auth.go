package server

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const sessionCookie = "lightisle_session"

func originMatchesHost(origin, host string) bool {
	parsed, err := url.Parse(origin)
	return err == nil && (parsed.Scheme == "https" || parsed.Scheme == "http") &&
		strings.EqualFold(parsed.Host, host) && parsed.User == nil &&
		parsed.RawQuery == "" && parsed.Fragment == ""
}
func (a *API) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		user, ok := a.auth.Identity(token(r))
		if !ok || user.Role != auth.RoleAdmin {
			jsonReply(w, 403, map[string]string{"error": "admin_only"})
			return
		}
		next(w, r)
	})
}
func isLocal(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	addr := net.ParseIP(host)
	return addr != nil && addr.IsLoopback()
}
func token(r *http.Request) string {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	return c.Value
}
func (a *API) requireLogin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if a.auth == nil || !a.auth.Session(token(r)) {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		next(w, r)
	}
}
func (a *API) authStatus(w http.ResponseWriter, r *http.Request) {
	if a.auth == nil {
		jsonReply(w, 503, map[string]string{"error": "database_not_ready"})
		return
	}
	ok, err := a.auth.Configured()
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "database_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]bool{"configured": ok})
}

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func decodeCredentials(w http.ResponseWriter, r *http.Request) (credentials, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var c credentials
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil || len(c.Username) > 32 || len(c.Password) > 256 {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return c, false
	}
	return c, true
}
func (a *API) setup(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r.RemoteAddr) {
		jsonReply(w, 403, map[string]string{"error": "local_setup_only"})
		return
	}
	if a.auth == nil {
		jsonReply(w, 503, map[string]string{"error": "database_not_ready"})
		return
	}
	c, ok := decodeCredentials(w, r)
	if !ok {
		return
	}
	err := a.auth.Setup(c.Username, c.Password)
	switch {
	case err == nil:
		jsonReply(w, 201, map[string]any{"created": true})
	case errors.Is(err, auth.ErrExists):
		jsonReply(w, 409, map[string]string{"error": "already_configured"})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, 400, map[string]string{"error": "username_or_password_invalid"})
	default:
		jsonReply(w, 500, map[string]string{"error": "setup_failed"})
	}
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	if a.auth == nil {
		jsonReply(w, 503, map[string]string{"error": "database_not_ready"})
		return
	}
	c, ok := decodeCredentials(w, r)
	if !ok {
		return
	}
	if !a.limiter.allow(r.RemoteAddr, c.Username) {
		jsonReply(w, 429, map[string]string{"error": "too_many_attempts"})
		return
	}
	session, err := a.auth.Login(c.Username, c.Password)
	if err != nil {
		a.limiter.fail(r.RemoteAddr, c.Username)
		jsonReply(w, 401, map[string]string{"error": "invalid_credentials"})
		return
	}
	a.limiter.success(r.RemoteAddr, c.Username)
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: session, Path: "/", HttpOnly: true,
		Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode,
		MaxAge: 7 * 24 * 3600,
	})
	user, _ := a.auth.Identity(session)
	jsonReply(w, 200, map[string]any{"authenticated": true, "username": user.Username, "role": user.Role})
}
func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	if a.auth != nil {
		a.auth.Logout(token(r))
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: "", Path: "/", HttpOnly: true,
		Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode, MaxAge: -1,
	})
	jsonReply(w, 200, map[string]bool{"authenticated": false})
}
func (a *API) me(w http.ResponseWriter, r *http.Request) {
	if a.auth == nil {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	jsonReply(w, 200, map[string]any{"authenticated": true, "username": user.Username, "role": user.Role})
}

func (a *API) users(w http.ResponseWriter, r *http.Request) {
	users, err := a.auth.ListUsers(token(r))
	if err != nil {
		jsonReply(w, 500, map[string]string{"error": "users_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]any{"users": users})
}
func (a *API) addUser(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var payload struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Role     string `json:"role"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&payload); err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if payload.Role == "" {
		payload.Role = auth.RoleMember
	}
	user, err := a.auth.CreateUser(token(r), payload.Username, payload.Password, payload.Role)
	switch {
	case err == nil:
		jsonReply(w, 201, user)
	case errors.Is(err, auth.ErrExists):
		jsonReply(w, 409, map[string]string{"error": "username_exists"})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, 400, map[string]string{"error": "invalid_account"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, 403, map[string]string{"error": "admin_only"})
	default:
		jsonReply(w, 500, map[string]string{"error": "create_failed"})
	}
}
func (a *API) changeUser(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id < 1 {
		jsonReply(w, 400, map[string]string{"error": "invalid_user"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var payload struct {
		Enabled *bool `json:"enabled"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&payload); err != nil || payload.Enabled == nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	err = a.auth.SetEnabled(token(r), id, *payload.Enabled)
	switch {
	case err == nil:
		jsonReply(w, 200, map[string]bool{"updated": true})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, 403, map[string]string{"error": "protected_account"})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, 404, map[string]string{"error": "user_not_found"})
	default:
		jsonReply(w, 500, map[string]string{"error": "update_failed"})
	}
}

// Lightweight per-remote-address + account throttle. Account-mode is intended
// for a trusted LAN; the map is bounded and old entries expire automatically.
type attempt struct {
	n     int
	until time.Time
}
type loginLimiter struct {
	mu      sync.Mutex
	entries map[string]attempt
}

func newLoginLimiter() *loginLimiter { return &loginLimiter{entries: map[string]attempt{}} }
func (l *loginLimiter) key(remote, user string) string {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	return host + "|" + strings.ToLower(user)
}
func (l *loginLimiter) allow(remote, user string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	key := l.key(remote, user)
	e, ok := l.entries[key]
	if !ok || time.Now().After(e.until) {
		delete(l.entries, key)
		return true
	}
	return e.n < 6
}
func (l *loginLimiter) fail(remote, user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	for k, v := range l.entries {
		if now.After(v.until) {
			delete(l.entries, k)
		}
	}
	// Avoid unbounded memory allocation under adversarial username attempts.
	if len(l.entries) > 2048 {
		l.entries = map[string]attempt{}
	}
	k := l.key(remote, user)
	v := l.entries[k]
	if now.After(v.until) {
		v = attempt{until: now.Add(15 * time.Minute)}
	}
	v.n++
	l.entries[k] = v
}
func (l *loginLimiter) success(remote, user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, l.key(remote, user))
}
