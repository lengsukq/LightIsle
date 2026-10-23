// Package diskmgmt is the shared, minimally privileged macOS drive-management
// backend for both the native parent IPC and authenticated web administrators.
// It never runs a shell, disk formatting, repair, force-unmount or elevation.
package diskmgmt

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/system"
)

var (
	ErrInvalid     = errors.New("invalid_drive_request")
	ErrProtected   = errors.New("drive_in_use_or_protected")
	ErrChanged     = errors.New("drive_identity_changed_refresh_required")
	ErrUnsupported = errors.New("drive_operation_not_supported")
	ErrBusy        = errors.New("drive_operation_busy")
	deviceRule     = regexp.MustCompile("^(disk[0-9]+)s[0-9]+$")
	diskIDRule     = regexp.MustCompile("(?s)<key>DeviceIdentifier</key>\\s*<string>(disk[0-9]+s[0-9]+)</string>")
	labelRule      = regexp.MustCompile("^[^/\\\\\\x00-\\x1f\\x7f:]+$")
)

type Disk struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Mount      string `json:"mount"`
	Parent     string `json:"parent"`
	Filesystem string `json:"filesystem"`
	Protocol   string `json:"protocol"`
	SMART      string `json:"smart"`
	Total      uint64 `json:"total"`
	Free       uint64 `json:"free"`
	ReadOnly   bool   `json:"readOnly"`
	Mounted    bool   `json:"mounted"`
	External   bool   `json:"external"`
	Identity   string `json:"identity"`
}
type Request struct {
	Action   string `json:"action"`
	ID       string `json:"id"`
	Identity string `json:"identity"`
	Name     string `json:"name,omitempty"`
}

type runFunc func(context.Context, ...string) ([]byte, error)
type Manager struct {
	mu    sync.Mutex
	run   runFunc
	guard func(d Disk, action string) error
}

var shared = New()

func Shared() *Manager { return shared }
func New() *Manager    { return &Manager{run: runDiskutil} }
func (m *Manager) SetGuard(fn func(Disk, string) error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.guard = fn
}
func runDiskutil(ctx context.Context, args ...string) ([]byte, error) {
	child, cancel := context.WithTimeout(ctx, 7*time.Second)
	defer cancel()
	cmd := exec.CommandContext(child, "/usr/sbin/diskutil", args...)
	var out limitedOutput
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		if child.Err() != nil {
			return nil, child.Err()
		}
		return nil, fmt.Errorf("diskutil_rejected: %w", err)
	}
	if out.overflow {
		return nil, ErrUnsupported
	}
	return out.buf.Bytes(), nil
}

type limitedOutput struct {
	buf      bytes.Buffer
	overflow bool
}

func (b *limitedOutput) Write(p []byte) (int, error) {
	if b.buf.Len()+len(p) > 256*1024 {
		b.overflow = true
		return 0, ErrUnsupported
	}
	return b.buf.Write(p)
}

// Simple, strict plist leaf reader; only first-level key-value pairs from the
// single-volume diskutil info dictionary are used. Nested arrays are ignored.
func infoFields(raw []byte) (map[string]string, error) {
	if len(raw) == 0 || len(raw) > 256*1024 {
		return nil, ErrInvalid
	}
	dec := xml.NewDecoder(bytes.NewReader(raw))
	fields := map[string]string{}
	var key string
	inKey := false
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, ErrInvalid
		}
		switch v := tok.(type) {
		case xml.StartElement:
			switch v.Name.Local {
			case "key":
				inKey = true
			case "true":
				if key != "" {
					fields[key] = "true"
					key = ""
				}
			case "false":
				if key != "" {
					fields[key] = "false"
					key = ""
				}
			case "string", "integer":
				var value string
				if err := dec.DecodeElement(&value, &v); err != nil {
					return nil, ErrInvalid
				}
				if key != "" {
					fields[key] = value
					key = ""
				}
			}
		case xml.CharData:
			if inKey {
				key = strings.TrimSpace(string(v))
			}
		case xml.EndElement:
			if v.Name.Local == "key" {
				inKey = false
			}
		}
	}
	return fields, nil
}
func truth(v string) bool { return strings.EqualFold(v, "true") }
func details(fields map[string]string) (Disk, error) {
	id := fields["DeviceIdentifier"]
	parts := deviceRule.FindStringSubmatch(id)
	if len(parts) == 0 || fields["Internal"] != "false" || truth(fields["WholeDisk"]) {
		return Disk{}, ErrUnsupported
	}
	// Some current macOS versions omit PartOfWhole from diskutil info -plist
	// even for a valid external partition. The candidate already came from
	// diskutil list external, so the anchored diskXsY identifier supplies the
	// parent; reject a contradictory explicit parent, if supplied.
	parent := fields["PartOfWhole"]
	if parent == "" {
		parent = parts[1]
	}
	if parent != parts[1] {
		return Disk{}, ErrUnsupported
	}
	name := fields["VolumeName"]
	if name == "" {
		return Disk{}, ErrUnsupported
	}
	mount := fields["MountPoint"]
	if mount != "" && (mount == "/" || !strings.HasPrefix(mount, "/Volumes/")) {
		return Disk{}, ErrUnsupported
	}
	stableID := fields["VolumeUUID"]
	if stableID == "" {
		stableID = fields["MediaUUID"]
	}
	if stableID == "" {
		stableID = fields["DiskUUID"]
	}
	// Disk identifiers may be reused after unplug/replug. Without a stable
	// identity, information can still be displayed, but mutations are disabled.
	identity := ""
	if stableID != "" {
		hash := sha256.Sum256([]byte(id + "\x00" + stableID + "\x00" + fields["TotalSize"]))
		identity = hex.EncodeToString(hash[:])
	}
	total, _ := strconv.ParseUint(fields["TotalSize"], 10, 64)
	filesystem := fields["FilesystemName"]
	if filesystem == "" {
		filesystem = fields["FilesystemType"]
	}
	return Disk{ID: id, Parent: parent, Name: name, Mount: mount, Filesystem: filesystem,
		Protocol: fields["BusProtocol"], SMART: fields["SMARTStatus"],
		ReadOnly: truth(fields["ReadOnlyVolume"]), Mounted: mount != "", External: true,
		Total: total, Identity: identity}, nil
}
func (m *Manager) listLocked(ctx context.Context) ([]Disk, error) {
	raw, err := m.run(ctx, "list", "-plist", "external")
	if err != nil {
		return nil, err
	}
	ids := diskIDRule.FindAllSubmatch(raw, 64)
	if len(ids) > 32 {
		return nil, ErrUnsupported
	}
	mounted := map[string]system.Volume{}
	for _, v := range system.Volumes() {
		mounted[v.Mount] = v
	}
	out := make([]Disk, 0, len(ids))
	seen := map[string]bool{}
	for _, match := range ids {
		id := string(match[1])
		if seen[id] {
			continue
		}
		seen[id] = true
		infoRaw, err := m.run(ctx, "info", "-plist", id)
		if err != nil {
			continue
		}
		fields, err := infoFields(infoRaw)
		if err != nil {
			continue
		}
		d, err := details(fields)
		if err != nil {
			continue
		}
		if stat, ok := mounted[d.Mount]; ok && stat.Device != "" {
			d.Total = stat.Total
			d.Free = stat.Free
			d.ReadOnly = stat.ReadOnly
			if d.Filesystem == "" {
				d.Filesystem = stat.Filesystem
			}
		}
		out = append(out, d)
	}
	return out, nil
}
func (m *Manager) List(ctx context.Context) ([]Disk, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.listLocked(ctx)
}
func validName(s string) bool {
	return len(s) > 0 && len([]rune(s)) <= 64 && s == strings.TrimSpace(s) &&
		s != "." && s != ".." && labelRule.MatchString(s)
}
func (m *Manager) Do(ctx context.Context, req Request) ([]Disk, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if req.Action != "rename" && req.Action != "mount" && req.Action != "eject" {
		return nil, ErrInvalid
	}
	if !deviceRule.MatchString(req.ID) || len(req.Identity) != 64 {
		return nil, ErrInvalid
	}
	if req.Action == "rename" && !validName(req.Name) {
		return nil, ErrInvalid
	}
	disks, err := m.listLocked(ctx)
	if err != nil {
		return nil, err
	}
	var selected *Disk
	for i := range disks {
		if disks[i].ID == req.ID {
			selected = &disks[i]
			break
		}
	}
	if selected == nil || selected.Identity == "" || selected.Identity != req.Identity {
		return nil, ErrChanged
	}
	if req.Action == "mount" && selected.Mounted {
		return nil, ErrInvalid
	}
	if (req.Action == "rename" || req.Action == "eject") && !selected.Mounted {
		return nil, ErrInvalid
	}
	// A fresh per-device check immediately before dispatch reduces exposure to
	// stale list snapshots and device identifiers reused after re-plugging.
	fresh, err := m.run(ctx, "info", "-plist", selected.ID)
	if err != nil {
		return nil, ErrChanged
	}
	fields, err := infoFields(fresh)
	if err != nil {
		return nil, ErrChanged
	}
	now, err := details(fields)
	if err != nil || now.Identity != selected.Identity || now.Parent != selected.Parent ||
		now.Mount != selected.Mount {
		return nil, ErrChanged
	}
	if m.guard != nil {
		for _, d := range disks {
			if d.Parent == selected.Parent && req.Action == "eject" || d.ID == selected.ID {
				if err := m.guard(d, req.Action); err != nil {
					return nil, err
				}
			}
		}
	}
	var args []string
	switch req.Action {
	case "rename":
		args = []string{"rename", selected.ID, req.Name}
	case "mount":
		args = []string{"mount", selected.ID}
	case "eject":
		args = []string{"eject", selected.Parent}
	}
	if _, err := m.run(ctx, args...); err != nil {
		return nil, err
	}
	return m.listLocked(ctx)
}
