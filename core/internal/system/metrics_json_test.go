package system

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestSnapshotJSONDoesNotExposeLocalProcesses(t *testing.T) {
	snapshot := Snapshot{
		Timestamp: time.Unix(1, 0).UTC(),
		Hostname:  "test-host",
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "processes") {
		t.Fatalf("public snapshot contains local process data: %s", data)
	}
}

func TestLocalSnapshotIncludesProcesses(t *testing.T) {
	cpu := 12.5
	rss := uint64(4096)
	local := LocalSnapshot{
		Snapshot:           Snapshot{Timestamp: time.Unix(1, 0).UTC()},
		Processes:          []ProcessSnapshot{{PID: 42, Name: "Example", CPUPercent: &cpu, RSSBytes: &rss}},
		ProcessesAvailable: true,
	}
	data, err := json.Marshal(local)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["processes"]; !ok {
		t.Fatalf("local snapshot missing processes: %s", data)
	}
	if _, ok := decoded["processesAvailable"]; !ok {
		t.Fatalf("local snapshot missing availability: %s", data)
	}
}
