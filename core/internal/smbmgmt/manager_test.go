package smbmgmt

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type fakeSMBSystem struct {
	serviceLoaded bool
	portListening bool
	sudoReady     bool
	computerName  string
	localHostName string
	shares        map[string]rawShareEntry
	lastCalls     [][]string
}

func newFakeSMBSystem() *fakeSMBSystem {
	return &fakeSMBSystem{
		serviceLoaded: true,
		sudoReady:     true,
		computerName:  "Family Mac mini",
		localHostName: "Family-Mac-mini",
		shares:        map[string]rawShareEntry{},
	}
}

func (f *fakeSMBSystem) exec(_ context.Context, binary string, args ...string) ([]byte, []byte, int, error) {
	call := append([]string{binary}, args...)
	f.lastCalls = append(f.lastCalls, call)
	if binary == "/usr/sbin/lsof" {
		if f.portListening {
			return []byte("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nsmbd 42 root 4u IPv4 123 0t0 TCP *:445 (LISTEN)\n"), nil, 0, nil
		}
		return nil, nil, 1, errors.New("no matching listener")
	}

	if binary == "/bin/launchctl" {
		if len(args) >= 2 && args[0] == "print" && args[1] == smbdLaunchdTarget {
			if f.serviceLoaded {
				return []byte("system/com.apple.smbd = {}"), nil, 0, nil
			}
			return nil, []byte("Could not find service"), 113, errors.New("exit 113")
		}
		if len(args) >= 2 && args[0] == "print-disabled" {
			if f.serviceLoaded {
				return []byte(`"com.apple.smbd" => enabled`), nil, 0, nil
			}
			return []byte(`"com.apple.smbd" => disabled`), nil, 0, nil
		}
	}

	if binary == "/usr/sbin/scutil" && len(args) == 2 && args[0] == "--get" {
		switch args[1] {
		case "ComputerName":
			return []byte(f.computerName + "\n"), nil, 0, nil
		case "LocalHostName":
			return []byte(f.localHostName + "\n"), nil, 0, nil
		}
	}

	if binary == "/usr/sbin/sharing" && slices.Equal(args, []string{"-l", "-f", "json"}) {
		raw, _ := json.Marshal(f.shares)
		return raw, nil, 0, nil
	}

	if binary == "/usr/bin/sudo" && len(args) >= 2 && args[0] == "-n" {
		if !f.sudoReady {
			return nil, []byte("sudo: a password is required\n"), 1, errors.New("exit 1")
		}
		subBin := args[1]
		subArgs := args[2:]
		if subBin == "/usr/sbin/sharing" {
			if slices.Equal(subArgs, []string{"-l"}) {
				return []byte("ok"), nil, 0, nil
			}
			return f.handleSharingMutation(subArgs)
		}
		if subBin == "/bin/launchctl" && len(subArgs) == 3 && subArgs[1] == "-w" && subArgs[2] == smbdPlistPath {
			switch subArgs[0] {
			case "load":
				f.serviceLoaded = true
				return nil, nil, 0, nil
			case "unload":
				f.serviceLoaded = false
				return nil, nil, 0, nil
			}
		}
	}

	return nil, []byte("unsupported command"), 1, errors.New("unsupported")
}

func (f *fakeSMBSystem) handleSharingMutation(args []string) ([]byte, []byte, int, error) {
	if len(args) >= 2 && args[0] == "-r" {
		delete(f.shares, args[1])
		return nil, nil, 0, nil
	}
	if len(args) >= 2 && (args[0] == "-a" || args[0] == "-e") {
		isAdd := args[0] == "-a"
		target := args[1]
		var entry rawShareEntry
		recordName := target
		if isAdd {
			recordName = filepath.Base(target)
			entry.Path = target
			entry.Shared = 1
		} else {
			existing, ok := f.shares[recordName]
			if !ok {
				return nil, []byte("share not found"), 1, errors.New("not found")
			}
			entry = existing
		}
		for i := 2; i+1 < len(args); i += 2 {
			flag, val := args[i], args[i+1]
			switch flag {
			case "-S":
				entry.SMBName = val
			case "-n":
				if isAdd {
					recordName = val
				}
			case "-s":
				if val == "001" {
					entry.Shared = 1
				} else {
					entry.Shared = 0
				}
			case "-g":
				if val == "001" {
					entry.GuestAccess = 1
				} else {
					entry.GuestAccess = 0
				}
			case "-R":
				if val == "1" {
					entry.ReadOnly = 1
				} else {
					entry.ReadOnly = 0
				}
			case "-E":
				if val == "1" {
					entry.Sealed = 1
				} else {
					entry.Sealed = 0
				}
			}
		}
		if entry.SMBName == "" {
			entry.SMBName = recordName
		}
		f.shares[recordName] = entry
		return nil, nil, 0, nil
	}
	return nil, []byte("invalid sharing args"), 1, errors.New("invalid")
}

func TestStatusAndShareLifecycle(t *testing.T) {
	tmp := t.TempDir()
	realTmp, err := filepath.EvalSymlinks(tmp)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	rootDir := filepath.Join(realTmp, "nas-root")
	moviesDir := filepath.Join(rootDir, "Movies")
	usersDir := filepath.Join(rootDir, "Users")
	trashDir := filepath.Join(rootDir, ".lightisle-trash")
	for _, d := range []string{moviesDir, usersDir, trashDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("MkdirAll %s: %v", d, err)
		}
	}
	symlinkDir := filepath.Join(rootDir, "LinkedMovies")
	if err := os.Symlink(moviesDir, symlinkDir); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	fake := newFakeSMBSystem()
	mgr := &Manager{
		exec:  fake.exec,
		lanIP: func() string { return "192.168.1.88" },
		rootProvider: func() []RootInfo {
			return []RootInfo{
				{ID: "root-main", Name: "主存储盘", Path: rootDir, Online: true},
				{ID: "root-offline", Name: "离线盘", Path: filepath.Join(realTmp, "offline"), Online: false},
			}
		},
	}

	ctx := context.Background()
	st, err := mgr.Status(ctx)
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if !st.ServiceEnabled || st.BonjourURL != "smb://Family-Mac-mini.local" || st.LanURL != "smb://192.168.1.88" {
		t.Fatalf("unexpected initial status: %+v", st)
	}
	if st.Listening || st.ListeningState != "unknown" {
		t.Fatalf("loaded on-demand smbd must not imply a confirmed TCP listener: %+v", st)
	}
	fake.portListening = true
	st, err = mgr.Status(ctx)
	if err != nil || !st.Listening || st.ListeningState != "listening" {
		t.Fatalf("actual listener not recognized: %+v %v", st, err)
	}
	fake.portListening = false
	if ok, state := detectSMBListening(ctx, func(context.Context, string, ...string) ([]byte, []byte, int, error) {
		return []byte("other 444 user 3u IPv4 1 0t0 TCP *:445 (LISTEN)"), nil, 0, nil
	}, true); ok || state != "unknown" {
		t.Fatalf("unrelated program on port 445 must not masquerade as SMB: %v %s", ok, state)
	}
	if len(st.CandidateRoots) != 2 {
		t.Fatalf("expected 2 candidate roots, got %d", len(st.CandidateRoots))
	}
	// Candidate subdirectories must include Movies and Users, but exclude .lightisle-trash and symlinks.
	if !slices.Equal(st.CandidateRoots[0].Subdirectories, []string{"Movies", "Users"}) {
		t.Fatalf("unexpected subdirectories: %v", st.CandidateRoots[0].Subdirectories)
	}

	// 1. Add a normal subdirectory share (Movies) -> ExposesPersonalDirs must be false.
	st, err = mgr.AddShare(ctx, AddRequest{
		RootID:      "root-main",
		Subpath:     "Movies",
		SMBName:     "家庭影院",
		GuestAccess: true,
		ReadOnly:    true,
	})
	if err != nil {
		t.Fatalf("AddShare Movies: %v", err)
	}
	if len(st.Shares) != 1 {
		t.Fatalf("expected 1 share, got %d", len(st.Shares))
	}
	movieShare := st.Shares[0]
	if movieShare.SMBName != "家庭影院" || !movieShare.GuestAccess || !movieShare.ReadOnly || movieShare.ExposesPersonalDirs || movieShare.RootID != "root-main" {
		t.Fatalf("unexpected movieShare: %+v", movieShare)
	}

	// 2. Adding duplicate share must fail with ErrAlreadyExists.
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-main", Subpath: "Movies", SMBName: "OtherName"}); !errors.Is(err, ErrAlreadyExists) {
		t.Fatalf("expected ErrAlreadyExists for same path, got %v", err)
	}

	// 3. A private root requires native confirmation and cannot allow guests.
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-main"}); !errors.Is(err, ErrLocalConfirmation) {
		t.Fatalf("remote whole-root sharing accepted: %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-main", LocalConfirmation: true, GuestAccess: true}); !errors.Is(err, ErrPersonalGuest) {
		t.Fatalf("guest whole-root sharing accepted: %v", err)
	}
	st, err = mgr.AddShare(ctx, AddRequest{
		RootID:            "root-main",
		Subpath:           "",
		SMBName:           "主存储整盘",
		Sealed:            true,
		LocalConfirmation: true,
	})
	if err != nil {
		t.Fatalf("AddShare root top-level: %v", err)
	}
	var rootShare *SharePoint
	for i := range st.Shares {
		if st.Shares[i].SMBName == "主存储整盘" {
			rootShare = &st.Shares[i]
		}
	}
	if rootShare == nil || !rootShare.ExposesPersonalDirs || !rootShare.Sealed {
		t.Fatalf("expected root share with ExposesPersonalDirs=true and Sealed=true, got %+v", rootShare)
	}
	if _, err := mgr.UpdateShare(ctx, rootShare.RecordName, UpdateRequest{Shared: true, GuestAccess: true, LocalConfirmation: true}); !errors.Is(err, ErrPersonalGuest) {
		t.Fatalf("guest access enabled on an existing private share: %v", err)
	}

	// 4. Reject .lightisle-* internal directories, symlinks, path traversal, and offline roots.
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-main", Subpath: ".lightisle-trash", SMBName: "Trash"}); !errors.Is(err, ErrProtectedPath) {
		t.Fatalf("expected ErrProtectedPath for .lightisle-trash, got %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{Path: trashDir, SMBName: "TrashDirect"}); !errors.Is(err, ErrProtectedPath) {
		t.Fatalf("expected ErrProtectedPath for direct trash path, got %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{Path: symlinkDir, SMBName: "Symlink"}); !errors.Is(err, ErrProtectedPath) {
		t.Fatalf("expected ErrProtectedPath for symlink, got %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-main", Subpath: "../outside", SMBName: "Escape"}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid for traversal, got %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{RootID: "root-offline", Subpath: "", SMBName: "Offline"}); !errors.Is(err, ErrRootOffline) {
		t.Fatalf("expected ErrRootOffline, got %v", err)
	}

	// 5. Update share flags.
	st, err = mgr.UpdateShare(ctx, "家庭影院", UpdateRequest{
		SMBName:     "家庭影院",
		Shared:      true,
		GuestAccess: false,
		ReadOnly:    false,
		Sealed:      true,
	})
	if err != nil {
		t.Fatalf("UpdateShare: %v", err)
	}
	for _, s := range st.Shares {
		if s.RecordName == "家庭影院" && (s.GuestAccess || s.ReadOnly || !s.Sealed) {
			t.Fatalf("share update did not apply: %+v", s)
		}
	}

	// 6. Remove share and verify underlying directory remains intact on disk.
	st, err = mgr.RemoveShare(ctx, "家庭影院")
	if err != nil {
		t.Fatalf("RemoveShare: %v", err)
	}
	if len(st.Shares) != 1 {
		t.Fatalf("expected 1 remaining share, got %d", len(st.Shares))
	}
	if _, statErr := os.Stat(moviesDir); statErr != nil {
		t.Fatalf("RemoveShare must not delete underlying folder: %v", statErr)
	}

	// 7. Custom local folder sharing & unmanaged share update/remove boundaries.
	customDir := filepath.Join(realTmp, "LocalDownloads", "bustv")
	if err := os.MkdirAll(customDir, 0o755); err != nil {
		t.Fatalf("MkdirAll customDir: %v", err)
	}
	if _, err := mgr.AddShare(ctx, AddRequest{Path: customDir, SMBName: "bustv"}); !errors.Is(err, ErrProtectedPath) {
		t.Fatalf("expected ErrProtectedPath for raw Path without AllowCustomPath, got %v", err)
	}
	st, err = mgr.AddShare(ctx, AddRequest{Path: customDir, SMBName: "bustv", AllowCustomPath: true})
	if err != nil {
		t.Fatalf("AddShare custom local folder: %v", err)
	}
	if _, err := mgr.UpdateShare(ctx, "bustv", UpdateRequest{SMBName: "bustv", Shared: false}); !errors.Is(err, ErrUnmanagedShare) {
		t.Fatalf("expected ErrUnmanagedShare for remote UpdateShare on unmanaged share, got %v", err)
	}
	if _, err := mgr.RemoveShare(ctx, "bustv"); !errors.Is(err, ErrUnmanagedShare) {
		t.Fatalf("expected ErrUnmanagedShare for remote RemoveShare on unmanaged share, got %v", err)
	}
	st, err = mgr.UpdateShare(ctx, "bustv", UpdateRequest{SMBName: "bustv", Shared: true, ReadOnly: true, AllowUnmanaged: true})
	if err != nil {
		t.Fatalf("UpdateShare local on unmanaged share: %v", err)
	}
	st, err = mgr.RemoveShareLocal(ctx, "bustv")
	if err != nil {
		t.Fatalf("RemoveShareLocal on unmanaged share: %v", err)
	}
	if _, statErr := os.Stat(customDir); statErr != nil {
		t.Fatalf("RemoveShareLocal must not delete underlying folder: %v", statErr)
	}

	// 8. Offline root share must not block enabling SMB service.
	fake.shares["OfflineShare"] = rawShareEntry{
		Path:    filepath.Join(realTmp, "offline", "Media"),
		SMBName: "OfflineShare",
		Shared:  1,
	}
	if _, err := mgr.SetService(ctx, true); err != nil {
		t.Fatalf("SetService(true) with offline share: %v", err)
	}

	// 9. When sudo requires a password, operations return ErrElevationRequired and remoteManageReady becomes false.
	fake.sudoReady = false
	if _, err := mgr.SetService(ctx, false); !errors.Is(err, ErrElevationRequired) {
		t.Fatalf("expected ErrElevationRequired when sudo not ready, got %v", err)
	}
	st, err = mgr.Status(ctx)
	if err != nil {
		t.Fatalf("Status after sudoReady=false: %v", err)
	}
	if st.RemoteManageReady {
		t.Fatalf("expected RemoteManageReady=false when sudo -n fails")
	}
}

type fakeIdentityProvider struct {
	uuid string
}

func (p *fakeIdentityProvider) Capture(_ context.Context, path string) (storageidentity.Binding, error) {
	return storageidentity.Binding{
		Path:        path,
		VolumeUUID:  p.uuid,
		DirectoryID: 101,
		BirthSec:    1700000000,
		BirthNsec:   0,
		Generation:  1,
	}, nil
}

func (p *fakeIdentityProvider) Verify(_ context.Context, b storageidentity.Binding) error {
	if b.VolumeUUID != p.uuid {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestExternalVolumeDisconnectAndReconnectRestoresSMBShare(t *testing.T) {
	tmp := t.TempDir()
	realTmp, err := filepath.EvalSymlinks(tmp)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	storePath := filepath.Join(realTmp, "smb-shares.json")
	extRoot := filepath.Join(realTmp, "Volumes", "MediaDrive")
	shareDir := filepath.Join(extRoot, "Cinema")
	if err := os.MkdirAll(shareDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	diskOnline := true
	idProvider := &fakeIdentityProvider{uuid: "11111111-2222-3333-4444-555555555555"}
	fake := newFakeSMBSystem()

	newManager := func() *Manager {
		m := &Manager{
			exec:  fake.exec,
			lanIP: func() string { return "192.168.1.88" },
			rootProvider: func() []RootInfo {
				return []RootInfo{
					{ID: "root-ext", Name: "外置影视盘", Path: extRoot, Online: diskOnline},
				}
			},
		}
		m.SetIdentityProvider(idProvider)
		m.ConfigurePersistence(storePath)
		return m
	}

	ctx := context.Background()
	mgr := newManager()

	// 1. Create SMB share with specific permissions (GuestAccess + ReadOnly + Sealed).
	st, err := mgr.AddShare(ctx, AddRequest{
		RootID:      "root-ext",
		Subpath:     "Cinema",
		SMBName:     "外置影院",
		GuestAccess: true,
		ReadOnly:    true,
		Sealed:      true,
	})
	if err != nil {
		t.Fatalf("AddShare: %v", err)
	}
	if len(st.Shares) != 1 || !st.Shares[0].SyncedInMacOS || !st.Shares[0].PathExists {
		t.Fatalf("unexpected initial share: %+v", st.Shares)
	}

	// 2. External drive disconnects: macOS removes the SharePoint and unmounts the path.
	diskOnline = false
	delete(fake.shares, "外置影院")
	if err := os.RemoveAll(extRoot); err != nil {
		t.Fatalf("RemoveAll: %v", err)
	}

	st, err = mgr.Status(ctx)
	if err != nil {
		t.Fatalf("Status while offline: %v", err)
	}
	if len(st.Shares) != 1 {
		t.Fatalf("expected desired share to remain visible while offline, got %d", len(st.Shares))
	}
	if st.Shares[0].PathExists || st.Shares[0].SyncedInMacOS {
		t.Fatalf("expected offline share PathExists=false & SyncedInMacOS=false, got %+v", st.Shares[0])
	}
	if len(fake.shares) != 0 {
		t.Fatalf("must not register share in macOS while drive is offline")
	}

	// 3. A foreign unverified drive mounts at the same /Volumes/MediaDrive path (diskOnline still false).
	if err := os.MkdirAll(shareDir, 0o755); err != nil {
		t.Fatalf("MkdirAll foreign drive: %v", err)
	}
	st, restored, err := mgr.Reconcile(ctx, extRoot)
	if err != nil {
		t.Fatalf("Reconcile on foreign disk: %v", err)
	}
	if restored != 0 || len(fake.shares) != 0 {
		t.Fatalf("SECURITY: must NEVER auto-share a foreign unverified disk at the same mount path! restored=%d shares=%+v", restored, fake.shares)
	}
	if len(st.Shares) != 1 || st.Shares[0].PathExists {
		t.Fatalf("expected foreign disk share to remain marked offline: %+v", st.Shares)
	}

	// 4. Original drive reconnects and passes physical RootRegistry verification, even after daemon restart.
	diskOnline = true
	mgrRestarted := newManager()
	st, restored, err = mgrRestarted.Reconcile(ctx, extRoot)
	if err != nil {
		t.Fatalf("Reconcile on verified reconnect: %v", err)
	}
	if restored != 1 {
		t.Fatalf("expected 1 restored share, got %d", restored)
	}
	rawRestored, ok := fake.shares["外置影院"]
	if !ok {
		t.Fatalf("expected macOS sharing -a to restore 外置影院, got %+v", fake.shares)
	}
	if rawRestored.Shared != 1 || rawRestored.GuestAccess != 1 || rawRestored.ReadOnly != 1 || rawRestored.Sealed != 1 {
		t.Fatalf("restored share lost permissions: %+v", rawRestored)
	}
	if len(st.Shares) != 1 || !st.Shares[0].PathExists || !st.Shares[0].SyncedInMacOS || st.Shares[0].NeedsRestore {
		t.Fatalf("expected fully synced online share after reconnect, got %+v", st.Shares)
	}

	// 5. Even if macOS kept a stale dslocal SharePoint entry across disconnect/remount,
	// forceMountPrefix on NSWorkspace.didMountNotification removes and re-adds it so smbd re-binds.
	fake.lastCalls = nil
	_, restoredAgain, err := mgrRestarted.Reconcile(ctx, extRoot)
	if err != nil || restoredAgain != 1 {
		t.Fatalf("expected remount force-rebind to restore 1 share, got %d (err=%v)", restoredAgain, err)
	}
	sawRemove := false
	sawAdd := false
	for _, c := range fake.lastCalls {
		if len(c) >= 5 && c[2] == "/usr/sbin/sharing" && c[3] == "-r" && c[4] == "外置影院" {
			sawRemove = true
		}
		if len(c) >= 5 && c[2] == "/usr/sbin/sharing" && c[3] == "-a" && c[4] == shareDir {
			sawAdd = true
		}
	}
	if !sawRemove || !sawAdd {
		t.Fatalf("expected stale SharePoint to be removed and re-added on volume remount; calls=%v", fake.lastCalls)
	}
}

func TestStatusIsStrictlyReadOnlyAndDoesNotHoldStateLockAcrossExec(t *testing.T) {
	tmp := t.TempDir()
	realTmp, err := filepath.EvalSymlinks(tmp)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	extRoot := filepath.Join(realTmp, "Volumes", "MediaDrive")
	shareDir := filepath.Join(extRoot, "Cinema")
	if err := os.MkdirAll(shareDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	fake := newFakeSMBSystem()
	inSharingList := make(chan struct{})
	releaseSharingList := make(chan struct{})
	var blockOnce bool
	var mu sync.Mutex

	mgr := &Manager{
		lanIP: func() string { return "192.168.1.88" },
		rootProvider: func() []RootInfo {
			return []RootInfo{{ID: "root-ext", Name: "外置影视盘", Path: extRoot, Online: true}}
		},
		desired: map[string]DesiredShare{
			"外置影院": {
				RecordName: "外置影院",
				SMBName:    "外置影院",
				Path:       shareDir,
				RootID:     "root-ext",
				Shared:     true,
				ReadOnly:   true,
			},
		},
	}
	mgr.exec = func(ctx context.Context, binary string, args ...string) ([]byte, []byte, int, error) {
		if binary == "/usr/sbin/sharing" && len(args) >= 3 && args[0] == "-l" && args[1] == "-f" {
			mu.Lock()
			shouldBlock := blockOnce
			if blockOnce {
				blockOnce = false
			}
			mu.Unlock()
			if shouldBlock {
				close(inSharingList)
				<-releaseSharingList
			}
		}
		return fake.exec(ctx, binary, args...)
	}

	// 1. Status while desired share is missing from macOS must NOT invoke any mutating sharing command.
	mu.Lock()
	blockOnce = true
	mu.Unlock()

	type statusResult struct {
		st  Status
		err error
	}
	done := make(chan statusResult, 1)
	go func() {
		st, err := mgr.Status(context.Background())
		done <- statusResult{st: st, err: err}
	}()

	// Wait until Status is actively inside external `/usr/sbin/sharing -l -f json`.
	<-inSharingList

	// While external process is executing, state lock m.mu must NOT be held:
	// HasManagedShares must return immediately without blocking.
	lockCheckDone := make(chan bool, 1)
	go func() {
		lockCheckDone <- mgr.HasManagedShares()
	}()
	select {
	case has := <-lockCheckDone:
		if !has {
			t.Fatalf("expected HasManagedShares() == true")
		}
	case <-time.After(500 * time.Millisecond):
		close(releaseSharingList)
		t.Fatal("HasManagedShares blocked while Status executed external process; m.mu must not be held across exec")
	}

	close(releaseSharingList)
	res := <-done
	if res.err != nil {
		t.Fatalf("Status: %v", res.err)
	}
	if len(fake.shares) != 0 {
		t.Fatalf("Status must be strictly read-only and never mutate system shares, got %+v", fake.shares)
	}
	for _, c := range fake.lastCalls {
		if len(c) >= 4 && c[2] == "/usr/sbin/sharing" && (c[3] == "-a" || c[3] == "-e" || c[3] == "-r") {
			t.Fatalf("Status invoked mutating sharing command: %v", c)
		}
	}
	if len(res.st.Shares) != 1 || res.st.Shares[0].SyncedInMacOS || !res.st.Shares[0].NeedsRestore {
		t.Fatalf("expected Status to report SyncedInMacOS=false and NeedsRestore=true without mutating, got %+v", res.st.Shares)
	}

	// 2. Explicit Reconcile performs the actual restoration.
	st, restored, err := mgr.Reconcile(context.Background(), "")
	if err != nil || restored != 1 {
		t.Fatalf("explicit Reconcile expected restored=1, got %d (err=%v)", restored, err)
	}
	if len(fake.shares) != 1 || len(st.Shares) != 1 || !st.Shares[0].SyncedInMacOS || st.Shares[0].NeedsRestore {
		t.Fatalf("expected share restored after explicit Reconcile, got %+v", st.Shares)
	}
}
