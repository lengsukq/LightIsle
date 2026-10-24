// Package diskhealth adds read-only SMART health reporting on top of the
// optional user-installed smartctl binary (smartmontools). It never writes to
// devices, never elevates privileges, and degrades honestly when smartctl is
// missing or lacks device access: callers receive a stable machine reason
// code instead of a fabricated "healthy" answer.
package diskhealth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Reason codes are stable machine strings; the web and native clients map
// them to localized explanations.
const (
	ReasonNotInstalled = "smartctl_not_installed"
	ReasonPermission   = "smartctl_permission_required"
	ReasonUnsupported  = "smartctl_device_unsupported"
	ReasonFailed       = "smartctl_query_failed"
)

const (
	queryTimeout = 12 * time.Second
	maxOutput    = 256 * 1024
	cacheTTL     = 5 * time.Minute
)

// Only known Homebrew prefixes are probed. Like the Docker runtime and the
// media worker, external binaries are never searched on PATH or downloaded.
var candidates = []string{"/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"}

type Report struct {
	Device       string `json:"device"`
	Source       string `json:"source"` // "smartctl" or "none"
	Reason       string `json:"reason,omitempty"`
	Model        string `json:"model,omitempty"`
	Serial       string `json:"serial,omitempty"`
	Firmware     string `json:"firmware,omitempty"`
	Temperature  *int   `json:"temperature,omitempty"`
	Passed       *bool  `json:"passed,omitempty"`
	PowerOnHours *int   `json:"powerOnHours,omitempty"`
	LifeUsed     *int   `json:"lifeUsed,omitempty"`
}

var wholeDiskRule = regexp.MustCompile(`^disk([0-9]+)(?:s[0-9]+)?$`)

// NormalizeDevice accepts a whole-disk ("disk4") or partition ("disk4s1")
// identifier and returns the BSD whole-disk name smartctl should query.
func NormalizeDevice(id string) (string, bool) {
	parts := wholeDiskRule.FindStringSubmatch(id)
	if len(parts) == 0 {
		return "", false
	}
	return "disk" + parts[1], true
}

type entry struct {
	report Report
	at     time.Time
}

type Manager struct {
	mu      sync.Mutex
	run     func(ctx context.Context, bin string, args ...string) (stdout []byte, stderr []byte, exitCode int, err error)
	locate  func() (string, error)
	bin     string
	checked bool
	cache   map[string]entry
}

var shared = New()

func Shared() *Manager { return shared }
func New() *Manager {
	m := &Manager{run: runSmartctl, cache: map[string]entry{}}
	m.locate = m.probeBinary
	return m
}

func (m *Manager) probeBinary() (string, error) {
	if m.checked {
		return m.bin, nil
	}
	for _, path := range candidates {
		info, err := os.Stat(path)
		if err != nil || info.IsDir() || info.Mode()&0111 == 0 {
			continue
		}
		m.bin, m.checked = path, true
		return m.bin, nil
	}
	// A miss stays uncached so a later `brew install` is picked up without a
	// restart; two stat calls per query are cheap.
	return "", errors.New(ReasonNotInstalled)
}

// Report returns the best-effort SMART health report for a disk ("disk4" or a
// partition of it). Unavailable health data is expressed as Source "none"
// plus a reason code, never as an empty success.
func (m *Manager) Report(ctx context.Context, id string) (Report, error) {
	device, ok := NormalizeDevice(id)
	if !ok {
		return Report{}, fmt.Errorf("%s: %w", ReasonFailed, ErrInvalid)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if hit, ok := m.cache[device]; ok && time.Since(hit.at) < cacheTTL {
		return hit.report, nil
	}
	report := m.query(ctx, device)
	m.cache[device] = entry{report: report, at: time.Now()}
	return report, nil
}

func (m *Manager) query(ctx context.Context, device string) Report {
	base := Report{Device: device, Source: "none"}
	bin, err := m.locate()
	if err != nil {
		base.Reason = ReasonNotInstalled
		return base
	}
	stdout, stderr, exitCode, err := m.run(ctx, bin, "--json", "-a", "/dev/"+device)
	if err != nil {
		base.Reason = ReasonFailed
		return base
	}
	var out smartctlOutput
	if len(stdout) > 0 && len(stdout) <= maxOutput && json.Unmarshal(stdout, &out) == nil {
		return mergeSmartctl(base, &out)
	}
	base.Reason = classifyFailure(stderr, exitCode)
	return base
}

func classifyFailure(stderr []byte, exitCode int) string {
	text := strings.ToLower(string(stderr))
	switch {
	case exitCode < 0:
		return ReasonFailed
	case strings.Contains(text, "permission denied"), exitCode&0x02 != 0:
		return ReasonPermission
	case strings.Contains(text, "usb bridge"), strings.Contains(text, "unknown usb"),
		strings.Contains(text, "smart status is: unavailable"), exitCode&0x04 != 0:
		return ReasonUnsupported
	default:
		return ReasonFailed
	}
}

func mergeSmartctl(base Report, out *smartctlOutput) Report {
	base.Source = "smartctl"
	base.Model = firstNonEmpty(out.ModelFamily, out.ModelName)
	base.Serial = out.SerialNumber
	base.Firmware = out.FirmwareVersion
	if out.SmartStatus != nil {
		passed := out.SmartStatus.Passed
		base.Passed = &passed
	}
	if out.Temperature != nil && out.Temperature.Current != nil && *out.Temperature.Current > 0 {
		temperature := *out.Temperature.Current
		base.Temperature = &temperature
	}
	if out.PowerOnTime != nil && out.PowerOnTime.Hours != nil && *out.PowerOnTime.Hours > 0 {
		hours := *out.PowerOnTime.Hours
		base.PowerOnHours = &hours
	}
	if out.NVMe != nil {
		if base.Temperature == nil && out.NVMe.Temperature != nil && *out.NVMe.Temperature > 0 {
			temperature := *out.NVMe.Temperature
			base.Temperature = &temperature
		}
		if base.PowerOnHours == nil && out.NVMe.PowerOnHours != nil && *out.NVMe.PowerOnHours > 0 {
			hours := *out.NVMe.PowerOnHours
			base.PowerOnHours = &hours
		}
		if out.NVMe.PercentageUsed != nil && *out.NVMe.PercentageUsed >= 0 && *out.NVMe.PercentageUsed <= 1000 {
			used := *out.NVMe.PercentageUsed
			base.LifeUsed = &used
		}
	}
	if out.ATA != nil {
		for _, attribute := range out.ATA.Table {
			// 177 Wear_Leveling_Count: normalized value approximates remaining
			// life on SSDs; 9 Power_On_Hours raw value is hours on most drives.
			switch attribute.ID {
			case 177:
				if base.LifeUsed == nil && attribute.Value != nil && *attribute.Value >= 0 && *attribute.Value <= 100 {
					used := 100 - *attribute.Value
					base.LifeUsed = &used
				}
			case 9:
				if base.PowerOnHours == nil && attribute.Raw.Value > 0 && attribute.Raw.Value <= 1<<40 {
					hours := int(attribute.Raw.Value)
					base.PowerOnHours = &hours
				}
			}
		}
	}
	return base
}

// IngestReport caches a SMART report collected by the trusted Mac App after
// a user-approved administrator elevation (the Go core cannot read device
// SMART itself and the web cannot present the macOS auth dialog). The
// payload is strictly validated: it must parse as a smartctl-sourced report
// for the requested device and carry at least one real health datum.
func (m *Manager) IngestReport(id string, payload []byte) (Report, error) {
	device, ok := NormalizeDevice(id)
	if !ok || len(payload) == 0 || len(payload) > 64*1024 {
		return Report{}, fmt.Errorf("%s: %w", ReasonFailed, ErrInvalid)
	}
	var report Report
	if err := json.Unmarshal(payload, &report); err != nil {
		return Report{}, fmt.Errorf("%s: %w", ReasonFailed, ErrInvalid)
	}
	if report.Source != "smartctl" {
		return Report{}, fmt.Errorf("%s: %w", ReasonFailed, ErrInvalid)
	}
	hasData := report.Passed != nil || report.Temperature != nil ||
		report.PowerOnHours != nil || report.LifeUsed != nil || report.Model != ""
	if !hasData {
		return Report{}, fmt.Errorf("%s: %w", ReasonFailed, ErrInvalid)
	}
	report.Device = device
	report.Reason = ""
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cache[device] = entry{report: report, at: time.Now()}
	return report, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// ErrInvalid mirrors diskmgmt.ErrInvalid semantics for request validation.
var ErrInvalid = errors.New("invalid_drive_request")

type smartctlOutput struct {
	DeviceName      string `json:"device_name"`
	ModelName       string `json:"model_name"`
	ModelFamily     string `json:"model_family"`
	SerialNumber    string `json:"serial_number"`
	FirmwareVersion string `json:"firmware_version"`
	SmartStatus     *struct {
		Passed bool `json:"passed"`
	} `json:"smart_status"`
	Temperature *struct {
		Current *int `json:"current"`
	} `json:"temperature"`
	PowerOnTime *struct {
		Hours *int `json:"hours"`
	} `json:"power_on_time"`
	NVMe *struct {
		Temperature    *int `json:"temperature"`
		PercentageUsed *int `json:"percentage_used"`
		PowerOnHours   *int `json:"power_on_hours"`
	} `json:"nvme_smart_health_information_log"`
	ATA *struct {
		Table []struct {
			ID    int    `json:"id"`
			Name  string `json:"name"`
			Value *int   `json:"value"`
			Raw   struct {
				Value int64 `json:"value"`
			} `json:"raw"`
		} `json:"table"`
	} `json:"ata_smart_attributes"`
}

func runSmartctl(ctx context.Context, bin string, args ...string) (stdout []byte, stderr []byte, exitCode int, err error) {
	child, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	cmd := exec.CommandContext(child, bin, args...)
	var out, errOut cappedBuffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	runErr := cmd.Run()
	if ctx.Err() != nil || child.Err() != nil {
		return nil, nil, -1, context.DeadlineExceeded
	}
	if overflow := out.overflow || errOut.overflow; overflow {
		return nil, nil, -1, errors.New(ReasonFailed)
	}
	if runErr != nil {
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			// smartctl encodes findings in its exit bitmask; the JSON body
			// decides whether it is a usable report.
			return out.buf.Bytes(), errOut.buf.Bytes(), exitErr.ExitCode(), nil
		}
		return nil, nil, -1, runErr
	}
	return out.buf.Bytes(), errOut.buf.Bytes(), 0, nil
}

type cappedBuffer struct {
	buf      bytes.Buffer
	overflow bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.buf.Len()+len(p) > maxOutput {
		b.overflow = true
		return 0, errors.New("output limit exceeded")
	}
	return b.buf.Write(p)
}
