//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func makeRootServices(dataDir string, worker *mediaworker.Client, cacheBytes int64) server.RootServicesFactory {
	return func(ctx context.Context, record roots.Root, lease *roots.Lease) (*server.RootServices, error) {
		if !lease.Valid(ctx) {
			return nil, roots.ErrOffline
		}
		manager, err := files.NewPinnedManager(lease.Root, record.Binding)
		if err != nil {
			return nil, err
		}
		services := &server.RootServices{Files: manager}
		journal, err := tasks.OpenRootScoped(dataDir, record.ID)
		if err != nil {
			slog.Warn("root task history unavailable", "rootID", record.ID, "error", err)
		}
		services.Journal = journal
		rootAppDataDir := filepath.Join(record.Path, ".lightisle-appdata")
		_ = os.MkdirAll(rootAppDataDir, 0700)
		cacheDir := filepath.Join(rootAppDataDir, "thumbnails-generation-"+strconv.FormatUint(record.Generation, 10))
		photos, err := gallery.OpenRootScoped(dataDir, manager, record.ID, gallery.Options{
			ThumbnailCacheBytes: cacheBytes,
			RootGeneration:      record.Generation,
			CacheDir:            cacheDir,
		})
		if err != nil {
			services.GalleryUnavailable = true
			slog.Warn("root gallery unavailable; continuing with files", "rootID", record.ID, "error", err)
		} else {
			photos.SetJournal(journal)
			photos.SetMediaWorker(worker)
			services.Gallery = photos
		}
		films, err := cinema.OpenRootScoped(dataDir, manager, record.ID, record.Generation)
		if err != nil {
			services.CinemaUnavailable = true
			slog.Warn("root cinema unavailable; continuing with files", "rootID", record.ID, "error", err)
		} else {
			films.SetJournal(journal)
			films.SetMediaWorker(worker)
			services.Cinema = films
		}
		services.Close = func() error {
			var result error
			if photos != nil {
				result = errors.Join(result, photos.Close())
			}
			if films != nil {
				result = errors.Join(result, films.Close())
			}
			if journal != nil {
				result = errors.Join(result, journal.Close())
			}
			return errors.Join(result, manager.Close())
		}

		if !lease.Valid(ctx) {
			services.Close()
			return nil, roots.ErrOffline
		}
		return services, nil
	}
}
