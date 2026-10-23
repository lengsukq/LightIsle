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

func (a *API) resetMemberPassword(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_user"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var body struct {
		Password string `json:"password"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&body); err != nil || body.Password == "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	err = a.auth.ResetMemberPassword(token(r), id, body.Password)
	switch {
	case err == nil:
		jsonReply(w, http.StatusOK, map[string]bool{"reset": true, "sessionsRevoked": true})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_new_password"})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "user_not_found"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "protected_account"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "password_reset_failed"})
	}
}
func (a *API) changeOwnPassword(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var payload struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&payload); err != nil || payload.CurrentPassword == "" || payload.NewPassword == "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	key := "password-change:" + user.Username
	if !a.limiter.admit(r.RemoteAddr, key) {
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "too_many_attempts"})
		return
	}
	err := a.auth.ChangePassword(token(r), payload.CurrentPassword, payload.NewPassword)
	switch {
	case err == nil:
		a.limiter.success(r.RemoteAddr, key)
		http.SetCookie(w, &http.Cookie{
			Name: sessionCookie, Value: "", Path: "/", HttpOnly: true,
			Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode, MaxAge: -1,
		})
		jsonReply(w, http.StatusOK, map[string]bool{"changed": true, "authenticated": false})
	case errors.Is(err, auth.ErrInvalid):
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "current_password_invalid"})
	case errors.Is(err, auth.ErrInput):
		a.limiter.cancel(r.RemoteAddr, key)
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_new_password"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
	default:
		a.limiter.cancel(r.RemoteAddr, key)
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "password_change_failed"})
	}
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
	if !a.limiter.admit(r.RemoteAddr, c.Username) {
		jsonReply(w, 429, map[string]string{"error": "too_many_attempts"})
		return
	}
	session, err := a.auth.Login(c.Username, c.Password)
	switch {
	case err == nil:
	case errors.Is(err, auth.ErrInvalid):
		jsonReply(w, 401, map[string]string{"error": "invalid_credentials"})
		return
	default:
		a.limiter.cancel(r.RemoteAddr, c.Username)
		jsonReply(w, 500, map[string]string{"error": "login_failed"})
		return
	}
	if a.afterLogin != nil {
		a.afterLogin()
	}
	user, ok := a.auth.Identity(session)
	if !ok {
		a.limiter.cancel(r.RemoteAddr, c.Username)
		a.auth.Logout(session)
		jsonReply(w, 500, map[string]string{"error": "login_failed"})
		return
	}
	a.limiter.success(r.RemoteAddr, c.Username)

	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: session, Path: "/", HttpOnly: true,
		Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode,
		MaxAge: int(auth.SessionLifetime.Seconds()),
	})
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

const (
	loginAttemptLimit = 6
	// loginRemoteAttemptLimit caps total attempts from one remote address so
	// username spraying stays bounded. It is deliberately several times the
	// per-account limit: failures against one account must not consume the
	// budget shared by other accounts behind the same NAT egress.
	loginRemoteAttemptLimit = 4 * loginAttemptLimit
	loginWindow             = 15 * time.Minute
	loginLimiterKeys        = 2048
)

// Login attempts are reserved atomically before Argon2 work begins. This keeps
// concurrent requests from all passing the same preflight check. Each attempt
// occupies one account bucket and one remote bucket, so a bucket counts toward
// the same bounded key capacity; when full, previously unseen keys are refused
// rather than deleting existing attempts or active lockouts.
type attempt struct {
	n     int
	until time.Time
}
type loginLimiter struct {
	mu      sync.Mutex
	entries map[string]attempt
	now     func() time.Time
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{entries: map[string]attempt{}, now: time.Now}
}
func (l *loginLimiter) host(remote string) string {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	return host
}
func (l *loginLimiter) admit(remote, username string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for key, value := range l.entries {
		if !now.Before(value.until) {
			delete(l.entries, key)
		}
	}
	accountKey := "account|" + strings.ToLower(username)
	remoteKey := "remote|" + l.host(remote)
	account, accountOK := l.entries[accountKey]
	origin, originOK := l.entries[remoteKey]
	if accountOK && account.n >= loginAttemptLimit {
		return false
	}
	if originOK && origin.n >= loginRemoteAttemptLimit {
		return false
	}
	newKeys := 0
	if !accountOK {
		newKeys++
	}
	if !originOK {
		newKeys++
	}
	if len(l.entries)+newKeys > loginLimiterKeys {
		return false
	}
	account.n++
	account.until = now.Add(loginWindow)
	l.entries[accountKey] = account
	origin.n++
	origin.until = now.Add(loginWindow)
	l.entries[remoteKey] = origin
	return true
}
func (l *loginLimiter) success(remote, username string) {
	l.cancel(remote, username)
}
func (l *loginLimiter) cancel(remote, username string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.decrement("account|" + strings.ToLower(username))
	l.decrement("remote|" + l.host(remote))
}
func (l *loginLimiter) decrement(key string) {
	value, ok := l.entries[key]
	if !ok {
		return
	}
	if value.n > 0 {
		value.n--
	}
	if value.n == 0 {
		delete(l.entries, key)
		return
	}
	l.entries[key] = value
}
