package server

import (
	"context"
	"errors"
	"io/fs"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

type UploadCleanupReport struct {
	Removed             int
	Skipped             int
	PendingReservations int
	HasMore             bool
}

// SweepRootUploads is called only by the in-process scheduler. It holds the
// registered root lease throughout removal and reservation verification.
// A failed or ambiguous release is retained for administrator inspection.
func (s *RootServer) SweepRootUploads(ctx context.Context, rootID string, generation uint64, cutoff time.Time) (report UploadCleanupReport, resultErr error) {
	if s == nil || s.accounts == nil || cutoff.IsZero() || cutoff.After(time.Now()) {
		return report, errors.New("upload_cleanup_unavailable")
	}
	lease, err := s.AcquireRootServices(ctx, rootID)
	if err != nil {
		return report, err
	}
	defer lease.Close()
	if lease.Root.Generation != generation || !lease.Lease.Valid(ctx) {
		return report, roots.ErrStale
	}
	journal := lease.Services.Journal
	if journal == nil || lease.Services.Files == nil {
		return report, errors.New("upload_cleanup_unavailable")
	}
	if err := journal.Start("uploads", "expired-cleanup"); err != nil {
		return report, err
	}
	defer func() {
		if err := journal.Progress("uploads", int64(report.Removed), 0); err != nil && resultErr == nil {
			resultErr = errors.New("upload_cleanup_status_unavailable")
		}
		if err := journal.Finish("uploads", resultErr); err != nil {
			resultErr = errors.Join(resultErr, err)
		}
	}()
	if err := ctx.Err(); err != nil {
		resultErr = errors.New("upload_cleanup_cancelled")
		return report, resultErr
	}
	removed, skipped, more, cleanupErr := lease.Services.Files.CleanupExpiredUploads(cutoff.Unix())
	report.Removed, report.Skipped, report.HasMore = len(removed), skipped, more
	for _, uploadID := range removed {
		if ctx.Err() != nil || !lease.Lease.Valid(ctx) {
			report.PendingReservations++
			continue
		}
		id, path, owner, found, err := s.accounts.UploadReservationForCleanup(rootID, generation, uploadID)
		if err != nil {
			report.PendingReservations++
			continue
		}
		if !found {
			continue
		}
		// A destination that appeared after the staging check makes the
		// outcome uncertain, regardless of its name, size or timestamp.
		if _, err := lease.Services.Files.Stat(path); !errors.Is(err, fs.ErrNotExist) || !lease.Lease.Valid(ctx) {
			report.PendingReservations++
			continue
		}
		if err := s.accounts.ReleaseCleanedUploadReservation(id, rootID, generation, uploadID, path, owner); err != nil {
			report.PendingReservations++
		}
	}
	switch {
	case cleanupErr != nil:
		resultErr = errors.New("upload_cleanup_failed")
	case report.Skipped > 0 || report.PendingReservations > 0:
		resultErr = errors.New("upload_cleanup_needs_review")
	case report.HasMore:
		resultErr = errors.New("upload_cleanup_more")
	}
	return report, resultErr
}
