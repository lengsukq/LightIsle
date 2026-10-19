package cinema

import (
	"errors"
	"github.com/lengsukq/lightisle/core/internal/files"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestIdentify(t *testing.T) {
	checks := []struct {
		name, title, kind     string
		season, episode, year int
	}{
		{"The.Matrix.1999.1080p.mp4", "The Matrix", "movie", 0, 0, 1999},
		{"Example.Show.S02E03.mkv", "Example Show", "series", 2, 3, 0},
		{"Example.Show.1x12.webm", "Example Show", "series", 1, 12, 0},
	}
	for _, c := range checks {
		name, kind, _, season, episode, year := Identify(c.name)
		if name != c.title || kind != c.kind || season != c.season || episode != c.episode || year != c.year {
			t.Errorf("%s parsed as %s %s %d %d %d", c.name, name, kind, season, episode, year)
		}
	}
}
func TestScanAndIsolatedProgress(t *testing.T) {
	base := t.TempDir()
	fs, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer fs.Close()
	share := filepath.Join(base, "SharedFiles")
	if err := os.WriteFile(filepath.Join(share, "The.Matrix.1999.mp4"), []byte("hello-video"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "The.Matrix.1999.zh.srt"), []byte("1\n00:00:01,000 --> 00:00:02,000\nhello"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := fs.Mkdir("TV"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "TV", "Demo.Show.S01E02.mkv"), []byte("other-video"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(base, fs)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(8 * time.Second)
		for lib.Status().Running && time.Now().Before(deadline) {
			time.Sleep(25 * time.Millisecond)
		}
		s := lib.Status()
		if s.Running || s.LastError != "" || s.Found != 2 {
			t.Fatalf("scan: %+v", s)
		}
	}
	scan()
	movies, _, err := lib.List(1, "movie", "Matrix", 20, 0)
	if err != nil || len(movies) != 1 || !movies[0].Playable {
		t.Fatalf("movies %+v %v", movies, err)
	}
	series, _, err := lib.List(1, "series", "Demo", 20, 0)
	if err != nil || len(series) != 1 || series[0].Episode != 2 || series[0].Playable {
		t.Fatalf("series %+v %v", series, err)
	}
	item := movies[0]
	if err := lib.SaveProgress(1, item.ID, 45, 100, false); err != nil {
		t.Fatal(err)
	}
	one, err := lib.Get(item.ID, 1)
	if err != nil || one.Position != 45 {
		t.Fatalf("owner progress %+v %v", one, err)
	}
	other, err := lib.Get(item.ID, 2)
	if err != nil || other.Position != 0 {
		t.Fatalf("leaked progress %+v %v", other, err)
	}
	sub, ext, err := lib.FindSubtitle(item, "zh")
	if err != nil {
		t.Fatal(err)
	}
	bytes, err := io.ReadAll(sub)
	sub.Close()
	if ext != ".srt" || err != nil || !strings.Contains(string(bytes), "hello") {
		t.Fatal("subtitle")
	}
	if _, _, err := lib.FindSubtitle(item, "../../etc"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("subtitle path escape: %v", err)
	}
	if err := lib.Rename(item.ID, "Custom title"); err != nil {
		t.Fatal(err)
	}
	scan()
	after, err := lib.Get(item.ID, 1)
	if err != nil || after.Title != "Custom title" || after.Position != 45 {
		t.Fatalf("rescan lost edits: %+v %v", after, err)
	}
}
