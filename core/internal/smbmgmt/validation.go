package smbmgmt

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func resolveAndValidateTargetPath(req AddRequest, roots []RootInfo) (string, error) {
	var candidate string
	allowVolumeRoot := false
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
			allowVolumeRoot = true
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
		if !req.AllowCustomPath {
			return "", ErrProtectedPath
		}
		candidate = filepath.Clean(strings.TrimSpace(req.Path))
	} else {
		return "", ErrInvalid
	}

	validated, err := validateSharePath(candidate, allowVolumeRoot)
	if err != nil {
		return "", err
	}
	if len(roots) > 0 {
		matchedOnline := false
		matchedAny := false
		for _, r := range roots {
			rootClean := filepath.Clean(r.Path)
			if rootClean != "" && rootClean != "." && pathContains(rootClean, validated) {
				matchedAny = true
				if r.Online {
					matchedOnline = true
					break
				}
			}
		}
		if matchedAny && !matchedOnline {
			return "", ErrRootOffline
		}
		if !matchedAny && !req.AllowCustomPath {
			return "", ErrProtectedPath
		}
	}
	return validated, nil
}

func isRegisteredRootPath(candidate string, roots []RootInfo) bool {
	clean := strings.ToLower(filepath.Clean(candidate))
	for _, r := range roots {
		rootClean := filepath.Clean(r.Path)
		if rootClean != "" && rootClean != "." && strings.ToLower(rootClean) == clean {
			return true
		}
	}
	return false
}

func validateSharePath(candidate string, allowVolumeRoot bool) (string, error) {
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
	if !allowVolumeRoot && strings.HasPrefix(candidate, "/Volumes/") {
		rest := strings.TrimPrefix(candidate, "/Volumes/")
		if !strings.Contains(rest, "/") {
			// Bare external volume mount point (/Volumes/<Disk>) is rejected
			// for ad-hoc folder selection; require a folder on the volume
			// unless the volume root itself is a registered LightIsle root.
			return "", ErrVolumeRoot
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
