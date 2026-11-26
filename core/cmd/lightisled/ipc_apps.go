//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/safego"
)

var appsIPCWorkerSem = make(chan struct{}, 4)

type nativeAppMember struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
}

type nativeAppLogsResult struct {
	AppID     string               `json:"appId"`
	WebOutput string               `json:"webOutput"`
	CronRuns  []automation.TaskRun `json:"cronRuns"`
}

type nativeAppLaunchResult struct {
	AppID     string `json:"appId"`
	Ticket    string `json:"ticket"`
	LaunchURL string `json:"launchUrl"`
}

type nativeAutomationRunsResult struct {
	TaskID string               `json:"taskId"`
	Runs   []automation.TaskRun `json:"runs"`
}

type nativeAutomationUpdateRequest struct {
	Enabled      bool                    `json:"enabled"`
	Schedule     automation.Schedule     `json:"schedule"`
	Notification automation.Notification `json:"notification"`
	Revision     string                  `json:"revision"`
}

type nativeAppsOverview struct {
	Apps                 []apps.PublicApp            `json:"apps"`
	Store                *apps.AppStoreSnapshot      `json:"store,omitempty"`
	Templates            []apps.OfficialAppTemplate  `json:"templates"`
	AppStorage           apps.AppStorageSnapshot     `json:"appStorage"`
	MCP                  apps.MCPConfigSnapshot      `json:"mcp"`
	MCPLogs              []apps.MCPCallLogEntry      `json:"mcpLogs"`
	Members              []nativeAppMember           `json:"members"`
	ConfiguredChannels   []string                    `json:"configuredChannels"`
	AutomationTasks      []automation.Task           `json:"automationTasks"`
	AutomationScriptsDir string                      `json:"automationScriptsDir,omitempty"`
	AppLogs              *nativeAppLogsResult        `json:"appLogs,omitempty"`
	AutomationRuns       *nativeAutomationRunsResult `json:"automationRuns,omitempty"`
	ProbeResult          *apps.AppProbeResult        `json:"probeResult,omitempty"`
	MCPDebugResult       *apps.MCPDebugExecResult    `json:"mcpDebug,omitempty"`
	LaunchTicket         *nativeAppLaunchResult      `json:"launchTicket,omitempty"`
	BackupPath           string                      `json:"backupPath,omitempty"`
}

type appsIPCRequest struct {
	RequestID        string                          `json:"requestID,omitempty"`
	AppID            string                          `json:"appID,omitempty"`
	TemplateID       string                          `json:"templateId,omitempty"`
	PluginID         string                          `json:"pluginId,omitempty"`
	LocationID       string                          `json:"locationId,omitempty"`
	Action           string                          `json:"action,omitempty"`
	DeleteData       bool                            `json:"deleteData,omitempty"`
	MCPEnabled       *bool                           `json:"mcpEnabled,omitempty"`
	MCPLanEnabled    *bool                           `json:"mcpLanEnabled,omitempty"`
	Update           *apps.AppUpdateRequest          `json:"update,omitempty"`
	Storage          *apps.AppStorageMutationRequest `json:"storage,omitempty"`
	StoreConfig      *apps.AppStoreConfigRequest     `json:"storeConfig,omitempty"`
	Scaffold         json.RawMessage                 `json:"scaffold,omitempty"`
	Probe            *apps.AppProbeRequest           `json:"probe,omitempty"`
	MCPDebug         *apps.MCPDebugExecRequest       `json:"mcpDebug,omitempty"`
	FilePath         string                          `json:"filePath,omitempty"`
	AutomationTaskID string                          `json:"automationTaskId,omitempty"`
	AutomationUpdate *nativeAutomationUpdateRequest  `json:"automationUpdate,omitempty"`
}

func emitAppsReply(requestID, operation string, result any, err error) {
	var errMsg string
	if err != nil {
		errMsg = appsIPCErrorMessage(err)
	}
	writeIPCEnvelope(ipcEnvelopeOptions{
		Prefix:        "LIGHTISLE_APPS",
		RequestID:     requestID,
		Operation:     operation,
		Result:        result,
		IncludeResult: result != nil,
		ErrorMessage:  errMsg,
		FallbackError: "轻应用与 MCP 状态序列化失败",
	})
}

func appsIPCErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	switch {
	case errors.Is(err, apps.ErrNotFound):
		return "未找到对应的轻应用"
	case errors.Is(err, apps.ErrPendingActivation):
		return "该轻应用尚未经管理员首次激活确认"
	case errors.Is(err, apps.ErrDisabled):
		return "该轻应用当前已停用"
	case errors.Is(err, apps.ErrBusy):
		return "该轻应用正在执行操作，请稍后再试"
	case errors.Is(err, apps.ErrRunning):
		return "该轻应用正在运行中，请先停止后再试"
	case errors.Is(err, apps.ErrChanged):
		return "轻应用配置已在外部变更，请刷新后重试"
	case errors.Is(err, apps.ErrInvalid):
		detail := strings.TrimSpace(strings.TrimPrefix(err.Error(), apps.ErrInvalid.Error()))
		detail = strings.TrimSpace(strings.TrimPrefix(detail, ":"))
		if detail != "" {
			return "轻应用配置或参数无效：" + detail
		}
		return "轻应用配置或参数无效"
	case errors.Is(err, apps.ErrStorageSlotLimit), errors.Is(err, apps.ErrStorageOffline):
		detail := strings.TrimSpace(strings.TrimPrefix(err.Error(), apps.ErrStorageSlotLimit.Error()))
		detail = strings.TrimSpace(strings.TrimPrefix(detail, apps.ErrStorageOffline.Error()))
		detail = strings.TrimSpace(strings.TrimPrefix(detail, ":"))
		if detail != "" {
			return detail
		}
		return err.Error()
	case errors.Is(err, apps.ErrAlreadyInstalled):
		return "该插件已安装，无需重复下载"
	case errors.Is(err, apps.ErrStorePluginNotFound):
		return "未在在线插件商店中找到该应用，请先刷新商店目录"
	case errors.Is(err, apps.ErrStoreChecksumMismatch):
		return "下载的插件包 SHA-256 校验未通过，系统已拒绝安装"
	case errors.Is(err, apps.ErrStoreNoUpdate):
		return "当前已安装插件已是商店最新版本"
	case errors.Is(err, apps.ErrStoreInvalidConfig):
		detail := strings.TrimSpace(strings.TrimPrefix(err.Error(), apps.ErrStoreInvalidConfig.Error()))
		detail = strings.TrimSpace(strings.TrimPrefix(detail, ":"))
		if detail != "" {
			return detail
		}
		return "在线商店源地址或镜像前缀无效"
	case errors.Is(err, apps.ErrStoreUnavailable):
		detail := strings.TrimSpace(strings.TrimPrefix(err.Error(), apps.ErrStoreUnavailable.Error()))
		detail = strings.TrimSpace(strings.TrimPrefix(detail, ":"))
		if detail != "" {
			return detail
		}
		return "暂时无法连接 Git 在线插件商店，请检查网络或配置镜像前缀"
	case errors.Is(err, automation.ErrInvalid):
		return "定时脚本配置、Cron 表达式或时区无效，请检查后重试"
	case errors.Is(err, automation.ErrNotFound):
		return "未找到对应的本机定时脚本任务"
	case errors.Is(err, automation.ErrBusy):
		return "该定时脚本正在运行中，请等待本次执行完成"
	case errors.Is(err, automation.ErrChanged):
		return "脚本 task.json 已在外部修改，请先刷新脚本列表后再保存"
	case errors.Is(err, automation.ErrUnavailable):
		return "定时脚本调度服务尚未就绪"
	default:
		msg := strings.TrimSpace(err.Error())
		if msg != "" {
			return msg
		}
		return "轻应用操作失败"
	}
}

func buildNativeAppsOverview(appsMgr *apps.Manager, autoMgr *automation.Manager, accountStore *auth.Store) nativeAppsOverview {
	autoTasks := []automation.Task{}
	autoScriptsDir := ""
	if autoMgr != nil {
		autoScriptsDir = autoMgr.ScriptsDir()
		if tasks := autoMgr.PublicScriptTasks(); tasks != nil {
			autoTasks = tasks
		}
	}
	if appsMgr == nil {
		return nativeAppsOverview{
			Apps:                 []apps.PublicApp{},
			Templates:            []apps.OfficialAppTemplate{},
			MCPLogs:              []apps.MCPCallLogEntry{},
			Members:              []nativeAppMember{},
			ConfiguredChannels:   []string{},
			AutomationTasks:      autoTasks,
			AutomationScriptsDir: autoScriptsDir,
		}
	}
	members := make([]nativeAppMember, 0)
	if accountStore != nil {
		if users, err := accountStore.NativeListUsers(); err == nil {
			for _, u := range users {
				if u.Enabled {
					members = append(members, nativeAppMember{
						ID:       u.ID,
						Username: u.Username,
						Role:     u.Role,
					})
				}
			}
		}
	}
	storeSnap := appsMgr.GetStoreSnapshot()
	return nativeAppsOverview{
		Apps:                 appsMgr.ListForUser(0, auth.RoleAdmin),
		Store:                &storeSnap,
		Templates:            appsMgr.ListTemplates(),
		AppStorage:           appsMgr.GetStorageSnapshot(),
		MCP:                  appsMgr.BuildMCPConfigSnapshot(""),
		MCPLogs:              appsMgr.GetMCPCallLogs(),
		Members:              members,
		ConfiguredChannels:   appsMgr.ConfiguredChannels(),
		AutomationTasks:      autoTasks,
		AutomationScriptsDir: autoScriptsDir,
	}
}

func decodeAppsIPCRequest(encoded string) (appsIPCRequest, error) {
	if encoded == "" {
		return appsIPCRequest{}, nil
	}
	if len(encoded) > 192*1024 {
		return appsIPCRequest{}, errors.New("请求内容过大")
	}
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return appsIPCRequest{}, errors.New("请求格式无效")
	}
	var req appsIPCRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return appsIPCRequest{}, errors.New("请求 JSON 格式无效")
	}
	return req, nil
}

func resolveNativeAdminIdentity(accountStore *auth.Store) apps.UserIdentity {
	if accountStore != nil {
		if users, err := accountStore.NativeListUsers(); err == nil {
			for _, u := range users {
				if u.Enabled && u.Role == auth.RoleAdmin {
					return apps.UserIdentity{
						ID:       u.ID,
						Username: u.Username,
						Role:     auth.RoleAdmin,
					}
				}
			}
		}
	}
	return apps.UserIdentity{
		ID:       1,
		Username: "admin",
		Role:     auth.RoleAdmin,
	}
}

func runAppsIPCAsync(parentCtx context.Context, requestID, operation string, fn func(context.Context)) {
	select {
	case appsIPCWorkerSem <- struct{}{}:
	default:
		emitAppsReply(requestID, operation, nil, apps.ErrBusy)
		return
	}
	go func() {
		defer func() { <-appsIPCWorkerSem }()
		defer safego.Recover("apps-ipc:" + operation)
		ctx, cancel := context.WithTimeout(parentCtx, 40*time.Second)
		defer cancel()
		fn(ctx)
	}()
}

func exportAppDataAtomically(ctx context.Context, appsMgr *apps.Manager, appID, filePath string) (string, error) {
	target := filepath.Clean(strings.TrimSpace(filePath))
	if target == "" || !filepath.IsAbs(target) {
		return "", errors.New("请选择有效的导出文件路径")
	}
	if info, err := os.Stat(target); err == nil && info.IsDir() {
		return "", errors.New("导出目标路径不能是目录")
	}
	dir := filepath.Dir(target)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, ".lightisle-app-backup-*.tmp")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	success := false
	defer func() {
		if tmp != nil {
			_ = tmp.Close()
		}
		if !success {
			_ = os.Remove(tmpPath)
		}
	}()
	if err := appsMgr.ExportAppData(ctx, appID, tmp); err != nil {
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		return "", err
	}
	if err := tmp.Close(); err != nil {
		tmp = nil
		return "", err
	}
	tmp = nil
	if err := os.Chmod(tmpPath, 0600); err != nil {
		return "", err
	}
	if err := os.Rename(tmpPath, target); err != nil {
		return "", err
	}
	success = true
	return target, nil
}

type appsIPCHandler struct {
	parentCtx    context.Context
	appsMgr      *apps.Manager
	autoMgr      *automation.Manager
	accountStore *auth.Store
}

func (h appsIPCHandler) overview() nativeAppsOverview {
	return buildNativeAppsOverview(h.appsMgr, h.autoMgr, h.accountStore)
}

func (h appsIPCHandler) attachAppLogs(ov *nativeAppsOverview, appID string) {
	if appID == "" || h.appsMgr == nil {
		return
	}
	logs, err := h.appsMgr.GetWebLogs(appID)
	if err != nil {
		return
	}
	runs, _ := h.appsMgr.GetCronRuns(appID, 30)
	ov.AppLogs = &nativeAppLogsResult{AppID: appID, WebOutput: logs, CronRuns: runs}
}

func handleAppsIPC(
	parentCtx context.Context,
	command string,
	appsMgr *apps.Manager,
	autoMgr *automation.Manager,
	accountStore *auth.Store,
) bool {
	if command != "apps" && !strings.HasPrefix(command, "apps ") {
		return false
	}
	operation, encoded := parseAppsIPCCommand(command)
	req, err := decodeAppsIPCRequest(encoded)
	if err != nil {
		emitAppsReply(req.RequestID, operation, nil, err)
		return true
	}

	handler := appsIPCHandler{
		parentCtx:    parentCtx,
		appsMgr:      appsMgr,
		autoMgr:      autoMgr,
		accountStore: accountStore,
	}
	if strings.HasPrefix(operation, "automation-") {
		handler.handleAutomationOp(operation, req)
		return true
	}
	if appsMgr == nil {
		emitAppsReply(req.RequestID, operation, nil, errors.New("轻应用服务尚未就绪"))
		return true
	}
	if handler.handleInventoryOp(operation, req) ||
		handler.handleMCPOp(operation, req) ||
		handler.handleRuntimeOp(operation, req) {
		return true
	}
	emitAppsReply(req.RequestID, operation, nil, errors.New("未知轻应用指令："+operation))
	return true
}

func parseAppsIPCCommand(command string) (operation, encoded string) {
	words := strings.Fields(command)
	operation = "list"
	if len(words) > 1 {
		operation = words[1]
	}
	if len(words) > 2 {
		encoded = words[2]
	}
	return operation, encoded
}

func (h appsIPCHandler) handleInventoryOp(operation string, req appsIPCRequest) bool {
	switch operation {
	case "list":
		emitAppsReply(req.RequestID, operation, h.overview(), nil)
	case "refresh":
		err := h.appsMgr.Reload()
		if err == nil && h.autoMgr != nil {
			_ = h.autoMgr.Reload()
		}
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "update":
		if req.Update == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少更新参数"))
			return true
		}
		_, err := h.appsMgr.UpdateApp(req.AppID, *req.Update)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "scaffold":
		if len(req.Scaffold) == 0 {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少新建插件参数"))
			return true
		}
		_, err := h.appsMgr.ScaffoldApp(req.Scaffold, true)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "set-storage":
		if req.Storage == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少应用存储位置参数"))
			return true
		}
		_, err := h.appsMgr.MutateStorageLocation(*req.Storage)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "install-template", "store-install":
		pluginID := strings.TrimSpace(req.PluginID)
		if pluginID == "" {
			pluginID = strings.TrimSpace(req.TemplateID)
		}
		if pluginID == "" {
			pluginID = strings.TrimSpace(req.AppID)
		}
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			_, err := h.appsMgr.InstallStorePlugin(ctx, pluginID, req.LocationID)
			emitAppsReply(req.RequestID, operation, h.overview(), err)
		})
	case "store-refresh":
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			snap, err := h.appsMgr.RefreshStore(ctx)
			ov := h.overview()
			ov.Store = &snap
			emitAppsReply(req.RequestID, operation, ov, err)
		})
	case "store-config":
		if req.StoreConfig == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少商店源配置参数"))
			return true
		}
		cfgReq := *req.StoreConfig
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			snap, err := h.appsMgr.UpdateStoreConfig(ctx, cfgReq)
			ov := h.overview()
			ov.Store = &snap
			if errors.Is(err, apps.ErrStoreInvalidConfig) {
				emitAppsReply(req.RequestID, operation, nil, err)
				return
			}
			emitAppsReply(req.RequestID, operation, ov, err)
		})
	case "store-upgrade":
		pluginID := strings.TrimSpace(req.PluginID)
		if pluginID == "" {
			pluginID = strings.TrimSpace(req.AppID)
		}
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			_, err := h.appsMgr.UpgradeStorePlugin(ctx, pluginID)
			emitAppsReply(req.RequestID, operation, h.overview(), err)
		})
	case "delete":
		err := h.appsMgr.DeleteApp(req.AppID, req.DeleteData)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	default:
		return false
	}
	return true
}

func (h appsIPCHandler) handleMCPOp(operation string, req appsIPCRequest) bool {
	switch operation {
	case "set-mcp":
		_, err := h.appsMgr.SetMCPConfig(req.MCPEnabled, req.MCPLanEnabled)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "rotate-mcp-token":
		_, err := h.appsMgr.RotateMCPToken()
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "mcp-debug":
		debugReq := apps.MCPDebugExecRequest{}
		if req.MCPDebug != nil {
			debugReq = *req.MCPDebug
		}
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			res := h.appsMgr.ExecuteDebugMCP(ctx, debugReq, "127.0.0.1")
			ov := h.overview()
			ov.MCPDebugResult = &res
			emitAppsReply(req.RequestID, operation, ov, nil)
		})
	case "mcp-clear-logs":
		err := h.appsMgr.ClearMCPCallLogs()
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	default:
		return false
	}
	return true
}

func (h appsIPCHandler) handleRuntimeOp(operation string, req appsIPCRequest) bool {
	switch operation {
	case "action":
		h.handleAction(operation, req)
	case "logs":
		h.handleLogs(operation, req)
	case "probe":
		h.handleProbe(operation, req)
	case "issue-ticket":
		h.handleIssueTicket(operation, req)
	case "export-data":
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			target, exportErr := exportAppDataAtomically(ctx, h.appsMgr, req.AppID, req.FilePath)
			ov := h.overview()
			if exportErr == nil {
				ov.BackupPath = target
			}
			emitAppsReply(req.RequestID, operation, ov, exportErr)
		})
	case "restore-data":
		h.handleRestoreData(operation, req)
	default:
		return false
	}
	return true
}

func isAsyncAppAction(act string) bool {
	switch act {
	case "start", "wake", "restart", "approve", "activate":
		return true
	default:
		return false
	}
}

func (h appsIPCHandler) handleAction(operation string, req appsIPCRequest) {
	id := strings.TrimSpace(req.AppID)
	act := strings.ToLower(strings.TrimSpace(req.Action))
	if isAsyncAppAction(act) {
		runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
			_, opErr := h.appsMgr.ExecuteAction(ctx, id, req.Action)
			ov := h.overview()
			if opErr != nil {
				h.attachAppLogs(&ov, id)
			}
			emitAppsReply(req.RequestID, operation, ov, opErr)
		})
		return
	}
	ctx, cancel := context.WithTimeout(h.parentCtx, 10*time.Second)
	defer cancel()
	_, opErr := h.appsMgr.ExecuteAction(ctx, id, req.Action)
	emitAppsReply(req.RequestID, operation, h.overview(), opErr)
}

func (h appsIPCHandler) handleLogs(operation string, req appsIPCRequest) {
	logs, err := h.appsMgr.GetWebLogs(req.AppID)
	runs, _ := h.appsMgr.GetCronRuns(req.AppID, 30)
	ov := h.overview()
	if err == nil {
		ov.AppLogs = &nativeAppLogsResult{
			AppID:     req.AppID,
			WebOutput: logs,
			CronRuns:  runs,
		}
	}
	emitAppsReply(req.RequestID, operation, ov, err)
}

func (h appsIPCHandler) handleProbe(operation string, req appsIPCRequest) {
	probeReq := apps.AppProbeRequest{}
	if req.Probe != nil {
		probeReq = *req.Probe
	}
	runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
		res, err := h.appsMgr.ProbeApp(ctx, req.AppID, probeReq)
		ov := h.overview()
		ov.ProbeResult = &res
		emitAppsReply(req.RequestID, operation, ov, err)
	})
}

func (h appsIPCHandler) handleIssueTicket(operation string, req appsIPCRequest) {
	id := strings.TrimSpace(req.AppID)
	runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
		app, err := h.appsMgr.GetForUser(id, 0, auth.RoleAdmin)
		if err != nil {
			emitAppsReply(req.RequestID, operation, h.overview(), err)
			return
		}
		if app.PendingActivation {
			emitAppsReply(req.RequestID, operation, h.overview(), apps.ErrPendingActivation)
			return
		}
		if app.Web.Enabled && app.Web.Mode != apps.WebModeStatic && app.Web.Mode != "none" {
			app, err = h.appsMgr.WakeApp(ctx, id)
		}
		ov := h.overview()
		if err != nil {
			h.attachAppLogs(&ov, id)
			emitAppsReply(req.RequestID, operation, ov, err)
			return
		}
		ov.LaunchTicket = h.buildLaunchTicket(id)
		emitAppsReply(req.RequestID, operation, ov, nil)
	})
}

func (h appsIPCHandler) buildLaunchTicket(appID string) *nativeAppLaunchResult {
	adminUser := resolveNativeAdminIdentity(h.accountStore)
	ticket := h.appsMgr.IssueTicket(appID, adminUser)
	localBase, _ := h.appsMgr.Endpoints()
	if localBase == "" {
		localBase = "http://127.0.0.1:16666"
	}
	return &nativeAppLaunchResult{
		AppID:     appID,
		Ticket:    ticket,
		LaunchURL: strings.TrimRight(localBase, "/") + "/apps/" + appID + "/?__li_ticket=" + ticket,
	}
}

func (h appsIPCHandler) handleRestoreData(operation string, req appsIPCRequest) {
	source := filepath.Clean(strings.TrimSpace(req.FilePath))
	if source == "" || !filepath.IsAbs(source) {
		emitAppsReply(req.RequestID, operation, nil, errors.New("请选择有效的备份归档文件"))
		return
	}
	runAppsIPCAsync(h.parentCtx, req.RequestID, operation, func(ctx context.Context) {
		f, err := os.Open(source)
		if err != nil {
			emitAppsReply(req.RequestID, operation, nil, err)
			return
		}
		restoreErr := h.appsMgr.RestoreAppData(ctx, req.AppID, f)
		_ = f.Close()
		ov := h.overview()
		if restoreErr == nil {
			ov.BackupPath = source
		}
		emitAppsReply(req.RequestID, operation, ov, restoreErr)
	})
}

func (h appsIPCHandler) handleAutomationOp(operation string, req appsIPCRequest) {
	if h.autoMgr == nil {
		emitAppsReply(req.RequestID, operation, nil, automation.ErrUnavailable)
		return
	}
	id := strings.TrimSpace(req.AutomationTaskID)
	switch operation {
	case "automation-refresh":
		emitAppsReply(req.RequestID, operation, h.overview(), h.autoMgr.Reload())
	case "automation-runs":
		runs, err := h.autoMgr.ListScriptRuns(id, 30)
		if err == nil && runs == nil {
			runs = []automation.TaskRun{}
		}
		ov := h.overview()
		if err == nil {
			ov.AutomationRuns = &nativeAutomationRunsResult{TaskID: id, Runs: runs}
		}
		emitAppsReply(req.RequestID, operation, ov, err)
	case "automation-update":
		if !h.autoMgr.Ready() {
			emitAppsReply(req.RequestID, operation, nil, automation.ErrUnavailable)
			return
		}
		if req.AutomationUpdate == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少定时脚本更新参数"))
			return
		}
		err := h.autoMgr.UpdateRevision(
			id,
			req.AutomationUpdate.Enabled,
			req.AutomationUpdate.Schedule,
			req.AutomationUpdate.Notification,
			req.AutomationUpdate.Revision,
		)
		emitAppsReply(req.RequestID, operation, h.overview(), err)
	case "automation-run":
		if !h.autoMgr.Ready() {
			emitAppsReply(req.RequestID, operation, nil, automation.ErrUnavailable)
			return
		}
		emitAppsReply(req.RequestID, operation, h.overview(), h.autoMgr.RunScriptTaskNow(id))
	case "automation-delete":
		if !h.autoMgr.Ready() {
			emitAppsReply(req.RequestID, operation, nil, automation.ErrUnavailable)
			return
		}
		emitAppsReply(req.RequestID, operation, h.overview(), h.autoMgr.Delete(id))
	default:
		emitAppsReply(req.RequestID, operation, nil, errors.New("未知轻应用指令："+operation))
	}
}
