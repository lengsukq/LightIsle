package files

import (
	"bytes"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSearchSingleCharMultiKeywordAndRelevanceRanking(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	for _, dir := range []string{"2026", "2026/归档", "2025", "音频"} {
		if err := s.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	filesToCreate := []string{
		"税.pdf",
		"税务申报_2026.pdf",
		"2026/年度个税备份.pdf",
		"2026/租房合同.pdf",
		"2026_劳动合同.docx",
		"2025/租房合同.pdf",
		"x.txt",
		"音频/无损母带.ape",
	}
	for _, rel := range filesToCreate {
		if _, err := s.Upload(rel, bytes.NewBufferString("payload")); err != nil {
			t.Fatalf("upload %s: %v", rel, err)
		}
	}

	// Reject empty, whitespace, NUL, and >128 byte queries.
	for _, invalid := range []string{"", "   ", "ab\x00cd", strings.Repeat("a", 129)} {
		if _, _, err := s.Search(".", invalid, 20); !errors.Is(err, ErrPath) {
			t.Fatalf("expected ErrPath for %q, got %v", invalid, err)
		}
	}

	// 1-byte ASCII query succeeds.
	asciiHits, _, err := s.Search(".", "x", 20)
	if err != nil || len(asciiHits) == 0 || asciiHits[0].Path != "x.txt" {
		t.Fatalf("expected x.txt first for 'x', got %+v err=%v", asciiHits, err)
	}

	// 1-char CJK query succeeds and ranks exact stem ("税.pdf") > prefix ("税务申报_2026.pdf") > substring ("2026/年度个税备份.pdf").
	taxHits, _, err := s.Search(".", "税", 20)
	if err != nil || len(taxHits) != 3 {
		t.Fatalf("expected 3 hits for '税', got %+v err=%v", taxHits, err)
	}
	if taxHits[0].Path != "税.pdf" || taxHits[1].Path != "税务申报_2026.pdf" || taxHits[2].Path != "2026/年度个税备份.pdf" {
		t.Fatalf("unexpected relevance order for '税': %+v", taxHits)
	}

	// Multi-keyword AND matches both filename ("2026_劳动合同.docx") and relative directory+filename ("2026/租房合同.pdf"),
	// ranking all-tokens-in-filename above directory+filename, and excluding "2025/租房合同.pdf".
	contractHits, _, err := s.Search(".", "2026 合同", 20)
	if err != nil || len(contractHits) != 2 {
		t.Fatalf("expected 2 hits for '2026 合同', got %+v err=%v", contractHits, err)
	}
	if contractHits[0].Path != "2026_劳动合同.docx" || contractHits[1].Path != "2026/租房合同.pdf" {
		t.Fatalf("unexpected multi-keyword order: %+v", contractHits)
	}

	// Subdirectory scope ("2025") restricts hits to that subtree.
	subHits, _, err := s.Search("2025", "合同", 20)
	if err != nil || len(subHits) != 1 || subHits[0].Path != "2025/租房合同.pdf" {
		t.Fatalf("expected 2025/租房合同.pdf in subdir search, got %+v err=%v", subHits, err)
	}

	// Extended lossless audio extension (.ape) matches kind="audio".
	audioHits, _, err := s.SearchKind(".", "无损", "audio", 20)
	if err != nil || len(audioHits) != 1 || audioHits[0].Path != "音频/无损母带.ape" {
		t.Fatalf("expected audio match for .ape, got %+v err=%v", audioHits, err)
	}
}

func TestRankSearchEntriesTieBreaksByModifiedDesc(t *testing.T) {
	older := time.Unix(1700000000, 0)
	newer := time.Unix(1750000000, 0)
	entries := []Entry{
		{Name: "report_old.pdf", Path: "docs/report_old.pdf", Type: "file", Modified: older},
		{Name: "body_only.pdf", Path: "docs/body_only.pdf", Type: "file", Modified: newer},
		{Name: "report_new.pdf", Path: "docs/report_new.pdf", Type: "file", Modified: newer},
		{Name: "report.pdf", Path: "docs/report.pdf", Type: "file", Modified: older},
	}
	RankSearchEntries(entries, "report")
	want := []string{"docs/report.pdf", "docs/report_new.pdf", "docs/report_old.pdf", "docs/body_only.pdf"}
	for i, w := range want {
		if entries[i].Path != w {
			t.Fatalf("rank[%d] = %s, want %s (full=%+v)", i, entries[i].Path, w, entries)
		}
	}
}
