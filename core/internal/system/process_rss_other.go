//go:build !(darwin && arm64)

package system

func ProcessResidentBytes(pid int) int64 {
	return 0
}
