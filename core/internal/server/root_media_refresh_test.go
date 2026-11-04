package server

import "testing"

func TestMediaKindForPath(t *testing.T) {
	for _, tc := range []struct{ path, want string }{
		{"图库/2026/照片.heic", "gallery"},
		{"photos/DCIM/a.jpeg", "gallery"},
		{"Users/u5/photos/my-photo.heic", "gallery"},
		{"Users/u5/videos/my-video.mp4", "cinema"},
		{"影视/剧集/S01E01.mkv", "cinema"},
		{"videos/one.mkv", "cinema"},
		{"Users/u5/files/text.txt", ""},
		{"Users/u5/other/anything.mov", ""},
		{"docs/readme.txt", ""},
		{"random/photos/media.jpg", "gallery"},
		{"家庭/2026/生日.jpg", "gallery"},
		{"家庭/婚礼.HEIC", "gallery"},
		{"Movies/Film.MKV", "cinema"},
		{"Users/u5/files/camera.mp4", "cinema"},
		{".lightisle-config/movie.mp4", ""},
		{"docs/pictures.zip", ""},
		{"", ""},
	} {
		if got := mediaKindForPath(tc.path); got != tc.want {
			t.Errorf("mediaKindForPath(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
}

func TestDefaultTaskRoutesUseCurrentVerifiedRoot(t *testing.T) {
	f := newRootRoutingFixture(t)
	for _, root := range []struct {
		id         string
		generation uint64
	}{
		{f.rootA.ID, f.rootA.Generation},
		{f.rootB.ID, f.rootB.Generation},
	} {
		if err := f.registry.SetDefault(t.Context(), root.id, root.generation); err != nil {
			t.Fatal(err)
		}
		// The fixture deliberately has no host-wide journal, only per-root
		// journals. This verifies that host history is NOT accidentally
		// replaced by whichever root was selected as default.
		if r := f.call(f.admin, "GET", "/api/v2/tasks", ""); r.Code != 200 {
			t.Fatalf("host task list lost after root switch: %d %s", r.Code, r.Body.String())
		}
		if r := f.call(f.admin, "GET", "/api/v2/tasks/history", ""); r.Code != 503 {
			t.Fatalf("host task history was silently replaced by root %s: %d %s", root.id, r.Code, r.Body.String())
		}
		// But default-root media task controls must reach the live root
		// instead of the disabled single-root global gallery.
		if r := f.call(f.admin, "POST", "/api/v2/tasks/gallery/retry", ""); r.Code != 202 {
			t.Fatalf("media retry did not route to root %s: %d %s", root.id, r.Code, r.Body.String())
		}
		missing := f.call(f.member, "POST", "/api/v2/tasks/gallery/retry", "")
		if missing.Code != 403 && missing.Code != 404 {
			t.Fatalf("member started administrator task on %s: %d %s", root.id, missing.Code, missing.Body.String())
		}
	}
}
