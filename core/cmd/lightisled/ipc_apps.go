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

type nativeAppsOverview struct {
	Apps               []apps.PublicApp          `json:"apps"`
	Templates          []apps.OfficialAppTemplate `json:"templates"`
	AppStorage         apps.AppStorageSnapshot   `json:"appStorage"`
	MCP                apps.MCPConfigSnapshot    `json:"mcp"`
	MCPLogs            []apps.MCPCallLogEntry    `json:"mcpLogs"`
	Members            []nativeAppMember         `json:"members"`
	ConfiguredChannels []string                  `json:"configuredChannels"`
	AppLogs            *nativeAppLogsResult      `json:"appLogs,omitempty"`
	ProbeResult        *apps.AppProbeResult      `json:"probeResult,omitempty"`
	MCPDebugResult     *apps.MCPDebugExecResult  `json:"mcpDebug,omitempty"`
	LaunchTicket       *nativeAppLaunchResult    `json:"launchTicket,omitempty"`
	BackupPath         string                    `json:"backupPath,omitempty"`
}

type appsIPCRequest struct {
	RequestID     string                          `json:"requestID,omitempty"`
	AppID         string                          `json:"appID,omitempty"`
	TemplateID    string                          `json:"templateId,omitempty"`
	LocationID    string                          `json:"locationId,omitempty"`
	Action        string                          `json:"action,omitempty"`
	DeleteData    bool                            `json:"deleteData,omitempty"`
	MCPEnabled    *bool                           `json:"mcpEnabled,omitempty"`
	MCPLanEnabled *bool                           `json:"mcpLanEnabled,omitempty"`
	Update        *apps.AppUpdateRequest          `json:"update,omitempty"`
	Storage       *apps.AppStorageMutationRequest `json:"storage,omitempty"`
	Scaffold      json.RawMessage                 `json:"scaffold,omitempty"`
	Probe         *apps.AppProbeRequest           `json:"probe,omitempty"`
	MCPDebug      *apps.MCPDebugExecRequest       `json:"mcpDebug,omitempty"`
	FilePath      string                          `json:"filePath,omitempty"`
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
		return "该精选模板已安装，无需重复添加"
	default:
		msg := strings.TrimSpace(err.Error())
		if msg != "" {
			return msg
		}
		return "轻应用操作失败"
	}
}

func buildNativeAppsOverview(appsMgr *apps.Manager, accountStore *auth.Store) nativeAppsOverview {
	if appsMgr == nil {
		return nativeAppsOverview{
			Apps:               []apps.PublicApp{},
			Templates:          []apps.OfficialAppTemplate{},
			MCPLogs:            []apps.MCPCallLogEntry{},
			Members:            []nativeAppMember{},
			ConfiguredChannels: []string{},
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
	return nativeAppsOverview{
		Apps:               appsMgr.ListForUser(0, auth.RoleAdmin),
		Templates:          appsMgr.ListTemplates(),
		AppStorage:         appsMgr.GetStorageSnapshot(),
		MCP:                appsMgr.BuildMCPConfigSnapshot(""),
		MCPLogs:            appsMgr.GetMCPCallLogs(),
		Members:            members,
		ConfiguredChannels: appsMgr.ConfiguredChannels(),
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

func handleAppsIPC(
	parentCtx context.Context,
	command string,
	appsMgr *apps.Manager,
	accountStore *auth.Store,
) bool {
	if command != "apps" && !strings.HasPrefix(command, "apps ") {
		return false
	}
	words := strings.Fields(command)
	operation := "list"
	if len(words) > 1 {
		operation = words[1]
	}
	var encoded string
	if len(words) > 2 {
		encoded = words[2]
	}
	req, err := decodeAppsIPCRequest(encoded)
	if err != nil {
		emitAppsReply(req.RequestID, operation, nil, err)
		return true
	}
	if appsMgr == nil {
		emitAppsReply(req.RequestID, operation, nil, errors.New("轻应用服务尚未就绪"))
		return true
	}

	switch operation {
	case "list":
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, nil)
		return true

	case "refresh":
		err := appsMgr.Reload()
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "set-mcp":
		_, err := appsMgr.SetMCPConfig(req.MCPEnabled, req.MCPLanEnabled)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "rotate-mcp-token":
		_, err := appsMgr.RotateMCPToken()
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "action":
		id := strings.TrimSpace(req.AppID)
		act := strings.ToLower(strings.TrimSpace(req.Action))
		if act == "start" || act == "wake" || act == "restart" || act == "approve" || act == "activate" {
			runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
				_, opErr := appsMgr.ExecuteAction(ctx, id, req.Action)
				overview := buildNativeAppsOverview(appsMgr, accountStore)
				if opErr != nil && id != "" {
					if logs, logErr := appsMgr.GetWebLogs(id); logErr == nil {
						runs, _ := appsMgr.GetCronRuns(id, 30)
						overview.AppLogs = &nativeAppLogsResult{AppID: id, WebOutput: logs, CronRuns: runs}
					}
				}
				emitAppsReply(req.RequestID, operation, overview, opErr)
			})
			return true
		}
		ctx, cancel := context.WithTimeout(parentCtx, 10*time.Second)
		defer cancel()
		_, opErr := appsMgr.ExecuteAction(ctx, id, req.Action)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, opErr)
		return true

	case "update":
		if req.Update == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少更新参数"))
			return true
		}
		_, err := appsMgr.UpdateApp(req.AppID, *req.Update)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "scaffold":
		if len(req.Scaffold) == 0 {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少新建插件参数"))
			return true
		}
		_, err := appsMgr.ScaffoldApp(req.Scaffold, true)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "set-storage":
		if req.Storage == nil {
			emitAppsReply(req.RequestID, operation, nil, errors.New("缺少应用存储位置参数"))
			return true
		}
		_, err := appsMgr.MutateStorageLocation(*req.Storage)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "install-template":
		tplID := strings.TrimSpace(req.TemplateID)
		if tplID == "" {
			tplID = strings.TrimSpace(req.AppID)
		}
		_, err := appsMgr.InstallTemplateAt(tplID, req.LocationID)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "delete":
		err := appsMgr.DeleteApp(req.AppID, req.DeleteData)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "logs":
		logs, err := appsMgr.GetWebLogs(req.AppID)
		runs, _ := appsMgr.GetCronRuns(req.AppID, 30)
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		if err == nil {
			overview.AppLogs = &nativeAppLogsResult{
				AppID:     req.AppID,
				WebOutput: logs,
				CronRuns:  runs,
			}
		}
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "probe":
		probeReq := apps.AppProbeRequest{}
		if req.Probe != nil {
			probeReq = *req.Probe
		}
		runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
			res, err := appsMgr.ProbeApp(ctx, req.AppID, probeReq)
			overview := buildNativeAppsOverview(appsMgr, accountStore)
			overview.ProbeResult = &res
			emitAppsReply(req.RequestID, operation, overview, err)
		})
		return true

	case "mcp-debug":
		debugReq := apps.MCPDebugExecRequest{}
		if req.MCPDebug != nil {
			debugReq = *req.MCPDebug
		}
		runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
			res := appsMgr.ExecuteDebugMCP(ctx, debugReq, "127.0.0.1")
			overview := buildNativeAppsOverview(appsMgr, accountStore)
			overview.MCPDebugResult = &res
			emitAppsReply(req.RequestID, operation, overview, nil)
		})
		return true

	case "mcp-clear-logs":
		err := appsMgr.ClearMCPCallLogs()
		overview := buildNativeAppsOverview(appsMgr, accountStore)
		emitAppsReply(req.RequestID, operation, overview, err)
		return true

	case "issue-ticket":
		id := strings.TrimSpace(req.AppID)
		runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
			app, err := appsMgr.GetForUser(id, 0, auth.RoleAdmin)
			if err != nil {
				overview := buildNativeAppsOverview(appsMgr, accountStore)
				emitAppsReply(req.RequestID, operation, overview, err)
				return
			}
			if app.PendingActivation {
				overview := buildNativeAppsOverview(appsMgr, accountStore)
				emitAppsReply(req.RequestID, operation, overview, apps.ErrPendingActivation)
				return
			}
			if app.Web.Enabled && app.Web.Mode != apps.WebModeStatic && app.Web.Mode != "none" {
				app, err = appsMgr.WakeApp(ctx, id)
			}
			overview := buildNativeAppsOverview(appsMgr, accountStore)
			if err == nil {
				adminUser := resolveNativeAdminIdentity(accountStore)
				ticket := appsMgr.IssueTicket(id, adminUser)
				localBase, _ := appsMgr.Endpoints()
				if localBase == "" {
					localBase = "http://127.0.0.1:16666"
				}
				overview.LaunchTicket = &nativeAppLaunchResult{
					AppID:     id,
					Ticket:    ticket,
					LaunchURL: strings.TrimRight(localBase, "/") + "/apps/" + id + "/?__li_ticket=" + ticket,
				}
			} else if id != "" {
				if logs, logErr := appsMgr.GetWebLogs(id); logErr == nil {
					runs, _ := appsMgr.GetCronRuns(id, 30)
					overview.AppLogs = &nativeAppLogsResult{AppID: id, WebOutput: logs, CronRuns: runs}
				}
			}
			emitAppsReply(req.RequestID, operation, overview, err)
		})
		return true

	case "export-data":
		runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
			target, exportErr := exportAppDataAtomically(ctx, appsMgr, req.AppID, req.FilePath)
			overview := buildNativeAppsOverview(appsMgr, accountStore)
			if exportErr == nil {
				overview.BackupPath = target
			}
			emitAppsReply(req.RequestID, operation, overview, exportErr)
		})
		return true

	case "restore-data":
		source := filepath.Clean(strings.TrimSpace(req.FilePath))
		if source == "" || !filepath.IsAbs(source) {
			emitAppsReply(req.RequestID, operation, nil, errors.New("请选择有效的备份归档文件"))
			return true
		}
		runAppsIPCAsync(parentCtx, req.RequestID, operation, func(ctx context.Context) {
			f, err := os.Open(source)
			if err != nil {
				emitAppsReply(req.RequestID, operation, nil, err)
				return
			}
			restoreErr := appsMgr.RestoreAppData(ctx, req.AppID, f)
			_ = f.Close()
			overview := buildNativeAppsOverview(appsMgr, accountStore)
			if restoreErr == nil {
				overview.BackupPath = source
			}
			emitAppsReply(req.RequestID, operation, overview, restoreErr)
		})
		return true

	default:
		emitAppsReply(req.RequestID, operation, nil, errors.New("未知轻应用指令："+operation))
		return true
	}
}
