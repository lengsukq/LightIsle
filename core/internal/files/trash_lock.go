package files

import (
	"errors"
	"sync"
	"syscall"
)

// Different managers can hold separate descriptors for the same physical
// root. Fixed-size lock striping keeps their trash transitions serialized
// without retaining a growing registry of paths or disk identities.
var trashMutationLocks [256]sync.Mutex

func (s *Store) lockTrash() (func(), error) {
	info, err := s.root.Stat(".")
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Ino == 0 {
		return nil, errors.New("trash_identity_unavailable")
	}
	index := (uint64(stat.Dev)*0x9e3779b97f4a7c15 ^ uint64(stat.Ino)) % uint64(len(trashMutationLocks))
	mutex := &trashMutationLocks[index]
	mutex.Lock()
	return mutex.Unlock, nil
}
