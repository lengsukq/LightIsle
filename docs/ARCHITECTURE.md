# 技术架构与模块边界

> **HTTP 接口版本（2026-10-27）**：LightIsle 作为全新项目仅发布 v2 REST 契约。全局系统、认证、用户管理及下载等接口为 `/api/v2/...`；硬盘绑定的数据操作为 `/api/v2/roots/{rootID}/...`，写请求必须携带对应的 `X-LightIsle-Root-Generation`。旧 `/api/v1/...` 在 Core 上返回 404，不保留别名或重定向。Web、Flutter 三端均已同步改动；公开分享表单在 v2 使用独立安全规则。关于旧协议的历史 ADR 不再是运行时契约。

> **唯一后端目标：macOS arm64 / Apple Silicon。** 不为 Linux、Windows、x86_64 编写服务端兼容层。服务端由 Mac 原生管理端拥有，用户客户端包括 Vue Web/PWA 与 Flutter Android、macOS、iOS；**不做独立常驻 NAS 守护进程**。具体实现和安全验收状态以 [STATUS](STATUS.md) 为准。

## 1. 架构与边界

```mermaid
flowchart TD
    U[LightIsle.app<br/>SwiftUI 管理控制台] -->|本机私有 IPC: 初始化/监控/控制/退出| C[Go NAS Core<br/>仅 App 存活时运行]
    A[Vue Web 用户端<br/>账号/文件/图库/影视] -->|浏览器受控 HTTP(S) REST| C
    FC[Flutter 用户客户端<br/>Android / macOS / iOS] -->|会话鉴权 HTTP(S) REST| C
    B[其他设备浏览器<br/>已有 Web 访问] -->|App 开启时的 LAN HTTP(S) API| C
    C --> D[(SQLite WAL<br/>统一索引/任务/业务)]
    C --> F[macOS 数据卷<br/>本机/外置磁盘]
    C --> M[媒体任务队列<br/>限并发/按需启动]
    M --> S[Swift 媒体 Worker<br/>ImageIO/AVFoundation]
    M --> V[FFmpeg VideoToolbox<br/>需要时运行]
    C -.->|仅授权操作期间| H[临时 Swift 授权操作<br/>不常驻]
    H --> O[macOS 系统服务<br/>磁盘/电源/共享]
    C -.->|可选 Docker API| X[Colima / Docker VM]
```

- **LightIsle.app**：唯一生命周期拥有者。SwiftUI/AppKit 负责原生首次管理员初始化、系统指标、服务及存储控制台，不内嵌文件/图库/影视用户页面。打开 App 启动 Go，完全退出 App 停止 Go。
- **Go Core**：由 App 启动的普通权限子进程；负责 API、认证/授权、文件访问、统一索引、图库、影视、任务调度、审计、进程监控。**不安装独立 launchd 服务**。
- **Swift Worker**：优先用于 Swift/macOS Framework 的媒体与系统 API；不把大量业务逻辑写在 Swift。
- **Swift 特权操作**：用户授权时才运行受限、临时的辅助操作，不能作为持续运行的高权限守护服务。普通 API 不等于 root 权限。
- **Vue Web**：桌面、平板和 Android 浏览器的用户界面，负责账号登录、文件、图库、影视和账户管理。尚未初始化时只提示用户到 Mac 操作，HTTP 禁止创建首任管理员。
- **其他设备浏览器与 Flutter**：共享受限 REST/HTTP(S) 业务契约；Flutter Android、macOS、iOS 为独立用户客户端，不拥有本机管理员/磁盘操作特权。
- **共享设计系统**：Mac 与 Web 以 iOS 27 / macOS 27 的 Liquid Glass 层级为视觉目标，设计 token 作为语义单一来源。Mac 用系统 SwiftUI 材质；Web 映射实现，并保留各自输入规范。参见 [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)。
- **SQLite**：小型本地数据库。原始媒体始终存储在用户指定的目录，不进数据库。
- **容器服务**：Colima/Docker 作为可选模块，停用或缺失时不能影响核心 NAS。

### App 生命周期是业务约束

- **关闭最后一个主窗口或最小化窗口**，Mac App 仍留在菜单栏，Go Core 与 NAS 服务继续运行；这是产品现行契约。
- **明确执行 ⌘Q / 菜单栏退出**才关闭 Core API、LightIsle 媒体任务及 App 自己启动的子进程。Android 只有 Mac App 正在运行且用户开启远程访问时才能连接。
- 即使 App 崩溃，也必须使用父进程管道 EOF 与 PID/心跳监督防止 Go Core 变成孤儿常驻进程。
- App 没有运行时，不自动开机启动服务器、不保证注销或未登录时远程访问。
- 外部 Docker/Colima 容器是用户独立运行的第三方服务，LightIsle 退出**不自动停止**它们。

具体关闭顺序、错误恢复与真机验收见 [macOS App 生命周期](MACOS_APP.md)。

## 2. 实际仓库结构与数据归属

| 目录/模块 | 现有职责 |
| --- | --- |
| `apps/macos` 与 `Package.swift` | SwiftUI/AppKit 宿主管理端、私有控制 IPC、ImageIO/AVFoundation/Vision/NaturalLanguage 原生媒体与本地 AI Worker |
| `core/cmd/lightisled` | Go Core 入口、原生私有命令处理、备份/扫描任务调度 |
| `core/internal/server`、`auth`、`files` | HTTP 路由、会话和按根授权、受保护的文件/上传/分享/回收站操作 |
| `core/internal/roots`、`storageidentity`、`diskmgmt` | 共享根身份（rootID、generation、目录/卷 Binding）、可租用的物理句柄、管理员磁盘操作保护 |
| `core/internal/gallery`、`cinema`、`mediaworker` | 图库（含本地 OCR/双语场景/私有人物聚类/相似图派生表）与影视 SQLite 索引、媒体任务、Swift Worker 交互及可选 ffmpeg |
| `core/internal/backup`、`tasks` | 文件/SQLite 快照、隔离恢复、任务和告警持久记录 |
| `apps/web`、`apps/flutter` | Vue Web/PWA 与 Flutter Android、macOS、iOS 用户客户端 |
| `scripts`、`tests`、`docs/adr` | 构建/回归/发行门禁、历史架构决策 |

以上是**当前可查看的代码目录**，不再列出未创建的 `native/macos-arm64`、`core/migrations`、`contracts/openapi.yaml`、`packaging/macos-arm64` 作为已存在模块。详细运行/测试见 [DEVELOPMENT](DEVELOPMENT.md)。

### 当前客户端职责边界（2026-10-25 重构后的代码）

| 边界 | 具体实现 | 不应承担的职责 |
| --- | --- | --- |
| Web 根作用域请求 | `apps/web/src/rootRequestTransport.ts`：请求时捕获 rootID、generation 和 context epoch；切根取消请求、拒绝过期响应 | 不管理 Vue 页面选中状态、账号授权或根的实际物理身份 |
| Web 根切换生命周期 | `rootContextLifecycle.ts`（统一请求 AbortSignal、代际与发现序号）和 `rootDiscovery.ts` 的 `chooseDiscoveredRoot`（无副作用的选择决策） | 不用路径或同名卷猜测根身份；消失的已选根不能静默改为默认盘 |
| Web 文件动作 | `apps/web/src/fileOperationsClient.ts`：目标目录查询、移动/复制指令和响应代际检查 | 不自行绕过 Go 文件授权，不承担文件写盘事务 |
| Web 上传本地提示 | `apps/web/src/uploadResumeStorage.ts`：会话缓存 ID、清理旧提示、存储不可用时降级 | 不把浏览器 Storage 当作服务器上传真实状态或已落盘证明 |
| Flutter 上传本地提示 | `apps/flutter/lib/features/files/upload_resume_store.dart` | 不代替后端校验偏移或上传完成 |
| Flutter 文件上传引擎 | `apps/flutter/lib/features/files/file_upload_service.dart`：校验原件、查询权威上传偏移、范围续传及提交确认；`file_upload_stream.dart`：读流与暂停／取消门闩 | 不处理文件管理 UI，不将另一根的上传 ID 发送到当前根，不将本地续传缓存视为提交成功 |
| Mac 通知与服务运行状态 | `NativeAlertCoordinator.swift`、`NativeServicePresenceCoordinator.swift`：告警去重、可选防休眠、Bonjour 广播 | 不启动额外 HTTP 监听或长期后台守护服务 |
| Mac Tunnel 私有 IPC | `TunnelWireCodec.swift`（命令和 URL-safe Base64 JSON）、`TunnelPayloadParser.swift`（类型化响应） | 不直接保存明文 Token、不解析为任意系统 shell 命令 |
| Mac Token 生命周期 | `TunnelCredentialCoordinator.swift`（验证前临时暂存、Keychain 持久化及失败处理）与 Go `tunnel_control.go`（进程内授权） | 不保存 Token 至用户公开 HTTP API/日志；不等同于远程服务端撤销 |

以上是已落地的**部分分层**。入口 `App.vue`、`AppModel.swift`、`ContentView.swift` 仍有较多 UI/状态协调逻辑，后续重构应采取行为兼容的小步迁移，并给跨根、跨账户、重启和异常退出增加回归测试。最新完成度以 [STATUS](STATUS.md) 为准。

## 3. 数据模型与物理身份

- 应用持久化依赖多个有职责边界的 SQLite WAL 数据库（账号/任务/图库/影视等），不是计划中的单一“全量 file_entries 目录索引”或跨数据库联合事务；建表/升级方式以各实际包为准。
- **原始照片、影片及文件始终保存在用户授权卷目录**，外置存储卷（NAS 磁盘）**保持零 SQLite 污染**（仅存放 `.lightisle-appdata` 缩略图缓存与临时分块）；全部 SQLite 数据库统一严格收敛于 Mac 系统盘 `~/Library/Application Support/LightIsle/`。
- **SQLite 拓扑与生命周期边界**：
  - **全局核心元数据**：`accounts.sqlite`（用户、密码盐、会话、多根授权、配额账本、分享链接、WebDAV 凭证、全量审计日志，主进程常驻）；`tasks.sqlite`（系统全局告警、CPU/内存/磁盘度量采样历史）；`downloads.sqlite`（aria2 任务流水、进度、绑定的 rootID 与 generation、发布追踪）；`automation/automation.sqlite`（定时脚本运行历史与通知投递流水）。
  - **按物理根隔离媒体索引**：`gallery-root-<rootID>.sqlite`（对应根的照片/视频 EXIF、GPS、相册、个人收藏，以及本地 Vision AI 派生的 OCR、CJK 二元词与词元索引、场景标签、人脸向量、用户级私有人物聚类与 Float16 图像特征表）、`cinema-root-<rootID>.sqlite`（对应根的影视刮削元数据、剧集、播放进度）、`tasks-root-<rootID>.sqlite`（对应根的媒体扫描、哈希探测等局部任务流水）。这三者随对应存储根的 `RootServices` 动态加载，空闲 10 分钟且无媒体扫描/备份任务时由 `releaseIdleRuntimes` 主动调用 `Close()` 释放句柄；当管理员移除存储根或守护进程启动自检时，自动驱逐缓存运行时并将无引用的 `*-root-*.sqlite*` 归档移入 `retired-roots/`，同时 `NativeUpgradePreflight.swift` 与 `beta-upgrade-preflight.py` 同步检查顶层 `.sqlite` 与子目录 `automation/automation.sqlite` 的只读完整性。
  - **历史遗留兼容**：单根时代遗留的 `gallery.sqlite` 与 `cinema.sqlite` 在当前运行中不再主动打开与写入，仅保留供旧版元数据快照离线恢复兼容。
  - **连接与读写双池并发契约**：写连接池统一使用 `_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1&_cache_size=-512`（媒体库 `-1024`）并保持 `db.SetMaxOpenConns(1)` 单写串行化，彻底杜绝并发写引发的 `SQLITE_BUSY`；同时 `auth`、`gallery`、`cinema` 独立挂载 `mode=ro&_query_only=1` 只读连接池（`rdb.SetMaxOpenConns(4)`），充分利用 SQLite WAL 读写并发特性，确保后台媒体扫描/AI 索引写入期间前端时间线、海报墙与会话鉴权零阻塞。
  - **备份快照边界契约**：`backup` 模块的一致性快照仅包含 `accounts.sqlite`、`tasks.sqlite` 及登记根的 `*-root-*.sqlite`；`downloads.sqlite` 与 `automation.sqlite` 属于易失性运行时数据，不纳入轻量配置灾难恢复。
- 默认根（非限定根）v2 API 与按物理根限定的 `/api/v2/roots/{rootID}/...` 并存；隔离的 v2 多根按 `rootID + generation + 物理 Binding` 租用文件管理器、索引/任务与文件分享。**另一硬盘或同路径新 inode 绝不能重用旧根的成员授权**；无身份确认时根是离线，不根据路径“猜测重连”。
- 外置卷 FSEvents 事件可能丢失或合并，需通过有界周期对账补扫；索引可重建不代表文件已备份。

## 4. 文件生命周期

1. 管理员注册**明确允许访问的数据根目录**，服务端解析符号链接与卷边界，阻断路径穿越。
2. 首次后台扫描建立索引；FSEvents 增量更新，但事件可能合并/丢失，须有定期对账。
3. 文件变化异步投递图库与影视派生索引；任务去重、限频；离线卷只标记 unavailable。
4. 目录改名/移动更新关系并防止 TOCTOU 问题；跨卷移动采用复制-校验-原子确认而非错误假设 rename 原子。
5. 文件回收站不同于“从媒体库移除”；自动清理策略需可配置并明确占用空间。

## 5. 图库架构

- 读取 EXIF、方向、时间及 HEIC/AVIF/RAW 的真实平台支持能力。
- Swift Media Worker 优先调用 ImageIO/QuickLookThumbnailing，统一按尺寸和版本生成缩略图。
- 缩略图落磁盘缓存，可设置容量、LRU/年龄清理，不把原图完整载入常驻服务。
- Web 时间线 cursor 分页 + 虚拟滚动；分区/相册与通用文件列表复用 file_id。
- **Apple Live Photo 实况配对、智能回忆与人物只读共享**：扫描器自动识别同目录同名照片与短视频伴侣（`live_video_asset_id` / `live_companion_of`），时间线默认聚合展示并在 `/live-video` 提供 Range 流与成对打包导出；基于拍摄时空/GPS/收藏聚类生成虚拟回忆卡片（`/api/v2/photos/memories`）；支持将所有者本人可写目录内的 Vision 人物聚类零拷贝只读共享给指定家庭成员（`/api/v2/photos/person-shares*`）。
- **本地离线 Vision AI 管道**：由短生命周期 `LightIsleMediaWorker ai-batch` 子进程通过只读文件描述符（单批最多 16 项，`QOS_CLASS_UTILITY` 低优调度与 `thermalState == .critical` 过热限流）调用 Apple 原生 Vision / NaturalLanguage 完成简繁英 OCR、双语场景分类、人脸特征（ANFRv4 128D / FeaturePrint 768D + 睁眼度 EAR）与图像特征/清晰度/美学分析，退出即释放全部模型内存，零外部模型下载与公网请求；Go `gallery` 在常规扫描空闲时以单并发槽位（`aiSlots=1`）增量写入派生表并支持暂停（含宿主机 `pmset` 断电供电联动自动暂停），服务端 `/api/v2/roots/{rootID}/photos/{persons,person-shares,memories,faces,cleanup/similar,{id}/ai}` 路由、人脸头像 ETag/304 协商、MCP 工具及 Web/Flutter 客户端界面均已全链路闭环（详见 [STATUS](STATUS.md)）。

## 6. 影视与播放策略

播放协商三层策略：**Direct Play（含 `.strm` 安全校验后的客户端 `307` 直连）→ Direct Stream/Remux（如确有必要）→ Transcode**。

- Web/Android 上报解码及容器支持能力，不仅根据文件扩展名猜测。
- HTTP Range 流式返回文件；支持鉴权和读取边界，不缓存整个媒体。
- 字幕、音轨、HDR、HEVC 的具体兼容性需要矩阵化真机测试。
- 视频处理使用 macOS 宿主机进程和 VideoToolbox；不期待 Linux Docker VM 使用 Mac GPU 转码。
- 转码工作队列设置并发、超时、资源限额、断连回收、临时目录空间上限。
- 第三方影视元数据与海报抓取属可选增强，有速率限制、失效缓存与手工纠正入口。

## 7. macOS-only 约束与运维

- Go 构建目标为 `GOOS=darwin GOARCH=arm64`；Mac 原生 App 是 Core 唯一生命周期所有者，关闭窗口仍提供菜单栏 NAS，⌘Q/明确退出停止服务。父进程 EOF/终止处理必须防止孤儿 Core 和媒体任务。
- 文件、SMART/磁盘、Time Machine、SMB 及系统安全验证均优先采用 macOS 系统能力或有严格白名单的程序；高权限 SMART 请求由 Mac 用户手动授权，不在 HTTP 暴露任意 shell、系统盘格式化或系统权限绕过。
- Docker/Colima 是**用户预先安装的可选引擎**。LightIsle 可按需管理但不捆绑、不在启动时依赖 VM，退出不关闭用户已有容器。
- FileVault、无用户登录、网络证书、系统休眠与外接盘真实安全行为必须分别真机验收；**不承诺 Mac 关机后仅靠软件能提供 NAS**。

## 8. 当前 API 与客户端约定

- **当前唯一 HTTP 契约为 v2**：认证、设置、系统与默认共享目录访问使用 `/api/v2/...`；指定物理根的文件、照片、影视、任务等使用 `/api/v2/roots/{rootID}/...`，并在修改请求中校验 `X-LightIsle-Root-Generation`。旧 `/api/v1/...` 路由已停用，新项目不维护旧客户端兼容或数据迁移。
- 请求使用已认证会话并按操作检查管理员身份或成员授权；文件/分享/媒体访问每次校验真实根目录身份和访问范围。Mac 物理文件夹选择、离线恢复与宿主系统命令只使用私有 IPC。
- 分页、分块上传、Range 下载与任务取消/重试以实际 handler 为准；错误目前常用 `{"error":"code"}`，**没有宣称存在的 OpenAPI 自动 SDK 或统一四字段错误 JSON**。
- 音视频转封装/转码依赖可选本机 FFmpeg，按需 HLS、字幕与音轨能力见 [功能状态](STATUS.md)；正式播放能力受浏览器解码、ffmpeg 安装及真实设备测试限制。

详见 [Mac 应用生命周期](MACOS_APP.md)、[跨端设计系统](DESIGN_SYSTEM.md)、[安全](SECURITY.md)、[性能](PERFORMANCE.md)、[开发指南](DEVELOPMENT.md)。

