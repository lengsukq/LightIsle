//go:build darwin && arm64

package system

import "testing"

func TestLocalCollectorProducesBoundedProcessList(t *testing.T) {
	local, err := (&Collector{}).CollectLocal()
	if err != nil {
		t.Fatal(err)
	}
	if !local.ProcessesAvailable {
		t.Fatal("local process list is unavailable")
	}
	if len(local.Processes) > 256 {
		t.Fatalf("local process list has %d entries, want at most 256", len(local.Processes))
	}
	for index, process := range local.Processes {
		if process.PID <= 0 || process.Name == "" {
			t.Fatalf("invalid process at index %d: %+v", index, process)
		}
		if index > 0 && local.Processes[index-1].RSSBytes != nil && process.RSSBytes != nil &&
			*local.Processes[index-1].RSSBytes < *process.RSSBytes {
			t.Fatalf("processes are not sorted by resident memory at index %d", index)
		}
	}
}
