package files

import (
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// TransferTask is the in-memory descriptor the live cross-volume copy and
// logged single-file move code threads through their progress receipts. The
// persistent queue that used to own it was removed (product boundary P0-01);
// these fields remain the receipt contract the Mac app renders.
type TransferTask struct {
	ID              string               `json:"id"`
	Source          string               `json:"source"`
	Destination     string               `json:"destination"`
	Mode            string               `json:"mode"`
	State           string               `json:"state"`
	Phase           string               `json:"phase"`
	CompletedBytes  int64                `json:"completedBytes"`
	TotalBytes      int64                `json:"totalBytes"`
	Error           string               `json:"error,omitempty"`
	CreatedAt       int64                `json:"createdAt"`
	UpdatedAt       int64                `json:"updatedAt"`
	SourceRoot      TransferRootIdentity `json:"sourceRoot"`
	DestinationRoot TransferRootIdentity `json:"destinationRoot"`
	SourceSnapshot  string               `json:"sourceSnapshot"`
	RetryBehavior   string               `json:"retryBehavior"`
}

type TransferRootIdentity = storageidentity.Binding

type transferProgressFunc func(phase string, completed, total int64) error
