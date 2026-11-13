package automation

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkReadEnv20Keys(b *testing.B) {
	dir := b.TempDir()
	envMap := make(map[string]string, 20)
	for i := 0; i < 20; i++ {
		envMap[fmt.Sprintf("LIGHTISLE_TASK_KEY_%02d", i)] = fmt.Sprintf("value-%02d", i)
	}
	raw, err := json.Marshal(envMap)
	if err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "env.json"), raw, 0600); err != nil {
		b.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		b.Fatal(err)
	}
	defer root.Close()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		vals, err := readEnv(root, "env.json")
		if err != nil || len(vals) != 20 {
			b.Fatalf("readEnv failed: len=%d err=%v", len(vals), err)
		}
	}
}
