package mediascope

import (
	"errors"
	"path"
	"sort"
	"strings"
)

// ScanDirectories validates and compacts changed folders. Never expand an
// untrusted relative path to the NAS root or accept a traversal alias.
func ScanDirectories(input []string) ([]string, error) {
	if len(input) == 0 || len(input) > 64 {
		return nil, errors.New("invalid_scan_directories")
	}
	unique := map[string]struct{}{}
	full := false
	for _, p := range input {
		if p == "" || len(p) > 1024 || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00\r\n") || path.Clean(p) != p || p == ".." || strings.HasPrefix(p, "../") {
			return nil, errors.New("invalid_scan_directory")
		}
		if p == "." {
			full = true
			continue
		}
		unique[p] = struct{}{}
	}
	if full { return []string{"."}, nil }
	sorted := make([]string, 0, len(unique))
	for p := range unique {
		sorted = append(sorted, p)
	}
	sort.Strings(sorted)
	out := make([]string, 0, len(sorted))
	for _, dir := range sorted {
		contained := false
		for _, parent := range out {
			if dir == parent || strings.HasPrefix(dir, parent+"/") {
				contained = true
				break
			}
		}
		if !contained {
			out = append(out, dir)
		}
	}
	if len(out) > 32 {
		return nil, errors.New("too_many_scan_directories")
	}
	return out, nil
}
