package smbmgmt

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// DesiredShare persists LightIsle-managed SMB share configurations so that
// when an external volume disconnects (causing macOS smbd/sharingd to drop or
// orphan the export) and later reconnects with verified physical identity,
// LightIsle automatically re-registers the SMB share and its permissions.
type DesiredShare struct {
	RecordName        string                   `json:"recordName"`
	SMBName           string                   `json:"smbName"`
	Path              string                   `json:"path"`
	RootID            string                   `json:"rootId,omitempty"`
	Shared            bool                     `json:"shared"`
	GuestAccess       bool                     `json:"guestAccess"`
	ReadOnly          bool                     `json:"readOnly"`
	Sealed            bool                     `json:"sealed"`
	ConfirmedPersonal bool                     `json:"confirmedPersonal,omitempty"`
	CustomBinding     *storageidentity.Binding `json:"customBinding,omitempty"`
	LastOnline        bool                     `json:"lastOnline"`
	LastDev           uint64                   `json:"lastDev,omitempty"`
}

type persistedShareStore struct {
	Version int            `json:"version"`
	Shares  []DesiredShare `json:"shares"`
}

func (m *Manager) ConfigurePersistence(storePath string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.storePath = strings.TrimSpace(storePath)
	m.loadDesiredLocked()
}

func (m *Manager) SetIdentityProvider(provider storageidentity.Provider) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.identity = provider
}

func (m *Manager) HasManagedShares() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.desired) > 0
}

func (m *Manager) loadDesiredLocked() {
	if m.desired == nil {
		m.desired = make(map[string]DesiredShare)
	}
	if m.storePath == "" {
		return
	}
	raw, err := os.ReadFile(m.storePath)
	if err != nil || len(raw) == 0 {
		return
	}
	var doc persistedShareStore
	if json.Unmarshal(raw, &doc) != nil {
		return
	}
	next := make(map[string]DesiredShare, len(doc.Shares))
	for _, item := range doc.Shares {
		rec := strings.TrimSpace(item.RecordName)
		cleanPath := filepath.Clean(strings.TrimSpace(item.Path))
		if rec == "" || !filepath.IsAbs(cleanPath) {
			continue
		}
		item.RecordName = rec
		item.Path = cleanPath
		if item.SMBName == "" {
			item.SMBName = rec
		}
		next[rec] = item
	}
	m.desired = next
}

func (m *Manager) commitDesired(next map[string]DesiredShare) {
	copied := make(map[string]DesiredShare, len(next))
	for k, v := range next {
		copied[k] = v
	}
	m.mu.Lock()
	m.desired = copied
	storePath := m.storePath
	m.mu.Unlock()
	saveDesiredFile(storePath, copied)
}

func saveDesiredFile(storePath string, desired map[string]DesiredShare) {
	if storePath == "" {
		return
	}
	list := make([]DesiredShare, 0, len(desired))
	for _, item := range desired {
		list = append(list, item)
	}
	sort.Slice(list, func(i, j int) bool {
		return list[i].RecordName < list[j].RecordName
	})
	raw, err := json.MarshalIndent(persistedShareStore{
		Version: 1,
		Shares:  list,
	}, "", "  ")
	if err != nil {
		return
	}
	dir := filepath.Dir(storePath)
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, "smb-shares-*.tmp")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	_, wErr := tmp.Write(raw)
	cErr := tmp.Close()
	if wErr != nil || cErr != nil {
		_ = os.Remove(tmpName)
		return
	}
	_ = os.Chmod(tmpName, 0o600)
	if os.Rename(tmpName, storePath) != nil {
		_ = os.Remove(tmpName)
	}
}

func statDirOnlineAndDev(p string) (bool, uint64) {
	info, err := os.Stat(p)
	if err != nil || !info.IsDir() {
		return false, 0
	}
	if st, ok := info.Sys().(*syscall.Stat_t); ok && st != nil {
		return true, uint64(st.Dev)
	}
	return true, 0
}

func buildDesiredFromShare(ctx context.Context, sp SharePoint, prev DesiredShare, idProvider storageidentity.Provider, confirmedPersonal bool) DesiredShare {
	exists, dev := statDirOnlineAndDev(sp.Path)
	entry := DesiredShare{
		RecordName:        sp.RecordName,
		SMBName:           sp.SMBName,
		Path:              sp.Path,
		RootID:            sp.RootID,
		Shared:            sp.Shared,
		GuestAccess:       sp.GuestAccess,
		ReadOnly:          sp.ReadOnly,
		Sealed:            sp.Sealed,
		ConfirmedPersonal: confirmedPersonal || prev.ConfirmedPersonal || sp.ExposesPersonalDirs,
		CustomBinding:     prev.CustomBinding,
		LastOnline:        exists,
		LastDev:           dev,
	}
	if entry.RootID == "" && exists && (prev.RecordName == "" || entry.CustomBinding == nil || entry.CustomBinding.Path != sp.Path) {
		if b, err := idProvider.Capture(ctx, sp.Path); err == nil {
			entry.CustomBinding = &b
		}
	}
	return entry
}

func findDesiredKeyByRecordOrPath(desired map[string]DesiredShare, recordName, targetPath string) string {
	if _, ok := desired[recordName]; ok {
		return recordName
	}
	for k, v := range desired {
		if strings.EqualFold(k, recordName) || (targetPath != "" && strings.EqualFold(v.Path, targetPath)) {
			return k
		}
	}
	return ""
}

// Reconcile inspects desired LightIsle SMB shares against live macOS SharePoints
// and mounted volumes, automatically restoring shares and permissions whose
// verified physical external drive has reconnected.
func (m *Manager) Reconcile(ctx context.Context, forceMountPrefix string) (Status, int, error) {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	snap := m.snapshotState()
	var roots []RootInfo
	if snap.rootProvider != nil {
		roots = snap.rootProvider()
	}
	return m.reconcileAndCollectWithOpLock(ctx, roots, strings.TrimSpace(forceMountPrefix))
}

func indexLiveShares(liveShares []SharePoint) (map[string]SharePoint, map[string]SharePoint) {
	byRecord := make(map[string]SharePoint, len(liveShares))
	byPathLower := make(map[string]SharePoint, len(liveShares))
	for _, sp := range liveShares {
		byRecord[sp.RecordName] = sp
		byPathLower[strings.ToLower(sp.Path)] = sp
	}
	return byRecord, byPathLower
}

func lookupLiveShare(byRecord, byPathLower map[string]SharePoint, d DesiredShare) (SharePoint, bool) {
	if sp, ok := byRecord[d.RecordName]; ok {
		return sp, true
	}
	sp, ok := byPathLower[strings.ToLower(d.Path)]
	return sp, ok
}

func shareFlagsDrifted(live SharePoint, d DesiredShare) bool {
	return live.Shared != d.Shared ||
		live.GuestAccess != d.GuestAccess ||
		live.ReadOnly != d.ReadOnly ||
		live.Sealed != d.Sealed ||
		live.SMBName != d.SMBName
}

func hydratePreExistingShares(
	ctx context.Context,
	liveShares []SharePoint,
	desired map[string]DesiredShare,
	rootByID map[string]RootInfo,
	idProvider storageidentity.Provider,
) bool {
	dirty := false
	for _, sp := range liveShares {
		if findDesiredKeyByRecordOrPath(desired, sp.RecordName, sp.Path) != "" || !sp.PathExists {
			continue
		}
		if sp.RootID != "" {
			r, ok := rootByID[sp.RootID]
			if !ok || !r.Online {
				continue
			}
			_, dev := statDirOnlineAndDev(sp.Path)
			desired[sp.RecordName] = DesiredShare{
				RecordName:        sp.RecordName,
				SMBName:           sp.SMBName,
				Path:              sp.Path,
				RootID:            sp.RootID,
				Shared:            sp.Shared,
				GuestAccess:       sp.GuestAccess,
				ReadOnly:          sp.ReadOnly,
				Sealed:            sp.Sealed,
				ConfirmedPersonal: sp.ExposesPersonalDirs,
				LastOnline:        true,
				LastDev:           dev,
			}
			dirty = true
			continue
		}
		if !strings.HasPrefix(sp.Path, "/Volumes/") {
			continue
		}
		_, dev := statDirOnlineAndDev(sp.Path)
		var bindingPtr *storageidentity.Binding
		if b, err := idProvider.Capture(ctx, sp.Path); err == nil {
			bindingPtr = &b
		}
		desired[sp.RecordName] = DesiredShare{
			RecordName:        sp.RecordName,
			SMBName:           sp.SMBName,
			Path:              sp.Path,
			Shared:            sp.Shared,
			GuestAccess:       sp.GuestAccess,
			ReadOnly:          sp.ReadOnly,
			Sealed:            sp.Sealed,
			ConfirmedPersonal: sp.ExposesPersonalDirs,
			CustomBinding:     bindingPtr,
			LastOnline:        true,
			LastDev:           dev,
		}
		dirty = true
	}
	return dirty
}

type desiredVerification struct {
	curDev           uint64
	verifiedOnline   bool
	identityMismatch bool
	unregisteredRoot bool
}

func evaluateDesiredShareState(
	ctx context.Context,
	d DesiredShare,
	rootByID map[string]RootInfo,
	hasKnownRoots bool,
	idProvider storageidentity.Provider,
) desiredVerification {
	pathExists, curDev := statDirOnlineAndDev(d.Path)
	res := desiredVerification{curDev: curDev}
	if d.RootID != "" {
		r, rootExists := rootByID[d.RootID]
		if !rootExists && hasKnownRoots {
			res.unregisteredRoot = true
			return res
		}
		if !rootExists {
			res.verifiedOnline = pathExists
			return res
		}
		res.verifiedOnline = r.Online && pathExists
		res.identityMismatch = !r.Online && pathExists
		return res
	}
	if d.CustomBinding != nil {
		if pathExists {
			if idProvider.Verify(ctx, *d.CustomBinding) == nil {
				res.verifiedOnline = true
			} else {
				res.identityMismatch = true
			}
		}
		return res
	}
	res.verifiedOnline = pathExists
	return res
}

func disableLiveShareOnMismatch(ctx context.Context, exec execFunc, live SharePoint, hasLive, remoteReady bool) bool {
	if !hasLive || !live.Shared || !remoteReady {
		return false
	}
	_, _, code, err := exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing", "-e", live.RecordName, "-s", "000")
	return err == nil && code == 0
}

func disableDesiredUnsharedLive(ctx context.Context, exec execFunc, d DesiredShare, live SharePoint, hasLive, remoteReady bool) bool {
	if !hasLive || !live.Shared || !remoteReady {
		return false
	}
	_, _, code, err := exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing",
		"-e", live.RecordName,
		"-S", d.SMBName,
		"-s", "000",
		"-g", boolFlag3(d.GuestAccess),
		"-R", boolFlag1(d.ReadOnly),
		"-E", boolFlag1(d.Sealed),
	)
	return err == nil && code == 0
}

func restoreManagedShare(ctx context.Context, exec execFunc, d DesiredShare, live SharePoint, hasLive bool) bool {
	// If a stale SharePoint record exists in dslocal after an external drive
	// remount, removing and re-adding forces opendirectoryd & smbd to bind
	// to the newly mounted volume's vnode and re-apply all SMB permissions.
	if hasLive {
		_, _, _, _ = exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing", "-r", live.RecordName)
	}
	recName := d.RecordName
	if !shareNameRule.MatchString(recName) {
		recName = d.SMBName
	}
	_, _, code, err := exec(ctx, "/usr/bin/sudo", "-n", "/usr/sbin/sharing",
		"-a", d.Path,
		"-S", d.SMBName,
		"-n", recName,
		"-s", "001",
		"-g", boolFlag3(d.GuestAccess),
		"-R", boolFlag1(d.ReadOnly),
		"-E", boolFlag1(d.Sealed),
	)
	return err == nil && code == 0
}

func reconcileSingleDesiredShare(
	ctx context.Context,
	snap managerStateSnapshot,
	roots []RootInfo,
	rootByID map[string]RootInfo,
	desired map[string]DesiredShare,
	key string,
	live SharePoint,
	hasLive bool,
	forceMountPrefix string,
	remoteReady bool,
	needsRestore map[string]bool,
) (dirty, mutated, restored bool) {
	d := desired[key]
	state := evaluateDesiredShareState(ctx, d, rootByID, len(roots) > 0, snap.identity)

	if state.unregisteredRoot {
		if !hasLive {
			delete(desired, key)
			return true, false, false
		}
		return false, false, false
	}

	// Never leave an SMB share active if a DIFFERENT physical disk was mounted at the same path.
	if state.identityMismatch {
		mutated = disableLiveShareOnMismatch(ctx, snap.exec, live, hasLive, remoteReady)
		if d.LastOnline {
			d.LastOnline = false
			desired[key] = d
			dirty = true
		}
		return dirty, mutated, false
	}

	if !state.verifiedOnline {
		if d.LastOnline {
			d.LastOnline = false
			desired[key] = d
			return true, false, false
		}
		return false, false, false
	}

	if !d.Shared {
		mutated = disableDesiredUnsharedLive(ctx, snap.exec, d, live, hasLive, remoteReady)
		if !d.LastOnline || d.LastDev != state.curDev {
			d.LastOnline = true
			d.LastDev = state.curDev
			desired[key] = d
			dirty = true
		}
		return dirty, mutated, false
	}

	remounted := !d.LastOnline ||
		(d.LastDev != 0 && state.curDev != 0 && d.LastDev != state.curDev) ||
		(forceMountPrefix != "" && pathContains(forceMountPrefix, d.Path))
	flagsDrifted := hasLive && shareFlagsDrifted(live, d)

	if !hasLive || flagsDrifted || remounted {
		if _, vErr := validateSharePath(d.Path, isRegisteredRootPath(d.Path, roots)); vErr != nil {
			return false, false, false
		}
		if aErr := checkShareAccess(d.Path, roots, d.GuestAccess, d.ConfirmedPersonal); aErr != nil {
			return false, false, false
		}
		if !remoteReady {
			needsRestore[d.RecordName] = true
			return false, false, false
		}
		if restoreManagedShare(ctx, snap.exec, d, live, hasLive) {
			d.LastOnline = true
			d.LastDev = state.curDev
			desired[key] = d
			return true, true, true
		}
		needsRestore[d.RecordName] = true
		return false, false, false
	}

	if !d.LastOnline || d.LastDev != state.curDev {
		d.LastOnline = true
		d.LastDev = state.curDev
		desired[key] = d
		return true, false, false
	}
	return false, false, false
}

func (m *Manager) reconcileAndCollectWithOpLock(ctx context.Context, roots []RootInfo, forceMountPrefix string) (Status, int, error) {
	snap := m.snapshotState()
	desired := snap.desired
	if forceMountPrefix != "" {
		forceMountPrefix = filepath.Clean(forceMountPrefix)
	}

	remoteReady := isRemoteManageReady(ctx, snap.exec)
	rawShares, _, _, listErr := snap.exec(ctx, "/usr/sbin/sharing", "-l", "-f", "json")
	liveShares := []SharePoint{}
	if listErr == nil {
		parsed, parseErr := parseSharingJSON(rawShares, roots)
		if parseErr != nil {
			return Status{}, 0, parseErr
		}
		liveShares = parsed
	}

	rootByID := make(map[string]RootInfo, len(roots))
	for _, r := range roots {
		rootByID[r.ID] = r
	}
	liveByRecord, liveByPathLower := indexLiveShares(liveShares)
	dirty := hydratePreExistingShares(ctx, liveShares, desired, rootByID, snap.identity)

	restoredCount := 0
	mutated := false
	needsRestore := make(map[string]bool)

	keys := make([]string, 0, len(desired))
	for k := range desired {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, key := range keys {
		live, hasLive := lookupLiveShare(liveByRecord, liveByPathLower, desired[key])
		stepDirty, stepMutated, stepRestored := reconcileSingleDesiredShare(
			ctx, snap, roots, rootByID, desired, key, live, hasLive, forceMountPrefix, remoteReady, needsRestore,
		)
		dirty = dirty || stepDirty
		mutated = mutated || stepMutated
		if stepRestored {
			restoredCount++
		}
	}

	if dirty {
		m.commitDesired(desired)
	}

	status, err := collectStatusWithRemoteReady(ctx, snap.exec, roots, snap.lanIP, remoteReady, !mutated, liveShares)
	if err != nil {
		return Status{}, restoredCount, err
	}
	status.Shares = mergeDesiredIntoStatusShares(ctx, status.Shares, desired, roots, snap.identity, needsRestore)
	return status, restoredCount, nil
}

// computeReadOnlyNeedsRestore checks which desired shares are verified online
// yet missing or drifted in live macOS shares, without modifying system state.
func computeReadOnlyNeedsRestore(
	ctx context.Context,
	live []SharePoint,
	desired map[string]DesiredShare,
	roots []RootInfo,
	idProvider storageidentity.Provider,
) map[string]bool {
	if len(desired) == 0 {
		return nil
	}
	rootByID := make(map[string]RootInfo, len(roots))
	for _, r := range roots {
		rootByID[r.ID] = r
	}
	liveByRecord, liveByPathLower := indexLiveShares(live)
	needsRestore := make(map[string]bool)
	for _, d := range desired {
		if !d.Shared {
			continue
		}
		pathExists, _ := statDirOnlineAndDev(d.Path)
		verifiedOnline := pathExists
		if d.RootID != "" {
			if r, ok := rootByID[d.RootID]; ok {
				verifiedOnline = r.Online && pathExists
			}
		} else if d.CustomBinding != nil && pathExists && idProvider != nil {
			verifiedOnline = idProvider.Verify(ctx, *d.CustomBinding) == nil
		}
		if !verifiedOnline {
			continue
		}
		sp, hasLive := lookupLiveShare(liveByRecord, liveByPathLower, d)
		if !hasLive {
			needsRestore[d.RecordName] = true
			continue
		}
		if shareFlagsDrifted(sp, d) {
			needsRestore[sp.RecordName] = true
		}
	}
	return needsRestore
}

func mergeDesiredIntoStatusShares(
	ctx context.Context,
	live []SharePoint,
	desired map[string]DesiredShare,
	roots []RootInfo,
	idProvider storageidentity.Provider,
	needsRestore map[string]bool,
) []SharePoint {
	seenRecord := make(map[string]bool, len(live))
	seenPath := make(map[string]bool, len(live))
	merged := make([]SharePoint, 0, len(live)+len(desired))

	for _, sp := range live {
		sp.SyncedInMacOS = true
		if needsRestore[sp.RecordName] {
			sp.NeedsRestore = true
		}
		seenRecord[strings.ToLower(sp.RecordName)] = true
		seenPath[strings.ToLower(sp.Path)] = true
		merged = append(merged, sp)
	}

	for _, d := range desired {
		if seenRecord[strings.ToLower(d.RecordName)] || seenPath[strings.ToLower(d.Path)] {
			continue
		}
		pathExists, _ := statDirOnlineAndDev(d.Path)
		sp := SharePoint{
			RecordName:    d.RecordName,
			SMBName:       d.SMBName,
			Path:          d.Path,
			Shared:        d.Shared,
			GuestAccess:   d.GuestAccess,
			ReadOnly:      d.ReadOnly,
			Sealed:        d.Sealed,
			PathExists:    pathExists,
			SyncedInMacOS: false,
			NeedsRestore:  needsRestore[d.RecordName] || (pathExists && d.Shared),
		}
		matchRootAndPersonalExposure(&sp, roots)
		if sp.RootID == "" && d.RootID != "" {
			sp.RootID = d.RootID
		}
		if sp.RootID != "" {
			for _, r := range roots {
				if r.ID == sp.RootID {
					sp.RootName = r.Name
					if !r.Online {
						sp.PathExists = false
						sp.NeedsRestore = false
					}
					break
				}
			}
		} else if d.CustomBinding != nil && sp.PathExists && idProvider != nil {
			if idProvider.Verify(ctx, *d.CustomBinding) != nil {
				sp.PathExists = false
				sp.NeedsRestore = false
			}
		}
		merged = append(merged, sp)
	}

	sort.Slice(merged, func(i, j int) bool {
		if merged[i].SMBName != merged[j].SMBName {
			return merged[i].SMBName < merged[j].SMBName
		}
		return merged[i].RecordName < merged[j].RecordName
	})
	return merged
}

func boolFlag3(v bool) string {
	if v {
		return "001"
	}
	return "000"
}

func boolFlag1(v bool) string {
	if v {
		return "1"
	}
	return "0"
}
