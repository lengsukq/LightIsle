//go:build darwin && arm64

package main

import (
	"context"
	"errors"

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
		journal, err := tasks.OpenRootScoped(dataDir, record.ID)
		if err != nil {
			manager.Close()
			return nil, err
		}
		photos, err := gallery.OpenRootScoped(dataDir, manager, record.ID, gallery.Options{ThumbnailCacheBytes: cacheBytes, RootGeneration: record.Generation})
		if err != nil {
			journal.Close()
			manager.Close()
			return nil, err
		}
		films, err := cinema.OpenRootScoped(dataDir, manager, record.ID, record.Generation)
		if err != nil {
			photos.Close()
			journal.Close()
			manager.Close()
			return nil, err
		}
		photos.SetJournal(journal)
		photos.SetMediaWorker(worker)
		films.SetJournal(journal)
		films.SetMediaWorker(worker)
		services := &server.RootServices{Files: manager, Gallery: photos, Cinema: films, Journal: journal}
		services.Close = func() error {
			return errors.Join(photos.Close(), films.Close(), journal.Close(), manager.Close())
		}
		if !lease.Valid(ctx) {
			services.Close()
			return nil, roots.ErrOffline
		}
		return services, nil
	}
}
