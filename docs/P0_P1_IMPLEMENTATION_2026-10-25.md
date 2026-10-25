# 个人 NAS P0/P1 交付与验收记录（2026-10-25）

> 记录当前 Lightlsle 本地工作树的实现和验证，不代表远端 main 或正式发布状态。另有开发任务正在同步修改影视、分享、缩略图、回收站等未提交文件，不能冒认或覆盖。产品定位见 [个人/极客代码复审](PERSONAS_AND_CODE_AUDIT_2026-10-25.md)、[影音闭环计划](CORE_LOOP_PLAN_2026-10-25.md)。

## 1. 本轮代码交付

| 工作项 | 实现与代码位置 | 验证状态 |
| --- | --- | --- |
| Web 文件分页排序 | App.vue 把 name/size/mtime、asc/desc 传给文件分页 API；排序变更重载第一页、旧请求不能覆盖新状态 | Web 生产构建通过 |
| Flutter 文件分页排序 | files_page.dart 中加入排序菜单，请求保留 sort/dir | 新增 widget 回归通过 |
| Web 移动/复制选择目录 | 新增 apps/web/src/FileOperationDialog.vue：仅浏览授权根、目标文件名、skip/rename/拒绝冲突策略；不再手输完整路径 | Web 类型检查与构建通过 |
| Flutter 移动/复制选择目录 | 新增 apps/flutter/lib/features/files/file_destination_dialog.dart：目录浏览、写权限检查、同名策略、安全提示 | 新增 widget 回归通过 |
| Web 文件缩略图与预览 | 文件列表请求已接入的服务端文件缩略图 API；HEIC/HEIF 使用 2048px JPEG 预览，PDF 使用在线预览 | Web 构建通过，真实浏览器与图片格式待验收 |
| Web 上传同名自动改名 | 上传区新增加开关，默认关闭；保留分片续传与不覆盖原件原则 | UI 已接入，上传与重名结合仍需手工联调 |
| 上传重名逻辑修复 | core/internal/server/uploads.go：连续冲突始终根据最初文件名生成 (2)、(3)，防止嵌套后缀 | 新增真实 HTTP handler 回归通过，已有文件内容不变 |
| Web 限时分享增强 | 提供可选访问密码、最大下载次数，复用服务端已新增 SharePolicy 接口 | UI 与请求接入，匿名计数验收待完成 |
| P0 SQLite 恢复回归 | core/internal/backup/recovery_state_test.go 同步分享接口新参数 | 单独 backup 全部测试通过；不代表真实异盘恢复 |
| P1 macOS Swift 6 兼容 | AppModel.swift 将 SMART 提权回传改为主 actor 隔离方法；SmartElevation.swift 去除不必要的 try，消除可升级为 Swift 6 错误的并发捕获警告 | 修正后重新执行 Swift release 构建，退出码 0，未见相关编译警告 |
| Flutter 窄窗口导航回归 | responsive_shell_test.dart 等待账号菜单真正可见后再点击 | 320×568、1024×480 等 10 组窗口/文字缩放通过 |

## 2. P0：不能冒充已经验收的发布门禁

| P0 | 已有代码基础 | 尚需真实完成 |
| --- | --- | --- |
| 磁盘与文件原件安全 | 卷身份、路径授权、离线保留、跨卷复制与上传失败保源 | 两块可丢弃物理盘，重插/错盘/断电/满盘、原件哈希核对 |
| 元数据备份和回滚 | SQLite 一致性快照、离线激活、旧副本保留和测试 | 独立备份介质上真实账号/目录授权/私人相册恢复与回滚 |
| 数据卷备份覆盖 | macOS Time Machine 只读诊断和引导 | 检查外置 NAS 数据卷确实由另一块物理备份盘覆盖；不把本地快照当独立备份 |
| App 生命周期 | 菜单栏常驻、用户登录项、Go 父子进程及防空闲休眠 | 真实关窗、退出、强杀、注销、睡眠唤醒、用户未登录状态 |
| 认证与网络 | LAN HTTPS、Bonjour、WebDAV、Cloudflare Token/隧道 | Android/iOS 真机证书变更和断网重连，Finder/Infuse，真实公网 DNS/代理 |
| 正式发布 | 开发签名包和发行检查脚本 | 72 小时真实稳定性、干净安装升级、Developer ID、公证与 Gatekeeper |

多共享根仍是隔离开发预览，不能对普通用户宣称正式可用。产品刻意不自研 RAID、联合文件/数据库事务灾备、第二套备份引擎，不把 Docker 或 FFmpeg 当 Core 强制依赖。

## 3. P1：仍未全部闭环

1. 影视：HLS/VideoToolbox/内嵌字幕和音轨切换、剧集自动刮削虽然已有并行开发实现，仍缺真实 FFmpeg、Safari/Chrome、Android 播放、Token/网络端到端验证。
2. 网盘与图库：Web 文件预览已接入，但 2048px/原图渐进、真实图片/视频大库、回收站 TTL 定期运行和分享密码下载次数须再做客户端验收。
3. Android/iOS：Android 后台备份已有 WorkManager 与哈希校验；锁屏/省电/首次大相册补跑未验收；iOS 前台相册备份与照片授权也未正式闭环。
4. 极客运维：已有本机 Docker/Colima/Compose 管理；真实引擎测试、容器资源与健康历史、网络诊断、告警 Webhook 尚不完整，不通过远程 Web 提供特权命令。
5. 所有 UI 仍须物理端浏览器/真机、深浅色、大字体测试，不能把组件和静态检查当最终体验验收。

## 4. 本地测试与实际结果

- Go files/server 非缓存测试通过；新增 TestUploadConflictRenameUsesOriginalNameAndNeverOverwrites 通过，覆盖两次冲突及原文件内容保护。
- Go cinema/ffmpegbin 非缓存单元测试通过；不是实机 FFmpeg 视频验收。
- Go backup 非缓存测试通过；go vet ./... 通过。
- Web npm test：41 项通过。npm run build：类型检查与构建通过；仍有超过 500 KB 的 Vite 分块体积提醒。
- Flutter analyze --no-pub：零诊断；单独 files_test.dart：14 项通过；responsive_shell_test.dart：10 项通过。
- Flutter 全量 flutter test --no-pub：123 项通过、1 项依赖真实 Go Core 的集成用例未配置而跳过。
- Go 全量 go test -race ./... 首次在并行分享接口变更后出现旧测试签名不兼容，已修正恢复用例并单独验证；**第二次全包竞态测试退出码 0，包含 backup、files、server、cinema、gallery 和其余 Go 包，全部通过**。属于代码竞态检查，不代替物理外置盘故障演练。
- bash scripts/build-macos.sh：完整 5 阶段开发打包与随包冒烟退出码 0；产生本机开发签名的 dist/LightIsle.app，绝非 Developer ID / 公证发行包。该次 Swift 编译出现 SMART 回传的未来 Swift 6 严格并发警告，随后已修复，并以 swift build -c release --product LightIsle 二次构建通过，未再出现相关警告。

## 5. 后续需要人机验收的实际步骤

首先用可丢弃的外置硬盘核对 P0 写入/断线/恢复原件安全；随后 Web 浏览器与 Android 真机测试排序、复制移动、断点续传、缩略图与 HLS；再执行 iOS 照片权限/备份、WebDAV、Cloudflare、Docker Desktop/Colima 联调。最后 72 小时稳定性及 Apple Developer ID 公证。任何涉及现有数据盘、系统配置、证书或删除的操作都必须由所有者显式确认，测试默认只用临时虚构数据。

## 6. 第二轮：排除真实验收后的剩余 P1 实施（2026-10-25）

本节记录本地继续开发的增量，**与前面第一轮的测试统计分开**，不能认为这些变动已提交或同步到 GitHub。

| 需求 | 新增能力 | 当前代码验证边界 |
| --- | --- | --- |
| iOS 手机照片前台备份 | Photos 原生只读通道、完整读取权限、游标分页、原片临时导出、用户暂停/临时文件释放、应用重启后私有残留清理；复用 Flutter 前台流、NAS 上传断点续传及两端 SHA-256 原片确认。原片只读、不静默下载 iCloud 远端资源、不覆盖 NAS 不同内容 | Xcode iOS Simulator 编译通过；新增 Flutter iOS 原片尺寸动态处理 / 不调用 Android WorkManager 的 widget 回归通过；iPhone/iCloud 真机未测 |
| 首次大图库补跑 | 前台每轮最多 10 / 30 / 100 页，每页 40 张（400 / 1200 / 4000）；一页完成才保存游标、最近核对时间与全库完成时间，选项放在折叠高级区；后台 Android WorkManager 仍独立 | Flutter 原 123 项用例通过，新增 iOS widget 用例通过；锁屏/电量/系统调度不能通过模拟保证 |
| 个人运维资源历史 | Go 每分钟采样一次 CPU/内存/磁盘占用、上下行速率，用本地 SQLite 保存最多 48 小时 / 2880 条；仅管理员 GET /api/v1/system/history；没有登录名、文件路径、进程名或 IP 历史 | 新增 Go 单元测试验证持久化、无效数据/NaN/越界拒绝；Web 构建通过 |
| 局域网诊断 | 仅管理员 GET /api/v1/system/diagnostics；显示本机网络接口、默认网关、当前请求是否 TLS；固定本地 route 查询并强制 1 秒超时；拒绝任意目标/查询参数，不执行公网 HTTP 请求 | 新增 HTTP 登录权限/参数边界测试通过；不是 NAT/Tunnel 的可达性证明 |
| Web 诊断页面 | 偏好设置 → 任务与通知：3/12/24/48 小时曲线、网卡状态、排障建议；管理员手动导出 JSON | Vue 类型检查与 Vite 构建通过；真实浏览器留待 QA |
| Docker 健康/资源 | 只在点击容器“资源与健康”时，通过验证过的本机 Unix Socket Context 执行受限 docker stats --no-stream / container inspect，显示 CPU、内存、网络/磁盘 I/O 与 HEALTHCHECK 状态 | Swift Release 编译通过；不启动新 Engine、不运行 exec、不提供公网特权接口；真实 Docker 引擎未测 |

**未凭空实现：** 外部告警 Webhook 本次未开放；Mac App 已有可选原生本机通知，本轮继续维持默认不对外发送告警的隐私边界，提供管理员主动导出的汇总。容器长周期历史指标/策略性自动更新、iCloud 远端大规模原片自动预取不属于本轮已完成功能。

**最终自动化回归：** Go tasks/server/lightisled 单测通过；完整 go test -race ./... 于第二次复跑退出码 0（所有包通过）；go vet ./... 通过。Web npm test 共 41 项和 npm run build 通过（仅存在 Vite 500KB chunk 提示）。Swift Release 构建通过。Flutter 全量 124 passed / 1 skipped，新增 iOS 模拟原片备份通过、flutter analyze 零问题。Xcode iOS Simulator（Debug，CODE_SIGNING_ALLOWED=NO）完整编译最后一次重跑 **BUILD SUCCEEDED**。以上均不等价于用户资料实盘/真机/公证验收。

**整包交付状态：** 随后完整执行 scripts/build-macos.sh 的五阶段 Web、Go、Swift、开发签名和随包冒烟，**退出码 0**，本地开发包实际输出到 dist/LightIsle.app（不会自动安装、运行或修改现有用户资料）。随包两共享根 ACL/上传/分享/备份隔离和元数据离线恢复等模拟验收通过；外置真实介质测试明确 SKIP，开发 ad hoc 签名不是 Developer ID 或 Apple 公证。
