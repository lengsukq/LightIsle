package diskhealth

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

const nvmeFixture = `{
  "device_name": "/dev/disk4",
  "model_name": "Samsung SSD 980 1TB",
  "serial_number": "S5XBNX0R123456",
  "firmware_version": "1B4QFXOA",
  "smart_status": {"passed": true, "nvme": {"value": 0}},
  "temperature": {"current": 41},
  "power_on_time": {"hours": 8123},
  "user_capacity": {"blocks": 1953525168, "bytes": 1000204886016},
  "nvme_smart_health_information_log": {
    "critical_warning": 0, "temperature": 41, "percentage_used": 3,
    "power_on_hours": 8123
  }
}`

const ataFixture = `{
  "device_name": "/dev/disk2",
  "model_family": "TOSHIBA N300",
  "model_name": "TOSHIBA HDWG480",
  "serial_number": "89TXK1EZFS5G",
  "firmware_version": "KF10O2AA",
  "smart_status": {"passed": false},
  "temperature": {"current": 33},
  "power_on_time": {"hours": 15320},
  "ata_smart_attributes": {"table": [
    {"id": 9, "name": "Power_On_Hours", "value": 84, "raw": {"value": 15320}},
    {"id": 177, "name": "Wear_Leveling_Count", "value": 91, "raw": {"value": 4294967296}}
  ]}
}`

func TestNormalizeDevice(t *testing.T) {
	cases := map[string]struct {
		want string
		ok   bool
	}{
		"disk4":    {"disk4", true},
		"disk12s1": {"disk12", true},
		"disk4s2":  {"disk4", true},
		"diskx":    {"", false},
		"disk":     {"", false},
		"../disk4": {"", false},
		"disk4s1x": {"", false},
		"disk-4":   {"", false},
		"":         {"", false},
		"disk4/s1": {"", false},
	}
	for id, want := range cases {
		got, ok := NormalizeDevice(id)
		if got != want.want || ok != want.ok {
			t.Errorf("NormalizeDevice(%q) = (%q, %v), want (%q, %v)", id, got, ok, want.want, want.ok)
		}
	}
}

func stubLocate(m *Manager) {
	m.locate = func() (string, error) { return "/fake/bin/smartctl", nil }
}

func TestReportNVMe(t *testing.T) {
	calls := 0
	m := New()
	stubLocate(m)
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		calls++
		return []byte(nvmeFixture), nil, 0, nil
	}
	report, err := m.Report(context.Background(), "disk4s1")
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if report.Source != "smartctl" || report.Reason != "" {
		t.Fatalf("report = %+v", report)
	}
	if report.Model != "Samsung SSD 980 1TB" || report.Serial != "S5XBNX0R123456" {
		t.Errorf("identity fields = %+v", report)
	}
	if report.Temperature == nil || *report.Temperature != 41 {
		t.Errorf("temperature = %v", report.Temperature)
	}
	if report.Passed == nil || !*report.Passed {
		t.Errorf("passed = %v", report.Passed)
	}
	if report.PowerOnHours == nil || *report.PowerOnHours != 8123 {
		t.Errorf("powerOnHours = %v", report.PowerOnHours)
	}
	if report.LifeUsed == nil || *report.LifeUsed != 3 {
		t.Errorf("lifeUsed = %v", report.LifeUsed)
	}
	if _, err := m.Report(context.Background(), "disk4"); err != nil {
		t.Fatalf("cached Report: %v", err)
	}
	if calls != 1 {
		t.Errorf("expected cached lookup, got %d queries", calls)
	}
}

func TestReportATAWearAndFailure(t *testing.T) {
	m := New()
	stubLocate(m)
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		return []byte(ataFixture), nil, 0, nil
	}
	report, err := m.Report(context.Background(), "disk2")
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if report.Passed == nil || *report.Passed {
		t.Errorf("expected failing SMART status, got %v", report.Passed)
	}
	if report.Model != "TOSHIBA N300" {
		t.Errorf("model should prefer family name, got %q", report.Model)
	}
	if report.LifeUsed == nil || *report.LifeUsed != 9 {
		t.Errorf("wear-leveling lifeUsed = %v, want 9", report.LifeUsed)
	}
	if report.PowerOnHours == nil || *report.PowerOnHours != 15320 {
		t.Errorf("powerOnHours = %v", report.PowerOnHours)
	}
}

func TestReportPermissionDegradation(t *testing.T) {
	m := New()
	stubLocate(m)
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		return nil, []byte("smartctl 7.4: Permission denied"), 2, nil
	}
	report, err := m.Report(context.Background(), "disk5")
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if report.Source != "none" || report.Reason != ReasonPermission {
		t.Fatalf("report = %+v", report)
	}
	if report.Temperature != nil || report.Passed != nil || report.Model != "" {
		t.Errorf("degraded report must not fabricate data: %+v", report)
	}
}

func TestReportUSBBridgeUnsupported(t *testing.T) {
	m := New()
	stubLocate(m)
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		return nil, []byte("Unknown USB bridge [0x152d:0x0567]"), 4, nil
	}
	report, _ := m.Report(context.Background(), "disk3")
	if report.Reason != ReasonUnsupported {
		t.Fatalf("reason = %q, want unsupported", report.Reason)
	}
}

func TestReportMissingBinary(t *testing.T) {
	m := New()
	m.locate = func() (string, error) { return "", errors.New(ReasonNotInstalled) }
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		return nil, nil, 0, errors.New("must not run")
	}
	report, _ := m.Report(context.Background(), "disk1")
	if report.Reason != ReasonNotInstalled || report.Source != "none" {
		t.Fatalf("report = %+v", report)
	}
}

func TestReportInvalidDevice(t *testing.T) {
	m := New()
	if _, err := m.Report(context.Background(), "../../etc"); err == nil || !strings.Contains(err.Error(), ReasonFailed) {
		t.Fatalf("expected invalid device rejection, got %v", err)
	}
}

func TestCacheTTLExpiry(t *testing.T) {
	calls := 0
	m := New()
	stubLocate(m)
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, []byte, int, error) {
		calls++
		return []byte(nvmeFixture), nil, 0, nil
	}
	if _, err := m.Report(context.Background(), "disk4"); err != nil {
		t.Fatalf("Report: %v", err)
	}
	m.cache["disk4"] = entry{report: m.cache["disk4"].report, at: time.Now().Add(-cacheTTL - time.Second)}
	if _, err := m.Report(context.Background(), "disk4"); err != nil {
		t.Fatalf("Report after expiry: %v", err)
	}
	if calls != 2 {
		t.Errorf("expected expired cache to refresh, got %d calls", calls)
	}
}

func TestIngestReportValidationAndCache(t *testing.T) {
	m := New()
	stubLocate(m)
	valid := `{"device":"disk4","source":"smartctl","model":"Samsung","temperature":41,"passed":true}`
	report, err := m.IngestReport("disk4s1", []byte(valid))
	if err != nil {
		t.Fatalf("IngestReport: %v", err)
	}
	if report.Device != "disk4" || report.Temperature == nil {
		t.Fatalf("report = %+v", report)
	}
	// Cached: a later plain query must return the ingested report without
	// invoking smartctl.
	cached, err := m.Report(context.Background(), "disk4")
	if err != nil || cached.Source != "smartctl" || cached.Model != "Samsung" {
		t.Fatalf("cached = %+v, %v", cached, err)
	}
	for name, payload := range map[string]string{
		"not smartctl source": `{"device":"disk4","source":"none","reason":"smartctl_permission_required"}`,
		"no health data":      `{"device":"disk4","source":"smartctl"}`,
		"truncated json":      `{"device":"disk4","source":"smartctl"`,
	} {
		if _, err := m.IngestReport("disk4", []byte(payload)); err == nil {
			t.Errorf("%s must be rejected", name)
		}
	}
	if _, err := m.IngestReport("../../etc", []byte(valid)); err == nil {
		t.Error("invalid device must be rejected")
	}
}
