//go:build darwin && arm64

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"

	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

type nativeRootMediaEvent struct {
	RootID     string   `json:"rootID"`
	Generation uint64   `json:"generation"`
	Dirs       []string `json:"dirs"`
}

func parseNativeRootMediaEvent(encoded string) (nativeRootMediaEvent, bool) {
	var event nativeRootMediaEvent
	if len(encoded) == 0 || len(encoded) > 11000 {
		return event, false
	}
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return event, false
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&event) != nil || decoder.Decode(new(any)) != io.EOF ||
		len(event.RootID) != 32 || event.Generation == 0 {
		return nativeRootMediaEvent{}, false
	}
	for _, c := range event.RootID {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return nativeRootMediaEvent{}, false
		}
	}
	if event.Dirs == nil {
		event.Dirs = []string{"."}
	}
	var normalizeErr error
	if event.Dirs, normalizeErr = mediascope.ScanDirectories(event.Dirs); normalizeErr != nil {
		return nativeRootMediaEvent{}, false
	}
	return event, true
}
