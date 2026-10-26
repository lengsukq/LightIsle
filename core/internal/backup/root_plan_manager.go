package backup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

const (
	rootPlanDirectoryName = "root-backup-plans"
	rootPlanArchiveName   = "archive"
	rootPlanArchiveLimit  = 32
	rootPlanRefreshPeriod = time.Minute
)

// RootPlanManager owns one independent scheduler for each ready, non-legacy
// root generation. Each generation has a different file, so a rebind can
// never inherit an old destination, PlanID, or retention choice.
type RootPlanManager struct {
	registry       *roots.Registry
	provider       RootBackupProvider
	ctx            context.Context
	cancel         context.CancelFunc
	dir            string
	archive        string
	readVolumeInfo func(string) (diskutilVolumeInfo, error)

	opMu      sync.RWMutex
	mu        sync.RWMutex
	plans     map[string]*Scheduler
	failures  map[string]rootPlanFailure
	closed    bool
	loopWG    sync.WaitGroup
	closeOnce sync.Once
	closeErr  error
}

type rootPlanFailure struct {
	schedule      Schedule
	safeToArchive bool
	cause         error
}

// NewRootPlanManager loads plans for currently registered, bound roots without
// requiring those volumes to be mounted. Provider calls happen only when an
// owner configures a plan or a scheduled backup becomes due.
func NewRootPlanManager(dataDir string, registry *roots.Registry, provider RootBackupProvider) (*RootPlanManager, error) {
	if dataDir == "" || registry == nil || provider == nil {
		return nil, ErrInvalid
	}
	resolved, err := filepath.EvalSymlinks(dataDir)
	if err != nil || resolved != filepath.Clean(dataDir) {
		return nil, ErrInvalid
	}
	planDir := filepath.Join(resolved, rootPlanDirectoryName)
	if err := ensurePrivateDirectory(planDir); err != nil {
		return nil, err
	}
	archiveDir := filepath.Join(planDir, rootPlanArchiveName)
	ctx, cancel := context.WithCancel(context.Background())
	manager := &RootPlanManager{
		registry: registry, provider: provider, ctx: ctx, cancel: cancel,
		dir: planDir, archive: archiveDir, plans: make(map[string]*Scheduler), failures: make(map[string]rootPlanFailure),
	}
	if err := manager.reconcile(); err != nil {
		cancel()
		_ = manager.closeSchedulers()
		return nil, err
	}
	manager.loopWG.Add(1)
	go manager.loop()
	return manager, nil
}

func ensurePrivateDirectory(name string) error {
	info, err := os.Lstat(name)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(name, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		info, err = os.Lstat(name)
	}
	if err != nil {
		return err
	}
	uid, owned := currentUID(info)
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || !owned || uid != uint32(os.Geteuid()) {
		return ErrInvalid
	}
	return nil
}

func planFileName(rootID string, generation uint64) string {
	return rootID + "-" + strconv.FormatUint(generation, 10) + ".json"
}

func eligibleBackupRoot(root roots.Root) bool {
	return root.ID != "" && root.Generation != 0 && !root.Pending && !root.Compatibility &&
		root.Path == root.Binding.Path && root.Binding.Validate() == nil
}

func (m *RootPlanManager) loop() {
	defer m.loopWG.Done()
	ticker := time.NewTicker(rootPlanRefreshPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-ticker.C:
			if err := m.reconcile(); err != nil && !errors.Is(err, context.Canceled) {
				slog.Error("reconcile root backup plans", "error", err)
			}
		}
	}
}

// reconcile archives every plan whose logical or physical root generation is
// no longer current, then loads fresh schedules for newly eligible roots.
func (m *RootPlanManager) reconcile() error {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	if m.ctx.Err() != nil {
		return context.Canceled
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return context.Canceled
	}
	registered := make(map[string]roots.Root)
	for _, root := range m.registry.List() {
		if eligibleBackupRoot(root) {
			registered[root.ID] = root
		}
	}
	for id, failure := range m.failures {
		root, exists := registered[id]
		if !exists || failure.schedule.RootGeneration != root.Generation {
			delete(m.failures, id)
		}
	}

	var stale []*Scheduler
	for id, scheduler := range m.plans {
		current, exists := registered[id]
		if exists && sameRootRecord(current, scheduler.rootRecord) {
			continue
		}
		delete(m.plans, id)
		delete(m.failures, id)
		stale = append(stale, scheduler)
	}
	m.mu.Unlock()

	pendingIssues := make(map[string]error)
	for _, scheduler := range stale {
		if err := m.retireScheduler(scheduler); err != nil {
			pendingIssues[scheduler.rootRecord.ID] = errors.Join(pendingIssues[scheduler.rootRecord.ID], err)
			slog.Error("archive stale root backup plan", "rootID", scheduler.rootRecord.ID, "error", err)
		}
	}

	activeFiles := make(map[string]bool, len(registered))
	for _, root := range registered {
		activeFiles[planFileName(root.ID, root.Generation)] = true
	}
	orphanIssues, err := m.archiveOrphanPlans(activeFiles)
	if err != nil {
		return err
	}
	for id, issue := range orphanIssues {
		pendingIssues[id] = errors.Join(pendingIssues[id], issue)
	}
	if issue := orphanIssues[""]; issue != nil {
		for id := range registered {
			pendingIssues[id] = errors.Join(pendingIssues[id], issue)
		}
	}

	m.mu.Lock()
	for id, root := range registered {
		if _, exists := m.plans[id]; exists {
			continue
		}
		previousFailure, hadPreviousFailure := m.failures[id]
		scheduler, failure, err := m.openPlan(root)
		if err != nil {
			m.mu.Unlock()
			return err
		}
		if failure != nil {
			if hadPreviousFailure && previousFailure.schedule.RootGeneration == root.Generation &&
				previousFailure.schedule.LastError == ErrRootPlanArchiveFailed.Error() {
				previousFailure.cause = errors.Join(previousFailure.cause, failure.cause)
				m.failures[id] = previousFailure
			} else {
				m.failures[id] = *failure
			}
			continue
		}
		if hadPreviousFailure && previousFailure.schedule.RootGeneration == root.Generation &&
			previousFailure.schedule.LastError == ErrRootPlanArchiveFailed.Error() && !scheduler.persisted {
			_ = scheduler.Close()
			m.failures[id] = previousFailure
			continue
		}
		delete(m.failures, id)
		m.plans[id] = scheduler
	}
	for id, issue := range pendingIssues {
		root, exists := registered[id]
		if !exists {
			continue
		}
		if scheduler := m.plans[id]; scheduler != nil {
			scheduler.mu.Lock()
			scheduler.config.LastError = ErrRootPlanArchiveFailed.Error()
			scheduler.config.LastErrorDetail = "有一份旧代计划未能归档。当前代计划仍独立保存；请检查本机私有计划目录的权限。"
			if _, saveErr := scheduler.writeLocked(); saveErr != nil {
				slog.Error("persist root backup plan archive issue", "rootID", id, "error", saveErr)
			}
			scheduler.mu.Unlock()
			continue
		}
		failure := m.failures[id]
		failure.schedule = Schedule{RootID: root.ID, RootGeneration: root.Generation, Enabled: false,
			LastError:       ErrRootPlanArchiveFailed.Error(),
			LastErrorDetail: "有一份旧代计划未能归档，当前根计划已停用。请检查本机私有计划目录权限后重新保存。"}
		failure.cause = errors.Join(failure.cause, issue)
		m.failures[id] = failure
	}
	m.mu.Unlock()
	return nil
}

func (m *RootPlanManager) newPlanScheduler(root roots.Root) *Scheduler {
	path := filepath.Join(m.dir, planFileName(root.ID, root.Generation))
	ctx, cancel := context.WithCancel(m.ctx)
	return &Scheduler{
		rootPlan: true, rootRecord: root, rootRegistry: m.registry, rootProvider: m.provider,
		ctx: ctx, cancel: cancel, path: path,
		readVolumeInfo: m.readVolumeInfo,
		config:         Schedule{RootID: root.ID, RootGeneration: root.Generation},
	}
}

func (m *RootPlanManager) startPlanScheduler(scheduler *Scheduler) {
	scheduler.wg.Add(1)
	go scheduler.loop()
}

func rootPlanConfigFailure(root roots.Root, cause error, safeToArchive bool) *rootPlanFailure {
	code := ErrRootPlanConfigInvalid
	detail := "已保存的计划无效或权限不正确，当前不会运行。重新选择目的地并保存时，会先把旧配置保存在本机私有归档中。"
	if !safeToArchive {
		code = ErrRootPlanConfigUnsafe
		detail = "计划文件是符号链接、非普通文件或不属于当前用户，因此不会读取或覆盖。请在本机修复该文件后重新配置。"
	}
	return &rootPlanFailure{
		schedule: Schedule{RootID: root.ID, RootGeneration: root.Generation, Enabled: false,
			LastError: code.Error(), LastErrorDetail: detail},
		safeToArchive: safeToArchive, cause: cause,
	}
}

func (m *RootPlanManager) openPlan(root roots.Root) (*Scheduler, *rootPlanFailure, error) {
	scheduler := m.newPlanScheduler(root)
	info, err := os.Lstat(scheduler.path)
	if errors.Is(err, os.ErrNotExist) {
		m.startPlanScheduler(scheduler)
		return scheduler, nil, nil
	}
	if err != nil {
		scheduler.cancel()
		return nil, rootPlanConfigFailure(root, err, false), nil
	}
	uid, owned := currentUID(info)
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !owned || uid != uint32(os.Geteuid()) {
		scheduler.cancel()
		return nil, rootPlanConfigFailure(root, ErrRootPlanConfigUnsafe, false), nil
	}
	if info.Mode().Perm()&0077 != 0 || info.Size() > 16<<10 {
		scheduler.cancel()
		return nil, rootPlanConfigFailure(root, ErrInvalid, true), nil
	}
	raw, err := readRootPlanFile(scheduler.path, info)
	if err != nil {
		scheduler.cancel()
		return nil, rootPlanConfigFailure(root, err, true), nil
	}
	if err := validateRootPlanConfig(raw, root, &scheduler.config); err != nil {
		scheduler.cancel()
		return nil, rootPlanConfigFailure(root, err, true), nil
	}
	scheduler.persisted = true
	if scheduler.config.Enabled && !scheduleHasDestinationIdentity(scheduler.config) {
		scheduler.config.DestinationIdentityStatus = destinationIdentityConfirmationRequired
		scheduler.config.LastError = ErrDestinationConfirmationRequired.Error()
		scheduler.config.NextRun = 0
		if _, err := scheduler.writeLocked(); err != nil {
			slog.Error("persist root backup destination confirmation requirement", "error", err)
		}
	}
	m.startPlanScheduler(scheduler)
	return scheduler, nil, nil
}

func readRootPlanFile(path string, expected os.FileInfo) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(expected, opened) {
		return nil, ErrRootPlanConfigUnsafe
	}
	if opened.Size() < 0 || opened.Size() > 16<<10 {
		return nil, ErrInvalid
	}
	return io.ReadAll(io.LimitReader(f, (16<<10)+1))
}

func validateRootPlanConfig(raw []byte, root roots.Root, schedule *Schedule) error {
	if len(raw) == 0 || len(raw) > 16<<10 || json.Unmarshal(raw, schedule) != nil {
		return ErrInvalid
	}
	if schedule.RootID != root.ID || schedule.RootGeneration != root.Generation ||
		(schedule.Enabled && schedule.EveryHours != 24 && schedule.EveryHours != 168) ||
		schedule.RetentionCount < 0 || schedule.RetentionCount > maximumScheduledRetention ||
		(schedule.PlanID != "" && !validPlanID(schedule.PlanID)) ||
		(schedule.Destination != "" && (!filepath.IsAbs(schedule.Destination) || filepath.Clean(schedule.Destination) != schedule.Destination)) {
		return ErrInvalid
	}
	return nil
}

func (m *RootPlanManager) archiveOrphanPlans(activeFiles map[string]bool) (map[string]error, error) {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		return nil, err
	}
	issues := make(map[string]error)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") || activeFiles[entry.Name()] {
			continue
		}
		path := filepath.Join(m.dir, entry.Name())
		if err := deactivateAndArchivePlanFile(path, m.archive); err != nil {
			rootID := planRootID(entry.Name())
			if rootID != "" {
				issues[rootID] = errors.Join(issues[rootID], err)
			}
			slog.Error("archive orphan root backup plan", "path", path, "rootID", rootID, "error", err)
		}
	}
	if err := trimRootPlanArchive(m.archive); err != nil {
		slog.Error("trim root backup plan archive", "error", err)
		issues[""] = err
	}
	return issues, nil
}

func planRootID(name string) string {
	if len(name) < 34 || name[32] != '-' || !strings.HasSuffix(name, ".json") {
		return ""
	}
	rootID := name[:32]
	if !validMetadataRootID(rootID) {
		return ""
	}
	if _, err := strconv.ParseUint(strings.TrimSuffix(name[33:], ".json"), 10, 64); err != nil {
		return ""
	}
	return rootID
}

func deactivateAndArchivePlanFile(path, archiveDir string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	uid, owned := currentUID(info)
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || !owned || uid != uint32(os.Geteuid()) {
		return ErrInvalid
	}
	if info.Size() <= 16<<10 {
		raw, readErr := readRootPlanFile(path, info)
		var schedule Schedule
		if readErr == nil && json.Unmarshal(raw, &schedule) == nil && schedule.RootID != "" && schedule.RootGeneration != 0 {
			schedule.Enabled = false
			schedule.NextRun = 0
			schedule.LastError = ErrRootChanged.Error()
			schedule.LastErrorDetail = "此计划属于已失效的根代际，已停用并归档。"
			writer := &Scheduler{path: path, config: schedule, persisted: true}
			if _, err := writer.writeLocked(); err != nil {
				return err
			}
		}
	}
	return archivePlanFile(path, archiveDir)
}

func (m *RootPlanManager) retireScheduler(scheduler *Scheduler) error {
	scheduler.mu.Lock()
	if scheduler.config.Enabled {
		scheduler.config.Enabled = false
		scheduler.config.NextRun = 0
		scheduler.config.LastError = ErrRootChanged.Error()
		if _, err := scheduler.writeLocked(); err != nil {
			scheduler.mu.Unlock()
			scheduler.Close()
			return err
		}
	}
	persisted := scheduler.persisted
	path := scheduler.path
	scheduler.mu.Unlock()
	closeErr := scheduler.Close()
	if !persisted {
		return closeErr
	}
	archiveErr := archivePlanFile(path, m.archive)
	trimErr := trimRootPlanArchive(m.archive)
	return errors.Join(closeErr, archiveErr, trimErr)
}

func archivePlanFile(path, archiveDir string) error {
	if err := ensurePrivateDirectory(archiveDir); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	uid, owned := currentUID(info)
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !owned || uid != uint32(os.Geteuid()) {
		return ErrInvalid
	}
	base := strings.TrimSuffix(filepath.Base(path), ".json")
	archiveName := fmt.Sprintf("%s-%020d.json", base, time.Now().UnixNano())
	destination := filepath.Join(archiveDir, archiveName)
	if err := os.Rename(path, destination); err != nil {
		return err
	}
	if err := os.Chmod(destination, 0600); err != nil {
		return err
	}
	archived, err := os.Open(destination)
	if err != nil {
		return err
	}
	syncErr := archived.Sync()
	closeErr := archived.Close()
	if syncErr != nil || closeErr != nil {
		return errors.Join(syncErr, closeErr)
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		return err
	}
	return syncDirectory(archiveDir)
}

func trimRootPlanArchive(directory string) error {
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	type archivedFile struct {
		name    string
		modTime time.Time
	}
	files := make([]archivedFile, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		info, err := os.Lstat(filepath.Join(directory, entry.Name()))
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return ErrInvalid
		}
		files = append(files, archivedFile{name: entry.Name(), modTime: info.ModTime()})
	}
	if len(files) <= rootPlanArchiveLimit {
		return nil
	}
	sort.Slice(files, func(i, j int) bool {
		if files[i].modTime.Equal(files[j].modTime) {
			return files[i].name < files[j].name
		}
		return files[i].modTime.Before(files[j].modTime)
	})
	var result error
	for _, file := range files[:len(files)-rootPlanArchiveLimit] {
		if err := os.Remove(filepath.Join(directory, file.name)); err != nil {
			result = errors.Join(result, err)
		}
	}
	if result != nil {
		return result
	}
	return syncDirectory(directory)
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func (m *RootPlanManager) schedulerFor(id string, generation uint64) (*Scheduler, error) {
	if id == "" || generation == 0 {
		return nil, ErrRootPlanUnavailable
	}
	current := m.registry.List()
	var root *roots.Root
	for index := range current {
		if current[index].ID == id {
			root = &current[index]
			break
		}
	}
	if root == nil {
		return nil, roots.ErrMissing
	}
	if !eligibleBackupRoot(*root) || root.Generation != generation {
		return nil, ErrRootChanged
	}
	m.mu.RLock()
	scheduler := m.plans[id]
	m.mu.RUnlock()
	if scheduler == nil || scheduler.rootRecord.Generation != generation || !sameRootRecord(scheduler.rootRecord, *root) {
		return nil, ErrRootPlanUnavailable
	}
	return scheduler, nil
}

func (m *RootPlanManager) currentRoot(id string, generation uint64) (roots.Root, error) {
	if id == "" || generation == 0 {
		return roots.Root{}, ErrRootPlanUnavailable
	}
	for _, root := range m.registry.List() {
		if root.ID != id {
			continue
		}
		if !eligibleBackupRoot(root) || root.Generation != generation {
			return roots.Root{}, ErrRootChanged
		}
		return root, nil
	}
	return roots.Root{}, roots.ErrMissing
}

// Status returns the persistent state for the requested current root
// generation. An eligible root with no saved plan gets a bound, disabled
// schedule so clients can show that it has never been configured.
func (m *RootPlanManager) Status(id string, generation uint64) (Schedule, error) {
	if err := m.reconcile(); err != nil && !errors.Is(err, context.Canceled) {
		return Schedule{}, err
	}
	m.opMu.RLock()
	defer m.opMu.RUnlock()
	if m.ctx.Err() != nil {
		return Schedule{}, context.Canceled
	}
	_, err := m.currentRoot(id, generation)
	if err != nil {
		return Schedule{}, err
	}
	m.mu.RLock()
	if failure, exists := m.failures[id]; exists && failure.schedule.RootGeneration == generation {
		status := failure.schedule
		m.mu.RUnlock()
		return status, nil
	}
	m.mu.RUnlock()
	scheduler, err := m.schedulerFor(id, generation)
	if err != nil {
		return Schedule{}, err
	}
	return scheduler.Status(), nil
}

// Configure explicitly binds a plan to the chosen destination's volume UUID,
// directory inode/birth/generation, and the selected root generation.
func (m *RootPlanManager) Configure(ctx context.Context, id string, generation uint64, destination string, hours, retention int) error {
	if ctx == nil {
		return ErrInvalid
	}
	if err := m.reconcile(); err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	m.opMu.RLock()
	defer m.opMu.RUnlock()
	if m.ctx.Err() != nil {
		return context.Canceled
	}
	root, err := m.currentRoot(id, generation)
	if err != nil {
		return err
	}
	configuredCtx, cancel := context.WithCancel(ctx)
	stopCancel := context.AfterFunc(m.ctx, cancel)
	defer func() {
		stopCancel()
		cancel()
	}()
	m.mu.RLock()
	scheduler := m.plans[id]
	failure, hasFailure := m.failures[id]
	m.mu.RUnlock()
	if scheduler != nil && scheduler.rootRecord.Generation == generation && sameRootRecord(scheduler.rootRecord, root) {
		configureErr := scheduler.configureWithContext(configuredCtx, destination, hours, &retention)
		scheduler.mu.Lock()
		persisted := scheduler.persisted
		scheduler.mu.Unlock()
		if persisted {
			m.mu.Lock()
			delete(m.failures, id)
			m.mu.Unlock()
		}
		return configureErr
	}
	if !hasFailure || failure.schedule.RootGeneration != generation {
		return ErrRootPlanUnavailable
	}
	if !failure.safeToArchive {
		return ErrRootPlanConfigUnsafe
	}
	configPath := filepath.Join(m.dir, planFileName(root.ID, root.Generation))
	if err := archivePlanFile(configPath, m.archive); err != nil {
		m.setArchiveFailure(id, root, err)
		return errors.Join(ErrRootPlanArchiveFailed, err)
	}
	trimErr := trimRootPlanArchive(m.archive)
	replacement := m.newPlanScheduler(root)
	configureErr := replacement.configureWithContext(configuredCtx, destination, hours, &retention)
	if !replacement.persisted {
		_ = replacement.Close()
		return configureErr
	}
	m.mu.Lock()
	if m.ctx.Err() != nil {
		m.mu.Unlock()
		_ = replacement.Close()
		return context.Canceled
	}
	m.plans[id] = replacement
	delete(m.failures, id)
	m.mu.Unlock()
	if trimErr != nil {
		replacement.mu.Lock()
		replacement.config.LastError = ErrRootPlanArchiveFailed.Error()
		replacement.config.LastErrorDetail = "旧配置已保存在本机私有归档中，但归档整理未完成。当前计划仍可运行；请检查归档目录权限。"
		if _, saveErr := replacement.writeLocked(); saveErr != nil {
			replacement.closeErr = errors.Join(replacement.closeErr, saveErr)
		}
		replacement.mu.Unlock()
	}
	if configureErr != nil {
		replacement.recordRootPlanError(configureErr)
	}
	m.startPlanScheduler(replacement)
	return configureErr
}

// Disable persists an offline-capable pause for the requested generation.
func (m *RootPlanManager) Disable(id string, generation uint64) error {
	if err := m.reconcile(); err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	m.opMu.RLock()
	defer m.opMu.RUnlock()
	if m.ctx.Err() != nil {
		return context.Canceled
	}
	if _, err := m.currentRoot(id, generation); err != nil {
		return err
	}
	scheduler, err := m.schedulerFor(id, generation)
	if err != nil {
		m.mu.Lock()
		failure, exists := m.failures[id]
		if exists && failure.schedule.RootGeneration == generation {
			failure.schedule.Enabled = false
			failure.schedule.NextRun = 0
			m.failures[id] = failure
			m.mu.Unlock()
			return nil
		}
		m.mu.Unlock()
		return err
	}
	return scheduler.Disable()
}

func (m *RootPlanManager) setArchiveFailure(id string, root roots.Root, cause error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	failure := m.failures[id]
	failure.schedule = Schedule{RootID: root.ID, RootGeneration: root.Generation, Enabled: false,
		LastError:       ErrRootPlanArchiveFailed.Error(),
		LastErrorDetail: "旧配置未能安全归档，因此尚未启用新计划。请检查本机私有计划目录权限后重试。"}
	failure.safeToArchive = true
	failure.cause = cause
	m.failures[id] = failure
}

// Schedules exposes internal guard information for the trusted macOS runtime.
// It intentionally returns no HTTP capability and includes disabled plans so
// their currently selected backup volumes remain protected.
func (m *RootPlanManager) Schedules() []Schedule {
	if err := m.reconcile(); err != nil && !errors.Is(err, context.Canceled) {
		slog.Error("reconcile plans before schedule snapshot", "error", err)
	}
	m.opMu.RLock()
	defer m.opMu.RUnlock()
	m.mu.RLock()
	plans := make([]*Scheduler, 0, len(m.plans))
	seen := make(map[string]bool, len(m.plans)+len(m.failures))
	for _, scheduler := range m.plans {
		plans = append(plans, scheduler)
		seen[scheduler.rootRecord.ID] = true
	}
	failures := make([]Schedule, 0, len(m.failures))
	for id, failure := range m.failures {
		if !seen[id] {
			failures = append(failures, failure.schedule)
		}
	}
	m.mu.RUnlock()
	schedules := make([]Schedule, 0, len(plans)+len(failures))
	for _, scheduler := range plans {
		schedules = append(schedules, scheduler.Status())
	}
	schedules = append(schedules, failures...)
	sort.Slice(schedules, func(i, j int) bool {
		if schedules[i].RootID != schedules[j].RootID {
			return schedules[i].RootID < schedules[j].RootID
		}
		return schedules[i].RootGeneration < schedules[j].RootGeneration
	})
	return schedules
}

// Destinations lists configured backup destinations, including paused plans.
func (m *RootPlanManager) Destinations() []string {
	seen := make(map[string]bool)
	var destinations []string
	for _, schedule := range m.Schedules() {
		if schedule.Destination != "" && !seen[schedule.Destination] {
			seen[schedule.Destination] = true
			destinations = append(destinations, schedule.Destination)
		}
	}
	sort.Strings(destinations)
	return destinations
}

func (m *RootPlanManager) closeSchedulers() error {
	m.mu.Lock()
	plans := make([]*Scheduler, 0, len(m.plans))
	for _, scheduler := range m.plans {
		plans = append(plans, scheduler)
	}
	m.plans = make(map[string]*Scheduler)
	m.mu.Unlock()
	var result error
	for _, scheduler := range plans {
		result = errors.Join(result, scheduler.Close())
	}
	return result
}

// Close stops reconciliation, cancels active jobs, waits for each job to
// finish, and only then releases its RootBackupLease.
func (m *RootPlanManager) Close() error {
	if m == nil {
		return nil
	}
	m.closeOnce.Do(func() {
		m.cancel()
		m.loopWG.Wait()
		m.opMu.Lock()
		defer m.opMu.Unlock()
		m.mu.Lock()
		m.closed = true
		m.mu.Unlock()
		m.closeErr = m.closeSchedulers()
	})
	return m.closeErr
}
