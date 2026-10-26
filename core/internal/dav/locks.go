package dav

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"sync"
	"time"

	"golang.org/x/net/webdav"
)

// memLS uses decimal sequence tokens internally. Externally supplied tokens
// that are not owned by this namespace must never be forwarded unchanged.
const unknownInnerLockToken = "__lightisle_dav_unknown_lock_token__"

type lockOwner struct {
	userID     int64
	name       string
	root       os.FileInfo
	innerToken string
	expires    time.Time
	temporary  bool
}

// lockNamespace contains all lock state for one physical share root. The
// service retains only its current namespace; switching roots intentionally
// drops the old in-memory locks, and switching back starts a fresh namespace.
type lockNamespace struct {
	inner  webdav.LockSystem
	root   os.FileInfo
	mu     sync.Mutex
	owners map[string]lockOwner
}

func (s *Service) lockNamespaceFor(root os.FileInfo) *lockNamespace {
	s.lockMu.Lock()
	defer s.lockMu.Unlock()
	if s.lockNS != nil && sameIdentity(s.lockNS.root, root) {
		return s.lockNS
	}
	namespace := &lockNamespace{
		inner:  webdav.NewMemLS(),
		root:   root,
		owners: map[string]lockOwner{},
	}
	s.lockNS = namespace
	return namespace
}

func (n *lockNamespace) cleanupExpiredLocked(now time.Time) {
	for token, record := range n.owners {
		if !record.expires.IsZero() && !now.Before(record.expires) {
			_ = n.inner.Unlock(now, record.innerToken)
			delete(n.owners, token)
		}
	}
}

func (n *lockNamespace) setOwner(token string, record lockOwner, now time.Time) {
	n.mu.Lock()
	n.cleanupExpiredLocked(now)
	n.owners[token] = record
	n.mu.Unlock()
}

func (n *lockNamespace) removeOwner(token string) {
	n.mu.Lock()
	delete(n.owners, token)
	n.mu.Unlock()
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
	service     *Service
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
	return l.inner.Confirm(now, name0, name1, innerConditions...)
}

func (l *ownedLockSystem) Create(now time.Time, details webdav.LockDetails) (string, error) {
	name, err := normalizeDAVName(details.Root)
	temporary := (l.state.method == "COPY" || l.state.method == "MOVE") && name != l.requestPath
	if err != nil || (name != l.requestPath && !temporary) {
		return "", webdav.ErrForbidden
	}
	details.Root = name
	innerToken, err := l.inner.Create(now, details)
	if err != nil {
		return "", err
	}
	token, err := newLockToken()
	if err != nil {
		_ = l.inner.Unlock(now, innerToken)
		return "", err
	}
	record := lockOwner{userID: l.state.user.ID, name: name, root: l.state.root.info, innerToken: innerToken, temporary: temporary}
	if details.Duration >= 0 {
		record.expires = now.Add(details.Duration)
	}
	l.namespace.setOwner(token, record, now)
	return token, nil
}

func (l *ownedLockSystem) Refresh(now time.Time, token string, duration time.Duration) (webdav.LockDetails, error) {
	record, ok := l.namespace.owner(token, now)
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
	l.namespace.setOwner(token, record, now)
	return details, nil
}

func (l *ownedLockSystem) Unlock(now time.Time, token string) error {
	record, ok := l.namespace.owner(token, now)
	if !ok || !l.owns(record, l.requestPath) {
		return webdav.ErrForbidden
	}
	if err := l.inner.Unlock(now, record.innerToken); err != nil {
		return err
	}
	l.namespace.removeOwner(token)
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
	pathMatches := record.name == name || (record.temporary && (l.state.method == "COPY" || l.state.method == "MOVE"))
	return err == nil && record.userID == l.state.user.ID && pathMatches &&
		sameIdentity(record.root, l.state.root.info) && sameIdentity(l.namespace.root, l.state.root.info) &&
		l.state.root.current()
}

var _ webdav.LockSystem = (*ownedLockSystem)(nil)
