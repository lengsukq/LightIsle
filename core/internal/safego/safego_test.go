package safego

import (
	"sync"
	"testing"
)

func TestGoRecoversPanic(t *testing.T) {
	var wg sync.WaitGroup
	wg.Add(1)
	Go("test-panic-worker", func() {
		defer wg.Done()
		panic("boom")
	})
	wg.Wait()
}

func TestOrderedNotifierPreservesStrictFIFOOrderAndRecoversPanic(t *testing.T) {
	var notifier OrderedNotifier[int]
	const total = 50
	var mu sync.Mutex
	received := make([]int, 0, total)
	done := make(chan struct{})

	cb := func(v int) {
		if v == 10 {
			panic("callback boom")
		}
		mu.Lock()
		received = append(received, v)
		if v == total-1 {
			close(done)
		}
		mu.Unlock()
	}
	for i := 0; i < total; i++ {
		notifier.Enqueue("ordered-test", cb, i)
	}
	<-done

	mu.Lock()
	defer mu.Unlock()
	if len(received) != total-1 {
		t.Fatalf("received %d items, want %d", len(received), total-1)
	}
	prev := -1
	for _, v := range received {
		if v <= prev {
			t.Fatalf("out-of-order notification: got %d after %d", v, prev)
		}
		prev = v
	}
}
