package server

import (
	"archive/zip"
	"errors"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/computerfiles"
	"golang.org/x/sys/unix"
)

type computerArchiveItem struct {
	path, name string
	info       os.FileInfo
	directory  bool
}

// Prepare a bounded plan before writing headers, then reopen each object while
// streaming. A changed source or revoked grant aborts the ZIP rather than
// returning a valid-looking partial archive.
func (a *API) computerFolderArchive(w http.ResponseWriter, r *http.Request) {
	if !acquireArchiveSlot(w, false) {
		return
	}
	defer func() { <-archiveSlots }()
	folder, err := computerfiles.Clean(r.URL.Query().Get("path"))
	if err != nil {
		computerFileError(w, err)
		return
	}
	base := filepath.Base(folder)
	if base == "/" || base == "." {
		base = "Mac"
	}
	items := []computerArchiveItem{}
	var total int64
	var walk func(string, string, int) error
	walk = func(path, name string, depth int) error {
		if err := r.Context().Err(); err != nil {
			return err
		}
		if depth > archiveMaxDepth || len(items) >= archiveMaxEntries {
			return errArchiveLimit
		}
		f, access, err := a.openComputerFile(r, path)
		if err != nil {
			return err
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || !info.IsDir() {
			return computerfiles.ErrPath
		}
		items = append(items, computerArchiveItem{path: path, name: name + "/", info: info, directory: true})
		for {
			dirs, e := f.ReadDir(128)
			if e != nil && !errors.Is(e, io.EOF) {
				return e
			}
			for _, dir := range dirs {
				if len(items) >= archiveMaxEntries {
					return errArchiveLimit
				}
				var st unix.Stat_t
				if err := unix.Fstatat(int(f.Fd()), dir.Name(), &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
					return err
				}
				child, childName := filepath.Join(path, dir.Name()), name+"/"+dir.Name()
				switch st.Mode & unix.S_IFMT {
				case unix.S_IFDIR:
					if err := walk(child, childName, depth+1); err != nil {
						return err
					}
				case unix.S_IFREG:
					file, childAccess, err := a.openComputerFile(r, child)
					if err != nil {
						return err
					}
					childInfo, statErr := file.Stat()
					file.Close()
					if statErr != nil || !childInfo.Mode().IsRegular() || !childAccess.valid() {
						return fs.ErrPermission
					}
					if childInfo.Size() < 0 || childInfo.Size() > archiveMaxBytes-total {
						return errArchiveLimit
					}
					total += childInfo.Size()
					items = append(items, computerArchiveItem{path: child, name: childName, info: childInfo})
				default:
					return computerfiles.ErrPath
				}
			}
			if !access.valid() {
				return fs.ErrPermission
			}
			if errors.Is(e, io.EOF) {
				break
			}
		}
		return nil
	}
	if err = walk(folder, base, 0); err != nil {
		if errors.Is(err, errArchiveLimit) {
			jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
		} else {
			computerFileError(w, err)
		}
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": base + ".zip"}))
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	z := zip.NewWriter(archiveStreamWriter{writer: w, ctx: r.Context()})
	for _, item := range items {
		f, access, err := a.openComputerFile(r, item.path)
		if err != nil {
			panic(http.ErrAbortHandler)
		}
		info, err := f.Stat()
		if err != nil || !os.SameFile(info, item.info) || info.Size() != item.info.Size() || !info.ModTime().Equal(item.info.ModTime()) || !access.valid() {
			f.Close()
			panic(http.ErrAbortHandler)
		}
		h := &zip.FileHeader{Name: strings.ReplaceAll(item.name, "\\", "_"), Method: zip.Deflate}
		if item.directory {
			h.SetMode(os.ModeDir | 0755)
			h.Method = zip.Store
		} else {
			h.SetMode(0644)
			h.Modified = info.ModTime()
		}
		out, err := z.CreateHeader(h)
		if err != nil {
			f.Close()
			panic(http.ErrAbortHandler)
		}
		if !item.directory {
			n, copyErr := io.CopyN(out, computerReader{f: f, access: access}, info.Size())
			after, statErr := f.Stat()
			if copyErr != nil || n != info.Size() || statErr != nil || after.Size() != info.Size() || !after.ModTime().Equal(info.ModTime()) || !access.valid() {
				f.Close()
				panic(http.ErrAbortHandler)
			}
		}
		f.Close()
	}
	if err := z.Close(); err != nil {
		panic(http.ErrAbortHandler)
	}
}
