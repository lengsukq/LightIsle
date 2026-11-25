package cinema

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

const (
	onlineSubtitleSearchEndpoint = "https://api-shoulei-ssl.xunlei.com/oracle/subtitle"
	onlineSubtitleMaxResults     = 15
	onlineSubtitleHTTPTimeout    = 12 * time.Second
)

type OnlineSubtitleCandidate struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Language string `json:"language"`
	Ext      string `json:"ext"`
	URL      string `json:"url"`
	Score    int    `json:"score,omitempty"`
}

func validatePublicSubtitleURL(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return nil, fmt.Errorf("%w: 仅允许安全的 HTTPS 字幕地址", ErrInvalid)
	}
	host := strings.ToLower(strings.TrimSuffix(u.Hostname(), "."))
	if host == "localhost" || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") {
		return nil, fmt.Errorf("%w: 禁止访问内网字幕地址", ErrInvalid)
	}
	if ip := net.ParseIP(host); ip != nil && isDisallowedSubtitleIP(ip) {
		return nil, fmt.Errorf("%w: 禁止访问内网或回环地址", ErrInvalid)
	}
	return u, nil
}

func isDisallowedSubtitleIP(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified()
}

func newOnlineSubtitleHTTPClient() *http.Client {
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	return &http.Client{
		Timeout: onlineSubtitleHTTPTimeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				host, port, err := net.SplitHostPort(addr)
				if err != nil {
					return nil, err
				}
				ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
				if err != nil || len(ips) == 0 {
					return nil, fmt.Errorf("subtitle host lookup failed: %w", err)
				}
				for _, ip := range ips {
					if isDisallowedSubtitleIP(ip.IP) {
						return nil, fmt.Errorf("%w: blocked private IP", ErrInvalid)
					}
				}
				return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
			},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return fmt.Errorf("%w: too many redirects", ErrInvalid)
			}
			_, err := validatePublicSubtitleURL(req.URL.String())
			return err
		},
	}
}

func normalizeSubtitleExt(raw string) string {
	ext := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "."))
	switch ext {
	case "srt", "vtt", "ass", "ssa":
		return ext
	default:
		return ""
	}
}

func normalizeSubtitleLangTag(raw string) string {
	lower := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case strings.Contains(lower, "cht") || strings.Contains(lower, "繁") || strings.Contains(lower, "tc"):
		return "cht"
	case strings.Contains(lower, "en") || strings.Contains(lower, "英"):
		return "en"
	default:
		return "zh"
	}
}

// SearchOnlineSubtitles queries public subtitle indices by film title/filename
// and returns direct downloadable SRT/ASS/VTT candidates without requiring any
// third-party account or API key.
func SearchOnlineSubtitles(ctx context.Context, query string) ([]OnlineSubtitleCandidate, error) {
	query = strings.TrimSpace(query)
	if len([]rune(query)) < 1 || len([]rune(query)) > 160 {
		return nil, ErrInvalid
	}
	reqURL := onlineSubtitleSearchEndpoint + "?name=" + url.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "LightIsle/1.0")
	req.Header.Set("Accept", "application/json")

	resp, err := newOnlineSubtitleHTTPClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("subtitle search HTTP %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Data []struct {
			GCID      string   `json:"gcid"`
			CID       string   `json:"cid"`
			URL       string   `json:"url"`
			Ext       string   `json:"ext"`
			Name      string   `json:"name"`
			Languages []string `json:"languages"`
			Rate      string   `json:"rate"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}

	out := make([]OnlineSubtitleCandidate, 0, min(len(parsed.Data), onlineSubtitleMaxResults))
	seen := map[string]bool{}
	for idx, item := range parsed.Data {
		if len(out) >= onlineSubtitleMaxResults {
			break
		}
		ext := normalizeSubtitleExt(item.Ext)
		if ext == "" {
			ext = normalizeSubtitleExt(path.Ext(item.Name))
		}
		if ext == "" || item.URL == "" || seen[item.URL] {
			continue
		}
		if _, err := validatePublicSubtitleURL(item.URL); err != nil {
			continue
		}
		seen[item.URL] = true
		lang := "zh"
		if len(item.Languages) > 0 {
			lang = strings.Join(item.Languages, "/")
		}
		id := item.CID
		if id == "" {
			id = fmt.Sprintf("sub-%d", idx+1)
		}
		out = append(out, OnlineSubtitleCandidate{
			ID:       id,
			Name:     strings.TrimSpace(item.Name),
			Language: lang,
			Ext:      ext,
			URL:      item.URL,
		})
	}
	return out, nil
}

// SaveOnlineSubtitle downloads a validated remote subtitle and writes it
// in-place next to the video file (<stem>.<lang>.<ext>), never overwriting an
// existing sidecar file.
func (l *Library) SaveOnlineSubtitle(ctx context.Context, filmPath, rawURL, language, ext string) (string, error) {
	if _, err := validatePublicSubtitleURL(rawURL); err != nil {
		return "", err
	}
	cleanExt := normalizeSubtitleExt(ext)
	if cleanExt == "" {
		return "", fmt.Errorf("%w: 仅支持 .srt/.vtt/.ass/.ssa 字幕格式", ErrInvalid)
	}
	shareRoot, online := l.files.State()
	if !online {
		return "", ErrOffline
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "LightIsle/1.0")
	resp, err := newOnlineSubtitleHTTPClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("subtitle download HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxSubtitleBytes+1))
	if err != nil {
		return "", err
	}
	if len(data) == 0 {
		return "", fmt.Errorf("%w: 下载的字幕文件为空", ErrInvalid)
	}
	if len(data) > maxSubtitleBytes {
		return "", ErrSubtitleTooLarge
	}

	dirRel := path.Dir(filmPath)
	base := path.Base(filmPath)
	stem := strings.TrimSuffix(base, path.Ext(base))
	langTag := normalizeSubtitleLangTag(language)

	root, err := os.OpenRoot(shareRoot)
	if err != nil {
		return "", err
	}
	defer root.Close()

	var targetRel string
	for attempt := 0; attempt < 20; attempt++ {
		var fileName string
		if attempt == 0 {
			fileName = fmt.Sprintf("%s.%s.%s", stem, langTag, cleanExt)
		} else {
			fileName = fmt.Sprintf("%s.%s.%d.%s", stem, langTag, attempt, cleanExt)
		}
		candidateRel := fileName
		if dirRel != "." && dirRel != "" {
			candidateRel = path.Join(dirRel, fileName)
		}
		if _, statErr := root.Lstat(filepath.FromSlash(candidateRel)); os.IsNotExist(statErr) {
			targetRel = candidateRel
			break
		}
	}
	if targetRel == "" {
		return "", fmt.Errorf("%w: 同目录同类字幕文件过多", ErrInvalid)
	}
	f, err := root.OpenFile(filepath.FromSlash(targetRel), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
	if err != nil {
		return "", err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = root.Remove(filepath.FromSlash(targetRel))
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	return targetRel, nil
}
