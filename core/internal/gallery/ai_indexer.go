package gallery

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"os"
	"path"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

const (
	aiIndexBatchSize      = mediaworker.MaxAIBatchItems
	aiIndexIdleInterval   = 2 * time.Minute
	aiIndexActiveDelay    = 1500 * time.Millisecond
	aiIndexPriorityDelay  = 100 * time.Millisecond
	aiIndexThrottleDelay  = 30 * time.Second
	maxPriorityAIQueueLen = 128
	priorityAIHoldTTL     = 2 * time.Minute
)

type aiPriorityItem struct {
	relPath    string
	enqueuedAt time.Time
}

type AIIndexStatus struct {
	Running   bool `json:"running"`
	Paused    bool `json:"paused"`
	Remaining int  `json:"remaining"`
	Total     int  `json:"total"`
}

type aiBatchAnalyzer interface {
	AnalyzeBatch(ctx context.Context, items []mediaworker.AIBatchInput) ([]mediaworker.AIAnalysis, error)
}

func (l *Library) SetAIAnalyzer(analyzer aiBatchAnalyzer) {
	l.mu.Lock()
	l.aiWorker = analyzer
	l.mu.Unlock()
	l.TriggerAIIndex()
}

func (l *Library) SetAIPaused(paused bool) {
	l.mu.Lock()
	l.aiPaused = paused
	l.aiStatus.Paused = paused
	l.mu.Unlock()
	if !paused {
		l.TriggerAIIndex()
	}
}

func (l *Library) AIPaused() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.aiPaused
}

func (l *Library) TriggerAIIndex() {
	if l.aiWake == nil {
		return
	}
	select {
	case l.aiWake <- struct{}{}:
	default:
	}
}

// EnqueuePriorityAI pushes a newly uploaded document/receipt photo ahead of
// the background AI backlog so Apple Vision OCR completes within seconds.
func (l *Library) EnqueuePriorityAI(relPath string) bool {
	clean := cleanPriorityRelPath(relPath)
	if clean == "" || mediaType(path.Base(clean)) != "photo" {
		return false
	}
	now := l.currentTime()
	l.mu.Lock()
	if l.aiPrioritySet == nil {
		l.aiPrioritySet = make(map[string]struct{})
	}
	if _, exists := l.aiPrioritySet[clean]; !exists {
		if len(l.aiPriority) >= maxPriorityAIQueueLen {
			oldest := l.aiPriority[0]
			l.aiPriority = l.aiPriority[1:]
			delete(l.aiPrioritySet, oldest.relPath)
		}
		l.aiPriority = append(l.aiPriority, aiPriorityItem{relPath: clean, enqueuedAt: now})
		l.aiPrioritySet[clean] = struct{}{}
	}
	l.mu.Unlock()
	l.TriggerAIIndex()
	return true
}

// PriorityAIQueueLen returns the number of paths currently queued for
// high-priority OCR/AI indexing.
func (l *Library) PriorityAIQueueLen() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.aiPriority)
}

// IndexSinglePhotoNow immediately indexes a single photo file into the gallery
// database (without waiting for the debounced directory refresh) so priority
// OCR and asset AI polling can start right away.
func (l *Library) IndexSinglePhotoNow(ctx context.Context, relPath string) (Asset, error) {
	clean := cleanPriorityRelPath(relPath)
	if clean == "" || mediaType(path.Base(clean)) != "photo" {
		return Asset{}, errors.New("invalid_photo_path")
	}
	share, physicalShare, err := l.shareState()
	if err != nil {
		return Asset{}, err
	}
	info, err := l.storage.Stat(clean)
	if err != nil {
		return Asset{}, err
	}
	if !info.Mode().IsRegular() {
		return Asset{}, files.ErrType
	}
	if !l.Status().Running {
		entry := files.Entry{
			Name:       path.Base(clean),
			Path:       clean,
			Type:       "file",
			Size:       info.Size(),
			Modified:   info.ModTime(),
			Identity:   files.MediaFileIdentity(info),
			SingleLink: files.MediaFileHasSingleLink(info),
		}
		if err := l.indexScanBatch(ctx, share, physicalShare, l.currentTime().UnixNano(), []files.Entry{entry}); err != nil {
			return Asset{}, err
		}
	}
	var id int64
	err = l.db.QueryRowContext(ctx,
		`SELECT id FROM assets WHERE share=? AND path=? AND missing_path=''`,
		share, clean).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return Asset{}, nil
	}
	if err != nil {
		return Asset{}, err
	}
	return l.Asset(id)
}

func cleanPriorityRelPath(raw string) string {
	trimmed := strings.Trim(strings.TrimSpace(raw), "/")
	if trimmed == "" || trimmed == "." || strings.ContainsAny(trimmed, "\\\x00") {
		return ""
	}
	clean := path.Clean(trimmed)
	if clean == "." || clean != trimmed {
		return ""
	}
	for _, part := range strings.Split(clean, "/") {
		if part == "" || part == "." || part == ".." || files.IsInternalName(part) {
			return ""
		}
	}
	return clean
}

func (l *Library) aiIndexLoop() {
	defer l.wg.Done()
	for {
		delay := l.aiIndexStep()
		select {
		case <-l.ctx.Done():
			return
		case <-l.aiWake:
		case <-time.After(delay):
		}
	}
}

func (l *Library) aiIndexStep() time.Duration {
	l.mu.Lock()
	analyzer := l.aiWorker
	paused := l.aiPaused
	scanRunning := l.status.Running
	l.mu.Unlock()

	if analyzer == nil || paused {
		l.setAIRunning(false)
		return aiIndexIdleInterval
	}
	if scanRunning {
		l.setAIRunning(false)
		return aiIndexActiveDelay
	}

	share, err := l.share()
	if err != nil {
		l.setAIRunning(false)
		return aiIndexIdleInterval
	}
	candidates, err := l.nextAIBatch(share, aiIndexBatchSize)
	if err != nil || len(candidates) == 0 {
		l.refreshAIStatus(share, false)
		return aiIndexIdleInterval
	}
	l.refreshAIStatus(share, true)

	throttled, _ := l.processAIBatch(share, analyzer, candidates)
	l.refreshAIStatus(share, false)
	if throttled {
		return aiIndexThrottleDelay
	}
	if l.PriorityAIQueueLen() > 0 {
		return aiIndexPriorityDelay
	}
	return aiIndexActiveDelay
}

type aiCandidate struct {
	id       int64
	relPath  string
	size     int64
	modified int64
}

func (l *Library) popPriorityAICandidates(share string, limit int) []aiCandidate {
	l.mu.Lock()
	if len(l.aiPriority) == 0 {
		l.mu.Unlock()
		return nil
	}
	snapshot := append([]aiPriorityItem(nil), l.aiPriority...)
	l.mu.Unlock()

	now := l.currentTime()
	selected := make([]aiCandidate, 0, min(len(snapshot), limit))
	removePaths := make(map[string]struct{})

	for _, item := range snapshot {
		if len(selected) >= limit {
			break
		}
		var c aiCandidate
		var aiVer, srcSize, srcMod sql.NullInt64
		err := l.db.QueryRow(`
			SELECT a.id, a.path, a.size, a.modified,
			       s.ai_version, s.source_size, s.source_modified
			FROM assets a
			LEFT JOIN ai_index_state s ON s.asset_id = a.id
			WHERE a.share = ? AND a.path = ? AND a.missing_path = '' AND a.type = 'photo'`,
			share, item.relPath).Scan(&c.id, &c.relPath, &c.size, &c.modified, &aiVer, &srcSize, &srcMod)
		if errors.Is(err, sql.ErrNoRows) {
			if now.Sub(item.enqueuedAt) >= priorityAIHoldTTL {
				removePaths[item.relPath] = struct{}{}
			}
			continue
		}
		if err != nil {
			continue
		}
		removePaths[item.relPath] = struct{}{}
		needsIndex := !aiVer.Valid || aiVer.Int64 < aiSchemaVersion || srcSize.Int64 != c.size || srcMod.Int64 != c.modified
		if needsIndex {
			selected = append(selected, c)
		}
	}

	if len(removePaths) > 0 {
		l.mu.Lock()
		kept := l.aiPriority[:0]
		for _, item := range l.aiPriority {
			if _, drop := removePaths[item.relPath]; drop {
				delete(l.aiPrioritySet, item.relPath)
				continue
			}
			kept = append(kept, item)
		}
		l.aiPriority = kept
		l.mu.Unlock()
	}
	return selected
}

func (l *Library) nextAIBatch(share string, limit int) ([]aiCandidate, error) {
	batch := l.popPriorityAICandidates(share, limit)
	remaining := limit - len(batch)
	if remaining <= 0 {
		return batch, nil
	}
	seenIDs := make(map[int64]struct{}, len(batch))
	for _, c := range batch {
		seenIDs[c.id] = struct{}{}
	}
	queryLimit := remaining + len(batch)
	rows, err := l.db.Query(`
		SELECT a.id, a.path, a.size, a.modified
		FROM assets a
		LEFT JOIN ai_index_state s ON s.asset_id = a.id
		WHERE a.share = ? AND a.missing_path = '' AND a.type = 'photo'
		  AND (s.asset_id IS NULL OR s.ai_version < ? OR s.source_size <> a.size OR s.source_modified <> a.modified)
		ORDER BY a.taken_at DESC, a.id DESC
		LIMIT ?`, share, aiSchemaVersion, queryLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		if len(batch) >= limit {
			break
		}
		var c aiCandidate
		if err := rows.Scan(&c.id, &c.relPath, &c.size, &c.modified); err != nil {
			return nil, err
		}
		if _, dup := seenIDs[c.id]; dup {
			continue
		}
		seenIDs[c.id] = struct{}{}
		batch = append(batch, c)
	}
	return batch, rows.Err()
}

func (l *Library) processAIBatch(share string, analyzer aiBatchAnalyzer, candidates []aiCandidate) (bool, int) {
	opened := make([]*os.File, 0, len(candidates))
	valid := make([]aiCandidate, 0, len(candidates))
	inputs := make([]mediaworker.AIBatchInput, 0, len(candidates))
	defer func() {
		for _, f := range opened {
			_ = f.Close()
		}
	}()

	nowUnix := l.currentTime().Unix()
	for _, c := range candidates {
		if l.ctx.Err() != nil || l.Status().Running || l.AIPaused() {
			break
		}
		file, info, err := l.storage.Read(c.relPath)
		if err != nil {
			_ = l.recordAIStateOnly(c.id, c.size, c.modified, "failed", nowUnix)
			continue
		}
		if !info.Mode().IsRegular() || info.Size() != c.size || info.ModTime().UnixNano() != c.modified {
			_ = file.Close()
			continue
		}
		opened = append(opened, file)
		valid = append(valid, c)
		inputs = append(inputs, mediaworker.AIBatchInput{
			Source: file,
			Name:   path.Base(c.relPath),
		})
	}
	if len(inputs) == 0 {
		return false, 0
	}

	results, err := analyzer.AnalyzeBatch(l.ctx, inputs)
	if err != nil {
		if errors.Is(err, mediaworker.ErrThrottled) {
			return true, 0
		}
		if errors.Is(err, mediaworker.ErrUnavailable) || errors.Is(err, context.Canceled) {
			return false, 0
		}
		for _, c := range valid {
			_ = l.recordAIStateOnly(c.id, c.size, c.modified, "failed", nowUnix)
		}
		return false, 0
	}

	throttled := false
	processed := 0
	for i, res := range results {
		if i >= len(valid) {
			break
		}
		if res.Status == "throttled" {
			throttled = true
			continue
		}
		if l.persistAIAnalysis(share, valid[i], res, nowUnix) == nil {
			processed++
		}
	}
	return throttled, processed
}

func (l *Library) recordAIStateOnly(assetID, size, modified int64, status string, nowUnix int64) error {
	_, err := l.db.Exec(`
		INSERT INTO ai_index_state(asset_id, source_size, source_modified, ai_version, status, updated_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(asset_id) DO UPDATE SET
			source_size=excluded.source_size,
			source_modified=excluded.source_modified,
			ai_version=excluded.ai_version,
			status=excluded.status,
			updated_at=excluded.updated_at`,
		assetID, size, modified, aiSchemaVersion, status, nowUnix)
	return err
}

func (l *Library) persistAIAnalysis(share string, c aiCandidate, res mediaworker.AIAnalysis, nowUnix int64) error {
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var liveSize, liveModified int64
	if err := tx.QueryRow(
		`SELECT size, modified FROM assets WHERE id=? AND share=? AND missing_path=''`,
		c.id, share,
	).Scan(&liveSize, &liveModified); err != nil {
		return err
	}
	if liveSize != c.size || liveModified != c.modified {
		return ErrAssetChanged
	}

	for _, table := range []string{"asset_ocr", "asset_search_tokens", "asset_scene_tags", "asset_faces", "asset_features"} {
		if _, err := tx.Exec("DELETE FROM "+table+" WHERE asset_id=?", c.id); err != nil {
			return err
		}
	}

	if res.Status == "ok" {
		if text := strings.TrimSpace(res.OCRText); text != "" {
			if _, err := tx.Exec(`INSERT INTO asset_ocr(asset_id, raw_text, updated_at) VALUES(?, ?, ?)`, c.id, text, nowUnix); err != nil {
				return err
			}
			for _, ngram := range extractOCRIndexTokens(text) {
				if _, err := tx.Exec(`INSERT OR IGNORE INTO asset_search_tokens(token, source, asset_id, score) VALUES(?, 'ocr', ?, 1.0)`, ngram, c.id); err != nil {
					return err
				}
			}
		}
		for _, tok := range res.OCRTokens {
			norm := normalizeSearchToken(tok)
			if norm == "" {
				continue
			}
			if _, err := tx.Exec(`INSERT OR IGNORE INTO asset_search_tokens(token, source, asset_id, score) VALUES(?, 'ocr', ?, 1.0)`, norm, c.id); err != nil {
				return err
			}
		}
		for _, tag := range res.SceneTags {
			label := strings.ToLower(strings.TrimSpace(tag.Label))
			if label == "" {
				continue
			}
			if _, err := tx.Exec(`INSERT OR REPLACE INTO asset_scene_tags(asset_id, label, confidence) VALUES(?, ?, ?)`, c.id, label, tag.Confidence); err != nil {
				return err
			}
			terms := append([]string{label}, tag.SearchTerms...)
			terms = append(terms, builtinSceneAliases(label)...)
			for _, term := range terms {
				norm := normalizeSearchToken(term)
				if norm == "" {
					continue
				}
				if _, err := tx.Exec(`
					INSERT INTO asset_search_tokens(token, source, asset_id, score) VALUES(?, 'scene', ?, ?)
					ON CONFLICT(token, source, asset_id) DO UPDATE SET score = MAX(score, excluded.score)`,
					norm, c.id, tag.Confidence); err != nil {
					return err
				}
			}
		}
		for _, f := range res.Faces {
			if len(f.Embedding) == 0 {
				continue
			}
			if _, err := tx.Exec(`
				INSERT INTO asset_faces(asset_id, box_x, box_y, box_w, box_h, quality, eye_openness, model_version, embedding)
				VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				c.id, f.BoxX, f.BoxY, f.BoxW, f.BoxH, f.Quality, f.EyeOpenness, f.ModelVersion, f.Embedding); err != nil {
				return err
			}
		}
		if len(res.FeaturePrintF16) > 0 {
			aesthetics := float32(0)
			if res.Aesthetics != nil {
				aesthetics = *res.Aesthetics
			}
			utility := 0
			if res.IsUtility != nil && *res.IsUtility {
				utility = 1
			}
			if _, err := tx.Exec(`
				INSERT INTO asset_features(asset_id, feature_print_f16, sharpness, aesthetics, is_utility)
				VALUES(?, ?, ?, ?, ?)`,
				c.id, res.FeaturePrintF16, res.Sharpness, aesthetics, utility); err != nil {
				return err
			}
		}
	}

	state := res.Status
	if state != "ok" && state != "unsupported" {
		state = "failed"
	}
	if _, err := tx.Exec(`
		INSERT INTO ai_index_state(asset_id, source_size, source_modified, ai_version, status, updated_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(asset_id) DO UPDATE SET
			source_size=excluded.source_size,
			source_modified=excluded.source_modified,
			ai_version=excluded.ai_version,
			status=excluded.status,
			updated_at=excluded.updated_at`,
		c.id, c.size, c.modified, aiSchemaVersion, state, nowUnix); err != nil {
		return err
	}
	return tx.Commit()
}

func (l *Library) setAIRunning(running bool) {
	l.mu.Lock()
	l.aiStatus.Running = running
	l.aiStatus.Paused = l.aiPaused
	l.mu.Unlock()
}

func (l *Library) refreshAIStatus(share string, running bool) {
	rdb := l.readDB()
	var total, remaining int
	if err := rdb.QueryRow(`SELECT COUNT(*) FROM assets WHERE share=? AND missing_path='' AND type='photo'`, share).Scan(&total); err != nil && !errors.Is(err, sql.ErrNoRows) {
		slog.Warn("gallery AI total count query failed", "share", share, "error", err)
		return
	}
	if err := rdb.QueryRow(`
		SELECT COUNT(*) FROM assets a
		LEFT JOIN ai_index_state s ON s.asset_id=a.id
		WHERE a.share=? AND a.missing_path='' AND a.type='photo'
		  AND (s.asset_id IS NULL OR s.ai_version<? OR s.source_size<>a.size OR s.source_modified<>a.modified)`,
		share, aiSchemaVersion).Scan(&remaining); err != nil && !errors.Is(err, sql.ErrNoRows) {
		slog.Warn("gallery AI remaining count query failed", "share", share, "error", err)
		return
	}
	l.mu.Lock()
	l.aiStatus = AIIndexStatus{
		Running:   running && remaining > 0 && !l.aiPaused,
		Paused:    l.aiPaused,
		Remaining: remaining,
		Total:     total,
	}
	l.mu.Unlock()
}

func (l *Library) currentTime() time.Time {
	if l.now != nil {
		return l.now()
	}
	return time.Now()
}
