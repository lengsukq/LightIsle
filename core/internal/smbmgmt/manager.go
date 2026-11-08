// Package smbmgmt provides the unified macOS File Sharing (SMB) inspection and
// control backend for both the native Mac management app and authenticated
// Web/Flutter administrators. All privileged mutations execute through fixed
// argv templates via sudo -n (never a shell) and never delete user files.
package smbmgmt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	smbdLaunchdTarget = "system/com.apple.smbd"
	smbdPlistPath     = "/System/Library/LaunchDaemons/com.apple.smbd.plist"
	sudoersFilePath   = "/etc/sudoers.d/lightisle-smb"
)

var (
	ErrInvalid           = errors.New("invalid_smb_request")
	ErrNotFound          = errors.New("smb_share_not_found")
	ErrAlreadyExists     = errors.New("smb_share_already_exists")
	ErrElevationRequired = errors.New("smb_elevation_required")
	ErrProtectedPath     = errors.New("smb_protected_path_rejected")
	ErrRootOffline       = errors.New("smb_root_offline")
	ErrOperationFailed   = errors.New("smb_operation_failed")

	shareNameRule = regexp.MustCompile(`^[^/\\\x00-\x1f\x7f:]{1,64}$`)
)

type RootInfo struct {
	ID     string
	Name   string
	Path   string
	Online bool
}

type Status struct {
	ServiceEnabled    bool            `json:"serviceEnabled"`
	Listening         bool            `json:"listening"`
	RemoteManageReady bool            `json:"remoteManageReady"`
	ComputerName      string          `json:"computerName"`
	LocalHostName     string          `json:"localHostName"`
	BonjourURL        string          `json:"bonjourUrl,omitempty"`
	LanURL            string          `json:"lanUrl,omitempty"`
	Shares            []SharePoint    `json:"shares"`
	CandidateRoots    []CandidateRoot `json:"candidateRoots"`
}

type SharePoint struct {
	RecordName          string `json:"recordName"`
	SMBName             string `json:"smbName"`
	Path                string `json:"path"`
	Shared              bool   `json:"shared"`
	GuestAccess         bool   `json:"guestAccess"`
	ReadOnly            bool   `json:"readOnly"`
	Sealed              bool   `json:"sealed"`
	RootID              string `json:"rootId,omitempty"`
	RootName            string `json:"rootName,omitempty"`
	ExposesPersonalDirs bool   `json:"exposesPersonalDirs"`
	PathExists          bool   `json:"pathExists"`
}

type CandidateRoot struct {
	RootID         string   `json:"rootId"`
	Name           string   `json:"name"`
	Path           string   `json:"path"`
	Online         bool     `json:"online"`
	Subdirectories []string `json:"subdirectories"`
}

type AddRequest struct {
	RootID      string `json:"rootId,omitempty"`
	Subpath     string `json:"subpath,omitempty"`
	Path        string `json:"path,omitempty"`
	SMBName     string `json:"smbName"`
	GuestAccess bool   `json:"guestAccess"`
	ReadOnly    bool   `json:"readOnly"`
	Sealed      bool   `json:"sealed"`
}

type UpdateRequest struct {
	SMBName     string `json:"smbName"`
	Shared      bool   `json:"shared"`
	GuestAccess bool   `json:"guestAccess"`
	ReadOnly    bool   `json:"readOnly"`
	Sealed      bool   `json:"sealed"`
}

type execFunc func(ctx context.Context, binary string, args ...string) ([]byte, []byte, int, error)

type Manager struct {
	mu           sync.Mutex
	exec         execFunc
	rootProvider func() []RootInfo
	lanIP        func() string
}

var shared = New()

func Shared() *Manager { return shared }

func New() *Manager {
	return &Manager{
		exec:  runCommand,
		lanIP: detectPrivateLANIPv4,
	}
}

func (m *Manager) SetRootProvider(fn func() []RootInfo) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rootProvider = fn
}

// ServiceEnabledQuick performs a fast, non-waking check of whether macOS
// com.apple.smbd is loaded in launchd, avoiding TCP connects to port 445 that
// would spawn smbd on every poll.
func (m *Manager) ServiceEnabledQuick(ctx context.Context) bool {
	m.mu.Lock()
	execFn := m.exec
	m.mu.Unlock()
	return isServiceEnabled(ctx, execFn)
}

func isServiceEnabled(ctx context.Context, execFn execFunc) bool {
	_, _, code, err := execFn(ctx, "/bin/launchctl", "print", smbdLaunchdTarget)
	if err == nil && code == 0 {
		return true
	}
	out, _, dCode, dErr := execFn(ctx, "/bin/launchctl", "print-disabled", "system")
	if dErr == nil && dCode == 0 && strings.Contains(string(out), `"com.apple.smbd" => enabled`) {
		return true
	}
	return false
}

func (m *Manager) Status(ctx context.Context) (Status, error) {
	m.mu.Lock()
	execFn := m.exec
	provider := m.rootProvider
	lanIPFn := m.lanIP
	m.mu.Unlock()

	var roots []RootInfo
	if provider != nil {
		roots = provider()
	}
	return collectStatus(ctx, execFn, roots, lanIPFn)
}

func collectStatus(ctx context.Context, execFn execFunc, roots []RootInfo, lanIPFn func() string) (Status, error) {
	enabled := isServiceEnabled(ctx, execFn)
	remoteReady := isRemoteManageReady(ctx, execFn)
	compName := readScutil(ctx, execFn, "ComputerName")
	localHost := readScutil(ctx, execFn, "LocalHostName")

	var bonjourURL string
	if localHost != "" {
		bonjourURL = "smb://" + localHost + ".local"
	}
	var lanURL string
	if lanIPFn != nil {
		if ip := lanIPFn(); ip != "" {
			lanURL = "smb://" + ip
		}
	}

	rawShares, _, _, err := execFn(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
	var shares []SharePoint
	if err == nil {
		parsed, parseErr := parseSharingJSON(rawShares, roots)
		if parseErr != nil {
			return Status{}, parseErr
		}
		shares = parsed
	} else {
		shares = []SharePoint{}
	}

	candidates := buildCandidateRoots(roots)

	return Status{
		ServiceEnabled:    enabled,
		Listening:         enabled,
		RemoteManageReady: remoteReady,
		ComputerName:      compName,
		LocalHostName:     localHost,
		BonjourURL:        bonjourURL,
		LanURL:            lanURL,
		Shares:            shares,
		CandidateRoots:    candidates,
	}, nil
}

func isRemoteManageReady(ctx context.Context, execFn execFunc) bool {
	if _, err := os.Stat(sudoersFilePath); err == nil {
		return true
	}
	_, _, code, err := execFn(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing", "-l")
	return err == nil && code == 0
}

func readScutil(ctx context.Context, execFn execFunc, key string) string {
	out, _, code, err := execFn(ctx, "/usr/sbin/scutil", "--get", key)
	if err != nil || code != 0 {
		return ""
	}
	return strings.TrimSpace(string(out))
}

type rawShareEntry struct {
	Path        string `json:"path"`
	GuestAccess int    `json:"smb_guest_access"`
	SMBName     string `json:"smb_name"`
	ReadOnly    int    `json:"smb_read_only"`
	Sealed      int    `json:"smb_sealed"`
	Shared      int    `json:"smb_shared"`
}

func parseSharingJSON(raw []byte, roots []RootInfo) ([]SharePoint, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return []SharePoint{}, nil
	}
	var decoded map[string]rawShareEntry
	if err := json.Unmarshal(trimmed, &decoded); err != nil {
		return nil, ErrOperationFailed
	}
	result := make([]SharePoint, 0, len(decoded))
	for recordName, item := range decoded {
		cleanPath := filepath.Clean(item.Path)
		smbName := item.SMBName
		if smbName == "" {
			smbName = recordName
		}
		sp := SharePoint{
			RecordName:  recordName,
			SMBName:     smbName,
			Path:        cleanPath,
			Shared:      item.Shared != 0,
			GuestAccess: item.GuestAccess != 0,
			ReadOnly:    item.ReadOnly != 0,
			Sealed:      item.Sealed != 0,
		}
		if info, err := os.Stat(cleanPath); err == nil && info.IsDir() {
			sp.PathExists = true
		}
		matchRootAndPersonalExposure(&sp, roots)
		result = append(result, sp)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].SMBName != result[j].SMBName {
			return result[i].SMBName < result[j].SMBName
		}
		return result[i].RecordName < result[j].RecordName
	})
	return result, nil
}

func matchRootAndPersonalExposure(sp *SharePoint, roots []RootInfo) {
	for _, r := range roots {
		rootClean := filepath.Clean(r.Path)
		if rootClean == "" || rootClean == "." {
			continue
		}
		if sp.Path == rootClean || strings.HasPrefix(sp.Path, rootClean+string(os.PathSeparator)) {
			sp.RootID = r.ID
			sp.RootName = r.Name
			usersDir := filepath.Join(rootClean, "Users")
			if sp.Path == rootClean || sp.Path == usersDir || strings.HasPrefix(sp.Path, usersDir+string(os.PathSeparator)) {
				sp.ExposesPersonalDirs = true
			}
			break
		}
	}
	if !sp.ExposesPersonalDirs {
		if filepath.Base(sp.Path) == "Users" {
			sp.ExposesPersonalDirs = true
		} else if info, err := os.Stat(filepath.Join(sp.Path, "Users")); err == nil && info.IsDir() {
			sp.ExposesPersonalDirs = true
		}
	}
}

func buildCandidateRoots(roots []RootInfo) []CandidateRoot {
	candidates := make([]CandidateRoot, 0, len(roots))
	for _, r := range roots {
		clean := filepath.Clean(r.Path)
		subs := []string{}
		if r.Online {
			if entries, err := os.ReadDir(clean); err == nil {
				for _, entry := range entries {
					name := entry.Name()
					if strings.HasPrefix(name, ".") {
						continue
					}
					if entry.Type()&os.ModeSymlink != 0 || !entry.IsDir() {
						continue
					}
					subs = append(subs, name)
					if len(subs) >= 64 {
						break
					}
				}
				sort.Strings(subs)
			}
		}
		candidates = append(candidates, CandidateRoot{
			RootID:         r.ID,
			Name:           r.Name,
			Path:           clean,
			Online:         r.Online,
			Subdirectories: subs,
		})
	}
	return candidates
}

func (m *Manager) SetService(ctx context.Context, enabled bool) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	subcmd := "unload"
	if enabled {
		subcmd = "load"
	}
	_, stderr, code, err := m.exec(ctx, "/usr/bin/sudo", "-n", "/bin/launchctl", subcmd, "-w", smbdPlistPath)
	if err != nil || code != 0 {
		if isSudoPasswordError(stderr, code) {
			return Status{}, ErrElevationRequired
		}
		// launchctl load -w may return non-zero if already loaded; check actual state.
		if isServiceEnabled(ctx, m.exec) != enabled {
			return Status{}, ErrOperationFailed
		}
	}
	var roots []RootInfo
	if m.rootProvider != nil {
		roots = m.rootProvider()
	}
	return collectStatus(ctx, m.exec, roots, m.lanIP)
}

func (m *Manager) AddShare(ctx context.Context, req AddRequest) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var roots []RootInfo
	if m.rootProvider != nil {
		roots = m.rootProvider()
	}

	targetPath, err := resolveAndValidateTargetPath(req, roots)
	if err != nil {
		return Status{}, err
	}

	smbName := strings.TrimSpace(req.SMBName)
	if smbName == "" {
		smbName = filepath.Base(targetPath)
	}
	if !shareNameRule.MatchString(smbName) {
		return Status{}, ErrInvalid
	}

	rawShares, _, _, listErr := m.exec(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
	if listErr == nil {
		existing, parseErr := parseSharingJSON(rawShares, roots)
		if parseErr == nil {
			for _, s := range existing {
				if s.Path == targetPath || strings.EqualFold(s.SMBName, smbName) || strings.EqualFold(s.RecordName, smbName) {
					return Status{}, ErrAlreadyExists
				}
			}
		}
	}

	guestFlag := "000"
	if req.GuestAccess {
		guestFlag = "001"
	}
	roFlag := "0"
	if req.ReadOnly {
		roFlag = "1"
	}
	sealFlag := "0"
	if req.Sealed {
		sealFlag = "1"
	}

	_, stderr, code, err := m.exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing",
		"-a", targetPath,
		"-S", smbName,
		"-n", smbName,
		"-s", "001",
		"-g", guestFlag,
		"-R", roFlag,
		"-E", sealFlag,
	)
	if err != nil || code != 0 {
		if isSudoPasswordError(stderr, code) {
			return Status{}, ErrElevationRequired
		}
		return Status{}, ErrOperationFailed
	}

	return collectStatus(ctx, m.exec, roots, m.lanIP)
}

func (m *Manager) UpdateShare(ctx context.Context, recordName string, req UpdateRequest) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	recordName = strings.TrimSpace(recordName)
	if recordName == "" || !shareNameRule.MatchString(recordName) {
		return Status{}, ErrInvalid
	}

	var roots []RootInfo
	if m.rootProvider != nil {
		roots = m.rootProvider()
	}

	rawShares, _, _, listErr := m.exec(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
	if listErr != nil {
		return Status{}, ErrOperationFailed
	}
	existing, parseErr := parseSharingJSON(rawShares, roots)
	if parseErr != nil {
		return Status{}, parseErr
	}
	var found *SharePoint
	for i := range existing {
		if existing[i].RecordName == recordName {
			found = &existing[i]
			break
		}
	}
	if found == nil {
		return Status{}, ErrNotFound
	}
	if containsInternalSegment(found.Path) {
		return Status{}, ErrProtectedPath
	}

	smbName := strings.TrimSpace(req.SMBName)
	if smbName == "" {
		smbName = found.SMBName
	}
	if !shareNameRule.MatchString(smbName) {
		return Status{}, ErrInvalid
	}

	shareFlag := "000"
	if req.Shared {
		shareFlag = "001"
	}
	guestFlag := "000"
	if req.GuestAccess {
		guestFlag = "001"
	}
	roFlag := "0"
	if req.ReadOnly {
		roFlag = "1"
	}
	sealFlag := "0"
	if req.Sealed {
		sealFlag = "1"
	}

	_, stderr, code, err := m.exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing",
		"-e", recordName,
		"-S", smbName,
		"-s", shareFlag,
		"-g", guestFlag,
		"-R", roFlag,
		"-E", sealFlag,
	)
	if err != nil || code != 0 {
		if isSudoPasswordError(stderr, code) {
			return Status{}, ErrElevationRequired
		}
		return Status{}, ErrOperationFailed
	}

	return collectStatus(ctx, m.exec, roots, m.lanIP)
}

func (m *Manager) RemoveShare(ctx context.Context, recordName string) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	recordName = strings.TrimSpace(recordName)
	if recordName == "" || !shareNameRule.MatchString(recordName) {
		return Status{}, ErrInvalid
	}

	var roots []RootInfo
	if m.rootProvider != nil {
		roots = m.rootProvider()
	}

	rawShares, _, _, listErr := m.exec(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
	if listErr != nil {
		return Status{}, ErrOperationFailed
	}
	existing, parseErr := parseSharingJSON(rawShares, roots)
	if parseErr != nil {
		return Status{}, parseErr
	}
	found := false
	for _, item := range existing {
		if item.RecordName == recordName {
			found = true
			break
		}
	}
	if !found {
		return Status{}, ErrNotFound
	}

	_, stderr, code, err := m.exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing", "-r", recordName)
	if err != nil || code != 0 {
		if isSudoPasswordError(stderr, code) {
			return Status{}, ErrElevationRequired
		}
		return Status{}, ErrOperationFailed
	}

	return collectStatus(ctx, m.exec, roots, m.lanIP)
}

func resolveAndValidateTargetPath(req AddRequest, roots []RootInfo) (string, error) {
	var candidate string
	if strings.TrimSpace(req.RootID) != "" {
		if strings.TrimSpace(req.Path) != "" {
			return "", ErrInvalid
		}
		var matched *RootInfo
		for i := range roots {
			if roots[i].ID == req.RootID {
				matched = &roots[i]
				break
			}
		}
		if matched == nil {
			return "", ErrInvalid
		}
		if !matched.Online {
			return "", ErrRootOffline
		}
		baseClean := filepath.Clean(matched.Path)
		sub := strings.TrimSpace(req.Subpath)
		if sub == "" || sub == "." || sub == "/" {
			candidate = baseClean
		} else {
			if filepath.IsAbs(sub) {
				return "", ErrInvalid
			}
			cleanSub := filepath.Clean(sub)
			if cleanSub == "." || cleanSub == ".." || strings.HasPrefix(cleanSub, ".."+string(os.PathSeparator)) {
				return "", ErrInvalid
			}
			for _, seg := range strings.Split(cleanSub, string(os.PathSeparator)) {
				if seg == "" || seg == "." || seg == ".." {
					return "", ErrInvalid
				}
				if strings.HasPrefix(seg, ".") {
					return "", ErrProtectedPath
				}
			}
			candidate = filepath.Join(baseClean, cleanSub)
		}
	} else if strings.TrimSpace(req.Path) != "" {
		candidate = filepath.Clean(strings.TrimSpace(req.Path))
	} else {
		return "", ErrInvalid
	}

	return validateSharePath(candidate)
}

func validateSharePath(candidate string) (string, error) {
	if !filepath.IsAbs(candidate) || filepath.Clean(candidate) != candidate {
		return "", ErrInvalid
	}
	if containsInternalSegment(candidate) {
		return "", ErrProtectedPath
	}
	// Reject top-level system directories or bare volume roots.
	forbiddenExact := map[string]bool{
		"/": true, "/Volumes": true, "/System": true, "/Library": true,
		"/Users": true, "/private": true, "/bin": true, "/sbin": true,
		"/usr": true, "/etc": true, "/var": true, "/dev": true, "/tmp": true,
	}
	if forbiddenExact[candidate] {
		return "", ErrProtectedPath
	}
	for _, sysPrefix := range []string{"/System/", "/bin/", "/sbin/", "/usr/", "/etc/", "/dev/"} {
		if strings.HasPrefix(candidate, sysPrefix) {
			return "", ErrProtectedPath
		}
	}
	if strings.HasPrefix(candidate, "/Volumes/") {
		rest := strings.TrimPrefix(candidate, "/Volumes/")
		if !strings.Contains(rest, "/") {
			// Bare external volume mount point (/Volumes/<Disk>) is rejected;
			// require a dedicated folder on the volume.
			return "", ErrProtectedPath
		}
	}

	lstat, err := os.Lstat(candidate)
	if err != nil {
		return "", ErrInvalid
	}
	if lstat.Mode()&os.ModeSymlink != 0 || !lstat.IsDir() {
		return "", ErrProtectedPath
	}
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", ErrInvalid
	}
	// Allow macOS /var -> /private/var firmlink in temp tests only if the
	// non-private suffix matches and no user segment is a symlink.
	if resolved != candidate && resolved != "/private"+candidate {
		return "", ErrProtectedPath
	}
	return candidate, nil
}

func containsInternalSegment(p string) bool {
	for _, seg := range strings.Split(filepath.Clean(p), string(os.PathSeparator)) {
		lower := strings.ToLower(seg)
		if strings.HasPrefix(lower, ".lightisle") || lower == ".trash" || lower == ".trashes" {
			return true
		}
	}
	return false
}

func isSudoPasswordError(stderr []byte, code int) bool {
	if code == 0 {
		return false
	}
	msg := strings.ToLower(string(stderr))
	return strings.Contains(msg, "password is required") ||
		strings.Contains(msg, "no tty present") ||
		strings.Contains(msg, "must be run as root") ||
		strings.Contains(msg, "not allowed to execute")
}

func detectPrivateLANIPv4() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		if !(strings.HasPrefix(iface.Name, "en") || strings.HasPrefix(iface.Name, "bridge")) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ip, _, parseErr := net.ParseCIDR(addr.String())
			if parseErr != nil || ip == nil {
				continue
			}
			ip4 := ip.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() || !ip4.IsPrivate() {
				continue
			}
			return ip4.String()
		}
	}
	return ""
}

func runCommand(ctx context.Context, binary string, args ...string) ([]byte, []byte, int, error) {
	child, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(child, binary, args...)
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"}
	var stdout, stderr limitedBuffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if child.Err() != nil {
		return nil, nil, -1, child.Err()
	}
	if stdout.overflow || stderr.overflow {
		return nil, nil, -1, ErrOperationFailed
	}
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return stdout.buf.Bytes(), stderr.buf.Bytes(), exitErr.ExitCode(), exitErr
		}
		return stdout.buf.Bytes(), stderr.buf.Bytes(), -1, err
	}
	return stdout.buf.Bytes(), stderr.buf.Bytes(), 0, nil
}

type limitedBuffer struct {
	buf      bytes.Buffer
	overflow bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.buf.Len()+len(p) > 256*1024 {
		b.overflow = true
		return 0, io.ErrShortBuffer
	}
	return b.buf.Write(p)
}
