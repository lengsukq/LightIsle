//go:build darwin && arm64

package main

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestIPCSettingsRejectUnknownCommands(t *testing.T) {
	if handleMapSettings("map unrelated") {
		t.Fatal("unrelated command was consumed by map settings")
	}
	if !handleMapSettings("map tianditu unsupported") {
		t.Fatal("malformed map settings must be consumed")
	}
	if handleCinemaTokenSettings("cinema unrelated", nil) {
		t.Fatal("unrelated command was consumed by cinema settings")
	}
}

func TestIPCPrivateDiskAndNotifyHandlersConsumeMalformedRequests(t *testing.T) {
	if handleDiskIPC(context.Background(), "map unrelated") {
		t.Fatal("disk handler consumed unrelated command")
	}
	if !handleDiskIPC(context.Background(), "disk action not_base64") {
		t.Fatal("disk action parser must reject malformed request before mounting hardware")
	}
	if !handleDiskIPC(context.Background(), "disk smart report not_base64") {
		t.Fatal("SMART parser must reject malformed elevated report")
	}
	active := false
	if handleNotificationIPC("notify-unrelated", nil, &active, nil) {
		t.Fatal("notify handler consumed unrelated command")
	}
	if !handleNotificationIPC("notify set not_base64", nil, &active, nil) {
		t.Fatal("notify parser did not reject malformed secret payload")
	}
	if active {
		t.Fatal("malformed notification command started a test")
	}
}

func TestIPCRetentionRejectsMalformedCommandWithoutMutation(t *testing.T) {
	store := tasks.OpenRetentionStore(filepath.Join(t.TempDir(), "retention.json"))
	before := store.Get()
	if handleTrashRetentionSettings("trash unrelated", store) {
		t.Fatal("unrelated command was consumed by retention settings")
	}
	if !handleTrashRetentionSettings("trash retention bad==", store) {
		t.Fatal("invalid settings should be consumed and rejected")
	}
	after := store.Get()
	if after.Enabled != before.Enabled || after.Days != before.Days {
		t.Fatalf("invalid command changed retention: before=%+v after=%+v", before, after)
	}
}
