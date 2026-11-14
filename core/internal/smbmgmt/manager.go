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
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

const (
	smbdLaunchdTarget = "system/com.apple.smbd"
	smbdPlistPath     = "/System/Library/LaunchDaemons/com.apple.smbd.plist"
)

var (
	ErrInvalid           = errors.New("invalid_smb_request")
	ErrNotFound          = errors.New("smb_share_not_found")
	ErrAlreadyExists     = errors.New("smb_share_already_exists")
	ErrElevationRequired = errors.New("smb_elevation_required")
	ErrProtectedPath     = errors.New("smb_protected_path_rejected")
	ErrVolumeRoot        = errors.New("smb_volume_root_rejected")
	ErrUnmanagedShare    = errors.New("smb_unmanaged_share_rejected")
	ErrRootOffline       = errors.New("smb_root_offline")
	ErrPersonalGuest     = errors.New("smb_personal_guest_forbidden")
	ErrLocalConfirmation = errors.New("smb_personal_confirmation_required")
	ErrOperationFailed   = errors.New("smb_operation_failed")

	shareNameRule = regexp.MustCompile(`^[^-/\\\x00-\x1f\x7f:][^/\\\x00-\x1f\x7f:]{0,63}$`)
)

type RootInfo struct {
	ID     string
	Name   string
	Path   string
	Online bool
}

// Checking launchd alone does not prove port 445 is accepting connections.
// Inspect existing listeners without opening a connection (which would wake
// an on-demand smbd). Socket activation and restricted lsof access mean a
// missing visible listener is UNKNOWN, not proof of a networking failure.
func detectSMBListening(ctx context.Context, execFn execFunc, enabled bool) (bool, string) {
	if !enabled {
		return false, "disabled"
	}
	out, _, code, err := execFn(ctx, "/usr/sbin/lsof", "-nP", "-iTCP:445", "-sTCP:LISTEN")
	if err != nil || code != 0 {
		return false, "unknown"
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		// Port 445 belonging to an unrelated process does not prove macOS SMB
		// availability. launchd may own the socket on a demand-started system.
		if len(fields) > 1 && (fields[0] == "smbd" || fields[0] == "launchd") &&
			strings.Contains(line, ":445") && strings.Contains(line, "(LISTEN)") {
			return true, "listening"
		}
	}
	return false, "unknown"
}

type Status struct {
	ServiceEnabled    bool            `json:"serviceEnabled"`
	Listening         bool            `json:"listening"`
	ListeningState    string          `json:"listeningState"` // listening, unknown, disabled
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
	RootID            string `json:"rootId,omitempty"`
	Subpath           string `json:"subpath,omitempty"`
	Path              string `json:"path,omitempty"`
	SMBName           string `json:"smbName"`
	GuestAccess       bool   `json:"guestAccess"`
	ReadOnly          bool   `json:"readOnly"`
	Sealed            bool   `json:"sealed"`
	LocalConfirmation bool   `json:"-"`
	AllowCustomPath   bool   `json:"-"`
}

type UpdateRequest struct {
	SMBName           string `json:"smbName"`
	Shared            bool   `json:"shared"`
	GuestAccess       bool   `json:"guestAccess"`
	ReadOnly          bool   `json:"readOnly"`
	Sealed            bool   `json:"sealed"`
	LocalConfirmation bool   `json:"-"`
	AllowUnmanaged    bool   `json:"-"`
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
	listening, listeningState := detectSMBListening(ctx, execFn, enabled)
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
		Listening:         listening,
		ListeningState:    listeningState,
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
		if pathContains(rootClean, sp.Path) {
			sp.RootID = r.ID
			sp.RootName = r.Name
		}
		usersDir := filepath.Join(rootClean, "Users")
		if pathContains(sp.Path, usersDir) || pathContains(usersDir, sp.Path) {
			sp.ExposesPersonalDirs = true
		}
	}
	if !sp.ExposesPersonalDirs {
		if strings.EqualFold(filepath.Base(sp.Path), "Users") {
			sp.ExposesPersonalDirs = true
		} else if info, err := os.Stat(filepath.Join(sp.Path, "Users")); err == nil && info.IsDir() {
			sp.ExposesPersonalDirs = true
		}
	}
}

func pathContains(parent, child string) bool {
	parent, child = strings.ToLower(parent), strings.ToLower(child)
	return child == parent || strings.HasPrefix(child, strings.TrimRight(parent, "/")+"/")
}

func checkShareAccess(target string, roots []RootInfo, guest, localConfirmation bool) error {
	for _, root := range roots {
		if !root.Online && pathContains(filepath.Clean(root.Path), target) {
			return ErrRootOffline
		}
	}
	share := SharePoint{Path: target}
	matchRootAndPersonalExposure(&share, roots)
	if share.ExposesPersonalDirs {
		if guest {
			return ErrPersonalGuest
		}
		if !localConfirmation {
			return ErrLocalConfirmation
		}
	}
	return nil
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

	var roots []RootInfo
	if m.rootProvider != nil {
		roots = m.rootProvider()
	}
	subcmd := "unload"
	if enabled {
		raw, _, code, err := m.exec(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
		if err != nil || code != 0 {
			return Status{}, ErrOperationFailed
		}
		shares, err := parseSharingJSON(raw, roots)
		if err != nil {
			return Status{}, err
		}
		for _, share := range shares {
			if !share.Shared {
				continue
			}
			if err := checkShareAccess(share.Path, roots, share.GuestAccess, true); err != nil && !errors.Is(err, ErrRootOffline) {
				return Status{}, err
			}
		}
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
	if err := checkShareAccess(targetPath, roots, req.GuestAccess, req.LocalConfirmation); err != nil {
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
				if strings.EqualFold(s.Path, targetPath) || strings.EqualFold(s.SMBName, smbName) || strings.EqualFold(s.RecordName, smbName) {
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
	if !req.AllowUnmanaged && len(roots) > 0 && found.RootID == "" {
		return Status{}, ErrUnmanagedShare
	}
	if containsInternalSegment(found.Path) {
		return Status{}, ErrProtectedPath
	}
	if req.Shared {
		if _, err := validateSharePath(found.Path, isRegisteredRootPath(found.Path, roots)); err != nil {
			return Status{}, err
		}
		if err := checkShareAccess(found.Path, roots, req.GuestAccess, req.LocalConfirmation); err != nil {
			return Status{}, err
		}
	} else if found.ExposesPersonalDirs {
		// Disabling an older share must remain available even if it used guests.
		req.GuestAccess = false
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
	return m.removeShare(ctx, recordName, false)
}

// RemoveShareLocal removes an SMB share on behalf of the local Mac desktop app,
// including pre-existing or custom-folder shares outside LightIsle's RootRegistry.
func (m *Manager) RemoveShareLocal(ctx context.Context, recordName string) (Status, error) {
	return m.removeShare(ctx, recordName, true)
}

func (m *Manager) removeShare(ctx context.Context, recordName string, allowUnmanaged bool) (Status, error) {
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
	if !allowUnmanaged && len(roots) > 0 && found.RootID == "" {
		return Status{}, ErrUnmanagedShare
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
