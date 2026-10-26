//go:build darwin

package server

import (
	"os"
	"strings"
	"syscall"
)

func fileSystemIsAPFS(file *os.File) (bool, error) {
	var stat syscall.Statfs_t
	if err := syscall.Fstatfs(int(file.Fd()), &stat); err != nil {
		return false, err
	}
	var name strings.Builder
	for _, ch := range stat.Fstypename {
		if ch == 0 {
			break
		}
		name.WriteByte(byte(ch))
	}
	return strings.EqualFold(name.String(), "apfs"), nil
}
