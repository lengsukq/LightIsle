//go:build darwin

package files

import (
	"strings"
	"testing"
)

func TestSpotlightQueryEscapesExpressionSyntax(t *testing.T) {
	for _, term := range []string{"", "   ", strings.Repeat("a", 129), "ab\x00cd", "a b c d e f g h i"} {
		if _, err := spotlightQuery(term); err == nil {
			t.Fatalf("accepted invalid term %q", term)
		}
	}
	for _, term := range []string{"x", "税", "hello world", "中文照片", `" || kMDItemPath == "*"`, "back\\slash"} {
		q, err := spotlightQuery(term)
		if err != nil {
			t.Fatalf("query %q: %v", term, err)
		}
		if !strings.Contains(q, "kMDItemFSName == ") || !strings.Contains(q, "kMDItemTextContent") {
			t.Fatalf("invalid Spotlight structure %q", q)
		}
		if strings.Contains(term, " ") && !strings.Contains(q, " && ") {
			t.Fatalf("expected AND predicate for multi-token query %q, got %q", term, q)
		}
		if strings.Contains(term, `"`) && !strings.Contains(q, `\"`) {
			t.Fatalf("unescaped quote %q", q)
		}
	}
}
