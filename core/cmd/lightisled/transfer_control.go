//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// These commands belong to the native owner's private pipe, never HTTP.
type transferControl struct {
	ctx       context.Context
	queue     *files.TransferQueue
	admission chan struct{}
}

func newTransferControl(ctx context.Context, queue *files.TransferQueue) *transferControl {
	return &transferControl{ctx: ctx, queue: queue, admission: make(chan struct{}, 1)}
}

func transferReply(prefix string, value any) {
	data, err := json.Marshal(value)
	if err != nil || len(data) > 256<<10 {
		transferFailure("response", errors.New("transfer_response_too_large"))
		return
	}
	fmt.Fprintln(os.Stdout, prefix+" "+base64.RawURLEncoding.EncodeToString(data))
}

func transferFailure(operation string, err error) {
	message := err.Error()
	if len(message) > 4096 {
		message = message[:4096]
	}
	transferReply("LIGHTISLE_TRANSFER_ERROR", map[string]any{"schemaVersion": 1, "operation": operation, "error": message})
}

func validTransferID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func (c *transferControl) handle(command string) bool {
	if !strings.HasPrefix(command, "transfer ") {
		return false
	}
	if c.queue == nil {
		transferFailure("unavailable", errors.New("transfer_queue_unavailable"))
		return true
	}
	words := strings.Fields(command)
	if len(words) < 2 {
		transferFailure("request", errors.New("invalid_transfer_request"))
		return true
	}
	switch words[1] {
	case "list":
		if len(words) > 3 {
			transferFailure("list", errors.New("invalid_transfer_request"))
			break
		}
		cursor := ""
		if len(words) == 3 {
			cursor = words[2]
		}
		if cursor != "" && !validTransferID(cursor) {
			transferFailure("list", errors.New("invalid_transfer_cursor"))
			break
		}
		tasks, err := c.queue.List()
		if err != nil {
			transferFailure("list", err)
			break
		}
		sort.Slice(tasks, func(i, j int) bool {
			if tasks[i].CreatedAt == tasks[j].CreatedAt {
				return tasks[i].ID > tasks[j].ID
			}
			return tasks[i].CreatedAt > tasks[j].CreatedAt
		})
		activeCount := 0
		var runningTask *files.TransferTask
		for _, task := range tasks {
			if task.State == "queued" || task.State == "running" {
				activeCount++
			}
			if task.State == "running" { item:=task; runningTask=&item }
		}
		start := 0
		if cursor != "" {
			found := false
			for i, task := range tasks {
				if task.ID == cursor {
					start = i + 1
					found = true
					break
				}
			}
			if !found {
				transferFailure("list", errors.New("transfer_cursor_expired"))
				break
			}
		}
		end := min(start+20, len(tasks))
		next := ""
		if end < len(tasks) && end > start {
			next = tasks[end-1].ID
		}
		transferReply("LIGHTISLE_TRANSFERS", map[string]any{"schemaVersion": 1, "tasks": tasks[start:end], "nextCursor": next, "activeCount": activeCount, "totalCount": len(tasks), "requestedCursor": cursor,"runningTask":runningTask})
	case "enqueue":
		if len(words) != 3 {
			transferFailure("enqueue", errors.New("invalid_transfer_request"))
			break
		}
		data, err := base64.RawURLEncoding.DecodeString(words[2])
		var request struct {
			Source      string `json:"source"`
			Destination string `json:"destination"`
			Mode        string `json:"mode"`
		}
		if err == nil && len(data) <= 6000 {
			decoder := json.NewDecoder(strings.NewReader(string(data)))
			decoder.DisallowUnknownFields()
			err = decoder.Decode(&request)
			if err == nil && !errors.Is(decoder.Decode(new(any)), io.EOF) {
				err = errors.New("trailing_transfer_request")
			}
		} else {
			err = errors.New("invalid_transfer_request")
		}
		if err != nil {
			transferFailure("enqueue", err)
			break
		}
		select {
		case c.admission <- struct{}{}:
			go func() {
				defer func() { <-c.admission }()
				task, err := c.queue.Enqueue(c.ctx, request.Source, request.Destination, request.Mode)
				if err != nil {
					transferFailure("enqueue", err)
					return
				}
				transferReply("LIGHTISLE_TRANSFER_ENQUEUED", task)
			}()
		default:
			transferFailure("enqueue", errors.New("transfer_enqueue_busy"))
		}
	case "cancel", "retry", "forget":
		if len(words) != 3 || !validTransferID(words[2]) {
			transferFailure(words[1], errors.New("invalid_transfer_id"))
			break
		}
		var err error
		switch words[1] {
		case "cancel":
			err = c.queue.Cancel(words[2])
		case "retry":
			_, err = c.queue.Retry(words[2])
		case "forget":
			err = c.queue.Forget(words[2])
		}
		if err != nil {
			transferFailure(words[1], err)
			break
		}
		transferReply("LIGHTISLE_TRANSFER_CHANGED", map[string]string{"operation": words[1], "id": words[2]})
	default:
		transferFailure("request", errors.New("invalid_transfer_request"))
	}
	return true
}
