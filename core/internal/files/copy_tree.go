package files

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strings"
)

const maxCopyEntries = 20000
const maxCopyBytes = int64(50) << 30

type contextReader struct {
	ctx  context.Context
	file *os.File
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.file.Read(p)
}

// copyVerified writes only to a staging file. It fsyncs the exact byte count,
// and independently re-reads both source and destination to detect concurrent
// source mutation or silent copy corruption before publication.
func copyVerified(ctx context.Context, dst, src *os.File, size int64) error {
	if size < 0 || size > maxCopyBytes {
		return ErrSize
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	written, err := io.Copy(dst, io.LimitReader(contextReader{ctx, src}, size+1))
	if err != nil {
		return err
	}
	if written != size {
		return fmt.Errorf("source_changed_during_copy")
	}
	if err := dst.Sync(); err != nil {
		return err
	}
	if _, err := dst.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return err
	}
	var sums [2][32]byte
	for i, f := range []*os.File{src, dst} {
		digest := sha256.New()
		n, err := io.Copy(digest, io.LimitReader(contextReader{ctx, f}, size+1))
		if err != nil {
			return err
		}
		if n != size {
			return fmt.Errorf("source_changed_during_copy")
		}
		copy(sums[i][:], digest.Sum(nil))
	}
	if sums[0] != sums[1] {
		return fmt.Errorf("copy_checksum_mismatch")
	}
	return ctx.Err()
}

// copyDirectory builds a complete private sibling tree before publishing its
// root in one RENAME_EXCL. Partial failure never publishes destination files.
// It rejects symlinks, sockets, and unsupported source entries rather than
// silently omitting anything; it also limits total entry and byte counts.
func (s *Store) copyDirectory(ctx context.Context, src, dst string) error {
	if dst == src || strings.HasPrefix(dst, src+"/") {
		return ErrPath
	}
	if _, err := s.safePath(src, false, false); err != nil {
		return err
	}
	if _, err := s.safePath(dst, false, true); err != nil {
		return err
	}
	if _, err := s.root.Lstat(dst); err == nil {
		return ErrExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if info, err := s.root.Stat(path.Dir(dst)); err != nil {
		return err
	} else if !info.IsDir() {
		return ErrType
	}

	stage := path.Join(path.Dir(dst), ".lightisle-copy-"+randomName())
	if err := s.root.Mkdir(stage, 0700); err != nil {
		return err
	}
	defer s.root.RemoveAll(stage)
	target, err := s.root.OpenRoot(stage)
	if err != nil {
		return err
	}
	defer target.Close()
	pending := []string{"."}
	entries := 0
	var total int64
	for len(pending) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		rel := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		sourceDir := path.Join(src, rel)
		parent, err := s.openDirNoFollow(sourceDir)
		if err != nil {
			return err
		}
		start, err := parent.Stat()
		if err != nil {
			parent.Close()
			return err
		}
		if !start.IsDir() {
			parent.Close()
			return ErrType
		}
		for {
			if err := ctx.Err(); err != nil {
				parent.Close()
				return err
			}
			batch, readErr := parent.ReadDir(128)
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				parent.Close()
				return readErr
			}
			for _, item := range batch {
				name := item.Name()
				itemRel := name
				if rel != "." {
					itemRel = path.Join(rel, name)
				}
				if _, err := validate(itemRel, false); err != nil {
					parent.Close()
					return err
				}
				info, err := statEntryNoFollow(parent, name)
				if err != nil {
					parent.Close()
					return fmt.Errorf("unsupported_source_entry: %w", err)
				}
				entries++
				if entries > maxCopyEntries {
					parent.Close()
					return ErrSize
				}
				if info.IsDir() {
					if err := target.Mkdir(itemRel, 0700); err != nil {
						parent.Close()
						return err
					}
					pending = append(pending, itemRel)
					continue
				}
				if !info.Mode().IsRegular() {
					parent.Close()
					return ErrType
				}
				if info.Size() > maxCopyBytes-total {
					parent.Close()
					return ErrSize
				}
				total += info.Size()
				in, _, err := s.Read(path.Join(src, itemRel))
				if err != nil {
					parent.Close()
					return err
				}
				out, err := target.OpenFile(itemRel, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
				if err != nil {
					in.Close()
					parent.Close()
					return err
				}
				e := copyVerified(ctx, out, in, info.Size())
				closeErr := out.Close()
				in.Close()
				if e == nil {
					e = closeErr
				}
				if e != nil {
					parent.Close()
					return e
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
		}
		end, err := parent.Stat()
		parent.Close()
		if err != nil {
			return err
		}
		if !os.SameFile(start, end) || !start.ModTime().Equal(end.ModTime()) {
			return fmt.Errorf("source_directory_changed_during_copy")
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.renameExclusive(stage, dst)
}
