package files

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkDirectoryPage(b *testing.B) {
	root := b.TempDir()
	store, err := Open(root)
	if err != nil {
		b.Fatal(err)
	}
	defer store.Close()
	for i := range 10000 {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("file-%05d", i)), nil, 0600); err != nil {
			b.Fatal(err)
		}
	}
	for _, key := range []SortKey{SortName, SortSize, SortModified} {
		for _, desc := range []bool{false, true} {
			b.Run(fmt.Sprintf("%s/desc=%t", key, desc), func(b *testing.B) {
				b.ReportAllocs()
				for range b.N {
					page, next, err := store.PageSorted(".", "", 100, key, desc)
					if err != nil || len(page) != 100 || next == "" {
						b.Fatalf("page=%d cursor=%q: %v", len(page), next, err)
					}
				}
			})
		}
	}
}
