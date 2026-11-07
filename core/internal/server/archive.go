package server

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

var (
	errArchiveLimit      = errors.New("archive_limit_exceeded")
	errArchivePermission = errors.New("archive_permission_changed")
)

// Bounded, read-only exports. A folder larger than these limits must be
// downloaded in smaller parts; never buffer an unbounded folder on the NAS.
const (
	archiveMaxEntries    = 2000
	archiveMaxBytes      = int64(2) << 30
	archiveMaxDepth      = 16
	archiveMaxScanned    = 5000
	archiveMaxConcurrent = 2
)

// Share the budget across every root and both authenticated and public ZIPs.
var archiveSlots = make(chan struct{}, archiveMaxConcurrent)

func acquireArchiveSlot(w http.ResponseWriter, public bool) bool {
	select {
	case archiveSlots <- struct{}{}:
		return true
	default:
		w.Header().Set("Retry-After", "5")
		if public {
			http.Error(w, "当前打包下载较多，请稍后重试。", http.StatusTooManyRequests)
		} else {
			jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "archive_busy"})
		}
		return false
	}
}

type archiveItem struct {
	path      string
	name      string
	size      int64
	modified  time.Time
	directory bool
	// Nonempty for explicitly selected indexed media. The streamed object must
	// still be the same one the user selected, not a same-name replacement.
	identity string
}

// archivePlan checks limits and permissions before writing HTTP headers. An
// unreadable child is omitted, not leaked through the ZIP file's names.
func (a *API) archivePlan(ctx context.Context, session, folder string) ([]archiveItem, error) {
	return a.archivePlanAuthorized(ctx, folder, func(p string) bool {
		return a.canAccess(session, p, false, false)
	})
}

// shareArchivePlan is the public-link variant: authorization follows the link
// owner's current grants instead of a live session, so revoked subdirectories
// drop out of the export on every request.
func (a *API) shareArchivePlan(ctx context.Context, access auth.ShareAccess, folder string) ([]archiveItem, error) {
	return a.archivePlanAuthorized(ctx, folder, a.shareEntryCheck(access))
}

func (a *API) archivePlanAuthorized(ctx context.Context, folder string, canRead func(string) bool) ([]archiveItem, error) {
	if folder == "" || folder == "." || strings.HasPrefix(folder, "/") {
		return nil, files.ErrPath
	}
	items := make([]archiveItem, 0, 64)
	remaining := archiveMaxBytes
	scanned := 0
	var walk func(string, string, int) error
	walk = func(dir, zipPrefix string, depth int) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if depth > archiveMaxDepth || len(items) >= archiveMaxEntries {
			return errArchiveLimit
		}
		if !canRead(dir) {
			return errArchivePermission
		}
		items = append(items, archiveItem{path: dir, name: zipPrefix + "/", directory: true})
		// Listing through cursor pages supports directories with more than the
		// legacy List() 1,500-entry ceiling and bounds metadata held in memory.
		cursor := ""
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			entries, next, err := a.files.Page(dir, cursor, 200)
			if err != nil {
				return err
			}
			for _, entry := range entries {
				scanned++
				if scanned > archiveMaxScanned {
					return errArchiveLimit
				}
				if !canRead(entry.Path) {
					continue
				}
				if len(items) >= archiveMaxEntries {
					return errArchiveLimit
				}
				name := zipPrefix + "/" + entry.Name
				switch entry.Type {
				case "folder":
					if err := walk(entry.Path, name, depth+1); err != nil {
						return err
					}
				case "file":
					if entry.Size < 0 || entry.Size > remaining {
						return errArchiveLimit
					}
					remaining -= entry.Size
					items = append(items, archiveItem{path: entry.Path, name: name, size: entry.Size, modified: entry.Modified})
				}
			}
			if next == "" {
				break
			}
			cursor = next
		}
		return nil
	}
	if err := walk(folder, path.Base(folder), 0); err != nil {
		return nil, err
	}
	return items, nil
}

func (a *API) downloadFolderArchive(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	folder := r.URL.Query().Get("path")
	if folder == "" || folder == "." {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "archive_folder_required"})
		return
	}
	if !a.allowFile(w, r, folder, false) {
		return
	}
	if !acquireArchiveSlot(w, false) {
		return
	}
	defer func() { <-archiveSlots }()
	plan, err := a.archivePlan(r.Context(), token(r), folder)
	if err != nil {
		if errors.Is(err, errArchiveLimit) {
			jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
		} else if errors.Is(err, errArchivePermission) {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		} else {
			fileError(w, err)
		}
		return
	}
	// Check every file is still a readable regular file before starting the
	// response. During streaming re-open through the share's safe read API.
	for _, item := range plan {
		if r.Context().Err() != nil {
			return
		}
		if item.directory {
			continue
		}
		f, info, err := a.files.Read(item.path)
		if err != nil {
			fileError(w, err)
			return
		}
		closeErr := f.Close()
		if closeErr != nil || info.Size() != item.size {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "archive_source_changed"})
			return
		}
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": path.Base(folder) + ".zip"}))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if err := a.writeFolderZip(w, r, plan, func(p string) bool {
		return a.canAccess(token(r), p, false, false)
	}); err != nil {
		slog.Warn("archive interrupted; aborting incomplete download", "error", err)
		// Do not finalize an incomplete ZIP as a valid HTTP 200 response.
		// net/http handles ErrAbortHandler by closing HTTP/1 connections or
		// resetting HTTP/2 streams without sending a misleading success body.
		panic(http.ErrAbortHandler)
	}
}

// Refresh the write deadline as data is sent so a stopped client cannot
// hold the compression slot forever. Middleware can expose its underlying
// writer via Unwrap; in-memory recorders do not support deadlines.
type archiveStreamWriter struct {
	writer http.ResponseWriter
	ctx    context.Context
}

func (w archiveStreamWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	deadline := time.Now().Add(time.Minute)
	if err := http.NewResponseController(w.writer).SetWriteDeadline(deadline); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return 0, err
	}
	return w.writer.Write(p)
}

func (a *API) writeFolderZip(w http.ResponseWriter, r *http.Request, plan []archiveItem, canRead func(string) bool) error {
	z := zip.NewWriter(archiveStreamWriter{writer: w, ctx: r.Context()})
	for _, item := range plan {
		if err := r.Context().Err(); err != nil {
			return err
		}
		if !canRead(item.path) {
			return errArchivePermission
		}
		h := &zip.FileHeader{Name: item.name, Method: zip.Deflate}
		if item.directory {
			h.SetMode(os.ModeDir | 0755)
			h.Method = zip.Store
		} else {
			h.SetMode(0644)
			h.Modified = item.modified
			if item.identity != "" {
				h.Method = zip.Store // photos/videos are already compressed
			}
		}
		dest, err := z.CreateHeader(h)
		if err != nil {
			return err
		}
		if item.directory {
			continue
		}
		f, info, err := a.files.Read(item.path)
		if err != nil {
			return err
		}
		if info.Size() != item.size || (item.identity != "" &&
			(files.MediaFileIdentity(info) != item.identity || !info.ModTime().Equal(item.modified))) {
			f.Close()
			return errors.New("archive_source_changed")
		}
		copied, copyErr := io.CopyN(dest, f, item.size)
		if copyErr == nil && item.identity != "" {
			info, statErr := f.Stat()
			if statErr != nil || files.MediaFileIdentity(info) != item.identity || info.Size() != item.size || !info.ModTime().Equal(item.modified) {
				copyErr = errors.New("archive_source_changed")
			}
		}
		closeErr := f.Close()
		if copyErr != nil || closeErr != nil || copied != item.size {
			return errors.Join(copyErr, closeErr)
		}
		if item.identity != "" && !canRead(item.path) {
			return errArchivePermission
		}
	}
	return z.Close()
}
