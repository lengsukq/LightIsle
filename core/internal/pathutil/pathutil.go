package pathutil

import (
	"os"
	"path/filepath"
	"strings"
)

// Inside reports whether candidate is equal to or nested inside parent.
func Inside(parent, candidate string) bool {
	rel, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(candidate))
	return err == nil && (rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))))
}

// Overlap reports whether paths a and b are identical or one is an ancestor of
// the other.
func Overlap(a, b string) bool {
	return Inside(a, b) || Inside(b, a)
}

// ResolveExistingParent resolves symlinks on the deepest existing ancestor of
// p, reattaching any non-existent trailing path segments.
func ResolveExistingParent(p string) (string, error) {
	clean := filepath.Clean(p)
	if resolved, err := filepath.EvalSymlinks(clean); err == nil {
		return resolved, nil
	}
	var tail []string
	cur := clean
	for {
		parent := filepath.Dir(cur)
		if parent == cur {
			return clean, nil
		}
		tail = append([]string{filepath.Base(cur)}, tail...)
		cur = parent
		if resolved, err := filepath.EvalSymlinks(cur); err == nil {
			parts := append([]string{resolved}, tail...)
			return filepath.Join(parts...), nil
		}
	}
}

// OverlapResolved reports whether paths a and b overlap after resolving
// symlinks along their existing parent directories.
func OverlapResolved(a, b string) bool {
	ca, cb := filepath.Clean(a), filepath.Clean(b)
	if ra, err := ResolveExistingParent(ca); err == nil {
		ca = ra
	}
	if rb, err := ResolveExistingParent(cb); err == nil {
		cb = rb
	}
	return Overlap(ca, cb)
}

// FileExistsRegular reports whether path exists and is a regular file.
func FileExistsRegular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
