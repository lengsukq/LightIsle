//go:build !darwin

package files

import "os"

type apfsCloneInfo struct {
	supported   bool
	device      uint64
	inode       uint64
	nlink       uint64
	cloneID     uint64
	cloneRefCnt uint32
	privateSize int64
}

func inspectAPFSClone(_ *os.File, _ os.FileInfo) apfsCloneInfo {
	return apfsCloneInfo{}
}
