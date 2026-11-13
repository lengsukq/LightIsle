package apps

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"github.com/robfig/cron/v3"
)

var (
	ErrInvalid           = errors.New("app_invalid")
	ErrNotFound          = errors.New("app_not_found")
	ErrForbidden         = errors.New("app_forbidden")
	ErrDisabled          = errors.New("app_disabled")
	ErrBusy              = errors.New("app_busy")
	ErrRunning           = errors.New("app_running")
	ErrChanged           = errors.New("app_changed")
	ErrUnavailable       = errors.New("app_unavailable")
	ErrPendingActivation = errors.New("app_pending_activation")
	ErrMCPDisabled       = errors.New("mcp_disabled")
	ErrStorageSlotLimit  = errors.New("app_storage_slot_limit")
	ErrStorageOffline    = errors.New("app_storage_offline")

	PluginIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,40}$`)
	envKeyPattern   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)
	cronParser      = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
)

const (
	MCPDisabledMessage = "LightIsle 开发者 MCP 当前处于关闭状态。请先在 LightIsle 管理端（macOS 客户端设置页、Web 应用中心或 Flutter 应用中心）打开「允许 AI Agent (MCP) 接入」开关后再试。"

	AccessAdminOnly       = "admin_only"
	AccessSelectedMembers = "selected_members"
	AccessAllMembers      = "all_members"

	WebModeStatic     = "static"
	WebModeOnDemand   = "on-demand"
	WebModePersistent = "persistent"

	StatusStatic   = "static"
	StatusSleeping = "sleeping"
	StatusStarting = "starting"
	StatusRunning  = "running"
	StatusStopped  = "stopped"
	StatusCrashed  = "crashed"
	StatusDisabled = "disabled"

	maxManifestBytes = 64 << 10
	maxEnvBytes      = 32 << 10
	maxScriptBytes   = 4 << 20
	maxEmailBytes    = 64 << 10
)

const (
	AppStorageIDInternal   = "internal"
	AppStorageIDExternal   = "external"
	AppStorageKindInternal = "internal"
	AppStorageKindExternal = "external"
)

type StoredAppLocation struct {
	ID        string                   `json:"id"`
	Kind      string                   `json:"kind"`
	Name      string                   `json:"name"`
	Path      string                   `json:"path"`
	Binding   *storageidentity.Binding `json:"binding,omitempty"`
	UpdatedAt string                   `json:"updatedAt,omitempty"`
}

type AppsStorageSettings struct {
	DefaultLocationID string             `json:"defaultLocationId,omitempty"`
	Internal          *StoredAppLocation `json:"internal,omitempty"`
	External          *StoredAppLocation `json:"external,omitempty"`
}

type AppStorageLocation struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"`
	Name          string `json:"name"`
	Path          string `json:"path"`
	PluginsDir    string `json:"pluginsDir"`
	PluginDataDir string `json:"pluginDataDir"`
	IsDefault     bool   `json:"isDefault"`
	IsCustomPath  bool   `json:"isCustomPath"`
	Online        bool   `json:"online"`
	Writable      bool   `json:"writable"`
	Error         string `json:"error,omitempty"`
	VolumeName    string `json:"volumeName,omitempty"`
	VolumeMount   string `json:"volumeMount,omitempty"`
	VolumeUUID    string `json:"volumeUuid,omitempty"`
	FreeBytes     uint64 `json:"freeBytes,omitempty"`
	TotalBytes    uint64 `json:"totalBytes,omitempty"`
	AppCount      int    `json:"appCount"`
}

type AppStorageVolumeOption struct {
	Name       string `json:"name"`
	Mount      string `json:"mount"`
	Suggested  string `json:"suggestedPath"`
	Filesystem string `json:"filesystem,omitempty"`
	TotalBytes uint64 `json:"totalBytes"`
	FreeBytes  uint64 `json:"freeBytes"`
	ReadOnly   bool   `json:"readOnly"`
	VolumeUUID string `json:"volumeUuid,omitempty"`
}

type AppStorageSnapshot struct {
	DefaultLocationID string                   `json:"defaultLocationId"`
	MaxInternal       int                      `json:"maxInternal"`
	MaxExternal       int                      `json:"maxExternal"`
	MaxLocations      int                      `json:"maxLocations"`
	HasExternal       bool                     `json:"hasExternal"`
	Locations         []AppStorageLocation     `json:"locations"`
	AvailableVolumes  []AppStorageVolumeOption `json:"availableVolumes"`
}

type AppStorageMutationRequest struct {
	Action            string `json:"action"` // add, set, set_default, reset_internal, remove_external
	Kind              string `json:"kind,omitempty"`
	Path              string `json:"path,omitempty"`
	Name              string `json:"name,omitempty"`
	DefaultLocationID string `json:"defaultLocationId,omitempty"`
	SetDefault        bool   `json:"setDefault,omitempty"`
}

type AppsSystemConfig struct {
	MCPEnabled    bool                 `json:"mcpEnabled"`
	MCPLanEnabled bool                 `json:"mcpLanEnabled"`
	UpdatedAt     string               `json:"updatedAt"`
	PendingApps   []string             `json:"pendingApps,omitempty"`
	ActivatedApps []string             `json:"activatedApps,omitempty"`
	Storage       *AppsStorageSettings `json:"storage,omitempty"`
}

type PluginManifest struct {
	SchemaVersion int          `json:"schemaVersion"`
	ID            string       `json:"id"`
	Name          string       `json:"name"`
	Version       string       `json:"version"`
	Author        string       `json:"author,omitempty"`
	Description   string       `json:"description,omitempty"`
	Category      string       `json:"category,omitempty"`
	Icon          string       `json:"icon,omitempty"`
	Access        AccessConfig `json:"access"`
	Cron          *CronConfig  `json:"cron,omitempty"`
	Web           *WebConfig   `json:"web,omitempty"`
}

type AccessConfig struct {
	Policy         string  `json:"policy"`
	AllowedUserIDs []int64 `json:"allowedUserIDs"`
}

func normalizeAccessPolicy(p string) string {
	switch strings.TrimSpace(p) {
	case "", AccessAdminOnly:
		return AccessAdminOnly
	case AccessSelectedMembers, "allowlist":
		return AccessSelectedMembers
	case AccessAllMembers, "authenticated":
		return AccessAllMembers
	default:
		return p
	}
}

func (a *AccessConfig) UnmarshalJSON(data []byte) error {
	var raw struct {
		Policy          string  `json:"policy"`
		AllowedUserIDs  []int64 `json:"allowedUserIDs"`
		AllowedUserIds2 []int64 `json:"allowedUserIds"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	a.Policy = normalizeAccessPolicy(raw.Policy)
	if raw.AllowedUserIDs != nil {
		a.AllowedUserIDs = raw.AllowedUserIDs
	} else if raw.AllowedUserIds2 != nil {
		a.AllowedUserIDs = raw.AllowedUserIds2
	} else {
		a.AllowedUserIDs = []int64{}
	}
	return nil
}

type CronConfig struct {
	Enabled        bool                    `json:"enabled"`
	Entry          string                  `json:"entry"`
	Schedule       automation.Schedule     `json:"schedule"`
	TimeoutSeconds int                     `json:"timeoutSeconds,omitempty"`
	Notification   automation.Notification `json:"notification,omitempty"`
}

type WebConfig struct {
	Enabled             bool   `json:"enabled"`
	Mode                string `json:"mode"`
	Runtime             string `json:"runtime,omitempty"`
	Entry               string `json:"entry,omitempty"`
	StaticDir           string `json:"staticDir,omitempty"`
	Port                int    `json:"port,omitempty"`
	BasePath            string `json:"basePath,omitempty"`
	IdleTimeoutSeconds  int    `json:"idleTimeoutSeconds,omitempty"`
	ReadyTimeoutSeconds int    `json:"readyTimeoutSeconds,omitempty"`
	HealthCheckPath     string `json:"healthCheckPath,omitempty"`
	AutoRestart         bool   `json:"autoRestart,omitempty"`
	RestartLimit        int    `json:"restartLimit,omitempty"`
}

type PublicApp struct {
	ID                string         `json:"id"`
	Name              string         `json:"name"`
	Version           string         `json:"version"`
	Author            string         `json:"author,omitempty"`
	Description       string         `json:"description,omitempty"`
	Category          string         `json:"category,omitempty"`
	HasIcon           bool           `json:"hasIcon"`
	IconURL           string         `json:"iconUrl,omitempty"`
	LaunchPath        string         `json:"launchPath"`
	Revision          string         `json:"revision"`
	Valid             bool           `json:"valid"`
	ValidationError   string         `json:"validationError,omitempty"`
	LastError         string         `json:"lastError,omitempty"`
	Diagnostic        *AppDiagnostic `json:"diagnostic,omitempty"`
	PendingActivation bool           `json:"pendingActivation,omitempty"`
	LocationID        string         `json:"locationId"`
	LocationKind      string         `json:"locationKind"`
	LocationName      string         `json:"locationName"`
	PluginsDir        string         `json:"pluginsDir"`
	PluginDataDir     string         `json:"pluginDataDir"`
	Access            AccessConfig   `json:"access"`
	Web               PublicWebView  `json:"web"`
	Cron              PublicCronView `json:"cron"`
}

type PublicWebView struct {
	Enabled             bool   `json:"enabled"`
	Mode                string `json:"mode"`
	Runtime             string `json:"runtime,omitempty"`
	Port                int    `json:"port,omitempty"`
	BasePath            string `json:"basePath,omitempty"`
	IdleTimeoutSeconds  int    `json:"idleTimeoutSeconds,omitempty"`
	ReadyTimeoutSeconds int    `json:"readyTimeoutSeconds,omitempty"`
	AutoRestart         bool   `json:"autoRestart"`
	RestartLimit        int    `json:"restartLimit,omitempty"`
	Status              string `json:"status"`
	PID                 int    `json:"pid,omitempty"`
	RSSBytes            int64  `json:"rssBytes"`
	ActiveStreams       int64  `json:"activeStreams"`
	LastActiveAt        int64  `json:"lastActiveAt,omitempty"`
	LastError           string `json:"lastError,omitempty"`
}

type PublicCronView struct {
	HasCron        bool                   `json:"hasCron"`
	TaskID         string                 `json:"taskId,omitempty"`
	Enabled        bool                   `json:"enabled"`
	Cron           string                 `json:"cron,omitempty"`
	Timezone       string                 `json:"timezone,omitempty"`
	TimeoutSeconds int                    `json:"timeoutSeconds,omitempty"`
	Events         []string               `json:"events"`
	Channels       []string               `json:"channels"`
	Running        bool                   `json:"running"`
	NextRunAt      int64                  `json:"nextRunAt,omitempty"`
	LastRun        *automation.RunSummary `json:"lastRun,omitempty"`
}

type UserIdentity struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	Role         string `json:"role"`
	SessionToken string `json:"-"`
}

type AppUpdateRequest struct {
	Access          *AccessConfig    `json:"access,omitempty"`
	Web             *WebUpdateInput  `json:"web,omitempty"`
	Cron            *CronUpdateInput `json:"cron,omitempty"`
	Revision        string           `json:"revision,omitempty"`
	RequireApproved bool             `json:"-"`
}

type WebUpdateInput struct {
	Enabled            *bool   `json:"enabled,omitempty"`
	Mode               *string `json:"mode,omitempty"`
	IdleTimeoutSeconds *int    `json:"idleTimeoutSeconds,omitempty"`
	AutoRestart        *bool   `json:"autoRestart,omitempty"`
}

type CronUpdateInput struct {
	Enabled        *bool                    `json:"enabled,omitempty"`
	Cron           *string                  `json:"cron,omitempty"`
	Timezone       *string                  `json:"timezone,omitempty"`
	Schedule       *automation.Schedule     `json:"schedule,omitempty"`
	TimeoutSeconds *int                     `json:"timeoutSeconds,omitempty"`
	Events         []string                 `json:"events,omitempty"`
	Channels       []string                 `json:"channels,omitempty"`
	Notification   *automation.Notification `json:"notification,omitempty"`
}

func ValidPluginID(id string) bool {
	return PluginIDPattern.MatchString(id)
}

func validChildName(v string) bool {
	return v != "" && v != "." && v != ".." && filepath.Base(v) == v && !strings.ContainsAny(v, "/\\")
}

func validRelDir(v string) bool {
	if v == "" || strings.HasPrefix(v, "/") || strings.Contains(v, "\\") {
		return false
	}
	cleaned := filepath.Clean(v)
	return cleaned != "." && cleaned != ".." && !strings.HasPrefix(cleaned, "../") && cleaned == v
}

func manifestRevision(raw []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(raw))
}

func readCheckedFile(root *os.Root, rel string, limit int64) ([]byte, os.FileInfo, error) {
	if !validChildName(rel) {
		return nil, nil, ErrInvalid
	}
	st, err := root.Lstat(rel)
	if err != nil {
		return nil, nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > limit {
		return nil, nil, ErrInvalid
	}
	f, err := root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(st, opened) {
		return nil, nil, ErrInvalid
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, nil, ErrInvalid
	}
	return data, opened, nil
}

func ReadEnvFile(root *os.Root, name string) (map[string]string, error) {
	raw, _, err := readCheckedFile(root, name, maxEnvBytes)
	if err != nil {
		return nil, err
	}
	var values map[string]string
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("env.json JSON 格式错误: %w", err)
	}
	for k, v := range values {
		if !envKeyPattern.MatchString(k) || len(v) > 4096 || strings.ContainsRune(v, 0) {
			return nil, fmt.Errorf("env.json 包含非法键名或值: %s", k)
		}
	}
	return values, nil
}

// ValidateManifest validates plugin.json against Schema v2 and verifies local files in root.
func ValidateManifest(root *os.Root, dirName string, raw []byte) (PluginManifest, error) {
	var m PluginManifest
	if len(raw) == 0 || len(raw) > maxManifestBytes {
		return m, errors.New("plugin.json 为空或超出大小限制（最大 64KB）")
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, fmt.Errorf("plugin.json 格式错误: %w", err)
	}
	if m.SchemaVersion == 0 {
		m.SchemaVersion = 2
	}
	if m.SchemaVersion != 2 {
		return m, fmt.Errorf("不支持的 schemaVersion: %d（需为 2）", m.SchemaVersion)
	}
	if !ValidPluginID(m.ID) || m.ID != dirName {
		return m, fmt.Errorf("插件 ID %q 不合法或与目录名 %q 不一致（需匹配 ^[a-z][a-z0-9-]{0,40}$）", m.ID, dirName)
	}
	m.Name = strings.TrimSpace(m.Name)
	if m.Name == "" || len(m.Name) > 120 {
		return m, errors.New("插件名称不能为空且长度不能超过 120 字符")
	}
	if m.Version == "" {
		m.Version = "0.1.0"
	}
	if m.Category == "" {
		m.Category = "utility"
	}
	m.Access.Policy = normalizeAccessPolicy(m.Access.Policy)
	switch m.Access.Policy {
	case AccessAdminOnly, AccessSelectedMembers, AccessAllMembers:
	default:
		return m, fmt.Errorf("不支持的访问策略: %s", m.Access.Policy)
	}
	if m.Access.AllowedUserIDs == nil {
		m.Access.AllowedUserIDs = []int64{}
	}
	if m.Icon != "" {
		if !validChildName(m.Icon) {
			return m, errors.New("icon 必须为当前目录下的合法文件名")
		}
		if st, err := root.Lstat(m.Icon); err != nil || !st.Mode().IsRegular() {
			return m, fmt.Errorf("找不到有效的图标文件: %s", m.Icon)
		}
	}
	if m.Web == nil && m.Cron == nil {
		return m, errors.New("plugin.json 必须至少包含 web 或 cron 配置之一")
	}
	if m.Web != nil {
		if err := validateWebConfig(root, m.ID, m.Web); err != nil {
			return m, err
		}
	}
	if m.Cron != nil {
		if err := validateCronConfig(root, m.Cron); err != nil {
			return m, err
		}
	}
	if root != nil {
		if st, err := root.Lstat("env.json"); err == nil {
			if !st.Mode().IsRegular() {
				return m, errors.New("env.json 必须是普通文件，不能是符号链接")
			}
			if _, err := ReadEnvFile(root, "env.json"); err != nil {
				return m, err
			}
		}
	}
	return m, nil
}

func validateWebConfig(root *os.Root, id string, w *WebConfig) error {
	switch w.Mode {
	case WebModeStatic, WebModeOnDemand, WebModePersistent:
	default:
		return fmt.Errorf("不支持的 web.mode: %q（需为 static、on-demand 或 persistent）", w.Mode)
	}
	expectedBase := "/apps/" + id
	if w.BasePath == "" {
		w.BasePath = expectedBase
	}
	if w.BasePath != expectedBase {
		return fmt.Errorf("web.basePath 必须为 %q", expectedBase)
	}
	if w.Mode == WebModeStatic {
		if w.StaticDir == "" {
			w.StaticDir = "ui"
		}
		if !validRelDir(w.StaticDir) {
			return fmt.Errorf("web.staticDir %q 不合法", w.StaticDir)
		}
		if root != nil {
			st, err := root.Lstat(w.StaticDir)
			if err != nil || !st.IsDir() {
				return fmt.Errorf("静态资源目录 %q 不存在或不是目录", w.StaticDir)
			}
		}
		return nil
	}
	if w.Entry == "" {
		w.Entry = "run-web.sh"
	}
	if !validChildName(w.Entry) {
		return fmt.Errorf("web.entry %q 不合法", w.Entry)
	}
	if w.Port < 0 || (w.Port > 0 && w.Port < 1024) || w.Port > 65535 {
		return fmt.Errorf("web.port %d 不合法（需为 0 或 1024-65535）", w.Port)
	}
	if w.IdleTimeoutSeconds <= 0 {
		w.IdleTimeoutSeconds = 300
	} else if w.IdleTimeoutSeconds > 86400 {
		return errors.New("web.idleTimeoutSeconds 不能超过 86400 秒")
	}
	if w.ReadyTimeoutSeconds <= 0 {
		w.ReadyTimeoutSeconds = 15
	} else if w.ReadyTimeoutSeconds > 120 {
		return errors.New("web.readyTimeoutSeconds 不能超过 120 秒")
	}
	if w.RestartLimit <= 0 {
		w.RestartLimit = 5
	} else if w.RestartLimit > 20 {
		w.RestartLimit = 20
	}
	if root != nil {
		_, st, err := readCheckedFile(root, w.Entry, maxScriptBytes)
		if err != nil {
			return fmt.Errorf("找不到有效的 Web 启动脚本 %q", w.Entry)
		}
		if st.Mode()&0111 == 0 {
			return fmt.Errorf("Web 启动脚本 %q 缺少可执行权限（需 chmod 0700）", w.Entry)
		}
	}
	return nil
}

func validateCronConfig(root *os.Root, c *CronConfig) error {
	if c.Entry == "" {
		c.Entry = "run-cron.sh"
	}
	if !validChildName(c.Entry) {
		return fmt.Errorf("cron.entry %q 不合法", c.Entry)
	}
	if c.Schedule.Timezone == "" {
		c.Schedule.Timezone = "Asia/Shanghai"
	}
	if _, err := time.LoadLocation(c.Schedule.Timezone); err != nil {
		return fmt.Errorf("cron.schedule.timezone %q 无效", c.Schedule.Timezone)
	}
	if len(strings.Fields(c.Schedule.Cron)) != 5 {
		return fmt.Errorf("cron.schedule.cron %q 必须为 5 段标准 Cron 表达式", c.Schedule.Cron)
	}
	if _, err := cronParser.Parse(c.Schedule.Cron); err != nil {
		return fmt.Errorf("cron.schedule.cron %q 语法无效", c.Schedule.Cron)
	}
	if c.TimeoutSeconds <= 0 {
		c.TimeoutSeconds = 300
	} else if c.TimeoutSeconds > 3600 {
		return errors.New("cron.timeoutSeconds 不能超过 3600 秒")
	}
	for _, ev := range c.Notification.Events {
		switch ev {
		case "success", "failure", "timeout":
		default:
			return fmt.Errorf("不支持的通知事件: %s", ev)
		}
	}
	for _, ch := range c.Notification.Channels {
		switch ch {
		case "bark", "webhook", "email", "wecom", "dingtalk":
		default:
			return fmt.Errorf("不支持的通知渠道: %s", ch)
		}
	}
	if email := c.Notification.Email; email != nil {
		if len(email.Subject) > 180 || strings.ContainsAny(email.Subject, "\r\n") {
			return errors.New("邮件主题长度超限或包含非法换行符")
		}
		switch email.Mode {
		case "", "builtin":
			if email.File != "" {
				return errors.New("builtin 邮件模式不能指定模板文件")
			}
		case "content", "custom":
			if !validChildName(email.File) {
				return errors.New("邮件模板文件名不合法")
			}
			if root != nil {
				if _, _, err := readCheckedFile(root, email.File, maxEmailBytes); err != nil {
					return fmt.Errorf("无法读取邮件模板文件 %q", email.File)
				}
			}
		default:
			return fmt.Errorf("不支持的邮件模板模式: %s", email.Mode)
		}
	}
	if root != nil {
		_, st, err := readCheckedFile(root, c.Entry, maxScriptBytes)
		if err != nil {
			return fmt.Errorf("找不到有效的定时脚本入口 %q", c.Entry)
		}
		if st.Mode()&0111 == 0 {
			return fmt.Errorf("定时脚本入口 %q 缺少可执行权限（需 chmod 0700）", c.Entry)
		}
	}
	return nil
}

func patchManifestBytes(raw []byte, req AppUpdateRequest) ([]byte, error) {
	var doc map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		return nil, ErrInvalid
	}
	if req.Access != nil {
		ids := req.Access.AllowedUserIDs
		if ids == nil {
			ids = []int64{}
		}
		doc["access"] = map[string]any{"policy": normalizeAccessPolicy(req.Access.Policy), "allowedUserIDs": ids}
	}
	if req.Web != nil {
		webDoc, ok := doc["web"].(map[string]any)
		if !ok {
			if req.Web.Enabled != nil && *req.Web.Enabled {
				return nil, ErrInvalid
			}
		} else {
			if req.Web.Enabled != nil {
				webDoc["enabled"] = *req.Web.Enabled
			}
			if req.Web.Mode != nil {
				webDoc["mode"] = *req.Web.Mode
			}
			if req.Web.IdleTimeoutSeconds != nil {
				webDoc["idleTimeoutSeconds"] = *req.Web.IdleTimeoutSeconds
			}
			if req.Web.AutoRestart != nil {
				webDoc["autoRestart"] = *req.Web.AutoRestart
			}
			doc["web"] = webDoc
		}
	}
	if req.Cron != nil {
		cronDoc, ok := doc["cron"].(map[string]any)
		if !ok {
			if req.Cron.Enabled != nil && *req.Cron.Enabled {
				return nil, ErrInvalid
			}
		} else {
			if req.Cron.Enabled != nil {
				cronDoc["enabled"] = *req.Cron.Enabled
			}
			if req.Cron.TimeoutSeconds != nil {
				cronDoc["timeoutSeconds"] = *req.Cron.TimeoutSeconds
			}
			schedDoc, _ := cronDoc["schedule"].(map[string]any)
			if schedDoc == nil {
				schedDoc = make(map[string]any)
			}
			if req.Cron.Schedule != nil {
				schedDoc["cron"] = req.Cron.Schedule.Cron
				schedDoc["timezone"] = req.Cron.Schedule.Timezone
			}
			if req.Cron.Cron != nil {
				schedDoc["cron"] = *req.Cron.Cron
			}
			if req.Cron.Timezone != nil {
				schedDoc["timezone"] = *req.Cron.Timezone
			}
			cronDoc["schedule"] = schedDoc

			notifDoc, _ := cronDoc["notification"].(map[string]any)
			if notifDoc == nil {
				notifDoc = make(map[string]any)
			}
			if req.Cron.Notification != nil {
				notifDoc["events"] = req.Cron.Notification.Events
				notifDoc["channels"] = req.Cron.Notification.Channels
			}
			if req.Cron.Events != nil {
				notifDoc["events"] = req.Cron.Events
			}
			if req.Cron.Channels != nil {
				notifDoc["channels"] = req.Cron.Channels
			}
			cronDoc["notification"] = notifDoc
			doc["cron"] = cronDoc
		}
	}
	updated, err := json.MarshalIndent(doc, "", "  ")
	if err != nil || len(updated) > maxManifestBytes {
		return nil, ErrInvalid
	}
	return updated, nil
}
