# 轻屿 LightIsle

![LightIsle 轻屿 Logo](assets/brand/lightisle-logo.svg)

> 为 Apple Silicon Mac mini 设计的轻量、高效、真正以原生 macOS App 形式运行、可通过 Android 管理的开源家庭 NAS。
>
> **状态：M1–M5 开发预览，未达到正式发布标准。** Mac App 做初始化、系统监控、服务/存储配置和本机备份恢复；文件、图库、影视及账号管理由独立 Web 用户端实现。仓库内已有 Go 单测/集成测和打包冒烟脚本，但真实磁盘、GUI、规模/72 小时、Android 实机和签名公证验收**尚未完成**。Flutter Android 原生客户端与 Docker/Colima 管理不是本版本的发布阻断项，除非产品另行承诺。

LightIsle（轻屿，暂定产品名）将 **文件管理、图库、影视、存储与系统管理** 整合为统一的家庭服务器。保留 macOS，不安装替代操作系统；基础 NAS 服务不依赖 Docker。

**产品形态是一个完整的 `LightIsle.app`，不是一个退出应用后仍独立运行的服务器。** 双击启动 Mac 应用就启动内置 Go 后端；完全退出应用（默认关闭最后一个主窗口或按 ⌘Q）就结束 Go 后端和 LightIsle 的媒体任务，Android 连接随之断开。最小化窗口不等于退出，NAS 继续运行。**不使用独立常驻 launchd NAS 服务或开机自启守护进程。** [详见 App 生命周期](docs/MACOS_APP.md)。

## 平台范围（硬性约束）

- **后端：仅 macOS arm64（Apple Silicon）**，面向 Mac mini；不支持、不规划 Linux 后端、macOS x86_64 后端或 Windows 后端。
- **macOS 本机客户端：SwiftUI + AppKit 原生管理端**，负责首次创建管理员、系统监控、后端状态、远程 HTTPS 开关和共享目录授权。**不内嵌文件、图库、影视等用户业务页面。**
- **网页端：Vue 3 / PWA**，覆盖桌面浏览器和 Android 手机浏览器。
- **移动客户端：暂定 Flutter Android**，先实现 Web 的手机适配，后续开发 Android 原生客户端。iOS 并非当前开发目标。
- 底层平台适配只实现 macOS arm64，不额外抽象跨系统的 Linux Provider。

## 产品特点

- **轻量低占用**：一个 Go 核心后端；媒体扫描、生成缩略图、刮削与转码按需运行；无强制 Redis/PostgreSQL/JVM。
- **内置 NAS 三核心（推进中）**：Web 文件管理、图库及影视直放初版均已开发，M4 的视频海报与不兼容格式按需转码仍待实现。
- **原生 Mac 能力**：通过 Swift/macOS API 使用 FSEvents、ImageIO、AVFoundation 和系统磁盘能力。
- **App 与后端同生命周期**：启动应用自动启动 Go 子进程，退出应用优雅关闭服务；意外退出时 Go 自动检测父进程离开。
- **跨端设计方向**：macOS 原生 App 与 Web/PWA 采用一致的色彩、圆角和层级规范；规划中的 Flutter Android 客户端将沿用这套设计语言，同时保留平台原生交互并优先低资源占用。详见 [设计系统](docs/DESIGN_SYSTEM.md)。
- **统一官方 Logo**：初始化动画、Mac 侧栏、Finder/Dock App 图标、Web 登录、浏览器标签和移动端主屏共用同源蓝紫六边形图形。构建自动生成全尺寸素材，见 [品牌资源说明](assets/brand/README.md)。
- **Android 浏览器管理（开发预览）**：管理员在 Mac 应用中手动开启 HTTPS 局域网服务后，通过账号密码登录；自签名证书需要核验指纹。Flutter Android 原生客户端和照片备份仍在规划中。
- **安全默认**：初始只监听 127.0.0.1；首次管理员由 Mac App 通过私有 IPC 创建，HTTP 不提供注册管理员入口。其他账号由管理员在 Web 创建；SQLite + Argon2id + 会话授权；共享目录只能 Mac 本机选择。Web 登录会话最长 30 天，停用账号或重置密码会撤销相关会话。
- **本机固定端口与密码恢复**：默认 Web 地址为 `http://127.0.0.1:16666/`；在 **Mac App → 设置 → 本机 Web 端口** 可修改，完全退出并重新打开后生效。忘记首任管理员密码可在 **Mac App → 设置 → 管理员安全 → 重置管理员密码**，使用 macOS Touch ID 或系统登录密码验证设备所有者身份后修改。仅本机私有进程通道可以执行重置；旧管理员会话会失效，Web 没有公开重置接口。可选 Touch ID 钥匙串存储需要先验证已有轻屿密码。

**重置成功仍提示用户名或密码不正确？** Mac「设置 → 管理员安全」现在会直接显示**当前数据库中实际的首任管理员用户名**，重置成功提示也会显示具体修改了哪个账号。请点击同页「打开当前 Web 登录页面」，用显示的用户名和刚设置的新密码登录；不要复用浏览器之前保存的旧密码或以前的随机端口标签页。新密码不会改动用户名，也不会修改其他管理员的密码。排查时不要删除 `accounts.sqlite` 或重新初始化。
- **模块化、但不微服务化**：仅 App 打开时运行单一 Go Core；Docker/Colima 仅作为可选应用扩展。

## 功能模块与路线

| 模块 | 计划能力 | 目标里程碑 |
| --- | --- | --- |
| 原生 Mac 应用 | SwiftUI 主窗口、系统控制台、App 启停联动、故障恢复 | M1 |
| 系统控制台 | CPU、内存、网络、盘容量、进程与服务状态 | M1 |
| 文件管理 | 目录、搜索、上传下载/续传、预览、批量操作、回收站 | M2 |
| 磁盘 | 发现、容量、健康、挂载状态；高危操作受限 | M2 / M5 |
| 图库 | 时间线、EXIF、HEIC、相册、收藏、预览、缓存 | M3 |
| 影视 | 电影/剧集、海报、字幕、续播、直放/按需转码 | M4 |
| NAS 运维 | 手动/每日/每周文件备份和 SHA-256 恢复、SMB 只读诊断；SMB 配置及受权关机重启待开发 | M5 |
| Docker / 应用 | 可选 Colima/Docker 管理与应用目录 | M5 / M7 |
| Flutter Android | 设备管理、照片后台备份、通知、原生体验 | M6 |
| 安装发布 | 单一 LightIsle.app、签名/公证安装包、更新和恢复测试 | M7 |

**M1–M5 均已有部分开发版能力，但未通过完整实机/压力验收。** [完整推进路线及验收标准](docs/ROADMAP.md)

**P0 增补（开发预览）：** 管理员可按目录授予普通成员只读/读写权限（默认拒绝）；Web 文件管理提供有限搜索、同共享卷排他移动/重命名、校验后原子发布的文件/目录复制与管理员回收站永久清理；Mac 存储页展示已挂载卷、SMART 读取状态、网络速率，并提供跨卷**安全复制**（不覆盖、不删除源文件、仅 Mac App 可发起）。图库/影视按授权目录过滤；FSEvents + 周期对账、任务状态持久化、30 天登录会话和可配置缩略图缓存（默认 1 GiB，256 MiB–8 GiB）已实现。备份 v2 可一致性导出 SQLite 与配置，恢复先安全暂存，再经 Mac 所有者身份验证离线切换数据库并保留旧版本，不自动覆盖共享文件。**跨卷移动、成功激活后一键回退和文件+数据库联合灾难恢复仍未实现。** [P0 实施与验证状态](docs/P0_IMPLEMENTATION_STATUS.md)

**生产发布限制：** 已加入授权子树隔离、上传崩溃恢复日志、任务状态持久化、可移动卷重挂防误写校验和受磁盘日志保护的离线数据库激活；但跨卷事务化**移动**、成功恢复后的反向回滚、共享文件与数据库联合恢复、实机 SMART 与稳定性验收仍是阻断项。请勿将 `dist/LightIsle.app` 的本机临时签名视为正式发布包。参阅 [正式发布门禁及拒绝条件](docs/PRODUCTION_RELEASE.md)。

### 两个独立的前端

- **Mac 原生管理端**：启动 Go Core；首次使用时原生设置首任管理员；系统 CPU/内存/磁盘监控通过私有 IPC 采样；配置 HTTPS 远程访问、授权共享目录，提供“打开 Web 用户端”入口。
- **Web 用户端**：首次未初始化时提示用户先到 Mac；初始化完成后只提供账号登录，不开放注册；文件管理、图库、相册、收藏、影视中心与管理员账号管理全在 Web。
- **生命周期**：完全退出 Mac App 后 Go 和 Web 服务一起退出；Mac App 最小化时继续运行。不提供独立常驻 NAS 守护进程。

### 当前文件管理功能

- 在 macOS App 的“设置 → 文件共享目录”中使用原生文件夹选择器，授权 `~/...` 下的子目录或外置数据卷，保存后重启依然生效。
- Web 文件页支持游标分页、创建文件夹、上传断点续传（最高 32 GiB，4 MiB 请求分块）、Range 下载、预览、批量移入回收站；搜索是 30,000 项上限的限量遍历，不是完整全文索引。
- 删除采用 App 内部回收站，支持按原路径恢复；发生同名冲突时拒绝覆盖。外接卷离线不会转写到其他共享目录，可在 Mac 设置中手动重新连接。
- **同卷操作与跨卷复制是两件事**：同共享卷内的改名/移动使用排他原子重命名；文件/目录复制在私有临时树中逐文件校验后发布。Mac「存储」页可把共享目录中的对象**复制**到另一块磁盘，但**跨卷移动尚未实现**，不会自动“复制成功后删除源文件”。
- Web 图库首版支持按需扫描照片/视频、SQLite 索引、部分 EXIF 拍摄时间、时间线、收藏、相册以及 macOS 按需缩略图；缩略图缓存默认 1 GiB，可在 Mac 设置中调整为 256 MiB–8 GiB 并按最近使用淘汰。Mac App 已增加 FSEvents 变更触发及 Go 周期核对，但尚未实现完整 HEIC 元数据、视频封面、增量任务检查点或大规模性能验收。
- **Web 影视中心 M4 初版**：管理员按需扫描共享目录的视频文件；SQLite 索引电影/剧集，按文件名识别年份/季集；Web 提供筛选、搜索、影片改名、MP4/WebM HTTP Range 原文件播放、同名 VTT/SRT 字幕与每用户独立续播进度。未适配的格式支持下载用本地播放器打开。
- **M4 尚未实现**：影片海报/自动刮削、完整媒体编码探测、MKV/MOV 转码、VideoToolbox/HLS 自适应流。仅支持浏览器自身能解码的音视频组合，不保证所有 MP4 可播放。
- **M5 本机运维预览**：Mac App「存储」页可手动备份/恢复共享文件，也可配置仅在 App 运行时执行的每日/每周定时备份；「服务管理」提供 SMB TCP 445 只读探测。备份/恢复与计划配置只能通过 Mac App 私有 IPC 触发，不暴露远程 Web API。
- **M5/P0 备份范围**：v2 可备份共享普通文件和账号、图库/影视/任务 SQLite 与部分应用配置；单任务最多 20,000 文件项或 50 GiB，共享目录备份可恢复到隔离文件夹，应用元数据需先校验暂存，再由 Mac 所有者验证身份、停止后端后**离线激活**。这不等同于 Time Machine/整机灾难恢复；没有成功激活后的一键回退、文件+数据库联合恢复、增量快照/自动轮换、SMB 自动配置、系统关机/重启或 Docker 管理。[操作说明与安全边界](docs/M5_OPERATIONS.md)
- 尚未实现：跨卷移动、成功恢复后的自动反向回滚、文件与数据库联合灾备、备份轮换/加密、完整存储健康告警。已实现同卷移动、跨卷安全复制和管理员清理单个回收站项。**不要把这版用于重要数据的唯一副本。**

## macOS ARM64 本地构建与运行

需要 Apple Silicon Mac、Go 1.26+、Xcode 27、Node.js 与 npm。最低 macOS 支持版本暂按 14.0 的构建设置开发，发行前需在目标版本真机验证。

```bash
cd /Users/leo/Documents/code/Lightlsle
bash scripts/build-macos.sh
open dist/LightIsle.app
```

构建脚本将安装前端依赖、运行 Go 测试、构建 Vue 与 SwiftUI，打包为 `dist/LightIsle.app` 并进行**本地临时签名**。这不是已经公证的正式发布包，不要直接分发给其他用户。

Mac App 只负责原生系统概览、首次管理员初始化、服务和存储管理；文件、图库和影视由按钮打开 Web 浏览器。关闭最后一个窗口或按 ⌘Q 应当关闭 Go 后端，完整 GUI 交互和 Android HTTPS 真机访问仍须手工验证。

单独执行自动化校验：`bash scripts/verify-macos.sh`。M1 的历史验收记录见 [M1 状态快照](docs/M1_STATUS.md)；当前状态以 [P0 实施与验证状态](docs/P0_IMPLEMENTATION_STATUS.md) 和 [路线图](docs/ROADMAP.md) 为准。

## 技术方案

| 部分 | 拟选技术 |
| --- | --- |
| macOS 原生 App | SwiftUI + AppKit，负责初始化、控制 Go 子进程和系统管理（不依赖 WKWebView 用户页） |
| 跨端设计 | iOS 27 / macOS 27 视觉语言、Liquid Glass、共享语义 Design Tokens |
| 后端服务 | Go 1.26 + 标准库 net/http（当前）、后续 REST / WebSocket 或 SSE |
| macOS 专用服务 | Swift + 系统 Framework，受控本地 IPC |
| Web / Android 浏览器 | Vue 3 + TypeScript + Vite + PWA |
| Android 原生 | Flutter（暂定仅 Android） |
| 数据索引 | SQLite WAL + FTS5（规划），当前为 SQLite 限量遍历与扫描式对账 |
| 媒体 | macOS `sips`（当前缩略图）、ImageIO/QuickLook/AVFoundation（规划）、必要时 FFmpeg + VideoToolbox |
| 容器 | Docker Engine API / Colima（**可选**） |
| 运行维护 | App 内启动/退出 Go 子进程、受保护本地 IPC、签名发行 |

详细见 [技术架构](docs/ARCHITECTURE.md)。

## 不做什么

- 不尝试在 macOS 上复刻 Linux Btrfs/ZFS 的存储池、RAID 或 Docker 内核功能。
- 不将 Linux、Windows、Intel Mac 作为后端兼容范围；也不为假想平台设计大量接口。
- 不宣称完全关机的 Mac 可以纯软件开机；取决于实际硬件及供电设备。
- 不承诺所有视频编码、HDR、字幕组合直接播放或都有硬件转码。
- 不允许 Web API 执行任意 root Shell；系统盘不开放远程擦除功能。

## 文档

- [产品功能与范围](docs/PRODUCT.md)
- [macOS 原生应用及启停生命周期](docs/MACOS_APP.md)
- [iOS 27 风格的跨端设计系统](docs/DESIGN_SYSTEM.md)
- [共享主题 Design Tokens 草案](design-tokens/tokens.json)
- [架构与核心模块](docs/ARCHITECTURE.md)
- [开发指南与约束](docs/DEVELOPMENT.md)
- [阶段路线图及验收表](docs/ROADMAP.md)
- [性能预算与验证方法](docs/PERFORMANCE.md)
- [权限和安全方案](docs/SECURITY.md)
- [P0 实施与验证状态](docs/P0_IMPLEMENTATION_STATUS.md)
- [正式发布门禁及拒绝条件](docs/PRODUCTION_RELEASE.md)
- [M1 历史状态快照](docs/M1_STATUS.md)
- [M5 备份恢复与 SMB 诊断](docs/M5_OPERATIONS.md)

## 项目状态

状态标记只表示“代码/入口存在”或“自动化脚本存在”，不代表真机验收通过；详见 [P0 实施与验证状态](docs/P0_IMPLEMENTATION_STATUS.md)。

- [x] 初步产品定位、平台约束和开发文档
- [x] 创建 SwiftUI Mac App / Go / Vue 工程骨架，并成功构建 macOS .app
- [x] 编写并验证 Go 在父进程管道关闭后退出的机制（完整 GUI 验收仍待完成）
- [x] Web 实现共享设计 token 与浅色/深色主题（SwiftUI 原生映射和 Android 未全部完成）
- [x] macOS arm64 上 Go 健康检查与真实系统指标测试通过
- [x] 账号模式：Mac 原生初始化首任管理员；Web 只登录和由管理员创建其他账号；SQLite 持久化；会话最长 30 天且可撤销
- [x] 基础文件 API 与 Web：浏览、上传下载、预览、回收站恢复
- [x] Mac 原生共享目录选择及外置卷离线后重连
- [ ] Android 真机端安全 HTTPS 连接验证（接口已开发）
- [x] Web 图库首版、照片索引/收藏/相册、文件分页与分块续传；缩略图缓存默认 1 GiB、可在 256 MiB–8 GiB 间配置
- [x] Web 影视中心初版：电影/剧集索引、Range 直放、字幕、账户独立播放进度与断点续播
- [ ] 影视转码/海报、图库深度增强与真实大规模压测
- [ ] 正式签名/公证的 LightIsle.app 与 Android App

当前仓库以 MIT 许可证发布；品牌名唯一性、正式最低支持 macOS 版本尚待确认。状态标记不代表真机/规模验收已通过；Flutter Android 原生客户端和 Docker/Colima 管理不是本版本阻断项，除非产品另行承诺。后端范围固定为 macOS arm64。
