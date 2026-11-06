package cinema

import (
	"context"
	"testing"
)

func TestFilmWithoutPhysicalIdentityDoesNotInheritProgress(t *testing.T) {
	lib, root, entries := batchTestLibrary(t, "Movie.2020.mp4")
	entries[0].Identity = ""
	if err := lib.indexScanBatch(context.Background(), root, root, 1, entries); err != nil {
		t.Fatal(err)
	}
	items, _, err := lib.List(42, "movie", "", 20, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("initial media: %+v %v", items, err)
	}
	id := items[0].ID
	if err := lib.SaveProgress(42, id, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if err := lib.indexScanBatch(context.Background(), root, root, 2, entries); err != nil {
		t.Fatal(err)
	}
	items, _, err = lib.List(42, "movie", "", 20, 0)
	if err != nil || len(items) != 1 || items[0].ID == id || items[0].Position != 0 {
		t.Fatalf("unverified file inherited progress: %+v %v", items, err)
	}
	missing, _, err := lib.MissingMedia([]string{"."}, 0, 20)
	if err != nil || len(missing) != 1 || missing[0].ID != id || missing[0].Reason != "identity_unverified" {
		t.Fatalf("unverified data not retained: %+v %v", missing, err)
	}
}
