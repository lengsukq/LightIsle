package safego

import (
	"log/slog"
	"runtime/debug"
)

// Recover catches panics in background goroutines and logs a structured error
// with stack trace so an unexpected background panic never brings down the
// lightisled daemon process.
func Recover(name string) {
	if r := recover(); r != nil {
		slog.Error("background goroutine panicked",
			"worker", name,
			"panic", r,
			"stack", string(debug.Stack()),
		)
	}
}

// Go starts a background goroutine wrapped with Recover.
func Go(name string, fn func()) {
	go func() {
		defer Recover(name)
		fn()
	}()
}
