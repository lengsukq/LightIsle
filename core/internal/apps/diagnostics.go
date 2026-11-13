package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	errPortListenTimeout = errors.New("port listen timed out")
	errHealthCheckFailed = errors.New("health check failed")
	ansiEscapePattern    = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
)

// AppDiagnostic provides structured, human-understandable troubleshooting guidance
// when a plugin fails validation, exits during startup, times out waiting for its
// port/health check, or crashes at runtime.
type AppDiagnostic struct {
	Summary    string   `json:"summary"`
	Reason     string   `json:"reason"`
	LogExcerpt string   `json:"logExcerpt,omitempty"`
	Checks     []string `json:"checks"`
	Solutions  []string `json:"solutions"`
	DataSafe   string   `json:"dataSafe"`
}

type boundedCaptureBuffer struct {
	buf   bytes.Buffer
	limit int
}

func newBoundedCaptureBuffer(limit int) *boundedCaptureBuffer {
	if limit <= 0 {
		limit = 8 << 10
	}
	return &boundedCaptureBuffer{limit: limit}
}

func (b *boundedCaptureBuffer) Write(p []byte) (int, error) {
	total := len(p)
	if b.buf.Len() >= b.limit {
		return total, nil
	}
	remain := b.limit - b.buf.Len()
	if len(p) > remain {
		p = p[:remain]
	}
	_, _ = b.buf.Write(p)
	return total, nil
}

func (b *boundedCaptureBuffer) String() string {
	return b.buf.String()
}

func dataSafetyNote(appID string) string {
	return fmt.Sprintf("仅当前轻应用界面暂不可用；plugin-data/%s 中的业务数据与 NAS 文件均完好无损。", appID)
}

func formatExitStatus(err error) (int, string) {
	if err == nil {
		return 0, "退出码 0"
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		if code >= 0 {
			return code, fmt.Sprintf("退出码 %d", code)
		}
	}
	return -1, err.Error()
}

func extractRelevantLogExcerpt(raw string) string {
	cleaned := ansiEscapePattern.ReplaceAllString(raw, "")
	cleaned = strings.ReplaceAll(cleaned, "\r\n", "\n")
	lines := strings.Split(cleaned, "\n")
	nonEmpty := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "--- [") {
			continue
		}
		nonEmpty = append(nonEmpty, trimmed)
	}
	if len(nonEmpty) == 0 {
		return ""
	}

	keywords := []string{
		"error", "exception", "traceback", "cannot find", "no such file",
		"not found", "modulenotfounderror", "importerror", "no module named",
		"permission denied", "operation not permitted", "eaddrinuse",
		"address already in use", "syntaxerror", "panic:", "failed",
	}
	var matched []string
	for _, line := range nonEmpty {
		lower := strings.ToLower(line)
		for _, kw := range keywords {
			if strings.Contains(lower, kw) {
				matched = append(matched, line)
				break
			}
		}
	}

	picked := matched
	if len(picked) == 0 {
		picked = nonEmpty
	}
	if len(picked) > 3 {
		picked = picked[len(picked)-3:]
	}
	joined := strings.Join(picked, "\n")
	return truncateUTF8(joined, 360)
}

func firstLineSummary(s string, maxChars int) string {
	s = strings.TrimSpace(s)
	if idx := strings.IndexByte(s, '\n'); idx >= 0 {
		s = strings.TrimSpace(s[:idx])
	}
	return truncateUTF8(s, maxChars)
}

func truncateUTF8(s string, maxRunes int) string {
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	var b strings.Builder
	count := 0
	for _, r := range s {
		if count >= maxRunes {
			b.WriteString("…")
			break
		}
		b.WriteRune(r)
		count++
	}
	return b.String()
}

func formatActionableWakeError(diag AppDiagnostic) string {
	var parts []string
	if diag.Reason != "" {
		parts = append(parts, diag.Reason)
	} else if diag.Summary != "" {
		parts = append(parts, diag.Summary)
	}
	if len(diag.Checks) > 0 {
		parts = append(parts, "排查："+diag.Checks[0])
	}
	if len(diag.Solutions) > 0 {
		parts = append(parts, "解决："+diag.Solutions[0])
	}
	return strings.Join(parts, " ")
}

func buildValidationDiagnostic(appID, valErr string) *AppDiagnostic {
	valErr = strings.TrimSpace(valErr)
	if valErr == "" {
		return nil
	}
	lower := strings.ToLower(valErr)
	var checks, solutions []string

	switch {
	case strings.Contains(valErr, "缺少可执行权限") || strings.Contains(lower, "chmod"):
		checks = []string{
			fmt.Sprintf("打开 plugins/%s 目录，检查启动脚本或定时脚本的文件权限位。", appID),
			"确认脚本首行包含正确的 Shebang（例如 #!/bin/sh 或 #!/usr/bin/env python3）。",
		}
		solutions = []string{
			fmt.Sprintf("在终端对入口脚本执行 chmod 700（如 chmod 700 plugins/%s/run-web.sh），完成后回到应用中心点击「重新扫描」。", appID),
		}
	case strings.Contains(valErr, "找不到有效的") || strings.Contains(valErr, "不存在"):
		checks = []string{
			fmt.Sprintf("打开 plugins/%s/plugin.json，核对 web.entry / cron.entry / web.staticDir 填写的文件名是否与目录内实际文件一致。", appID),
		}
		solutions = []string{
			fmt.Sprintf("补齐缺失的入口文件或修正 plugins/%s/plugin.json 中的文件名，保存后点击「重新扫描」。", appID),
		}
	default:
		checks = []string{
			fmt.Sprintf("打开 plugins/%s/plugin.json（以及可选的 env.json），核对 JSON 语法、字段类型与必填配置。", appID),
		}
		solutions = []string{
			"按上述报错提示修正配置文件后，回到应用中心点击「重新扫描」即可恢复加载。",
			"也可在 Mac 客户端「Docker 与应用 → MCP 控制台与调试」开启「允许本地 AI Agent (MCP) 接入」，交由 AI Agent 自动校验并修复插件清单。",
		}
	}

	return &AppDiagnostic{
		Summary:   "插件配置校验未通过：" + firstLineSummary(valErr, 120),
		Reason:    "读取插件清单或入口文件时发现配置问题：" + valErr,
		Checks:    checks,
		Solutions: solutions,
		DataSafe:  dataSafetyNote(appID),
	}
}

func buildPreStartDiagnostic(appID, entry, reason string) AppDiagnostic {
	if entry == "" {
		entry = "run-web.sh"
	}
	lower := strings.ToLower(reason)
	checks := []string{
		fmt.Sprintf("打开 plugins/%s 目录，检查 %s 与 env.json 是否存在且格式、权限正常。", appID, entry),
	}
	solutions := []string{
		fmt.Sprintf("确保 plugins/%s/%s 具备可执行权限（chmod 700）且首行解释器路径有效，随后点击「重新扫描」并重试唤醒。", appID, entry),
	}
	if strings.Contains(lower, "env.json") {
		checks = []string{
			fmt.Sprintf("打开 plugins/%s/env.json，检查是否为合法的扁平字符串键值 JSON（键名仅限字母、数字与下划线）。", appID),
		}
		solutions = []string{
			"修正 env.json 语法或非法键名后重新点击「唤醒启动」。",
		}
	}
	return AppDiagnostic{
		Summary:   "启动前检查未通过：" + firstLineSummary(reason, 100),
		Reason:    reason,
		Checks:    checks,
		Solutions: solutions,
		DataSafe:  dataSafetyNote(appID),
	}
}

func buildStartFailureDiagnostic(
	appID, entry, runtimeName, healthCheckPath string,
	port, readyTimeoutSec int,
	waitErr, procExitErr error,
	attemptOutput string,
) AppDiagnostic {
	if entry == "" {
		entry = "run-web.sh"
	}
	if readyTimeoutSec <= 0 {
		readyTimeoutSec = 15
	}
	excerpt := extractRelevantLogExcerpt(attemptOutput)
	lowerOut := strings.ToLower(attemptOutput)
	exitCode, exitText := formatExitStatus(procExitErr)

	// 1. Port hijacked / EADDRINUSE
	if errors.Is(waitErr, errPortNotOwned) ||
		strings.Contains(lowerOut, "eaddrinuse") ||
		strings.Contains(lowerOut, "address already in use") {
		return AppDiagnostic{
			Summary:    fmt.Sprintf("启动失败：本地端口 127.0.0.1:%d 被占用", port),
			Reason:     fmt.Sprintf("启动 %s 时目标端口 127.0.0.1:%d 已被本机其他进程占用，导致应用无法绑定监听。", entry, port),
			LogExcerpt: excerpt,
			Checks: []string{
				fmt.Sprintf("打开 plugins/%s/plugin.json 检查 web.port 是否配置了已被占用的固定端口。", appID),
				fmt.Sprintf("检查 %s 与应用代码是否读取了系统注入的 PORT 环境变量，而不是硬编码固定端口。", entry),
			},
			Solutions: []string{
				fmt.Sprintf("建议将 plugins/%s/plugin.json 中的 web.port 设为 0（由轻屿自动分配空闲回环端口），并在脚本中使用 $PORT 启动服务。", appID),
				"修改后点击「重新扫描」，再点击「唤醒启动」。",
			},
			DataSafe: dataSafetyNote(appID),
		}
	}

	// 2. Process exited before port/health became ready
	if errors.Is(waitErr, errProcessExitedEarly) {
		if strings.Contains(lowerOut, "operation not permitted") || strings.Contains(lowerOut, "permission denied") {
			return AppDiagnostic{
				Summary:    fmt.Sprintf("启动失败：脚本或目标目录访问权限不足（%s）", exitText),
				Reason:     fmt.Sprintf("执行 %s 时因系统权限受限退出（%s）：%s", entry, exitText, fallbackDetail(excerpt, "进程访问文件或执行脚本被拒绝")),
				LogExcerpt: excerpt,
				Checks: []string{
					fmt.Sprintf("查看下方错误摘录或「运行日志」，确认被拒绝访问的具体文件路径（如 %s 是否引用了文稿/桌面/外置卷目录）。", entry),
					fmt.Sprintf("检查 plugins/%s/%s 及所调用二进制文件是否具备可执行权限。", appID, entry),
				},
				Solutions: []string{
					fmt.Sprintf("若脚本引用了「文稿 / 桌面 / 下载」等受保护目录，请在「系统设置 → 隐私与安全性 → 文件与文件夹」允许 LightIsle 访问，或将插件代码直接放在 plugins/%s 目录内。", appID),
					fmt.Sprintf("若为脚本权限问题，执行 chmod 700 plugins/%s/%s 后重新唤醒。", appID, entry),
				},
				DataSafe: dataSafetyNote(appID),
			}
		}

		isMissingDepOrBuild := strings.Contains(lowerOut, "node_modules") ||
			strings.Contains(lowerOut, ".next") ||
			strings.Contains(lowerOut, ".venv") ||
			strings.Contains(lowerOut, "cannot find module") ||
			strings.Contains(lowerOut, "err_module_not_found") ||
			strings.Contains(lowerOut, "module_not_found") ||
			strings.Contains(lowerOut, "modulenotfounderror") ||
			strings.Contains(lowerOut, "no module named") ||
			strings.Contains(lowerOut, "importerror") ||
			(strings.Contains(lowerOut, "no such file or directory") && exitCode != 0)

		if isMissingDepOrBuild {
			buildHint := "在插件或对应项目目录安装依赖并完成构建（例如 Node/Next.js 项目执行 npm install && npm run build；Python 项目执行 python3 -m venv .venv && .venv/bin/pip install -r requirements.txt），完成后再点击「唤醒启动」。"
			if runtimeName == "python" {
				buildHint = "在插件目录创建虚拟环境并安装依赖（python3 -m venv .venv && .venv/bin/pip install -r requirements.txt），完成后再点击「唤醒启动」。"
			}
			return AppDiagnostic{
				Summary:    fmt.Sprintf("启动失败：缺少依赖包或构建产物（%s）", exitText),
				Reason:     fmt.Sprintf("执行 %s 后进程提前退出（%s），未能启动 Web 服务。日志表明缺少本地依赖、构建产物或脚本引用的目录不存在：%s", entry, exitText, fallbackDetail(excerpt, "请查看运行日志确认缺失文件")),
				LogExcerpt: excerpt,
				Checks: []string{
					"进入「管理与日志 / 运行日志」查看完整控制台输出，确认缺失的具体包名或文件路径。",
					fmt.Sprintf("打开 plugins/%s/%s，核对脚本中 cd 的项目路径、依赖目录（如 node_modules / .venv）及构建产物（如 .next / dist）是否已生成。", appID, entry),
				},
				Solutions: []string{
					buildHint,
					"也可在 Mac 客户端「Docker 与应用 → MCP 控制台与调试」开启「允许本地 AI Agent (MCP) 接入」，将插件交由本机 AI Agent 自动安装依赖并修复启动脚本。",
				},
				DataSafe: dataSafetyNote(appID),
			}
		}

		if exitCode == 127 || strings.Contains(lowerOut, "command not found") {
			return AppDiagnostic{
				Summary:    "启动失败：未找到插件所需的运行环境命令（退出码 127）",
				Reason:     fmt.Sprintf("执行 %s 时找不到对应的解释器或命令（%s）。轻屿默认在 /opt/homebrew/bin、/usr/local/bin 与系统目录查找命令：%s", entry, exitText, fallbackDetail(excerpt, "命令未找到")),
				LogExcerpt: excerpt,
				Checks: []string{
					"查看下方日志摘录或「运行日志」，确认提示 not found 的命令名称（如 node、python3、go、uv）。",
					"在终端执行 which <命令名>，检查该命令是否尚未安装，或仅位于 nvm / conda / pyenv 等用户私有目录。",
				},
				Solutions: []string{
					fmt.Sprintf("通过 Homebrew 安装对应运行时（如 brew install node 或 brew install python），或在 plugins/%s/%s 顶部显式导出运行时 PATH / 使用绝对路径调用解释器。", appID, entry),
					"修改保存后回到此处点击「唤醒启动」重试。",
				},
				DataSafe: dataSafetyNote(appID),
			}
		}

		if exitCode == 0 && procExitErr == nil {
			return AppDiagnostic{
				Summary:    "启动失败：启动脚本执行完毕后立即退出（未保持前台运行）",
				Reason:     fmt.Sprintf("启动脚本 %s 以退出码 0 正常结束，未持续监听分配端口 127.0.0.1:%d。轻应用 Web 入口必须保持前台常驻运行，不能后台化退出。", entry, port),
				LogExcerpt: excerpt,
				Checks: []string{
					fmt.Sprintf("打开 plugins/%s/%s，检查是否使用了 &、nohup、daemon 参数让服务转入后台后脚本提前结束。", appID, entry),
					"查看「运行日志」确认脚本是否在满足某个条件判断后提前 return / exit 0。",
				},
				Solutions: []string{
					fmt.Sprintf("将 %s 最后一行改为前台阻塞运行（例如 exec node server.js 或 exec python3 app.py），不要后台守护化，保存后重新点击「唤醒启动」。", entry),
				},
				DataSafe: dataSafetyNote(appID),
			}
		}

		return AppDiagnostic{
			Summary:    fmt.Sprintf("启动失败：应用进程启动阶段异常退出（%s）", exitText),
			Reason:     fmt.Sprintf("执行 %s 后进程在就绪前异常退出（%s），未能在 127.0.0.1:%d 提供服务。%s", entry, exitText, port, prefixedExcerptReason(excerpt)),
			LogExcerpt: excerpt,
			Checks: []string{
				"点击「管理与日志 / 运行日志」查看完整的 stdout / stderr 报错堆栈。",
				fmt.Sprintf("检查 plugins/%s/%s 启动参数与 env.json 环境变量配置是否正确。", appID, entry),
			},
			Solutions: []string{
				fmt.Sprintf("可在终端进入 plugins/%s 手动运行 PORT=18080 HOST=127.0.0.1 ./%s 复现并修复脚本报错，修复后点击「唤醒启动」。", appID, entry),
				"若需自动排障，可在 Mac 客户端「Docker 与应用 → MCP 控制台与调试」开启 MCP 开关并复制提示词交给本机 AI Agent 修复。",
			},
			DataSafe: dataSafetyNote(appID),
		}
	}

	// 3. Port bound, but HTTP healthCheckPath failed
	if errors.Is(waitErr, errHealthCheckFailed) {
		hc := healthCheckPath
		if hc == "" {
			hc = "/"
		}
		return AppDiagnostic{
			Summary:    fmt.Sprintf("启动失败：端口已监听，但健康检查 %s 未通过", hc),
			Reason:     fmt.Sprintf("应用进程已监听 127.0.0.1:%d，但在 %d 秒内请求健康检查路径 %s 持续失败（%v）。", port, readyTimeoutSec, hc, waitErr),
			LogExcerpt: excerpt,
			Checks: []string{
				"查看「运行日志」确认健康检查请求到达时后端是否抛出 500 异常（如数据库初始化失败）。",
				fmt.Sprintf("打开 plugins/%s/plugin.json，核对 web.healthCheckPath（当前为 %s）与服务实际路由前缀（/apps/%s）是否匹配。", appID, hc, appID),
			},
			Solutions: []string{
				"修复后端初始化报错，或在 plugin.json 中将 web.healthCheckPath 改为实际返回 200~404 的轻量路由（或留空仅检测端口连通），点击「重新扫描」后重新唤醒。",
			},
			DataSafe: dataSafetyNote(appID),
		}
	}

	// 4. Context canceled externally vs timeout waiting for port listen
	if errors.Is(waitErr, context.Canceled) {
		return AppDiagnostic{
			Summary:    "启动已取消：请求在应用就绪前中断",
			Reason:     fmt.Sprintf("等待 %s 启动期间请求被取消。", entry),
			LogExcerpt: excerpt,
			Checks:     []string{"确认核心服务未在重启，或浏览器未中途关闭请求。"},
			Solutions:  []string{"直接重新点击「唤醒启动」或「在浏览器打开」即可。"},
			DataSafe:   dataSafetyNote(appID),
		}
	}

	return AppDiagnostic{
		Summary:    fmt.Sprintf("启动超时：进程在 %d 秒内未监听分配端口 127.0.0.1:%d", readyTimeoutSec, port),
		Reason:     fmt.Sprintf("启动脚本 %s 已运行且未退出，但在 %d 秒内未在 127.0.0.1:%d 建立 TCP 监听。最常见原因是应用绑定了固定端口而未读取环境变量 PORT，或首次冷启动耗时超过 %d 秒。", entry, readyTimeoutSec, port, readyTimeoutSec),
		LogExcerpt: excerpt,
		Checks: []string{
			fmt.Sprintf("打开 plugins/%s/%s 与服务代码，检查是否使用环境变量 PORT（而非写死 3000/8000 等固定端口）并绑定在 127.0.0.1。", appID, entry),
			"查看「运行日志」观察服务实际打印的监听地址，或是否卡在首次编译 / 外部网络请求。",
		},
		Solutions: []string{
			"修改启动脚本使服务严格监听 127.0.0.1:$PORT（例如 --host 127.0.0.1 --port \"$PORT\"）。",
			fmt.Sprintf("若服务正常但冷启动较慢，可在 plugins/%s/plugin.json 中调大 web.readyTimeoutSeconds（最大 120 秒），点击「重新扫描」后再唤醒。", appID),
		},
		DataSafe: dataSafetyNote(appID),
	}
}

func buildRuntimeCrashDiagnostic(appID, entry, lastErr, logsTail string) *AppDiagnostic {
	lastErr = strings.TrimSpace(lastErr)
	if lastErr == "" {
		return nil
	}
	if entry == "" {
		entry = "run-web.sh"
	}
	excerpt := extractRelevantLogExcerpt(logsTail)
	return &AppDiagnostic{
		Summary:    lastErr,
		Reason:     fmt.Sprintf("轻应用运行期间子进程异常中断（%s）。%s", lastErr, prefixedExcerptReason(excerpt)),
		LogExcerpt: excerpt,
		Checks: []string{
			"进入「管理与日志 / 运行日志」查看崩溃前的最后一段错误堆栈或内存超限提示（如 JavaScript heap out of memory）。",
			fmt.Sprintf("检查 plugins/%s/%s 中的内存限制参数（如 NODE_OPTIONS）与外部设备/网络连接超时处理。", appID, entry),
		},
		Solutions: []string{
			"点击「唤醒启动」可立即恢复服务运行；若因内存上限过低导致退出，可适当调大启动脚本中的堆内存参数。",
		},
		DataSafe: dataSafetyNote(appID),
	}
}

func fallbackDetail(excerpt, fallback string) string {
	if line := firstLineSummary(excerpt, 180); line != "" {
		return line
	}
	return fallback
}

func prefixedExcerptReason(excerpt string) string {
	if line := firstLineSummary(excerpt, 180); line != "" {
		return "最近错误输出：" + line
	}
	return ""
}

func requestPrefersHTML(r *http.Request) bool {
	if r == nil || r.Method != http.MethodGet {
		return false
	}
	accept := strings.ToLower(r.Header.Get("Accept"))
	return strings.Contains(accept, "text/html")
}

var gatewayErrorPageTmpl = template.Must(template.New("gateway_error").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Title}} · 轻屿 LightIsle</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f5f6fa;
    --card: #ffffff;
    --border: rgba(15, 23, 42, 0.09);
    --text: #0f172a;
    --muted: #64748b;
    --warn-bg: rgba(245, 158, 11, 0.10);
    --warn-text: #b45309;
    --ok-bg: rgba(16, 185, 129, 0.10);
    --ok-text: #047857;
    --code-bg: rgba(15, 23, 42, 0.05);
    --accent: #4f46e5;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b1020;
      --card: #131b2e;
      --border: rgba(255, 255, 255, 0.10);
      --text: #f1f5f9;
      --muted: #94a3b8;
      --warn-bg: rgba(245, 158, 11, 0.16);
      --warn-text: #fbbf24;
      --ok-bg: rgba(16, 185, 129, 0.16);
      --ok-text: #34d399;
      --code-bg: rgba(0, 0, 0, 0.32);
      --accent: #6366f1;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 18px; background: var(--bg); color: var(--text);
    font: 14px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
    display: flex; justify-content: center; align-items: flex-start; min-height: 100vh;
  }
  .card {
    width: 100%; max-width: 680px; background: var(--card);
    border: 1px solid var(--border); border-radius: 18px; padding: 24px 26px;
    box-shadow: 0 12px 32px rgba(15, 23, 42, 0.07);
  }
  .badge {
    display: inline-block; font-size: 12px; font-weight: 600; padding: 3px 10px;
    border-radius: 999px; background: var(--warn-bg); color: var(--warn-text);
  }
  h1 { font-size: 19px; margin: 12px 0 6px; }
  .safe {
    margin: 10px 0 18px; padding: 9px 12px; border-radius: 10px;
    background: var(--ok-bg); color: var(--ok-text); font-size: 12.5px; font-weight: 500;
  }
  h2 { font-size: 13.5px; margin: 16px 0 6px; color: var(--text); }
  p { margin: 0 0 8px; color: var(--muted); }
  pre {
    margin: 8px 0 12px; padding: 11px 13px; border-radius: 10px;
    background: var(--code-bg); overflow-x: auto;
    font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
    white-space: pre-wrap; word-break: break-word;
  }
  ol { margin: 4px 0 12px; padding-left: 20px; color: var(--muted); }
  li { margin-bottom: 5px; }
  .actions { margin-top: 20px; display: flex; gap: 10px; flex-wrap: wrap; }
  button {
    appearance: none; border: 0; border-radius: 999px; padding: 9px 18px;
    background: var(--accent); color: #fff; font-weight: 600; font-size: 13px; cursor: pointer;
  }
</style>
</head>
<body>
  <main class="card">
    <span class="badge">轻应用未能启动</span>
    <h1>{{.Title}}</h1>
    <div class="safe">{{.DataSafe}}</div>
    <h2>问题原因</h2>
    <p>{{.Reason}}</p>
    {{if .LogExcerpt}}<pre>{{.LogExcerpt}}</pre>{{end}}
    {{if .Checks}}
      <h2>如何排查</h2>
      <ol>{{range .Checks}}<li>{{.}}</li>{{end}}</ol>
    {{end}}
    {{if .Solutions}}
      <h2>解决办法</h2>
      <ol>{{range .Solutions}}<li>{{.}}</li>{{end}}</ol>
    {{end}}
    <div class="actions">
      <button type="button" onclick="window.location.reload()">修复后重新尝试打开</button>
    </div>
  </main>
</body>
</html>`))

func writeGatewayDiagnosticError(w http.ResponseWriter, r *http.Request, status int, code, appName, appID string, isAdmin bool, diag *AppDiagnostic, fallbackMsg string) {
	if !requestPrefersHTML(r) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(status)
		payload := map[string]any{
			"error":   code,
			"message": fallbackMsg,
		}
		if isAdmin && diag != nil {
			payload["diagnostic"] = diag
		}
		if !isAdmin {
			payload["message"] = "该轻应用暂时无法启动，你的个人数据不受影响，请联系管理员处理。"
		}
		_ = json.NewEncoder(w).Encode(payload)
		return
	}

	setAppGatewayHeaders(w.Header())
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)

	displayName := strings.TrimSpace(appName)
	if displayName == "" {
		displayName = appID
	}

	if !isAdmin {
		_ = gatewayErrorPageTmpl.Execute(w, map[string]any{
			"Title":     fmt.Sprintf("「%s」暂时无法打开", displayName),
			"DataSafe":  "你的个人空间与家庭应用数据均完好无损。",
			"Reason":    "该轻应用的后台服务当前未能正常启动。",
			"Checks":    []string{"确认网络连接正常后点击下方按钮重试。"},
			"Solutions": []string{"若重试后仍无法打开，请联系家庭管理员在「应用中心」查看运行日志并修复插件依赖或配置。"},
		})
		return
	}

	if diag == nil {
		d := buildRuntimeCrashDiagnostic(appID, "run-web.sh", fallbackMsg, "")
		diag = d
	}
	reason := fallbackMsg
	dataSafe := dataSafetyNote(appID)
	var logExcerpt string
	var checks, solutions []string
	if diag != nil {
		if diag.Reason != "" {
			reason = diag.Reason
		}
		if diag.DataSafe != "" {
			dataSafe = diag.DataSafe
		}
		logExcerpt = diag.LogExcerpt
		checks = diag.Checks
		solutions = diag.Solutions
	}

	_ = gatewayErrorPageTmpl.Execute(w, map[string]any{
		"Title":      fmt.Sprintf("无法启动「%s」(%s)", displayName, appID),
		"DataSafe":   dataSafe,
		"Reason":     reason,
		"LogExcerpt": logExcerpt,
		"Checks":     checks,
		"Solutions":  solutions,
	})
}

func verifyPortOwnedByInstance(port, pid, pgid int) bool {
	if port <= 0 || pid <= 0 {
		return true
	}
	lsofBin := "/usr/sbin/lsof"
	if _, err := os.Stat(lsofBin); err != nil {
		if found, lookErr := exec.LookPath("lsof"); lookErr == nil {
			lsofBin = found
		} else {
			return true
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, lsofBin, "-nP", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-Fp").Output()
	if err != nil || len(out) == 0 {
		return true
	}
	var listenerPIDs []int
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "p") {
			if p, convErr := strconv.Atoi(strings.TrimPrefix(line, "p")); convErr == nil && p > 0 {
				listenerPIDs = append(listenerPIDs, p)
			}
		}
	}
	if len(listenerPIDs) == 0 {
		return true
	}
	for _, lpid := range listenerPIDs {
		if lpid == pid || lpid == pgid {
			return true
		}
		psOut, psErr := exec.Command("/bin/ps", "-o", "pgid=,ppid=", "-p", strconv.Itoa(lpid)).Output()
		if psErr == nil {
			fields := strings.Fields(string(psOut))
			for _, f := range fields {
				if v, convErr := strconv.Atoi(f); convErr == nil && (v == pid || v == pgid) {
					return true
				}
			}
		}
	}
	return false
}
