package apps

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const (
	maxPackageArchiveBytes = 64 << 20 // 64 MiB uncompressed cap for shareable .liapp.zip
	maxPackageArchiveFiles = 2000
	PackageSchemaVersion   = 1
	packageManifestPath    = "package-manifest.json"
)

// PluginPackageManifest describes the files and SHA-256 digests embedded in a
// shareable .liapp.zip plugin code bundle.
type PluginPackageManifest struct {
	SchemaVersion int                     `json:"schemaVersion"`
	AppID         string                  `json:"appId"`
	Name          string                  `json:"name"`
	Version       string                  `json:"version"`
	ExportedAt    string                  `json:"exportedAt"`
	FileCount     int                     `json:"fileCount"`
	Files         []PluginBackupFileEntry `json:"files"`
}

func shouldSkipPackageRelPath(slashRel string, isDir bool) bool {
	if slashRel == "" || slashRel == "." {
		return true
	}
	parts := strings.Split(slashRel, "/")
	for _, part := range parts {
		if part == "" || strings.HasPrefix(part, ".") {
			return true
		}
		switch part {
		case "node_modules", "__pycache__", ".venv", "venv":
			return true
		}
	}
	if !isDir {
		lower := strings.ToLower(slashRel)
		if lower == "env.json" || strings.HasSuffix(lower, "/env.json") || lower == packageManifestPath {
			return true
		}
	}
	return false
}

// ExportAppPackage streams a shareable .liapp.zip bundle containing the plugin's
// code and sanitized plugin.json (stripping env.json and allowedUserIds so no
// host secrets or personal member IDs are leaked).
func (m *Manager) ExportAppPackage(ctx context.Context, appID string, w io.Writer) error {
	if !ValidPluginID(appID) {
		return ErrInvalid
	}
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return ErrNotFound
	}
	if !snap.valid {
		return fmt.Errorf("%w: 当前插件配置无效，无法导出分享包", ErrInvalid)
	}
	if err := m.verifyRecordStorageOnline(snap.locationID, snap.pluginDir); err != nil {
		return err
	}

	zw := zip.NewWriter(w)
	defer zw.Close()

	var (
		totalBytes int64
		totalFiles int
		entries    = make([]PluginBackupFileEntry, 0, 16)
	)

	addBytes := func(archivePath string, raw []byte, mode fs.FileMode, modTime time.Time) error {
		totalFiles++
		if totalFiles > maxPackageArchiveFiles || totalBytes+int64(len(raw)) > maxPackageArchiveBytes {
			return fmt.Errorf("%w: 插件包体积超过 64 MiB 或文件数超过 %d 上限", ErrInvalid, maxPackageArchiveFiles)
		}
		hdr := &zip.FileHeader{
			Name:     archivePath,
			Method:   zip.Deflate,
			Modified: modTime,
		}
		hdr.SetMode(mode & 0755)
		fw, err := zw.CreateHeader(hdr)
		if err != nil {
			return err
		}
		if _, err := fw.Write(raw); err != nil {
			return err
		}
		sum := sha256.Sum256(raw)
		totalBytes += int64(len(raw))
		entries = append(entries, PluginBackupFileEntry{
			Path:   archivePath,
			Size:   int64(len(raw)),
			SHA256: hex.EncodeToString(sum[:]),
		})
		return nil
	}

	walkErr := filepath.WalkDir(snap.pluginDir, func(curPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if curPath == snap.pluginDir {
			return nil
		}
		rel, err := filepath.Rel(snap.pluginDir, curPath)
		if err != nil {
			return err
		}
		slashRel := filepath.ToSlash(rel)
		if shouldSkipPackageRelPath(slashRel, d.IsDir()) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 || d.IsDir() {
			return nil
		}
		info, err := os.Lstat(curPath)
		if err != nil || !info.Mode().IsRegular() {
			return err
		}
		if slashRel == "plugin.json" {
			sanitized, err := sanitizePluginManifestForExport(curPath)
			if err != nil {
				return err
			}
			return addBytes(slashRel, sanitized, 0600, info.ModTime())
		}
		if info.Size() > maxPackageArchiveBytes || totalBytes+info.Size() > maxPackageArchiveBytes {
			return fmt.Errorf("%w: 插件包体积超过 64 MiB 导出上限", ErrInvalid)
		}
		raw, err := os.ReadFile(curPath)
		if err != nil {
			return err
		}
		perm := fs.FileMode(0600)
		if info.Mode()&0100 != 0 {
			perm = 0700
		}
		return addBytes(slashRel, raw, perm, info.ModTime())
	})
	if walkErr != nil {
		return walkErr
	}
	if totalFiles == 0 {
		return fmt.Errorf("%w: 插件目录为空，无法导出", ErrInvalid)
	}

	pkgManifest := PluginPackageManifest{
		SchemaVersion: PackageSchemaVersion,
		AppID:         snap.id,
		Name:          snap.manifest.Name,
		Version:       snap.manifest.Version,
		ExportedAt:    time.Now().UTC().Format(time.RFC3339),
		FileCount:     len(entries),
		Files:         entries,
	}
	pkgBytes, err := json.MarshalIndent(pkgManifest, "", "  ")
	if err != nil {
		return err
	}
	hdr := &zip.FileHeader{
		Name:     packageManifestPath,
		Method:   zip.Deflate,
		Modified: time.Now(),
	}
	hdr.SetMode(0600)
	fw, err := zw.CreateHeader(hdr)
	if err != nil {
		return err
	}
	if _, err := fw.Write(pkgBytes); err != nil {
		return err
	}
	return zw.Close()
}

func sanitizePluginManifestForExport(manifestPath string) ([]byte, error) {
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, err
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	if access, ok := doc["access"].(map[string]any); ok {
		access["allowedUserIds"] = []int64{}
		if policy, _ := access["policy"].(string); policy == AccessSelectedMembers {
			access["policy"] = AccessAdminOnly
		}
	}
	return json.MarshalIndent(doc, "", "  ")
}

// ImportAppPackage validates and installs an uploaded .liapp.zip bundle into the
// requested storage slot ("internal", "external", or "" for default). Imported
// apps ALWAYS enter pendingActivation=true until the administrator explicitly
// reviews and activates them.
func (m *Manager) ImportAppPackage(ctx context.Context, r io.Reader, locationID string) (PublicApp, error) {
	tmpFile, err := os.CreateTemp("", "lightisle-liapp-import-*.zip")
	if err != nil {
		return PublicApp{}, err
	}
	tmpPath := tmpFile.Name()
	defer func() {
		_ = tmpFile.Close()
		_ = os.Remove(tmpPath)
	}()

	written, err := io.Copy(tmpFile, io.LimitReader(r, maxPackageArchiveBytes+1))
	if err != nil {
		return PublicApp{}, fmt.Errorf("%w: 读取上传插件包失败 (%v)", ErrInvalid, err)
	}
	if written <= 0 {
		return PublicApp{}, fmt.Errorf("%w: 上传的插件包为空", ErrInvalid)
	}
	if written > maxPackageArchiveBytes {
		return PublicApp{}, fmt.Errorf("%w: 插件包超过 64 MiB 安全大小限制", ErrInvalid)
	}

	zr, err := zip.NewReader(tmpFile, written)
	if err != nil {
		return PublicApp{}, fmt.Errorf("%w: 无法解析 .liapp.zip 归档 (%v)", ErrInvalid, err)
	}

	target, err := m.ResolveInstallTarget(locationID)
	if err != nil {
		return PublicApp{}, err
	}
	if err := os.MkdirAll(target.pluginsDir, 0700); err != nil {
		return PublicApp{}, err
	}

	stageDir, err := os.MkdirTemp(target.pluginsDir, ".import-stage-*")
	if err != nil {
		return PublicApp{}, err
	}
	stageMoved := false
	defer func() {
		if !stageMoved {
			_ = os.RemoveAll(stageDir)
		}
	}()

	manifest, err := extractAndVerifyPackageZip(ctx, zr, stageDir)
	if err != nil {
		return PublicApp{}, err
	}
	if m.appIDExistsAnywhere(manifest.ID) {
		return PublicApp{}, ErrAlreadyInstalled
	}
	destDir := filepath.Join(target.pluginsDir, manifest.ID)
	if _, err := os.Lstat(destDir); err == nil {
		return PublicApp{}, ErrAlreadyInstalled
	}
	if err := os.Rename(stageDir, destDir); err != nil {
		return PublicApp{}, err
	}
	stageMoved = true
	_ = os.MkdirAll(filepath.Join(target.dataRoot, manifest.ID), 0700)

	// Enforce pendingActivation=true for every imported package, even if its ID
	// previously existed or matches a template name.
	m.mutation.Lock()
	cfg, cfgErr := readSystemConfigFile(m.configPath)
	if cfgErr == nil {
		cfg.ActivatedApps = removeString(cfg.ActivatedApps, manifest.ID)
		if !slices.Contains(cfg.PendingApps, manifest.ID) {
			cfg.PendingApps = uniqueSortedStrings(append(cfg.PendingApps, manifest.ID))
		}
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		_ = writeSystemConfigFile(m.configPath, cfg)
	}
	m.mutation.Unlock()

	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	return m.GetForUser(manifest.ID, 0, "admin")
}

func extractAndVerifyPackageZip(ctx context.Context, zr *zip.Reader, stageDir string) (PluginManifest, error) {
	var (
		totalBytes   int64
		totalFiles   int
		pkgManifest  *PluginPackageManifest
		extracted    = make(map[string]PluginBackupFileEntry, len(zr.File))
		seenNames    = make(map[string]bool, len(zr.File))
		pluginRaw    []byte
	)

	for _, f := range zr.File {
		if err := ctx.Err(); err != nil {
			return PluginManifest{}, err
		}
		if f.FileInfo().IsDir() {
			continue
		}
		if f.Mode()&os.ModeSymlink != 0 {
			return PluginManifest{}, fmt.Errorf("%w: 插件包禁止包含符号链接 %q", ErrInvalid, f.Name)
		}
		rawName := strings.ReplaceAll(f.Name, "\\", "/")
		cleanName := path.Clean(strings.TrimPrefix(rawName, "/"))
		if cleanName == "." || cleanName == "" || strings.HasPrefix(cleanName, "../") || strings.Contains(cleanName, "..") {
			return PluginManifest{}, fmt.Errorf("%w: 非法插件包路径 %q", ErrInvalid, f.Name)
		}
		if seenNames[cleanName] {
			return PluginManifest{}, fmt.Errorf("%w: 插件包包含重复条目 %q", ErrInvalid, cleanName)
		}
		seenNames[cleanName] = true

		// Ignore macOS AppleDouble / hidden junk if packed manually.
		if cleanName != packageManifestPath && shouldSkipPackageRelPath(cleanName, false) {
			continue
		}

		totalFiles++
		if totalFiles > maxPackageArchiveFiles {
			return PluginManifest{}, fmt.Errorf("%w: 插件包文件数量超过 %d 上限", ErrInvalid, maxPackageArchiveFiles)
		}
		if f.UncompressedSize64 > uint64(maxPackageArchiveBytes) || totalBytes+int64(f.UncompressedSize64) > maxPackageArchiveBytes {
			return PluginManifest{}, fmt.Errorf("%w: 插件包解压后超过 64 MiB 安全限制", ErrInvalid)
		}

		rc, err := f.Open()
		if err != nil {
			return PluginManifest{}, fmt.Errorf("%w: 无法读取插件包条目 %q (%v)", ErrInvalid, cleanName, err)
		}
		limit := maxPackageArchiveBytes - totalBytes
		if cleanName == packageManifestPath {
			raw, readErr := io.ReadAll(io.LimitReader(rc, minInt64(limit, 4<<20)+1))
			_ = rc.Close()
			if readErr != nil || int64(len(raw)) > 4<<20 {
				return PluginManifest{}, fmt.Errorf("%w: package-manifest.json 超出限制", ErrInvalid)
			}
			var parsed PluginPackageManifest
			if err := json.Unmarshal(raw, &parsed); err != nil {
				return PluginManifest{}, fmt.Errorf("%w: package-manifest.json 格式无效 (%v)", ErrInvalid, err)
			}
			pkgManifest = &parsed
			totalBytes += int64(len(raw))
			continue
		}

		dstPath := filepath.Join(stageDir, filepath.FromSlash(cleanName))
		if err := os.MkdirAll(filepath.Dir(dstPath), 0700); err != nil {
			_ = rc.Close()
			return PluginManifest{}, err
		}
		perm := fs.FileMode(0600)
		if f.Mode()&0111 != 0 {
			perm = 0700
		}
		outFile, err := os.OpenFile(dstPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, perm)
		if err != nil {
			_ = rc.Close()
			return PluginManifest{}, err
		}
		hasher := sha256.New()
		n, copyErr := io.Copy(io.MultiWriter(outFile, hasher), io.LimitReader(rc, limit+1))
		_ = rc.Close()
		closeErr := outFile.Close()
		if copyErr != nil || closeErr != nil {
			return PluginManifest{}, fmt.Errorf("%w: 写入插件文件失败 (%s)", ErrInvalid, cleanName)
		}
		if totalBytes+n > maxPackageArchiveBytes {
			return PluginManifest{}, fmt.Errorf("%w: 插件包解压后超过 64 MiB 安全限制", ErrInvalid)
		}
		totalBytes += n
		extracted[cleanName] = PluginBackupFileEntry{
			Path:   cleanName,
			Size:   n,
			SHA256: hex.EncodeToString(hasher.Sum(nil)),
		}
		if cleanName == "plugin.json" {
			if n > maxManifestBytes {
				return PluginManifest{}, fmt.Errorf("%w: plugin.json 超出大小限制", ErrInvalid)
			}
			pluginRaw, _ = os.ReadFile(dstPath)
		}
	}

	if len(pluginRaw) == 0 {
		return PluginManifest{}, fmt.Errorf("%w: 插件包缺少 plugin.json 清单文件", ErrInvalid)
	}
	var idProbe struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(pluginRaw, &idProbe); err != nil || !ValidPluginID(idProbe.ID) {
		return PluginManifest{}, fmt.Errorf("%w: plugin.json 缺少合法的插件 ID", ErrInvalid)
	}
	root, err := os.OpenRoot(stageDir)
	if err != nil {
		return PluginManifest{}, err
	}
	defer root.Close()
	manifest, err := ValidateManifest(root, idProbe.ID, pluginRaw)
	if err != nil {
		return PluginManifest{}, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	if pkgManifest != nil {
		if pkgManifest.SchemaVersion != PackageSchemaVersion {
			return PluginManifest{}, fmt.Errorf("%w: 不支持的插件包清单版本 %d", ErrInvalid, pkgManifest.SchemaVersion)
		}
		if pkgManifest.AppID != manifest.ID {
			return PluginManifest{}, fmt.Errorf("%w: 插件包清单 ID (%q) 与 plugin.json (%q) 不一致", ErrInvalid, pkgManifest.AppID, manifest.ID)
		}
		for _, expected := range pkgManifest.Files {
			actual, ok := extracted[expected.Path]
			if !ok {
				return PluginManifest{}, fmt.Errorf("%w: 插件包缺少声明文件 %q", ErrInvalid, expected.Path)
			}
			if actual.Size != expected.Size || !strings.EqualFold(actual.SHA256, expected.SHA256) {
				return PluginManifest{}, fmt.Errorf("%w: 插件包文件 %q 校验失败（可能已损坏或被篡改）", ErrInvalid, expected.Path)
			}
		}
	}
	return manifest, nil
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func removeString(list []string, target string) []string {
	out := make([]string, 0, len(list))
	for _, s := range list {
		if s != target {
			out = append(out, s)
		}
	}
	return out
}
