package frpclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const releasesAPI = "https://api.github.com/repos/fatedier/frp/releases"
const maxReleasePages = 4

var validVersion = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
var validDigest = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Release only lists official GitHub release assets for macOS Apple Silicon.
// The download URL and digest stay in Go's private cache, not in the IPC UI.
type Release struct {
	Version     string `json:"version"`
	PublishedAt string `json:"publishedAt,omitempty"`
	Prerelease  bool   `json:"prerelease"`
	Installable bool   `json:"installable"`
	Reason      string `json:"reason,omitempty"`

	url    string
	digest string
}

type githubRelease struct {
	TagName     string `json:"tag_name"`
	Draft       bool   `json:"draft"`
	Prerelease  bool   `json:"prerelease"`
	PublishedAt string `json:"published_at"`
	Assets      []struct {
		Name               string `json:"name"`
		Digest             string `json:"digest"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

func officialURL(tag, name string) string {
	return "https://github.com/fatedier/frp/releases/download/" + tag + "/" + name
}

func parseReleases(raw []githubRelease) []Release {
	items := make([]Release, 0, len(raw))
	seen := make(map[string]bool, len(raw))
	for _, r := range raw {
		if r.Draft || !validVersion.MatchString(r.TagName) || seen[r.TagName] {
			continue
		}
		seen[r.TagName] = true
		version := strings.TrimPrefix(r.TagName, "v")
		expected := "frp_" + version + "_darwin_arm64.tar.gz"
		entry := Release{Version: version, PublishedAt: r.PublishedAt, Prerelease: r.Prerelease, Reason: "frpc_platform_unavailable"}
		for _, a := range r.Assets {
			if a.Name != expected {
				continue
			}
			entry.Reason = "frpc_checksum_unavailable"
			digest := strings.TrimPrefix(a.Digest, "sha256:")
			if !validDigest.MatchString(digest) || a.BrowserDownloadURL != officialURL(r.TagName, expected) {
				continue
			}
			entry.Reason = ""
			entry.Installable = true
			entry.digest = digest
			entry.url = a.BrowserDownloadURL
			break
		}
		items = append(items, entry)
	}
	return items
}

func trustedRedirect(req *http.Request, via []*http.Request) error {
	host := req.URL.Hostname()
	switch host {
	case "github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com":
	default:
		return errors.New("frpc_untrusted_download_redirect")
	}
	if req.URL.Scheme != "https" || len(via) > 8 {
		return errors.New("frpc_untrusted_download_redirect")
	}
	return nil
}

func githubClient() *http.Client {
	return &http.Client{Timeout: 35 * time.Second, CheckRedirect: trustedRedirect}
}

// fetchReleases is bounded by page count, response size, and a timeout.
// No arbitrary download URL can be provided by the Mac UI.
func fetchReleases(ctx context.Context, client *http.Client, endpoint string) ([]Release, error) {
	var result []Release
	seen := make(map[string]bool)
	for page := 1; page <= maxReleasePages; page++ {
		requestURL := fmt.Sprintf("%s?per_page=100&page=%d", endpoint, page)
		if _, err := url.ParseRequestURI(requestURL); err != nil {
			return nil, err
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Accept", "application/vnd.github+json")
		request.Header.Set("User-Agent", "LightIsle-frpc-version-manager")
		response, err := client.Do(request)
		if err != nil {
			return nil, fmt.Errorf("frpc_version_fetch_failed: %w", err)
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
				return nil, errors.New("frpc_github_rate_limited")
			}
			return nil, fmt.Errorf("frpc_versions_http_%d", response.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 4<<20+1))
		response.Body.Close()
		if err != nil {
			return nil, err
		}
		if len(body) > 4<<20 {
			return nil, errors.New("frpc_versions_too_large")
		}
		var raw []githubRelease
		if err := json.Unmarshal(body, &raw); err != nil {
			return nil, errors.New("frpc_versions_invalid_response")
		}
		for _, version := range parseReleases(raw) {
			if !seen[version.Version] {
				seen[version.Version] = true
				result = append(result, version)
			}
		}
		if len(raw) < 100 {
			break
		}
	}
	if len(result) == 0 {
		return nil, errors.New("frpc_versions_empty")
	}
	return result, nil
}
