# LightIsle 文档中心

> **Beta 开发预览。** 每类信息只维护一处：**产品决策 ≠ 已实现代码 ≠ 待办计划 ≠ 真实硬件验收**。从 [README](../README.md) 开始，按需进入下面的专项文档。

## 首先阅读

| 想知道什么 | 唯一维护入口 |
| --- | --- |
| 项目定位、快速安装、仓库入口 | [README](../README.md) |
| 面向个人/家庭的长期边界与取舍 | [产品原则](PRODUCT.md) |
| **当前代码实现和明确限制** | [功能状态](STATUS.md) |
| **下一批优先级和验收条件** | [路线图](ROADMAP.md) |
| 运行、编译、代码规则、跨端错误提示 | [开发指南](DEVELOPMENT.md) |

## 使用与技术专题

| 分类 | 文档 | 描述 |
| --- | --- | --- |
| 系统 | [架构与 API v2](ARCHITECTURE.md) · [Mac 管理端](MACOS_APP.md) | 进程/模块边界、Mac 生命周期、原生 UI 与调试预览 |
| 客户端 | [Flutter Android/iOS/macOS](FLUTTER_CLIENT.md) · [设计系统](DESIGN_SYSTEM.md) | 连接/相册备份/客户端接口；统一样式 |
| 数据 | [多硬盘与成员空间](STORAGE_AND_DISKS.md) · [安全](SECURITY.md) | 物理根、每盘独立额度、授权、恢复与危险操作 |
| 连接 | [网络与 WebDAV/Cloudflare/FRP](REMOTE_ACCESS.md) | 默认家庭 LAN HTTP、可选 HTTPS/远程穿透 |
| 扩展 | [Docker 与可选外部工具](LOCAL_SERVICES.md) · [本地脚本与通知](AUTOMATION_AGENT.md) | 用户授权的 Mac 本机管理能力 |
| 性能 | [性能预算、优化记录与测试](PERFORMANCE.md) | 内存生命周期、测量数据和真实场景测试 |

## 验收与发行

- [真实设备与外部服务清单](DEVICE_ACCEPTANCE.md)：仍缺的真机、外置盘、网络、播放器与可访问性证据。
- [生产发布与恢复门禁](PRODUCTION_RELEASE.md)：签名、公证、数据库离线恢复、强制拒绝条件。构建成功≠正式发布。
- 架构决策：[ADR 0001：原生媒体 Worker](adr/0001-native-media-worker.md) · [ADR 0002：物理多根](adr/0002-multiple-share-roots.md) · [ADR 0003：私人目录与每盘额度](adr/0003-personal-homes-and-quota.md)。

## 历史文档与追溯

按日期的 Beta/P0/P1/M1 审计、旧影音实施批次、逐根文件备份方案和已取消的 v1 兼容设计**不再作为现行文档维护**。它们的阶段结论已归并到现行指南；需要还原某个历史证据时可在 Git 中查找原始提交：

```bash
git log --all -- docs/
git log --all -- docs/BETA3_IMPLEMENTATION_2026-10-23.md
git show <commit>:docs/BETA3_IMPLEMENTATION_2026-10-23.md
```

**维护约定**：新增功能只在 `STATUS` 写当前实现，`ROADMAP` 记待办，`PRODUCT` 写长期原则；特殊技术决策写 ADR，操作说明归对应专题。不要再创建同一功能的日期版“最新进展”文档或把代码单测等同真实设备验收。
