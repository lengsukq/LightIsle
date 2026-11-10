package server

import (
	"context"
	"errors"
	"os"
	"path"
	"strconv"
	"syscall"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

var errStorageSwitchMedia = errors.New("storage_switch_media_reassociation")

func (s *RootServer) stageInitialSwitchTrees(
	ctx context.Context,
	src, dst *files.Manager,
	targetRootPath string,
	paths []string,
	ignoredLinks map[string]string,
	switchReq auth.SwitchUserStorageCategoriesRequest,
	progress *storageSwitchProgress,
) error {
	var total int64
	var totalFiles int
	if src != nil {
		for _, prefix := range paths {
			progress.ReviewPath = prefix
			tree, err := src.StorageSwitchTreeIgnoring(ctx, prefix, false, ignoredLinks)
			if err != nil {
				return err
			}
			total += tree.Bytes
			totalFiles += len(tree.Files)
		}
	}
	if total < 0 || total > (int64(8)<<40) {
		return files.ErrSize
	}
	if total > 0 {
		var volume syscall.Statfs_t
		if err := syscall.Statfs(targetRootPath, &volume); err != nil {
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
	progress.TotalBytes = total
	progress.TotalFiles = totalFiles
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
	return nil
}

func (s *RootServer) verifyStagedSwitchTrees(
	ctx context.Context,
	src, dst *files.Manager,
	paths []string,
	resuming, firstPass bool,
	ignoredLinks map[string]string,
	switchReq *auth.SwitchUserStorageCategoriesRequest,
	progress *storageSwitchProgress,
) (map[string]files.StorageSwitchTree, map[string]bool, error) {
	stagedTrees := make(map[string]files.StorageSwitchTree, len(paths))
	alreadyPublished := make(map[string]bool, len(paths))
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
				return nil, nil, errors.Join(errMigrationVerifyFailed, err, liveErr)
			}
			expected := progress.Published[prefix]
			if len(expected.Directories) == 0 || !expected.SameObjects(staged) {
				return nil, nil, errMigrationVerifyFailed
			}
		}
		if err != nil {
			return nil, nil, err
		}
		original, err := src.StorageSwitchTreeIgnoring(ctx, prefix, true, ignoredLinks)
		if err != nil || !original.SameContent(staged) {
			return nil, nil, errors.Join(errMigrationVerifyFailed, err)
		}
		if firstPass {
			progress.Verified[prefix] = original
			progress.VerifiedFiles += len(original.Files)
		} else if !progress.Verified[prefix].SameObjects(original) {
			return nil, nil, errMigrationVerifyFailed
		}
		stagedTrees[prefix] = staged
		switchReq.ReservedBytes += staged.Bytes
		for _, item := range staged.Files {
			switchReq.CopiedFiles = append(switchReq.CopiedFiles, auth.SwitchedStorageFile{
				RelativePath: path.Join(prefix, item.Path), SizeBytes: item.Size, Identity: item.Identity,
			})
		}
	}
	return stagedTrees, alreadyPublished, nil
}

func publishSwitchTrees(
	ctx context.Context,
	src, dst *files.Manager,
	source, target *RootServicesLease,
	paths []string,
	mode string,
	alreadyPublished map[string]bool,
	stagedTrees map[string]files.StorageSwitchTree,
	progress *storageSwitchProgress,
) error {
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
	if mode == "empty" {
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

func copyVerifiedSwitchMedia(ctx context.Context, owner int64, paths []string, source, target *RootServicesLease, progress *storageSwitchProgress) error {
	for _, prefix := range paths {
		if !source.Lease.Valid(ctx) || !target.Lease.Valid(ctx) {
			return errStorageRootGenChanged
		}
		category := path.Base(prefix)
		if category != auth.StoragePhotos && category != auth.StorageVideos {
			continue
		}
		before, after := progress.Verified[prefix], progress.Published[prefix]
		if !before.SameContent(after) {
			return errMigrationVerifyFailed
		}
		verified := make(map[string]files.SwitchMediaPair, len(before.Files))
		for i, item := range before.Files {
			verified[path.Join(prefix, item.Path)] = files.SwitchMediaPair{Source: item, Target: after.Files[i]}
		}
		progress.ReviewPath = prefix
		var err error
		switch category {
		case auth.StoragePhotos:
			if source.Services.GalleryUnavailable || target.Services.GalleryUnavailable {
				return errStorageSwitchMedia
			}
			if source.Services.Gallery != nil && target.Services.Gallery != nil {
				err = source.Services.Gallery.CopySwitchAssociations(ctx, target.Services.Gallery, owner, prefix, verified)
			}
		case auth.StorageVideos:
			if source.Services.CinemaUnavailable || target.Services.CinemaUnavailable {
				return errStorageSwitchMedia
			}
			if source.Services.Cinema != nil && target.Services.Cinema != nil {
				err = source.Services.Cinema.CopySwitchProgress(ctx, target.Services.Cinema, owner, prefix, verified)
			}
		}
		if err != nil {
			return errors.Join(errStorageSwitchMedia, err)
		}
	}
	return nil
}
