package downloads

import (
	"context"
	"errors"
	"fmt"
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
		_ = os.RemoveAll(staging)
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

	stagePath := filepath.Join(staging, fmt.Sprintf(".archive-%d.html", token))
	res, archiveErr := webarchive.ArchiveToFile(runCtx, task.URL, stagePath, archiveOpts)

	m.importMu.Lock()
	defer m.importMu.Unlock()
	if !m.isActiveRunToken(id, token) {
		_ = os.Remove(stagePath)
		if !m.hasActiveRun(id) {
			if current, _, readErr := m.rowByIDUnscoped(id); errors.Is(readErr, ErrNotFound) || (readErr == nil && current.Status == StatusCancelled) {
				_ = os.RemoveAll(staging)
			}
		}
		return
	}
	m.clearTaskCancel(id, token)
	current, _, readErr := m.rowByIDUnscoped(id)
	if errors.Is(readErr, ErrNotFound) {
		_ = os.RemoveAll(staging)
		return
	}
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
		_ = os.RemoveAll(staging)
		m.failTask(id, webArchiveErrorCode(runCtx, archiveErr), "")
		return
	}
	targetName := "archive.html"
	if res.SuggestedName != "" {
		targetName = filepath.Base(res.SuggestedName)
	}
	targetPath := filepath.Join(staging, targetName)
	if renameErr := os.Rename(stagePath, targetPath); renameErr != nil {
		_ = os.RemoveAll(staging)
		m.failTask(id, "download_staging_failed", "")
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
