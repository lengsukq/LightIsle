package dav

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"
)

// memLS uses decimal sequence tokens internally. Externally supplied tokens
// that are not owned by this namespace must never be forwarded unchanged.
const unknownInnerLockToken = "__lightisle_dav_unknown_lock_token__"

const (
	maxDAVLocks           = 1024
	maxPersistentDAVLocks = 512
	maxDAVLocksPerUser    = 64
	maxDAVLockSeconds     = 1800
)

// Leave malformed values to WebDAV's parser. Cap valid requests before
// dispatch so the returned lock XML advertises the actual expiration.
func boundedLockTimeout(header string) string {
	first, _, _ := strings.Cut(header, ",")
	first = strings.TrimSpace(first)
	if header == "" || first == "Infinite" {
		return "Second-" + strconv.Itoa(maxDAVLockSeconds)
	}
	value, ok := strings.CutPrefix(first, "Second-")
	if !ok || value == "" || value[0] < '0' || value[0] > '9' {
		return header
	}
	if seconds, err := strconv.ParseUint(value, 10, 32); err == nil && seconds > maxDAVLockSeconds {
		return "Second-" + strconv.Itoa(maxDAVLockSeconds)
	}
	return header
}

type lockOwner struct {
	userID     int64
	name       string
	root       os.FileInfo
	innerToken string
	expires    time.Time
	temporary  bool
}

// lockNamespace contains all lock state for one physical root and generation.
type lockNamespace struct {
	inner      webdav.LockSystem
	root       os.FileInfo
	generation uint64
	mu         sync.Mutex
	owners     map[string]lockOwner
}

func (s *Service) lockNamespaceFor(root *rootHandle) *lockNamespace {
	s.lockMu.Lock()
	defer s.lockMu.Unlock()
	if root.rootID == "" {
		if s.lockNS == nil || !sameIdentity(s.lockNS.root, root.info) {
			s.lockNS = newLockNamespace(root)
		}
		return s.lockNS
	}
	if s.rootLocks == nil {
		s.rootLocks = make(map[string]*lockNamespace)
	}
	for id, namespace := range s.rootLocks {
		record, ok := s.registry.Lookup(id)
		if !ok || record.Generation != namespace.generation {
			delete(s.rootLocks, id)
		}
	}
	namespace := s.rootLocks[root.rootID]
	if namespace == nil || !sameIdentity(namespace.root, root.info) {
		namespace = newLockNamespace(root)
		s.rootLocks[root.rootID] = namespace
	}
	return namespace
}

func newLockNamespace(root *rootHandle) *lockNamespace {
	return &lockNamespace{
		inner:      webdav.NewMemLS(),
		root:       root.info,
		generation: root.generation,
		owners:     map[string]lockOwner{},
	}
}

func (n *lockNamespace) cleanupExpiredLocked(now time.Time) {
	for token, record := range n.owners {
		if !record.expires.IsZero() && !now.Before(record.expires) {
			_ = n.inner.Unlock(now, record.innerToken)
			delete(n.owners, token)
		}
	}
}

func (n *lockNamespace) owner(token string, now time.Time) (lockOwner, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.cleanupExpiredLocked(now)
	record, ok := n.owners[token]
	return record, ok
}

// ownedLockSystem keeps x/net/webdav's lock semantics while binding lock
// refresh, unlock and token use to the DAV account and pinned share root that
// created each token.
type ownedLockSystem struct {
	inner       webdav.LockSystem
	namespace   *lockNamespace
	state       *requestState
	requestPath string
}

func (l *ownedLockSystem) Confirm(now time.Time, name0, name1 string, conditions ...webdav.Condition) (func(), error) {
	innerConditions := append([]webdav.Condition(nil), conditions...)
	for i := range innerConditions {
		condition := &innerConditions[i]
		if condition.Token == "" {
			continue
		}
		if condition.Not {
			condition.Token = unknownInnerLockToken
			continue
		}
		record, ok := l.namespace.owner(condition.Token, now)
		if ok && !l.owns(record, record.name) {
			return nil, webdav.ErrConfirmationFailed
		}
		if ok {
			condition.Token = record.innerToken
		} else {
			condition.Token = unknownInnerLockToken
		}
	}
	release, err := l.inner.Confirm(now, strings.ToLower(name0), strings.ToLower(name1), innerConditions...)
	if err == nil && l.state.copyUnlocks != nil {
		*l.state.copyUnlocks = append(*l.state.copyUnlocks, release)
		return func() {}, nil
	}
	return release, err
}

func (l *ownedLockSystem) Create(now time.Time, details webdav.LockDetails) (string, error) {
	name, err := normalizeDAVName(details.Root)
	temporary := (l.state.method == "COPY" || l.state.method == "MOVE") && name != l.requestPath
	if err != nil || (name != l.requestPath && !temporary) {
		return "", webdav.ErrForbidden
	}
	// Different case spellings can resolve to the same APFS resource.
	details.Root = strings.ToLower(name)
	ns := l.namespace
	ns.mu.Lock()
	defer ns.mu.Unlock()
	ns.cleanupExpiredLocked(now)
	if len(ns.owners) >= maxDAVLocks {
		return "", webdav.ErrLocked
	}
	if l.state.method == "LOCK" {
		persistent, owned := 0, 0
		for _, record := range ns.owners {
			if !record.expires.IsZero() {
				persistent++
				if record.userID == l.state.user.ID {
					owned++
				}
			}
		}
		if persistent >= maxPersistentDAVLocks || owned >= maxDAVLocksPerUser {
			return "", webdav.ErrLocked
		}
	}
	token, err := newLockToken()
	if err != nil {
		return "", err
	}
	innerToken, err := l.inner.Create(now, details)
	if err != nil {
		return "", err
	}
	record := lockOwner{userID: l.state.user.ID, name: name, root: l.state.root.info, innerToken: innerToken, temporary: temporary}
	if details.Duration >= 0 {
		record.expires = now.Add(details.Duration)
	}
	ns.owners[token] = record
	return token, nil
}

func (l *ownedLockSystem) Refresh(now time.Time, token string, duration time.Duration) (webdav.LockDetails, error) {
	ns := l.namespace
	ns.mu.Lock()
	defer ns.mu.Unlock()
	ns.cleanupExpiredLocked(now)
	record, ok := ns.owners[token]
	if !ok || !l.owns(record, l.requestPath) {
		return webdav.LockDetails{}, webdav.ErrForbidden
	}
	details, err := l.inner.Refresh(now, record.innerToken, duration)
	if err != nil {
		return webdav.LockDetails{}, err
	}
	if duration >= 0 {
		record.expires = now.Add(duration)
	} else {
		record.expires = time.Time{}
	}
	ns.owners[token] = record
	details.Root = record.name
	return details, nil
}

func (l *ownedLockSystem) Unlock(now time.Time, token string) error {
	if l.state.copyUnlocks != nil {
		*l.state.copyUnlocks = append(*l.state.copyUnlocks, func() { _ = l.unlock(now, token) })
		return nil
	}
	return l.unlock(now, token)
}

func (l *ownedLockSystem) unlock(now time.Time, token string) error {
	ns := l.namespace
	ns.mu.Lock()
	defer ns.mu.Unlock()
	ns.cleanupExpiredLocked(now)
	record, ok := ns.owners[token]
	if !ok || !(record.temporary && record.userID == l.state.user.ID || l.owns(record, l.requestPath)) {
		return webdav.ErrForbidden
	}
	if err := l.inner.Unlock(now, record.innerToken); err != nil {
		return err
	}
	delete(ns.owners, token)
	return nil
}

func newLockToken() (string, error) {
	var raw [24]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return "opaquelocktoken:" + hex.EncodeToString(raw[:]), nil
}

func (l *ownedLockSystem) owns(record lockOwner, name string) bool {
	name, err := normalizeDAVName(name)
	pathMatches := strings.EqualFold(record.name, name) || (record.temporary && (l.state.method == "COPY" || l.state.method == "MOVE"))
	return err == nil && record.userID == l.state.user.ID && pathMatches &&
		sameIdentity(record.root, l.state.root.info) && sameIdentity(l.namespace.root, l.state.root.info) &&
		l.state.root.current()
}

var _ webdav.LockSystem = (*ownedLockSystem)(nil)
