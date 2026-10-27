# LightIsle 文档导航

> 以本索引作为文档导航入口。项目仍是 macOS arm64 个人 NAS **开发预览**；“代码完成”“自动化测试通过”“实机验收完成”和“可正式发布”是四种不同状态，不能混用。

## 首先阅读

| 要了解的事情 | 唯一入口 | 用途 |
| --- | --- | --- |
| 项目是什么、怎样安装/启动 | [README](../README.md) | 面向使用者的快速介绍 |
| 当前哪些模块真正走通 | [当前实现与闭环状态](STATUS.md) | 现有功能、已知风险、待验收项目 |
| 个人版做什么、不做什么 | [产品范围、用户体验与 fnOS 对标](FNOS_PARITY_PRIORITIES.md) | 唯一产品范围和不做清单 |
| 下一步实现哪些功能 | [路线图](ROADMAP.md) | 以最新计划为准，不将旧日期报告的“未实现”当成当前缺口 |
| 可以公开分发了吗 | [正式发布与拒绝条件](PRODUCTION_RELEASE.md) | **强制门禁**；临时签名绝不当公证 |
| 哪些真机测试尚未做 | [真实设备与外部服务验收清单](ACCEPTANCE_DEBT_2026-10-25.md) | 外接盘、手机、媒体解码、公网和签名证据 |

## 开发和安全规范

- [架构与模块边界](ARCHITECTURE.md) · [开发环境、测试与提交约定](DEVELOPMENT.md) · [权限/文件/高危操作安全](SECURITY.md) · [性能预算和测量方法](PERFORMANCE.md) · [内存占用审查及优化候选清单](MEMORY_OPTIMIZATION_REVIEW.md)
- [macOS App 启停与本机权限](MACOS_APP.md) · [Flutter 用户客户端](FLUTTER_CLIENT.md) · [设计系统](DESIGN_SYSTEM.md)
- [用户可理解的错误提示约定](USER_FACING_ERRORS.md)：统一原因、影响、恢复操作与安全诊断码，不向用户裸露后端错误标识。
- [影音与文件体验技术实施记录（历史）](CORE_LOOP_PLAN_2026-10-25.md)：保留 FFmpeg/HLS、音轨、字幕、刮削及冲突策略等具体实现参数，**不作为当前待办清单**。
- [当前个人版的备份范围与限制](STATUS.md) · [M5 早期备份/离线恢复技术说明（部分文件备份内容已退出当前产品范围）](M5_OPERATIONS.md) · [存储与外置磁盘管理](STORAGE_AND_DISKS.md)
- [WebDAV、Cloudflare Tunnel、FRP](REMOTE_ACCESS.md) · [Docker/Colima 本机管理](DOCKER_MANAGEMENT.md) · [本地脚本自动化与邮件模板](AUTOMATION_AGENT.md)
- [Mac 外部依赖检测与按需安装](EXTERNAL_DEPENDENCIES.md)：Homebrew 白名单安装、日志、FRP 和 Docker 的独立边界。
- 架构决策：[ADR 0001：原生媒体 Worker](adr/0001-native-media-worker.md) · [ADR 0002：多共享根](adr/0002-multiple-share-roots.md) · [ADR 0003：用户私人目录与额度](adr/0003-personal-homes-and-quota.md)

## 历史、淘汰与维护规则

- [历史开发快照与替代索引](HISTORY.md)：合并 2026-10-19 至 10-25 的 M1/Beta、阶段复审、P0/P1 修复流水账。**不是当前待办清单**；需要查看全文时通过 Git 历史恢复。
- 不再维护多份名称带日期的“最新能力”报告；每次修复功能时更新 [STATUS.md](STATUS.md)；范围决定更新 [FNOS_PARITY_PRIORITIES.md](FNOS_PARITY_PRIORITIES.md)，开发顺序更新 [ROADMAP.md](ROADMAP.md)。
- 涉及磁盘格式化、账号权限、真实文件迁移、外网暴露、独立备份目的地的变更，必须同时核对 [SECURITY.md](SECURITY.md) 与 [PRODUCTION_RELEASE.md](PRODUCTION_RELEASE.md)。
- 新的、有长期价值的架构决定写 ADR，不再将临时 Agent 派活/当日构建日志堆成顶层文档。
- 不随手删除有唯一设计、故障排查或安全约束的规范；不把某次本地通过的单测写成已完成 USB/真实手机/公证验收。
