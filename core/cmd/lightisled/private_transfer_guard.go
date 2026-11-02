package main

import (
	"path/filepath"
	"strings"
)

// The Mac native export bridge has no account/root-generation quota
// transaction. Copying a file OUT leaves the original and its bill intact,
// but moving a private home out would leave an orphaned ledger entry.
// Fail closed until a durable root-scoped move/export reconciliation exists.
func nativeMoveTouchesPersonalHome(source string) bool {
	return strings.EqualFold(source, "Users") ||
		(len(source) > len("Users/") &&
			source[5] == '/' &&
			strings.EqualFold(source[:5], "Users"))
}

// The native export is for locations OUTSIDE all registered NAS roots.
// CopyOut already rejects overlap with its own source share, but without
// this guard another registered volume could be used as an unmetered
// destination (including another user's Users/uID/... subtree).
func nativeExportOverlapsRegisteredRoot(destination string, rootPaths []string) bool {
	resolved, err := filepath.EvalSymlinks(destination)
	if err != nil {
		return true // Unverifiable target must not be used for a trusted export.
	}
	for _, registered := range rootPaths {
		if registered == "" {
			continue
		}
		rootPathsToCheck := []string{filepath.Clean(registered)}
		if canonical, err := filepath.EvalSymlinks(registered); err == nil {
			rootPathsToCheck = append(rootPathsToCheck, canonical)
		}
		for _, root := range rootPathsToCheck {
			for _, dest := range []string{filepath.Clean(destination), resolved} {
				for _, pair := range [][2]string{{root, dest}, {dest, root}} {
					relative, err := filepath.Rel(pair[0], pair[1])
					if err == nil && (relative == "." ||
						(relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)))) {
						return true
					}
				}
			}
		}
	}
	return false
}
