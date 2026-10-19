# M1 实现与验收记录

> 更新：2026-10-19。项目处于开发预览阶段，未对外发布。Mac App 仅支持 Apple Silicon macOS arm64；Flutter Android 暂未创建。

## 已经有代码的部分

| 子系统 | 文件 | 状态 |
| --- | --- | --- |
| macOS SwiftUI App | `Package.swift`、`apps/macos/Sources/LightIsle/` | **已编译**，导航/设置页面、Go Core 进程监督 |
| 内置 Go Core | `core/cmd/lightisled` | **已编译/测试**，本机随机端口 API |
| macOS 系统采样 | `core/internal/system/metrics_darwin_arm64.go` | **已测试**，通过 Mach 接口读取 CPU、内存；系统卷剩余空间 |
| HTTP 后端 | `core/internal/server/` | **已测试**，`GET /api/v1/health`、`GET /api/v1/system`、静态 Web |
| Vue3 总览 | `apps/web/` | **已构建**，真实数据、浅深主题、响应式概览 |
| 单一应用打包 | `scripts/build-macos.sh` | **已执行成功**，生成 `dist/LightIsle.app`，ad-hoc 本地签名 |
| 生命周期冒烟 | `tests/test_app_lifecycle.py` | **已通过**，服务启动、HTTP、父进程管道 EOF 后退出和端口释放 |
| Design Tokens | `design-tokens/tokens.json` | 首版草案，已用于 Vue 主题；SwiftUI 用原生系统色材质 |

## 已验证的环境与命令

开发机环境（已在 leo-coding Workspace 确认）：
- Go 1.26.1 `darwin/arm64`。
- Xcode 27.0。
- Node.js v26.3.0、npm。
- SwiftUI `swift build -c debug` 编译成功。
- `go test ./...` 通过。
- `npm run build --prefix apps/web` 通过；生产 Web JS ~80 KB（不含运行时/系统 WebKit），不等于完整 App 资源占用。
- `bash scripts/build-macos.sh` 完成完整 App 打包、开发签名与 Info.plist 验证。
- `python3 tests/test_app_lifecycle.py` 打包后后端启动/退出冒烟测试通过。

本地开发启动：

```bash
cd /Users/leo/Documents/code/Lightlsle
bash scripts/build-macos.sh
open dist/LightIsle.app
```

打开后切到 **概览** 查看 CPU/内存/系统卷；切到 **设置** 可查看服务状态及本地 URL。关闭最后一个窗口或按 **⌘Q** 按照设计终止内置服务。

## 安全状态（不可误解）

- Go 服务**仅绑定 127.0.0.1 的随机端口**，不提供 LAN/公网监听。
- 目前 **没有用户登录、SQLite 持久化、设备配对、TLS 或高权限管理**，所以不能对外网开放。
- 文件、图库、影视只显示“开发中”入口，**不会实际读写用户数据**。
- Docker、Swift 特权 Helper、图库索引与 FFmpeg 均未引入常驻服务。
- 开发 App 是 ad-hoc 本地签名，不是 Developer ID、公证或上架版本。

## 仍需完成的 M1 任务（优先级）

1. **GUI 实机运行回归**：真实打开 `dist/LightIsle.app`，核验 SwiftUI 与 WKWebView 能加载，最小化/关窗/⌘Q、强制退出均无 Go 残留（目前仅 Go 父管道 EOF 已自动化验证）。
2. **初始化与认证**：SQLite migrations、管理员首次初始化、密码安全存储、Web 授权与会话撤销。
3. **Android 安全远程访问**：必须先完成认证/配对与 TLS，再允许启用 LAN API，不允许未经认证直接监听 0.0.0.0。
4. **完整原生系统控制台**：将概览 WebView、原生侧边栏与状态栏统一导航；修复真实 UI 测试中的布局/主题问题。
5. **指标扩展与真实性**：网络速率、多卷磁盘信息、进程状态；严格区分“未知”与“0”。
6. **SwiftUI 真正退出机制完善**：异常 PID/心跳二次保护、端到端 GUI 行为测试、重复启动保护和核心崩溃恢复。
7. **性能基线**：记录 SwiftUI + WKWebView/渲染进程 + Go 的总 RSS/CPU 与窗口关闭资源释放。
8. **发行构建**：完整图标、正式版本号、最低 macOS 验收、Developer ID 签名/公证为后续 M7 范围。

## 里程碑定义

M1 只有在 **Mac App 实机完整生命周期、首次管理员初始化、Android 手机经安全配对远程连接、系统指标和基本视觉测试** 均通过后才可标记完成。当前只是 M1 的**首个可构建开发版**。

参阅：[路线图](ROADMAP.md)、[Mac App 生命周期](MACOS_APP.md)、[开发指南](DEVELOPMENT.md)。

