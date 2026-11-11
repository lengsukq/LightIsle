package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

type duplicateItemResponse struct {
	files.DuplicateFileItem
	CanTrash bool `json:"canTrash"`
}

type duplicateGroupResponse struct {
	GroupID                  string                  `json:"groupId"`
	SHA256                   string                  `json:"sha256,omitempty"`
	Size                     int64                   `json:"size"`
	Count                    int                     `json:"count"`
	ReclaimableBytes         int64                   `json:"reclaimableBytes"`
	ReclaimablePhysicalBytes int64                   `json:"reclaimablePhysicalBytes"`
	AllAPFSClones            bool                    `json:"allApfsClones,omitempty"`
	Items                    []duplicateItemResponse `json:"items"`
}

type duplicateResultResponse struct {
	MinSizeBytes                  int64                    `json:"minSizeBytes"`
	ScannedFiles                  int                      `json:"scannedFiles"`
	TotalGroups                   int                      `json:"totalGroups"`
	TotalReclaimableBytes         int64                    `json:"totalReclaimableBytes"`
	TotalReclaimablePhysicalBytes int64                    `json:"totalReclaimablePhysicalBytes"`
	Truncated                     bool                     `json:"truncated,omitempty"`
	Groups                        []duplicateGroupResponse `json:"groups"`
}

type duplicateScanSnapshot struct {
	Running          bool                         `json:"running"`
	Progress         *files.DuplicateScanProgress `json:"progress,omitempty"`
	LastDone         int64                        `json:"lastDone,omitempty"`
	LastError        string                       `json:"lastError,omitempty"`
	Result           *duplicateResultResponse     `json:"result,omitempty"`
	QuotaReleaseNote string                       `json:"quotaReleaseNote"`
}

type activeDuplicateJob struct {
	userID int64
	role   string
	cancel context.CancelFunc
	done   chan struct{}
}

type storedDuplicateState struct {
	running   bool
	progress  *files.DuplicateScanProgress
	lastDone  int64
	lastError string
	rawResult *files.DuplicateScanResult
}

type duplicateScanStore struct {
	mu          sync.Mutex
	rootRunning map[string]*activeDuplicateJob
	byUserRoot  map[string]storedDuplicateState
}

func newDuplicateScanStore() *duplicateScanStore {
	return &duplicateScanStore{
		rootRunning: make(map[string]*activeDuplicateJob),
		byUserRoot:  make(map[string]storedDuplicateState),
	}
}

func duplicateRootGenKey(rootID string, generation uint64) string {
	return rootID + "#" + strconv.FormatUint(generation, 10)
}

func duplicateStoreKey(rootID string, generation uint64, userID int64) string {
	return duplicateRootGenKey(rootID, generation) + "|" + strconv.FormatInt(userID, 10)
}

func (s *duplicateScanStore) tryBegin(rootID string, generation uint64, userID int64, role string) (context.Context, <-chan struct{}, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rkey := duplicateRootGenKey(rootID, generation)
	if s.rootRunning[rkey] != nil {
		return nil, nil, false
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	s.rootRunning[rkey] = &activeDuplicateJob{
		userID: userID,
		role:   role,
		cancel: cancel,
		done:   done,
	}
	ukey := duplicateStoreKey(rootID, generation, userID)
	prev := s.byUserRoot[ukey]
	prev.running = true
	prev.lastError = ""
	prev.progress = &files.DuplicateScanProgress{Phase: "walking"}
	s.byUserRoot[ukey] = prev
	return ctx, done, true
}

func (s *duplicateScanStore) updateProgress(rootID string, generation uint64, userID int64, p files.DuplicateScanProgress) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ukey := duplicateStoreKey(rootID, generation, userID)
	cur := s.byUserRoot[ukey]
	cp := p
	cur.progress = &cp
	s.byUserRoot[ukey] = cur
}

func (s *duplicateScanStore) finish(rootID string, generation uint64, userID int64, raw *files.DuplicateScanResult, scanErr error) {
	s.mu.Lock()
	rkey := duplicateRootGenKey(rootID, generation)
	job := s.rootRunning[rkey]
	delete(s.rootRunning, rkey)
	ukey := duplicateStoreKey(rootID, generation, userID)
	cur := s.byUserRoot[ukey]
	cur.running = false
	cur.progress = nil
	if scanErr != nil {
		if errors.Is(scanErr, context.Canceled) {
			cur.lastError = "cancelled"
		} else {
			cur.lastError = scanErr.Error()
		}
	} else {
		cur.lastError = ""
		cur.lastDone = time.Now().Unix()
		cur.rawResult = raw
	}
	s.byUserRoot[ukey] = cur
	s.mu.Unlock()
	if job != nil {
		job.cancel()
		close(job.done)
	}
}

func (s *duplicateScanStore) cancelRoot(rootID string, generation uint64, callerID int64, isAdmin bool) (bool, bool) {
	s.mu.Lock()
	rkey := duplicateRootGenKey(rootID, generation)
	job := s.rootRunning[rkey]
	if job == nil {
		s.mu.Unlock()
		return false, true
	}
	if !isAdmin && job.userID != callerID {
		s.mu.Unlock()
		return true, false
	}
	cancel := job.cancel
	done := job.done
	s.mu.Unlock()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
	return true, true
}

func (s *duplicateScanStore) cancelAll() {
	if s == nil {
		return
	}
	s.mu.Lock()
	jobs := make([]*activeDuplicateJob, 0, len(s.rootRunning))
	for _, j := range s.rootRunning {
		if j != nil {
			jobs = append(jobs, j)
		}
	}
	s.mu.Unlock()
	for _, j := range jobs {
		j.cancel()
	}
	for _, j := range jobs {
		<-j.done
	}
}

func (s *duplicateScanStore) snapshot(
	rootID string,
	generation uint64,
	userID int64,
	canRead func(string) bool,
	canWrite func(string) bool,
) duplicateScanSnapshot {
	s.mu.Lock()
	st, ok := s.byUserRoot[duplicateStoreKey(rootID, generation, userID)]
	var progCopy *files.DuplicateScanProgress
	if st.progress != nil {
		cp := *st.progress
		progCopy = &cp
	}
	var rawCopy *files.DuplicateScanResult
	if st.rawResult != nil {
		cp := *st.rawResult
		cp.Groups = append([]files.DuplicateFileGroup(nil), st.rawResult.Groups...)
		rawCopy = &cp
	}
	s.mu.Unlock()

	if !ok {
		return duplicateScanSnapshot{QuotaReleaseNote: quotaTrashReleaseNote}
	}
	out := duplicateScanSnapshot{
		Running:          st.running,
		Progress:         progCopy,
		LastDone:         st.lastDone,
		LastError:        st.lastError,
		QuotaReleaseNote: quotaTrashReleaseNote,
	}
	if rawCopy != nil {
		decorated := decorateDuplicateResult(*rawCopy, canRead, canWrite)
		out.Result = &decorated
	}
	return out
}

func (s *duplicateScanStore) pruneTrashedPaths(rootID string, generation uint64, userID int64, removed map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ukey := duplicateStoreKey(rootID, generation, userID)
	st, ok := s.byUserRoot[ukey]
	if !ok || st.rawResult == nil {
		return
	}
	var keptGroups []files.DuplicateFileGroup
	var totalReclaim, totalPhys int64
	for _, g := range st.rawResult.Groups {
		var items []files.DuplicateFileItem
		for _, it := range g.Items {
			if !removed[it.Path] {
				items = append(items, it)
			}
		}
		if len(items) < 2 {
			continue
		}
		g.Items = items
		g.Count = len(items)
		g.ReclaimableBytes = int64(len(items)-1) * g.Size
		if g.AllAPFSClones {
			g.ReclaimablePhysicalBytes = 0
		} else if g.ReclaimablePhysicalBytes > g.ReclaimableBytes {
			g.ReclaimablePhysicalBytes = g.ReclaimableBytes
		}
		totalReclaim += g.ReclaimableBytes
		totalPhys += g.ReclaimablePhysicalBytes
		keptGroups = append(keptGroups, g)
	}
	if keptGroups == nil {
		keptGroups = []files.DuplicateFileGroup{}
	}
	cp := *st.rawResult
	cp.Groups = keptGroups
	cp.TotalGroups = len(keptGroups)
	cp.TotalReclaimableBytes = totalReclaim
	cp.TotalReclaimablePhysicalBytes = totalPhys
	st.rawResult = &cp
	s.byUserRoot[ukey] = st
}

func (a *API) currentRootGeneration() uint64 {
	if a.rootRuntime != nil {
		return a.rootRuntime.root.Generation
	}
	return 0
}

func (a *API) duplicatesStatus(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	session := token(r)
	viewer, ok := a.auth.Identity(session)
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	if a.duplicateScans == nil {
		jsonReply(w, http.StatusOK, duplicateScanSnapshot{QuotaReleaseNote: quotaTrashReleaseNote})
		return
	}
	snap := a.duplicateScans.snapshot(
		a.rootID,
		a.currentRootGeneration(),
		viewer.ID,
		func(p string) bool { return a.canAccess(session, p, false, false) },
		func(p string) bool { return a.canAccess(session, p, true, false) },
	)
	jsonReply(w, http.StatusOK, snap)
}

func (a *API) duplicatesCancel(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	session := token(r)
	viewer, ok := a.auth.Identity(session)
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	if a.duplicateScans == nil {
		jsonReply(w, http.StatusOK, map[string]bool{"cancelled": false})
		return
	}
	found, allowed := a.duplicateScans.cancelRoot(
		a.rootID,
		a.currentRootGeneration(),
		viewer.ID,
		viewer.Role == auth.RoleAdmin,
	)
	if !allowed {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"cancelled": found})
}

func (a *API) duplicatesScan(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	scanner, ok := a.files.(interface {
		ScanDuplicates(context.Context, files.DuplicateScanOptions) (files.DuplicateScanResult, error)
	})
	if !ok {
		a.fileUnavailable(w)
		return
	}
	session := token(r)
	viewer, authenticated := a.auth.Identity(session)
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}

	var body struct {
		Path         string `json:"path"`
		MinSizeBytes int64  `json:"minSizeBytes"`
		MaxGroups    int    `json:"maxGroups"`
		Async        bool   `json:"async"`
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, 2048)
		defer r.Body.Close()
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
	}
	if r.URL.Query().Get("async") == "1" {
		body.Async = true
	}
	base := strings.TrimSpace(body.Path)
	if base == "" {
		base = "."
	}
	if a.auth == nil || !a.canSee(session, base) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		return
	}
	scanRoots, err := a.searchRoots(session, base)
	if err != nil || len(scanRoots) == 0 {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		return
	}

	gen := a.currentRootGeneration()
	if a.duplicateScans == nil {
		rawRes, scanErr := scanner.ScanDuplicates(r.Context(), files.DuplicateScanOptions{
			Roots:        scanRoots,
			MinSizeBytes: body.MinSizeBytes,
			MaxGroups:    body.MaxGroups,
		})
		if scanErr != nil {
			fileError(w, scanErr)
			return
		}
		decorated := decorateDuplicateResult(
			rawRes,
			func(p string) bool { return a.canAccess(session, p, false, false) },
			func(p string) bool { return a.canAccess(session, p, true, false) },
		)
		jsonReply(w, http.StatusOK, duplicateScanSnapshot{
			LastDone:         time.Now().Unix(),
			Result:           &decorated,
			QuotaReleaseNote: quotaTrashReleaseNote,
		})
		return
	}

	var bgLease *roots.Lease
	runtime := a.rootRuntime
	rootSrv := a.rootServer
	rootID := a.rootID
	if rootSrv != nil && runtime != nil && rootID != "" {
		acquired, leaseErr := rootSrv.registry.Acquire(context.Background(), rootID)
		if leaseErr != nil {
			rootError(w, leaseErr)
			return
		}
		bgLease = acquired
	}

	jobCtx, doneCh, started := a.duplicateScans.tryBegin(rootID, gen, viewer.ID, viewer.Role)
	if !started {
		if bgLease != nil {
			_ = bgLease.Close()
		}
		jsonReply(w, http.StatusConflict, map[string]string{"error": "scan_running"})
		return
	}

	if runtime != nil && bgLease != nil {
		runtime.scanMu.Lock()
		runtime.scans["duplicates"] = bgLease
		runtime.scanWG.Add(1)
		runtime.scanMu.Unlock()
	}

	store := a.duplicateScans
	minSize := body.MinSizeBytes
	maxGroups := body.MaxGroups
	go func() {
		defer func() {
			if runtime != nil && bgLease != nil && rootSrv != nil {
				rootSrv.mu.Lock()
				runtime.scanMu.Lock()
				if runtime.scans["duplicates"] == bgLease {
					delete(runtime.scans, "duplicates")
				}
				_ = bgLease.Close()
				runtime.lastUsed = time.Now()
				runtime.scanMu.Unlock()
				rootSrv.mu.Unlock()
				runtime.scanWG.Done()
			} else if bgLease != nil {
				_ = bgLease.Close()
			}
		}()
		rawRes, scanErr := scanner.ScanDuplicates(jobCtx, files.DuplicateScanOptions{
			Roots:        scanRoots,
			MinSizeBytes: minSize,
			MaxGroups:    maxGroups,
			OnProgress: func(p files.DuplicateScanProgress) {
				store.updateProgress(rootID, gen, viewer.ID, p)
			},
		})
		if scanErr != nil {
			store.finish(rootID, gen, viewer.ID, nil, scanErr)
			return
		}
		store.finish(rootID, gen, viewer.ID, &rawRes, nil)
	}()

	canRead := func(p string) bool { return a.canAccess(session, p, false, false) }
	canWrite := func(p string) bool { return a.canAccess(session, p, true, false) }

	if body.Async {
		snap := store.snapshot(rootID, gen, viewer.ID, canRead, canWrite)
		status := http.StatusAccepted
		if !snap.Running {
			status = http.StatusOK
		}
		jsonReply(w, status, snap)
		return
	}

	// Hybrid fast-path: wait briefly so small/medium scans and synchronous callers
	// finish in a single round-trip, while large multi-GiB disk scans hand off with
	// 202 Accepted before any client/reverse-proxy timeout can abort the job.
	timer := time.NewTimer(1500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-doneCh:
		snap := store.snapshot(rootID, gen, viewer.ID, canRead, canWrite)
		if snap.LastError != "" && snap.LastError != "cancelled" && snap.Result == nil {
			fileError(w, errors.New(snap.LastError))
			return
		}
		jsonReply(w, http.StatusOK, snap)
	case <-timer.C:
		snap := store.snapshot(rootID, gen, viewer.ID, canRead, canWrite)
		status := http.StatusAccepted
		if !snap.Running {
			status = http.StatusOK
		}
		jsonReply(w, status, snap)
	case <-r.Context().Done():
		// Client disconnected; keep background job alive so status polling can pick it up.
	}
}

func decorateDuplicateResult(
	raw files.DuplicateScanResult,
	canRead func(string) bool,
	canWrite func(string) bool,
) duplicateResultResponse {
	groups := make([]duplicateGroupResponse, 0, len(raw.Groups))
	var totalReclaim, totalPhys int64
	for _, g := range raw.Groups {
		items := make([]duplicateItemResponse, 0, len(g.Items))
		for _, it := range g.Items {
			if canRead != nil && !canRead(it.Path) {
				continue
			}
			items = append(items, duplicateItemResponse{
				DuplicateFileItem: it,
				CanTrash:          canWrite(it.Path),
			})
		}
		if len(items) < 2 {
			continue
		}
		reclaim := int64(len(items)-1) * g.Size
		phys := g.ReclaimablePhysicalBytes
		if g.AllAPFSClones {
			phys = 0
		} else if phys > reclaim {
			phys = reclaim
		}
		totalReclaim += reclaim
		totalPhys += phys
		groups = append(groups, duplicateGroupResponse{
			GroupID:                  g.GroupID,
			SHA256:                   g.SHA256,
			Size:                     g.Size,
			Count:                    len(items),
			ReclaimableBytes:         reclaim,
			ReclaimablePhysicalBytes: phys,
			AllAPFSClones:            g.AllAPFSClones,
			Items:                    items,
		})
	}
	return duplicateResultResponse{
		MinSizeBytes:                  raw.MinSizeBytes,
		ScannedFiles:                  raw.ScannedFiles,
		TotalGroups:                   len(groups),
		TotalReclaimableBytes:         totalReclaim,
		TotalReclaimablePhysicalBytes: totalPhys,
		Truncated:                     raw.Truncated,
		Groups:                        groups,
	}
}

func (a *API) duplicatesTrash(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	defer r.Body.Close()

	type trashTarget struct {
		Path     string `json:"path"`
		Size     int64  `json:"size"`
		Identity string `json:"identity"`
	}
	type groupTrashReq struct {
		KeepPath   string        `json:"keepPath"`
		TrashItems []trashTarget `json:"trashItems"`
	}
	var body struct {
		Groups []groupTrashReq `json:"groups"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || len(body.Groups) == 0 || len(body.Groups) > 50 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	type verifiedMove struct {
		relPath string
		info    os.FileInfo
	}
	var moves []verifiedMove
	seenMove := make(map[string]bool)

	for _, grp := range body.Groups {
		keep := strings.TrimSpace(grp.KeepPath)
		if keep == "" || keep == "." || path.Clean(keep) == "." || strings.HasPrefix(keep, ".lightisle-") || len(grp.TrashItems) == 0 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "must_keep_one_file"})
			return
		}
		if !a.allowFile(w, r, keep, false) {
			return
		}
		keepInfo, err := a.files.Stat(keep)
		if err != nil || !keepInfo.Mode().IsRegular() {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_rescan_required"})
			return
		}

		for _, item := range grp.TrashItems {
			clean := strings.TrimSpace(item.Path)
			if clean == "" || clean == "." || path.Clean(clean) == "." || strings.HasPrefix(clean, ".lightisle-") {
				jsonReply(w, http.StatusBadRequest, map[string]string{"error": "path_not_allowed"})
				return
			}
			if path.Clean(clean) == path.Clean(keep) {
				jsonReply(w, http.StatusBadRequest, map[string]string{"error": "must_keep_one_file"})
				return
			}
			if seenMove[clean] {
				continue
			}
			if len(moves) >= 100 {
				jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
				return
			}
			if !a.allowFile(w, r, clean, true) {
				return
			}
			info, err := a.files.Stat(clean)
			if err != nil || !info.Mode().IsRegular() {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_rescan_required"})
				return
			}
			if item.Size <= 0 || info.Size() != item.Size || item.Identity == "" || files.MediaFileIdentity(info) != item.Identity {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_rescan_required"})
				return
			}
			seenMove[clean] = true
			moves = append(moves, verifiedMove{relPath: clean, info: info})
		}
	}

	guarded, hasGuarded := a.files.(interface {
		MoveToTrashIfUnchanged(string, os.FileInfo) error
	})
	removedPaths := make(map[string]bool, len(moves))
	var stagedBytes int64
	for _, mv := range moves {
		var err error
		if hasGuarded {
			err = guarded.MoveToTrashIfUnchanged(mv.relPath, mv.info)
		} else {
			err = a.files.MoveToTrash(mv.relPath)
		}
		if err != nil {
			fileError(w, err)
			return
		}
		removedPaths[mv.relPath] = true
		stagedBytes += mv.info.Size()
		if a.rootServer != nil {
			a.rootServer.QueueMediaRefresh(a.rootID, mv.relPath)
		}
	}
	if a.duplicateScans != nil {
		a.duplicateScans.pruneTrashedPaths(a.rootID, a.currentRootGeneration(), viewer.ID, removedPaths)
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"trashed":          len(removedPaths),
		"stagedTrashBytes": stagedBytes,
		"quotaReleaseNote": quotaTrashReleaseNote,
	})
}
