package files

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestScanDuplicatesExactAPFSCloneAndSubtreeScope(t *testing.T) {
	dataDir := t.TempDir()
	mgr, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer mgr.Close()

	shareRoot := filepath.Join(dataDir, "SharedFiles")
	if err := os.MkdirAll(filepath.Join(shareRoot, "Users", "u1", "Docs"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareRoot, "Users", "u2", "Docs"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareRoot, "Archive"), 0700); err != nil {
		t.Fatal(err)
	}

	// Create 256 KiB payload (> 3*64 KiB so sparse sample + full SHA-256 stages both run).
	payloadA := bytes.Repeat([]byte("LightIsle-Duplicate-Block-A-"), 10000) // 280,000 bytes
	payloadB := bytes.Repeat([]byte("LightIsle-Different-Block-B-"), 10000) // same size, different content!
	clonePayload := bytes.Repeat([]byte("APFS-Pure-CoW-Clone-Payload!"), 9000)

	u1Orig := filepath.Join(shareRoot, "Users", "u1", "Docs", "report.pdf")
	u1Copy := filepath.Join(shareRoot, "Archive", "report_backup.pdf")
	sameSizeDiff := filepath.Join(shareRoot, "Archive", "other_same_size.pdf")
	u2Secret := filepath.Join(shareRoot, "Users", "u2", "Docs", "u2_secret_copy.pdf")

	for _, item := range []struct {
		p    string
		data []byte
	}{
		{u1Orig, payloadA},
		{u1Copy, payloadA},
		{sameSizeDiff, payloadB},
		{u2Secret, payloadA}, // Identical bytes in u2's private space — MUST NOT leak into u1's scan!
	} {
		if err := os.WriteFile(item.p, item.data, 0600); err != nil {
			t.Fatal(err)
		}
	}

	// Symlink inside Archive must be ignored and never followed.
	_ = os.Symlink(u2Secret, filepath.Join(shareRoot, "Archive", "evil_symlink.pdf"))

	// Create an APFS CoW clone pair inside Archive to verify 0-byte-read fgetattrlist clone detection.
	clone1 := filepath.Join(shareRoot, "Archive", "movie_master.mov")
	clone2 := filepath.Join(shareRoot, "Archive", "movie_clone.mov")
	if err := os.WriteFile(clone1, clonePayload, 0600); err != nil {
		t.Fatal(err)
	}
	clonedOK := unix.Clonefile(clone1, clone2, unix.CLONE_NOFOLLOW) == nil
	if !clonedOK {
		// Non-APFS fallback environment
		if err := os.WriteFile(clone2, clonePayload, 0600); err != nil {
			t.Fatal(err)
		}
	}

	// Scan strictly within u1's authorized roots ("Archive" + "Users/u1"), never "Users/u2".
	res, err := mgr.ScanDuplicates(context.Background(), DuplicateScanOptions{
		Roots:        []string{"Archive", "Users/u1"},
		MinSizeBytes: 4096,
		MaxGroups:    50,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalGroups != 2 || len(res.Groups) != 2 {
		t.Fatalf("expected 2 duplicate groups (report pair + clone pair), got %+v", res)
	}

	// Group 0 is larger (280,000 bytes): u1Orig + u1Copy (NEVER u2Secret, NEVER sameSizeDiff, NEVER symlink).
	g0 := res.Groups[0]
	if g0.Count != 2 || g0.ReclaimableBytes != int64(len(payloadA)) || g0.ReclaimablePhysicalBytes != int64(len(payloadA)) {
		t.Fatalf("unexpected group 0 metrics: %+v", g0)
	}
	for _, it := range g0.Items {
		if it.Path == "Users/u2/Docs/u2_secret_copy.pdf" || it.Name == "other_same_size.pdf" || it.Name == "evil_symlink.pdf" {
			t.Fatalf("unauthorized or non-duplicate file leaked into group: %+v", it)
		}
	}

	// Group 1 is the APFS clone pair (252,000 bytes).
	g1 := res.Groups[1]
	if g1.Count != 2 || g1.ReclaimableBytes != int64(len(clonePayload)) {
		t.Fatalf("unexpected group 1 clone group: %+v", g1)
	}
	if clonedOK {
		if !g1.AllAPFSClones || g1.ReclaimablePhysicalBytes != 0 {
			t.Fatalf("expected APFS clone detection (AllAPFSClones=true, ReclaimablePhysicalBytes=0), got %+v", g1)
		}
	}
}
