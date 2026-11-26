package webarchive

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tinyPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 200, G: 80, B: 40, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestIsBlockedIPCoversAllSSRFClasses(t *testing.T) {
	blocked := []string{
		"127.0.0.1",
		"127.255.255.254",
		"::1",
		"::ffff:127.0.0.1",
		"10.0.0.1",
		"172.16.0.1",
		"192.168.1.100",
		"fc00::1",
		"fd12:3456::1",
		"169.254.169.254",
		"fe80::1",
		"224.0.0.1",
		"ff02::1",
		"0.0.0.0",
		"::",
		"100.64.0.1",
		"255.255.255.255",
	}
	for _, raw := range blocked {
		ip := net.ParseIP(raw)
		if !IsBlockedIP(ip) {
			t.Errorf("expected IP %s to be blocked", raw)
		}
	}
	allowed := []string{
		"1.1.1.1",
		"8.8.8.8",
		"93.184.216.34",
		"2606:2800:220:1:248:1893:25c8:1946",
	}
	for _, raw := range allowed {
		ip := net.ParseIP(raw)
		if IsBlockedIP(ip) {
			t.Errorf("expected public IP %s to be allowed", raw)
		}
	}
}

func TestArchiveBlocksLoopbackByDefault(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html><title>Secret</title><body><p>internal</p></body></html>"))
	}))
	defer srv.Close()

	_, err := Archive(context.Background(), srv.URL, Options{})
	if !errors.Is(err, ErrBlockedAddress) {
		t.Fatalf("expected ErrBlockedAddress for loopback server, got %v", err)
	}
}

func TestArchiveSanitizesAndInlinesImagesOffline(t *testing.T) {
	pngBytes := tinyPNG(t)
	oversized := bytes.Repeat([]byte{0x89, 'P', 'N', 'G'}, 200*1024) // > 512 KiB

	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/article":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!doctype html>
<html>
<head>
  <title>  家庭菜谱：番茄炒蛋  </title>
  <script>alert('xss-head')</script>
</head>
<body>
  <article>
    <h2 onclick="alert(1)">做法步骤</h2>
    <p>经典家常菜</p>
    <script>fetch("https://evil.example/steal")</script>
    <iframe src="https://evil.example/frame"></iframe>
    <object data="https://evil.example/obj"></object>
    <embed src="https://evil.example/embed">
    <a href="javascript:alert(2)" onmouseover="evil()">恶意链接</a>
    <a href="https://example.org/ref">参考来源</a>
    <img src="/img/ok.png" alt="成品图" onerror="alert(3)">
    <img src="/img/big.png" alt="超大原图">
    <img src="http://169.254.169.254/latest/meta-data/" alt="SSRF图">
  </article>
</body>
</html>`))
		case "/img/ok.png":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(pngBytes)
		case "/img/big.png":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(oversized)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	fixedNow := time.Date(2026, 5, 1, 8, 30, 0, 0, time.UTC)
	dest := filepath.Join(t.TempDir(), "out.html")
	res, err := ArchiveToFile(context.Background(), srv.URL+"/article", dest, Options{
		AllowHosts: []string{"127.0.0.1", "::1"},
		Now:        func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("ArchiveToFile failed: %v", err)
	}
	if res.Title != "家庭菜谱：番茄炒蛋" {
		t.Fatalf("unexpected title: %q", res.Title)
	}
	if res.InlinedImages != 1 || res.SkippedImages != 2 {
		t.Fatalf("unexpected image counts: inlined=%d skipped=%d", res.InlinedImages, res.SkippedImages)
	}
	if !strings.HasSuffix(res.SuggestedName, ".html") {
		t.Fatalf("unexpected suggested name: %q", res.SuggestedName)
	}

	raw, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("archived file unreadable: %v", err)
	}
	doc := string(raw)

	mustContain := []string{
		"家庭菜谱：番茄炒蛋",
		srv.URL + "/article",
		"2026-05-01T08:30:00Z",
		"data:image/png;base64,",
		`href="https://example.org/ref"`,
		"Content-Security-Policy",
		"[图片: 超大原图]",
	}
	for _, needle := range mustContain {
		if !strings.Contains(doc, needle) {
			t.Errorf("expected archive HTML to contain %q", needle)
		}
	}

	mustNotContain := []string{
		"<script",
		"<iframe",
		"<object",
		"<embed",
		"onclick=",
		"onerror=",
		"onmouseover=",
		"javascript:",
		"/img/ok.png",
		"/img/big.png",
		"169.254.169.254",
	}
	for _, forbidden := range mustNotContain {
		if strings.Contains(strings.ToLower(doc), strings.ToLower(forbidden)) {
			t.Errorf("archive HTML leaked forbidden token %q", forbidden)
		}
	}
}

func TestArchiveEnforcesRedirectLimitAndBlocksPrivateRedirect(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/loop":
			http.Redirect(w, r, "/loop", http.StatusFound)
		case "/to-private":
			http.Redirect(w, r, "http://169.254.169.254/latest/meta-data/", http.StatusFound)
		}
	}))
	defer srv.Close()

	opts := Options{AllowHosts: []string{"127.0.0.1", "::1"}, MaxRedirects: 5}
	if _, err := Archive(context.Background(), srv.URL+"/loop", opts); !errors.Is(err, ErrTooManyRedirects) {
		t.Fatalf("expected ErrTooManyRedirects, got %v", err)
	}
	if _, err := Archive(context.Background(), srv.URL+"/to-private", opts); !errors.Is(err, ErrBlockedAddress) {
		t.Fatalf("expected ErrBlockedAddress on redirect to link-local, got %v", err)
	}
}

func TestArchiveEnforcesTotalSizeLimit(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html><body><p>" + strings.Repeat("a", 8192) + "</p></body></html>"))
	}))
	defer srv.Close()

	_, err := Archive(context.Background(), srv.URL, Options{
		AllowHosts:    []string{"127.0.0.1", "::1"},
		MaxTotalBytes: 2048,
	})
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("expected ErrTooLarge, got %v", err)
	}
}

func TestValidateURLRejectsUnsafeSchemes(t *testing.T) {
	for _, bad := range []string{
		"",
		"file:///etc/passwd",
		"ftp://example.com/a",
		"javascript:alert(1)",
		"http://user:pass@example.com/",
		"-https://example.com",
		"https://example.com/\r\nInjected: 1",
	} {
		if err := ValidateURL(bad); !errors.Is(err, ErrInvalidURL) {
			t.Errorf("expected ErrInvalidURL for %q, got %v", bad, err)
		}
	}
}
