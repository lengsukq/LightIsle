# M1 历史状态快照（已过期）

> **这不是当前状态。** 本文记录 2026-10-19 M1 首个可构建开发版的事实，仅用于追溯。当前能力、自动化覆盖与人工验收缺口以 [P0 实施与验证状态](P0_IMPLEMENTATION_STATUS.md) 和 [路线图](ROADMAP.md) 为准。
>
> 当时的“未实现”表述（无账号/SQLite/TLS、随机端口、文件/图库/影视只是占位入口）**已经被后续代码取代**，不应再据此判断现状。M1 仍未完成，因为 GUI 生命周期、Android 浏览器实机、真机指标和视觉验收没有人工记录。

## 当时已经存在的部分

| 子系统 | 文件 | 当时状态 |
| --- | --- | --- |
| macOS SwiftUI App | `Package.swift`、`apps/macos/Sources/LightIsle/` | 已编译，导航/设置页面、Go Core 进程监督 |
| 内置 Go Core | `core/cmd/lightisled` | 已编译/测试，本机回环 API |
| macOS 系统采样 | `core/internal/system/metrics_darwin_arm64.go` | 已测试，通过 Mach 接口读取 CPU、内存；系统卷剩余空间 |
| HTTP 后端 | `core/internal/server/` | 已测试，`GET /api/v1/health`、`GET /api/v1/system`、静态 Web |
| Vue3 总览 | `apps/web/` | 已构建，浅深主题、响应式概览 |
| 单一应用打包 | `scripts/build-macos.sh` | 已执行成功，生成 `dist/LightIsle.app`，ad-hoc 本地签名 |
| 生命周期冒烟 | `tests/test_app_lifecycle.py` | 已通过，服务启动、HTTP、父进程管道 EOF 后退出和端口释放 |
| Design Tokens | `design-tokens/tokens.json` | 首版草案，已用于 Vue 主题；SwiftUI 用原生系统色材质 |

当时记录的环境：Go 1.26.1 darwin/arm64、Xcode 27、Node.js v26.3.0。这些是历史记录，未在当前文档基线上重跑。

## 后续已经实现、但当时尚不存在的部分

- SQLite `accounts.sqlite` + Argon2id、首任管理员由 Mac 私有 IPC 初始化、管理员重置、Web 登录与 30 天会话撤销。
- 默认固定本机端口 `127.0.0.1:16666`（可在 Mac 设置中修改，重启 App 生效），不再是随机端口。
- 由 Mac App 显式开启的 LAN HTTPS（自签名证书 + 指纹），默认仍只监听回环地址。
- 文件管理（分页、有限搜索、上传续传、预览、回收站、同卷移动、目录复制）、图库、相册/收藏、影视 Range 播放与续播。
- 目录级成员授权、任务状态持久化、备份 v2 与离线元数据激活、Mac-only 跨卷安全复制、可配置缩略图缓存。
- FSEvents 变更触发 + Go 周期对账。

## 仍然有效的 M1 缺口

1. **GUI 实机运行回归**：真实打开 `dist/LightIsle.app`，核验原生窗口、最小化/关窗/⌘Q、强制退出均无 Go 残留。目前只有 Go 父管道 EOF 和端口释放的自动化验证。
2. **Android 浏览器实机**：Mac 开启 LAN HTTPS 后，用真实 Android 设备核验证书指纹、登录、文件和媒体操作。设备配对/设备撤销模型仍未设计。
3. **原生系统控制台验收**：真实窗口布局、主题、减少透明度、错误页和 Core 崩溃恢复的人工检查。
4. **指标真实性**：外接卷、SMART 桥接设备、网络速率和真实进程状态的实机核对。
5. **性能基线**：SwiftUI + Go 的真实空闲 RSS/CPU，以及窗口关闭后的资源释放。
6. **发行构建**：Developer ID 签名、公证、Gatekeeper 和干净机器安装属于 M7，尚未执行。

## 里程碑定义（未变）

M1 只有在 **Mac App 实机完整生命周期、首次管理员初始化、Android 浏览器经 Mac 显式开启的 LAN HTTPS 连接、系统指标和基本视觉测试** 均通过后才可标记完成。设备配对模型尚未设计，不能用它替代账号密码与证书指纹核验。目前只是开发预览，自动化测试通过不等于上述验收完成。

参阅：[路线图](ROADMAP.md)、[P0 实施与验证状态](P0_IMPLEMENTATION_STATUS.md)、[Mac App 生命周期](MACOS_APP.md)、[开发指南](DEVELOPMENT.md)。
