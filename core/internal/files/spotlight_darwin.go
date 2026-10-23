//go:build darwin

package files

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// SpotlightSearch is an optional macOS-backed search for a *pre-authorized*
// subtree. Unlike global mdfind queries, -onlyin never scans sibling shares.
// Paths are rechecked through the pinned os.Root and safePath before return.
func (m *Manager) SpotlightSearch(ctx context.Context, base, term string, limit int) ([]Entry, bool, error) {
	var out []Entry
	var more bool
	err := m.withRead(func(s *Store) (err error) { out, more, err = s.spotlightSearch(ctx, base, term, limit); return })
	return out, more, err
}
func spotlightQuery(term string) (string, error) {
	term = strings.TrimSpace(term)
	if len(term) < 2 || len(term) > 128 || strings.ContainsRune(term, 0) {
		return "", ErrPath
	}
	// Only a literal, quoted search term: no shell or raw predicate fragments.
	escaped := strings.NewReplacer("\\", "\\\\", "\"", "\\\"").Replace(term)
	return `(kMDItemFSName == "*` + escaped + `*"cd || kMDItemTextContent == "*` + escaped + `*"cd)`, nil
}
func (s *Store) spotlightSearch(ctx context.Context, base, term string, limit int) ([]Entry, bool, error) {
	base, err := s.safePath(base, true, false)
	if err != nil {
		return nil, false, err
	}
	if limit < 1 || limit > 200 {
		return nil, false, ErrPath
	}
	query, err := spotlightQuery(term)
	if err != nil {
		return nil, false, err
	}
	baseAbs := s.root.Name()
	if base != "." {
		baseAbs = filepath.Join(baseAbs, filepath.FromSlash(base))
	}
	if ctx == nil {
		ctx = context.Background()
	}
	runCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(runCtx, "/usr/bin/mdfind", "-0", "-onlyin", baseAbs, query)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, false, err
	}
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		return nil, false, err
	}
	// Bounded even for common terms like "a" on a million-file disk.
	const maxOutput = 512 * 1024
	content, readErr := io.ReadAll(io.LimitReader(stdout, maxOutput+1))
	if len(content) > maxOutput {
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()
	if readErr != nil {
		return nil, false, readErr
	}
	if runCtx.Err() != nil {
		return nil, false, runCtx.Err()
	}
	if waitErr != nil && len(content) <= maxOutput {
		return nil, false, waitErr
	}
	tooLarge := len(content) > maxOutput
	result := make([]Entry, 0, limit)
	rootAbs, err := filepath.Abs(s.root.Name())
	if err != nil {
		return nil, false, err
	}
	baseRelative := filepath.Clean(base)
	for _, line := range bytes.Split(content, []byte{0}) {
		if len(result) >= limit {
			return result, true, nil
		}
		if len(line) == 0 {
			continue
		}
		absolute := string(line)
		// Use filepath.Rel on absolute paths without trusting mdfind's index.
		rel, err := filepath.Rel(rootAbs, absolute)
		if err != nil || rel == "." || rel == ".." || filepath.IsAbs(rel) || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			continue
		}
		rel = filepath.ToSlash(rel)
		if baseRelative != "." && rel != baseRelative && !strings.HasPrefix(rel, baseRelative+"/") {
			continue
		}
		safe, err := s.safePath(rel, false, false)
		if err != nil {
			continue
		}
		info, err := s.root.Lstat(safe)
		if err != nil || (!info.IsDir() && !info.Mode().IsRegular()) {
			continue
		}
		result = append(result, Entry{Name: path.Base(safe), Path: safe, Type: typeOf(info), Size: info.Size(), Modified: info.ModTime()})
	}
	return result, tooLarge, nil
}

// A missing/disabled Spotlight index never prevents the existing safe
// bounded filename traversal from working.
func (m *Manager) SearchSpotlightOrFallback(ctx context.Context, base, term string, limit int) ([]Entry, bool, error) {
	items, more, err := m.SpotlightSearch(ctx, base, term, limit)
	if err == nil && (len(items) > 0 || more) {
		return items, more, nil
	}
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		return m.Search(base, term, limit)
	}
	if err == nil {
		return m.Search(base, term, limit)
	}
	return nil, false, err
}
