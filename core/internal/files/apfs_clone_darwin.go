//go:build darwin

package files

/*
#include <stdint.h>
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

typedef struct __attribute__((aligned(4), packed)) {
	uint32_t        length;
	attribute_set_t returned;
	off_t           private_size;
	uint64_t        clone_id;
	uint32_t        clone_refcnt;
} lightisle_clone_attrbuf_t;

static int lightisle_fgetattr_clone(int fd, int64_t *private_size, uint64_t *clone_id, uint32_t *clone_refcnt) {
	struct attrlist alist;
	memset(&alist, 0, sizeof(alist));
	alist.bitmapcount = ATTR_BIT_MAP_COUNT;
	alist.commonattr  = ATTR_CMN_RETURNED_ATTRS;
	alist.forkattr    = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;

	lightisle_clone_attrbuf_t buf;
	memset(&buf, 0, sizeof(buf));
	if (fgetattrlist(fd, &alist, &buf, sizeof(buf), FSOPT_ATTR_CMN_EXTENDED) != 0) {
		return -1;
	}
	uint32_t need = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;
	if ((buf.returned.forkattr & need) != need) {
		return -1;
	}
	*private_size = (int64_t)buf.private_size;
	*clone_id     = buf.clone_id;
	*clone_refcnt = buf.clone_refcnt;
	return 0;
}
*/
import "C"

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

type apfsCloneInfo struct {
	supported   bool
	device      uint64
	inode       uint64
	nlink       uint64
	cloneID     uint64
	cloneRefCnt uint32
	privateSize int64
}

func inspectAPFSClone(file *os.File, info os.FileInfo) apfsCloneInfo {
	var out apfsCloneInfo
	if info != nil {
		switch st := info.Sys().(type) {
		case *unix.Stat_t:
			out.device, out.inode, out.nlink = uint64(st.Dev), st.Ino, uint64(st.Nlink)
		case *syscall.Stat_t:
			out.device, out.inode, out.nlink = uint64(st.Dev), st.Ino, uint64(st.Nlink)
		}
	}
	if file == nil {
		return out
	}
	var privSize C.int64_t
	var cloneID C.uint64_t
	var refCnt C.uint32_t
	if C.lightisle_fgetattr_clone(C.int(file.Fd()), &privSize, &cloneID, &refCnt) == 0 && uint64(cloneID) != 0 {
		out.supported = true
		out.privateSize = int64(privSize)
		out.cloneID = uint64(cloneID)
		out.cloneRefCnt = uint32(refCnt)
	}
	return out
}
