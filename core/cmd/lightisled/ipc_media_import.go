//go:build darwin && arm64

package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/safego"
	"github.com/lengsukq/lightisle/core/internal/server"
)

const (
	maxMediaImportEncodedBytes  = 8192
	maxMediaImportDecodedBytes  = 6144
	maxMediaImportResponseBytes = 128 << 10
	mediaImportProgressInterval = 180 * time.Millisecond
)

type mediaImportRequest struct {
	RequestID   string `json:"requestID,omitempty"`
	SourcePath  string `json:"sourcePath,omitempty"`
	RootID      string `json:"rootID,omitempty"`
	Generation  uint64 `json:"generation,omitempty"`
	UserID      int64  `json:"userID,omitempty"`
	Category    string `json:"category,omitempty"`    // "auto" | "photos" | "videos" | "files"
	ArchiveMode string `json:"archiveMode,omitempty"` // "ymd" | "ym" | "preserve"
	Subfolder   string `json:"subfolder,omitempty"`
	JobID       string `json:"jobID,omitempty"`
}

type mediaImportScanResult struct {
	SourcePath     string   `json:"sourcePath"`
	VolumeName     string   `json:"volumeName"`
	TotalFiles     int      `json:"totalFiles"`
	PhotoCount     int      `json:"photoCount"`
	RawCount       int      `json:"rawCount"`
	VideoCount     int      `json:"videoCount"`
	LivePhotoCount int      `json:"livePhotoCount"`
	TotalBytes     int64    `json:"totalBytes"`
	DetectedHints  []string `json:"detectedHints,omitempty"`
	SampleFiles    []string `json:"sampleFiles,omitempty"`
	Truncated      bool     `json:"truncated,omitempty"`
}

type mediaImportStatus struct {
	JobID          string `json:"jobID"`
	Phase          string `json:"phase"` // "running" | "completed" | "cancelled" | "failed"
	SourcePath     string `json:"sourcePath"`
	RootID         string `json:"rootID"`
	Generation     uint64 `json:"generation"`
	UserID         int64  `json:"userID"`
	TotalFiles     int    `json:"totalFiles"`
	ProcessedFiles int    `json:"processedFiles"`
	ImportedFiles  int    `json:"importedFiles"`
	SkippedFiles   int    `json:"skippedFiles"`
	FailedFiles    int    `json:"failedFiles"`
	TotalBytes     int64  `json:"totalBytes"`
	ProcessedBytes int64  `json:"processedBytes"`
	ImportedBytes  int64  `json:"importedBytes"`
	CurrentFile    string `json:"currentFile,omitempty"`
	LastError      string `json:"lastError,omitempty"`
	AllVerified    bool   `json:"allVerified"`
	TargetPrefix   string `json:"targetPrefix,omitempty"`
}

type mediaImportControl struct {
	registry            *roots.Registry
	accounts            *auth.Store
	server              *server.RootServer
	output              io.Writer
	allowedSourcePrefix string
	onQueueRefresh      func(rootID, relativePath string)

	mu          sync.Mutex
	activeID    string
	cancelJob   context.CancelFunc
	running     atomic.Bool
	runningFlag *atomic.Bool
	wg          sync.WaitGroup
}

func newMediaImportControl(
	registry *roots.Registry,
	accounts *auth.Store,
	rootServer *server.RootServer,
	runningFlag *atomic.Bool,
) *mediaImportControl {
	return &mediaImportControl{
		registry:            registry,
		accounts:            accounts,
		server:              rootServer,
		output:              ipcStdout,
		allowedSourcePrefix: "/Volumes",
		runningFlag:         runningFlag,
	}
}

func (c *mediaImportControl) setRunning(active bool) {
	c.running.Store(active)
	if c.runningFlag != nil {
		c.runningFlag.Store(active)
	}
}

func (c *mediaImportControl) IsRunning() bool {
	return c != nil && c.running.Load()
}

func (c *mediaImportControl) CancelAll() {
	if c == nil {
		return
	}
	c.mu.Lock()
	cancel := c.cancelJob
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (c *mediaImportControl) Wait() {
	if c != nil {
		c.wg.Wait()
	}
}

func (c *mediaImportControl) reply(requestID, operation string, value any, errCode string) {
	writeIPCEnvelope(ipcEnvelopeOptions{
		Output:        c.output,
		Prefix:        "LIGHTISLE_MEDIA_IMPORT",
		RequestID:     requestID,
		Operation:     operation,
		Result:        value,
		IncludeResult: value != nil,
		ErrorMessage:  errCode,
		FallbackError: "media_import_response_encode_failed",
		MaxJSONBytes:  maxMediaImportResponseBytes,
	})
}

func (c *mediaImportControl) handle(ctx context.Context, command string) bool {
	if !strings.HasPrefix(command, "media-import ") {
		return false
	}
	words := strings.Fields(command)
	if len(words) < 2 {
		c.reply("", "request", nil, "media_import_invalid_request")
		return true
	}
	operation := words[1]
	var req mediaImportRequest
	if len(words) >= 3 {
		decoded, err := decodeMediaImportRequest(words[2])
		if err != nil {
			c.reply("", operation, nil, "media_import_invalid_request")
			return true
		}
		req = decoded
	} else if operation != "cancel" {
		c.reply("", operation, nil, "media_import_invalid_request")
		return true
	}

	switch operation {
	case "scan":
		c.handleScan(ctx, req)
	case "start":
		c.handleStart(ctx, req)
	case "cancel":
		c.handleCancel(req)
	default:
		c.reply(req.RequestID, operation, nil, "media_import_invalid_request")
	}
	return true
}

func decodeMediaImportRequest(encoded string) (mediaImportRequest, error) {
	var req mediaImportRequest
	if len(encoded) == 0 || len(encoded) > maxMediaImportEncodedBytes {
		return req, errors.New("invalid")
	}
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(raw) == 0 || len(raw) > maxMediaImportDecodedBytes {
		return req, errors.New("invalid")
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return req, err
	}
	if err := dec.Decode(new(any)); !errors.Is(err, io.EOF) {
		return req, errors.New("trailing")
	}
	if len(req.RequestID) > maxRootRequestIDChars {
		return req, errors.New("request_id_too_long")
	}
	return req, nil
}

func (c *mediaImportControl) handleScan(ctx context.Context, req mediaImportRequest) {
	resolved, errCode := c.validateSourcePath(req.SourcePath)
	if errCode != "" {
		c.reply(req.RequestID, "scan", nil, errCode)
		return
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer safego.Recover("media-import-scan")
		scanCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
		defer cancel()
		result, _, scanErr := scanRemovableMediaSource(scanCtx, resolved)
		if scanErr != nil {
			c.reply(req.RequestID, "scan", nil, classifyMediaImportError(scanErr))
			return
		}
		c.reply(req.RequestID, "scan", result, "")
	}()
}

func (c *mediaImportControl) handleCancel(req mediaImportRequest) {
	c.mu.Lock()
	activeID := c.activeID
	cancel := c.cancelJob
	c.mu.Unlock()
	if cancel == nil || (req.JobID != "" && activeID != "" && req.JobID != activeID) {
		c.reply(req.RequestID, "cancel", map[string]any{"cancelled": false, "jobID": activeID}, "")
		return
	}
	cancel()
	c.reply(req.RequestID, "cancel", map[string]any{"cancelled": true, "jobID": activeID}, "")
}

func (c *mediaImportControl) handleStart(ctx context.Context, req mediaImportRequest) {
	if c.registry == nil || c.accounts == nil {
		c.reply(req.RequestID, "start", nil, "media_import_unavailable")
		return
	}
	resolvedSource, errCode := c.validateSourcePath(req.SourcePath)
	if errCode != "" {
		c.reply(req.RequestID, "start", nil, errCode)
		return
	}
	archiveMode, modeOK := normalizeMediaArchiveMode(req.ArchiveMode)
	if !modeOK {
		c.reply(req.RequestID, "start", nil, "media_import_invalid_archive_mode")
		return
	}
	subfolder, subOK := sanitizeMediaImportSubfolder(req.Subfolder)
	if !subOK {
		c.reply(req.RequestID, "start", nil, "media_import_invalid_subfolder")
		return
	}
	category := strings.ToLower(strings.TrimSpace(req.Category))
	if category == "" {
		category = "auto"
	}
	if category != "auto" && category != auth.StoragePhotos && category != auth.StorageVideos && category != auth.StorageFiles {
		c.reply(req.RequestID, "start", nil, "media_import_invalid_category")
		return
	}

	targetPlan, planErr := c.resolveTargetPlan(ctx, req.RootID, req.Generation, req.UserID, category)
	if planErr != "" {
		c.reply(req.RequestID, "start", nil, planErr)
		return
	}

	jobID := newMediaImportJobID()
	jobCtx, cancel := context.WithCancel(ctx)
	c.mu.Lock()
	if c.cancelJob != nil {
		c.mu.Unlock()
		cancel()
		c.reply(req.RequestID, "start", nil, "media_import_already_running")
		return
	}
	if err := diskmgmt.WithStorageTransition(func() error {
		c.setRunning(true)
		return nil
	}); err != nil {
		c.mu.Unlock()
		cancel()
		c.reply(req.RequestID, "start", nil, classifyMediaImportError(err))
		return
	}
	c.activeID = jobID
	c.cancelJob = cancel
	c.mu.Unlock()

	initial := mediaImportStatus{
		JobID:        jobID,
		Phase:        "running",
		SourcePath:   resolvedSource,
		RootID:       targetPlan.root.ID,
		Generation:   targetPlan.root.Generation,
		UserID:       targetPlan.user.ID,
		TargetPrefix: joinRelativePrefix(targetPlan.primaryBase, subfolder),
	}
	c.reply(req.RequestID, "start", initial, "")

	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer safego.Recover("media-import-run")
		defer func() {
			cancel()
			c.setRunning(false)
			c.mu.Lock()
			if c.activeID == jobID {
				c.activeID = ""
				c.cancelJob = nil
			}
			c.mu.Unlock()
		}()
		c.executeImportJob(jobCtx, req.RequestID, jobID, resolvedSource, targetPlan, archiveMode, subfolder)
	}()
}

type mediaImportTargetPlan struct {
	root        roots.Root
	user        auth.User
	category    string
	photosBase  string
	videosBase  string
	filesBase   string
	primaryBase string
}

func (p mediaImportTargetPlan) baseFor(kind mediaKind) string {
	switch p.category {
	case auth.StoragePhotos:
		return p.photosBase
	case auth.StorageVideos:
		return p.videosBase
	case auth.StorageFiles:
		return p.filesBase
	default:
		if kind == mediaKindVideo {
			if p.videosBase != "" {
				return p.videosBase
			}
			if p.photosBase != "" {
				return p.photosBase
			}
			return p.filesBase
		}
		if p.photosBase != "" {
			return p.photosBase
		}
		if p.videosBase != "" {
			return p.videosBase
		}
		return p.filesBase
	}
}

func (c *mediaImportControl) resolveTargetPlan(
	ctx context.Context,
	rootID string,
	generation uint64,
	userID int64,
	category string,
) (mediaImportTargetPlan, string) {
	if rootID == "" || generation == 0 || userID <= 0 {
		return mediaImportTargetPlan{}, "media_import_invalid_request"
	}
	var matchedRoot *roots.Root
	for _, r := range c.registry.List() {
		if r.ID == rootID {
			copyRoot := r
			matchedRoot = &copyRoot
			break
		}
	}
	if matchedRoot == nil {
		return mediaImportTargetPlan{}, "root_not_found"
	}
	if matchedRoot.Generation != generation {
		return mediaImportTargetPlan{}, "root_unavailable"
	}
	lease, err := c.registry.Acquire(ctx, matchedRoot.ID)
	if err != nil {
		return mediaImportTargetPlan{}, classifyMediaImportError(err)
	}
	valid := lease.Binding == matchedRoot.Binding && lease.Valid(ctx)
	_ = lease.Close()
	if !valid {
		return mediaImportTargetPlan{}, "root_unavailable"
	}

	user, err := c.accounts.GetUser(userID)
	if err != nil || !user.Enabled {
		return mediaImportTargetPlan{}, "user_not_found"
	}
	policy, err := c.accounts.NativeStoragePolicy(user.ID)
	if err != nil {
		return mediaImportTargetPlan{}, classifyMediaImportError(err)
	}
	plan := mediaImportTargetPlan{root: *matchedRoot, user: user, category: category}
	for _, loc := range policy.Locations {
		if loc.RootID != matchedRoot.ID || loc.RootGeneration != matchedRoot.Generation {
			continue
		}
		switch loc.Category {
		case auth.StoragePhotos:
			plan.photosBase = strings.Trim(loc.RelativePath, "/")
		case auth.StorageVideos:
			plan.videosBase = strings.Trim(loc.RelativePath, "/")
		case auth.StorageFiles:
			plan.filesBase = strings.Trim(loc.RelativePath, "/")
		}
	}
	switch category {
	case auth.StoragePhotos:
		plan.primaryBase = plan.photosBase
	case auth.StorageVideos:
		plan.primaryBase = plan.videosBase
	case auth.StorageFiles:
		plan.primaryBase = plan.filesBase
	default:
		if plan.photosBase != "" {
			plan.primaryBase = plan.photosBase
		} else if plan.videosBase != "" {
			plan.primaryBase = plan.videosBase
		} else {
			plan.primaryBase = plan.filesBase
		}
	}
	if plan.primaryBase == "" {
		return mediaImportTargetPlan{}, "target_user_location_missing"
	}
	return plan, ""
}

func (c *mediaImportControl) executeImportJob(
	ctx context.Context,
	requestID, jobID, sourcePath string,
	plan mediaImportTargetPlan,
	archiveMode, subfolder string,
) {
	status := mediaImportStatus{
		JobID:        jobID,
		Phase:        "running",
		SourcePath:   sourcePath,
		RootID:       plan.root.ID,
		Generation:   plan.root.Generation,
		UserID:       plan.user.ID,
		TargetPrefix: joinRelativePrefix(plan.primaryBase, subfolder),
	}

	scanResult, items, scanErr := scanRemovableMediaSource(ctx, sourcePath)
	if scanErr != nil {
		status.Phase = terminalPhaseForError(ctx, scanErr)
		status.LastError = classifyMediaImportError(scanErr)
		c.reply(requestID, "complete", status, status.LastError)
		return
	}
	status.TotalFiles = scanResult.TotalFiles
	status.TotalBytes = scanResult.TotalBytes
	if len(items) == 0 {
		status.Phase = "completed"
		c.reply(requestID, "complete", status, "")
		return
	}

	lease, err := c.registry.Acquire(ctx, plan.root.ID)
	if err != nil {
		status.Phase = "failed"
		status.LastError = classifyMediaImportError(err)
		c.reply(requestID, "complete", status, status.LastError)
		return
	}
	defer func() { _ = lease.Close() }()
	if lease.Binding != plan.root.Binding || !lease.Valid(ctx) {
		status.Phase = "failed"
		status.LastError = "root_unavailable"
		c.reply(requestID, "complete", status, status.LastError)
		return
	}
	manager, err := files.NewPinnedManager(lease.Root, lease.Binding)
	if err != nil {
		status.Phase = "failed"
		status.LastError = classifyMediaImportError(err)
		c.reply(requestID, "complete", status, status.LastError)
		return
	}
	defer func() { _ = manager.Close() }()

	touchedPrefixes := map[string]bool{}
	lastEmit := time.Now()
	c.reply(requestID, "progress", status, "")

	for _, item := range items {
		if ctx.Err() != nil {
			status.Phase = "cancelled"
			status.LastError = "media_import_cancelled"
			break
		}
		if !lease.Valid(ctx) {
			status.Phase = "failed"
			status.LastError = "root_unavailable"
			break
		}
		status.CurrentFile = item.RelPath
		baseRel := plan.baseFor(item.Kind)
		if baseRel == "" {
			status.FailedFiles++
			status.ProcessedFiles++
			status.LastError = "target_user_location_missing"
			continue
		}
		desiredRel, pathErr := buildArchiveRelativePath(baseRel, subfolder, archiveMode, item)
		if pathErr != nil {
			status.FailedFiles++
			status.ProcessedFiles++
			status.LastError = "media_import_invalid_filename"
			continue
		}

		outcome, importedBytes, itemErr := c.importSingleMediaItem(ctx, lease, manager, plan, item, desiredRel)
		status.ProcessedFiles++
		switch outcome {
		case "skipped":
			status.SkippedFiles++
			status.ProcessedBytes += item.Size
		case "imported":
			status.ImportedFiles++
			status.ImportedBytes += importedBytes
			status.ProcessedBytes += importedBytes
			touchedPrefixes[joinRelativePrefix(baseRel, subfolder)] = true
		default:
			status.FailedFiles++
			errCode := classifyMediaImportError(itemErr)
			status.LastError = errCode
			if isFatalMediaImportError(itemErr, errCode) {
				status.Phase = terminalPhaseForError(ctx, itemErr)
				goto finish
			}
		}

		if status.TotalFiles <= 20 || time.Since(lastEmit) >= mediaImportProgressInterval {
			c.reply(requestID, "progress", status, "")
			lastEmit = time.Now()
		}
	}

finish:
	status.CurrentFile = ""
	if status.Phase == "running" {
		if ctx.Err() != nil {
			status.Phase = "cancelled"
			status.LastError = "media_import_cancelled"
		} else if status.FailedFiles > 0 && status.ImportedFiles == 0 && status.SkippedFiles == 0 {
			status.Phase = "failed"
		} else {
			status.Phase = "completed"
		}
	}
	status.AllVerified = status.Phase == "completed" &&
		status.FailedFiles == 0 &&
		status.TotalFiles > 0 &&
		(status.ImportedFiles+status.SkippedFiles) == status.TotalFiles

	if status.ImportedFiles > 0 {
		for prefix := range touchedPrefixes {
			if c.onQueueRefresh != nil {
				c.onQueueRefresh(plan.root.ID, prefix)
			} else if c.server != nil {
				c.server.QueueMediaRefresh(plan.root.ID, prefix)
			}
		}
	}

	errToReport := ""
	if status.Phase == "failed" {
		errToReport = status.LastError
	}
	c.reply(requestID, "complete", status, errToReport)
}

func (c *mediaImportControl) importSingleMediaItem(
	ctx context.Context,
	lease *roots.Lease,
	manager *files.Manager,
	plan mediaImportTargetPlan,
	item scannedMediaItem,
	desiredRel string,
) (string, int64, error) {
	srcInfo, err := os.Lstat(item.FullPath)
	if err != nil {
		return "failed", 0, err
	}
	if !srcInfo.Mode().IsRegular() {
		return "failed", 0, errors.New("source_not_regular_file")
	}
	actualSize := srcInfo.Size()

	var cachedSrcHash string
	getSourceHash := func() (string, error) {
		if cachedSrcHash != "" {
			return cachedSrcHash, nil
		}
		h, hashErr := hashLocalFileSHA256(ctx, item.FullPath)
		if hashErr != nil {
			return "", hashErr
		}
		cachedSrcHash = h
		return cachedSrcHash, nil
	}

	targetRel, skipped, resolveErr := resolveDeduplicatedTarget(ctx, manager, lease.Binding, desiredRel, actualSize, getSourceHash)
	if resolveErr != nil {
		return "failed", 0, resolveErr
	}
	if skipped {
		return "skipped", 0, nil
	}

	resID, tracked, resErr := c.accounts.ReserveStorageUploadForUser(
		plan.user, plan.root.ID, plan.root.Generation, targetRel, actualSize,
	)
	if resErr != nil {
		return "failed", 0, resErr
	}

	srcFile, openErr := os.Open(item.FullPath)
	if openErr != nil {
		if tracked {
			_ = c.accounts.ReleaseStorageReservation(resID)
		}
		return "failed", 0, openErr
	}
	defer func() { _ = srcFile.Close() }()

	var publishedIdentity string
	reader := &ctxReader{ctx: ctx, r: io.LimitReader(srcFile, actualSize)}
	written, pubErr := manager.PublishDownloadPrepared(lease.Binding, targetRel, reader, func(info os.FileInfo) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !lease.Valid(ctx) {
			return roots.ErrOffline
		}
		publishedIdentity = files.MediaFileIdentity(info)
		return nil
	})
	if pubErr != nil {
		if tracked {
			_ = c.accounts.ReleaseStorageReservation(resID)
		}
		return "failed", 0, pubErr
	}
	if written != actualSize {
		if tracked {
			_ = c.accounts.ReleaseStorageReservation(resID)
		}
		return "failed", 0, errors.New("media_import_size_mismatch")
	}
	if tracked {
		if commitErr := c.accounts.CommitStorageReservationWithIdentity(resID, publishedIdentity); commitErr != nil {
			return "failed", written, commitErr
		}
	}
	return "imported", written, nil
}

func newMediaImportJobID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return "mi-" + hex.EncodeToString(b[:])
}
