package server

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"html"
	"net"
	"net/http"
	"os"
	"path"
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
	shareGrantLimit    = 4096
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
	if len(s.grants) >= shareGrantLimit {
		return "", false
	}
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
		if !ok && len(s.attempts) >= 4096 {
			for oldKey, old := range s.attempts {
				if !now.Before(old.windowEnd) {
					delete(s.attempts, oldKey)
				}
			}
			if len(s.attempts) >= 4096 {
				return false // Fail closed; do not reset existing lockouts.
			}
		}
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
}

// sharePasswordClientKey scopes the brute-force budget to one link and
// address pair; the key never leaves this process.
func sharePasswordClientKey(r *http.Request, token string) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return token + "|unknown"
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return token + "|unknown"
	}
	return token + "|" + ip.String()
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
<form method="post" action="{{ACTION}}">
<label for="password">访问密码</label>
<input id="password" name="password" type="password" autocomplete="off" autofocus required>
<button type="submit">验证并下载</button>
</form>
<p class="meta">LightIsle 限时分享 · 密码由创建者设置，验证通过后 15 分钟内可直接下载。</p>
</main></body></html>`

// sharePasswordChallenge writes the self-contained form. All interpolated
// values are server-generated; no user-supplied string reaches the template.
func sharePasswordChallenge(w http.ResponseWriter, status int, actionPath, meta, message string) {
	body := sharePasswordForm
	body = strings.ReplaceAll(body, "{{META}}", meta)
	body = strings.ReplaceAll(body, "{{ERROR}}", message)
	body = strings.ReplaceAll(body, "{{ACTION}}", html.EscapeString(actionPath))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
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
	linkPath := r.URL.Path
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		sharePasswordChallenge(w, http.StatusUnauthorized, linkPath,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)), "")
		return
	}
	password := r.PostFormValue("password")
	if !tryPasswordWork() {
		w.Header().Set("Retry-After", "1")
		sharePasswordChallenge(w, http.StatusServiceUnavailable, linkPath,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"密码验证繁忙，请稍后重试。")
		return
	}
	defer func() { <-passwordWorkSlots }()
	if !a.shareGrants.allowPasswordAttempt(key) {
		sharePasswordChallenge(w, http.StatusTooManyRequests, linkPath,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"尝试过于频繁，请 15 分钟后再试。")
		return
	}
	if password == "" || len(password) > 256 || !auth.SharePasswordOK(access.PasswordHash, password) {
		sharePasswordChallenge(w, http.StatusUnauthorized, linkPath,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"密码不正确，请重试。")
		return
	}
	value, ok := a.shareGrants.mint(access.Digest)
	if !ok {
		sharePasswordChallenge(w, http.StatusServiceUnavailable, linkPath,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)),
			"授权生成失败，请重试。")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     shareGrantCookie,
		Value:    value,
		Path:     strings.TrimSuffix(linkPath, "/"+token) + "/",
		MaxAge:   int(shareGrantLifetime.Seconds()),
		HttpOnly: true,
		Secure:   secureCookieRequest(r),
		SameSite: http.SameSiteLaxMode,
	})
	http.Redirect(w, r, linkPath, http.StatusSeeOther)
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

const sharePreviewPageTemplate = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{{NAME}} · LightIsle 分享</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#101319;color:#eef2f8;
font:14px/1.6 -apple-system,"PingFang SC","Segoe UI",sans-serif}
main{width:min(92vw,480px);background:#1a1f29;border:1px solid #2c3442;border-radius:16px;padding:26px;box-sizing:border-box}
h1{font-size:18px;margin:0 0 6px;word-break:break-all}
.meta{margin:0 0 16px;color:#9aa4b5;font-size:12.5px}
.preview{margin:0 0 18px;border-radius:12px;overflow:hidden;background:#0f131a;border:1px solid #262e3d;text-align:center}
.preview img,.preview video{max-width:100%;max-height:320px;display:block;margin:0 auto}
.preview audio{width:100%;display:block;padding:12px;box-sizing:border-box}
.actions{display:flex;gap:10px;flex-wrap:wrap}
a.btn{flex:1;min-width:140px;text-align:center;text-decoration:none;padding:11px 14px;border-radius:9px;
background:#0a84ff;color:#fff;font-size:14px;font-weight:600}
a.btn.secondary{background:#252c3a;color:#dce3f0;border:1px solid #364054}
</style></head><body><main>
<h1>{{NAME}}</h1>
<p class="meta">{{SIZE}} · {{META}}</p>
{{PREVIEW}}
<div class="actions">
<a class="btn" href="{{DOWNLOAD_URL}}">立即下载</a>
{{INLINE_ACTION}}
</div>
</main></body></html>`

func renderSharePreviewPage(w http.ResponseWriter, linkPath string, access auth.ShareAccess, info os.FileInfo) {
	baseName := path.Base(access.Path)
	escapedName := html.EscapeString(baseName)
	escapedDownload := html.EscapeString(linkPath + "?download=1")
	escapedInline := html.EscapeString(linkPath + "?inline=1")
	sizeLabel := "文件夹打包下载 (ZIP)"
	previewHTML := ""
	inlineAction := ""
	if access.Kind != auth.ShareKindDir && info != nil {
		sizeLabel = formatShareSize(info.Size())
		ext := strings.ToLower(path.Ext(baseName))
		// Only auto-embed media when download count is unlimited so opening
		// the preview page does not consume a one-time download quota.
		if access.MaxDownloads <= 0 {
			switch ext {
			case ".jpg", ".jpeg", ".png", ".gif", ".webp":
				previewHTML = `<div class="preview"><img src="` + escapedInline + `" alt="` + escapedName + `"></div>`
			case ".mp4", ".mov", ".m4v", ".webm", ".mkv":
				previewHTML = `<div class="preview"><video controls preload="metadata" src="` + escapedInline + `"></video></div>`
				inlineAction = `<a class="btn secondary" href="` + escapedInline + `">原画直链播放</a>`
			case ".mp3", ".m4a", ".flac", ".wav":
				previewHTML = `<div class="preview"><audio controls preload="metadata" src="` + escapedInline + `"></audio></div>`
			}
		}
	}
	body := sharePreviewPageTemplate
	body = strings.ReplaceAll(body, "{{NAME}}", escapedName)
	body = strings.ReplaceAll(body, "{{SIZE}}", html.EscapeString(sizeLabel))
	body = strings.ReplaceAll(body, "{{META}}", html.EscapeString(sharePasswordMeta(access.ExpiresAt, shareRemaining(access))))
	body = strings.ReplaceAll(body, "{{PREVIEW}}", previewHTML)
	body = strings.ReplaceAll(body, "{{DOWNLOAD_URL}}", escapedDownload)
	body = strings.ReplaceAll(body, "{{INLINE_ACTION}}", inlineAction)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; media-src 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(body))
}

func formatShareSize(bytes int64) string {
	switch {
	case bytes >= 1<<30:
		return fmt.Sprintf("%.2f GB", float64(bytes)/float64(1<<30))
	case bytes >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(bytes)/float64(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(bytes)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}
