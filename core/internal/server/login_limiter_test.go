package server

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestLoginLimiterThresholdResetAndWindow(t *testing.T) {
	limiter := newLoginLimiter()
	now := time.Unix(1_800_000_000, 0)
	limiter.now = func() time.Time { return now }

	for attempt := 0; attempt < loginAttemptLimit; attempt++ {
		if !limiter.admit("192.168.1.10:1234", "leo") {
			t.Fatalf("failure attempt %d unexpectedly rejected", attempt+1)
		}
	}
	if limiter.admit("192.168.1.10:1234", "leo") {
		t.Fatal("account lockout did not trigger after six failed attempts")
	}
	limiter.cancel("192.168.1.10:1234", "leo")
	if !limiter.admit("192.168.1.10:1234", "leo") {
		t.Fatal("cancelled reservation was not released")
	}
	limiter.success("192.168.1.10:1234", "leo")
	if !limiter.admit("192.168.1.10:1234", "leo") {
		t.Fatal("successful login did not release its reserved attempt")
	}

	now = now.Add(loginWindow)
	if !limiter.admit("192.168.1.10:1234", "leo") {
		t.Fatal("expired attempt bucket was not cleared")
	}
}

func TestLoginLimiterConcurrentAdmissionIsAtomic(t *testing.T) {
	limiter := newLoginLimiter()
	const requests = 64
	var admitted int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < requests; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if limiter.admit("192.168.1.20:1234", "shared-account") {
				mu.Lock()
				admitted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if admitted != loginAttemptLimit {
		t.Fatalf("concurrent requests admitted %d attempts, want %d", admitted, loginAttemptLimit)
	}
}

func TestLoginLimiterSharedEgressDoesNotLockOtherAccounts(t *testing.T) {
	limiter := newLoginLimiter()
	now := time.Unix(1_800_000_000, 0)
	limiter.now = func() time.Time { return now }

	const shared = "203.0.113.7:40000"
	for attempt := 0; attempt < loginAttemptLimit; attempt++ {
		if !limiter.admit(shared, "alice") {
			t.Fatalf("alice attempt %d rejected", attempt+1)
		}
	}
	if limiter.admit(shared, "alice") {
		t.Fatal("alice was not locked out")
	}
	if !limiter.admit(shared, "bob") {
		t.Fatal("alice's lockout blocked bob behind the same egress address")
	}
	limiter.success(shared, "bob")
	if !limiter.admit(shared, "carol") {
		t.Fatal("alice's lockout blocked carol behind the same egress address")
	}
	limiter.success(shared, "carol")
	if limiter.admit("198.51.100.9:1234", "alice") {
		t.Fatal("account lockout was bypassed by changing remote address")
	}

	// The shared address still has an overall spraying budget; once it is
	// exhausted, any account is refused until the window expires.
	remoteBudget := loginRemoteAttemptLimit - loginAttemptLimit
	for attempt := 0; attempt < remoteBudget; attempt++ {
		if !limiter.admit(shared, fmt.Sprintf("spray-%d", attempt)) {
			t.Fatalf("spray attempt %d rejected before the remote budget ran out", attempt+1)
		}
	}
	if limiter.admit(shared, "newcomer") {
		t.Fatal("remote spraying budget was not enforced")
	}

	now = now.Add(loginWindow)
	if !limiter.admit(shared, "newcomer") {
		t.Fatal("expired remote budget was not cleared")
	}
}

func TestLoginLimiterCapacityPreservesActiveLockouts(t *testing.T) {
	limiter := newLoginLimiter()
	now := time.Unix(1_800_000_000, 0)
	limiter.now = func() time.Time { return now }

	const lockedRemote = "192.168.1.1:1000"
	const lockedAccount = "locked"
	for i := 0; i < loginAttemptLimit; i++ {
		if !limiter.admit(lockedRemote, lockedAccount) {
			t.Fatalf("locked fixture attempt %d rejected", i+1)
		}
	}

	for i := 0; len(limiter.entries) < loginLimiterKeys; i++ {
		remote := fmt.Sprintf("10.%d.%d.%d:%d", (i>>16)&255, (i>>8)&255, i&255, 1000+i)
		if !limiter.admit(remote, fmt.Sprintf("capacity-%d", i)) {
			t.Fatalf("capacity fixture %d rejected", i)
		}
	}
	if limiter.admit("192.168.3.1:3000", "late") {
		t.Fatal("new key should be refused when limiter is at capacity")
	}
	if limiter.admit(lockedRemote, lockedAccount) {
		t.Fatal("capacity handling cleared an active lockout")
	}
	if len(limiter.entries) != loginLimiterKeys {
		t.Fatalf("limiter grew beyond capacity: %d", len(limiter.entries))
	}

	now = now.Add(loginWindow)
	if !limiter.admit("192.168.3.1:1000", "fresh") {
		t.Fatal("expired entries did not make capacity available")
	}
}
