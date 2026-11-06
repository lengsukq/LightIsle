//go:build darwin && arm64

package main

import (
	"encoding/base64"
	"testing"
)

func TestParseNativeRootMediaEvent(t *testing.T) {
	encode := func(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }
	valid := `{"rootID":"0123456789abcdef0123456789abcdef","generation":3}`
	if event, ok := parseNativeRootMediaEvent(encode(valid)); !ok || event.Generation != 3 {
		t.Fatalf("valid event rejected: %+v %v", event, ok)
	}
	for _, payload := range []string{
		`{"rootID":"0123456789abcdef0123456789abcdef","generation":0}`,
		`{"rootID":"../../etc","generation":1}`,
		`{"rootID":"0123456789abcdef0123456789abcdef","generation":1,"path":"/"}`,
		`{"rootID":"0123456789abcdef0123456789abcdef","generation":1,"dirs":["../outside"]}`,
		valid + `{}`,
	} {
		if _, ok := parseNativeRootMediaEvent(encode(payload)); ok {
			t.Fatalf("accepted invalid event %s", payload)
		}
	}
	withDirs := `{"rootID":"0123456789abcdef0123456789abcdef","generation":1,"dirs":["photos/a","photos/a/sub"]}`
	if event, ok := parseNativeRootMediaEvent(encode(withDirs)); !ok || len(event.Dirs) != 1 || event.Dirs[0] != "photos/a" {
		t.Fatalf("scoped event not normalized: %+v %v", event, ok)
	}
}
