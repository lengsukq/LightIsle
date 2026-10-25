# LightIsle 开发历程与旧文档追溯（2026-10-19—25）

> 这是**归档索引**，不是现状、产品范围、待办或真实设备验收结论。旧的按天快照曾互相引用、多次声称自己“最新”，且未提交工作树情况已经改变。统一以 [STATUS.md](STATUS.md) 为当前代码闭环入口，[FNOS_PARITY_PRIORITIES.md](FNOS_PARITY_PRIORITIES.md) 为个人版范围，[PRODUCTION_RELEASE.md](PRODUCTION_RELEASE.md) 为发布门禁。所有旧文件全文仍可从本仓库 **Git 历史**检索。

## 2026-10-19—22：M1、P0、个人版方向

| 原文档文件名 | 当时的主要信息 | 迁移后的维护位置 |
| --- | --- | --- |
| `M1_STATUS.md` | SwiftUI + Go + Web 最初可构建阶段；当时缺登录与业务能力，这些“未实现”**已作废** | [MACOS_APP](MACOS_APP.md)、[STATUS](STATUS.md) |
| `P0_IMPLEMENTATION_STATUS.md` | 单根身份绑定、账号和文件安全、备份/恢复与测试门槛，2026-10-20 代码快照 | [SECURITY](SECURITY.md)、[STATUS](STATUS.md)、[PRODUCTION_RELEASE](PRODUCTION_RELEASE.md) |
| `PERSONAL_NAS_PLAN.md` | 2026-10-22 多轮产品分阶段建议，包括后来取消的企业级联合灾备/事务化跨卷移动 | [fnOS 个人版范围](FNOS_PARITY_PRIORITIES.md)、[ROADMAP](ROADMAP.md) |

**后续确定的边界**：后端只有 macOS arm64；Mac App 完全退出时 Go 服务结束，关闭窗口继续留在菜单栏；Flutter 客户端已纳入 Android、macOS、iOS 开发，不能沿用 M1 的“没有 Flutter”判断。不另造 RAID/存储池、不建设企业级文件与 SQLite 联合事务引擎。

## 2026-10-23：Beta 迭代与缺口审查

| 原文档文件名 | 当时的有效成果或教训 | 迁移位置 |
| --- | --- | --- |
| `BETA_SCOPE_2026-10-23.md` | Beta 日常使用范围、豆瓣搜索实验、开发签名和实盘门禁 | [README](../README.md)、[STATUS](STATUS.md) |
| `BETA2_STABILITY_2026-10-23.md` | 离线共享目录 30 秒状态轮询、20 秒 Core 启动超时、明确重试而非无限重启 | [MACOS_APP](MACOS_APP.md)、[STORAGE_AND_DISKS](STORAGE_AND_DISKS.md) |
| `BETA3_IMPLEMENTATION_2026-10-23.md` | 数据库升级前预检、媒体增量扫描、Android 前台照片备份与 SHA-256 原片核验 | [STATUS](STATUS.md)、[FLUTTER_CLIENT](FLUTTER_CLIENT.md) |
| `BETA3_REAUDIT_2026-10-23.md` | Android 后台 WorkManager、账号隔离/权限中断复查、Flutter/模拟器回归 | [STATUS](STATUS.md)、[FLUTTER_CLIENT](FLUTTER_CLIENT.md) |
| `FUNCTION_GAP_AUDIT_2026-10-23.md` | 早期“19 个缺口”，部分已修复，不再是当前剩余功能数 | [STATUS](STATUS.md) |
| `REAUDIT_AND_EXECUTION_2026-10-23.md` | 19 项复审后拆分的修复任务；Agent 分工仅属于当日工作流 | [STATUS](STATUS.md)、[ROADMAP](ROADMAP.md) |
| `P0_P1_DELIVERY_2026-10-23.md` | 跨卷单文件安全复制/移入回收站、照片年月时间线、NFO/TMDB、私人相册、审计及告警 | [STATUS](STATUS.md)、[M5_OPERATIONS](M5_OPERATIONS.md) |
| `P0_P1_PERSONAL_IMPLEMENTATION_2026-10-23.md` | 多目录隔离、根/代际分享、持久告警、系统备份与安全恢复的阶段记录 | [STATUS](STATUS.md)、[STORAGE_AND_DISKS](STORAGE_AND_DISKS.md) |
| `MULTI_ROOT_RECOVERY_PROGRESS_2026-10-23.md` | rootID / generation、私有 IPC、独立根快照、恢复隔离预览 | [ADR 0002](adr/0002-multiple-share-roots.md)、[STATUS](STATUS.md) |
| `STORAGE_CONFIGURATION_BETA_PLAN_2026-10-23.md` | Mac 磁盘入口、当前 NAS 共享位置、安全文件选择器/切换、失败结果核对 | [STORAGE_AND_DISKS](STORAGE_AND_DISKS.md) |
| `DRIVE_MANAGEMENT_BETA_PLAN_2026-10-23.md` | Go diskmgmt + Mac/Web 共用、管理员授权、盘身份复检、弹出/挂载/重命名限制 | [STORAGE_AND_DISKS](STORAGE_AND_DISKS.md) |
| `OFFLINE_DRIVE_AND_FORMATTING_PLAN_2026-10-23.md` | NTFS 只读、离线盘记录保留/清理、真实文件不删除、仅打开 macOS 磁盘工具 | [STORAGE_AND_DISKS](STORAGE_AND_DISKS.md) |
| `UPLOAD_UX_BETA_FIX_2026-10-23.md` | 上传报错不能被目录刷新覆盖；上传分阶段进度、取消和多文件反馈 | [STATUS](STATUS.md) |

这些日期不代表一次正式发布。特别是被取消的目录事务性跨盘移动、强制原生加密/增量备份等不能重新被历史清单提升成 P0。

## 2026-10-24：存储/网络、移动端和可靠性

| 原文档文件名 | 当时的成果/边界 | 迁移位置 |
| --- | --- | --- |
| `FEATURE_REAUDIT_2026-10-24.md` | 磁盘防护、上传断点/客户端入口的已复审及未实测清单 | [STATUS](STATUS.md) |
| `P0_P1_CODE_HARDENING_2026-10-24.md` | 上传写入前通过 staging FD 的 Fstatfs 检查真实卷空间；媒体播放进度收尾 | [SECURITY](SECURITY.md)、[STATUS](STATUS.md) |
| `TUNNEL_WEBDAV_DISK_PLAN_2026-10-24.md` | SMART 只读/受限授权、容量阈值、WebDAV 独立凭证、Cloudflare 子进程/API Token/Ingress | [STORAGE_AND_DISKS](STORAGE_AND_DISKS.md)、[REMOTE_ACCESS](REMOTE_ACCESS.md) |

**长期安全教训**：SMART 设备/USB 桥接不支持时只能报未知；Cloudflare 快速随机 URL 不可当固定生产域名；WebDAV 不复用浏览器 Cookie 作 Basic 密码；同源访问仍必须遵守成员的路径授权。

## 2026-10-25：用户画像、P0/P1 和闭环复核

| 原文档文件名 | 当时的重点 | 迁移位置 |
| --- | --- | --- |
| `PERSONAS_AND_CODE_AUDIT_2026-10-25.md` | 个人用户和极客用户的体验优先级；区别“已有代码/开发版/设备验收” | [FNOS_PARITY_PRIORITIES](FNOS_PARITY_PRIORITIES.md)、[STATUS](STATUS.md) |
| `P0_P1_IMPLEMENTATION_2026-10-25.md` | 上传/文件夹选择/HEIC-PDF 预览/分享增强；iOS 前台原片、48h 系统指标、网络诊断 | [STATUS](STATUS.md) |
| `FUNCTION_CLOSURE_AUDIT_2026-10-25.md` | 入口→权限→落盘→恢复矩阵、错盘继承旧 rootID 修复、按需 SMART 记录、手机视频选项、额外根自动扫描 | [STATUS](STATUS.md) |

**仍需持续关注**：多根正式放开前的 v1 授权/私人相册/观看历史迁移、独立备份目的地与自动任务、额外根实盘恢复。SMART 历史来自按需查询，不能说有持续通知；Android 后台只备份照片。

## 如何找回旧文件全文

`PRODUCT.md` 的产品范围、跨功能数据归属与 UI 验收原则已整合到 [FNOS_PARITY_PRIORITIES](FNOS_PARITY_PRIORITIES.md)；不再维护第二份含 P0/P1 的产品清单。

这些文件在 Git 中已提交过，删去工作区副本不会删掉提交历史。例如：

```bash
git log --all -- docs/BETA3_IMPLEMENTATION_2026-10-23.md
git show <存在该文件的提交哈希>:docs/BETA3_IMPLEMENTATION_2026-10-23.md
```

把尖括号占位符换成 `git log` 找出的实际提交哈希；不要直接恢复旧内容到现行规范以覆盖较新安全要求。历史全文不作为当前功能状态的依据。
