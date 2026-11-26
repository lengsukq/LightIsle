package downloads

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/lengsukq/lightisle/core/internal/webarchive"
)

const webArchiveTaskTimeout = 60 * time.Second

func (m *Manager) kickWebArchive(id string) {
	m.mu.Lock()
	if m.ctx.Err() != nil {
		m.mu.Unlock()
		return
	}
	m.wg.Add(1)
	m.mu.Unlock()
	go func() {
		defer m.wg.Done()
		m.runWebArchiveTask(id)
	}()
}

func (m *Manager) runWebArchiveTask(id string) {
	m.importMu.Lock()
	task, _, err := m.rowByIDUnscoped(id)
	if err != nil || task.Status != StatusQueued || task.Engine != EngineWebArchive {
		m.importMu.Unlock()
		return
	}
	if !m.canFetch(task.Owner) {
		m.failTask(id, ErrFetchForbidden.Error(), "")
		m.importMu.Unlock()
		return
	}
	if err := m.requireTaskRoot(task); err != nil {
		m.failTask(id, downloadRootError(err), "")
		m.importMu.Unlock()
		return
	}
	staging := m.stagingDir(id)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		m.failTask(id, "download_staging_failed", "")
		m.importMu.Unlock()
		return
	}
	if err := m.update(id, "status", StatusRunning, "error", ""); err != nil {
		m.importMu.Unlock()
		return
	}
	archiveOpts := m.webArchiveOptions(task.MaxBytes)
	runCtx, cancel := context.WithTimeout(m.ctx, webArchiveTaskTimeout)
	token := m.registerTaskCancel(id, cancel)
	m.importMu.Unlock()

	defer func() {
		cancel()
		m.clearTaskCancel(id, token)
	}()

	initialPath := filepath.Join(staging, "archive.html")
	res, archiveErr := webarchive.ArchiveToFile(runCtx, task.URL, initialPath, archiveOpts)
	if archiveErr == nil && res.SuggestedName != "" && res.SuggestedName != "archive.html" {
		targetPath := filepath.Join(staging, filepath.Base(res.SuggestedName))
		_ = os.Rename(initialPath, targetPath)
	}

	m.importMu.Lock()
	defer m.importMu.Unlock()
	current, _, readErr := m.rowByIDUnscoped(id)
	if readErr != nil || current.Status != StatusRunning {
		if readErr == nil && current.Status == StatusCancelled {
			_ = os.RemoveAll(staging)
		}
		return
	}
	if m.ctx.Err() != nil {
		return
	}
	if archiveErr != nil {
		m.failTask(id, webArchiveErrorCode(runCtx, archiveErr), "")
		return
	}
	_ = m.updateRunnerProgress(id, res.TotalBytes, res.TotalBytes)
	m.importDownloadLocked(id)
	if healthy, err := m.noFailedActive(); err == nil && healthy {
		m.lowerAlert()
	}
}

func (m *Manager) webArchiveOptions(maxBytes int64) webarchive.Options {
	var opts webarchive.Options
	if m.opts.WebArchiveOptions != nil {
		opts = *m.opts.WebArchiveOptions
	}
	if maxBytes > 0 && (opts.MaxTotalBytes <= 0 || maxBytes < opts.MaxTotalBytes) {
		opts.MaxTotalBytes = maxBytes
	}
	return opts
}

func webArchiveErrorCode(ctx context.Context, err error) string {
	switch {
	case errors.Is(err, webarchive.ErrBlockedAddress):
		return webarchive.ErrBlockedAddress.Error()
	case errors.Is(err, webarchive.ErrTooManyRedirects):
		return webarchive.ErrTooManyRedirects.Error()
	case errors.Is(err, webarchive.ErrTooLarge):
		return webarchive.ErrTooLarge.Error()
	case errors.Is(err, webarchive.ErrUnsupportedContentType):
		return webarchive.ErrUnsupportedContentType.Error()
	case errors.Is(err, webarchive.ErrInvalidURL):
		return webarchive.ErrInvalidURL.Error()
	case errors.Is(err, webarchive.ErrHTTPStatus):
		return webarchive.ErrHTTPStatus.Error()
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return "webarchive_timeout"
	default:
		return sanitizeError(err)
	}
}
