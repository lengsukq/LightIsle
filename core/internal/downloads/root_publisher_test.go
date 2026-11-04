package downloads

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type publisherIdentityProvider struct{}

func (publisherIdentityProvider) Capture(_ context.Context, location string) (storageidentity.Binding, error) {
	resolved, err := filepath.EvalSymlinks(location)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("missing directory identity")
	}
	return storageidentity.Binding{
		Path: resolved, VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: stat.Ino, BirthSec: stat.Birthtimespec.Sec,
		BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen),
	}, nil
}

func TestScopedDownloadJournalFailsLegacyJobsClosed(t *testing.T) {
	base := t.TempDir()
	volume, data := filepath.Join(base, "volume"), filepath.Join(base, "data")
	for _, name := range []string{volume, data} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	reg, err := roots.OpenWithProvider(data, publisherIdentityProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	firstPath, secondPath := filepath.Join(volume, "first"), filepath.Join(volume, "second")
	for _, name := range []string{firstPath, secondPath} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	first, err := reg.Add(context.Background(), "first", firstPath)
	if err != nil {
		t.Fatal(err)
	}
	second, err := reg.Add(context.Background(), "second", secondPath)
	if err != nil {
		t.Fatal(err)
	}
	publisher := NewRegistryPublisher(reg)
	opts := Options{DataDir: data, Publisher: publisher, CanImport: func(int64, string) bool { return true }}
	m, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(first.Binding)
	if err != nil {
		t.Fatal(err)
	}
	_, err = m.db.Exec("INSERT INTO download_tasks (id,owner,url,destination,status,root_binding,created_at,updated_at) VALUES('legacy',7,'https://example.org/file','dl','paused',?,1,1)", string(encoded))
	if err != nil {
		t.Fatal(err)
	}
	_, err = m.db.Exec("INSERT INTO download_tasks (id,owner,url,destination,status,root_binding,root_id,root_generation,created_at,updated_at) VALUES('scoped',7,'https://example.org/file','dl','paused',?,?,?,1,1)",
		string(encoded), first.ID, first.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	legacy, _, err := reopened.rowByID("legacy", 7)
	if err != nil || legacy.Status != StatusFailed || legacy.Error != ErrRootUnbound.Error() {
		t.Fatalf("legacy task inherited permissions: %+v %v", legacy, err)
	}
	scoped, _, err := reopened.rowByID("scoped", 7)
	if err != nil || scoped.RootID != first.ID || scoped.RootGeneration != first.Generation {
		t.Fatalf("lost root identity after restart: %+v %v", scoped, err)
	}
	if err := reopened.requireTaskRoot(scoped); err != nil {
		t.Fatal(err)
	}
	if err := reg.SetDefault(context.Background(), second.ID, second.Generation); err != nil {
		t.Fatal(err)
	}
	if err := reopened.requireTaskRoot(scoped); !errors.Is(err, ErrRootChanged) {
		t.Fatalf("old task changed disk: %v", err)
	}
	if _, err := publisher.PublishDownloadRoot(RootIdentity{ID: first.ID, Generation: first.Generation, Binding: first.Binding},
		"unsafe.txt", bytes.NewBufferString("wrong disk"), nil); !errors.Is(err, ErrRootChanged) {
		t.Fatalf("old logical root accepted: %v", err)
	}
}

func (p publisherIdentityProvider) Verify(ctx context.Context, expected storageidentity.Binding) error {
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(actual, expected) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestRegistryPublisherFollowsDefaultAndRejectsStaleBinding(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	data := filepath.Join(base, "data")
	for _, name := range []string{volume, data} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(data, publisherIdentityProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	firstPath := filepath.Join(volume, "first")
	secondPath := filepath.Join(volume, "second")
	for _, name := range []string{firstPath, secondPath} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	first, err := registry.Add(context.Background(), "first", firstPath)
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Add(context.Background(), "second", secondPath)
	if err != nil {
		t.Fatal(err)
	}
	publisher := NewRegistryPublisher(registry)
	initial, err := publisher.DownloadRootBinding()
	if err != nil || initial != first.Binding {
		t.Fatalf("initial root binding: %v %+v", err, initial)
	}
	if _, err := publisher.PublishDownload(initial, "a.txt", bytes.NewBufferString("initial"), nil); err != nil {
		t.Fatal(err)
	}
	if err := registry.SetDefault(context.Background(), second.ID, second.Generation); err != nil {
		t.Fatal(err)
	}
	if _, err := publisher.PublishDownload(initial, "leak.txt", bytes.NewBufferString("stale"), nil); !errors.Is(err, ErrRootChanged) {
		t.Fatalf("stale root publish: %v", err)
	}
	if _, err := os.Stat(filepath.Join(secondPath, "leak.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("wrote to wrong root: %v", err)
	}
	current, err := publisher.DownloadRootBinding()
	if err != nil || current != second.Binding {
		t.Fatalf("new root binding: %v %+v", err, current)
	}
	if _, err := publisher.PublishDownload(current, "b.txt", bytes.NewBufferString("second"), nil); err != nil {
		t.Fatal(err)
	}
	if err := publisher.InspectDownload(current, "b.txt", func(r io.Reader, size int64) error {
		data, err := io.ReadAll(r)
		if err != nil || size != int64(len(data)) || string(data) != "second" {
			t.Fatalf("inspection mismatch: %q %d %v", data, size, err)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
