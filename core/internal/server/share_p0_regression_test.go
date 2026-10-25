package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPublicSharePasswordRateLimitDoesNotResetAcrossConnections(t *testing.T) {
	grants := newShareGrantStore()
	for i := 0; i < sharePasswordLimit+1; i++ {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/public/file/token", nil)
		req.RemoteAddr = fmt.Sprintf("192.0.2.25:%d", 40000+i)
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("203.0.113.%d", i+1))
		allowed := grants.allowPasswordAttempt(sharePasswordClientKey(req, "link-id"))
		if allowed != (i < sharePasswordLimit) {
			t.Fatalf("attempt %d: allowed=%v", i+1, allowed)
		}
	}
	another := httptest.NewRequest(http.MethodPost, "/api/v1/public/file/token", nil)
	another.RemoteAddr = "192.0.2.26:50000"
	if !grants.allowPasswordAttempt(sharePasswordClientKey(another, "link-id")) {
		t.Fatal("another client IP inherited the lockout")
	}
	for i := 0; i < 4096; i++ {
		grants.attempts[fmt.Sprintf("test-key-%d", i)] = &sharePasswordAttempts{count: 1, windowEnd: time.Now().Add(time.Hour)}
	}
	if grants.allowPasswordAttempt("brand-new-key") {
		t.Fatal("a full limiter discarded active lockouts instead of failing closed")
	}
	if _, ok := grants.mint([]byte("test-digest")); !ok {
		t.Fatal("grant mint failed")
	}
	if grants.allowPasswordAttempt("brand-new-key") {
		t.Fatal("grant mint reset the limiter's active lockouts")
	}
}

func TestRootPublicShareConcurrentDownloadsDoNotExceedQuota(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "once.txt"), []byte("limited-secret"), 0600); err != nil {
		t.Fatal(err)
	}
	created := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/file-shares"),
		`{"path":"once.txt","hours":1,"maxDownloads":1}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("create limited share: %d %s", created.Code, created.Body.String())
	}
	var link struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &link); err != nil || link.Token == "" {
		t.Fatalf("share response: %v %s", err, created.Body.String())
	}
	url := rootRoute(f.rootA.ID, "/public/file/"+link.Token)
	const clients = 12
	start := make(chan struct{})
	results := make(chan *httptest.ResponseRecorder, clients)
	var wg sync.WaitGroup
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			response := httptest.NewRecorder()
			f.server.ServeHTTP(response, httptest.NewRequest(http.MethodGet, url, nil))
			results <- response
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	served := 0
	for response := range results {
		switch response.Code {
		case http.StatusOK:
			served++
			if response.Body.String() != "limited-secret" {
				t.Fatalf("successful download had wrong body: %q", response.Body.String())
			}
		case http.StatusNotFound:
			if strings.Contains(response.Body.String(), "limited-secret") {
				t.Fatal("quota-exhausted response leaked protected content")
			}
		default:
			t.Fatalf("unexpected concurrent download result: %d %s", response.Code, response.Body.String())
		}
	}
	if served != 1 {
		t.Fatalf("expected exactly one served download, got %d", served)
	}
}

// Exercise the real v2 router. A browser form cannot send a private app
// header or root-generation header, and the resulting grant must stay scoped
// to the selected root. The same link must not work under another root.
func TestRootSharePasswordBrowserFlowAndQuota(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "secret.txt"), []byte("root-secret"), 0600); err != nil {
		t.Fatal(err)
	}
	createdResponse := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/file-shares"),
		`{"path":"secret.txt","hours":1,"password":"open-sesame","maxDownloads":1}`)
	if createdResponse.Code != http.StatusCreated {
		t.Fatalf("create v2 share: %d %s", createdResponse.Code, createdResponse.Body.String())
	}
	var created struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(createdResponse.Body.Bytes(), &created); err != nil || created.Token == "" {
		t.Fatalf("create response %s: %v", createdResponse.Body.String(), err)
	}
	link := rootRoute(f.rootA.ID, "/public/file/"+created.Token)
	other := rootRoute(f.rootB.ID, "/public/file/"+created.Token)
	call := func(method, url, body string, grant *http.Cookie) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, url, strings.NewReader(body))
		if method == http.MethodPost {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			req.Header.Set("Origin", "http://example.com")
		}
		if grant != nil {
			req.AddCookie(grant)
		}
		reply := httptest.NewRecorder()
		f.server.ServeHTTP(reply, req)
		return reply
	}
	if result := call(http.MethodGet, other, "", nil); result.Code != http.StatusNotFound {
		t.Fatalf("cross-root v2 share exposed: %d", result.Code)
	}
	challenge := call(http.MethodGet, link, "", nil)
	if challenge.Code != http.StatusUnauthorized ||
		!strings.Contains(challenge.Body.String(), `action="`+link+`"`) ||
		strings.Contains(challenge.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("v2 browser form unusable: %d %s", challenge.Code, challenge.Body.String())
	}
	badOrigin := httptest.NewRequest(http.MethodPost, link, strings.NewReader("password=open-sesame"))
	badOrigin.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	badOrigin.Header.Set("Origin", "https://evil.example")
	rejected := httptest.NewRecorder()
	f.server.ServeHTTP(rejected, badOrigin)
	if rejected.Code != http.StatusForbidden {
		t.Fatalf("cross-origin form bypass: %d", rejected.Code)
	}
	right := call(http.MethodPost, link, "password=open-sesame", nil)
	if right.Code != http.StatusSeeOther || right.Header().Get("Location") != link {
		t.Fatalf("v2 native POST failed: %d redirect=%q body=%s", right.Code, right.Header().Get("Location"), right.Body.String())
	}
	var grant *http.Cookie
	for _, c := range right.Result().Cookies() {
		if c.Name == shareGrantCookie {
			grant = c
		}
	}
	if grant == nil || grant.Path != rootRoute(f.rootA.ID, "/public/file/") {
		t.Fatalf("v2 cookie missing or incorrectly scoped: %+v", grant)
	}
	if head := call(http.MethodHead, link, "", grant); head.Code != http.StatusOK {
		t.Fatalf("v2 HEAD failed: %d", head.Code)
	}
	invalid := httptest.NewRequest(http.MethodGet, link, nil)
	invalid.AddCookie(grant)
	invalid.Header.Set("Range", "bytes=999999-")
	invalidResponse := httptest.NewRecorder()
	f.server.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("v2 invalid range = %d", invalidResponse.Code)
	}
	if downloaded := call(http.MethodGet, link, "", grant); downloaded.Code != http.StatusOK || downloaded.Body.String() != "root-secret" {
		t.Fatalf("v2 download failed: %d %s", downloaded.Code, downloaded.Body.String())
	}
	if exhausted := call(http.MethodGet, link, "", grant); exhausted.Code != http.StatusNotFound {
		t.Fatalf("v2 max download count bypass: %d", exhausted.Code)
	}
}
