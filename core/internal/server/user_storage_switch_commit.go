package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"path"
	"slices"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func (s *RootServer) publishAndCommitSwitch(
	ctx context.Context,
	session string,
	native bool,
	userID int64,
	base string,
	paths []string,
	req SwitchUserStorageRequest,
	switchReq auth.SwitchUserStorageCategoriesRequest,
	src *files.Manager,
	dst *files.Manager,
	source *RootServicesLease,
	target *RootServicesLease,
	resuming bool,
	alreadyPublished map[string]bool,
	stagedTrees map[string]files.StorageSwitchTree,
	progress *storageSwitchProgress,
) error {
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
	if err := publishSwitchTrees(ctx, src, dst, source, target, paths, req.Mode, alreadyPublished, stagedTrees, progress); err != nil {
		if len(alreadyPublished) == 0 && s.allSwitchCategoriesStillStaged(ctx, req, *progress) {
			progress.Publishing, progress.CanResume = false, false
		}
		return err
	}
	if source != nil {
		if err := copyVerifiedSwitchMedia(ctx, userID, paths, source, target, progress); err != nil {
			s.queueMediaRefreshForCategories(req.TargetRootID, base, req.Categories)
			return err
		}
	}
	if !target.Lease.Valid(ctx) || (source != nil && !source.Lease.Valid(ctx)) {
		return errStorageRootGenChanged
	}
	var err error
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
	if err := s.cleanupStorageSwitchAlbumLinks(ctx, req, source, progress); err != nil {
		return err
	}
	if len(progress.TrashIDs) != 0 {
		if err := s.finishStorageSwitchSource(ctx, paths, source, target, progress); err != nil {
			return err
		}
	}
	s.queueMediaRefreshForCategories(req.SourceRootID, base, req.Categories)
	if slices.Contains(req.Categories, auth.StoragePhotos) || slices.Contains(req.Categories, auth.StorageVideos) {
		s.QueueMediaRefresh(req.TargetRootID, "")
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
