package server

import (
	"context"
	"errors"
	"path"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

var errStorageSwitchMedia = errors.New("storage_switch_media_reassociation")

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
