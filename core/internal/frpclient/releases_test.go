package frpclient

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func testRelease(tag, arch, digest string) githubRelease {
	var result githubRelease
	result.TagName = tag
	name := "frp_" + strings.TrimPrefix(tag, "v") + "_" + arch + ".tar.gz"
	result.Assets = append(result.Assets, struct {
		Name               string `json:"name"`
		Digest             string `json:"digest"`
		BrowserDownloadURL string `json:"browser_download_url"`
	}{Name: name, Digest: digest, BrowserDownloadURL: officialURL(tag, name)})
	return result
}

func TestOfficialReleaseFiltering(t *testing.T) {
	digest := "sha256:" + strings.Repeat("a", 64)
	stable := testRelease("v0.71.1", "darwin_arm64", digest)
	older := testRelease("v0.51.0", "darwin_arm64", "")
	wrongArch := testRelease("v0.40.0", "linux_amd64", digest)
	prerelease := testRelease("v0.72.0", "darwin_arm64", digest)
	prerelease.Prerelease = true
	badURL := testRelease("v0.69.0", "darwin_arm64", digest)
	badURL.Assets[0].BrowserDownloadURL = "https://evil.example/frpc.tar.gz"
	draft := testRelease("v0.73.0", "darwin_arm64", digest)
	draft.Draft = true
	unexpected := testRelease("v0.69.0;sh", "darwin_arm64", digest)
	releases := parseReleases([]githubRelease{stable, older, wrongArch, prerelease, badURL, draft, unexpected, stable})
	if len(releases) != 5 {
		t.Fatalf("unexpected releases: %+v", releases)
	}
	if !releases[0].Installable || releases[0].Version != "0.71.1" {
		t.Fatalf("latest should be installable: %+v", releases[0])
	}
	if releases[1].Installable || releases[1].Reason != "frpc_checksum_unavailable" {
		t.Fatalf("missing digest must be refused: %+v", releases[1])
	}
	if releases[2].Installable || releases[2].Reason != "frpc_platform_unavailable" {
		t.Fatalf("unsupported arch must be refused: %+v", releases[2])
	}
	if !releases[3].Installable || !releases[3].Prerelease {
		t.Fatal("valid prerelease missing")
	}
	if releases[4].Installable {
		t.Fatal("untrusted download URL accepted")
	}
}

func TestFetchVersionsViaBoundedCatalog(t *testing.T) {
	payload, _ := json.Marshal([]githubRelease{testRelease("v0.71.1", "darwin_arm64", "sha256:"+strings.Repeat("b", 64))})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("page") != "1" || r.URL.Query().Get("per_page") != "100" {
			t.Errorf("unexpected page: %s", r.URL.String())
		}
		if r.Header.Get("Accept") != "application/vnd.github+json" {
			t.Error("missing accept")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(payload)
	}))
	defer srv.Close()
	releases, err := fetchReleases(context.Background(), srv.Client(), srv.URL)
	if err != nil || len(releases) != 1 || !releases[0].Installable {
		t.Fatalf("failed parsing catalog: %v %+v", err, releases)
	}
}

func TestCatalogRateLimitIsNotReportedAsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	_, err := fetchReleases(context.Background(), srv.Client(), srv.URL)
	if err == nil || err.Error() != "frpc_github_rate_limited" {
		t.Fatalf("unexpected rate limit error: %v", err)
	}
}

func fakeArchive(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tarWriter := tar.NewWriter(gz)
	content := []byte("#!/bin/sh\nexit 0\n")
	if err := tarWriter.WriteHeader(&tar.Header{Name: "frp_0.71.1_darwin_arm64/frpc", Mode: 0755, Size: int64(len(content))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestDownloadVerifiesChecksumAndPreservesConfig(t *testing.T) {
	payload := fakeArchive(t)
	digest := sha256.Sum256(payload)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.Copy(w, bytes.NewReader(payload)) }))
	defer srv.Close()
	ctx := context.Background()
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("custom = true\n"), 0600); err != nil {
		t.Fatal(err)
	}
	release := Release{Version: "0.71.1", url: srv.URL, digest: hex.EncodeToString(digest[:]), Installable: true}
	bad := release
	bad.digest = strings.Repeat("f", 64)
	if err := m.download(ctx, bad); err == nil || err.Error() != "frpc_checksum_mismatch" {
		t.Fatalf("bad download passed: %v", err)
	}
	if m.installed() {
		t.Fatal("invalid checksum replaced existing executable")
	}
	if err := m.download(ctx, release); err != nil {
		t.Fatal(err)
	}
	s := m.Status()
	if !s.Installed || s.Version != "0.71.1" {
		t.Fatalf("installed metadata incorrect: %+v", s)
	}
	if _, err := os.Stat(m.BinaryPath()); err != nil {
		t.Fatal(err)
	}
	config, _ := os.ReadFile(m.ConfigPath())
	if string(config) != "custom = true\n" {
		t.Fatal("existing user configuration was overwritten")
	}
}

func TestVersionInstallIsBoundToFetchedCatalog(t *testing.T) {
	m := New(context.Background(), t.TempDir(), nil)
	if err := m.BeginInstall("0.99.0"); !errors.Is(err, ErrVersion) {
		t.Fatalf("arbitrary version accepted: %v", err)
	}
	m.releases = map[string]Release{"0.71.1": {Version: "0.71.1", Installable: false}}
	if err := m.BeginInstall("0.71.1"); !errors.Is(err, ErrVersion) {
		t.Fatalf("unverified version accepted: %v", err)
	}
}
