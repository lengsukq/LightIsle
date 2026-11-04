package cinema

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// Synthetic already-probed episodes: includes directory I/O, index writes and
// series reconciliation, but no media worker, decoder or external provider.
func BenchmarkCinemaWarmScan(b *testing.B) {
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
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("Show.%04d.S01E01.mp4", i)), []byte("synthetic"), 0600); err != nil {
			b.Fatal(err)
		}
	}
	lib, err := Open(data, store)
	if err != nil {
		b.Fatal(err)
	}
	defer lib.Close()
	lib.wg.Add(1)
	lib.scan(context.Background(), []string{"."})
	if st := lib.Status(); st.LastError != "" || st.Found != 1000 {
		b.Fatalf("initial scan: %+v", st)
	}
	if _, err := lib.db.Exec("UPDATE films SET probe_status='ready'"); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		lib.wg.Add(1)
		lib.scan(context.Background(), []string{"."})
		if st := lib.Status(); st.LastError != "" || st.Found != 1000 {
			b.Fatalf("scan: %+v", st)
		}
	}
	b.StopTimer()
	var n int
	if err := lib.db.QueryRow("SELECT COUNT(*) FROM films").Scan(&n); err != nil || n != 1000 {
		b.Fatalf("count=%d: %v", n, err)
	}
}
