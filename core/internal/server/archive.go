package server

import (
	"archive/zip"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

var (
	errArchiveLimit      = errors.New("archive_limit_exceeded")
	errArchivePermission = errors.New("archive_permission_changed")
)

// Bounded, read-only exports. A folder larger than these limits must be
// downloaded in smaller parts; never buffer an unbounded folder on the NAS.
const (
	archiveMaxEntries = 2000
	archiveMaxBytes   = int64(2) << 30
	archiveMaxDepth   = 16
)

type archiveItem struct {
	path      string
	name      string
	size      int64
	modified  time.Time
	directory bool
}

// archivePlan checks limits and permissions before writing HTTP headers. An
// unreadable child is omitted, not leaked through the ZIP file's names.
func (a *API) archivePlan(session, folder string) ([]archiveItem, error) {
	if folder == "" || folder == "." || strings.HasPrefix(folder, "/") {
		return nil, files.ErrPath
	}
	items := make([]archiveItem, 0, 64)
	remaining := archiveMaxBytes
	var walk func(string, string, int) error
	walk = func(dir, zipPrefix string, depth int) error {
		if depth > archiveMaxDepth || len(items) >= archiveMaxEntries {
			return errArchiveLimit
		}
		if !a.auth.CanAccess(session, dir, false, false) {
			return errArchivePermission
		}
		items = append(items, archiveItem{path: dir, name: zipPrefix + "/", directory: true})
		entries, err := a.files.List(dir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if !a.auth.CanAccess(session, entry.Path, false, false) {
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
	plan, err := a.archivePlan(token(r), folder)
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
	if err := a.writeFolderZip(w, r, plan); err != nil {
		slog.Warn("archive interrupted; aborting incomplete download", "error", err)
		// Do not finalize an incomplete ZIP as a valid HTTP 200 response.
		// net/http handles ErrAbortHandler by closing HTTP/1 connections or
		// resetting HTTP/2 streams without sending a misleading success body.
		panic(http.ErrAbortHandler)
	}
}

func (a *API) writeFolderZip(w io.Writer, r *http.Request, plan []archiveItem) error {
	z := zip.NewWriter(w)
	for _, item := range plan {
		if err := r.Context().Err(); err != nil {
			return err
		}
		if !a.auth.CanAccess(token(r), item.path, false, false) {
			return errArchivePermission
		}
		h := &zip.FileHeader{Name: item.name, Method: zip.Deflate}
		if item.directory {
			h.SetMode(os.ModeDir | 0755)
			h.Method = zip.Store
		} else {
			h.SetMode(0644)
			h.Modified = item.modified
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
		if info.Size() != item.size {
			f.Close()
			return errors.New("archive_source_changed")
		}
		copied, copyErr := io.CopyN(dest, f, item.size)
		closeErr := f.Close()
		if copyErr != nil || closeErr != nil || copied != item.size {
			return errors.Join(copyErr, closeErr)
		}
	}
	return z.Close()
}
