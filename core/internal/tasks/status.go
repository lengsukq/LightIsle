package tasks

// Shared task and maintenance lifecycle status constants used across Core
// packages to avoid drifting magic status strings.
const (
	StatusPending          = "pending"
	StatusRunning          = "running"
	StatusCompleted        = "completed"
	StatusFailed           = "failed"
	StatusCancelled        = "cancelled"
	StatusInterrupted      = "interrupted"
	StatusRecoveryRequired = "recovery_required"
	StatusOK               = "ok"
	StatusOffline          = "offline"
	StatusBusy             = "busy"
)
