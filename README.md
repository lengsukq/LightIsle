# 轻屿 LightIsle

![LightIsle 标志](assets/brand/lightisle-logo.svg)

**把自己的 Mac 变成轻量的家庭 NAS。**

LightIsle 是面向个人和家庭的开源 NAS 管理层：在 **Apple Silicon Mac** 上运行原生管理 App，通过浏览器或独立客户端访问文件、照片、影音和日常服务。它**不替换 macOS**，不自建 RAID、文件系统或 Docker 运行时，而是尽量复用 APFS、系统文件共享、FSEvents、Time Machine 与 SQLite。

> **项目状态：Beta 开发预览，尚未正式发布。** 现有模块有代码和自动化测试，但外接盘故障、跨端体验、长期运行以及 Developer ID 签名与 Apple 公证尚未完成全套真实验收。重要数据必须另有独立备份；不要把开发构建直接当成已验收的生产 NAS。

**API 约定**：这是新项目，不提供旧版本兼容服务。Go Core、Web、Flutter（Android/iOS/macOS）统一使用 `/api/v2/...`；指定物理根的文件、媒体及上传使用 `/api/v2/roots/{rootID}/...` 并校验磁盘代际。旧 `/api/v1/...` 不注册路由，旧客户端需要同步升级。默认共享目录同样使用 v2，不属于旧 API 兼容功能。详见 [系统架构](docs/ARCHITECTURE.md)。

[快速开始](#快速开始) · [功能与限制](#功能概览) · [构建和打包](#构建打包与测试) · [文档导航](#文档导航) · [当前代码状态](docs/STATUS.md)

## 项目组成

| 组件 | 技术 | 职责 |
| --- | --- | --- |
| **Mac 管理端** | SwiftUI / AppKit | 首次初始化、Core 生命周期、磁盘和目录、备份恢复、服务开关、Docker 管理 |
| **NAS Core** | Go / SQLite | 登录会话、授权、文件与分享、图库/影视、任务、HTTP API 和安全的存储根边界 |
| **Web / PWA** | Vue 3 / TypeScript | 日常文件、图库、影音、下载中心、账号与管理员页面 |
| **用户客户端** | Flutter | Android、iOS、macOS 上连接已有 NAS；**不是另一套服务器** |

一个 `LightIsle.app` 负责启动和管理内置 Go Core。**关闭主窗口可以留在菜单栏继续运行；明确退出 App 才停止 NAS 服务。** 不会默默创建独立的开机守护进程。NAS 服务端只支持 **macOS ARM64**；Intel Mac、Windows 和 Linux 目前不能作为 LightIsle 服务端。见[系统架构](docs/ARCHITECTURE.md)、[Mac 生命周期](docs/MACOS_APP.md)。

## 功能概览

以下表示**已有开发版代码入口**，而不是所有场景都已通过真实设备验收。更精确的模块状态与已知问题以 [STATUS.md](docs/STATUS.md) 为准。

| 模块 | 当前能力 | 重要限制 |
| --- | --- | --- |
| **文件管理** | Web/Flutter 浏览、搜索、批量操作、预览、分片上传与续传、Range 下载、ZIP 导出、回收站及还原 | 跨盘、满盘、中断和不同客户端行为仍需实际验证 |
| **分享与 WebDAV** | 有效期/密码/次数限制的文件或文件夹分享；独立可撤销 WebDAV 凭据、目录读写授权、覆盖移入回收站 | 分享文件夹使用有界 ZIP；WebDAV PUT 不支持独立分块续传 |
| **照片图库** | 增量索引、HEIC/视频缩略图、时间线、共享/私人相册、收藏、EXIF/GPS、Web 地图及查看器手势 | Live Photo 动态配对、地图瓦片、海量图库和跨端一致性仍在完善 |
| **影视中心** | 电影/剧集、NFO/TMDB/豆瓣候选、字幕、原片播放、进度、可选 FFmpeg/HLS | 不保证所有编码、音轨、字幕和 HDR 在每台设备上都可播放 |
| **账号与授权** | Mac 初始化首任管理员、Argon2id、成员管理、会话撤销、目录读写授权、本机所有者身份验证重置管理员密码 | 真实 Touch ID 弹窗与多端授权场景需继续验收 |
| **外接硬盘** | 容量/文件系统/在线状态、挂载/弹出、有限改名、按需 SMART 和存储根物理身份校验 | 部分文件系统只读；SMART 读取失败显示未知，不代表健康 |
| **下载中心** | 复用本机已安装的 aria2，创建、暂停、继续、取消、重试和安全发布下载任务；Web/Flutter 可查看任务 | 不捆绑 aria2；实际磁力/DHT 与更多外部网络情况尚待验证 |
| **监控与通知** | CPU/内存/网络/磁盘历史、任务失败和空间告警；Mac 通知设置及外发渠道 | 某些通道尚需真实接收端验证；SMART 不是持续自动采样 |
| **Docker 管理** | 管理已存在的 Docker Desktop/Colima、容器、Compose、镜像、卷/网络和镜像源配置 | **不安装、不内置 Docker**；不提供容器终端或完整应用商店 |
| **Flutter 客户端** | Android / iOS / macOS 的文件、图库、影视和账号；手机原片备份 | Android 后台仅照片；iCloud 未下载原件、视频和锁屏调度需真机测试 |

### 备份与数据保护

LightIsle **当前家庭版只承诺应用配置/SQLite 快照**：Mac 本机手动备份，或每周自动备份并保留最近 **5 份**。恢复需验证快照并由本机所有者确认，账号/授权等数据库的离线恢复不等于文件和数据库一起回滚。

**不会由 LightIsle 自动整盘备份、备份或恢复全部照片/视频/文档，也不提供逐盘全量备份计划。** 原始 NAS 数据请自行通过 Time Machine 或独立备份介质保护；自动化脚本目录及其环境文件也不在当前应用配置快照内。详见[备份与恢复现状](docs/STATUS.md)、[发布安全要求](docs/PRODUCTION_RELEASE.md)。

### 可选网络与穿透服务

- **局域网**：管理员在 Mac 上明确启用服务；LAN 默认 HTTPS（本地证书），可在知晓风险后选择可信内网 HTTP。不会自动设置路由器端口转发。
- **WebDAV**：使用独立的账号凭据，路径为 `/dav/`；不能直接使用浏览器 Cookie 作为 WebDAV 密码。
- **Cloudflare Tunnel**：检测系统已有的 `cloudflared`；不内置、不自动下载，支持临时 Quick Tunnel 或自有账户/域名配置。
- **FRP 客户端**：Mac 设置中按需从官方 GitHub Releases 获取 **可安装的 macOS ARM64 版本**，选择版本后下载并校验 SHA-256；可打开 `frpc.toml` 并启动/停止 `frpc`。不内置 FRP 二进制，也**不提供 frps 服务端**；切换版本前需要停止进程。不能将“frpc 运行中”当成“远端映射已可访问”。

**不要把明文 HTTP 管理端口直接穿透到公网。** 本机高级操作通过 Mac App 与 Core 的私有 IPC 执行，不开放任意远程命令执行接口。见 [远程访问与 FRP](docs/REMOTE_ACCESS.md)、[安全边界](docs/SECURITY.md)。

### 本地脚本自动化（开发预览）

管理员可在 Web **自动化**页查看、刷新、启停与调度本机脚本、管理 Cron 和查看有限日志。脚本文件由用户在本地使用外部编辑器或 AI Agent 编写，放入 `automation/scripts/<task-id>/`，通过 `task.json` 描述任务，支持可选 `env.json` 与 HTML 邮件通知模板。

LightIsle **不内置 AI Agent、脚本代码编辑器、运行时依赖安装器或脚本沙箱**。脚本以运行 Core 的 Mac 用户身份执行，不要运行不可信脚本。通知可配置 Email、企业微信、钉钉、Bark、Webhook 等渠道；实际对外发送仍需逐项验收。完整 JSON 格式、邮件的 builtin/content/custom 模式及安全要求见 [自动化任务约定](docs/AUTOMATION_AGENT.md)。

### 多硬盘与用户配额（尚未完整闭环）

代码中已有多根 rootID/generation、用户专属 `files/photos/videos` 位置分配和部分写入渠道的容量预占。普通成员默认显示 **100 GiB** 配额，管理员无限。

但目前 API 仍明确返回 `enforcement=pending`：**并非全渠道硬配额已生效**，多根自动路由、所有写入渠道计费、跨端/实盘权限验收尚未完成。正式多根模式不能作为稳定功能宣传，也不会自动迁移旧盘数据。详见 [ADR 0003](docs/adr/0003-personal-homes-and-quota.md) 和 [路线图](docs/ROADMAP.md)。

## 快速开始

### 系统要求

| 环境 | 要求 |
| --- | --- |
| NAS 主机 | Apple Silicon Mac（M 系列），**macOS 14+**（Swift Package 部署目标） |
| 源码构建 | **Go 1.26+**、Swift 6 / Xcode、Node.js 与 npm、macOS 命令行工具 |
| 使用客户端 | Mac 上的浏览器、或本仓库 Flutter Android / iOS / macOS 客户端 |
| 可选依赖 | Docker Desktop / Colima、FFmpeg、aria2、cloudflared、smartctl、FRP；**非 NAS 启动必需** |

Mac 原生管理端「**外部依赖**」页可检查 FFmpeg、aria2、smartmontools、cloudflared，并在用户确认后用本机 Homebrew 安装；不会捆绑软件包或静默安装。FRP 仍由网络设置中的官方版本选择流程安装，Docker 只管理已存在的运行时。参见 [外部依赖安装说明](docs/EXTERNAL_DEPENDENCIES.md)。

目前没有经过正式 Developer ID 公证的公开发行版；建议使用可丢弃的数据目录体验开发构建。

```bash
git clone https://github.com/lengsukq/LightIsle.git
cd LightIsle
bash scripts/build-macos.sh
open dist/LightIsle.app
```

启动后按照以下顺序设置：

1. 在 **Mac 原生 App** 首次创建管理员（Web 不支持匿名创建管理员）。
2. 在「数据与存储」中选择经过确认、可写的 NAS 专属文件夹，按需接入外置磁盘。
3. Mac 本机可从 `http://127.0.0.1:16666/` 打开 Web；如修改了端口，以 Mac 管理端显示的实际地址为准。
4. 要让手机/其他电脑访问，先在 Mac 管理端显式开启局域网访问，然后使用显示的 **HTTPS 地址**连接。自签名证书须核对指纹；仅在可信内网才考虑主动允许 HTTP。
5. 需要更多能力时再配置 WebDAV、Docker 管理或 Tunnel/FRP；不要为了基础文件访问预先安装一套 Docker。

**忘记管理员密码？** Mac「设置 → 管理员安全 → 重置管理员密码」通过设备所有者的 Touch ID/登录密码验证后重置。旧会话会失效，但不会删除数据库。

**外接盘不可写/突然离线？** 先检查文件系统与挂载状态，不要自动格式化或清除数据；原盘重连优先。确认废弃后才能由管理员主动解除登记并为用户重建空白位置，**不会迁移或删除旧盘原文件**。详见[存储与磁盘](docs/STORAGE_AND_DISKS.md)。

## 构建、打包与测试

### 本机开发版（不要求 Apple 开发者账号）

```bash
bash scripts/build-macos.sh
# 输出：
# dist/LightIsle.app       原生应用（ad-hoc 本地签名）
# dist/LightIsle-dev.dmg   可拖入“应用程序”的本地测试磁盘镜像

# 已有完整 .app 时，可以只重做 DMG：
bash scripts/package-dmg.sh dist/LightIsle.app dist/LightIsle-dev.dmg
```

DMG 内包含 LightIsle.app 与 Applications 快捷入口，采用 macOS `hdiutil` 生成并校验。**Ad-hoc DMG 虽能挂载，但不等于获得 Gatekeeper 信任或 Apple 公证。** 可作为明确标注风险的开源 Community 预览版共享，不可冒充正式签名、公证或已完成真机验收的发行版；其他 Mac 首次打开可能需要在「系统设置 → 隐私与安全性」中手动允许。

### GitHub Actions 手动构建 macOS Community DMG

仓库提供 [`community-macos.yml`](.github/workflows/community-macos.yml)，**只在手动触发时运行**，不自动发布 GitHub Release，也无需 Apple Developer ID 或公证密钥。构建执行完整 `build-macos.sh`，上传 `LightIsle-dev.dmg` 和 SHA-256 校验文件，下载入口为该次 Actions 运行的 **Artifacts**，默认保留 30 天。

在 GitHub 网页的 **Actions → Build macOS Community DMG (manual) → Run workflow** 点击构建，或者安装并登录 GitHub CLI 后在仓库根目录运行：

```bash
gh workflow run community-macos.yml --ref main
gh run list --workflow community-macos.yml --limit 5
# 运行完成后将示例数字替换为列表显示的真实运行 ID：
gh run download 123456789 -n LightIsle-macOS-arm64-ad-hoc -D dist/ci
```

该工作流文件需要先提交并推送到 GitHub 默认分支才会出现手动运行入口。**Android APK 不包含在此工作流中**；若需要 Android 签名 APK 和 macOS DMG 同时发布到 Releases，应使用下方的双端发布工作流。

### GitHub Actions 一键手动发布 Android + macOS Community 预览版

**推荐使用** [`community-release.yml`](.github/workflows/community-release.yml) 统一发布双端版本，而上面的 `community-macos.yml` 仅适合获取一次性 macOS 构建 Artifact，不创建 Release。

- **手动触发、仅 `main`**：构建 Android 正式签名 APK/AAB 和 macOS ARM64 Ad-hoc DMG。两端测试/打包都成功、SHA-256 校验通过后才创建**同一个 GitHub Releases Pre-release**，不需要苹果付费证书。
- **自动版本**：版本标签采用 UTC `v0.1.0-beta.YYYYMMDDHHMMSS`，例如 `v0.1.0-beta.20261027153015`。Android `versionCode` 和打包后 macOS `CFBundleVersion` 采用从 2020-01-01 UTC 起的秒数，随发布时间递增；应用显示的 `versionName` / `CFBundleShortVersionString` 仍为 `0.1.0`，在升级到下一个语义版本时应同步调整。
- **安全边界**：Android 使用同一把长期保管的 Keystore 签名，绝不退回 Debug 签名。macOS 预览版未 Apple 公证，用户可能需要手动允许打开。发布说明明确写为 Beta，不能代替外接盘、移动端后台和恢复功能的真实验收。

首次设置 Android 密钥（**仅在本机执行，不要放进 CI；运行之前备份旧密钥，脚本不会覆盖已有身份**）：

```bash
python3 scripts/setup-android-signing.py --upload
```

该命令生成 `~/.config/lightisle/android-release.jks` 和 `~/.config/lightisle/android-release.properties`（权限为 0600），并使用已经登录的 `gh` 安全上传以下四个仓库级 Actions Secrets：`LIGHTISLE_ANDROID_KEYSTORE_BASE64`、`LIGHTISLE_ANDROID_STORE_PASSWORD`、`LIGHTISLE_ANDROID_KEY_PASSWORD`、`LIGHTISLE_ANDROID_KEY_ALIAS`。密钥不写入项目目录，不加入 Git。**必须独立离线备份这两个本地文件；GitHub Secrets 不能下载原值，丢失签名密钥后将无法为原有安装包发布兼容更新。**

手动触发与查看：

```bash
gh workflow run community-release.yml --ref main
gh run list --workflow community-release.yml --limit 5
gh release list --limit 5
```

也可以在 GitHub → **Actions → Publish Android + macOS Community Release (manual) → Run workflow** 触发。构建完成后统一在 [GitHub Releases](https://github.com/lengsukq/LightIsle/releases) 下载 APK、AAB、DMG 及其 SHA-256。首次生效前**必须将该工作流和相关 Gradle/打包脚本提交推送到远端 `main`**，仅将 Secrets 上传仓库并不能使本地未提交的代码出现在 CI。

### 正式发布（严格门禁）

```bash
# 请先在本机配置有效的 Developer ID、notarytool 凭据和真实 QA 证据
export LIGHTISLE_DEVELOPER_ID='Developer ID Application: ...'
export LIGHTISLE_NOTARY_PROFILE='your-notarytool-profile'
export LIGHTISLE_QA_REPORT='/absolute/path/to/qa-report.json'
bash scripts/release-macos.sh
# 通过全部检查后才会生成：
# dist/LightIsle.zip
# dist/LightIsle.dmg
```

正式脚本要求应用签名、Apple 公证/票据装订、解包复验和 DMG 再公证，缺少任何条件应中止。**项目尚未宣称已完成真实的正式发布验收**；详见 [PRODUCTION_RELEASE.md](docs/PRODUCTION_RELEASE.md)。

### 开发质量检查

```bash
go test -race ./...
go vet ./...
bash scripts/verify-macos.sh

# Flutter 用户客户端（需独立安装 Flutter SDK）
cd apps/flutter
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

macOS 验证脚本覆盖 Go、Swift、Web、打包流程相关的代码级检查，但**不会自动完成**真实外接盘、Android/iOS 设备、Cloudflare/FRP 公网连通、72 小时运行、苹果签名公证等验收。Flutter 客户端调试见 [FLUTTER_CLIENT.md](docs/FLUTTER_CLIENT.md)。

## 代码目录

```text
LightIsle/
├── apps/
│   ├── macos/       # SwiftUI 管理端与原生 Media Worker
│   ├── web/         # Vue 3 / TypeScript Web/PWA
│   └── flutter/     # Android / iOS / macOS 用户客户端
├── core/
│   ├── cmd/         # lightisled、lightisle-recovery
│   └── internal/    # 登录、文件、相册、影视、下载、自动化、隧道等
├── scripts/         # 构建、测试、DMG 制作、发行与验收
├── tests/           # 集成、边界、回归和离线发行模拟测试
├── design-tokens/   # 跨端设计 Token
├── assets/brand/    # Logo 和应用图标资源
└── docs/            # 使用指南、状态、架构、安全和 ADR
```

## 已知限制与后续方向

项目强调个人和家庭使用，不计划内建 RAID/ZFS、企业级 HA、整盘自动灾备、脚本沙箱或开机后独立常驻的 NAS 服务端。

当前最值得关注的是：**多根/个人目录配额未全链路执行**（`enforcement=pending`）；应用配置快照不包含媒体原件；Android 后台照片和 iOS 大原片、不同播放器编解码、真实外置盘拔插与恢复、FRP/Cloudflare 公网配置及正式签名/公证，都还需要对应真实环境的验证。不要根据单测通过推断已经适合长期保存唯一数据。

功能是否闭环请看 [STATUS](docs/STATUS.md)，接下来的优先级请看 [ROADMAP](docs/ROADMAP.md)，真实设备的证据缺口请看 [ACCEPTANCE_DEBT](docs/ACCEPTANCE_DEBT_2026-10-25.md)。

## 文档导航

- [文档总索引](docs/INDEX.md) · [当前功能与缺口](docs/STATUS.md) · [产品定位与 fnOS 对标](docs/FNOS_PARITY_PRIORITIES.md)
- [使用与开发](docs/DEVELOPMENT.md) · [macOS 生命周期](docs/MACOS_APP.md) · [Flutter 客户端](docs/FLUTTER_CLIENT.md)
- [外置磁盘与存储](docs/STORAGE_AND_DISKS.md) · [远程访问、WebDAV、FRP](docs/REMOTE_ACCESS.md) · [Docker/Colima 管理](docs/DOCKER_MANAGEMENT.md)
- [本地自动化 JSON/邮件模板协议](docs/AUTOMATION_AGENT.md) · [安全](docs/SECURITY.md) · [生产发布门禁](docs/PRODUCTION_RELEASE.md)
- [架构与 ADR](docs/ARCHITECTURE.md) · [历史开发摘要](docs/HISTORY.md)

## 许可证

项目源代码采用 [MIT License](LICENSE)。外部工具（如 Docker、aria2、FRP、FFmpeg）的许可证与运行风险由其各自项目规定；LightIsle 不将这些工具视为内置组件。
