package smbmgmt

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
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

	// 7. When sudo requires a password, operations return ErrElevationRequired.
	fake.sudoReady = false
	if _, err := mgr.SetService(ctx, false); !errors.Is(err, ErrElevationRequired) {
		t.Fatalf("expected ErrElevationRequired when sudo not ready, got %v", err)
	}
}
