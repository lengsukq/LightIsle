package cinema

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

func TestMissingFilmRetainsProgressAndRequiresFileIdentity(t *testing.T) {
	lib, root, _ := batchTestLibrary(t, "Movie.2020.mp4")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitMetadataScan(t, lib)
	}
	scan()
	films, _, err := lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("initial films: %+v %v", films, err)
	}
	id := films[0].ID
	if err := lib.SaveProgress(42, id, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(root, "Movie.2020.mp4")
	info, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	saved := filepath.Join(t.TempDir(), "saved.mp4")
	if err := os.Rename(name, saved); err != nil {
		t.Fatal(err)
	}
	scan()
	films, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 0 {
		t.Fatalf("missing film visible: %+v %v", films, err)
	}
	var missing string
	var progress float64
	if err := lib.db.QueryRow(`SELECT missing_path FROM films WHERE id=?`, id).Scan(&missing); err != nil || missing != "Movie.2020.mp4" {
		t.Fatalf("missing record: %q %v", missing, err)
	}
	if err := lib.db.QueryRow(`SELECT position FROM watch_progress WHERE film_id=? AND user_id=42`, id).Scan(&progress); err != nil || progress != 33 {
		t.Fatalf("progress lost: %f %v", progress, err)
	}
	if err := os.WriteFile(name, []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(name, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	scan()
	films, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 || films[0].ID == id || films[0].Position != 0 {
		t.Fatalf("replacement inherited progress: %+v %v", films, err)
	}
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(saved, name); err != nil {
		t.Fatal(err)
	}
	scan()
	films, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 || films[0].ID != id || films[0].Position != 33 {
		t.Fatalf("original not restored: %+v %v", films, err)
	}
}

func TestFilmRenameKeepsProgress(t *testing.T) {
	lib, root, _ := batchTestLibrary(t, "Movie.2020.mp4")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitMetadataScan(t, lib)
	}
	scan()
	films, _, err := lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("initial: %+v %v", films, err)
	}
	id := films[0].ID
	if err := lib.SaveProgress(42, id, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "movies"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(root, "Movie.2020.mp4"), filepath.Join(root, "movies", "Renamed.2020.mp4")); err != nil {
		t.Fatal(err)
	}
	scan()
	films, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 || films[0].ID != id || films[0].Position != 33 || films[0].Path != "movies/Renamed.2020.mp4" {
		t.Fatalf("rename lost progress: %+v %v", films, err)
	}
	missing, _, err := lib.MissingMedia([]string{"."}, 0, 20)
	if err != nil || len(missing) != 0 {
		t.Fatalf("rename marked missing: %+v %v", missing, err)
	}
}

func TestLegacyFilmIdentityIsNotGuessed(t *testing.T) {
	lib, _, _ := batchTestLibrary(t, "Movie.2020.mp4")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitMetadataScan(t, lib)
	}
	scan()
	films, _, err := lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("initial: %+v %v", films, err)
	}
	id := films[0].ID
	if err := lib.SaveProgress(42, id, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE films SET file_identity='' WHERE id=?`, id); err != nil {
		t.Fatal(err)
	}
	scan()
	films, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(films) != 1 || films[0].ID == id || films[0].Position != 0 {
		t.Fatalf("unverified film inherited progress: %+v %v", films, err)
	}
	missing, _, err := lib.MissingMedia([]string{"."}, 0, 20)
	if err != nil || len(missing) != 1 || missing[0].ID != id || missing[0].Reason != "identity_unverified" {
		t.Fatalf("legacy data not available for review: %+v %v", missing, err)
	}
	current := films[0].ID
	if err := lib.SaveProgress(42, current, 50, 100, false); err != nil {
		t.Fatal(err)
	}
	if err := lib.AttachMissing(id, []string{"."}); !errors.Is(err, mediapending.ErrConflict) {
		t.Fatalf("progress conflict overwritten: %v", err)
	}
	if _, err := lib.db.Exec(`DELETE FROM watch_progress WHERE film_id=? AND user_id=42`, current); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []struct {
		name string
		run  func(mediapending.Guard) error
	}{
		{"attach", func(g mediapending.Guard) error { return lib.AttachMissingGuarded(id, []string{"."}, g) }},
		{"discard", func(g mediapending.Guard) error { return lib.DiscardMissingGuarded(id, []string{"."}, g) }},
	} {
		calls := 0
		err := operation.run(func(path string) error {
			calls++
			if path != "Movie.2020.mp4" {
				t.Fatalf("guard path: %q", path)
			}
			if calls == 2 {
				return mediapending.ErrRootUnavailable
			}
			return nil
		})
		if !errors.Is(err, mediapending.ErrRootUnavailable) || calls != 2 {
			t.Fatalf("%s did not reject interrupted operation: calls=%d err=%v", operation.name, calls, err)
		}
		var missing, position float64
		var targetProgress int
		if err := lib.db.QueryRow(`SELECT COUNT(*) FROM films WHERE id=? AND missing_path<>''`, id).Scan(&missing); err != nil {
			t.Fatal(err)
		}
		if err := lib.db.QueryRow(`SELECT position FROM watch_progress WHERE film_id=? AND user_id=42`, id).Scan(&position); err != nil {
			t.Fatal(err)
		}
		if err := lib.db.QueryRow(`SELECT COUNT(*) FROM watch_progress WHERE film_id=? AND user_id=42`, current).Scan(&targetProgress); err != nil {
			t.Fatal(err)
		}
		if missing != 1 || position != 33 || targetProgress != 0 {
			t.Fatalf("%s left partial changes: missing=%v position=%v targetProgress=%d", operation.name, missing, position, targetProgress)
		}
	}
	if err := lib.AttachMissing(id, []string{"."}); err != nil {
		t.Fatal(err)
	}
	film, err := lib.Get(current, 42)
	if err != nil || film.Position != 33 {
		t.Fatalf("progress not attached: %+v %v", film, err)
	}
}
