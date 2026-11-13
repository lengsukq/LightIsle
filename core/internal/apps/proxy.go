package apps

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	appCookieMaxAge = 43200 // 12 hours
	ticketTTL       = 60 * time.Second
)

type appCookieClaims struct {
	AppID    string `json:"appId"`
	UserID   int64  `json:"userId"`
	Username string `json:"username"`
	Role     string `json:"role"`
	GrantID  string `json:"gid,omitempty"`
	Expires  int64  `json:"exp"`
}

func AppCookieName(appID string) string {
	return "lightisle_app_" + appID
}

// IssueTicket creates a single-use 60-second launch ticket for cross-client
// (Flutter WebView / external browser tab / iframe) session bootstrap.
func (m *Manager) IssueTicket(appID string, user UserIdentity) string {
	raw := make([]byte, 24)
	_, _ = rand.Read(raw)
	ticket := hex.EncodeToString(raw)
	now := time.Now()

	m.mu.Lock()
	for k, v := range m.tickets {
		if now.After(v.ExpiresAt) {
			delete(m.tickets, k)
		}
	}
	for len(m.tickets) >= maxAppTickets {
		var oldestKey string
		var oldestExp time.Time
		for k, v := range m.tickets {
			if oldestKey == "" || v.ExpiresAt.Before(oldestExp) {
				oldestKey = k
				oldestExp = v.ExpiresAt
			}
		}
		if oldestKey == "" {
			break
		}
		delete(m.tickets, oldestKey)
	}
	m.tickets[ticket] = ticketRecord{
		AppID:     appID,
		User:      user,
		ExpiresAt: now.Add(ticketTTL),
	}
	m.mu.Unlock()
	return ticket
}

// ConsumeTicket atomically validates and deletes a single-use launch ticket,
// and re-verifies the backing account/session is still active.
func (m *Manager) ConsumeTicket(appID, ticket string) (UserIdentity, bool) {
	if ticket == "" || appID == "" {
		return UserIdentity{}, false
	}
	m.mu.Lock()
	rec, ok := m.tickets[ticket]
	if ok {
		delete(m.tickets, ticket)
	}
	verifier := m.verifyUser
	m.mu.Unlock()
	if !ok || rec.AppID != appID || time.Now().After(rec.ExpiresAt) {
		return UserIdentity{}, false
	}
	if verifier != nil {
		return verifier(rec.User)
	}
	return rec.User, true
}

func (m *Manager) SignAppCookie(appID string, user UserIdentity, ttl time.Duration) string {
	if ttl <= 0 {
		ttl = time.Duration(appCookieMaxAge) * time.Second
	}
	now := time.Now()
	expiresAt := now.Add(ttl)
	var grantID string
	if user.SessionToken != "" {
		sum := sha256.Sum256([]byte(user.SessionToken))
		grantID = hex.EncodeToString(sum[:16])
		m.mu.Lock()
		if _, exists := m.sessionGrants[grantID]; !exists && len(m.sessionGrants) >= maxSessionGrants {
			for k, g := range m.sessionGrants {
				if now.After(g.expiresAt) {
					delete(m.sessionGrants, k)
				}
			}
			for len(m.sessionGrants) >= maxSessionGrants {
				var oldestKey string
				var oldestExp time.Time
				for k, g := range m.sessionGrants {
					if oldestKey == "" || g.expiresAt.Before(oldestExp) {
						oldestKey = k
						oldestExp = g.expiresAt
					}
				}
				if oldestKey == "" {
					break
				}
				delete(m.sessionGrants, oldestKey)
			}
		}
		m.sessionGrants[grantID] = sessionGrant{
			sessionToken: user.SessionToken,
			expiresAt:    expiresAt,
		}
		m.mu.Unlock()
	}
	claims := appCookieClaims{
		AppID:    appID,
		UserID:   user.ID,
		Username: user.Username,
		Role:     user.Role,
		GrantID:  grantID,
		Expires:  expiresAt.Unix(),
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return ""
	}
	block, err := aes.NewCipher(m.cookieSecret)
	if err != nil {
		return ""
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return ""
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return ""
	}
	sealed := gcm.Seal(nonce, nonce, payload, []byte(appID))
	return base64.RawURLEncoding.EncodeToString(sealed)
}

func (m *Manager) VerifyAppCookie(appID, cookieValue string) (UserIdentity, bool) {
	if appID == "" || cookieValue == "" {
		return UserIdentity{}, false
	}
	sealed, err := base64.RawURLEncoding.DecodeString(cookieValue)
	if err != nil {
		return UserIdentity{}, false
	}
	block, err := aes.NewCipher(m.cookieSecret)
	if err != nil {
		return UserIdentity{}, false
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil || len(sealed) < gcm.NonceSize() {
		return UserIdentity{}, false
	}
	nonce := sealed[:gcm.NonceSize()]
	payload, err := gcm.Open(nil, nonce, sealed[gcm.NonceSize():], []byte(appID))
	if err != nil {
		return UserIdentity{}, false
	}
	var claims appCookieClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return UserIdentity{}, false
	}
	now := time.Now()
	if claims.AppID != appID || claims.UserID <= 0 || now.Unix() > claims.Expires {
		return UserIdentity{}, false
	}
	m.mu.Lock()
	var sessionToken string
	if claims.GrantID != "" {
		if g, ok := m.sessionGrants[claims.GrantID]; ok {
			if now.After(g.expiresAt) {
				delete(m.sessionGrants, claims.GrantID)
			} else {
				sessionToken = g.sessionToken
			}
		}
	}
	verifier := m.verifyUser
	m.mu.Unlock()
	if claims.GrantID != "" && sessionToken == "" {
		return UserIdentity{}, false
	}
	u := UserIdentity{
		ID:           claims.UserID,
		Username:     claims.Username,
		Role:         claims.Role,
		SessionToken: sessionToken,
	}
	if verifier != nil {
		verified, ok := verifier(u)
		if !ok && claims.GrantID != "" {
			m.mu.Lock()
			if cur, exists := m.sessionGrants[claims.GrantID]; exists && cur.sessionToken == sessionToken {
				delete(m.sessionGrants, claims.GrantID)
			}
			m.mu.Unlock()
		}
		return verified, ok
	}
	return u, true
}

func (m *Manager) ServeIcon(w http.ResponseWriter, r *http.Request, appID string) {
	rec, ok := m.snapshotApp(appID)
	if !ok || !rec.hasIcon || rec.manifest.Icon == "" {
		http.NotFound(w, r)
		return
	}
	if err := m.verifyRecordStorageOnline(rec.locationID, rec.pluginDir); err != nil {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(rec.pluginDir)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer root.Close()
	if !validChildName(rec.manifest.Icon) {
		http.NotFound(w, r)
		return
	}
	f, err := root.Open(rec.manifest.Icon)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	ext := strings.ToLower(filepath.Ext(rec.manifest.Icon))
	switch ext {
	case ".svg":
		w.Header().Set("Content-Type", "image/svg+xml")
	case ".png":
		w.Header().Set("Content-Type", "image/png")
	case ".jpg", ".jpeg":
		w.Header().Set("Content-Type", "image/jpeg")
	case ".webp":
		w.Header().Set("Content-Type", "image/webp")
	default:
		if ct := mime.TypeByExtension(ext); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
	}
	w.Header().Set("Cache-Control", "private, max-age=300, stale-while-revalidate=86400")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox")
	etag := `"` + strconv.FormatInt(st.Size(), 16) + `-` + strconv.FormatInt(st.ModTime().UnixNano(), 16) + `"`
	w.Header().Set("ETag", etag)
	if (r.Method == http.MethodGet || r.Method == http.MethodHead) && appIfNoneMatchContains(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}

func appIfNoneMatchContains(headerValue, etag string) bool {
	if headerValue == "" {
		return false
	}
	for _, raw := range strings.Split(headerValue, ",") {
		cand := strings.TrimSpace(raw)
		cand = strings.TrimPrefix(cand, "W/")
		if cand == "*" || cand == etag {
			return true
		}
	}
	return false
}

// ServeApp handles all /apps/{id} and /apps/{id}/{rest...} gateway traffic.
func (m *Manager) ServeApp(w http.ResponseWriter, r *http.Request, resolveSession func(*http.Request) (UserIdentity, bool)) {
	appID, rest, ok := parseAppRoute(r.URL.Path)
	if !ok || !ValidPluginID(appID) {
		http.NotFound(w, r)
		return
	}

	snap, exists := m.snapshotApp(appID)
	if !exists || !snap.valid {
		http.NotFound(w, r)
		return
	}
	rec := &snap

	setAppGatewayHeadersForApp(w.Header(), r, appID)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if rec.pendingActivation {
		writeAppError(w, http.StatusForbidden, "app_pending_activation", "该轻应用尚未经管理员首次激活确认，请先由管理员在应用中心启动或保存配置。")
		return
	}

	// 1. Check single-use launch ticket (?__li_ticket=...) and exchange for HttpOnly path-scoped cookie
	var user UserIdentity
	var authed bool
	if ticket := r.URL.Query().Get("__li_ticket"); ticket != "" {
		tUser, validTicket := m.ConsumeTicket(appID, ticket)
		if !validTicket {
			writeAppError(w, http.StatusUnauthorized, "invalid_launch_ticket", "应用启动凭证无效或已过期，请返回应用中心重新打开。")
			return
		}
		if !m.CanAccess(appID, tUser.ID, tUser.Role) {
			writeAppError(w, http.StatusForbidden, "app_access_forbidden", "当前账号无权访问该轻应用。")
			return
		}
		cookieVal := m.SignAppCookie(appID, tUser, time.Duration(appCookieMaxAge)*time.Second)
		http.SetCookie(w, &http.Cookie{
			Name:     AppCookieName(appID),
			Value:    cookieVal,
			Path:     "/apps/" + appID,
			HttpOnly: true,
			Secure:   isSecureReq(r),
			SameSite: http.SameSiteLaxMode,
			MaxAge:   appCookieMaxAge,
		})
		user = tUser
		authed = true

		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			q := r.URL.Query()
			q.Del("__li_ticket")
			subPath := rest
			if subPath == "" {
				subPath = "/"
			}
			targetPath := "/apps/" + appID + subPath
			if encoded := q.Encode(); encoded != "" {
				targetPath += "?" + encoded
			}
			http.Redirect(w, r, targetPath, http.StatusFound)
			return
		}
	}

	// 2. Authenticate via main session OR path-scoped HttpOnly app cookie
	if !authed && resolveSession != nil {
		if sUser, ok := resolveSession(r); ok {
			user = sUser
			authed = true
		}
	}
	if !authed {
		if c, err := r.Cookie(AppCookieName(appID)); err == nil && c.Value != "" {
			if cUser, ok := m.VerifyAppCookie(appID, c.Value); ok {
				user = cUser
				authed = true
			} else {
				http.SetCookie(w, &http.Cookie{
					Name:     AppCookieName(appID),
					Value:    "",
					Path:     "/apps/" + appID,
					HttpOnly: true,
					Secure:   isSecureReq(r),
					SameSite: http.SameSiteLaxMode,
					MaxAge:   -1,
				})
			}
		}
	}
	if !authed {
		writeAppError(w, http.StatusUnauthorized, "authentication_required", "请先登录 LightIsle 后再访问该应用。")
		return
	}
	if !m.CanAccess(appID, user.ID, user.Role) {
		writeAppError(w, http.StatusForbidden, "app_access_forbidden", "当前账号无权访问该轻应用。")
		return
	}
	if err := m.verifyRecordStorageOnline(rec.locationID, rec.pluginDir); err != nil {
		if rec.instance != nil {
			_ = rec.instance.Stop(false)
		}
		msg := "该轻应用当前离线（所在存储设备未连接），你的个人数据不受影响，请联系管理员检查连接。"
		if user.Role == "admin" {
			msg = err.Error()
		}
		writeAppError(w, http.StatusServiceUnavailable, "app_storage_offline", msg)
		return
	}

	// Refresh path-scoped cookie when accessed via main session so subsequent
	// sub-resource requests under /apps/<id> also carry a scoped HttpOnly cookie.
	if _, err := r.Cookie(AppCookieName(appID)); err != nil {
		cookieVal := m.SignAppCookie(appID, user, time.Duration(appCookieMaxAge)*time.Second)
		http.SetCookie(w, &http.Cookie{
			Name:     AppCookieName(appID),
			Value:    cookieVal,
			Path:     "/apps/" + appID,
			HttpOnly: true,
			Secure:   isSecureReq(r),
			SameSite: http.SameSiteLaxMode,
			MaxAge:   appCookieMaxAge,
		})
	}

	// 3. Built-in icon subroute
	if rest == "/__lightisle_icon" {
		m.ServeIcon(w, r, appID)
		return
	}

	if rec.manifest.Web == nil || !rec.manifest.Web.Enabled {
		writeAppError(w, http.StatusServiceUnavailable, "app_web_disabled", "该轻应用的 Web 界面当前已停用。")
		return
	}

	// 4. Static mode: zero-RSS direct file serving from os.Root
	if rec.manifest.Web.Mode == WebModeStatic {
		m.serveStaticApp(w, r, rec, rest)
		return
	}

	// 5. Dynamic mode (on-demand / persistent): wake & reverse proxy
	m.serveDynamicApp(w, r, rec, user, rest)
}

func (m *Manager) serveStaticApp(w http.ResponseWriter, r *http.Request, rec *appRecord, rest string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if rest == "" {
		target := r.URL.Path + "/"
		if r.URL.RawQuery != "" {
			target += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, target, http.StatusFound)
		return
	}
	staticDir := filepath.Join(rec.pluginDir, rec.manifest.Web.StaticDir)
	root, err := os.OpenRoot(staticDir)
	if err != nil {
		http.Error(w, "static directory unavailable", http.StatusServiceUnavailable)
		return
	}
	defer root.Close()

	rel := strings.TrimPrefix(filepath.Clean("/"+rest), "/")
	if rel == "" {
		rel = "index.html"
	}
	info, err := root.Stat(rel)
	if err == nil && info.IsDir() {
		rel = filepath.Join(rel, "index.html")
		info, err = root.Stat(rel)
	}
	if os.IsNotExist(err) && !strings.Contains(filepath.Base(rest), ".") {
		rel = "index.html"
		info, err = root.Stat(rel)
	}
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	f, err := root.Open(rel)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}

func (m *Manager) serveDynamicApp(w http.ResponseWriter, r *http.Request, rec *appRecord, user UserIdentity, rest string) {
	inst := rec.instance
	if inst == nil {
		writeAppError(w, http.StatusServiceUnavailable, "app_unavailable", "应用实例未初始化。")
		return
	}
	port, secret, err := inst.Wake(r.Context())
	if err != nil {
		writeGatewayDiagnosticError(w, r, http.StatusBadGateway, "app_wake_failed", rec.manifest.Name, rec.id, user.Role == "admin", inst.Diagnostic(), err.Error())
		return
	}

	inst.BeginStream()
	defer inst.EndStream()

	targetURL := &url.URL{
		Scheme: "http",
		Host:   fmt.Sprintf("127.0.0.1:%d", port),
	}

	strippedPath := rest
	if strippedPath == "" {
		strippedPath = "/"
	}
	fullPath := "/apps/" + rec.id + rest

	proxy := &httputil.ReverseProxy{
		FlushInterval: -1,
		Director: func(outReq *http.Request) {
			outReq.URL.Scheme = targetURL.Scheme
			outReq.URL.Host = targetURL.Host
			if inst.preferStrippedPath.Load() {
				outReq.URL.Path = strippedPath
			} else {
				outReq.URL.Path = fullPath
			}
			outReq.URL.RawPath = ""
			outReq.Host = targetURL.Host

			sanitizeProxyRequestHeaders(outReq)
			outReq.Header.Set("X-LightIsle-Proxy-Secret", secret)
			outReq.Header.Set("X-LightIsle-User-ID", strconv.FormatInt(user.ID, 10))
			outReq.Header.Set("X-LightIsle-Username", user.Username)
			outReq.Header.Set("X-LightIsle-Role", user.Role)
			outReq.Header.Set("X-Forwarded-Prefix", "/apps/"+rec.id)
		},
		Transport: &adaptiveAppTransport{
			base:         http.DefaultTransport,
			inst:         inst,
			fullPath:     fullPath,
			strippedPath: strippedPath,
		},
		ModifyResponse: func(resp *http.Response) error {
			setAppGatewayHeadersForApp(resp.Header, r, rec.id)
			return nil
		},
		ErrorHandler: func(rw http.ResponseWriter, req *http.Request, proxyErr error) {
			writeGatewayDiagnosticError(rw, req, http.StatusBadGateway, "app_proxy_error", rec.manifest.Name, rec.id, user.Role == "admin", inst.Diagnostic(), fmt.Sprintf("轻应用本地服务无响应: %v", proxyErr))
		},
	}
	proxy.ServeHTTP(w, r)
}

type adaptiveAppTransport struct {
	base         http.RoundTripper
	inst         *Instance
	fullPath     string
	strippedPath string
}

func (t *adaptiveAppTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	bodyless := req.Body == nil || req.Body == http.NoBody || req.ContentLength == 0
	resp, err := t.base.RoundTrip(req)
	if err != nil && bodyless {
		time.Sleep(20 * time.Millisecond)
		retryReq := req.Clone(req.Context())
		resp, err = t.base.RoundTrip(retryReq)
	}
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusNotFound {
		t.inst.pathProbed.Store(true)
		return resp, nil
	}
	// Only probe the alternate prefix before the instance's path mode has been
	// confirmed. Once pathProbed is true, normal business 404 responses must
	// never trigger duplicate requests or flip preferStrippedPath mid-flight.
	if !t.inst.pathProbed.Load() && bodyless && t.fullPath != t.strippedPath {
		altPath := t.strippedPath
		preferStripped := true
		if req.URL.Path == t.strippedPath {
			altPath = t.fullPath
			preferStripped = false
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()

		retryReq := req.Clone(req.Context())
		retryReq.URL.Path = altPath
		retryReq.URL.RawPath = ""
		retryResp, retryErr := t.base.RoundTrip(retryReq)
		if retryErr == nil && retryResp.StatusCode != http.StatusNotFound {
			t.inst.preferStrippedPath.Store(preferStripped)
			t.inst.pathProbed.Store(true)
			return retryResp, nil
		}
		return retryResp, retryErr
	}
	return resp, nil
}

func sanitizeProxyRequestHeaders(r *http.Request) {
	// Strip host authentication headers and any client-supplied X-LightIsle-* headers
	// so the plugin backend can never receive a host Bearer token or spoofed identity.
	r.Header.Del("Authorization")
	r.Header.Del("Proxy-Authorization")
	for k := range r.Header {
		if strings.HasPrefix(strings.ToLower(k), "x-lightisle-") {
			r.Header.Del(k)
		}
	}
	cookies := r.Cookies()
	r.Header.Del("Cookie")
	for _, c := range cookies {
		if c.Name == "lightisle_session" || strings.HasPrefix(c.Name, "lightisle_app_") || strings.HasPrefix(c.Name, "lightisle_") {
			continue
		}
		r.AddCookie(c)
	}
}

func parseAppRoute(path string) (string, string, bool) {
	if !strings.HasPrefix(path, "/apps/") {
		return "", "", false
	}
	trimmed := strings.TrimPrefix(path, "/apps/")
	if trimmed == "" {
		return "", "", false
	}
	slash := strings.IndexByte(trimmed, '/')
	if slash < 0 {
		return trimmed, "", true
	}
	return trimmed[:slash], trimmed[slash:], true
}

func setAppGatewayHeaders(h interface{ Set(string, string) }) {
	setAppGatewayHeadersForApp(h, nil, "")
}

func setAppGatewayHeadersForApp(h interface{ Set(string, string) }, r *http.Request, appID string) {
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "same-origin")
	h.Set("X-Frame-Options", "SAMEORIGIN")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
	csp := "frame-ancestors 'self'; base-uri 'self'"
	if r != nil && r.Host != "" && ValidPluginID(appID) {
		scheme, wsScheme := "http", "ws"
		if isSecureReq(r) {
			scheme, wsScheme = "https", "wss"
		}
		appBare := scheme + "://" + r.Host + "/apps/" + appID
		appPrefix := appBare + "/"
		wsPrefix := wsScheme + "://" + r.Host + "/apps/" + appID + "/"
		csp += "; form-action " + appBare + " " + appPrefix + "; connect-src " + appBare + " " + appPrefix + " " + wsPrefix
	}
	h.Set("Content-Security-Policy", csp)
}

func isSecureReq(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			if strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
				return true
			}
		}
	}
	return false
}

func writeAppError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error":   code,
		"message": msg,
	})
}
