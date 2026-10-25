# 开发指南

> 当前阶段：M1–M5 开发预览。Mac SwiftUI、Go arm64 后端、Vue 3 Web、打包脚本和打包冒烟测试均已存在；文件、图库、影视、账号与备份主流程有代码和自动化测试，但**真实 GUI、外置盘、规模/72 小时、Android 实机和签名公证验收尚未完成**。当前状态以 [P0 实施与验证状态](STATUS.md) 为准；[M1_STATUS.md](HISTORY.md) 是历史快照。
>
> **目标后端：仅 macOS arm64。** 不做 Linux/Windows/macOS x86_64 后端。Flutter Android、iOS、macOS 客户端**已位于 `apps/flutter`**，仍是独立用户端开发预览；Docker/Colima 是可选扩展。Mac App 启动 Go Core，完全退出 App 必须结束 Go。真实设备与正式发布门禁参见 [STATUS](STATUS.md)。

## 1. 开发环境与构建目标

- 开发和测试主机：Apple Silicon Mac，`uname -m` 预期显示 `arm64`；构建脚本会拒绝其他架构。
- 后端：当前 Go 1.26（`go.mod` 为 `go 1.26.0`），构建环境固定 `GOOS=darwin GOARCH=arm64`。
- 原生应用：Swift 6 工具链 / Xcode 27、SwiftUI + AppKit，`Package.swift` 平台为 macOS 14；仅负责 Mac 原生初始化、系统监控、服务/存储设置及 Go 子进程启停；不使用 WKWebView 用户页面。
- Web：Node.js 22+、npm、Vue 3、TypeScript、Vite；使用 `apps/web/package-lock.json` 锁依赖。在独立浏览器/PWA 中实现登录、用户管理、文件、图库与影视。
- Flutter：`apps/flutter` 已包含 Android、macOS、iOS 用户客户端，使用 Flutter stable 及对应 Android SDK/Xcode 构建；独立构建与验证见 [FLUTTER_CLIENT.md](FLUTTER_CLIENT.md)。Windows 不作为本项目承诺的后端平台。
- SQLite：内嵌数据库（WAL）；各数据库在启动时建表，尚无独立版本化 migration 框架。
- FFmpeg / Colima：开发环境可安装以测试，但不作为基础 NAS 后端启动前置条件，也不是本版本发布阻断项。
- 设计规范：采用 [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)，基于 Apple iOS 27 / macOS 27 Liquid Glass 的布局、组件和视觉层级；优先轻量、可读与无障碍。

已验证的 macOS 内嵌后端构建命令：

```sh
# 在 Apple Silicon macOS 上构建
GOOS=darwin GOARCH=arm64 go build -o dist/lightisled ./core/cmd/lightisled
```

推荐统一使用 `bash scripts/build-macos.sh` 生成开发版 `dist/LightIsle.app`（含 Go 测试、Swift 构建、Web 构建与打包冒烟）。也可运行 `bash scripts/verify-macos.sh` 进行自动化检查。两者都不产生可发布的签名/公证包。

## 2. 仓库结构与规划目录

**当前实际存在：**

- `core/`：Go 模块化单体，`cmd/lightisled` 启动、`cmd/lightisle-recovery` 离线恢复、`internal` 各业务模块。SQLite 表在各自包启动时创建，当前**没有** `core/migrations/` 目录。
- `apps/macos/`：SwiftUI/AppKit 原生管理端（`Package.swift` 的 target 指向 `apps/macos/Sources/LightIsle`），包含管理员初始化、系统监控、原生设置和 Go 子进程生命周期管理。
- `apps/web/`：Vue 3 + TS + PWA，桌面与 Android 浏览器共用。
- `tests/`：打包后的 Python 冒烟测试（生命周期、初始化、备份、跨卷复制、恢复、影视、品牌资源）。
- `scripts/`：构建、开发签名、发布门禁和 QA 报告校验脚本。
- `design-tokens/`：语义主题 token 源文件；SwiftUI 仍主要使用系统色/材质。
- `docs/`：产品、架构、路线、M5 运维、生产发布、状态与安全文档。

**规划中、尚未创建（不要按现状引用）：**

- `native/macos-arm64/`：Swift 系统 Worker、特权 Helper、安装流程。Swift 目前全部在 `apps/macos`。
- `apps/android/`：Flutter Android，M6 之后才建立。
- `contracts/openapi.yaml`：服务端 API 契约与 TypeScript/Dart 客户端生成。
- `benchmarks/`：RSS / CPU / 延迟 / 索引耗时基准。
- `packaging/macos-arm64/`：当前打包逻辑在 `scripts/build-macos.sh` 与 `scripts/release-macos.sh`，产物在 `dist/`。
- `docs/adr/`：架构决策记录。

**不要**为了跨平台兼容创建无实际用途的 `platform/linux`、`platform/windows` 或 x86_64 构建矩阵。macOS 的系统调用集中在 `apps/macos`、`core/internal/system` 和 Go 的少数基础设施模块中，仅用于权限与可测试性隔离，而非预留别的平台。

## 3. 分层与依赖方向

```text
HTTP API / WS events
      ↓
业务应用层（Auth/Files/Photos/Cinema/Tasks/System）
      ↓
存储索引与 macOS 基础设施服务
      ↓
SQLite / 安全文件访问 / Swift IPC / OS API
```

- HTTP Handler 不能直接拼 Shell 命令、修改磁盘或访问任意文件路径。
- 文件、图库、影视共用受保护的文件域服务，图库/影视只保存派生元数据。
- API 层返回 task ID 处理长时任务；不在 HTTP 请求线程里做整个扫描/转码。
- Swift Helper 只暴露有类型参数的白名单动作，不接受任意命令字符串（Helper 尚未创建）。
- SwiftUI 主应用是 Go Core 的唯一生命周期拥有者：正常退出发送 shutdown，异常退出时 Go 通过 EOF/父进程存活检测主动停止；未启动 App 时不得存在独立 LightIsle NAS 服务。
- macOS Swift 工作进程失败时核心 API 可退化并报告功能不可用，不应拖垮文件访问。
- 三端 UI 共享同一设计 token、组件状态和语义色；玻璃效果只用于导航/控件，不对大量图片、文件行和文字内容叠加实时模糊。
- Web 与 Flutter 的状态显示不能代替服务器端鉴权。

## 4. API 与契约设计

> 当前 API 尚未导出 OpenAPI 文件，也没有生成的 TS/Dart 客户端；下面是目标约定。现有实现使用 Go 标准库 `net/http`，错误体以 `{"error":"code"}` 为主。

- 统一 `/api/v1/...`，OpenAPI schema 版本化、兼容性变更需标记。
- 认证使用短期会话、设备授权与撤销；涉及敏感数据禁止 URL query 存 token。当前 Web 会话固定最长 30 天，停用账号、重置首任管理员密码或退出会撤销相关会话；尚无设备配对/设备级撤销。
- 错误格式：`{code, message, request_id, details}`；服务器日志须脱敏。
- 列表统一 cursor 分页，限制最大 limit；大文件下载支持 Range；上传续传需校验。
- 任务响应 `202 Accepted` + task_id，状态/进度由 REST 和事件流提供。
- 对外 API 字段用英文稳定命名；面向用户的 UI 文案先中文，保留 i18n 结构。
- OpenAPI 变更必须更新 TS 客户端；M6 开始维护 Dart 客户端生成（目录尚未创建）。

## 5. 编码约定

- Go：`gofmt`、`go vet`、`go test`、错误返回可追踪上下文；无穷 goroutine、无上限任务队列禁止。
- Swift：明确线程模型，文件/媒体异步处理不阻塞 IPC，签名与身份校验保持在调用链。
- SwiftUI：原生导航、工具栏与系统 Liquid Glass 材质优先；Mac 管理端不渲染文件/图库/影视，避免双端业务维护。
- Vue：严格 TypeScript、按需路由加载、列表虚拟滚动、移动端触控面积与可访问性。
- Flutter：功能模块 + Repository/Service 分层；保留 Android 返回/权限交互；避免 Android UI 内复制后端业务规则。
- 视觉：支持 light/dark、reduce transparency、reduce motion；共享 Design Tokens 的变更应检查 Mac / Web / Android 映射的一致性。
- SQLite schema 所有变更必须带正向 migration 和恢复策略；禁止直接覆盖用户数据库。
- 代码评审关注权限、TOCTOU、符号链接、外接卷变化、备份与任务恢复。
- 日志不得记录密码、完整访问令牌、用户原始媒体内容；调试日志有级别和大小上限。

## 6. M1 首轮任务拆分（按依赖顺序）

> M1 立项时的拆分；多数代码已经存在。完成情况请参见 [P0 实施与验证状态](STATUS.md)，不要把下表当作当前进度。

| 顺序 | 实施任务 | 交付与验证 |
| --- | --- | --- |
| 1 | SwiftUI Mac App 最小可启动工程 | 应用窗口、App/Go 子进程生命周期、退出清理与错误页面 |
| 2 | Go module / main / 配置 / 健康检查 | App 启动 Go；`GET /api/v1/health` 有版本和服务状态 |
| 3 | SQLite 初始化及迁移 | 首次启动建表；重新打开 App 后数据保留 |
| 4 | 用户初始化与登录 | 未授权请求 401/403，设备会话可撤销 |
| 5 | macOS arm64 系统指标 | CPU/内存/磁盘数据来自真机，支持无数据降级 |
| 6 | 设计 token + 独立 Vue Web | SwiftUI 只保留本机初始化/监控/设置；文件图库影视由 Web 承担，统一 iOS 27 风格 |
| 7 | Web Android 浏览器适配 | Android Chrome 竖屏登录；远程访问需 Mac App 正在运行 |
| 8 | App 退出与崩溃验收 | ⌘Q/关闭最后窗口后 Go 及端口结束；kill App 后不留孤儿进程 |
| 9 | CI/本机验收与性能基线 | 单元/集成测试，统计 SwiftUI + Go 的真实空闲占用，Web 在浏览器单独测量 |

M1 结束前不要优先开发大量桌面动画、复杂图标组件或 AI 相册特性。Flutter Android 原生客户端不属于 M1–M5 的 macOS 发布阻断项。

## 7. 测试要求

- **单元测试**：路径与授权判定、媒体识别、任务状态、数据库表初始化与离线激活。
- **集成测试**：真实临时数据根目录、SQLite、HTTP API；用临时目录模拟离线/恢复。
- **打包冒烟**：`tests/*.py` 通过内置 Core 的私有 IPC 和真实 HTTP 端口验证生命周期、备份、跨卷复制、恢复和影视流程；这仍不是 GUI 或物理盘测试。
- **macOS arm64 真机**：磁盘信息、FSEvents、VideoToolbox、App/Go 子进程生命周期、Touch ID 和签名权限。
- **Web E2E**：桌面浏览器与 Android 实机/浏览器，文件、图库、播放器主流程。
- **视觉 E2E**：Mac、Web、Android 的日夜主题、减少透明、动态效果与低配设备渲染压力。
- **破坏性操作**：用专门测试外置盘/卷运行，永不对开发机系统盘做擦除实验。
- **性能回归**：记录 Git commit、OS/硬件、样本数据大小、CPU/RSS/吞吐/耗时。
- **故障注入**：断网、外接盘拔出、任务被 kill、系统重启、磁盘空间不足。
- **缓存**：缩略图缓存上限、命中、源变更失效和 LRU 淘汰顺序；设置只来自 Mac 本机。
- **会话**：登录、过期、退出、停用账号和重置管理员密码后的会话失效；Cookie 与数据库期限一致。

## 8. 推荐 PR/提交准则

- 提交尽量按模块/阶段拆分：core 基础、auth、system、web、files、photos 等。
- 不把安装包、数据库、缓存、密钥或用户媒体文件纳入 Git。
- 每个阶段合并前：有测试结果、风险说明、文档同步及性能影响评估。
- 使用“规划 / 已实现 / 自动化覆盖 / 人工验收通过”四态，不要让 README 把“已实现”写成“已验收”。

## 9. 待定 ADR

以下决策应记录到 `docs/adr/`（该目录**尚未创建**）：

1. 最低支持的 macOS 版本与 Swift Helper 机制。
2. Go 与 Swift 间 IPC 协议及特权验证（当前为私有 stdin/stdout 文本协议，尚无正式 ADR）。
3. 首次管理员初始化与 Android 设备配对。
4. 数据目录、缓存目录、数据库备份目录默认策略。
5. 文件稳定身份与外接卷离线恢复策略。
6. 图片工作进程与 FFmpeg 的生命周期控制。
7. SwiftUI App 对 Go Core 的子进程监督、父进程死亡检测及远程监听策略。
8. 三端设计系统 tokens 与 Liquid Glass 的兼容/性能回退策略。
9. 跨卷移动的可恢复事务与成功恢复后的一键回滚（当前均未实现）。

参阅 [Mac App 生命周期](MACOS_APP.md)、[设计系统](DESIGN_SYSTEM.md)、[路线图](ROADMAP.md)、[架构](ARCHITECTURE.md)、[性能](PERFORMANCE.md)、[安全](SECURITY.md)、[P0 实施与验证状态](STATUS.md)。

