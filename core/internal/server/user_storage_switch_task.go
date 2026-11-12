package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"math"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

type storageSwitchProgress struct {
	SwitchUserStorageResponse
	committed     bool
	StageIdentity string                             `json:"stageIdentity,omitempty"`
	Verified      map[string]files.StorageSwitchTree `json:"verified,omitempty"`
	Published     map[string]files.StorageSwitchTree `json:"published,omitempty"`
	AlbumLinks    []auth.StorageSwitchAlbumLink      `json:"albumLinks,omitempty"`
	Reserved      bool                               `json:"reserved,omitempty"`
	Publishing    bool                               `json:"publishing,omitempty"`
}

// Exact controlled symlink targets can be safely retried after an interrupted
// commit. Remove never unlinks a replaced real file or arbitrary symlink.
func (s *RootServer) cleanupStorageSwitchAlbumLinks(ctx context.Context, req SwitchUserStorageRequest, source *RootServicesLease, progress *storageSwitchProgress) error {
	if len(progress.AlbumLinks) == 0 {
		return nil
	}
	if source == nil {
		lease, err := s.AcquireRootServices(ctx, req.SourceRootID)
		if err != nil {
			return err
		}
		defer lease.Close()
		source = lease
	}
	if source.Root.Generation != req.SourceGeneration || !source.Lease.Valid(ctx) {
		return errStorageRootGenChanged
	}
	cleaner, ok := source.Services.Files.(interface {
		RemoveControlledAlbumSymlink(string, string, string) error
	})
	if !ok {
		return files.ErrOffline
	}
	for _, link := range progress.AlbumLinks {
		if !source.Lease.Valid(ctx) {
			return errStorageRootGenChanged
		}
		if err := cleaner.RemoveControlledAlbumSymlink(link.MemberPhotos, link.LinkName, link.ExpectedTarget); err != nil {
			return err
		}
	}
	return nil
}

func validSwitchID(id string) bool {
	return len(id) == 32 && strings.Trim(id, "0123456789abcdef") == ""
}

func validateStorageSwitch(req *SwitchUserStorageRequest) error {
	if !validSwitchID(req.SourceRootID) || !validSwitchID(req.TargetRootID) ||
		req.SourceRootID == req.TargetRootID || req.SourceGeneration < 1 || req.TargetGeneration < 1 ||
		req.SourceGeneration > math.MaxInt64 || req.TargetGeneration > math.MaxInt64 ||
		req.TargetQuotaBytes != nil && (*req.TargetQuotaBytes < 0 || *req.TargetQuotaBytes > auth.MaxMemberQuotaBytes) {
		return auth.ErrInput
	}
	switch req.Mode {
	case "migrate", "move", "empty", "copy":
	default:
		return errStorageSwitchInvalidMode
	}
	if len(req.Categories) == 0 {
		return auth.ErrInput
	}
	for _, category := range req.Categories {
		switch category {
		case auth.StorageFiles, auth.StoragePhotos, auth.StorageVideos:
		default:
			return auth.ErrInput
		}
	}
	slices.Sort(req.Categories)
	req.Categories = slices.Compact(req.Categories)
	return nil
}

func (s *RootServer) saveSwitch(progress storageSwitchProgress) error {
	data, err := json.Marshal(progress)
	if err != nil {
		return err
	}
	return s.accounts.SaveStorageSwitchTask(progress.TaskID, data)
}

func (s *RootServer) normalizeLoadedSwitchTask(session string, native bool, userID int64, record auth.StorageSwitchTask) (SwitchUserStorageRequest, storageSwitchProgress, error) {
	var stored SwitchUserStorageRequest
	var progress storageSwitchProgress
	if err := json.Unmarshal(record.Request, &stored); err != nil {
		return stored, progress, err
	}
	if err := json.Unmarshal(record.Progress, &progress); err != nil {
		return stored, progress, err
	}
	progress.CanResume = progress.Publishing && !record.Committed
	if s.switchTaskID != progress.TaskID && (progress.Phase == "queued" || progress.Phase == "copying" || progress.Phase == "committing") {
		progress.Phase = "interrupted"
		progress.Error = "storage_switch_interrupted"
		if record.Committed {
			progress.Phase = "source_pending"
			if len(progress.TrashIDs) == 0 && len(progress.AlbumLinks) == 0 {
				policy, err := s.fetchStoragePolicy(session, native, userID)
				if err != nil {
					return stored, progress, err
				}
				binding := stored
				binding.SourceRootID, binding.SourceGeneration = stored.TargetRootID, stored.TargetGeneration
				if storageSwitchSourceMatches(policy, binding) {
					progress.Policy, progress.Phase, progress.Error, progress.ErrorDetail = policy, "completed", "", ""
				}
			}
		}
		if err := s.saveSwitch(progress); err != nil {
			return stored, progress, err
		}
	}
	progress.CanCancel = progress.Phase == "interrupted" && (!progress.Publishing || (!record.Committed && s.allSwitchCategoriesStillStaged(context.Background(), stored, progress)))
	return stored, progress, nil
}

func (s *RootServer) allSwitchCategoriesStillStaged(ctx context.Context, stored SwitchUserStorageRequest, progress storageSwitchProgress) bool {
	if progress.committed || progress.StageIdentity == "" || len(stored.Categories) == 0 {
		return false
	}
	lease, err := s.AcquireRootServices(ctx, stored.TargetRootID)
	if err != nil {
		return false
	}
	defer lease.Close()
	dst, ok := lease.Services.Files.(*files.Manager)
	if !ok || lease.Root.Generation != stored.TargetGeneration || !lease.Lease.Valid(ctx) {
		return false
	}
	for _, cat := range stored.Categories {
		if _, err := dst.StagedStorageSwitchTree(ctx, progress.TaskID, cat); err != nil {
			return false
		}
	}
	return true
}

func (s *RootServer) cancelUnpublishedSwitchTaskLocked(ctx context.Context, stored SwitchUserStorageRequest, progress *storageSwitchProgress) error {
	if progress.StageIdentity != "" {
		if lease, err := s.AcquireRootServices(ctx, stored.TargetRootID); err == nil {
			defer lease.Close()
			if manager, ok := lease.Services.Files.(*files.Manager); ok && lease.Root.Generation == stored.TargetGeneration && lease.Lease.Valid(ctx) {
				_ = manager.DiscardStorageSwitch(progress.TaskID, progress.StageIdentity)
			}
		}
	}
	if err := s.accounts.ReleaseStorageSwitch(progress.TaskID); err != nil {
		return err
	}
	progress.Phase, progress.ReadyToCleanup, progress.Verified, progress.Published = "cancelled", false, nil, nil
	progress.Error, progress.ErrorDetail = "", ""
	progress.Reserved, progress.Publishing, progress.CanCancel, progress.CanResume = false, false, false, false
	return s.saveSwitch(*progress)
}

func sameSwitchOperation(a, b SwitchUserStorageRequest) bool {
	if a.SourceRootID != b.SourceRootID || a.SourceGeneration != b.SourceGeneration ||
		a.TargetRootID != b.TargetRootID || a.TargetGeneration != b.TargetGeneration ||
		a.Mode != b.Mode || !slices.Equal(a.Categories, b.Categories) {
		return false
	}
	if (a.TargetQuotaBytes == nil) != (b.TargetQuotaBytes == nil) {
		return false
	}
	return a.TargetQuotaBytes == nil || *a.TargetQuotaBytes == *b.TargetQuotaBytes
}

func (s *RootServer) ExecuteSwitchUserStorage(ctx context.Context, session string, native bool, userID int64, req SwitchUserStorageRequest) (SwitchUserStorageResponse, error) {
	var empty SwitchUserStorageResponse
	if s == nil || s.accounts == nil || s.registry == nil {
		return empty, auth.ErrInput
	}
	if !native {
		user, ok := s.accounts.Identity(session)
		if !ok || user.Role != auth.RoleAdmin {
			return empty, auth.ErrForbidden
		}
	}
	if req.TaskID != "" && !validSwitchID(req.TaskID) {
		return empty, auth.ErrInput
	}
	s.switchMu.Lock()
	defer s.switchMu.Unlock()

	record, loadErr := s.accounts.LoadStorageSwitchTask(userID, req.TaskID)
	var progress storageSwitchProgress
	var stored SwitchUserStorageRequest
	if loadErr == nil {
		var err error
		stored, progress, err = s.normalizeLoadedSwitchTask(session, native, userID, record)
		if err != nil {
			return empty, err
		}
	} else if !errors.Is(loadErr, auth.ErrNotFound) {
		return empty, loadErr
	}

	if req.Phase != "" && req.Phase != "copy_and_verify" {
		return s.handleExplicitSwitchPhaseLocked(ctx, session, native, userID, req, record, loadErr, stored, progress)
	}
	if err := validateStorageSwitch(&req); err != nil {
		return empty, err
	}
	req.Phase = ""
	reqBytes, err := json.Marshal(req)
	if err != nil {
		return empty, err
	}
	if resp, handled, err := s.reconcilePriorSwitchTaskLocked(ctx, session, native, userID, req, reqBytes, record, loadErr, stored, &progress); handled || err != nil {
		return resp, err
	}
	if s.switchTaskID != "" {
		return empty, files.ErrRootBusy
	}
	return s.createAndStartNewSwitchTaskLocked(session, native, userID, req, reqBytes)
}

func (s *RootServer) handleExplicitSwitchPhaseLocked(
	ctx context.Context,
	session string,
	native bool,
	userID int64,
	req SwitchUserStorageRequest,
	record auth.StorageSwitchTask,
	loadErr error,
	stored SwitchUserStorageRequest,
	progress storageSwitchProgress,
) (SwitchUserStorageResponse, error) {
	var empty SwitchUserStorageResponse
	switch req.Phase {
	case "status":
		if errors.Is(loadErr, auth.ErrNotFound) {
			return empty, errStorageSwitchTaskMissing
		}
		return progress.SwitchUserStorageResponse, nil
	case "resume_publish":
		if req.TaskID == "" {
			return empty, auth.ErrInput
		}
		if loadErr != nil {
			return empty, loadErr
		}
		if !progress.CanResume || record.Committed || progress.Phase != "interrupted" {
			return progress.SwitchUserStorageResponse, nil
		}
		if s.switchTaskID != "" {
			return progress.SwitchUserStorageResponse, files.ErrRootBusy
		}
		progress.Phase, progress.Error, progress.ErrorDetail = "committing", "", ""
		return s.startStorageSwitch(session, native, userID, stored, progress)
	case "recover_source":
		if req.TaskID == "" {
			return empty, auth.ErrInput
		}
		if loadErr != nil {
			return empty, loadErr
		}
		if progress.Phase != "source_pending" || !record.Committed || (len(progress.TrashIDs) == 0 && len(progress.AlbumLinks) == 0) {
			return progress.SwitchUserStorageResponse, nil
		}
		if s.switchTaskID != "" {
			return progress.SwitchUserStorageResponse, files.ErrRootBusy
		}
		progress.committed, progress.Phase, progress.Error, progress.ErrorDetail = true, "committing", "", ""
		return s.startStorageSwitch(session, native, userID, stored, progress)
	case "cancel", "confirm_cleanup":
		if req.TaskID == "" {
			return empty, auth.ErrInput
		}
		if loadErr != nil {
			return empty, loadErr
		}
		if s.switchTaskID == req.TaskID {
			if req.Phase == "cancel" && (progress.Phase == "queued" || progress.Phase == "copying") {
				s.switchCancel()
			}
			return progress.SwitchUserStorageResponse, nil
		}
		if progress.Phase != "verified" && !(req.Phase == "cancel" && progress.Phase == "interrupted" && progress.CanCancel) {
			return progress.SwitchUserStorageResponse, nil
		}
		if s.switchTaskID != "" {
			return progress.SwitchUserStorageResponse, files.ErrRootBusy
		}
		if req.Phase == "cancel" {
			if err := s.cancelUnpublishedSwitchTaskLocked(ctx, stored, &progress); err != nil {
				return empty, err
			}
			return progress.SwitchUserStorageResponse, nil
		}
		progress.Phase = "committing"
		progress.ReadyToCleanup = false
		return s.startStorageSwitch(session, native, userID, stored, progress)
	default:
		return empty, auth.ErrInput
	}
}

func (s *RootServer) reconcilePriorSwitchTaskLocked(
	ctx context.Context,
	session string,
	native bool,
	userID int64,
	req SwitchUserStorageRequest,
	reqBytes []byte,
	record auth.StorageSwitchTask,
	loadErr error,
	stored SwitchUserStorageRequest,
	progress *storageSwitchProgress,
) (SwitchUserStorageResponse, bool, error) {
	var empty SwitchUserStorageResponse
	if loadErr == nil {
		if progress.Phase == "interrupted" && progress.CanCancel && !record.Committed && s.switchTaskID != progress.TaskID && req.TaskID == "" {
			if err := s.cancelUnpublishedSwitchTaskLocked(ctx, stored, progress); err != nil {
				return empty, false, err
			}
			return empty, false, nil
		}
		if req.TaskID != "" || progress.CanResume || (progress.CanCancel && progress.Reserved) ||
			progress.Phase == "queued" || progress.Phase == "copying" || progress.Phase == "verified" || progress.Phase == "committing" {
			if string(reqBytes) != string(record.Request) {
				return progress.SwitchUserStorageResponse, true, files.ErrRootBusy
			}
			return progress.SwitchUserStorageResponse, true, nil
		}
		return empty, false, nil
	}
	if !errors.Is(loadErr, auth.ErrNotFound) || req.TaskID == "" {
		return empty, false, nil
	}
	latest, err := s.accounts.LoadStorageSwitchTask(userID, "")
	if errors.Is(err, auth.ErrNotFound) {
		return empty, false, nil
	}
	if err != nil {
		return empty, false, err
	}
	latestStored, latestProgress, normErr := s.normalizeLoadedSwitchTask(session, native, userID, latest)
	if normErr != nil {
		return empty, false, normErr
	}
	if (latestProgress.Phase == "verified" || latestProgress.Phase == "queued" || latestProgress.Phase == "copying" || latestProgress.Phase == "committing") &&
		sameSwitchOperation(latestStored, req) {
		return latestProgress.SwitchUserStorageResponse, true, nil
	}
	if !latest.Committed && (!latestProgress.Publishing || latestProgress.CanCancel) && s.switchTaskID != latestProgress.TaskID &&
		(latestProgress.Phase == "interrupted" || latestProgress.Phase == "verified") {
		if err := s.cancelUnpublishedSwitchTaskLocked(ctx, latestStored, &latestProgress); err != nil {
			return empty, false, err
		}
		return empty, false, nil
	}
	if latestProgress.Phase == "verified" || (!latest.Committed && (latestProgress.Publishing || latestProgress.Reserved)) {
		return latestProgress.SwitchUserStorageResponse, true, files.ErrRootBusy
	}
	return empty, false, nil
}

func (s *RootServer) createAndStartNewSwitchTaskLocked(
	session string,
	native bool,
	userID int64,
	req SwitchUserStorageRequest,
	reqBytes []byte,
) (SwitchUserStorageResponse, error) {
	var empty SwitchUserStorageResponse
	policy, err := s.fetchStoragePolicy(session, native, userID)
	if err != nil {
		return empty, err
	}
	if !storageSwitchSourceMatches(policy, req) {
		return empty, auth.ErrStorageReassignmentRequiresMigration
	}
	id := req.TaskID
	if id == "" {
		var bytes [16]byte
		if _, err := rand.Read(bytes[:]); err != nil {
			return empty, err
		}
		id = hex.EncodeToString(bytes[:])
	}
	progress := storageSwitchProgress{
		SwitchUserStorageResponse: SwitchUserStorageResponse{
			TaskID: id,
			Mode:   req.Mode,
			Phase:  "queued",
			Policy: policy,
		},
	}
	data, err := json.Marshal(progress)
	if err != nil {
		return empty, err
	}
	if err := s.accounts.CreateStorageSwitchTask(userID, auth.StorageSwitchTask{ID: id, Request: reqBytes, Progress: data}); err != nil {
		return empty, err
	}
	return s.startStorageSwitch(session, native, userID, req, progress)
}

func storageSwitchSourceMatches(policy auth.StoragePolicy, req SwitchUserStorageRequest) bool {
	for _, category := range req.Categories {
		if !slices.ContainsFunc(policy.Locations, func(location auth.StorageLocation) bool {
			return location.Category == category && location.RootID == req.SourceRootID && location.RootGeneration == req.SourceGeneration
		}) {
			return false
		}
	}
	return true
}

func (s *RootServer) startStorageSwitch(session string, native bool, userID int64, req SwitchUserStorageRequest, progress storageSwitchProgress) (SwitchUserStorageResponse, error) {
	if err := s.saveSwitch(progress); err != nil {
		return SwitchUserStorageResponse{}, err
	}
	if !s.beginRequest() {
		return SwitchUserStorageResponse{}, files.ErrOffline
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.switchTaskID, s.switchCancel = progress.TaskID, cancel
	response := progress.SwitchUserStorageResponse
	go func() {
		defer s.requests.Done()
		defer cancel()
		defer func() {
			s.switchMu.Lock()
			s.switchTaskID, s.switchCancel = "", nil
			s.switchMu.Unlock()
		}()
		err := s.runStorageSwitch(ctx, session, native, userID, req, &progress)
		if err != nil {
			slog.Warn("personal storage switch stopped", "taskID", progress.TaskID, "error", err)
			progress.ReadyToCleanup = false
			progress.Error = switchFailureCode(err)
			progress.ErrorDetail = err.Error()
			if progress.committed {
				progress.Phase = "source_pending"
			} else {
				progress.Phase = "failed"
				if progress.Publishing || progress.Reserved {
					progress.Phase = "interrupted"
				} else if errors.Is(err, context.Canceled) {
					progress.Phase = "cancelled"
				}
			}
		} else {
			progress.ErrorDetail = ""
		}
		if progress.Phase == "completed" || progress.Phase == "failed" || progress.Phase == "cancelled" {
			progress.Verified, progress.Published = nil, nil
		}
		_ = s.saveSwitch(progress)
	}()
	return response, nil
}

func switchFailureCode(err error) string {
	switch {
	case errors.Is(err, errStorageSwitchMedia):
		return "storage_switch_media_reassociation"
	case errors.Is(err, auth.ErrStorageQuotaExceeded):
		return "storage_quota_exceeded"
	case errors.Is(err, files.ErrExists), errors.Is(err, files.ErrTrashChanged), errors.Is(err, errStorageFolderConflict):
		return "storage_folder_conflict"
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, files.ErrInsufficientSpace):
		return "storage_switch_disk_full"
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "storage_permission_os_denied"
	case errors.Is(err, files.ErrSize):
		return "storage_switch_size_limit"
	case errors.Is(err, files.ErrType), errors.Is(err, files.ErrPath):
		return "storage_switch_unsupported_entry"
	case errors.Is(err, auth.ErrStorageLedgerConflict):
		return "storage_accounting_conflict"
	case errors.Is(err, errMigrationVerifyFailed):
		return "storage_migration_verification_failed"
	case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrMissing), errors.Is(err, files.ErrOffline):
		return "root_unavailable"
	case errors.Is(err, errStorageRootGenChanged), errors.Is(err, roots.ErrStale):
		return "root_generation_changed"
	case errors.Is(err, auth.ErrForbidden):
		return "storage_permission_denied"
	case errors.Is(err, context.Canceled):
		return "storage_switch_cancelled"
	default:
		return "storage_switch_failed"
	}
}

func (s *RootServer) discardStorageSwitch(target *files.Manager, id, identity string) error {
	if err := target.DiscardStorageSwitch(id, identity); err != nil {
		return err
	}
	return s.accounts.ReleaseStorageSwitch(id)
}

func (s *RootServer) runStorageSwitch(ctx context.Context, session string, native bool, userID int64, req SwitchUserStorageRequest, progress *storageSwitchProgress) (resultErr error) {
	if progress.committed {
		return s.recoverStorageSwitchSource(ctx, session, native, userID, req, progress)
	}
	base, paths, err := s.verifySwitchSourceAndReservations(session, native, userID, req)
	if err != nil {
		return err
	}
	target, dst, err := s.acquireValidatedSwitchRoot(ctx, req.TargetRootID, req.TargetGeneration)
	if err != nil {
		return err
	}
	defer target.Close()
	defer func() {
		// A failed rename may have published bytes. Keep them, and their
		// reservation, until an administrator has inspected the result.
		if resultErr != nil && progress.Reserved && !progress.Publishing && target.Lease.Valid(context.Background()) {
			if s.discardStorageSwitch(dst, progress.TaskID, progress.StageIdentity) == nil {
				progress.Reserved = false
			}
		}
	}()

	var src *files.Manager
	var source *RootServicesLease
	if req.Mode != "empty" {
		source, src, err = s.acquireValidatedSwitchRoot(ctx, req.SourceRootID, req.SourceGeneration)
		if err != nil {
			return err
		}
		defer source.Close()
	}

	resuming := progress.Publishing
	if err := prepareTargetSwitchPrefixes(ctx, dst, base, paths, req.Mode, resuming); err != nil {
		return err
	}

	switchReq := auth.SwitchUserStorageCategoriesRequest{
		TargetUserID:     userID,
		Categories:       req.Categories,
		SourceRootID:     req.SourceRootID,
		SourceGeneration: req.SourceGeneration,
		TargetRootID:     req.TargetRootID,
		TargetGeneration: req.TargetGeneration,
		TargetQuotaBytes: req.TargetQuotaBytes,
		TaskID:           progress.TaskID,
	}
	firstPass := !resuming && progress.Verified == nil
	ignoredLinks, err := s.resolveSwitchIgnoredAlbumLinks(userID, base, req, firstPass, progress)
	if err != nil {
		return err
	}
	if firstPass {
		if err := s.stageInitialSwitchTrees(ctx, src, dst, target.Root.Path, paths, ignoredLinks, switchReq, progress); err != nil {
			return err
		}
	}
	stagedTrees, alreadyPublished, err := s.verifyStagedSwitchTrees(ctx, src, dst, paths, resuming, firstPass, ignoredLinks, &switchReq, progress)
	if err != nil {
		return err
	}
	if progress.CopiedBytes != switchReq.ReservedBytes {
		return errMigrationVerifyFailed
	}
	progress.CopiedFiles = progress.VerifiedFiles
	switchReq.ExpectedAlbumLinks = progress.AlbumLinks
	progress.AffectedShareItems, progress.AffectedShares, err = s.accounts.StorageSwitchShares(switchReq)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !target.Lease.Valid(ctx) || (source != nil && !source.Lease.Valid(ctx)) {
		return errStorageRootGenChanged
	}
	if req.Mode == "migrate" && firstPass {
		progress.Phase, progress.ReadyToCleanup = "verified", true
		return nil
	}
	return s.publishAndCommitSwitch(ctx, session, native, userID, base, paths, req, switchReq, src, dst, source, target, resuming, alreadyPublished, stagedTrees, progress)
}

func (s *RootServer) verifySwitchSourceAndReservations(
	session string,
	native bool,
	userID int64,
	req SwitchUserStorageRequest,
) (string, []string, error) {
	policy, err := s.fetchStoragePolicy(session, native, userID)
	if err != nil {
		return "", nil, err
	}
	if !storageSwitchSourceMatches(policy, req) {
		return "", nil, auth.ErrStorageReassignmentRequiresMigration
	}
	base := "Users/u" + strconv.FormatInt(userID, 10)
	paths := make([]string, 0, len(req.Categories))
	for _, cat := range req.Categories {
		prefix := path.Join(base, cat)
		pending, err := s.accounts.HasPendingCategoryReservations(userID, req.SourceRootID, req.SourceGeneration, prefix)
		if err != nil {
			return "", nil, err
		}
		if pending {
			return "", nil, auth.ErrStorageLedgerConflict
		}
		paths = append(paths, prefix)
	}
	return base, paths, nil
}

func (s *RootServer) acquireValidatedSwitchRoot(
	ctx context.Context,
	rootID string,
	expectedGen uint64,
) (*RootServicesLease, *files.Manager, error) {
	lease, err := s.AcquireRootServices(ctx, rootID)
	if err != nil {
		return nil, nil, err
	}
	mgr, ok := lease.Services.Files.(*files.Manager)
	if !ok || lease.Root.Generation != expectedGen || !lease.Lease.Valid(ctx) {
		_ = lease.Close()
		return nil, nil, errStorageRootGenChanged
	}
	return lease, mgr, nil
}

func prepareTargetSwitchPrefixes(
	ctx context.Context,
	dst *files.Manager,
	base string,
	paths []string,
	mode string,
	resuming bool,
) error {
	for _, dir := range []string{"Users", base} {
		if err := ensureDirectoryExists(dst, dir); err != nil {
			return err
		}
	}
	for _, prefix := range paths {
		if mode == "empty" {
			if err := ensureDirectoryExists(dst, prefix); err != nil {
				return err
			}
			tree, err := dst.StorageSwitchTree(ctx, prefix, false)
			if err != nil {
				return err
			}
			if len(tree.Files) != 0 || len(tree.Directories) != 1 {
				return errStorageFolderConflict
			}
			continue
		}
		if resuming {
			continue
		}
		if _, err := dst.Stat(prefix); err == nil {
			tree, treeErr := dst.StorageSwitchTree(ctx, prefix, false)
			if treeErr != nil || len(tree.Files) != 0 || len(tree.Directories) != 1 {
				return errStorageFolderConflict
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (s *RootServer) resolveSwitchIgnoredAlbumLinks(
	userID int64,
	base string,
	req SwitchUserStorageRequest,
	firstPass bool,
	progress *storageSwitchProgress,
) (map[string]string, error) {
	if !slices.Contains(req.Categories, auth.StoragePhotos) {
		return nil, nil
	}
	current, err := s.accounts.StorageSwitchAlbumLinks(userID, req.SourceRootID, req.SourceGeneration)
	if err != nil {
		return nil, err
	}
	if firstPass {
		progress.AlbumLinks = current
	} else if !slices.Equal(progress.AlbumLinks, current) {
		return nil, auth.ErrStorageLedgerConflict
	}
	ignoredLinks := make(map[string]string)
	photosPrefix := path.Join(base, auth.StoragePhotos)
	for _, link := range current {
		if link.MemberPhotos == photosPrefix {
			ignoredLinks[path.Join(link.MemberPhotos, link.LinkName)] = link.ExpectedTarget
		}
	}
	return ignoredLinks, nil
}
