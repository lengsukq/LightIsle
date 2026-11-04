package gallery

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// Measures a complete warm reconciliation, including directory I/O and SQLite,
// but no image decoding. Originals are synthetic and the thumbnail cache empty.
func BenchmarkGalleryWarmScan(b *testing.B) {
	data := b.TempDir()
	root := b.TempDir()
	handle, err := os.OpenRoot(root)
	if err != nil {
		b.Fatal(err)
	}
	defer handle.Close()
	store, err := files.NewPinnedManager(handle)
	if err != nil {
		b.Fatal(err)
	}
	defer store.Close()
	for i := range 1000 {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("photo-%04d.jpg", i)), []byte("synthetic"), 0600); err != nil {
			b.Fatal(err)
		}
	}
	lib, err := Open(data, store)
	if err != nil {
		b.Fatal(err)
	}
	defer lib.Close()
	lib.scan(context.Background(), []string{"."})
	if st := lib.Status(); st.LastError != "" || st.Found != 1000 {
		b.Fatalf("initial scan: %+v", st)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		lib.scan(context.Background(), []string{"."})
		if st := lib.Status(); st.LastError != "" || st.Found != 1000 {
			b.Fatalf("scan: %+v", st)
		}
	}
	b.StopTimer()
	if n, err := lib.Count(); err != nil || n != 1000 {
		b.Fatalf("count=%d: %v", n, err)
	}
}
