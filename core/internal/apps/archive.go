package apps

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const (
	maxPluginArchiveBytes     = 512 << 20 // 512 MiB cap for plugin business data archive
	maxPluginArchiveFiles     = 10000
	PluginBackupSchemaVersion = 1
	backupManifestArchivePath = "backup-manifest.json"
)

type PluginBackupFileEntry struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type PluginBackupManifest struct {
	SchemaVersion int                     `json:"schemaVersion"`
	AppID         string                  `json:"appId"`
	CreatedAt     string                  `json:"createdAt"`
	DataFileCount int                     `json:"dataFileCount"`
	Files         []PluginBackupFileEntry `json:"files"`
}

// ExportAppData streams a consistent .tar.gz archive containing the plugin's
// configuration (plugin.json, env.json), its isolated business data directory
// (plugin-data/<id>/), and backup-manifest.json with SHA-256 checksums.
// Any SQLite database is snapshotted via VACUUM INTO; if snapshotting fails,
// export aborts immediately rather than falling back to an inconsistent raw copy.
func (m *Manager) ExportAppData(ctx context.Context, appID string, w io.Writer) error {
	if !ValidPluginID(appID) {
		return ErrInvalid
	}
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}

	if err := os.MkdirAll(rec.dataDir, 0700); err != nil {
		return err
	}

	gz := gzip.NewWriter(w)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	var totalBytes int64
	var totalFiles int
	var dataFileCount int
	manifestEntries := make([]PluginBackupFileEntry, 0, 16)

	addFile := func(archivePath, diskPath string, mode int64, isData bool) error {
		st, err := os.Lstat(diskPath)
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if !st.Mode().IsRegular() {
			return nil
		}
		totalFiles++
		if totalFiles > maxPluginArchiveFiles || totalBytes+st.Size() > maxPluginArchiveBytes {
			return fmt.Errorf("%w: 插件业务数据超过 512 MiB 导出上限", ErrInvalid)
		}
		f, err := os.Open(diskPath)
		if err != nil {
			return err
		}
		defer f.Close()

		hasher := sha256.New()
		if _, err := io.Copy(hasher, io.LimitReader(f, st.Size()+1)); err != nil {
			return err
		}
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return err
		}
		digest := hex.EncodeToString(hasher.Sum(nil))

		hdr := &tar.Header{
			Name:    archivePath,
			Size:    st.Size(),
			Mode:    mode,
			ModTime: st.ModTime(),
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		n, err := io.Copy(tw, io.LimitReader(f, st.Size()+1))
		if err != nil {
			return err
		}
		if n != st.Size() {
			return fmt.Errorf("导出文件 %s 大小在读取过程中发生变化", archivePath)
		}
		totalBytes += n
		if isData {
			dataFileCount++
		}
		manifestEntries = append(manifestEntries, PluginBackupFileEntry{
			Path:   archivePath,
			Size:   n,
			SHA256: digest,
		})
		return nil
	}

	for _, cfgName := range []string{"plugin.json", "env.json"} {
		if err := addFile(path.Join("config", cfgName), filepath.Join(rec.pluginDir, cfgName), 0600, false); err != nil {
			return err
		}
	}

	walkErr := filepath.WalkDir(rec.dataDir, func(curPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if curPath == rec.dataDir {
			return nil
		}
		rel, err := filepath.Rel(rec.dataDir, curPath)
		if err != nil {
			return err
		}
		slashRel := filepath.ToSlash(rel)
		if strings.HasPrefix(slashRel, ".") || strings.Contains(slashRel, "/.") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		// Skip SQLite WAL/SHM/Journal sidecars; primary DB files are exported via VACUUM INTO.
		lower := strings.ToLower(slashRel)
		if strings.HasSuffix(lower, "-wal") || strings.HasSuffix(lower, "-shm") || strings.HasSuffix(lower, "-journal") {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 || d.IsDir() {
			return nil
		}
		isSQLite, err := isSQLiteDatabaseFile(slashRel, curPath)
		if err != nil {
			return err
		}
		if isSQLite {
			tmpDir, tmpErr := os.MkdirTemp("", "lightisle-plugin-sqlite-*")
			if tmpErr != nil {
				return fmt.Errorf("创建 SQLite 快照临时目录失败 (%s): %w", slashRel, tmpErr)
			}
			defer os.RemoveAll(tmpDir)
			snapPath := filepath.Join(tmpDir, "snapshot.db")
			if vacuumErr := vacuumSQLiteFile(ctx, curPath, snapPath); vacuumErr != nil {
				return fmt.Errorf("%w: SQLite 数据库 %s 一致性快照失败 (%v)，已中止导出", ErrInvalid, slashRel, vacuumErr)
			}
			return addFile(path.Join("data", slashRel), snapPath, 0600, true)
		}
		return addFile(path.Join("data", slashRel), curPath, 0600, true)
	})
	if walkErr != nil {
		return walkErr
	}

	manifest := PluginBackupManifest{
		SchemaVersion: PluginBackupSchemaVersion,
		AppID:         appID,
		CreatedAt:     time.Now().UTC().Format(time.RFC3339),
		DataFileCount: dataFileCount,
		Files:         manifestEntries,
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	hdr := &tar.Header{
		Name:    backupManifestArchivePath,
		Size:    int64(len(manifestBytes)),
		Mode:    0600,
		ModTime: time.Now(),
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	if _, err := tw.Write(manifestBytes); err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}

func isSQLiteDatabaseFile(slashRel, diskPath string) (bool, error) {
	lower := strings.ToLower(slashRel)
	if strings.HasSuffix(lower, ".sqlite") || strings.HasSuffix(lower, ".sqlite3") || strings.HasSuffix(lower, ".db") {
		return true, nil
	}
	f, err := os.Open(diskPath)
	if err != nil {
		return false, err
	}
	defer f.Close()
	var magic [16]byte
	n, _ := io.ReadFull(f, magic[:])
	if n == 16 && string(magic[:]) == "SQLite format 3\x00" {
		return true, nil
	}
	return false, nil
}

func vacuumSQLiteFile(ctx context.Context, srcPath, dstPath string) error {
	uri := (&url.URL{Scheme: "file", Path: srcPath}).String() + "?mode=ro&_busy_timeout=5000"
	db, err := sql.Open("sqlite3", uri)
	if err != nil {
		return err
	}
	db.SetMaxOpenConns(1)
	defer db.Close()
	_, err = db.ExecContext(ctx, "VACUUM INTO ?", dstPath)
	return err
}

func validateEnvBytes(raw []byte) error {
	var values map[string]string
	if err := json.Unmarshal(raw, &values); err != nil {
		return fmt.Errorf("env.json JSON 格式错误: %w", err)
	}
	for k, v := range values {
		if !envKeyPattern.MatchString(k) || len(v) > 4096 || strings.ContainsRune(v, 0) {
			return fmt.Errorf("env.json 包含非法键名或值: %s", k)
		}
	}
	return nil
}

// RestoreAppData validates and stages the uploaded .tar.gz archive BEFORE stopping
// any running plugin process. It verifies backup-manifest.json (plugin ID, schemaVersion,
// non-empty business data file list, and per-file SHA-256 checksums) before swapping
// plugin-data/<id>/. If the swap fails, it rolls back the previous data directory and
// restores the prior running state.
func (m *Manager) RestoreAppData(ctx context.Context, appID string, r io.Reader) error {
	if !ValidPluginID(appID) {
		return ErrInvalid
	}
	m.mutation.Lock()
	m.mu.Lock()
	rec, ok := m.apps[appID]
	m.mu.Unlock()
	if !ok {
		m.mutation.Unlock()
		return ErrNotFound
	}

	stageDir := fmt.Sprintf("%s.restore-%d", rec.dataDir, time.Now().UnixNano())
	if err := os.MkdirAll(stageDir, 0700); err != nil {
		m.mutation.Unlock()
		return err
	}
	cleanupStage := func() { _ = os.RemoveAll(stageDir) }

	gz, err := gzip.NewReader(io.LimitReader(r, maxPluginArchiveBytes+(1<<20)))
	if err != nil {
		cleanupStage()
		m.mutation.Unlock()
		return fmt.Errorf("%w: 无法解压备份归档 (%v)", ErrInvalid, err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	var totalBytes int64
	var totalFiles int
	var restoredEnv []byte
	var restoredPluginJSON []byte
	var backupManifest *PluginBackupManifest
	extractedEntries := make(map[string]PluginBackupFileEntry)
	var extractedDataCount int

	for {
		if err := ctx.Err(); err != nil {
			cleanupStage()
			m.mutation.Unlock()
			return err
		}
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 读取归档条目失败 (%v)", ErrInvalid, err)
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			continue
		}
		cleanName := path.Clean(strings.TrimPrefix(hdr.Name, "/"))
		if cleanName == "." || strings.HasPrefix(cleanName, "../") || strings.Contains(cleanName, "..") {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 非法归档路径 %q", ErrInvalid, hdr.Name)
		}
		if _, dup := extractedEntries[cleanName]; dup || (cleanName == backupManifestArchivePath && backupManifest != nil) {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 归档中存在重复条目 %q", ErrInvalid, cleanName)
		}
		totalFiles++
		if totalFiles > maxPluginArchiveFiles || hdr.Size < 0 || totalBytes+hdr.Size > maxPluginArchiveBytes {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 备份归档超出 512 MiB 安全大小限制", ErrInvalid)
		}

		if cleanName == backupManifestArchivePath {
			if hdr.Size > (4 << 20) {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: backup-manifest.json 超出大小限制", ErrInvalid)
			}
			raw, readErr := io.ReadAll(io.LimitReader(tr, hdr.Size+1))
			if readErr != nil || int64(len(raw)) != hdr.Size {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: 读取 backup-manifest.json 失败", ErrInvalid)
			}
			var parsed PluginBackupManifest
			if err := json.Unmarshal(raw, &parsed); err != nil {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: backup-manifest.json 格式无效 (%v)", ErrInvalid, err)
			}
			backupManifest = &parsed
			totalBytes += int64(len(raw))
			continue
		}

		if cleanName == "config/plugin.json" {
			if hdr.Size > maxManifestBytes {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: config/plugin.json 超出大小限制", ErrInvalid)
			}
			raw, readErr := io.ReadAll(io.LimitReader(tr, hdr.Size+1))
			if readErr != nil || int64(len(raw)) != hdr.Size {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: 读取 config/plugin.json 失败", ErrInvalid)
			}
			sum := sha256.Sum256(raw)
			extractedEntries[cleanName] = PluginBackupFileEntry{
				Path:   cleanName,
				Size:   int64(len(raw)),
				SHA256: hex.EncodeToString(sum[:]),
			}
			restoredPluginJSON = raw
			totalBytes += int64(len(raw))
			continue
		}

		if cleanName == "config/env.json" {
			if hdr.Size > maxEnvBytes {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: env.json 超出限制", ErrInvalid)
			}
			raw, readErr := io.ReadAll(io.LimitReader(tr, hdr.Size+1))
			if readErr != nil || int64(len(raw)) != hdr.Size {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: 读取 env.json 失败", ErrInvalid)
			}
			if err := validateEnvBytes(raw); err != nil {
				cleanupStage()
				m.mutation.Unlock()
				return fmt.Errorf("%w: %v", ErrInvalid, err)
			}
			sum := sha256.Sum256(raw)
			extractedEntries[cleanName] = PluginBackupFileEntry{
				Path:   cleanName,
				Size:   int64(len(raw)),
				SHA256: hex.EncodeToString(sum[:]),
			}
			restoredEnv = raw
			totalBytes += int64(len(raw))
			continue
		}

		if !strings.HasPrefix(cleanName, "data/") {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 归档包含未知路径 %q", ErrInvalid, cleanName)
		}
		relData := strings.TrimPrefix(cleanName, "data/")
		if relData == "" || !validRelDir(relData) {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 非法数据文件路径 %q", ErrInvalid, relData)
		}
		dstPath := filepath.Join(stageDir, filepath.FromSlash(relData))
		if err := os.MkdirAll(filepath.Dir(dstPath), 0700); err != nil {
			cleanupStage()
			m.mutation.Unlock()
			return err
		}
		outFile, err := os.OpenFile(dstPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			cleanupStage()
			m.mutation.Unlock()
			return err
		}
		hasher := sha256.New()
		mw := io.MultiWriter(outFile, hasher)
		n, copyErr := io.Copy(mw, io.LimitReader(tr, hdr.Size+1))
		syncErr := outFile.Sync()
		closeErr := outFile.Close()
		if copyErr != nil || syncErr != nil || closeErr != nil || n != hdr.Size {
			cleanupStage()
			m.mutation.Unlock()
			return fmt.Errorf("%w: 写入恢复文件失败 (%s)", ErrInvalid, cleanName)
		}
		extractedEntries[cleanName] = PluginBackupFileEntry{
			Path:   cleanName,
			Size:   n,
			SHA256: hex.EncodeToString(hasher.Sum(nil)),
		}
		extractedDataCount++
		totalBytes += n
	}

	// Verify backup-manifest.json, plugin identity, schema version, non-empty data, and per-file SHA-256
	if err := verifyRestoredArchive(appID, backupManifest, restoredPluginJSON, extractedEntries, extractedDataCount); err != nil {
		cleanupStage()
		m.mutation.Unlock()
		return err
	}

	wasRunning := rec.instance != nil && rec.instance.Snapshot().Status == StatusRunning
	if rec.instance != nil {
		_ = rec.instance.Stop(false)
	}

	envPath := filepath.Join(rec.pluginDir, "env.json")
	oldEnvBytes, hadOldEnvErr := os.ReadFile(envPath)
	hadOldEnv := hadOldEnvErr == nil

	backupOldDir := fmt.Sprintf("%s.old-%d", rec.dataDir, time.Now().UnixNano())
	hasOld := false
	if _, err := os.Lstat(rec.dataDir); err == nil {
		if err := os.Rename(rec.dataDir, backupOldDir); err != nil {
			cleanupStage()
			m.mutation.Unlock()
			if wasRunning {
				_, _ = m.WakeApp(ctx, appID)
			}
			return err
		}
		hasOld = true
	}
	if err := os.Rename(stageDir, rec.dataDir); err != nil {
		if hasOld {
			_ = os.Rename(backupOldDir, rec.dataDir)
		}
		cleanupStage()
		m.mutation.Unlock()
		if wasRunning {
			_, _ = m.WakeApp(ctx, appID)
		}
		return err
	}
	if len(restoredEnv) > 0 {
		if err := os.WriteFile(envPath, restoredEnv, 0600); err != nil {
			_ = os.RemoveAll(rec.dataDir)
			if hasOld {
				_ = os.Rename(backupOldDir, rec.dataDir)
			}
			if hadOldEnv {
				_ = os.WriteFile(envPath, oldEnvBytes, 0600)
			}
			m.mutation.Unlock()
			if wasRunning {
				_, _ = m.WakeApp(ctx, appID)
			}
			return err
		}
	}
	if hasOld {
		_ = os.RemoveAll(backupOldDir)
	}
	m.mutation.Unlock()

	if err := m.Reload(); err != nil {
		return err
	}
	if wasRunning {
		_, _ = m.WakeApp(ctx, appID)
	}
	return nil
}

func verifyRestoredArchive(
	appID string,
	manifest *PluginBackupManifest,
	restoredPluginJSON []byte,
	extracted map[string]PluginBackupFileEntry,
	extractedDataCount int,
) error {
	if manifest == nil {
		return fmt.Errorf("%w: 备份归档缺少 %s 完整性清单，已拒绝覆盖现有数据", ErrInvalid, backupManifestArchivePath)
	}
	if manifest.SchemaVersion != PluginBackupSchemaVersion {
		return fmt.Errorf("%w: 不支持的备份归档格式版本 %d（需为 %d）", ErrInvalid, manifest.SchemaVersion, PluginBackupSchemaVersion)
	}
	if manifest.AppID != appID {
		return fmt.Errorf("%w: 备份归档所属插件 ID %q 与当前目标插件 %q 不匹配", ErrInvalid, manifest.AppID, appID)
	}
	if len(restoredPluginJSON) > 0 {
		var pm struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(bytes.NewReader(restoredPluginJSON)).Decode(&pm); err != nil || pm.ID != appID {
			return fmt.Errorf("%w: 归档内 config/plugin.json 的插件 ID 与当前插件 %q 不一致", ErrInvalid, appID)
		}
	}
	if manifest.DataFileCount <= 0 || extractedDataCount <= 0 {
		return fmt.Errorf("%w: 备份归档不包含有效的业务数据文件，已拒绝替换现有数据目录", ErrInvalid)
	}
	if extractedDataCount != manifest.DataFileCount {
		return fmt.Errorf("%w: 归档业务数据文件数量 (%d) 与清单声明 (%d) 不一致", ErrInvalid, extractedDataCount, manifest.DataFileCount)
	}
	if len(extracted) != len(manifest.Files) {
		return fmt.Errorf("%w: 归档文件总数 (%d) 与清单声明 (%d) 不一致", ErrInvalid, len(extracted), len(manifest.Files))
	}
	for _, expected := range manifest.Files {
		actual, ok := extracted[expected.Path]
		if !ok {
			return fmt.Errorf("%w: 归档缺少清单声明的文件 %q", ErrInvalid, expected.Path)
		}
		if actual.Size != expected.Size || !strings.EqualFold(actual.SHA256, expected.SHA256) {
			return fmt.Errorf("%w: 文件 %q 完整性校验失败（大小或 SHA-256 不匹配）", ErrInvalid, expected.Path)
		}
	}
	return nil
}
