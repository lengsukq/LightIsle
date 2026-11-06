package server

import "testing"

func TestMissingMediaScanState(t *testing.T) {
	for _, tc := range []struct {
		running bool
		done    int64
		err     string
		want    string
	}{
		{true, 10, "old failure", "running"},
		{false, 10, "cancelled", "failed"},
		{false, 0, "", "not_checked"},
		{false, 10, "", "finished"},
	} {
		if got := missingMediaScanState(tc.running, tc.done, tc.err); got != tc.want {
			t.Fatalf("state(%v, %d, %q) = %q, want %q", tc.running, tc.done, tc.err, got, tc.want)
		}
	}
}
