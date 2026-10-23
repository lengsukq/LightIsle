package cinema

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	_ "github.com/mattn/go-sqlite3"
)

type fakeCinemaWorker struct {
	calls map[string]int
	probe func(context.Context, *os.File, string) (mediaworker.Metadata, error)
}

func (w *fakeCinemaWorker) Probe(ctx context.Context, source *os.File, name string) (mediaworker.Metadata, error) {
	if w.calls == nil {
		w.calls = map[string]int{}
	}
	w.calls[name]++
	return w.probe(ctx, source, name)
}

func waitCinemaScan(t *testing.T, library *Library) {
	t.Helper()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if status := library.Status(); status.Running || status.LastError != "" {
		t.Fatalf("cinema scan did not finish: %+v", status)
	}
}

func findFilm(t *testing.T, library *Library, name string) Film {
	t.Helper()
	films, _, err := library.List(1, "", "", 120, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, film := range films {
		if filepath.Base(film.Path) == name {
			return film
		}
	}
	t.Fatalf("film %q missing", name)
	return Film{}
}

func TestCinemaProbeStatusCodecMatrixAndRetry(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	share, _ := storage.State()
	modified := time.Unix(1_700_000_000, 0)
	for name, data := range map[string]string{"good.mp4": "h264", "retry.webm": "vp9", "odd.mov": "hevc", "unknown.mkv": "unknown"} {
		if err := os.WriteFile(filepath.Join(share, name), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(filepath.Join(share, name), modified, modified); err != nil {
			t.Fatal(err)
		}
	}
	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	worker := &fakeCinemaWorker{}
	worker.probe = func(_ context.Context, _ *os.File, name string) (mediaworker.Metadata, error) {
		switch name {
		case "good.mp4":
			return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Container: "mp4", VideoCodec: "h264", AudioCodec: "aac", DurationSeconds: 90, Width: 1920, Height: 1080}, nil
		case "retry.webm":
			if worker.calls[name] == 1 {
				return mediaworker.Metadata{}, errors.New("temporary decode error")
			}
			return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Container: "webm", VideoCodec: "vp9", AudioCodec: "opus", DurationSeconds: 12.5, Width: 640, Height: 360}, nil
		case "odd.mov":
			return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Container: "quicktime", VideoCodec: "hevc", AudioCodec: "aac", DurationSeconds: 30, Width: 3840, Height: 2160}, nil
		default:
			return mediaworker.Metadata{}, mediaworker.ErrUnsupported
		}
	}
	library.SetMediaWorker(worker)
	waitCinemaScan(t, library)
	good := findFilm(t, library, "good.mp4")
	if good.ProbeStatus != "ready" || good.BrowserPlayback != "verified-direct" || !good.Playable || good.MediaDuration != 90 {
		t.Fatalf("valid browser media not marked verified: %+v", good)
	}
	odd := findFilm(t, library, "odd.mov")
	if odd.ProbeStatus != "ready" || odd.BrowserPlayback != "download-only" || odd.Playable {
		t.Fatalf("extension/codec mismatch falsely playable: %+v", odd)
	}
	unknown := findFilm(t, library, "unknown.mkv")
	if unknown.ProbeStatus != "unsupported" || unknown.BrowserPlayback != "download-only" || unknown.Playable {
		t.Fatalf("unsupported probe was exposed as ready: %+v", unknown)
	}
	retry := findFilm(t, library, "retry.webm")
	if retry.ProbeStatus != "failed" || retry.BrowserPlayback != "download-only" {
		t.Fatalf("failed result was exposed as playable: %+v", retry)
	}
	waitCinemaScan(t, library)
	retry = findFilm(t, library, "retry.webm")
	if retry.ProbeStatus != "ready" || retry.BrowserPlayback != "verified-direct" || retry.MediaDuration != 12.5 {
		t.Fatalf("failed probe was not retried: %+v", retry)
	}
	if worker.calls["good.mp4"] != 1 || worker.calls["unknown.mkv"] != 1 || worker.calls["retry.webm"] != 2 {
		t.Fatalf("unexpected retries: %+v", worker.calls)
	}

	filmPath := filepath.Join(share, "good.mp4")
	if err := os.WriteFile(filmPath, []byte("changed good movie"), 0600); err != nil {
		t.Fatal(err)
	}
	changed := modified.Add(time.Minute)
	if err := os.Chtimes(filmPath, changed, changed); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := library.Read(good.ID, 1); !errors.Is(err, ErrAssetChanged) {
		t.Fatalf("source changed after scan was served as current: %v", err)
	}
}

func TestMissingWorkerIsExplicitUnverifiedFallback(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	share, _ := storage.State()
	if err := os.WriteFile(filepath.Join(share, "legacy.mp4"), []byte("bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	waitCinemaScan(t, library)
	film := findFilm(t, library, "legacy.mp4")
	if film.ProbeStatus != "unavailable" || film.BrowserPlayback != "unverified-direct" || !film.Playable {
		t.Fatalf("missing worker fallback is ambiguous: %+v", film)
	}
}

func TestLegacyCinemaSchemaMigrationDoesNotInventProbe(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	share, _ := storage.State()
	db, err := sql.Open("sqlite3", filepath.Join(root, "cinema.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE films(id INTEGER PRIMARY KEY AUTOINCREMENT,share TEXT NOT NULL,path TEXT NOT NULL,title TEXT NOT NULL,manual_title INTEGER NOT NULL DEFAULT 0,kind TEXT NOT NULL,series TEXT NOT NULL DEFAULT '',season INTEGER NOT NULL DEFAULT 0,episode INTEGER NOT NULL DEFAULT 0,year INTEGER NOT NULL DEFAULT 0,size INTEGER NOT NULL,modified INTEGER NOT NULL,seen INTEGER NOT NULL,UNIQUE(share,path)); INSERT INTO films(share,path,title,kind,size,modified,seen) VALUES(?,?,?,?,?,?,?)`, share, "old.mp4", "Old", "movie", 9, 123, 123)
	if err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	film, err := library.Get(1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if film.ProbeStatus != "" || film.MediaDuration != 0 || film.BrowserPlayback != "unverified-direct" || !film.Playable {
		t.Fatalf("migration invented probe history or lost compatibility fallback: %+v", film)
	}
}
