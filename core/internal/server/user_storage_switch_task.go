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
		if err := json.Unmarshal(record.Request, &stored); err != nil {
			return empty, err
		}
		if err := json.Unmarshal(record.Progress, &progress); err != nil {
			return empty, err
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
						return empty, err
					}
					binding := stored
					binding.SourceRootID, binding.SourceGeneration = stored.TargetRootID, stored.TargetGeneration
					if storageSwitchSourceMatches(policy, binding) {
						progress.Policy, progress.Phase, progress.Error = policy, "completed", ""
					}
				}
			}
			if err := s.saveSwitch(progress); err != nil {
				return empty, err
			}
		}
		progress.CanCancel = progress.Phase == "interrupted" && !progress.Publishing
	} else if !errors.Is(loadErr, auth.ErrNotFound) {
		return empty, loadErr
	}

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
			return empty, files.ErrRootBusy
		}
		progress.Phase, progress.Error = "committing", ""
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
			return empty, files.ErrRootBusy
		}
		progress.committed, progress.Phase, progress.Error = true, "committing", ""
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
		if progress.Phase != "verified" && !(req.Phase == "cancel" && progress.Phase == "interrupted" && !progress.Publishing) {
			return progress.SwitchUserStorageResponse, nil
		}
		if s.switchTaskID != "" {
			return empty, files.ErrRootBusy
		}
		if req.Phase == "cancel" {
			lease, err := s.AcquireRootServices(ctx, stored.TargetRootID)
			if err != nil {
				return empty, err
			}
			defer lease.Close()
			manager, ok := lease.Services.Files.(*files.Manager)
			if !ok || lease.Root.Generation != stored.TargetGeneration || !lease.Lease.Valid(ctx) {
				return empty, errStorageRootGenChanged
			}
			if err := s.discardStorageSwitch(manager, progress.TaskID, progress.StageIdentity); err != nil {
				return empty, err
			}
			progress.Phase, progress.ReadyToCleanup, progress.Verified = "cancelled", false, nil
			progress.Error = ""
			progress.Reserved = false
			progress.CanCancel = false
			if err := s.saveSwitch(progress); err != nil {
				return empty, err
			}
			return progress.SwitchUserStorageResponse, nil
		}
		progress.Phase = "committing"
		progress.ReadyToCleanup = false
		return s.startStorageSwitch(session, native, userID, stored, progress)
	case "", "copy_and_verify":
	default:
		return empty, auth.ErrInput
	}
	if err := validateStorageSwitch(&req); err != nil {
		return empty, err
	}
	req.Phase = ""
	reqBytes, err := json.Marshal(req)
	if err != nil {
		return empty, err
	}
	if loadErr == nil && (req.TaskID != "" || progress.CanResume || progress.CanCancel && progress.Reserved ||
		progress.Phase == "queued" || progress.Phase == "copying" || progress.Phase == "verified" || progress.Phase == "committing") {
		if string(reqBytes) != string(record.Request) {
			return empty, files.ErrRootBusy
		}
		return progress.SwitchUserStorageResponse, nil
	}
	if errors.Is(loadErr, auth.ErrNotFound) && req.TaskID != "" {
		latest, err := s.accounts.LoadStorageSwitchTask(userID, "")
		if err == nil {
			var latestProgress storageSwitchProgress
			if err := json.Unmarshal(latest.Progress, &latestProgress); err != nil {
				return empty, err
			}
			if latestProgress.Phase == "verified" || !latest.Committed && (latestProgress.Publishing || latestProgress.Reserved) {
				return empty, files.ErrRootBusy
			}
		} else if !errors.Is(err, auth.ErrNotFound) {
			return empty, err
		}
	}

	if s.switchTaskID != "" {
		return empty, files.ErrRootBusy
	}
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
	progress = storageSwitchProgress{SwitchUserStorageResponse: SwitchUserStorageResponse{TaskID: id, Mode: req.Mode, Phase: "queued", Policy: policy}}
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
	case errors.Is(err, syscall.ENOSPC):
		return "storage_switch_disk_full"
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
	policy, err := s.fetchStoragePolicy(session, native, userID)
	if err != nil {
		return err
	}
	if !storageSwitchSourceMatches(policy, req) {
		return auth.ErrStorageReassignmentRequiresMigration
	}
	base := "Users/u" + strconv.FormatInt(userID, 10)
	paths := make([]string, 0, len(req.Categories))
	for _, cat := range req.Categories {
		prefix := path.Join(base, cat)
		pending, err := s.accounts.HasPendingCategoryReservations(userID, req.SourceRootID, req.SourceGeneration, prefix)
		if err != nil {
			return err
		}
		if pending {
			return auth.ErrStorageLedgerConflict
		}
		paths = append(paths, prefix)
	}
	target, err := s.AcquireRootServices(ctx, req.TargetRootID)
	if err != nil {
		return err
	}
	defer target.Close()
	dst, ok := target.Services.Files.(*files.Manager)
	if !ok || target.Root.Generation != req.TargetGeneration || !target.Lease.Valid(ctx) {
		return errStorageRootGenChanged
	}
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
		source, err = s.AcquireRootServices(ctx, req.SourceRootID)
		if err != nil {
			return err
		}
		defer source.Close()
		src, ok = source.Services.Files.(*files.Manager)
		if !ok || source.Root.Generation != req.SourceGeneration || !source.Lease.Valid(ctx) {
			return errStorageRootGenChanged
		}
	}
	for _, dir := range []string{"Users", base} {
		if err := ensureDirectoryExists(dst, dir); err != nil {
			return err
		}
	}
	resuming := progress.Publishing
	for _, prefix := range paths {
		if req.Mode == "empty" {
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
		} else if resuming {
			continue
		} else if _, err := dst.Stat(prefix); err == nil {
			return errStorageFolderConflict
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	stagedTrees := make(map[string]files.StorageSwitchTree, len(paths))
	alreadyPublished := make(map[string]bool, len(paths))
	switchReq := auth.SwitchUserStorageCategoriesRequest{
		TargetUserID: userID, Categories: req.Categories,
		SourceRootID: req.SourceRootID, SourceGeneration: req.SourceGeneration,
		TargetRootID: req.TargetRootID, TargetGeneration: req.TargetGeneration,
		TargetQuotaBytes: req.TargetQuotaBytes, TaskID: progress.TaskID,
	}
	firstPass := !resuming && progress.Verified == nil
	var ignoredLinks map[string]string
	if slices.Contains(req.Categories, auth.StoragePhotos) {
		current, err := s.accounts.StorageSwitchAlbumLinks(userID, req.SourceRootID, req.SourceGeneration)
		if err != nil {
			return err
		}
		if firstPass {
			progress.AlbumLinks = current
		} else if !slices.Equal(progress.AlbumLinks, current) {
			return auth.ErrStorageLedgerConflict
		}
		ignoredLinks = make(map[string]string)
		photosPrefix := path.Join(base, auth.StoragePhotos)
		for _, link := range current {
			if link.MemberPhotos == photosPrefix {
				ignoredLinks[path.Join(link.MemberPhotos, link.LinkName)] = link.ExpectedTarget
			}
		}
	}
	if firstPass {
		var total int64
		if src != nil {
			for _, prefix := range paths {
				tree, err := src.StorageSwitchTreeIgnoring(ctx, prefix, false, ignoredLinks)
				if err != nil {
					return err
				}
				total += tree.Bytes
			}
		}
		if total < 0 || total > (int64(8)<<40) {
			return files.ErrSize
		}
		if total > 0 {
			var volume syscall.Statfs_t
			if err := syscall.Statfs(target.Root.Path, &volume); err != nil {
				return err
			}
			if volume.Bsize == 0 || uint64(total)/uint64(volume.Bsize) >= volume.Bavail {
				return syscall.ENOSPC
			}
		}
		if err := s.accounts.ReserveStorageSwitch(progress.TaskID, switchReq, total); err != nil {
			return err
		}
		progress.Reserved = true
		progress.Phase = "copying"
		if err := s.saveSwitch(*progress); err != nil {
			return err
		}
		if src != nil {
			if err := src.StageStorageSwitch(ctx, dst, progress.TaskID, paths, total, func(identity string) error {
				progress.StageIdentity = identity
				return s.saveSwitch(*progress)
			}, func(n int64) {
				if n-progress.CopiedBytes >= 64<<20 {
					progress.CopiedBytes = n
					_ = s.saveSwitch(*progress)
				}
			}, ignoredLinks); err != nil {
				return err
			}
		}
		progress.CopiedBytes = total
		progress.Verified = make(map[string]files.StorageSwitchTree, len(paths))
	}
	for _, prefix := range paths {
		if src == nil {
			break
		}
		progress.ReviewPath = prefix
		staged, err := dst.StagedStorageSwitchTree(ctx, progress.TaskID, path.Base(prefix))
		if resuming {
			live, liveErr := dst.StorageSwitchTree(ctx, prefix, true)
			switch {
			case errors.Is(err, os.ErrNotExist) && liveErr == nil:
				staged, err = live, nil
				alreadyPublished[prefix] = true
			case err == nil && errors.Is(liveErr, os.ErrNotExist):
				// The exact directory remains in this task's private stage.
			default:
				return errors.Join(errMigrationVerifyFailed, err, liveErr)
			}
			expected := progress.Published[prefix]
			if len(expected.Directories) == 0 || !expected.SameObjects(staged) {
				return errMigrationVerifyFailed
			}
		}
		if err != nil {
			return err
		}
		original, err := src.StorageSwitchTreeIgnoring(ctx, prefix, true, ignoredLinks)
		if err != nil || !original.SameContent(staged) {
			return errors.Join(errMigrationVerifyFailed, err)
		}
		if firstPass {
			progress.Verified[prefix] = original
			progress.VerifiedFiles += len(original.Files)
		} else if !progress.Verified[prefix].SameObjects(original) {
			return errMigrationVerifyFailed
		}
		stagedTrees[prefix] = staged
		switchReq.ReservedBytes += staged.Bytes
		for _, item := range staged.Files {
			switchReq.CopiedFiles = append(switchReq.CopiedFiles, auth.SwitchedStorageFile{
				RelativePath: path.Join(prefix, item.Path), SizeBytes: item.Size, Identity: item.Identity,
			})
		}
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
	if !target.Lease.Valid(ctx) || source != nil && !source.Lease.Valid(ctx) {
		return errStorageRootGenChanged
	}
	if req.Mode == "migrate" && firstPass {
		progress.Phase, progress.ReadyToCleanup = "verified", true
		return nil
	}
	if !resuming && (req.Mode == "migrate" || req.Mode == "move") {
		progress.TrashIDs = make(map[string]string, len(paths))
		for _, prefix := range paths {
			var bytes [16]byte
			if _, err := rand.Read(bytes[:]); err != nil {
				return err
			}
			progress.TrashIDs[path.Base(prefix)] = hex.EncodeToString(bytes[:])
		}
	}
	progress.Phase, progress.Publishing = "committing", true
	progress.CanResume = true
	progress.Published = stagedTrees
	if err := s.saveSwitch(*progress); err != nil {
		return err
	}
	if src != nil {
		for _, prefix := range paths {
			if !target.Lease.Valid(ctx) || !source.Lease.Valid(ctx) {
				return errStorageRootGenChanged
			}
			progress.ReviewPath = prefix
			var err error
			if alreadyPublished[prefix] {
				err = dst.SyncStorageSwitchPublication(progress.TaskID, prefix)
			} else {
				err = dst.PublishStorageSwitch(progress.TaskID, prefix)
			}
			if err != nil {
				return err
			}
			published, err := dst.StorageSwitchTree(ctx, prefix, true)
			if err != nil || !stagedTrees[prefix].SameObjects(published) {
				return errors.Join(errMigrationVerifyFailed, err)
			}
		}
	}
	if req.Mode == "empty" {
		for _, prefix := range paths {
			tree, err := dst.StorageSwitchTree(ctx, prefix, false)
			if err != nil {
				return err
			}
			if len(tree.Files) != 0 || len(tree.Directories) != 1 {
				return errStorageFolderConflict
			}
		}
	}
	if source != nil {
		if err := copyVerifiedSwitchMedia(ctx, userID, paths, source, target, progress); err != nil {
			s.queueMediaRefreshForCategories(req.TargetRootID, base, req.Categories)
			return err
		}
	}
	if !target.Lease.Valid(ctx) || source != nil && !source.Lease.Valid(ctx) {
		return errStorageRootGenChanged
	}
	if native {
		_, err = s.accounts.NativeSwitchUserStorageCategories(switchReq)
	} else {
		_, err = s.accounts.SwitchUserStorageCategories(session, switchReq)
	}
	if err != nil {
		return err
	}
	progress.Reserved = false
	progress.committed = true
	progress.CanResume = false
	progress.ReviewPath = ""
	s.queueMediaRefreshForCategories(req.SourceRootID, base, req.Categories)
	s.queueMediaRefreshForCategories(req.TargetRootID, base, req.Categories)
	if err := s.cleanupStorageSwitchAlbumLinks(ctx, req, source, progress); err != nil {
		return err
	}
	if len(progress.TrashIDs) != 0 {
		if err := s.finishStorageSwitchSource(ctx, paths, source, target, progress); err != nil {
			return err
		}
	}
	progress.Policy, err = s.fetchStoragePolicy(session, native, userID)
	if err != nil {
		return err
	}
	if src != nil {
		// Successful publications leave an empty private stage.
		_ = dst.DiscardStorageSwitch(progress.TaskID, progress.StageIdentity)
	}
	progress.Phase = "completed"
	return nil
}

func (s *RootServer) recoverStorageSwitchSource(ctx context.Context, session string, native bool, userID int64, req SwitchUserStorageRequest, progress *storageSwitchProgress) error {
	policy, err := s.fetchStoragePolicy(session, native, userID)
	if err != nil {
		return err
	}
	destinationBinding := req
	destinationBinding.SourceRootID, destinationBinding.SourceGeneration = req.TargetRootID, req.TargetGeneration
	if !storageSwitchSourceMatches(policy, destinationBinding) {
		return auth.ErrStorageReassignmentRequiresMigration
	}
	source, err := s.AcquireRootServices(ctx, req.SourceRootID)
	if err != nil {
		return err
	}
	defer source.Close()
	target, err := s.AcquireRootServices(ctx, req.TargetRootID)
	if err != nil {
		return err
	}
	defer target.Close()
	if source.Root.Generation != req.SourceGeneration || target.Root.Generation != req.TargetGeneration {
		return errStorageRootGenChanged
	}
	paths := make([]string, 0, len(req.Categories))
	for _, category := range req.Categories {
		paths = append(paths, path.Join("Users/u"+strconv.FormatInt(userID, 10), category))
	}
	if err := s.cleanupStorageSwitchAlbumLinks(ctx, req, source, progress); err != nil {
		return err
	}
	if len(progress.TrashIDs) != 0 {
		if err := s.finishStorageSwitchSource(ctx, paths, source, target, progress); err != nil {
			return err
		}
	}
	progress.Policy, progress.Phase = policy, "completed"
	return nil
}

func (s *RootServer) finishStorageSwitchSource(ctx context.Context, paths []string, source, target *RootServicesLease, progress *storageSwitchProgress) error {
	src, sourceOK := source.Services.Files.(*files.Manager)
	dst, targetOK := target.Services.Files.(*files.Manager)
	if !sourceOK || !targetOK {
		return files.ErrOffline
	}
	count := 0
	for _, prefix := range paths {
		trashID := progress.TrashIDs[path.Base(prefix)]
		if trashID == "" || len(progress.Published[prefix].Directories) == 0 || len(progress.Verified[prefix].Directories) == 0 {
			return errMigrationVerifyFailed
		}
		if !target.Lease.Valid(ctx) || !source.Lease.Valid(ctx) {
			return errStorageRootGenChanged
		}
		published, err := dst.StorageSwitchTree(ctx, prefix, true)
		if err != nil || !progress.Published[prefix].SameObjects(published) {
			return errors.Join(errMigrationVerifyFailed, err)
		}
		if err := src.TrashStorageSwitch(ctx, prefix, progress.Verified[prefix], trashID); err != nil {
			return err
		}
		count += len(progress.Verified[prefix].Files)
		progress.DeletedSourceFiles = max(progress.DeletedSourceFiles, count)
		if err := s.saveSwitch(*progress); err != nil {
			return err
		}
	}
	return nil
}
