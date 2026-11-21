package safego

import "sync"

type queuedNotification[T any] struct {
	fn    func(T)
	value T
}

// OrderedNotifier delivers asynchronous callbacks in strict FIFO order using at
// most one active worker goroutine, avoiding out-of-order state delivery under
// bursty updates while never running callbacks under the caller's lock.
type OrderedNotifier[T any] struct {
	mu      sync.Mutex
	name    string
	pending []queuedNotification[T]
	running bool
}

// Enqueue appends one notification to the FIFO queue and ensures a single
// background drainer is running.
func (n *OrderedNotifier[T]) Enqueue(workerName string, fn func(T), value T) {
	if fn == nil {
		return
	}
	n.mu.Lock()
	if n.name == "" {
		n.name = workerName
	}
	n.pending = append(n.pending, queuedNotification[T]{fn: fn, value: value})
	if !n.running {
		n.running = true
		name := n.name
		Go(name, n.drain)
	}
	n.mu.Unlock()
}

func (n *OrderedNotifier[T]) drain() {
	for {
		n.mu.Lock()
		if len(n.pending) == 0 {
			n.running = false
			n.mu.Unlock()
			return
		}
		item := n.pending[0]
		n.pending = n.pending[1:]
		name := n.name
		n.mu.Unlock()

		func() {
			defer Recover(name)
			item.fn(item.value)
		}()
	}
}
