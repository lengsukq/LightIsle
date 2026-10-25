# LightIsle：个人用户 / 极客用户对标与代码现状复审（2026-10-25）

> 本文是**代码与产品需求的对应表**，不是已经发布的功能承诺。复审工作区 `/Users/leo/Documents/code/Lightlsle`，Git 基线 `main` / `a662463`，审查时工作树**非干净状态**。包括影视转码与文件排序、冲突策略在内的多项修改仍未提交；其他开发任务可能持续改变工作树。本文只记录检查当时的观察，不覆盖 [个人版产品边界](FNOS_PARITY_PRIORITIES.md) 和 [影音实施明细](CORE_LOOP_PLAN_2026-10-25.md)。

## 1. 双人群定位与优先级原则

| 用户画像 | 主要任务 | 必须首先满足 | 进阶但不应强制安装 |
| --- | --- | --- | --- |
| 普通个人 / 家庭 | 外置盘存储、手机照片备份、家庭影片、文件分享、远程访问 | 安全文件操作、原始数据保护、可理解的失败状态、备份核实、一致的移动端体验 | AI 相册、照片 OCR、自动整理 |
| 极客 / 开发者 | 把现成 Mac mini 用作家庭服务器；观察资源、管理已有 Docker/Compose、接入自己的网络与自动化 | 生命周期与网络可诊断、磁盘状态、最小授权、安全的容器管理、可恢复的配置 | Webhook、只读 API Token、更多运行指标、可选 restic/rclone 集成 |

**决策**：不造第二套 NAS 操作系统。仅支持 macOS arm64 宿主；文件系统、SMB、Time Machine、Spotlight/FSEvents 交给 macOS；Docker 引擎由用户自行提供；不自建 RAID、存储池、联合事务灾备、通用终端或内网穿透协议。不以“极客功能”为由提高基础 Core 的常驻资源开销。

## 2. 判断状态的标准

- **已有代码**：能指向实际实现/API/客户端；不意味着部署成功。
- **开发中**：本地出现未提交实现，或仅 API / 部分客户端接入，不能视为完整交付。
- **待验收**：源码/测试存在，但缺相关真实设备、系统权限、外部服务或长期运行证据。
- **缺失/后置**：没有找到对应端到端能力；某个关键词、文档规划或测试替身不算实现。
- **正式发布**：还需根据 `docs/PRODUCTION_RELEASE.md` 完成真实硬件、恢复、签名、公证、干净安装与持续稳定性门禁；任何本地开发构建都不等于正式发布。

## 3. 当前代码与用户需求矩阵

| 模块 | 当前已有代码 / 来源 | 当前结论 | 普通用户缺口 | 极客用户缺口 |
| --- | --- | --- | --- | --- |
| 宿主与服务常驻 | `apps/macos/Sources/LightIsle/AppModel.swift`：Go 子进程、菜单栏/登录项 `SMAppService`、在线时禁止空闲休眠；`core/cmd/lightisled` | 已有代码，GUI/注销/睡眠待验收 | 重启与断连解释、开机后服务状态引导；无人登录不承诺继续服务 | 服务进程/唤醒诊断、历史事件与异常恢复 |
| 文件/权限 | `core/internal/files/`、`core/internal/auth/file_grants.go`、`core/internal/server/files.go`：分页、文件操作、回收站、Range、ZIP、授权 | 核心已有；真实盘故障待验收 | 文件夹选择器、预览/缩略图、回收站策略、易懂的冲突交互 | 大目录分页性能、批处理可观测性 |
| **文件排序** | `core/internal/files/pagination.go` 的未提交 `PageSorted`；`core/internal/server/files.go` 的 `sort/dir` 参数 | **开发中，仅后端增量** | Web/Flutter 选择排序入口、游标切换行为 | 大文件夹性能与排序稳定性回归 |
| **同名冲突** | `core/internal/files/operations.go`、`core/internal/server/file_operations.go`、`uploads.go` 的未提交策略 | **开发中，仅后端增量**；现有 `skip`/`rename`/拒绝；**没有替换（overwrite）** | Web/Flutter 的明确冲突弹窗、最终路径提示；上传与操作一致 | 并发创建/改名、原件安全与路径授权的测试 |
| 外置盘与存储 | `core/internal/diskmgmt/`、`diskhealth/`、`storageidentity/`；`apps/web/src/DiskManagement.vue`；Mac 存储页 | 设备与健康详情已有；真实 USB/SATA 桥接、管理员权限与多盘待验收 | 插拔状态、数据卷与备份卷区分、一页式数据保护提示 | 温度/SMART 变化历史、告警阈值、IO 诊断 |
| 多根共享 | `core/internal/roots/`、`auth/root_grants.go`、`server/root_routing.go` | 隔离开发预览；默认个人版未正式开放 | 多个真实外接盘同时使用、断开重连 | 按根授权、跨根索引/备份与升级迁移验收 |
| 备份/恢复 | `core/internal/backup/`、离线 `lightisle-recovery`、Mac 原生身份确认；macOS Time Machine 只读检查与引导 | 已有开发实现；**真实独立介质恢复**待证明 | 数据盘是否被 Time Machine 覆盖的明确风险提示、账号/授权/相册恢复验收 | 备份状态/恢复验证记录；可选接入成熟备份工具 |
| 图片/相册 | `core/internal/gallery/`、`apps/web/src/PhotosView.vue`、Flutter 图库 | 时间线、相册、收藏、缩略图已有 | 2048px/原图渐进查看、Live Photo/RAW、批量整理 | 本地 Vision OCR/重复检测可后置 |
| Android 手机备份 | `apps/flutter` 原生后台调度与哈希核对；见 `BETA3_REAUDIT_2026-10-23.md` | 已有开发版；真机省电/锁屏/大量照片待验收 | 首次大图库快速补跑、清晰的最后成功时间、断线恢复 | 备份任务诊断与流量策略 |
| iOS 端 | `apps/flutter` 有 iOS 客户端、文件/图库/播放器 | 客户端已有；照片自动备份**不得按 Android 同等完成度标记** | 至少先闭环前台照片备份与权限体验 | 证书、后台约束和真实机型验证 |
| 影视 | `core/internal/cinema/`、`server/cinema.go`、`apps/web/src/CinemaView.vue`、Flutter 影院 | 直放、Range、外挂字幕、观看进度、手动元数据已有 | 海报墙、播放器错误反馈、大库体验 | 任务/缓存/转码资源监控 |
| **影视新能力** | **未提交**的 `cinema/transcode.go`、`hls.go`、`series.go`、`scrape.go`、`ffmpegbin/`、`server/cinema_transcode.go`，Web/Flutter/Mac 增量 | **开发中**：HLS/VideoToolbox、字幕轨、剧集、TMDB 后台刮削已写入代码；仍须真实 ffmpeg、浏览器/Android/HLS/凭证验证 | MKV 起播、拖动、字幕/音轨、下一集、自动刮削准确性 | 资源上限、降级、磁盘缓存、转码失败日志 |
| 局域网/协议 | HTTPS、Bonjour、系统 SMB 引导、`core/internal/dav/`、独立 WebDAV 凭据 | 核心已有；Finder/Windows/Infuse/真实证书验收不足 | 非开发者也能完成连接、核对证书、撤销访问 | IPv4/IPv6/DNS/端口/证书诊断、WebDAV 兼容性 |
| 异地访问 | `core/internal/tunnel/`、`cloudflareapi/`，Mac Keychain Token 管理 | Cloudflare 快速/命名隧道开发版；真实账号、DNS、代理环境待验收 | 清楚的在线状态与网络失败引导 | 运行日志、连通性检查、代理冲突处理 |
| Docker/Compose | `apps/macos` 原生 Docker 管理，见 `DOCKER_MANAGEMENT.md` | 本机按需管理已有容器、镜像、Compose/卷/网络；真实引擎验收不足 | 非基础 NAS 必需 | 增量日志、容器健康与资源曲线、更新预览；不向普通远程 Web 开放 Docker 特权 |
| 运维/告警 | `core/internal/tasks/`、审计/告警 API、Mac 通知、系统网络/IO 指标 | 现时指标与持久告警已有 | 简洁的问题解释和恢复入口 | 时间序列、Webhook/邮件（谨慎保存凭据）、任务事件关联 |
| 发行 | `scripts/build-macos.sh`、`scripts/verify-release-qa.py`、`docs/PRODUCTION_RELEASE.md` | **开发版，正式发布门禁未满足** | 一次安装/升级/恢复有实际证据 | 发布日志、诊断导出、回滚支持 |

### 需同步修正的旧判断

1. `CORE_LOOP_PLAN_2026-10-25.md` 第 4 批把“排序、冲突”写为未开始；**最新本地工作树已出现后端实现**，但 Web/Flutter 尚未贯通。这里用“开发中”而不是“未实现”或“已完成”。
2. 同名覆盖不应作为默认方案：当前后端刻意**不支持替换已有文件**。如将来要做替换，须单独设计原件回收站/备份、确认和并发原子性，不与 `skip/rename` 混称为已实现。
3. 影视新功能位于未提交工作树；单测或构建即使通过，也不能替代 FFmpeg 真机转码、Safari/Chrome、Android HLS、真实 TMDB Token 端到端证据。
4. 文件/图库/影视“核心已有”不等于多根正式可用，旧功能页也不代表新的 `rootID` 授权路径已经全部验收。
5. Docker 和 cloudflared 都**只管理用户已安装的外部能力**；不作为 Go Core 启动依赖，不承诺全自动安装或稳定公网访问。

## 4. 官方产品对标：只取适合 Mac 管理层的做法

| 产品 | 官方已介绍的典型能力 | LightIsle 该学的 | 明确不照搬 |
| --- | --- | --- | --- |
| [飞牛 fnOS](https://help.fnnas.com/) | 文件/相册自动备份、共享、影视、远程访问 | 手机上手/备份反馈、媒体库授权、家庭共享、日常闭环 | Linux NAS 系统与应用市场完整生态 |
| [ZimaOS](https://www.zimaspace.com/docs/zh/zimaos/features) | 文件与 SMB、远程访问、应用管理/Compose、存储管理 | 初次配置简洁、网络与应用状态集中展示、已有 Compose 的轻量管理 | 内建 RAID/ZFS、全套 Linux 容器平台 |
| [Unraid](https://docs.unraid.net/unraid-os/getting-started/set-up-unraid/customize-unraid-settings/) | Docker/插件与分类通知、外部通知渠道 | 有区别的系统/备份/Docker 告警和历史记录 | 阵列/虚拟化平台及插件市场 |
| [OpenMediaVault](https://docs.openmediavault.org/en/latest/features.html) | SMART、共享协议、计划任务、服务诊断 | 硬盘故障预警、只读诊断、受限计划任务 | 完整 Linux SMB/NFS/SSH 服务管理 |

以上是**竞品现有公开能力与借鉴方向**，不是 LightIsle 的实现声明；外部官方文档会继续变化。

## 5. 建议实施顺序（不改变此前已确认的影音优先主线）

| 优先级 | 一组完整可验收结果 | 开发关注点 | 必须提供的证据 |
| --- | --- | --- | --- |
| **P0 发布门禁，并行持续推进** | 数据不会因拔盘/满盘/断电/错误恢复而被误删或越权；登录项与 GUI 生命周期如实工作 | 磁盘身份、跨卷失败保源、数据库离线恢复、Time Machine 实际覆盖、权限边界 | 真实可丢弃双盘、断网、干净用户、72 小时、签名/公证记录 |
| **P1-A 当前进行中** | 影院能播真实 MKV、正确处理多音轨/内嵌字幕、剧集归类与自动刮削 | 完成现有未提交影视增量；修复真机发现的问题 | ffmpeg/remux/transcode、浏览器/Android HLS、TMDB Token 和失败降级 |
| **P1-B 下个高频批次** | 文件管理不需手输路径；排序、同名处理、缩略图、原图预览完整可用 | 串通现有后端排序/冲突增量与 Web/Flutter UI，保持老协议默认行为 | 分页排序、并发冲突、上传续传、只读账户、错误恢复 |
| **P1-C 家庭设备** | Android 首次备份大图库可追踪进度，iOS 前台备份可用 | 背景任务、权限/取消与 SHA 校验；多设备登录/重连 | Android 实机锁屏/省电/断网；iOS 真机照片权限与备份 |
| **P1-D 极客增强** | Docker/网络/磁盘出现问题能定位原因而非只看到失败 | 真实 Docker 引擎、诊断页、指标历史、分级告警；可选 Webhook | Docker Desktop + Colima、局域网/隧道、SMART 兼容性测试 |
| **P2 按需** | OCR、Live Photo/RAW、文件夹分享、restic/rclone 引导、有限权限 API | 必须可关、资源有界、原文件安全；不新增大型系统依赖 | 用户明确需求后再立项 |

## 6. 不应误判为缺口的事情

- **没有独立 RAID 管理**：由 macOS 与物理备份策略承担，属产品边界，不是必须补的 P0。
- **没有 Web 端高权限 Docker 终端**：是安全边界；不能为对标竞品直接开放。
- **没有自研增量备份引擎**：优先 Time Machine、可验证 SQLite 导出/恢复和可选成熟工具引导。
- **App 完全退出即停止 Core**：是当前明确的生命周期契约；真正的“无人登录仍常驻”必须先作为独立架构决策，而不能偷偷更改。
- **没有内置 FFmpeg 或云服务账户**：应明确显示不可用原因，不破坏原本直放和本地文件能力。

## 7. 复审方法与待验证项

- 已核对工作树状态、核心 API 路由、文件操作及分页的未提交差异、Web 当前文件操作交互、macOS App 的登录项/休眠控制、Docker/Flutter/备份/安全/发行文档；路径可在本仓库直接检索。
- **2026-10-25 非缓存回归**：执行 `go test -count=1 ./core/internal/files ./core/internal/server ./core/internal/cinema`，其中 `server` 和 `cinema` 通过，`files` 最初因为**同时正在修改**的冲突策略代码出现两个失败：`TestMoveConflictRename`（曾得到 `movie (2) (3).txt` 而不是 `movie (3).txt`）以及 `TestNextRenameCandidate`（保留内部名称生成未被拒绝）。随后复查 `operations.go` 时，这两处逻辑已在工作树中被另一个正在进行的修改修正；重新独立运行 `go test -count=1 ./core/internal/files` **通过**。说明代码仍在实时变化，不能把第一轮失败当作最终持续故障，也不能把后续测试通过当作 Web/Flutter 端到端完成。
- 尚不能由代码浏览证明真实硬盘、移动端、Finder/Infuse 挂载、Cloudflare DNS/隧道、ffmpeg 实际转码和 Apple Developer ID 公证成功，全部保留验收标记。
- **禁止**因为文档更新直接将未提交业务代码视为可发行、覆盖其它任务正在修改的工作树，或修改生产发布 Gate 要求。
