package server

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

// Public share password flow: the capability token alone is not enough when
// the creator set a password. The browser first receives a self-contained
// HTML form (401); a correct POST password mints a short-lived grant cookie
// held only in this process's memory, and the following GET streams the file.
// Wrong passwords are rate-limited per link and client address, and every
// invalid or exhausted link keeps the uniform-404 property.
const (
	shareGrantCookie   = "lightisle_share_grant"
	shareGrantLifetime = 15 * time.Minute
	sharePasswordLimit = 10
	sharePasswordTTL   = 15 * time.Minute
)

type shareGrant struct {
	digest  []byte
	expires time.Time
}

type shareGrantStore struct {
	mu       sync.Mutex
	grants   map[string]shareGrant
	attempts map[string]*sharePasswordAttempts
}

type sharePasswordAttempts struct {
	count     int
	windowEnd time.Time
}

func newShareGrantStore() *shareGrantStore {
	return &shareGrantStore{grants: map[string]shareGrant{}, attempts: map[string]*sharePasswordAttempts{}}
}

// mint creates a one-link grant after a successful password verification.
func (s *shareGrantStore) mint(digest []byte) (string, bool) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", false
	}
	value := base64.RawURLEncoding.EncodeToString(secret)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gcLocked()
	s.grants[value] = shareGrant{digest: append([]byte(nil), digest...), expires: time.Now().Add(shareGrantLifetime)}
	return value, true
}

// verify reports whether the cookie still grants this exact link.
func (s *shareGrantStore) verify(value string, digest []byte) bool {
	if value == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gcLocked()
	grant, ok := s.grants[value]
	if !ok || time.Now().After(grant.expires) {
		return false
	}
	return subtle.ConstantTimeCompare(grant.digest, digest) == 1
}

// allowPasswordAttempt applies the per-link+address brute-force budget.
func (s *shareGrantStore) allowPasswordAttempt(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	entry, ok := s.attempts[key]
	if !ok || now.After(entry.windowEnd) {
		s.attempts[key] = &sharePasswordAttempts{count: 1, windowEnd: now.Add(sharePasswordTTL)}
		return true
	}
	entry.count++
	return entry.count <= sharePasswordLimit
}

func (s *shareGrantStore) gcLocked() {
	now := time.Now()
	for value, grant := range s.grants {
		if now.After(grant.expires) {
			delete(s.grants, value)
		}
	}
	if len(s.attempts) > 4096 {
		s.attempts = map[string]*sharePasswordAttempts{}
	}
}

// sharePasswordClientKey scopes the brute-force budget to one link and
// address pair; the key never leaves this process.
func sharePasswordClientKey(r *http.Request, token string) string {
	return token + "|" + r.RemoteAddr
}

const sharePasswordForm = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>LightIsle 分享下载</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#101319;color:#eef2f8;
font:14px/1.6 -apple-system,"PingFang SC","Segoe UI",sans-serif}
main{width:min(92vw,380px);background:#1a1f29;border:1px solid #2c3442;border-radius:14px;padding:26px}
h1{font-size:17px;margin:0 0 6px}
p{margin:0 0 16px;color:#9aa4b5;font-size:12.5px}
label{display:block;font-size:12.5px;margin-bottom:6px;color:#c6cdd9}
input{width:100%;box-sizing:border-box;padding:10px;border-radius:8px;border:1px solid #3a4354;
background:#12161e;color:#eef2f8;font-size:14px}
button{width:100%;margin-top:14px;padding:11px;border:0;border-radius:8px;background:#0a84ff;
color:#fff;font-size:14px;font-weight:600;cursor:pointer}
.error{color:#ff9f9f;font-size:12.5px;margin:0 0 12px}
.meta{margin-top:14px;font-size:11.5px;color:#7c8698}
</style></head><body><main>
<h1>此分享受密码保护</h1>
<p>{{META}}</p>
<p class="error">{{ERROR}}</p>
<form method="post" action="/api/v1/public/file/{{TOKEN}}">
<label for="password">访问密码</label>
<input id="password" name="password" type="password" autocomplete="off" autofocus required>
<button type="submit">验证并下载</button>
</form>
<p class="meta">LightIsle 限时分享 · 密码由创建者设置，验证通过后 15 分钟内可直接下载。</p>
</main></body></html>`

// sharePasswordChallenge writes the self-contained form. All interpolated
// values are server-generated; no user-supplied string reaches the template.
func sharePasswordChallenge(w http.ResponseWriter, status int, token, meta, message string) {
	body := sharePasswordForm
	body = strings.ReplaceAll(body, "{{META}}", meta)
	body = strings.ReplaceAll(body, "{{ERROR}}", message)
	body = strings.ReplaceAll(body, "{{TOKEN}}", token)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

// sharePasswordExpiry renders the form metadata line. remaining is empty for
// unlimited links.
func sharePasswordMeta(expiresAt int64, remaining string) string {
	line := "链接有效期至 " + time.Unix(expiresAt, 0).Format("2006-01-02 15:04")
	if remaining != "" {
		line += " · 剩余 " + remaining + " 次下载"
	}
	return line
}

// handleSharePassword processes the form POST. Any failure re-renders the
// form (with a message) rather than leaking which check failed.
func (a *API) handleSharePassword(w http.ResponseWriter, r *http.Request, access auth.ShareAccess, token string) {
	key := sharePasswordClientKey(r, token)
	if !a.shareGrants.allowPasswordAttempt(key) {
		sharePasswordChallenge(w, http.StatusTooManyRequests, token,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"尝试过于频繁，请 15 分钟后再试。")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		sharePasswordChallenge(w, http.StatusUnauthorized, token,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)), "")
		return
	}
	password := r.PostFormValue("password")
	if password == "" || len(password) > 256 || !auth.SharePasswordOK(access.PasswordHash, password) {
		sharePasswordChallenge(w, http.StatusUnauthorized, token,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"密码不正确，请重试。")
		return
	}
	value, ok := a.shareGrants.mint(access.Digest)
	if !ok {
		sharePasswordChallenge(w, http.StatusInternalServerError, token,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"授权生成失败，请重试。")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     shareGrantCookie,
		Value:    value,
		Path:     "/api/v1/public/file/",
		MaxAge:   int(shareGrantLifetime.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	http.Redirect(w, r, "/api/v1/public/file/"+token, http.StatusSeeOther)
}

// shareRemaining renders the download quota line; unlimited links stay blank.
func shareRemaining(access auth.ShareAccess) string {
	if access.MaxDownloads <= 0 {
		return ""
	}
	remaining := access.MaxDownloads - access.DownloadCount
	if remaining < 0 {
		remaining = 0
	}
	return strconv.Itoa(remaining)
}

// shareGrantValue extracts the optional grant cookie.
func shareGrantValue(r *http.Request) string {
	cookie, err := r.Cookie(shareGrantCookie)
	if err != nil {
		return ""
	}
	return cookie.Value
}
