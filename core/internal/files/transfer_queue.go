package files

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const (
	maxTransferQueueTasks = 256
	maxTransferTaskBytes  = 16 << 10
	transferRetryFromZero = "restart_from_zero"
)

var (
	ErrTransferQueueFull = errors.New("transfer_queue_full")
	ErrTransferTaskState = errors.New("transfer_task_state_invalid")
	ErrTransferTaskID    = errors.New("transfer_task_not_found")
)

type TransferTask struct {
	ID              string                `json:"id"`
	Source          string                `json:"source"`
	Destination     string                `json:"destination"`
	Mode            string                `json:"mode"`
	State           string                `json:"state"`
	Phase           string                `json:"phase"`
	CompletedBytes  int64                 `json:"completedBytes"`
	TotalBytes      int64                 `json:"totalBytes"`
	Error           string                `json:"error,omitempty"`
	CreatedAt       int64                 `json:"createdAt"`
	UpdatedAt       int64                 `json:"updatedAt"`
	SourceRoot      TransferRootIdentity  `json:"sourceRoot"`
	DestinationRoot TransferRootIdentity  `json:"destinationRoot"`
	SourceSnapshot  string                `json:"sourceSnapshot"`
	RetryBehavior   string                `json:"retryBehavior"`
}

type TransferRootIdentity = storageidentity.Binding
type transferProgressFunc func(phase string, completed, total int64) error

type TransferQueue struct {
	manager *Manager
	dir     string
	mu      sync.Mutex
	tasks   map[string]TransferTask
	cancel  map[string]context.CancelFunc
	active  map[string]context.Context
	ctx     context.Context
	stop    context.CancelFunc
	wake    chan struct{}
	wg      sync.WaitGroup
	closed  bool
	identity storageidentity.Provider
}

func NewTransferQueue(dataDir string, manager *Manager) (*TransferQueue, error) {
	return newTransferQueue(dataDir, manager, storageidentity.SystemProvider{})
}

func newTransferQueue(dataDir string, manager *Manager, identity storageidentity.Provider) (*TransferQueue, error) {
	if manager == nil || !filepath.IsAbs(dataDir) || identity == nil {
		return nil, ErrPath
	}
	dir := filepath.Join(dataDir, "cross-volume-queue")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, ErrType
	}
	ctx, stop := context.WithCancel(context.Background())
	q := &TransferQueue{manager: manager, dir: dir, tasks: make(map[string]TransferTask), cancel: make(map[string]context.CancelFunc), active: make(map[string]context.Context), ctx: ctx, stop: stop, wake: make(chan struct{}, 1), identity: identity}
	if err := q.load(); err != nil {
		stop()
		return nil, err
	}
	q.wg.Add(1)
	go q.worker()
	q.signal()
	return q, nil
}

func validTransferTaskID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil && strings.ToLower(id) == id
}

func newQueueTaskID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func (q *TransferQueue) load() error {
	entries, err := os.ReadDir(q.dir)
	if err != nil {
		return err
	}
	count := 0
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasSuffix(name, ".tmp") {
			info, statErr := os.Lstat(filepath.Join(q.dir, name))
			if statErr == nil && info.Mode().IsRegular() {
				_ = os.Remove(filepath.Join(q.dir, name))
			}
			continue
		}
		if filepath.Ext(name) != ".json" {
			return ErrType
		}
		count++
		if count > maxTransferQueueTasks {
			return ErrTransferQueueFull
		}
		id := strings.TrimSuffix(name, ".json")
		if !validTransferTaskID(id) {
			return ErrType
		}
		info, err := os.Lstat(filepath.Join(q.dir, name))
		if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > maxTransferTaskBytes {
			return ErrType
		}
		data, err := os.ReadFile(filepath.Join(q.dir, name))
		if err != nil {
			return err
		}
		var task TransferTask
		decoder := json.NewDecoder(strings.NewReader(string(data)))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&task); err != nil || task.ID != id || !validTask(task) {
			return ErrType
		}
		if task.State == "running" {
			task.State = "interrupted"
			task.Phase = "interrupted_requires_explicit_retry"
			task.Error = "interrupted_by_restart; retry restarts from zero"
			task.UpdatedAt = time.Now().UnixNano()
			if err := q.persist(task); err != nil {
				return err
			}
		}
		q.tasks[id] = task
	}
	return nil
}

func validTask(task TransferTask) bool {
	if !validTransferTaskID(task.ID) || task.Source == "" || task.Destination == "" ||
		(task.Mode != "copy" && task.Mode != "move") || task.CompletedBytes < 0 || task.TotalBytes < 0 ||
		task.CompletedBytes > task.TotalBytes || task.RetryBehavior != transferRetryFromZero {
		return false
	}
	switch task.State {
	case "queued", "running", "completed", "failed", "cancelled", "interrupted":
		return true
	default:
		return false
	}
}

func (q *TransferQueue) persist(task TransferTask) error {
	if !validTask(task) {
		return ErrType
	}
	data, err := json.Marshal(task)
	if err != nil {
		return err
	}
	if len(data) > maxTransferTaskBytes {
		return ErrSize
	}
	root, err := os.OpenRoot(q.dir)
	if err != nil {
		return err
	}
	defer root.Close()
	tmp, name := task.ID+".tmp", task.ID+".json"
	f, err := root.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := f.Write(data)
	if writeErr == nil {
		writeErr = f.Sync()
	}
	if closeErr := f.Close(); writeErr == nil {
		writeErr = closeErr
	}
	if writeErr != nil {
		return writeErr
	}
	if err := root.Rename(tmp, name); err != nil {
		return err
	}
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	err = dir.Sync()
	if closeErr := dir.Close(); err == nil {
		err = closeErr
	}
	return err
}

func (q *TransferQueue) Enqueue(ctx context.Context, source, destination, mode string) (TransferTask, error) {
	if ctx == nil || source == "" || (mode != "copy" && mode != "move") {
		return TransferTask{}, ErrPath
	}
	dest, err := allowedSelectedFolder(destination)
	if err != nil {
		return TransferTask{}, err
	}
	var root TransferRootIdentity
	var snapshot string
	var total int64
	var normalizedSource string
	err = q.manager.withRead(func(s *Store) error {
		var e error
		root, e = captureStoreRootIdentity(ctx, s.root, q.identity)
		if e != nil {
			return e
		}
		name, e := s.safePath(source, false, false)
		if e != nil {
			return e
		}
		normalizedSource = name
		if mode == "copy" || mode == "move" {
			snapshot, total, e = s.captureTransferSource(name)
			if e != nil {
				return e
			}
		}
		if mode == "move" {
			info, e := s.root.Lstat(name)
			if e != nil {
				return e
			}
			if !info.Mode().IsRegular() {
				return ErrType
			}
		}
		if pathsOverlap(root.Path, dest) {
			return ErrPath
		}
		return nil
	})
	if err != nil {
		return TransferTask{}, err
	}
	destinationRoot, err := q.identity.Capture(ctx, dest)
	if err != nil {
		return TransferTask{}, err
	}
	if err := ctx.Err(); err != nil {
		return TransferTask{}, err
	}
	if root.VolumeUUID == destinationRoot.VolumeUUID {
		return TransferTask{}, ErrPath
	}
	// The root may have changed while the destination volume identity was read.
	err = q.manager.withRead(func(s *Store) error {
		current, e := captureStoreRootIdentity(ctx, s.root, q.identity)
		if e != nil {
			return e
		}
		if current != root {
			return ErrOffline
		}
		return nil
	})
	if err != nil {
		return TransferTask{}, err
	}
	id, err := newQueueTaskID()
	if err != nil {
		return TransferTask{}, err
	}
	now := time.Now().UnixNano()
	task := TransferTask{ID: id, Source: normalizedSource, Destination: dest, Mode: mode, State: "queued", Phase: "queued",
		TotalBytes: total, CreatedAt: now, UpdatedAt: now, SourceRoot: root, DestinationRoot: destinationRoot,
		SourceSnapshot: snapshot, RetryBehavior: transferRetryFromZero}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return TransferTask{}, fs.ErrClosed
	}
	if len(q.tasks) >= maxTransferQueueTasks {
		return TransferTask{}, ErrTransferQueueFull
	}
	if err := q.persist(task); err != nil {
		return TransferTask{}, err
	}
	q.tasks[id] = task
	q.signal()
	return task, nil
}

func (q *TransferQueue) List() ([]TransferTask, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return nil, fs.ErrClosed
	}
	out := make([]TransferTask, 0, len(q.tasks))
	for _, task := range q.tasks {
		out = append(out, task)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt == out[j].CreatedAt {
			return out[i].ID < out[j].ID
		}
		return out[i].CreatedAt < out[j].CreatedAt
	})
	return out, nil
}

func (q *TransferQueue) Forget(id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	task, ok := q.tasks[id]
	if !ok || !validTransferTaskID(id) {
		return ErrTransferTaskID
	}
	if task.State == "queued" || task.State == "running" {
		return ErrTransferTaskState
	}
	if err := os.Remove(filepath.Join(q.dir, id+".json")); err != nil {
		return err
	}
	dir, err := os.Open(q.dir)
	if err != nil {
		return err
	}
	err = dir.Sync()
	if closeErr := dir.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	delete(q.tasks, id)
	return nil
}

func (q *TransferQueue) Cancel(id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	task, ok := q.tasks[id]
	if !ok || !validTransferTaskID(id) {
		return ErrTransferTaskID
	}
	switch task.State {
	case "queued":
		task.State, task.Phase = "cancelled", "cancelled_before_start"
		task.UpdatedAt = time.Now().UnixNano()
		if err := q.persist(task); err != nil {
			return err
		}
		q.tasks[id] = task
		return nil
	case "running":
		task.Phase = "cancelling"
		task.UpdatedAt = time.Now().UnixNano()
		if err := q.persist(task); err != nil {
			return err
		}
		q.tasks[id] = task
		if cancel := q.cancel[id]; cancel != nil {
			cancel()
		}
		return nil
	default:
		return ErrTransferTaskState
	}
}

func (q *TransferQueue) Retry(id string) (TransferTask, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	task, ok := q.tasks[id]
	if !ok || !validTransferTaskID(id) {
		return TransferTask{}, ErrTransferTaskID
	}
	if task.State != "failed" && task.State != "cancelled" && task.State != "interrupted" {
		return TransferTask{}, ErrTransferTaskState
	}
	task.State, task.Phase, task.Error = "queued", transferRetryFromZero, ""
	task.CompletedBytes = 0
	task.UpdatedAt = time.Now().UnixNano()
	if err := q.persist(task); err != nil {
		return TransferTask{}, err
	}
	q.tasks[id] = task
	q.signal()
	return task, nil
}

func (q *TransferQueue) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

func (q *TransferQueue) worker() {
	defer q.wg.Done()
	for {
		select {
		case <-q.ctx.Done():
			return
		case <-q.wake:
		}
		for {
			task, ok := q.startNext()
			if !ok {
				break
			}
			q.run(task)
		}
	}
}

func (q *TransferQueue) startNext() (TransferTask, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed || q.ctx.Err() != nil {
		return TransferTask{}, false
	}
	var selected *TransferTask
	for _, candidate := range q.tasks {
		if candidate.State != "queued" {
			continue
		}
		copy := candidate
		if selected == nil || copy.CreatedAt < selected.CreatedAt || copy.CreatedAt == selected.CreatedAt && copy.ID < selected.ID {
			selected = &copy
		}
	}
	if selected == nil {
		return TransferTask{}, false
	}
	task := *selected
	task.State, task.Phase = "running", "checking_source_and_destination"
	task.UpdatedAt = time.Now().UnixNano()
	if err := q.persist(task); err != nil {
		slog.Error("persist transfer start failed; task was not run", "task_id", task.ID, "error", err)
		return TransferTask{}, false
	}
	q.tasks[task.ID] = task
	ctx, cancel := context.WithCancel(q.ctx)
	q.active[task.ID], q.cancel[task.ID] = ctx, cancel
	return task, true
}

func (q *TransferQueue) run(task TransferTask) {
	q.mu.Lock()
	ctx, cancel := q.active[task.ID], q.cancel[task.ID]
	q.mu.Unlock()
	if ctx == nil || cancel == nil {
		return
	}
	defer func() {
		cancel()
		q.mu.Lock()
		delete(q.cancel, task.ID)
		delete(q.active, task.ID)
		q.mu.Unlock()
	}()
	var lastPersist time.Time
	lastBytes := int64(-1)
	progress := func(phase string, completed, total int64) error {
		q.mu.Lock()
		defer q.mu.Unlock()
		current, ok := q.tasks[task.ID]
		if !ok || current.State != "running" {
			return ErrTransferTaskState
		}
		if completed < 0 || completed > current.TotalBytes || total != current.TotalBytes {
			return ErrSize
		}
		if completed-lastBytes < 1<<20 && time.Since(lastPersist) < 750*time.Millisecond && phase == current.Phase {
			return nil
		}
		current.Phase, current.CompletedBytes, current.UpdatedAt = phase, completed, time.Now().UnixNano()
		if err := q.persist(current); err != nil {
			return err
		}
		q.tasks[task.ID] = current
		lastPersist, lastBytes = time.Now(), completed
		return nil
	}
	var err error
	q.manager.opMu.Lock()
	err = q.manager.withRead(func(s *Store) error {
		if task.Mode == "copy" {
			_, err = s.copyOutWithTask(ctx, task.Source, task.Destination, &task, q.identity, progress)
			return err
		}
		_, err = s.moveOutWithTask(ctx, task, q.manager.configFile, q.identity, progress)
		return err
	})
	q.manager.opMu.Unlock()
	q.mu.Lock()
	defer q.mu.Unlock()
	current, ok := q.tasks[task.ID]
	if !ok {
		return
	}
	current.UpdatedAt = time.Now().UnixNano()
	switch {
	case err == nil:
		current.State, current.Phase, current.Error, current.CompletedBytes = "completed", "completed", "", current.TotalBytes
	case errors.Is(err, context.Canceled) && q.ctx.Err() != nil:
		current.State, current.Phase, current.Error = "interrupted", "interrupted_requires_explicit_retry", "interrupted_by_shutdown; retry restarts from zero"
	case errors.Is(err, context.Canceled):
		current.State, current.Phase, current.Error = "cancelled", "cancelled", err.Error()
	default:
		current.State, current.Phase, current.Error = "failed", "failed", err.Error()
	}
	if persistErr := q.persist(current); persistErr != nil {
		current.State, current.Phase, current.Error = "interrupted", "completion_persist_failed", fmt.Sprintf("%v; state persistence failed: %v", err, persistErr)
		slog.Error("persist transfer completion failed", "task_id", task.ID, "error", persistErr)
	}
	q.tasks[task.ID] = current
}

func (q *TransferQueue) Close() error {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return nil
	}
	q.closed = true
	q.stop()
	for _, cancel := range q.cancel {
		cancel()
	}
	q.mu.Unlock()
	q.wg.Wait()
	return nil
}
