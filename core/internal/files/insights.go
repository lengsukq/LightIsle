package files

import (
	"container/heap"
	"context"
	"errors"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	InsightModeLarge = "large"
	InsightModeRecent = "recent"

	DefaultInsightLimit    = 100
	MaxInsightLimit        = 200
	DefaultLargeMinBytes   = int64(50) << 20 // 50 MiB
	DefaultRecentDays      = 7
	MaxRecentDays          = 365
	DefaultInsightMaxScan  = 200000
	DefaultInsightMaxDirs  = 20000
	DefaultInsightTimeout  = 15 * time.Second
)

type InsightOptions struct {
	Roots          []string
	Mode           string
	MinBytes       int64
	HasMinBytes    bool
	Days           int
	Limit          int
	MaxScanEntries int
	MaxDirs        int
	Now            time.Time
	CanTraverse    func(relPath string) bool
	CanReadFile    func(relPath string) bool
	CanRead        func(relPath string) bool
}

type InsightItem struct {
	Name       string    `json:"name"`
	Path       string    `json:"path"`
	ParentDir  string    `json:"parentDir"`
	Size       int64     `json:"size"`
	Modified   time.Time `json:"modified"`
	ModifiedAt int64     `json:"modifiedAt"`
	Ext        string    `json:"ext,omitempty"`
}

type InsightResult struct {
	Mode         string        `json:"mode"`
	MinBytes     int64         `json:"minBytes,omitempty"`
	Days         int           `json:"days,omitempty"`
	ScannedFiles int           `json:"scannedFiles"`
	MatchedFiles int           `json:"matchedFiles"`
	TotalBytes   int64         `json:"totalBytes"`
	Truncated    bool          `json:"truncated"`
	TimedOut     bool          `json:"timedOut,omitempty"`
	Items        []InsightItem `json:"items"`
}

// insightHeap is a fixed-capacity min-heap: h[0] is always the weakest element
// among the current top-K so we can evict it in O(log K) without retaining
// every scanned file in memory.
type insightHeap struct {
	mode  string
	items []InsightItem
}

func (h insightHeap) Len() int { return len(h.items) }

func (h insightHeap) Less(i, j int) bool {
	return insightWorse(h.mode, h.items[i], h.items[j])
}

func (h insightHeap) Swap(i, j int) { h.items[i], h.items[j] = h.items[j], h.items[i] }

func (h *insightHeap) Push(x any) {
	h.items = append(h.items, x.(InsightItem))
}

func (h *insightHeap) Pop() any {
	n := len(h.items)
	item := h.items[n-1]
	h.items = h.items[:n-1]
	return item
}

// insightWorse reports whether a ranks strictly lower than b (so a should sit
// closer to the root of the min-heap and be evicted first).
func insightWorse(mode string, a, b InsightItem) bool {
	if mode == InsightModeRecent {
		if !a.Modified.Equal(b.Modified) {
			return a.Modified.Before(b.Modified)
		}
		if a.Size != b.Size {
			return a.Size < b.Size
		}
		return a.Path > b.Path
	}
	// InsightModeLarge
	if a.Size != b.Size {
		return a.Size < b.Size
	}
	if !a.Modified.Equal(b.Modified) {
		return a.Modified.Before(b.Modified)
	}
	return a.Path > b.Path
}

// ScanInsights walks caller-authorized subtrees using ScanDirectory (which
// skips .lightisle-* internals, macOS metadata sidecars, and symlinks) and
// retains only the Top-K largest or most recently modified regular files via a
// bounded min-heap.
func (m *Manager) ScanInsights(ctx context.Context, opts InsightOptions) (InsightResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	mode := opts.Mode
	if mode == "" {
		mode = InsightModeLarge
	}
	if mode != InsightModeLarge && mode != InsightModeRecent {
		return InsightResult{}, ErrPath
	}
	limit := opts.Limit
	if limit <= 0 {
		limit = DefaultInsightLimit
	}
	if limit > MaxInsightLimit {
		limit = MaxInsightLimit
	}
	minBytes := opts.MinBytes
	if mode == InsightModeLarge {
		if !opts.HasMinBytes {
			minBytes = DefaultLargeMinBytes
		}
		if minBytes < 0 {
			minBytes = 0
		}
	} else {
		minBytes = 0
	}
	days := opts.Days
	if mode == InsightModeRecent {
		if days <= 0 {
			days = DefaultRecentDays
		}
		if days > MaxRecentDays {
			days = MaxRecentDays
		}
	} else {
		days = 0
	}
	maxScan := opts.MaxScanEntries
	if maxScan <= 0 {
		maxScan = DefaultInsightMaxScan
	}
	maxDirs := opts.MaxDirs
	if maxDirs <= 0 {
		maxDirs = DefaultInsightMaxDirs
	}
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	var cutoff time.Time
	if mode == InsightModeRecent {
		cutoff = now.Add(-time.Duration(days) * 24 * time.Hour)
	}

	roots := deduplicateRoots(opts.Roots)
	res := InsightResult{
		Mode:     mode,
		MinBytes: minBytes,
		Days:     days,
		Items:    []InsightItem{},
	}
	if len(roots) == 0 {
		return res, nil
	}

	topK := &insightHeap{mode: mode, items: make([]InsightItem, 0, limit)}
	heap.Init(topK)

	scannedEntries := 0
	visitedDirs := 0
	stopErr := errors.New("insight_limit_reached")

	canTraverse := opts.CanTraverse
	if canTraverse == nil {
		canTraverse = opts.CanRead
	}
	canReadFile := opts.CanReadFile
	if canReadFile == nil {
		canReadFile = opts.CanRead
	}

	queue := make([]string, 0, len(roots))
	queue = append(queue, roots...)

	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				res.Truncated = true
				res.TimedOut = true
				break
			}
			return InsightResult{}, err
		}
		if visitedDirs >= maxDirs || scannedEntries >= maxScan {
			res.Truncated = true
			break
		}
		dir := queue[0]
		queue = queue[1:]
		visitedDirs++

		err := m.ScanDirectory(ctx, dir, func(entries []Entry) error {
			for _, e := range entries {
				scannedEntries++
				if scannedEntries > maxScan {
					res.Truncated = true
					return stopErr
				}
				if e.Type == "folder" {
					if canTraverse != nil && !canTraverse(e.Path) {
						continue
					}
					if len(queue)+visitedDirs < maxDirs {
						queue = append(queue, e.Path)
					} else {
						res.Truncated = true
					}
					continue
				}
				if e.Type != "file" {
					continue
				}
				if canReadFile != nil && !canReadFile(e.Path) {
					continue
				}
				res.ScannedFiles++
				if mode == InsightModeLarge && e.Size < minBytes {
					continue
				}
				if mode == InsightModeRecent && e.Modified.Before(cutoff) {
					continue
				}
				res.MatchedFiles++
				res.TotalBytes += e.Size

				parent := path.Dir(e.Path)
				if parent == "." {
					parent = ""
				}
				cand := InsightItem{
					Name:       e.Name,
					Path:       e.Path,
					ParentDir:  parent,
					Size:       e.Size,
					Modified:   e.Modified,
					ModifiedAt: e.Modified.Unix(),
					Ext:        strings.ToLower(filepath.Ext(e.Name)),
				}
				if topK.Len() < limit {
					heap.Push(topK, cand)
				} else if insightWorse(mode, topK.items[0], cand) {
					topK.items[0] = cand
					heap.Fix(topK, 0)
				}
			}
			return nil
		})
		if errors.Is(err, stopErr) {
			break
		}
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
				res.Truncated = true
				res.TimedOut = true
				break
			}
			if errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) {
				return InsightResult{}, context.Canceled
			}
			if errors.Is(err, ErrOffline) {
				return InsightResult{}, err
			}
			// Missing optional root or concurrent directory modification: skip cleanly.
			continue
		}
	}

	items := topK.items
	sort.Slice(items, func(i, j int) bool {
		return insightWorse(mode, items[j], items[i])
	})
	res.Items = items
	return res, nil
}
