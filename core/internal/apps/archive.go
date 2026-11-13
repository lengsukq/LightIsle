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

type pluginArchiveBuilder struct {
	tw              *tar.Writer
	totalBytes      int64
	totalFiles      int
	dataFileCount   int
	manifestEntries []PluginBackupFileEntry
}

func (b *pluginArchiveBuilder) addFile(archivePath, diskPath string, mode int64, isData bool) error {
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
	b.totalFiles++
	if b.totalFiles > maxPluginArchiveFiles || b.totalBytes+st.Size() > maxPluginArchiveBytes {
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
	if err := b.tw.WriteHeader(hdr); err != nil {
		return err
	}
	n, err := io.Copy(b.tw, io.LimitReader(f, st.Size()+1))
	if err != nil {
		return err
	}
	if n != st.Size() {
		return fmt.Errorf("导出文件 %s 大小在读取过程中发生变化", archivePath)
	}
	b.totalBytes += n
	if isData {
		b.dataFileCount++
	}
	b.manifestEntries = append(b.manifestEntries, PluginBackupFileEntry{
		Path:   archivePath,
		Size:   n,
		SHA256: digest,
	})
	return nil
}

func (b *pluginArchiveBuilder) exportDataDirectory(ctx context.Context, dataDir string) error {
	return filepath.WalkDir(dataDir, func(curPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if curPath == dataDir {
			return nil
		}
		rel, err := filepath.Rel(dataDir, curPath)
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
		if !isSQLite {
			return b.addFile(path.Join("data", slashRel), curPath, 0600, true)
		}
		tmpDir, tmpErr := os.MkdirTemp("", "lightisle-plugin-sqlite-*")
		if tmpErr != nil {
			return fmt.Errorf("创建 SQLite 快照临时目录失败 (%s): %w", slashRel, tmpErr)
		}
		defer os.RemoveAll(tmpDir)
		snapPath := filepath.Join(tmpDir, "snapshot.db")
		if vacuumErr := vacuumSQLiteFile(ctx, curPath, snapPath); vacuumErr != nil {
			return fmt.Errorf("%w: SQLite 数据库 %s 一致性快照失败 (%v)，已中止导出", ErrInvalid, slashRel, vacuumErr)
		}
		return b.addFile(path.Join("data", slashRel), snapPath, 0600, true)
	})
}

func (b *pluginArchiveBuilder) writeManifest(appID string) error {
	manifest := PluginBackupManifest{
		SchemaVersion: PluginBackupSchemaVersion,
		AppID:         appID,
		CreatedAt:     time.Now().UTC().Format(time.RFC3339),
		DataFileCount: b.dataFileCount,
		Files:         b.manifestEntries,
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
	if err := b.tw.WriteHeader(hdr); err != nil {
		return err
	}
	_, err = b.tw.Write(manifestBytes)
	return err
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
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return ErrNotFound
	}
	if err := m.verifyRecordStorageOnline(snap.locationID, snap.pluginDir); err != nil {
		return err
	}
	if err := os.MkdirAll(snap.dataDir, 0700); err != nil {
		return err
	}

	gz := gzip.NewWriter(w)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	builder := &pluginArchiveBuilder{
		tw:              tw,
		manifestEntries: make([]PluginBackupFileEntry, 0, 16),
	}
	for _, cfgName := range []string{"plugin.json", "env.json"} {
		if err := builder.addFile(path.Join("config", cfgName), filepath.Join(snap.pluginDir, cfgName), 0600, false); err != nil {
			return err
		}
	}
	if err := builder.exportDataDirectory(ctx, snap.dataDir); err != nil {
		return err
	}
	if err := builder.writeManifest(appID); err != nil {
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
	wasRunning, swapErr := m.stageAndSwapAppRestore(ctx, appID, r)
	m.mutation.Unlock()

	if swapErr != nil {
		if wasRunning {
			_, _ = m.WakeApp(ctx, appID)
		}
		return swapErr
	}
	if err := m.Reload(); err != nil {
		return err
	}
	if wasRunning {
		_, _ = m.WakeApp(ctx, appID)
	}
	return nil
}

// stageAndSwapAppRestore runs while holding m.mutation. It returns wasRunning=true
// only if the live plugin instance was actually stopped prior to a failed swap so
// the caller can wake it back up after releasing m.mutation.
func (m *Manager) stageAndSwapAppRestore(ctx context.Context, appID string, r io.Reader) (bool, error) {
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return false, ErrNotFound
	}
	if err := m.verifyRecordStorageOnline(snap.locationID, snap.pluginDir); err != nil {
		return false, err
	}

	stageDir := fmt.Sprintf("%s.restore-%d", snap.dataDir, time.Now().UnixNano())
	if err := os.MkdirAll(stageDir, 0700); err != nil {
		return false, err
	}
	stageMoved := false
	defer func() {
		if !stageMoved {
			_ = os.RemoveAll(stageDir)
		}
	}()

	restoredEnv, err := extractAndVerifyBackupArchive(ctx, appID, stageDir, r)
	if err != nil {
		return false, err
	}

	wasRunning := snap.instance != nil && snap.instance.Snapshot().Status == StatusRunning
	if snap.instance != nil {
		_ = snap.instance.Stop(false)
	}

	if err := swapRestoredPluginDirectories(&snap, stageDir, restoredEnv, &stageMoved); err != nil {
		return wasRunning, err
	}
	return wasRunning, nil
}

type stagedArchiveState struct {
	stageDir           string
	totalBytes         int64
	totalFiles         int
	restoredEnv        []byte
	restoredPluginJSON []byte
	backupManifest     *PluginBackupManifest
	extractedEntries   map[string]PluginBackupFileEntry
	extractedDataCount int
}

func extractAndVerifyBackupArchive(
	ctx context.Context,
	appID string,
	stageDir string,
	r io.Reader,
) ([]byte, error) {
	gz, err := gzip.NewReader(io.LimitReader(r, maxPluginArchiveBytes+(1<<20)))
	if err != nil {
		return nil, fmt.Errorf("%w: 无法解压备份归档 (%v)", ErrInvalid, err)
	}
	defer gz.Close()

	state := &stagedArchiveState{
		stageDir:         stageDir,
		extractedEntries: make(map[string]PluginBackupFileEntry),
	}
	tr := tar.NewReader(gz)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%w: 读取归档条目失败 (%v)", ErrInvalid, err)
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			continue
		}
		if err := state.consumeTarEntry(tr, hdr); err != nil {
			return nil, err
		}
	}

	if err := verifyRestoredArchive(
		appID,
		state.backupManifest,
		state.restoredPluginJSON,
		state.extractedEntries,
		state.extractedDataCount,
	); err != nil {
		return nil, err
	}
	return state.restoredEnv, nil
}

func (s *stagedArchiveState) consumeTarEntry(tr *tar.Reader, hdr *tar.Header) error {
	cleanName := path.Clean(strings.TrimPrefix(hdr.Name, "/"))
	if cleanName == "." || strings.HasPrefix(cleanName, "../") || strings.Contains(cleanName, "..") {
		return fmt.Errorf("%w: 非法归档路径 %q", ErrInvalid, hdr.Name)
	}
	if _, dup := s.extractedEntries[cleanName]; dup || (cleanName == backupManifestArchivePath && s.backupManifest != nil) {
		return fmt.Errorf("%w: 归档中存在重复条目 %q", ErrInvalid, cleanName)
	}
	s.totalFiles++
	if s.totalFiles > maxPluginArchiveFiles || hdr.Size < 0 || s.totalBytes+hdr.Size > maxPluginArchiveBytes {
		return fmt.Errorf("%w: 备份归档超出 512 MiB 安全大小限制", ErrInvalid)
	}

	switch cleanName {
	case backupManifestArchivePath:
		return s.consumeManifestEntry(tr, hdr.Size)
	case "config/plugin.json":
		raw, err := readExactTarBytes(tr, hdr.Size, maxManifestBytes, "config/plugin.json")
		if err != nil {
			return err
		}
		s.recordMemoryEntry(cleanName, raw)
		s.restoredPluginJSON = raw
		return nil
	case "config/env.json":
		raw, err := readExactTarBytes(tr, hdr.Size, maxEnvBytes, "env.json")
		if err != nil {
			return err
		}
		if err := validateEnvBytes(raw); err != nil {
			return fmt.Errorf("%w: %v", ErrInvalid, err)
		}
		s.recordMemoryEntry(cleanName, raw)
		s.restoredEnv = raw
		return nil
	default:
		return s.consumeDataEntry(tr, cleanName, hdr.Size)
	}
}

func readExactTarBytes(tr *tar.Reader, size int64, limit int64, label string) ([]byte, error) {
	if size > limit {
		return nil, fmt.Errorf("%w: %s 超出限制", ErrInvalid, label)
	}
	raw, err := io.ReadAll(io.LimitReader(tr, size+1))
	if err != nil || int64(len(raw)) != size {
		return nil, fmt.Errorf("%w: 读取 %s 失败", ErrInvalid, label)
	}
	return raw, nil
}

func (s *stagedArchiveState) recordMemoryEntry(cleanName string, raw []byte) {
	sum := sha256.Sum256(raw)
	s.extractedEntries[cleanName] = PluginBackupFileEntry{
		Path:   cleanName,
		Size:   int64(len(raw)),
		SHA256: hex.EncodeToString(sum[:]),
	}
	s.totalBytes += int64(len(raw))
}

func (s *stagedArchiveState) consumeManifestEntry(tr *tar.Reader, size int64) error {
	raw, err := readExactTarBytes(tr, size, 4<<20, "backup-manifest.json")
	if err != nil {
		return err
	}
	var parsed PluginBackupManifest
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return fmt.Errorf("%w: backup-manifest.json 格式无效 (%v)", ErrInvalid, err)
	}
	s.backupManifest = &parsed
	s.totalBytes += int64(len(raw))
	return nil
}

func (s *stagedArchiveState) consumeDataEntry(tr *tar.Reader, cleanName string, size int64) error {
	if !strings.HasPrefix(cleanName, "data/") {
		return fmt.Errorf("%w: 归档包含未知路径 %q", ErrInvalid, cleanName)
	}
	relData := strings.TrimPrefix(cleanName, "data/")
	if relData == "" || !validRelDir(relData) {
		return fmt.Errorf("%w: 非法数据文件路径 %q", ErrInvalid, relData)
	}
	dstPath := filepath.Join(s.stageDir, filepath.FromSlash(relData))
	if err := os.MkdirAll(filepath.Dir(dstPath), 0700); err != nil {
		return err
	}
	outFile, err := os.OpenFile(dstPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	hasher := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(outFile, hasher), io.LimitReader(tr, size+1))
	syncErr := outFile.Sync()
	closeErr := outFile.Close()
	if copyErr != nil || syncErr != nil || closeErr != nil || n != size {
		return fmt.Errorf("%w: 写入恢复文件失败 (%s)", ErrInvalid, cleanName)
	}
	s.extractedEntries[cleanName] = PluginBackupFileEntry{
		Path:   cleanName,
		Size:   n,
		SHA256: hex.EncodeToString(hasher.Sum(nil)),
	}
	s.extractedDataCount++
	s.totalBytes += n
	return nil
}

func swapRestoredPluginDirectories(
	rec *appRecord,
	stageDir string,
	restoredEnv []byte,
	stageMoved *bool,
) error {
	envPath := filepath.Join(rec.pluginDir, "env.json")
	oldEnvBytes, hadOldEnvErr := os.ReadFile(envPath)
	hadOldEnv := hadOldEnvErr == nil

	backupOldDir := fmt.Sprintf("%s.old-%d", rec.dataDir, time.Now().UnixNano())
	hasOld := false
	if _, err := os.Lstat(rec.dataDir); err == nil {
		if err := os.Rename(rec.dataDir, backupOldDir); err != nil {
			return err
		}
		hasOld = true
	}
	if err := os.Rename(stageDir, rec.dataDir); err != nil {
		if hasOld {
			_ = os.Rename(backupOldDir, rec.dataDir)
		}
		return err
	}
	*stageMoved = true

	if len(restoredEnv) > 0 {
		if err := os.WriteFile(envPath, restoredEnv, 0600); err != nil {
			_ = os.RemoveAll(rec.dataDir)
			if hasOld {
				_ = os.Rename(backupOldDir, rec.dataDir)
			}
			if hadOldEnv {
				_ = os.WriteFile(envPath, oldEnvBytes, 0600)
			}
			return err
		}
	}
	if hasOld {
		_ = os.RemoveAll(backupOldDir)
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
