//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *syncBuffer) Reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf.Reset()
}

type decodedMediaImportEnvelope struct {
	SchemaVersion int             `json:"schemaVersion"`
	Operation     string          `json:"operation"`
	RequestID     string          `json:"requestID"`
	Result        json.RawMessage `json:"result,omitempty"`
	Error         string          `json:"error,omitempty"`
}

func encodeMediaImportCommand(op string, req mediaImportRequest) string {
	raw, _ := json.Marshal(req)
	return "media-import " + op + " " + base64.RawURLEncoding.EncodeToString(raw)
}

func parseMediaImportEvents(t *testing.T, output string) []decodedMediaImportEnvelope {
	t.Helper()
	var events []decodedMediaImportEnvelope
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "LIGHTISLE_MEDIA_IMPORT ") {
			t.Fatalf("unexpected stdout line: %q", line)
		}
		encoded := strings.TrimPrefix(line, "LIGHTISLE_MEDIA_IMPORT ")
		raw, err := base64.RawURLEncoding.DecodeString(encoded)
		if err != nil {
			t.Fatalf("base64 decode failed: %v", err)
		}
		var env decodedMediaImportEnvelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("json decode failed: %v", err)
		}
		events = append(events, env)
	}
	return events
}

func setupMediaImportFixture(t *testing.T) (
	base string,
	volumesDir string,
	cardDir string,
	nasRootDir string,
	registry *roots.Registry,
	store *auth.Store,
	root roots.Root,
	member auth.User,
) {
	t.Helper()
	base = t.TempDir()
	privateDir := filepath.Join(base, "private")
	volumesDir = filepath.Join(base, "Volumes")
	cardDir = filepath.Join(volumesDir, "EOS_DIGITAL")
	nasRootDir = filepath.Join(volumesDir, "NAS_DISK", "LightIsle")
	for _, dir := range []string{privateDir, cardDir, nasRootDir} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}

	var err error
	registry, err = roots.OpenWithProvider(privateDir, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	root, err = registry.Add(context.Background(), "家庭主盘", nasRootDir)
	if err != nil {
		t.Fatal(err)
	}

	store, err = auth.Open(filepath.Join(privateDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Setup("admin", "admin-password-2026"); err != nil {
		t.Fatal(err)
	}
	member, err = store.NativeCreateUser("photographer", "member-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	adminSession, err := store.Login("admin", "admin-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	quota := int64(10 * 1024 * 1024)
	if _, err := store.AllocateUserStorageRoot(
		adminSession, member.ID, root.ID, root.Generation, &quota,
		[]string{auth.StoragePhotos, auth.StorageVideos},
	); err != nil {
		t.Fatal(err)
	}
	return base, volumesDir, cardDir, nasRootDir, registry, store, root, member
}

func writeTestMediaFile(t *testing.T, fullPath string, content []byte, modTime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fullPath, content, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(fullPath, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func TestMediaImportSourceValidationGuards(t *testing.T) {
	base, volumesDir, _, nasRootDir, registry, store, _, _ := setupMediaImportFixture(t)
	out := &syncBuffer{}
	ctl := newMediaImportControl(registry, store, nil, nil)
	ctl.output = out

	// Default production prefix "/Volumes" must reject temp dir paths.
	outsideDir := filepath.Join(base, "Desktop")
	if err := os.MkdirAll(outsideDir, 0700); err != nil {
		t.Fatal(err)
	}
	ctl.handle(context.Background(), encodeMediaImportCommand("scan", mediaImportRequest{
		RequestID:  "req-outside",
		SourcePath: outsideDir,
	}))
	ctl.Wait()
	events := parseMediaImportEvents(t, out.String())
	if len(events) != 1 || events[0].Error != "source_path_outside_volumes" {
		t.Fatalf("expected source_path_outside_volumes, got: %+v", events)
	}

	// With test Volumes prefix, registered NAS root and its parent/child must be rejected.
	ctl.allowedSourcePrefix = volumesDir
	nasChild := filepath.Join(nasRootDir, "Users")
	if err := os.MkdirAll(nasChild, 0700); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{nasRootDir, filepath.Dir(nasRootDir), nasChild} {
		out.Reset()
		ctl.handle(context.Background(), encodeMediaImportCommand("scan", mediaImportRequest{
			RequestID:  "req-overlap",
			SourcePath: bad,
		}))
		ctl.Wait()
		events = parseMediaImportEvents(t, out.String())
		if len(events) != 1 || events[0].Error != "source_overlaps_nas_root" {
			t.Fatalf("expected source_overlaps_nas_root for %s, got: %+v", bad, events)
		}
	}

	if !isAcceptedIPCCommand("media-import scan abc") ||
		!isAcceptedIPCCommand("media-import start abc") ||
		!isAcceptedIPCCommand("media-import cancel abc") {
		t.Fatal("expected media-import commands to be accepted by IPC validator")
	}
}

func TestMediaImportScanImportDeduplicateAndQuota(t *testing.T) {
	_, volumesDir, cardDir, nasRootDir, registry, store, root, member := setupMediaImportFixture(t)

	ts := time.Date(2026, 8, 15, 14, 30, 0, 0, time.Local)
	jpegBytes := []byte("fake-jpeg-camera-photo-0001")
	rawBytes := []byte("fake-canon-cr3-raw-image-0002")
	livePhotoBytes := []byte("fake-heic-live-photo-0003")
	liveMovBytes := []byte("fake-live-photo-companion-mov-0003")
	droneMp4Bytes := []byte("fake-dji-4k-video-clip-0004")

	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100CANON", "IMG_0001.JPG"), jpegBytes, ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100CANON", "IMG_0002.CR3"), rawBytes, ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100APPLE", "IMG_0003.HEIC"), livePhotoBytes, ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100APPLE", "IMG_0003.MOV"), liveMovBytes, ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DJI", "DJI_0004.MP4"), droneMp4Bytes, ts)
	// Sidecars, non-media, and symlinks must be skipped.
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100CANON", "._IMG_0001.JPG"), []byte("appledouble"), ts)
	writeTestMediaFile(t, filepath.Join(cardDir, ".DS_Store"), []byte("dsstore"), ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100CANON", "README.TXT"), []byte("notes"), ts)
	if err := os.Symlink(filepath.Join(cardDir, "DCIM", "100CANON", "IMG_0001.JPG"), filepath.Join(cardDir, "DCIM", "100CANON", "LINK.JPG")); err != nil {
		t.Fatal(err)
	}

	out := &syncBuffer{}
	var refreshMu sync.Mutex
	var refreshed []string
	ctl := newMediaImportControl(registry, store, nil, nil)
	ctl.output = out
	ctl.allowedSourcePrefix = volumesDir
	ctl.onQueueRefresh = func(rootID, relativePath string) {
		refreshMu.Lock()
		defer refreshMu.Unlock()
		refreshed = append(refreshed, rootID+":"+relativePath)
	}

	// 1) Scan
	ctl.handle(context.Background(), encodeMediaImportCommand("scan", mediaImportRequest{
		RequestID:  "scan-1",
		SourcePath: cardDir,
	}))
	ctl.Wait()
	events := parseMediaImportEvents(t, out.String())
	if len(events) != 1 || events[0].Operation != "scan" || events[0].Error != "" {
		t.Fatalf("unexpected scan events: %+v", events)
	}
	var scanRes mediaImportScanResult
	if err := json.Unmarshal(events[0].Result, &scanRes); err != nil {
		t.Fatal(err)
	}
	if scanRes.TotalFiles != 5 || scanRes.PhotoCount != 2 || scanRes.RawCount != 1 || scanRes.LivePhotoCount != 1 || scanRes.VideoCount != 1 {
		t.Fatalf("unexpected scan breakdown: %+v", scanRes)
	}
	if len(scanRes.DetectedHints) != 2 || scanRes.DetectedHints[0] != "DCIM" || scanRes.DetectedHints[1] != "DJI" {
		t.Fatalf("unexpected hints: %+v", scanRes.DetectedHints)
	}

	// 2) First import (auto category + ymd archive mode)
	out.Reset()
	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "imp-1",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "auto",
		ArchiveMode: "ymd",
		Subfolder:   "相机导入",
	}))
	ctl.Wait()
	events = parseMediaImportEvents(t, out.String())
	last := events[len(events)-1]
	if last.Operation != "complete" || last.Error != "" {
		t.Fatalf("expected clean complete event, got: %+v", last)
	}
	var status mediaImportStatus
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if status.Phase != "completed" || !status.AllVerified || status.ImportedFiles != 5 || status.SkippedFiles != 0 || status.FailedFiles != 0 {
		t.Fatalf("unexpected import status: %+v", status)
	}

	// Verify destination paths: photos/raw/livePhoto -> photos, video -> videos
	expectedPhotosDir := filepath.Join(nasRootDir, "Users", "u2", "photos", "相机导入", "2026", "08", "15")
	expectedVideosDir := filepath.Join(nasRootDir, "Users", "u2", "videos", "相机导入", "2026", "08", "15")
	for _, rel := range []string{
		filepath.Join(expectedPhotosDir, "IMG_0001.JPG"),
		filepath.Join(expectedPhotosDir, "IMG_0002.CR3"),
		filepath.Join(expectedPhotosDir, "IMG_0003.HEIC"),
		filepath.Join(expectedPhotosDir, "IMG_0003.MOV"),
		filepath.Join(expectedVideosDir, "DJI_0004.MP4"),
	} {
		if _, err := os.Stat(rel); err != nil {
			t.Fatalf("expected imported file at %s: %v", rel, err)
		}
	}

	// Verify quota ledger accounted exact bytes and zero leaked reservations.
	expectedTotalBytes := int64(len(jpegBytes) + len(rawBytes) + len(livePhotoBytes) + len(liveMovBytes) + len(droneMp4Bytes))
	policy, err := store.NativeStoragePolicy(member.ID)
	if err != nil {
		t.Fatal(err)
	}
	if policy.AccountedBytes != expectedTotalBytes || policy.ReservedBytes != 0 {
		t.Fatalf("unexpected quota ledger: accounted=%d expected=%d reserved=%d", policy.AccountedBytes, expectedTotalBytes, policy.ReservedBytes)
	}

	// Verify QueueMediaRefresh triggered for both photos and videos prefixes.
	refreshMu.Lock()
	refreshCount := len(refreshed)
	refreshMu.Unlock()
	if refreshCount != 2 {
		t.Fatalf("expected 2 media refresh notifications (photos+videos), got %d (%+v)", refreshCount, refreshed)
	}

	// Verify SD card original files were NEVER removed or altered.
	if got, err := os.ReadFile(filepath.Join(cardDir, "DCIM", "100CANON", "IMG_0001.JPG")); err != nil || !bytes.Equal(got, jpegBytes) {
		t.Fatalf("source card original altered or removed: err=%v", err)
	}

	// 3) Re-run identical import -> all 5 skipped via size + SHA-256 deduplication!
	out.Reset()
	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "imp-2",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "auto",
		ArchiveMode: "ymd",
		Subfolder:   "相机导入",
	}))
	ctl.Wait()
	events = parseMediaImportEvents(t, out.String())
	last = events[len(events)-1]
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if !status.AllVerified || status.ImportedFiles != 0 || status.SkippedFiles != 5 || status.FailedFiles != 0 {
		t.Fatalf("expected all 5 files skipped on re-import, got: %+v", status)
	}
	policyAfterSkip, err := store.NativeStoragePolicy(member.ID)
	if err != nil {
		t.Fatal(err)
	}
	if policyAfterSkip.AccountedBytes != expectedTotalBytes || policyAfterSkip.ReservedBytes != 0 {
		t.Fatalf("quota changed on deduplicated re-import: %+v", policyAfterSkip)
	}

	// 4) Same filename with DIFFERENT bytes -> must auto-rename to IMG_0001_1.JPG without overwriting!
	differentJpeg := []byte("brand-new-different-jpeg-bytes-same-filename")
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "100CANON", "IMG_0001.JPG"), differentJpeg, ts)
	out.Reset()
	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "imp-3",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "auto",
		ArchiveMode: "ymd",
		Subfolder:   "相机导入",
	}))
	ctl.Wait()
	events = parseMediaImportEvents(t, out.String())
	last = events[len(events)-1]
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if status.ImportedFiles != 1 || status.SkippedFiles != 4 || !status.AllVerified {
		t.Fatalf("expected 1 renamed import + 4 skipped, got: %+v", status)
	}
	if gotOrig, err := os.ReadFile(filepath.Join(expectedPhotosDir, "IMG_0001.JPG")); err != nil || !bytes.Equal(gotOrig, jpegBytes) {
		t.Fatal("existing destination file was overwritten on conflict")
	}
	if gotRenamed, err := os.ReadFile(filepath.Join(expectedPhotosDir, "IMG_0001_1.JPG")); err != nil || !bytes.Equal(gotRenamed, differentJpeg) {
		t.Fatalf("expected renamed sibling IMG_0001_1.JPG, err=%v", err)
	}
}

func TestMediaImportQuotaExceededAndPreserveMode(t *testing.T) {
	_, volumesDir, cardDir, nasRootDir, registry, store, root, member := setupMediaImportFixture(t)
	ts := time.Date(2026, 9, 1, 10, 0, 0, 0, time.Local)

	// Tighten member quota to 64 bytes so a 128-byte photo triggers quota exceeded.
	if err := store.NativeSetUserStorageRootQuota(member.ID, root.ID, root.Generation, 64); err != nil {
		t.Fatal(err)
	}
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "101NIKON", "SMALL.JPG"), bytes.Repeat([]byte("a"), 32), ts)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "101NIKON", "LARGE.JPG"), bytes.Repeat([]byte("b"), 128), ts)

	out := &syncBuffer{}
	ctl := newMediaImportControl(registry, store, nil, nil)
	ctl.output = out
	ctl.allowedSourcePrefix = volumesDir

	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "quota-1",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "photos",
		ArchiveMode: "preserve",
	}))
	ctl.Wait()

	events := parseMediaImportEvents(t, out.String())
	last := events[len(events)-1]
	var status mediaImportStatus
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if status.Phase != "failed" || status.LastError != "storage_quota_exceeded" || status.AllVerified {
		t.Fatalf("expected failed storage_quota_exceeded, got: %+v", status)
	}
	// Preserve mode path for SMALL.JPG should have succeeded (or failed first depending on sort order: LARGE sorts before SMALL!).
	// LARGE.JPG sorts before SMALL.JPG, so 0 imported, 0 reserved!
	policy, err := store.NativeStoragePolicy(member.ID)
	if err != nil {
		t.Fatal(err)
	}
	if policy.ReservedBytes != 0 {
		t.Fatalf("leaked reservation after quota error: %+v", policy)
	}

	// Raise quota and verify preserve mode keeps DCIM/101NIKON structure.
	if err := store.NativeSetUserStorageRootQuota(member.ID, root.ID, root.Generation, 4096); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "preserve-1",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "photos",
		ArchiveMode: "preserve",
	}))
	ctl.Wait()
	events = parseMediaImportEvents(t, out.String())
	last = events[len(events)-1]
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if !status.AllVerified || status.ImportedFiles != 2 {
		t.Fatalf("expected preserve import of 2 files, got: %+v", status)
	}
	if _, err := os.Stat(filepath.Join(nasRootDir, "Users", "u2", "photos", "DCIM", "101NIKON", "SMALL.JPG")); err != nil {
		t.Fatalf("expected preserved card directory path: %v", err)
	}
}

func TestMediaImportYMArchiveAndCancel(t *testing.T) {
	_, volumesDir, cardDir, nasRootDir, registry, store, root, member := setupMediaImportFixture(t)
	ts := time.Date(2026, 11, 20, 9, 15, 0, 0, time.Local)
	writeTestMediaFile(t, filepath.Join(cardDir, "PRIVATE", "CLIP_01.MP4"), []byte("sony-video-payload"), ts)

	out := &syncBuffer{}
	ctl := newMediaImportControl(registry, store, nil, nil)
	ctl.output = out
	ctl.allowedSourcePrefix = volumesDir

	// Verify ym (YYYY/MM) archive mode into videos category.
	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "ym-1",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "videos",
		ArchiveMode: "ym",
	}))
	ctl.Wait()
	events := parseMediaImportEvents(t, out.String())
	last := events[len(events)-1]
	var status mediaImportStatus
	if err := json.Unmarshal(last.Result, &status); err != nil {
		t.Fatal(err)
	}
	if !status.AllVerified || status.ImportedFiles != 1 {
		t.Fatalf("expected ym import success, got: %+v", status)
	}
	if _, err := os.Stat(filepath.Join(nasRootDir, "Users", "u2", "videos", "2026", "11", "CLIP_01.MP4")); err != nil {
		t.Fatalf("expected YYYY/MM archived file: %v", err)
	}

	// Cancel when idle returns cancelled=false cleanly without panic or race.
	out.Reset()
	ctl.handle(context.Background(), encodeMediaImportCommand("cancel", mediaImportRequest{
		RequestID: "cancel-idle",
	}))
	events = parseMediaImportEvents(t, out.String())
	if len(events) != 1 || events[0].Operation != "cancel" || events[0].Error != "" {
		t.Fatalf("unexpected idle cancel response: %+v", events)
	}
	if ctl.IsRunning() {
		t.Fatal("expected IsRunning false after completion")
	}
}

type observingWriter struct {
	syncBuffer
	onWrite func(s string)
}

func (w *observingWriter) Write(p []byte) (int, error) {
	if w.onWrite != nil {
		w.onWrite(string(p))
	}
	return w.syncBuffer.Write(p)
}

func TestMediaImportClearsRunningBeforeCompleteEventAndReportsPartialErrors(t *testing.T) {
	_, volumesDir, cardDir, _, registry, store, root, member := setupMediaImportFixture(t)
	ts := time.Date(2026, 11, 20, 9, 15, 0, 0, time.Local)
	writeTestMediaFile(t, filepath.Join(cardDir, "DCIM", "OK.JPG"), []byte("ok-photo-bytes"), ts)

	var runningAtComplete bool
	var sawComplete bool
	var ctl *mediaImportControl
	obs := &observingWriter{}
	obs.onWrite = func(line string) {
		if strings.HasPrefix(line, "LIGHTISLE_MEDIA_IMPORT ") {
			encoded := strings.TrimSpace(strings.TrimPrefix(line, "LIGHTISLE_MEDIA_IMPORT "))
			raw, err := base64.RawURLEncoding.DecodeString(encoded)
			if err == nil && strings.Contains(string(raw), `"operation":"complete"`) {
				sawComplete = true
				runningAtComplete = ctl.IsRunning()
			}
		}
	}
	ctl = newMediaImportControl(registry, store, nil, nil)
	ctl.output = obs
	ctl.allowedSourcePrefix = volumesDir

	ctl.handle(context.Background(), encodeMediaImportCommand("start", mediaImportRequest{
		RequestID:   "eject-race-1",
		SourcePath:  cardDir,
		RootID:      root.ID,
		Generation:  root.Generation,
		UserID:      member.ID,
		Category:    "photos",
		ArchiveMode: "ymd",
	}))
	ctl.Wait()
	if !sawComplete {
		t.Fatal("never observed complete event")
	}
	if runningAtComplete {
		t.Fatal("IsRunning() was still true when complete event was emitted (triggers disk_busy on immediate eject)")
	}
}
