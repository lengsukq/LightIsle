package main

import (
	"encoding/base64"
	"encoding/json"
)

// Decode only the bounded, URL-safe payload used by the trusted local
// Mac IPC. This performs input parsing, not device-owner authentication.
type nativeAdminCredentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func nativeAdminPayload(encoded string) ([]byte, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(raw) > 2048 {
		return nil, false
	}
	return raw, true
}

func parseNativeAdminCredentials(encoded string) (nativeAdminCredentials, bool) {
	raw, ok := nativeAdminPayload(encoded)
	if !ok {
		return nativeAdminCredentials{}, false
	}
	var credentials nativeAdminCredentials
	if json.Unmarshal(raw, &credentials) != nil {
		return nativeAdminCredentials{}, false
	}
	return credentials, true
}

func parseNativeAdminPassword(encoded string) (string, bool) {
	raw, ok := nativeAdminPayload(encoded)
	if !ok {
		return "", false
	}
	var request struct {
		Password string `json:"password"`
	}
	if json.Unmarshal(raw, &request) != nil {
		return "", false
	}
	return request.Password, true
}
