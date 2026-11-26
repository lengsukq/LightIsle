// Package webarchive fetches a web page through an SSRF-hardened HTTP client,
// sanitizes its HTML, inlines body images as Base64 Data URIs, and emits a
// self-contained offline .html file that opens cleanly with zero external
// network dependencies.
package webarchive

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	stdhtml "html"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"golang.org/x/net/html"
)

const (
	DefaultMaxRedirects  = 5
	DefaultMaxTotalBytes = 15 << 20  // 15 MiB
	DefaultMaxImageBytes = 512 << 10 // 512 KiB
	DefaultMaxImages     = 48
	DefaultTimeout       = 45 * time.Second

	maxURLLength     = 2048
	maxHTMLBodyBytes = 4 << 20 // 4 MiB raw HTML cap
	defaultUserAgent = "Mozilla/5.0 (compatible; LightIsle-WebArchiver/1.0)"
)

var (
	ErrInvalidURL             = errors.New("webarchive_invalid_url")
	ErrBlockedAddress         = errors.New("webarchive_blocked_address")
	ErrTooManyRedirects       = errors.New("webarchive_too_many_redirects")
	ErrTooLarge               = errors.New("webarchive_too_large")
	ErrUnsupportedContentType = errors.New("webarchive_unsupported_content_type")
	ErrHTTPStatus             = errors.New("webarchive_http_error")
)

// Options tunes limits and provides test hooks for the web archiver.
type Options struct {
	MaxRedirects  int
	MaxTotalBytes int64
	MaxImageBytes int64
	MaxImages     int
	Timeout       time.Duration
	UserAgent     string
	// AllowHosts permits specific hostnames or IP literals (e.g. "127.0.0.1")
	// to bypass SSRF private-IP blocking. Intended ONLY for unit tests against
	// httptest.Server; leave empty in production.
	AllowHosts []string
	// DialContext optionally replaces the low-level dialer invoked after SSRF
	// address verification.
	DialContext func(ctx context.Context, network, addr string) (net.Conn, error)
	// HTTPClient optionally overrides the entire HTTP client (tests only).
	HTTPClient *http.Client
	// Now optionally overrides the archive timestamp clock (tests only).
	Now func() time.Time
}

// Result describes a produced single-file offline HTML archive.
type Result struct {
	Title         string
	FinalURL      string
	ArchivedAt    time.Time
	HTML          []byte
	TotalBytes    int64
	InlinedImages int
	SkippedImages int
	SuggestedName string
}

var (
	carrierNAT   = mustCIDR("100.64.0.0/10")
	thisNetwork  = mustCIDR("0.0.0.0/8")
	ietfProtocol = mustCIDR("192.0.0.0/24")
	testNet1     = mustCIDR("192.0.2.0/24")
	benchmarkNet = mustCIDR("198.18.0.0/15")
	testNet2     = mustCIDR("198.51.100.0/24")
	testNet3     = mustCIDR("203.0.113.0/24")
	reservedNet  = mustCIDR("240.0.0.0/4")
)

func mustCIDR(cidr string) *net.IPNet {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		panic(err)
	}
	return network
}

// ValidateURL verifies that rawURL is a clean http:// or https:// URL without
// embedded credentials or control characters.
func ValidateURL(rawURL string) error {
	if rawURL == "" || len(rawURL) > maxURLLength || strings.HasPrefix(rawURL, "-") {
		return ErrInvalidURL
	}
	for _, r := range rawURL {
		if r <= 0x1f || r == 0x7f {
			return ErrInvalidURL
		}
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ErrInvalidURL
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
	default:
		return ErrInvalidURL
	}
	if parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil {
		return ErrInvalidURL
	}
	if port := parsed.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return ErrInvalidURL
		}
	}
	return nil
}

// IsBlockedIP returns true for loopback, RFC 1918 / RFC 4193 private ranges,
// link-local, multicast, unspecified, CGNAT, and non-global-unicast addresses.
func IsBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	if ip.IsLoopback() || ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsInterfaceLocalMulticast() || ip.IsMulticast() ||
		ip.IsUnspecified() || !ip.IsGlobalUnicast() {
		return true
	}
	if ip.To4() != nil {
		for _, blocked := range []*net.IPNet{
			carrierNAT, thisNetwork, ietfProtocol,
			testNet1, benchmarkNet, testNet2, testNet3, reservedNet,
		} {
			if blocked.Contains(ip) {
				return true
			}
		}
	}
	return false
}

func (o Options) normalized() Options {
	out := o
	if out.MaxRedirects <= 0 {
		out.MaxRedirects = DefaultMaxRedirects
	}
	if out.MaxTotalBytes <= 0 {
		out.MaxTotalBytes = DefaultMaxTotalBytes
	}
	if out.MaxImageBytes <= 0 {
		out.MaxImageBytes = DefaultMaxImageBytes
	}
	if out.MaxImages <= 0 {
		out.MaxImages = DefaultMaxImages
	}
	if out.Timeout <= 0 {
		out.Timeout = DefaultTimeout
	}
	if out.UserAgent == "" {
		out.UserAgent = defaultUserAgent
	}
	if out.Now == nil {
		out.Now = time.Now
	}
	return out
}

func (o Options) hostAllowed(host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	for _, allowed := range o.AllowHosts {
		if strings.EqualFold(strings.TrimSpace(allowed), h) {
			return true
		}
	}
	return false
}

func isBlockedHostname(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	return h == "" || h == "localhost" ||
		strings.HasSuffix(h, ".localhost") ||
		strings.HasSuffix(h, ".local") ||
		strings.HasSuffix(h, ".internal")
}

// NewHTTPClient builds an SSRF-hardened HTTP client enforcing IP blocking on
// every connection and redirect.
func NewHTTPClient(opts Options) *http.Client {
	cfg := opts.normalized()
	if cfg.HTTPClient != nil {
		return cfg.HTTPClient
	}
	baseDial := cfg.DialContext
	if baseDial == nil {
		baseDial = (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 15 * time.Second,
		}).DialContext
	}
	transport := &http.Transport{
		Proxy:                  nil,
		MaxResponseHeaderBytes: 64 << 10,
		TLSHandshakeTimeout:    10 * time.Second,
		ResponseHeaderTimeout:  15 * time.Second,
		DisableKeepAlives:      true,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, ErrBlockedAddress
			}
			cleanHost := strings.SplitN(host, "%", 2)[0]
			allowed := cfg.hostAllowed(cleanHost)
			if ip := net.ParseIP(cleanHost); ip != nil {
				if !allowed && IsBlockedIP(ip) {
					return nil, fmt.Errorf("%w: %s", ErrBlockedAddress, cleanHost)
				}
				return baseDial(ctx, network, net.JoinHostPort(ip.String(), port))
			}
			if !allowed && isBlockedHostname(cleanHost) {
				return nil, fmt.Errorf("%w: %s", ErrBlockedAddress, cleanHost)
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, cleanHost)
			if err != nil || len(ips) == 0 {
				return nil, fmt.Errorf("webarchive lookup failed: %w", err)
			}
			var chosen net.IP
			for _, candidate := range ips {
				if !allowed && !cfg.hostAllowed(candidate.IP.String()) && IsBlockedIP(candidate.IP) {
					return nil, fmt.Errorf("%w: resolved private address", ErrBlockedAddress)
				}
				if chosen == nil {
					chosen = candidate.IP
				}
			}
			return baseDial(ctx, network, net.JoinHostPort(chosen.String(), port))
		},
	}
	return &http.Client{
		Transport: transport,
		Timeout:   cfg.Timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > cfg.MaxRedirects {
				return ErrTooManyRedirects
			}
			return ValidateURL(req.URL.String())
		},
	}
}

// Archive fetches rawURL, sanitizes the document, inlines images as Base64
// Data URIs, and returns a standalone offline HTML document.
func Archive(ctx context.Context, rawURL string, opts Options) (Result, error) {
	if err := ValidateURL(rawURL); err != nil {
		return Result{}, err
	}
	cfg := opts.normalized()
	client := NewHTTPClient(cfg)

	reqCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, rawURL, nil)
	if err != nil {
		return Result{}, ErrInvalidURL
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,text/plain;q=0.8,*/*;q=0.1")

	resp, err := client.Do(req)
	if err != nil {
		return Result{}, normalizeFetchError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Result{}, fmt.Errorf("%w: http %d", ErrHTTPStatus, resp.StatusCode)
	}
	mediaType := parseMediaType(resp.Header.Get("Content-Type"))
	if mediaType != "" && mediaType != "text/html" && mediaType != "application/xhtml+xml" && mediaType != "text/plain" {
		return Result{}, fmt.Errorf("%w: %s", ErrUnsupportedContentType, mediaType)
	}

	htmlLimit := min(int64(maxHTMLBodyBytes), cfg.MaxTotalBytes)
	rawBody, err := readBounded(resp.Body, htmlLimit)
	if err != nil {
		return Result{}, err
	}

	finalURL := resp.Request.URL
	if finalURL == nil {
		finalURL, _ = url.Parse(rawURL)
	}
	archivedAt := cfg.Now().UTC()

	var title, bodyHTML string
	var inlined, skipped int

	if mediaType == "text/plain" {
		title = fallbackTitle(finalURL)
		bodyHTML = "<pre>" + stdhtml.EscapeString(string(rawBody)) + "</pre>"
	} else {
		doc, parseErr := html.Parse(bytes.NewReader(rawBody))
		if parseErr != nil {
			return Result{}, parseErr
		}
		title = strings.TrimSpace(extractTitle(doc))
		if title == "" {
			title = fallbackTitle(finalURL)
		}
		contentRoot := pickContentRoot(doc)
		state := &sanitizeState{
			ctx:           reqCtx,
			client:        client,
			baseURL:       finalURL,
			cfg:           cfg,
			remainingSize: max(0, cfg.MaxTotalBytes-int64(len(rawBody))),
		}
		var fragment bytes.Buffer
		state.renderChildren(&fragment, contentRoot)
		bodyHTML = fragment.String()
		inlined = state.inlinedImages
		skipped = state.skippedImages
	}

	fullDoc := buildArchiveDocument(title, finalURL.String(), archivedAt, bodyHTML)
	if int64(len(fullDoc)) > cfg.MaxTotalBytes {
		return Result{}, ErrTooLarge
	}
	return Result{
		Title:         title,
		FinalURL:      finalURL.String(),
		ArchivedAt:    archivedAt,
		HTML:          fullDoc,
		TotalBytes:    int64(len(fullDoc)),
		InlinedImages: inlined,
		SkippedImages: skipped,
		SuggestedName: SafeFilename(title, finalURL.String()),
	}, nil
}

// ArchiveToFile archives rawURL and writes the standalone offline HTML to
// destPath atomically via a sibling temporary file.
func ArchiveToFile(ctx context.Context, rawURL, destPath string, opts Options) (Result, error) {
	result, err := Archive(ctx, rawURL, opts)
	if err != nil {
		return Result{}, err
	}
	dir := filepath.Dir(destPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Result{}, err
	}
	tmp, err := os.CreateTemp(dir, ".webarchive-*.tmp")
	if err != nil {
		return Result{}, err
	}
	tmpPath := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(result.HTML); err != nil {
		_ = tmp.Close()
		return Result{}, err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return Result{}, err
	}
	if err := tmp.Close(); err != nil {
		return Result{}, err
	}
	if err := os.Rename(tmpPath, destPath); err != nil {
		return Result{}, err
	}
	cleanup = false
	return result, nil
}

// SafeFilename derives a safe, bounded `.html` filename from a page title or URL.
func SafeFilename(title, rawURL string) string {
	candidate := strings.TrimSpace(title)
	if candidate == "" {
		if u, err := url.Parse(rawURL); err == nil {
			candidate = fallbackTitle(u)
		}
	}
	var b strings.Builder
	lastSpace := false
	runes := 0
	for _, r := range candidate {
		if runes >= 72 {
			break
		}
		if unicode.IsControl(r) || strings.ContainsRune(`/\:*?"<>|`, r) || unicode.IsSpace(r) {
			if !lastSpace && b.Len() > 0 {
				b.WriteByte(' ')
				lastSpace = true
				runes++
			}
			continue
		}
		b.WriteRune(r)
		lastSpace = false
		runes++
	}
	name := strings.Trim(b.String(), " .-_")
	if name == "" {
		name = "webpage"
	}
	if !strings.HasSuffix(strings.ToLower(name), ".html") {
		name += ".html"
	}
	return name
}

func normalizeFetchError(err error) error {
	switch {
	case errors.Is(err, ErrBlockedAddress):
		return ErrBlockedAddress
	case errors.Is(err, ErrTooManyRedirects):
		return ErrTooManyRedirects
	case errors.Is(err, ErrInvalidURL):
		return ErrInvalidURL
	default:
		return err
	}
}

func parseMediaType(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	mediaType, _, err := mime.ParseMediaType(raw)
	if err != nil {
		return ""
	}
	return strings.ToLower(mediaType)
}

func readBounded(r io.Reader, limit int64) ([]byte, error) {
	if limit <= 0 {
		return nil, ErrTooLarge
	}
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, ErrTooLarge
	}
	return data, nil
}
