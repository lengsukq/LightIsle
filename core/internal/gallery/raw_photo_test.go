package gallery

import "testing"

func TestCameraRAWIsIndexedAsOriginalPhoto(t *testing.T) {
	for _, name := range []string{
		"IMG_001.DNG", "photo.cr2", "shot.CR3", "Sony.arw",
		"Nikon.NEF", "Fuji.raf", "Panasonic.rw2", "Olympus.orf",
		"Pentax.pef", "image.tif",
	} {
		if got := mediaType(name); got != "photo" {
			t.Errorf("%q must be indexed as photo, got %q", name, got)
		}
	}
	if got := mediaType("not-an-image.exe"); got != "" {
		t.Errorf("unexpected media type for executable: %q", got)
	}
}
