package files

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"path"
	"sort"
	"strings"
)

const (
	DefaultDuplicateMinBytes = 1 << 20 // 1 MiB default threshold for large duplicate files
	MinDuplicateMinBytes     = 4096    // 4 KiB floor
	MaxDuplicateGroups       = 200
	DefaultDuplicateGroups   = 100
	maxDuplicateCandidates   = 50000
	duplicateSampleChunk     = 64 << 10 // 64 KiB head / middle / tail sample
)

type DuplicateScanOptions struct {
	Roots        []string
	MinSizeBytes int64
	MaxGroups    int
	OnProgress   func(DuplicateScanProgress)
}

type DuplicateScanProgress struct {
	Phase          string `json:"phase"`
	ScannedFiles   int    `json:"scannedFiles"`
	CandidateFiles int    `json:"candidateFiles"`
	HashedBytes    int64  `json:"hashedBytes"`
}

type DuplicateFileItem struct {
	Path        string `json:"path"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	Modified    int64  `json:"modified"`
	ModifiedNs  int64  `json:"-"`
	Identity    string `json:"identity"`
	IsAPFSClone bool   `json:"isApfsClone,omitempty"`
	IsHardlink  bool   `json:"isHardlink,omitempty"`
}

type DuplicateFileGroup struct {
	GroupID                  string              `json:"groupId"`
	SHA256                   string              `json:"sha256,omitempty"`
	Size                     int64               `json:"size"`
	Count                    int                 `json:"count"`
	ReclaimableBytes         int64               `json:"reclaimableBytes"`
	ReclaimablePhysicalBytes int64               `json:"reclaimablePhysicalBytes"`
	AllAPFSClones            bool                `json:"allApfsClones,omitempty"`
	Items                    []DuplicateFileItem `json:"items"`
}

type DuplicateScanResult struct {
	MinSizeBytes                  int64                `json:"minSizeBytes"`
	ScannedFiles                  int                  `json:"scannedFiles"`
	TotalGroups                   int                  `json:"totalGroups"`
	TotalReclaimableBytes         int64                `json:"totalReclaimableBytes"`
	TotalReclaimablePhysicalBytes int64                `json:"totalReclaimablePhysicalBytes"`
	Truncated                     bool                 `json:"truncated,omitempty"`
	Groups                        []DuplicateFileGroup `json:"groups"`
}

type dupCandidate struct {
	relPath    string
	name       string
	size       int64
	modifiedNs int64
	identity   string
	clone      apfsCloneInfo
}

// ScanDuplicates executes a 4-stage duplicate file scan strictly inside the
// caller-authorized roots:
//  1. Size bucketing (discarding unique file sizes with 0 file reads)
//  2. APFS CoW clone / hardlink coalescing via fgetattrlist (0 file reads when pure clones)
//  3. 3x64 KiB head/mid/tail sparse sample SHA-256
//  4. Streaming full-content SHA-256 with pre/post MediaFileIdentity verification
func (m *Manager) ScanDuplicates(ctx context.Context, opts DuplicateScanOptions) (DuplicateScanResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	minBytes := opts.MinSizeBytes
	if minBytes <= 0 {
		minBytes = DefaultDuplicateMinBytes
	}
	if minBytes < MinDuplicateMinBytes {
		minBytes = MinDuplicateMinBytes
	}
	maxGroups := opts.MaxGroups
	if maxGroups <= 0 || maxGroups > MaxDuplicateGroups {
		maxGroups = DefaultDuplicateGroups
	}
	roots := deduplicateRoots(opts.Roots)
	if len(roots) == 0 {
		return DuplicateScanResult{MinSizeBytes: minBytes, Groups: []DuplicateFileGroup{}}, nil
	}

	progress := DuplicateScanProgress{Phase: "walking"}
	report := func() {
		if opts.OnProgress != nil {
			opts.OnProgress(progress)
		}
	}

	sizeBuckets := make(map[int64][]dupCandidate)
	seenPaths := make(map[string]struct{})
	truncated := false

	for _, root := range roots {
		if err := ctx.Err(); err != nil {
			return DuplicateScanResult{}, err
		}
		if err := m.walkDuplicatesSubtree(ctx, root, minBytes, seenPaths, sizeBuckets, &progress, &truncated, report); err != nil {
			return DuplicateScanResult{}, err
		}
		if truncated {
			break
		}
	}

	// Stage 1: Keep only size buckets with >= 2 distinct paths.
	var multiSizeKeys []int64
	candidateTotal := 0
	for sz, list := range sizeBuckets {
		if len(list) < 2 {
			delete(sizeBuckets, sz)
			continue
		}
		multiSizeKeys = append(multiSizeKeys, sz)
		candidateTotal += len(list)
	}
	// Process largest files first so partial progress surfaces high-value savings early.
	sort.Slice(multiSizeKeys, func(i, j int) bool { return multiSizeKeys[i] > multiSizeKeys[j] })
	progress.CandidateFiles = candidateTotal
	progress.Phase = "sampling"
	report()

	var allGroups []DuplicateFileGroup
	for _, sz := range multiSizeKeys {
		if err := ctx.Err(); err != nil {
			return DuplicateScanResult{}, err
		}
		groups, hashedBytes, err := m.resolveSizeBucket(ctx, sz, sizeBuckets[sz])
		if err != nil {
			return DuplicateScanResult{}, err
		}
		if hashedBytes > 0 {
			progress.Phase = "hashing"
			progress.HashedBytes += hashedBytes
			report()
		}
		allGroups = append(allGroups, groups...)
	}

	sort.Slice(allGroups, func(i, j int) bool {
		if allGroups[i].ReclaimableBytes == allGroups[j].ReclaimableBytes {
			return allGroups[i].Size > allGroups[j].Size
		}
		return allGroups[i].ReclaimableBytes > allGroups[j].ReclaimableBytes
	})

	var totalLogical, totalPhysical int64
	for _, g := range allGroups {
		totalLogical += g.ReclaimableBytes
		totalPhysical += g.ReclaimablePhysicalBytes
	}
	totalGroupCount := len(allGroups)
	if len(allGroups) > maxGroups {
		allGroups = allGroups[:maxGroups]
		truncated = true
	}
	if allGroups == nil {
		allGroups = []DuplicateFileGroup{}
	}
	progress.Phase = "done"
	report()

	return DuplicateScanResult{
		MinSizeBytes:                  minBytes,
		ScannedFiles:                  progress.ScannedFiles,
		TotalGroups:                   totalGroupCount,
		TotalReclaimableBytes:         totalLogical,
		TotalReclaimablePhysicalBytes: totalPhysical,
		Truncated:                     truncated,
		Groups:                        allGroups,
	}, nil
}

func (m *Manager) walkDuplicatesSubtree(
	ctx context.Context,
	startDir string,
	minBytes int64,
	seenPaths map[string]struct{},
	sizeBuckets map[int64][]dupCandidate,
	progress *DuplicateScanProgress,
	truncated *bool,
	report func(),
) error {
	queue := []string{startDir}
	totalCandidates := 0
	for _, list := range sizeBuckets {
		totalCandidates += len(list)
	}
	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		dir := queue[0]
		queue = queue[1:]
		err := m.ScanDirectory(ctx, dir, func(entries []Entry) error {
			for _, e := range entries {
				if e.Type == "folder" {
					queue = append(queue, e.Path)
					continue
				}
				if e.Type != "file" {
					continue
				}
				progress.ScannedFiles++
				if progress.ScannedFiles%250 == 0 {
					report()
				}
				if e.Size < minBytes || e.Identity == "" {
					continue
				}
				if _, dup := seenPaths[e.Path]; dup {
					continue
				}
				if totalCandidates >= maxDuplicateCandidates {
					*truncated = true
					return nil
				}
				seenPaths[e.Path] = struct{}{}
				totalCandidates++
				sizeBuckets[e.Size] = append(sizeBuckets[e.Size], dupCandidate{
					relPath:    e.Path,
					name:       e.Name,
					size:       e.Size,
					modifiedNs: e.Modified.UnixNano(),
					identity:   e.Identity,
				})
			}
			return nil
		})
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// Missing optional default media/user root or transient directory change in another folder: skip subtree cleanly.
			continue
		}
		if *truncated {
			return nil
		}
	}
	return nil
}

type cloneFamily struct {
	members []dupCandidate
}

func (m *Manager) resolveSizeBucket(ctx context.Context, size int64, items []dupCandidate) ([]DuplicateFileGroup, int64, error) {
	// Enrich candidates with APFS clone / hardlink metadata via open FD.
	valid := make([]dupCandidate, 0, len(items))
	for _, item := range items {
		if err := ctx.Err(); err != nil {
			return nil, 0, err
		}
		f, info, err := m.Read(item.relPath)
		if err != nil {
			continue
		}
		if !info.Mode().IsRegular() || info.Size() != item.size || MediaFileIdentity(info) != item.identity {
			_ = f.Close()
			continue
		}
		item.clone = inspectAPFSClone(f, info)
		item.modifiedNs = info.ModTime().UnixNano()
		_ = f.Close()
		valid = append(valid, item)
	}
	if len(valid) < 2 {
		return nil, 0, nil
	}

	// Stage 2: Coalesce pure APFS clones (privateSize == 0, same device & cloneID) and hardlinks (same device & inode).
	var families []cloneFamily
	cloneIdx := make(map[[2]uint64]int)
	inodeIdx := make(map[[2]uint64]int)

	for _, c := range valid {
		if c.clone.device != 0 && c.clone.inode != 0 {
			ikey := [2]uint64{c.clone.device, c.clone.inode}
			if idx, ok := inodeIdx[ikey]; ok {
				families[idx].members = append(families[idx].members, c)
				continue
			}
		}
		if c.clone.supported && c.clone.cloneID != 0 && c.clone.privateSize == 0 && c.clone.device != 0 {
			ckey := [2]uint64{c.clone.device, c.clone.cloneID}
			if idx, ok := cloneIdx[ckey]; ok {
				families[idx].members = append(families[idx].members, c)
				continue
			}
			idx := len(families)
			cloneIdx[ckey] = idx
			if c.clone.inode != 0 {
				inodeIdx[[2]uint64{c.clone.device, c.clone.inode}] = idx
			}
			families = append(families, cloneFamily{members: []dupCandidate{c}})
			continue
		}
		idx := len(families)
		if c.clone.device != 0 && c.clone.inode != 0 {
			inodeIdx[[2]uint64{c.clone.device, c.clone.inode}] = idx
		}
		families = append(families, cloneFamily{members: []dupCandidate{c}})
	}

	// Fast path: every candidate in this size bucket belongs to a single kernel-verified APFS clone / hardlink family!
	// Zero bytes of file content need to be read from disk!
	if len(families) == 1 {
		group := buildDuplicateGroup("", size, families[0].members)
		return []DuplicateFileGroup{group}, 0, nil
	}

	// Stage 3: Compute 3x64 KiB sample hash on 1 representative per family (for files > 3*64 KiB).
	var hashedBytes int64
	sampleBuckets := make(map[string][]cloneFamily)
	if size <= 3*duplicateSampleChunk {
		sampleBuckets["small"] = families
	} else {
		for _, fam := range families {
			if err := ctx.Err(); err != nil {
				return nil, hashedBytes, err
			}
			rep := fam.members[0]
			sh, nBytes, ok := m.sampleHashCandidate(rep)
			hashedBytes += nBytes
			if !ok {
				continue
			}
			sampleBuckets[sh] = append(sampleBuckets[sh], fam)
		}
	}

	// Stage 4: Full streaming SHA-256 only where >= 2 distinct families share a sample hash (or a single family itself has >= 2 clones).
	var groups []DuplicateFileGroup
	for _, fams := range sampleBuckets {
		if len(fams) == 1 {
			if len(fams[0].members) >= 2 {
				groups = append(groups, buildDuplicateGroup("", size, fams[0].members))
			}
			continue
		}
		fullBuckets := make(map[string][]dupCandidate)
		for _, fam := range fams {
			if err := ctx.Err(); err != nil {
				return nil, hashedBytes, err
			}
			rep := fam.members[0]
			digest, nBytes, ok := m.fullHashCandidate(ctx, rep)
			hashedBytes += nBytes
			if !ok {
				continue
			}
			fullBuckets[digest] = append(fullBuckets[digest], fam.members...)
		}
		for digest, members := range fullBuckets {
			if len(members) >= 2 {
				groups = append(groups, buildDuplicateGroup(digest, size, members))
			}
		}
	}
	return groups, hashedBytes, nil
}

func (m *Manager) sampleHashCandidate(c dupCandidate) (string, int64, bool) {
	f, info, err := m.Read(c.relPath)
	if err != nil {
		return "", 0, false
	}
	defer f.Close()
	if !info.Mode().IsRegular() || info.Size() != c.size || MediaFileIdentity(info) != c.identity {
		return "", 0, false
	}
	h := sha256.New()
	buf := make([]byte, duplicateSampleChunk)
	var readTotal int64
	offsets := []int64{0, c.size/2 - duplicateSampleChunk/2, c.size - duplicateSampleChunk}
	for _, off := range offsets {
		if off < 0 {
			off = 0
		}
		n, err := f.ReadAt(buf, off)
		if n > 0 {
			_, _ = h.Write(buf[:n])
			readTotal += int64(n)
		}
		if err != nil && err != io.EOF {
			return "", readTotal, false
		}
	}
	after, err := f.Stat()
	if err != nil || after.Size() != c.size || MediaFileIdentity(after) != c.identity || after.ModTime().UnixNano() != info.ModTime().UnixNano() {
		return "", readTotal, false
	}
	return hex.EncodeToString(h.Sum(nil)), readTotal, true
}

func (m *Manager) fullHashCandidate(ctx context.Context, c dupCandidate) (string, int64, bool) {
	f, info, err := m.Read(c.relPath)
	if err != nil {
		return "", 0, false
	}
	defer f.Close()
	if !info.Mode().IsRegular() || info.Size() != c.size || MediaFileIdentity(info) != c.identity {
		return "", 0, false
	}
	h := sha256.New()
	buf := make([]byte, 256<<10)
	var readTotal int64
	for {
		if ctx.Err() != nil {
			return "", readTotal, false
		}
		n, readErr := f.Read(buf)
		if n > 0 {
			_, _ = h.Write(buf[:n])
			readTotal += int64(n)
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return "", readTotal, false
		}
	}
	after, err := f.Stat()
	if err != nil || readTotal != c.size || after.Size() != c.size || MediaFileIdentity(after) != c.identity || after.ModTime().UnixNano() != info.ModTime().UnixNano() {
		return "", readTotal, false
	}
	return hex.EncodeToString(h.Sum(nil)), readTotal, true
}

func buildDuplicateGroup(digest string, size int64, members []dupCandidate) DuplicateFileGroup {
	// Deterministic ordering: shortest path first, then oldest modified first, then lexicographical path.
	sort.Slice(members, func(i, j int) bool {
		if len(members[i].relPath) != len(members[j].relPath) {
			return len(members[i].relPath) < len(members[j].relPath)
		}
		if members[i].modifiedNs != members[j].modifiedNs {
			return members[i].modifiedNs < members[j].modifiedNs
		}
		return members[i].relPath < members[j].relPath
	})

	inodeCount := make(map[[2]uint64]int)
	cloneCount := make(map[[2]uint64]int)
	for _, m := range members {
		if m.clone.device != 0 && m.clone.inode != 0 {
			inodeCount[[2]uint64{m.clone.device, m.clone.inode}]++
		}
		if m.clone.supported && m.clone.cloneID != 0 && m.clone.privateSize == 0 {
			cloneCount[[2]uint64{m.clone.device, m.clone.cloneID}]++
		}
	}

	items := make([]DuplicateFileItem, len(members))
	seenInodes := make(map[[2]uint64]bool)
	seenPureClones := make(map[[2]uint64]bool)
	var physicalUnits int
	allClones := true

	for i, m := range members {
		isHardlink := m.clone.nlink > 1 || (m.clone.device != 0 && inodeCount[[2]uint64{m.clone.device, m.clone.inode}] > 1)
		isClone := m.clone.supported && m.clone.cloneID != 0 && m.clone.privateSize == 0 &&
			(m.clone.cloneRefCnt > 1 || cloneCount[[2]uint64{m.clone.device, m.clone.cloneID}] > 1)
		if !isClone {
			allClones = false
		}
		items[i] = DuplicateFileItem{
			Path:        m.relPath,
			Name:        path.Base(m.relPath),
			Size:        m.size,
			Modified:    m.modifiedNs / 1_000_000_000,
			ModifiedNs:  m.modifiedNs,
			Identity:    m.identity,
			IsAPFSClone: isClone,
			IsHardlink:  isHardlink,
		}

		// Count distinct physical storage allocations across this duplicate group.
		if m.clone.device != 0 && m.clone.inode != 0 {
			ik := [2]uint64{m.clone.device, m.clone.inode}
			if seenInodes[ik] {
				continue
			}
			seenInodes[ik] = true
		}
		if isClone && m.clone.device != 0 {
			ck := [2]uint64{m.clone.device, m.clone.cloneID}
			if seenPureClones[ck] {
				continue
			}
			seenPureClones[ck] = true
		}
		physicalUnits++
	}

	reclaimLogical := int64(len(members)-1) * size
	var reclaimPhysical int64
	if physicalUnits > 1 {
		reclaimPhysical = int64(physicalUnits-1) * size
	}
	groupID := digest
	if groupID == "" {
		sum := sha256.Sum256([]byte(fmt.Sprintf("%d:%s", size, members[0].identity)))
		groupID = "clone-" + hex.EncodeToString(sum[:8])
	} else if len(groupID) > 16 {
		groupID = "sha-" + groupID[:16]
	}

	return DuplicateFileGroup{
		GroupID:                  groupID,
		SHA256:                   digest,
		Size:                     size,
		Count:                    len(members),
		ReclaimableBytes:         reclaimLogical,
		ReclaimablePhysicalBytes: reclaimPhysical,
		AllAPFSClones:            allClones,
		Items:                    items,
	}
}

func deduplicateRoots(raw []string) []string {
	var clean []string
	for _, r := range raw {
		trimmed := strings.Trim(strings.TrimSpace(r), "/")
		if trimmed == "" || trimmed == "." {
			return []string{"."}
		}
		clean = append(clean, path.Clean(trimmed))
	}
	sort.Slice(clean, func(i, j int) bool { return len(clean[i]) < len(clean[j]) })
	var out []string
	for _, r := range clean {
		covered := false
		for _, parent := range out {
			if r == parent || strings.HasPrefix(r, parent+"/") {
				covered = true
				break
			}
		}
		if !covered {
			out = append(out, r)
		}
	}
	return out
}
