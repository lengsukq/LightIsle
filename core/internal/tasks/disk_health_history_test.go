package tasks

import (
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/diskhealth"
)

func TestDiskHealthHistoryIsIdentityScopedAndUnknownIsNotHealthy(t *testing.T) {
	dir := t.TempDir()
	j, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	keyA := strings.Repeat("a", 64)
	keyB := strings.Repeat("b", 64)
	temp := 55
	ok := true
	if _, err = j.RecordDiskHealth(keyA, diskhealth.Report{Source: "smartctl", Temperature: &temp, Passed: &ok, Serial: "SECRET"}); err != nil {
		t.Fatal(err)
	}
	other, err := j.DiskHealthHistory(keyB, 100)
	if err != nil || len(other) != 0 {
		t.Fatalf("other disk history leaked: %v, %v", other, err)
	}
	samples, err := j.DiskHealthHistory(keyA, 100)
	if err != nil || len(samples) != 1 || samples[0].Risk != "ok" {
		t.Fatalf("known sample: %+v %v", samples, err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	j, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	samples, err = j.DiskHealthHistory(keyA, 100)
	if err != nil || len(samples) != 1 {
		t.Fatalf("persisted samples: %+v %v", samples, err)
	}
	unknown, err := j.RecordDiskHealth(keyB, diskhealth.Report{Source: "none", Reason: diskhealth.ReasonUnsupported})
	if err != nil || unknown.Risk != "unknown" {
		t.Fatalf("unknown must stay unknown: %+v %v", unknown, err)
	}
	failed := false
	bad, err := j.RecordDiskHealth(keyB, diskhealth.Report{Source: "smartctl", Passed: &failed})
	if err != nil || bad.Risk != "critical" {
		t.Fatalf("SMART failure not critical: %+v %v", bad, err)
	}
	hot := 67
	warn, err := j.RecordDiskHealth(keyB, diskhealth.Report{Source: "smartctl", Passed: &ok, Temperature: &hot})
	if err != nil || warn.Risk != "warning" {
		t.Fatalf("temperature warning: %+v %v", warn, err)
	}
	if _, err = j.DiskHealthHistory(keyA, 361); err == nil {
		t.Fatal("unbounded page accepted")
	}
	if _, err = j.DiskHealthHistory("disk1", 1); err == nil {
		t.Fatal("raw disk id accepted")
	}
}
