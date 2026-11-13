package cinema

import (
	"fmt"
	"testing"
)

func TestParseAndValidateStrmContent(t *testing.T) {
	lanURL := fmt.Sprintf("%s://%s/d/Movies/Dune.Part.Two.2024.2160p.mkv?sign=abc", "http", "192.168.31.10:5244")
	hlsURL := fmt.Sprintf("%s://%s/hls/master.m3u8", "https", "stream-cdn.invalid")
	validCases := []struct {
		name string
		raw  string
		want string
		host string
	}{
		{
			name: "lan openlist stream",
			raw:  "# OpenList 4K mount\n" + lanURL + "\n",
			want: lanURL,
			host: "192.168.31.10",
		},
		{
			name: "utf8 bom m3u8",
			raw:  "\xef\xbb\xbf" + hlsURL + "\r\n",
			want: hlsURL,
			host: "stream-cdn.invalid",
		},
	}
	for _, tc := range validCases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseAndValidateStrmContent(tc.raw)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
			if h := StrmHostSummary(got); h != tc.host {
				t.Fatalf("host = %q, want %q", h, tc.host)
			}
		})
	}

	rejectedCases := []struct {
		name string
		raw  string
	}{
		{name: "empty", raw: "   \n# comment only\n"},
		{name: "unsupported scheme", raw: fmt.Sprintf("%s://%s/movie.mkv", "ftp", "nas.invalid")},
		{name: "relative path", raw: "../Movies/sample.mp4"},
		{name: "loopback v4", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "127.0.0.1")},
		{name: "localhost", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "localhost")},
		{name: "localhost trailing dot", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "localhost.")},
		{name: "loopback decimal integer", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "2130706433")},
		{name: "loopback octal", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "0177.0.0.1")},
		{name: "loopback hex", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "0x7f000001")},
		{name: "ipv6 loopback zone", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "[::1%25lo0]")},
		{name: "ipv6 link local zone", raw: fmt.Sprintf("%s://%s:8080/video.mp4", "http", "[fe80::1%25en0]")},
		{name: "link local", raw: fmt.Sprintf("%s://%s/stream.mp4", "http", "169.254.10.20")},
		{name: "multiple urls", raw: lanURL + "\n" + hlsURL},
	}
	for _, tc := range rejectedCases {
		t.Run(tc.name, func(t *testing.T) {
			if got, err := ParseAndValidateStrmContent(tc.raw); err == nil {
				t.Fatalf("expected error for %q, got %q", tc.raw, got)
			}
		})
	}
}
