# LightIsle 开发指南

> 面向当前 macOS arm64 服务端和独立 Web/Flutter 用户客户端。**代码已存在不等于真实设备验收通过。** 当前实现与缺口统一见 [STATUS](STATUS.md)，签名、公证、真机 QA 规则见 [PRODUCTION_RELEASE](PRODUCTION_RELEASE.md)。

## 本地开发环境

- **主机**：Apple Silicon Mac；后端目标固定 `GOOS=darwin GOARCH=arm64`，不提供 Linux/Windows/x86_64 服务端构建。
- **Go**：以 `go.mod` 中的 Go 版本为准（当前 1.26），使用 SQLite WAL 和 macOS 系统 API。
- **Swift**：Xcode/Swift 6、SwiftUI + AppKit；部署目标以 `Package.swift` 为准。`LightIsle.app` 负责 Go Core 进程与 Mac 本地管理员/磁盘操作，不能用公开 HTTP 代替 Mac 本机授权。
- **Web**：Node.js 与 npm、Vue 3、TypeScript、Vite，锁文件 `apps/web/package-lock.json`。
- **Flutter**：`apps/flutter` 已支持 Android/macOS/iOS 用户客户端；构建与权限流程见 [FLUTTER_CLIENT](FLUTTER_CLIENT.md)。
- **可选依赖**：FFmpeg、Docker Desktop/Colima、smartctl、cloudflared 不是启动 NAS 的必要条件；代码必须提供可理解的缺失/无权限提示。

## 快速从源码构建与运行

确保已安装 **Go 1.26+、Xcode/Swift 6、Node.js 与 npm**。可选安装 Flutter（若需构建移动/多端客户端）。

```bash
# 1. 克隆代码仓库
git clone https://github.com/lengsukq/LightIsle.git
cd LightIsle

# 2. 本地开发与热更新（推荐）
./dev-macos.sh

# 3. 或执行全量发布打包（包含发行门禁测试与 DMG 制作）
bash scripts/build-macos.sh
open dist/LightIsle.app
```

单独构建 Go Core：`GOOS=darwin GOARCH=arm64 go build -o dist/lightisled ./core/cmd/lightisled`。构建的本机 ad-hoc 签名 App 不能作为已公证发行包。

## 本地测试与质量验证

```bash
# Go 单元测试与代码检查
go test -race ./...
go vet ./...

# Mac 原生与集成冒烟验证
bash scripts/verify-macos.sh

# Web 端构建与测试
cd apps/web
npm test
npm run build
cd ../..

# Flutter 客户端检查与测试
cd apps/flutter
flutter pub get
flutter analyze
flutter test
cd ../..
```

## 仓库结构与模块职责

| 路径 | 作用 |
| --- | --- |
| `core/cmd/lightisled`、`core/internal` | Go Core、认证、文件、根身份、图库/影视、备份、任务及网络；`core/cmd/lightisle-recovery` 用于离线恢复 |
| `apps/macos`、`Package.swift` | Mac 原生管理 UI、Core 启停、Mac 私有 IPC 和媒体 Worker |
| `apps/web` | Vue Web/PWA 登录、文件、图库、影视与账号 UI |
| `apps/flutter` | Android、macOS、iOS 用户客户端，不持有宿主系统特权 |
| `design-tokens`、`assets/brand` | 跨端语义颜色/交互与品牌资源 |
| `scripts`、`tests` | 构建、离线恢复、打包冒烟、发行 QA、模拟设备测试 |
| `docs`、`docs/adr` | 长期规范、当前现状、架构决策 |

新代码尽量放在现有模块，不要根据早期 M1 计划创建空的 Android 项目、`native/macos-arm64`、`platform/linux`、新 Helper 或虚假的 OpenAPI SDK。新系统权限必须先明确用途、风险和授权流程。

## 接口和安全约束

- Web/Flutter 调用同一套受保护的 **v2** HTTP API；根范围使用 v2 rootID/generation 隔离契约；旧 `/api/v1` 不再注册。服务端始终重新核验身份、角色和路径授权，不能相信 UI 隐藏按钮。
- Mac 原生控制/恢复使用父进程私有 IPC；HTTP Handler 不执行任意 Shell、不接受可写宿主绝对路径或格式化盘操作。
- 实际错误格式以现行实现为准（常用 `{"error":"code"}`）。OpenAPI / 生成 SDK 是将来可选工程优化，**不能把规划的 `{code,message,request_id,details}` 当成今天的 API 合同**。
- 上传、媒体扫描、备份和转码必须有并发/空间/时间限制，错误与取消可观察；共享根物理身份失效时拒绝提交，不用同名磁盘顶替旧目录。
- 数据库结构修改必须保证旧版本数据迁移/恢复路径，使用当前真实 SQLite 初始化机制；不因为未来可能引入 Flyway/OpenAPI 而伪造已有工具。
- 日志禁止记录密码、Token、会话 Cookie 和用户原始媒体内容；媒体索引/缩略图是派生数据，账号/授权/私人相册必须独立保护。

## 编码、测试与交付

**GitHub Actions 仅手动触发**：推送和 PR 不会自动启动构建，以节省 CI 额度。按需在仓库 Actions 页面执行 `macos-arm64.yml`（测试）、`community-macos.yml`（DMG Artifact）或 `community-release.yml`（发布预览版）。也可使用 `gh workflow run macos-arm64.yml --ref main` 等命令手动运行；正式发布门禁不因此降低。

- **Go**：`gofmt`、`go vet ./...`、`go test -race ./...`，涉及文件路径、权限、TOCTOU、离线卷必须有针对性的模拟盘单测。
- **Swift**：原生 UI 响应式布局，阻塞磁盘/媒体工作不放在主线程；Mac UI 使用系统权限确认、可取消的本机任务。
- **Web**：`npm test`、`npm run build`、TypeScript 检查，移动端触控、焦点与减少动态效果真实验收。
- **Flutter**：`flutter analyze`、`flutter test`、Android/iOS/macOS 逐平台编译；设备证书、后台调度、文件权限与系统分享须真机复核。
- **集成/打包**：`bash scripts/verify-macos.sh`、核心服务 HTTP/IPC 冒烟；真实可丢弃外接盘和公网配置单独留证，绝不触碰开发机重要原盘。
- **提交**：按功能拆分，不提交数据库、私钥、媒体、缓存和构建产物；报告实际执行测试与退出码，保留其他开发任务的工作树修改。

**文档维护检查**：先查 [文档中心](INDEX.md) 的唯一维护入口，优先更新已有专题，不再创建按日期的重复计划或代码快照。运行 `python3 -B scripts/check-docs.py` 核验 Markdown 链接、章节锚点和文档索引覆盖。

开发前应先读 [ARCHITECTURE](ARCHITECTURE.md)、[SECURITY](SECURITY.md) 与 [DESIGN_SYSTEM](DESIGN_SYSTEM.md)。功能完成标准在 [ROADMAP](ROADMAP.md)，设备/签名证据清单在 [ACCEPTANCE_DEBT](DEVICE_ACCEPTANCE.md)，性能目标在 [PERFORMANCE](PERFORMANCE.md)。

## 跨端错误提示规范

API/IPC 错误码用于机器与日志，不是用户需要理解的完整提示。各端要说明**哪个操作失败 → 已确认原因 → 是否影响数据/是否已完成 → 用户下一步操作**，不可仅显示 HTTP 状态或 `volume_offline` 等错误码。

| 情形 | 用户应看到的下一步 |
| --- | --- |
| `volume_offline` | 原硬盘离线或身份暂不能确认，请到 Mac 存储设置核验并重新连接，**不可自动改用另一块盘** |
| `file_permission_denied` | 当前账号无权访问目标目录，请联系管理员确认授权 |
| `storage_quota_exceeded` | 目标硬盘上的成员额度不足，请清理该盘空间或让管理员调整该盘额度 |
| HTTP 503 / 服务不可用 | 检查 Mac App 是否运行、LAN 是否开启及原盘是否在线 |
| `download_publish_failed` | 下载数据可能仍在暂存，发布未确认；先查看目标文件和任务状态，再重试，不要猜测成功或丢失 |

**统一翻译入口**：Web `apps/web/src/userFacingError.ts` 的 `describeUserFacingError`，Flutter `apps/flutter/lib/core/user_facing_error.dart` 的 `userFacingError`；Mac 端在对应 IPC 页面复用用户可理解的错误映射。未知码可以在可执行提示后附安全短标识（`[a-z][a-z0-9_]{1,80}`），不能泄露令牌、Cookie、绝对路径或请求体。已经包含恢复步骤的中文错误不重复翻译。超时、部分完成与磁盘同步未确认时必须显示“请核对”，不可假报成功；增加错误码时补三端映射与测试。

静态检查按本指南的 Go/Swift/Web/Flutter 工具执行；离线、无权、被撤销证书、弱网与恢复路径还需在实际设备复核，参见 [DEVICE_ACCEPTANCE](DEVICE_ACCEPTANCE.md)。
