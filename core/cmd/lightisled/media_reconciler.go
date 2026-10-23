//go:build darwin && arm64

package main

import (
	"context"
	"time"
)

// mediaReconciler coalesces bursts of filesystem events. If an existing scan
// is still active, retry after it completes rather than silently dropping
// changes received during that scan.
type mediaReconciler struct {
	requests chan struct{}
	attempts []func() bool // one per library: true when this library was busy
	periodic time.Duration
	retry    time.Duration
	startup  time.Duration
}

func newMediaReconciler(attempts ...func() bool) *mediaReconciler {
	return &mediaReconciler{
		requests: make(chan struct{}, 1), attempts: attempts,
		periodic: 15 * time.Minute, retry: 5 * time.Second, startup: 30 * time.Second,
	}
}
func (m *mediaReconciler) Request() {
	select {
	case m.requests <- struct{}{}:
	default:
	}
}

// requestMediaReconciliationAfterShareOnline starts a full reconciliation
// after an owner explicitly selects or reconnects the verified share. The new
// watcher starts at FSEvents' current point and cannot report changes made
// while that share was offline.
func requestMediaReconciliationAfterShareOnline(m *mediaReconciler) {
	if m != nil {
		m.Request()
	}
}

func (m *mediaReconciler) Run(ctx context.Context) {
	periodic := time.NewTicker(m.periodic)
	defer periodic.Stop()
	initial := time.NewTimer(m.startup)
	defer initial.Stop()
	var retry *time.Timer
	var retryC <-chan time.Time
	defer func() {
		if retry != nil {
			retry.Stop()
		}
	}()
	pending := make([]bool, len(m.attempts))
	attempt := func(refreshAll bool) {
		if refreshAll {
			for i := range pending {
				pending[i] = true
			}
		}
		busy := false
		for i, start := range m.attempts {
			if !pending[i] {
				continue
			}
			pending[i] = start()
			busy = busy || pending[i]
		}
		if busy {
			if retry == nil {
				retry = time.NewTimer(m.retry)
			} else {
				retry.Reset(m.retry)
			}
			retryC = retry.C
		} else {
			if retry != nil {
				retry.Stop()
			}
			retryC = nil
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-initial.C:
			attempt(true)
		case <-periodic.C:
			attempt(true)
		case <-m.requests:
			attempt(true)
		case <-retryC:
			attempt(false)
		}
	}
}
