# 开发指南

> 当前阶段为 M1 开发中。Mac SwiftUI、Go ARM64 后端、Vue 3 和本地 .app 打包脚本已存在；完整 NAS 和远程 Android 功能尚未完成。
>
> **目标后端：仅 macOS arm64。** 不做 Linux/Windows/macOS x86_64 后端。Flutter 客户端暂定 Android。用户双击 Mac App 启动 Go Core，完全退出 App 必须结束 Go。三端统一 iOS 27 视觉风格。

## 1. 开发环境与构建目标

- 开发和测试主机：Apple Silicon Mac，`uname -m` 预期显示 `arm64`。
- 后端：当前 Go 1.26，构建环境固定 `GOOS=darwin GOARCH=arm64`。
- 原生应用：Xcode、SwiftUI + AppKit，仅负责 Mac 原生初始化、系统监控、服务/存储设置及 Go 子进程启停；不使用 WKWebView 用户页面。
- Web：Node.js、npm、Vue 3、TypeScript、Vite；使用 `apps/web/package-lock.json` 锁依赖。在独立浏览器/PWA 中实现登录、用户管理、文件、图库与后续影视。
- Flutter：Android SDK、Flutter stable；暂不构建 iOS/macOS/Windows 客户端。
- SQLite：内嵌数据库（WAL）；迁移版本与后端发行版本关联。
- FFmpeg / Colima：开发环境可安装以测试，但不作为基础 NAS 后端启动前置条件。
- 设计规范：采用 [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)，基于 Apple iOS 27 / macOS 27 Liquid Glass 的布局、组件和视觉层级；优先轻量、可读与无障碍。

已验证的 macOS 内嵌后端构建命令：

```sh
# 在 Apple Silicon macOS 上构建
GOOS=darwin GOARCH=arm64 go build -o dist/lightisled ./core/cmd/lightisled
```

推荐统一使用 `bash scripts/build-macos.sh` 生成可安装的开发版 `dist/LightIsle.app`。也可运行 `bash scripts/verify-macos.sh` 进行自动化检查。

## 2. 推荐仓库结构

- `core/`：Go 模块化单体，`cmd/lightisled` 启动、`internal` 各业务模块、`migrations` SQLite 迁移。
- `apps/macos/`：SwiftUI/AppKit 原生管理端，包含首次管理员初始化、系统监控、原生设置、Go 子进程生命周期管理。
- `native/macos-arm64/`：Swift 系统 Worker、特权 Helper、安装流程。
- `apps/web/`：Vue 3 + TS + PWA，桌面与 Android 浏览器共用。
- `apps/android/`：Flutter Android（M6 后才建立，非当前必需）。
- `contracts/openapi.yaml`：服务端 API 唯一契约，TypeScript/Dart 客户端生成。
- `tests/`：API、文件、权限、媒体端到端；`benchmarks/`：RSS / CPU / 延迟 / 索引耗时。
- `packaging/macos-arm64/`：单一 LightIsle.app、嵌入 Go Core、签名与升级脚本，不能注册独立常驻 NAS launchd 服务。
- `design-tokens/`（M1 建立）：语义主题 token 源文件与 SwiftUI / Vue / Flutter 映射生成工具。
- `docs/`：产品、架构、路线、性能、安全、后续 ADR 与故障排查。

**不要**为了跨平台兼容创建无实际用途的 `platform/linux`、`platform/windows` 或 x86_64 构建矩阵。macOS 的系统调用集中在 `native/macos-arm64` 与 Go 的少数基础设施模块中，仅用于权限与可测试性隔离，而非预留别的平台。

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
- Swift Helper 只暴露有类型参数的白名单动作，不接受任意命令字符串。
- SwiftUI 主应用是 Go Core 的唯一生命周期拥有者：正常退出发送 shutdown，异常退出时 Go 通过 EOF/父进程存活检测主动停止；未启动 App 时不得存在独立 LightIsle NAS 服务。
- macOS Swift 工作进程失败时核心 API 可退化并报告功能不可用，不应拖垮文件访问。
- 三端 UI 共享同一设计 token、组件状态和语义色；玻璃效果只用于导航/控件，不对大量图片、文件行和文字内容叠加实时模糊。
- Web 与 Flutter 的状态显示不能代替服务器端鉴权。

## 4. API 与契约设计

- 统一 `/api/v1/...`，OpenAPI schema 版本化、兼容性变更需标记。
- 认证使用短期会话、设备授权与撤销；涉及敏感数据禁止 URL query 存 token。
- 错误格式：`{code, message, request_id, details}`；服务器日志须脱敏。
- 列表统一 cursor 分页，限制最大 limit；大文件下载支持 Range；上传续传需校验。
- 任务响应 `202 Accepted` + task_id，状态/进度由 REST 和事件流提供。
- 对外 API 字段用英文稳定命名；面向用户的 UI 文案先中文，保留 i18n 结构。
- OpenAPI 变更必须更新 TS 客户端；M6 开始维护 Dart 客户端生成。

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

M1 结束前不要优先开发大量桌面动画、复杂图标组件或 AI 相册特性。

## 7. 测试要求

- **单元测试**：路径与授权判定、媒体识别、任务状态、数据库迁移。
- **集成测试**：真实临时数据根目录、SQLite、HTTP API；用临时卷模拟离线/恢复。
- **macOS arm64 真机**：磁盘信息、FSEvents、Swift Worker、VideoToolbox、App/Go 子进程生命周期和签名权限。
- **Web E2E**：桌面浏览器与 Android 实机/浏览器，文件、图库、播放器主流程。
- **视觉 E2E**：Mac、Web、Android 的日夜主题、减少透明、动态效果与低配设备渲染压力。
- **破坏性操作**：用专门测试外置盘/卷运行，永不对开发机系统盘做擦除实验。
- **性能回归**：记录 Git commit、OS/硬件、样本数据大小、CPU/RSS/吞吐/耗时。
- **故障注入**：断网、外接盘拔出、任务被 kill、系统重启、磁盘空间不足。

## 8. 推荐 PR/提交准则

- 提交尽量按模块/阶段拆分：core 基础、auth、system、web、files、photos 等。
- 不把安装包、数据库、缓存、密钥或用户媒体文件纳入 Git。
- 每个阶段合并前：有测试结果、风险说明、文档同步及性能影响评估。
- 使用功能状态“规划/开发中/已验证”三态，不让 README 宣称尚未完成的能力。

## 9. 待定 ADR

M1 第一批应记录设计决策（`docs/adr/`）：
1. 最低支持的 macOS 版本与 Swift Helper 机制。
2. Go 与 Swift 间 IPC 协议及特权验证。
3. 首次管理员初始化与 Android 设备配对。
4. 数据目录、缓存目录、数据库备份目录默认策略。
5. 文件稳定身份与外接卷离线恢复策略。
6. 图片工作进程与 FFmpeg 的生命周期控制。
7. SwiftUI App 对 Go Core 的子进程监督、父进程死亡检测及远程监听策略。
8. 三端设计系统 tokens 与 Liquid Glass 的兼容/性能回退策略。

参阅 [Mac App 生命周期](MACOS_APP.md)、[设计系统](DESIGN_SYSTEM.md)、[路线图](ROADMAP.md)、[架构](ARCHITECTURE.md)、[性能](PERFORMANCE.md)、[安全](SECURITY.md)。

