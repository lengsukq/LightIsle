package files

import (
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxSearchTermBytes = 128
	maxSearchTokens    = 8
)

// ParseSearchTokens validates a user search query and splits it into lowercase
// whitespace-delimited keywords. Single-character CJK and ASCII queries are
// explicitly permitted; empty/whitespace-only, NUL-containing, or oversized
// queries fail with ErrPath.
func ParseSearchTokens(term string) ([]string, error) {
	trimmed := strings.TrimSpace(term)
	if trimmed == "" || len(trimmed) > maxSearchTermBytes || strings.ContainsRune(trimmed, 0) {
		return nil, ErrPath
	}
	rawFields := strings.Fields(strings.ToLower(trimmed))
	if len(rawFields) == 0 || len(rawFields) > maxSearchTokens {
		return nil, ErrPath
	}
	seen := make(map[string]struct{}, len(rawFields))
	tokens := make([]string, 0, len(rawFields))
	for _, field := range rawFields {
		if _, exists := seen[field]; exists {
			continue
		}
		seen[field] = struct{}{}
		tokens = append(tokens, field)
	}
	return tokens, nil
}

// MatchesSearchTokens reports whether every search token appears in the entry's
// slash-normalized relative path (which includes its file/folder name and parent
// directory names).
func MatchesSearchTokens(entry Entry, tokens []string) bool {
	if len(tokens) == 0 {
		return false
	}
	pathLower := strings.ToLower(entry.Path)
	for _, tok := range tokens {
		if !strings.Contains(pathLower, tok) {
			return false
		}
	}
	return true
}

// SearchRelevanceScore computes a deterministic relevance tier for an entry:
// exact filename > exact stem > filename prefix > all tokens in filename >
// all tokens across relative path > Spotlight body-content match.
func SearchRelevanceScore(entry Entry, fullQueryLower string, tokens []string) int {
	nameLower := strings.ToLower(entry.Name)
	ext := filepath.Ext(nameLower)
	stemLower := strings.TrimSuffix(nameLower, ext)
	if stemLower == "" {
		stemLower = nameLower
	}
	if fullQueryLower != "" {
		if nameLower == fullQueryLower {
			return 600
		}
		if stemLower == fullQueryLower {
			return 500
		}
		if strings.HasPrefix(nameLower, fullQueryLower) {
			return 400
		}
	}
	if len(tokens) == 0 {
		return 100
	}
	pathLower := strings.ToLower(entry.Path)
	nameHits := 0
	pathHits := 0
	for _, tok := range tokens {
		if strings.Contains(nameLower, tok) {
			nameHits++
		}
		if strings.Contains(pathLower, tok) {
			pathHits++
		}
	}
	if nameHits == len(tokens) {
		if fullQueryLower != "" && strings.Contains(nameLower, fullQueryLower) {
			return 350
		}
		if strings.HasPrefix(nameLower, tokens[0]) {
			return 330
		}
		return 300
	}
	if pathHits == len(tokens) {
		if nameHits > 0 {
			return 250
		}
		return 200
	}
	if nameHits > 0 {
		return 150
	}
	return 100
}

// RankSearchEntries orders matched entries by relevance descending, then
// modification time descending, shorter filename first, and path ascending.
func RankSearchEntries(entries []Entry, rawQuery string) {
	if len(entries) <= 1 {
		return
	}
	fullQueryLower := strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(rawQuery))), " ")
	tokens, _ := ParseSearchTokens(rawQuery)
	scores := make([]int, len(entries))
	for i := range entries {
		scores[i] = SearchRelevanceScore(entries[i], fullQueryLower, tokens)
	}
	idx := make([]int, len(entries))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		ia, ib := idx[a], idx[b]
		if scores[ia] != scores[ib] {
			return scores[ia] > scores[ib]
		}
		if !entries[ia].Modified.Equal(entries[ib].Modified) {
			return entries[ia].Modified.After(entries[ib].Modified)
		}
		if len(entries[ia].Name) != len(entries[ib].Name) {
			return len(entries[ia].Name) < len(entries[ib].Name)
		}
		return entries[ia].Path < entries[ib].Path
	})
	ranked := make([]Entry, len(entries))
	for outIdx, origIdx := range idx {
		ranked[outIdx] = entries[origIdx]
	}
	copy(entries, ranked)
}
