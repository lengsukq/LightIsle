# LightIsle 文档索引

> **以代码为准，文档区分功能实现、测试通过与真实设备验收。** 项目目前是 macOS ARM64 个人/家庭 NAS Beta 开发预览。

| 目标 | 文档 |
| --- | --- |
| 了解产品、首次运行 | [README](../README.md) |
| 查询当前已实现功能及限制 | [功能状态](STATUS.md) |
| 了解下一步 P0/P1 | [路线图](ROADMAP.md) |
| 确认个人家庭版产品取舍 | [产品范围](FNOS_PARITY_PRIORITIES.md) |
| 真机、外接盘、网络及发行验收 | [验收清单](DEVICE_ACCEPTANCE.md) |
| 构建、联调、代码测试 | [开发指南](DEVELOPMENT.md) |
| 生产签名、公证、恢复门禁 | [生产发布](PRODUCTION_RELEASE.md) |

## 架构与专项指南

- [技术架构与 API v2](ARCHITECTURE.md) · [安全边界](SECURITY.md) · [性能要求](PERFORMANCE.md)
- [Mac 原生端](MACOS_APP.md) · [Flutter 客户端](FLUTTER_CLIENT.md) · [跨端设计系统](DESIGN_SYSTEM.md)
- [存储与外接盘](STORAGE_AND_DISKS.md) · [远程访问、WebDAV、FRP](REMOTE_ACCESS.md)
- [Docker/Colima](DOCKER_MANAGEMENT.md) · [外部依赖](EXTERNAL_DEPENDENCIES.md)
- [脚本自动化](AUTOMATION_AGENT.md) · [用户可理解的错误提示](USER_FACING_ERRORS.md)
- [内存优化技术记录](MEMORY_OPTIMIZATION_REVIEW.md) · [原生 UI 验收记录](MACOS_UI_ACCEPTANCE.md)

## 架构决策与历史

- [ADR 0001：原生媒体 Worker](adr/0001-native-media-worker.md) · [ADR 0002：多根物理身份](adr/0002-multiple-share-roots.md) · [ADR 0003：私人目录与每盘配额](adr/0003-personal-homes-and-quota.md)
- [历史版本与已归档文档说明](HISTORY.md)：日期性阶段日志和已撤销能力不作为当前功能或开发任务。

**维护规则：** README 只介绍使用入口；`STATUS` 只写代码现状，`ROADMAP` 只写待办，`PRODUCTION_RELEASE` 负责发布与恢复，ADR 保留长期决策。已取消的整盘/逐根备份不得写成现有产品功能。
