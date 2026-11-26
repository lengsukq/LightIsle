package gallery

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type recordingAIAnalyzer struct {
	mu      sync.Mutex
	batches [][]string
	byName  map[string]mediaworker.AIAnalysis
}

func (r *recordingAIAnalyzer) AnalyzeBatch(_ context.Context, items []mediaworker.AIBatchInput) ([]mediaworker.AIAnalysis, error) {
	names := make([]string, len(items))
	out := make([]mediaworker.AIAnalysis, len(items))
	for i, it := range items {
		names[i] = it.Name
		if res, ok := r.byName[it.Name]; ok {
			out[i] = res
		} else {
			out[i] = mediaworker.AIAnalysis{Status: "ok"}
		}
	}
	r.mu.Lock()
	r.batches = append(r.batches, names)
	r.mu.Unlock()
	return out, nil
}

func TestPathPrefixFilterAndPriorityOCRQueue(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()

	shareRoot := filepath.Join(root, "SharedFiles")
	baseTime := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	// Several newer ordinary photos that would normally win ORDER BY taken_at DESC.
	for i := 1; i <= 5; i++ {
		writeTestPNG(t, filepath.Join(shareRoot, "Users", "u1", "photos", "Camera", "newer_"+string(rune('0'+i))+".png"), baseTime.Add(time.Duration(i)*time.Hour))
	}
	// An older receipt inside 家庭档案/发票 that we will fast-track via EnqueuePriorityAI.
	receiptRel := "Users/u1/photos/家庭档案/发票/receipt_priority.png"
	writeTestPNG(t, filepath.Join(shareRoot, filepath.FromSlash(receiptRel)), baseTime.Add(-48*time.Hour))
	// Another user's file that must never leak via PathPrefix.
	writeTestPNG(t, filepath.Join(shareRoot, "Users", "u2", "photos", "家庭档案", "发票", "u2_secret.png"), baseTime.Add(10*time.Hour))

	lib, err := Open(filepath.Join(root, "gallery"), storage)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	// Pause AI while scanning so we can queue priority item BEFORE the analyzer runs.
	lib.SetAIPaused(true)
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !lib.Status().Running {
			break
		}
		time.Sleep(15 * time.Millisecond)
	}

	// Queue the older receipt for priority OCR before resuming AI.
	if !lib.EnqueuePriorityAI(receiptRel) {
		t.Fatalf("EnqueuePriorityAI(%q) returned false", receiptRel)
	}
	if lib.PriorityAIQueueLen() != 1 {
		t.Fatalf("expected priority queue len 1, got %d", lib.PriorityAIQueueLen())
	}

	rec := &recordingAIAnalyzer{
		byName: map[string]mediaworker.AIAnalysis{
			"receipt_priority.png": {
				Status:    "ok",
				OCRText:   "增值税专用发票 实付金额 888.00 元 医疗报销",
				OCRTokens: []string{"增值税", "发票", "888", "医疗", "报销"},
			},
		},
	}
	lib.SetAIAnalyzer(rec)
	lib.SetAIPaused(false)

	waitForScanAndAIIndex(t, lib)

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.batches) == 0 || len(rec.batches[0]) == 0 {
		t.Fatalf("expected AI batches to run")
	}
	if rec.batches[0][0] != "receipt_priority.png" {
		t.Fatalf("expected receipt_priority.png to be first item in first AI batch, got batches=%v", rec.batches)
	}

	// Test PathPrefix + searchMode=ocr scoped to u1's roots.
	u1Roots := []string{"Users/u1/photos"}
	assets, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		PathPrefix: "Users/u1/photos/家庭档案",
		Query:      "医疗报销",
		SearchMode: "ocr",
	}, u1Roots)
	if err != nil {
		t.Fatalf("ListScopedForUserFiltered with PathPrefix: %v", err)
	}
	if len(assets) != 1 || assets[0].Path != receiptRel {
		t.Fatalf("expected only receipt_priority.png, got %+v", assets)
	}

	// PathPrefix pointing at u2 MUST yield 0 results when u1Roots does not cover u2.
	leaked, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		PathPrefix: "Users/u2/photos/家庭档案",
	}, u1Roots)
	if err != nil {
		t.Fatalf("cross-user PathPrefix error: %v", err)
	}
	if len(leaked) != 0 {
		t.Fatalf("cross-user PathPrefix leaked %d assets: %+v", len(leaked), leaked)
	}

	// IndexSinglePhotoNow indexes a brand-new photo immediately without waiting for scan.
	brandNewRel := "Users/u1/photos/家庭档案/保修/warranty_new.png"
	writeTestPNG(t, filepath.Join(shareRoot, filepath.FromSlash(brandNewRel)), baseTime.Add(24*time.Hour))
	indexed, err := lib.IndexSinglePhotoNow(context.Background(), brandNewRel)
	if err != nil {
		t.Fatalf("IndexSinglePhotoNow: %v", err)
	}
	if indexed.ID <= 0 || indexed.Path != brandNewRel {
		t.Fatalf("unexpected indexed asset: %+v", indexed)
	}
}
