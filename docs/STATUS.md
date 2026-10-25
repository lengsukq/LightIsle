# LightIsle 当前功能与闭环状态

> 2026-10-25 代码级审查基线。这里是对既有 P0/P1、Beta 和功能缺口文档的**唯一现状入口**；以后审查应先核对当前 Git HEAD 和测试退出码，再更新本表。状态不表示已通过真机测试或 Apple 公证。具体设计看 [架构](ARCHITECTURE.md)、[产品范围](FNOS_PARITY_PRIORITIES.md)、[发行门禁](PRODUCTION_RELEASE.md)。

## 评价标准

* **代码闭环**：用户入口 → 授权/身份绑定 → API/私有 IPC → 持久化 → 错误反馈/恢复 → 自动化回归。
* **部分闭环**：有代码及测试，但关键边界、自动维护、跨端体验或恢复流程尚缺。
* **设备待验收**：不等于功能代码缺失；必须用可丢弃的外接盘、真实手机或正式签名环境取证。

## 全业务功能矩阵

| 模块 | 已有代码能力 | 尚不能承诺的部分 |
| --- | --- | --- |
| 管理员、普通成员及会话 | Mac 初始化/所有者身份重置、Argon2id、SQLite 会话、禁用及撤销，成员按目录授权 | Touch ID、局域网 HTTPS 和多端旧会话真机需验收 |
| 文件管理与传输 | Web/Flutter 浏览、排序/分页、搜索、有授权的上传续传、SHA-256、同名策略、预览、文件夹 ZIP、回收站/原路径恢复 | 异盘、断电、满盘、超大上传和真实 GUI 验收；不要宣称跨盘目录级事务移动 |
| 文件分享 | 有期限、密码/次数限制的单文件与**文件夹**分享（目录为有界流式 ZIP，复用密码/次数/限流与 404 均一化，按所有者授权逐项复检）、代际及权限回查、撤销 | ZIP 流式下载不支持断点续传；公网访问需单独验证 |
| 图库 | 增量索引、缩略图、时间线、共享/私人相册、按账号收藏与权限过滤 | Live Photo 成对动图播放器、超大图库性能和相册迁移尚未全部闭环 |
| 影视 | 电影/剧集索引、观看进度、字幕、NFO/TMDB/豆瓣候选、受限 HLS/按需 FFmpeg 能力 | FFmpeg、字幕音轨、浏览器实际解码、外部信息源和公有素材全要实测；不保证所有格式直放 |
| 单共享目录与磁盘 | 验证物理目录身份；只读/离线/NTFS 提示；管理员有限磁盘操作；拒绝危险系统盘操作 | USB 桥接/重挂、满盘、设备 ID、改名弹出等必须在可丢弃真实硬盘测试 |
| **多目录/多硬盘** | v2 rootID/generation 独立文件/媒体/任务/ACL、私有 Mac 登记、跨盘 rebind 权限继承漏洞已修复 | **仍默认开发预览**；旧授权、私人相册、历史资料迁移和逐根备份计划未闭环 |
| 多根媒体自动维护 | 仅开发预览：额外根启动/周期串行图库与影视重扫，离线/占用后安全重试，重新上线补扫；SQLite 按 rootID+generation 记录上次成功/中断，Mac 原生显示状态 | 不等于备份文件；无额外根自动备份计划、真实拔盘验收 |
| 本机备份和离线恢复 | SQLite/配置与共享文件快照、校验暂存、Mac 所有者确认、离线激活及原元数据回退；定时任务 | 不实现企业级文件+数据库联合事务；真实独立介质/72h/恢复路径必须验收 |
| 运维、告警与磁盘健康 | CPU/内存/网络/磁盘 48h 有界历史、任务日志、低空间/失败去重告警、SMART 按盘身份保存最多30天/360次记录 | SMART 历史是**用户按需读取**产生，不是全天候采集或逐盘自动通知；读不到状态显示未知 |
| WebDAV/网络 | 独立可撤销凭据、按授权目录读写、HTTP 安全限制；可选 Bonjour/LAN HTTPS/Cloudflare Tunnel 本地管理 | Finder/Infuse/外网真实令牌 DNS、证书、代理与手机网络验证尚缺 |
| **下载中心** | 监督本机已装 aria2（白名单，未装诚实降级）；HTTP/HTTPS/FTP/磁力；暂存区→安全发布（不覆盖、发布前复检授权）；暂停/继续/重试/取消；`download_failed` 持久告警；Web 任务页 | 真实公网大文件/磁力全生命周期、多根预览支持、Flutter 端入口均未做；不做 PT/RSS/做种 |
| Docker / Colima | 只在 Mac 本机管理已安装的引擎、容器、卷/网络与 Compose 项目 | 不内置、不自动安装 Docker；需要真实引擎验证 |
| Android / iOS 媒体备份 | 前台照片、显式开启的视频与 iOS Live Photo 配套 MOV，SHA-256 校验、续传/不覆盖；Android 后台可选 WorkManager **照片**备份 | Android 后台不是视频备份；前台 Android 单原片 >2GiB、后台 >100MiB 不能静默当成功；iOS iCloud 原件不自动下载 |
| 公共发行 | macOS arm64 本地开发构建、随包冒烟、代码安全回归 | **正式版本仍未通过** Developer ID 签名/公证、Gatekeeper、实盘/实机和长测 |

## 关键修复与自动化证据摘要

1. **P0 权限隔离**：旧注册根被重新指到另一磁盘或同路径不同 inode 时，不得继承原 rootID 与成员授权；只有相同物理目录重新挂载后可重绑，媒体缓存与分享受 generation 约束。对应测试位于 `core/internal/roots`、`core/internal/server` 和 `core/cmd/lightisled`。
2. **多根自动补扫**：原兼容目录继续用 FSEvents，额外根仅在启用预览时约每15分钟逐一扫描；离线/人工占用约每分钟重试。扫描记录持久化在 `tasks.sqlite`、不存磁盘路径/序列号；状态有 pending/running/ok/offline/busy/failed/interrupted，Mac 目录设置页手动刷新查看。新一代根不会沿用旧代际的成功状态。
3. **媒体备份及容量边界**：Android/iOS 选视频前明确授权，旧默认仍只备份照片；无声跳过大文件的情况需反馈具体遗漏数量，失败不能报告完整备份。
4. **测试证据（2026-10-25 这次检查时）**：`go test -race ./...`、`go vet ./...`、macOS Swift Release 与 Web 类型检查/构建通过；模拟离线根 → 同一物理目录重连 → 分根扫描及 SQLite 世代持久化通过。其他轮次的 Flutter 全量回归和 iOS/Android 编译仅代表当次本地构建，不替代真实设备。
5. **多目录 v2 接口回归修复（2026-10-25）**：`/files/thumbnail` 改为实际 512/2048px JPEG 缩略图处理器，并补齐 HEAD；使用临时 PNG 与 macOS `sips` 实际转换，确认 JPEG 可解码、大小不越界。回收站自动清理策略透传相同的 `RetentionStore` 给多根预览下的 v1/v2 接口，管理员和成员权限、动态修改后的状态均有回归测试。详见 `core/internal/server/root_routing.go`、`root_routing_test.go`。这些修复**不代表**多根迁移与独立备份已可对外正式启用。
6. **可选 FFmpeg 测试隔离（2026-10-25）**：原 HTTP 降级测试曾假设开发机没有安装 Homebrew FFmpeg，在安装环境会误报失败；已通过明确的测试工具注入保持降级场景可重复，不更改生产环境 FFmpeg 白名单或视频处理策略。本次 `go test ./core/...`、关键包 `go test -race`、`go vet ./core/...` 与 Web 单测（55 项）通过；真机/大负载/正式发行仍须单独取证。
7. **Clean Code 职责拆分（2026-10-25）**：Web `App.vue` 已抽出 `rootRequestTransport`（根代际和中断隔离）、`fileOperationsClient`（移动/复制及目录查询）、`uploadResumeStorage`（浏览器本地续传提示；受限 `sessionStorage` 失败不阻止上传）；照片/影院按需加载，HLS 播放器按实际需要加载。macOS `AppModel.swift` 已抽出 `NativeAlertCoordinator`、`NativeServicePresenceCoordinator`、`TunnelWireCodec`、`TunnelPayloadParser`、`TunnelCredentialCoordinator`；Flutter 文件上传的本地续传提示拆为 `upload_resume_store.dart`。新增 Web/Swift/Flutter 回归。**这是阶段性职责拆分，不代表所有巨型页面已重构完毕。** 具体边界见 [ARCHITECTURE](ARCHITECTURE.md) 与 [MACOS_APP](MACOS_APP.md)。
8. **隧道配置安全闭环（2026-10-25）**：修复 Go Core 首次配置 Cloudflare API Token 误要求已有凭据；`configure` 响应明确标记后才保存暂存 Token，Keychain 替换失败保留旧凭据并反馈错误；“忘记 Token”同时删除本机钥匙串项并请求清除 Core 的内存授权；Core 退出后清空旧授权状态，以便下次启动重验。IPC 数据编码有操作白名单及大小限制。这里的“忘记”**不是去 Cloudflare 服务端撤销 Token，也不保证停止已启动的隧道进程**；公网访问停用需单独执行停止/撤销操作。详见 [REMOTE_ACCESS](REMOTE_ACCESS.md)。
9. **自动化证据与边界**：`scripts/verify-macos.sh` 在上述代码修改后通过（Go 测试及 vet、Swift 调试编译、原生 IPC/Token/告警相关检查、Web 55 项测试及生产构建、发行验证脚本的模拟校验）；Swift Release 编译、Flutter `analyze` 无问题，Flutter 测试 **127 通过、1 跳过**。Web 构建仍有按需 HLS 资源超过 500 kB 的提示。**这些是代码级验证，不等于真机浏览器上传、断网重试、Mac 钥匙串权限故障注入、外置盘或 Apple 公证已验收。**

## 仍应优先完成的 P0/P1

1. **P0**：旧单根→多根的授权/私人相册/续播进度预览与迁移；必须先展示差异、取得管理员确认，绝不自动把旧权限转给新盘。
2. **P1**：每根独立备份目的地、可启停的计划与明确恢复选择；不能默认复用当前 NAS 数据盘当备份盘。
3. **P1**：大视频/照片在 Android 后台、iCloud 未落盘场景、Live Photo 成对展示的端到端体验。
4. **P1**：磁盘 SMART 可选后台检查/通知须按 macOS 真实权限和休眠策略设计；现有按需历史不代表已完成该能力。
5. **发布阻断**：真机外接盘故障注入、独立恢复、网络/手机兼容、规模与 72h、正式签名公证。逐项证据留在 [真机验收债清单](ACCEPTANCE_DEBT_2026-10-25.md)；完整拒绝条件见 [PRODUCTION_RELEASE](PRODUCTION_RELEASE.md)。

### 尚未完成的代码质量重构（不等同于 P0 产品缺口）

- Web `App.vue` 仍集中大量文件/上传界面状态、分享与任务流程；继续按根作用域和职责拆分 composables/子组件，避免跨根异步结果覆写。
- Swift `AppModel.swift` 与 `ContentView.swift` 仍偏大；后续按存储、备份/恢复、界面区域拆分，并保留 Core IPC 与 Keychain 的安全边界。
- Flutter 文件/影视 StatefulWidget 与部分动态 JSON API 仍较重；逐步抽取状态机和类型化 DTO，优先补组件交互、设备行为测试。
- 真实 GUI、设备及恢复演练仍由 [ACCEPTANCE_DEBT](ACCEPTANCE_DEBT_2026-10-25.md) 跟踪，不得用单测通过代替。

## 如何维护

- 不再为每个修复创建新的 `P0_P1_*.md` 或日期复审表；更新本文件对应行、附相关代码与真实退出码。
- 功能**设计与稳定行为约束**分别放在 [STORAGE_AND_DISKS](STORAGE_AND_DISKS.md)、[REMOTE_ACCESS](REMOTE_ACCESS.md)、[M5_OPERATIONS](M5_OPERATIONS.md) 或其他专门的规范中。
- 旧阶段成果的来源清单、当时局限和历史 Git 恢复方法统一在 [HISTORY](HISTORY.md)，不要把当时的“未实现”当成今天的状态。
