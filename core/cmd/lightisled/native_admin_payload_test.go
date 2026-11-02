package main

import (
	"encoding/base64"
	"testing"
)

func TestNativeAdminPayload(t *testing.T) {
	encode := func(value string) string { return base64.RawURLEncoding.EncodeToString([]byte(value)) }
	c, ok := parseNativeAdminCredentials(encode(`{"username":"admin","password":"some secure passphrase"}`))
	if !ok || c.Username != "admin" || c.Password != "some secure passphrase" {
		t.Fatalf("valid credentials: %+v %v", c, ok)
	}
	p, ok := parseNativeAdminPassword(encode(`{"password":"replacement"}`))
	if !ok || p != "replacement" {
		t.Fatalf("valid reset payload: %s %v", p, ok)
	}
	for _, input := range []string{"!bad", encode(`{"password":`), encode(`"unexpected"`), encode(string(make([]byte, 2049)))} {
		if _, ok := parseNativeAdminCredentials(input); ok {
			t.Fatalf("accepted invalid credentials %q", input[:min(len(input), 24)])
		}
		if _, ok := parseNativeAdminPassword(input); ok {
			t.Fatalf("accepted invalid password payload %q", input[:min(len(input), 24)])
		}
	}
}
