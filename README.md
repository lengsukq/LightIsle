<div align="center">

<img src="assets/brand/lightisle-logo.svg" width="128" alt="LightIsle" />

# LightIsle · 轻屿

**把 Apple Silicon Mac 变成轻量、私有的家庭 NAS。**

**Your Mac. Your NAS. · 不换系统，也能拥有完整的 NAS 体验。**

原生 Mac 管理 · Web / PWA · Android / iOS / macOS

[快速开始](#快速开始) · [功能](#功能一览) · [架构](#技术架构) · [开发](#开发与构建) · [授权](#许可证与商业授权) · [文档](docs/INDEX.md)

</div>

> [!IMPORTANT]
> **Beta 开发预览，尚未正式发布。** 代码和自动化测试不等于真实硬盘、手机和长期运行验收。请勿将唯一重要数据存放于开发版；应用配置备份**不包括**照片、视频和文件原件。

## 为什么是 LightIsle？

**我们希望让现有的 Mac 就是一台好用的家庭 NAS，而不必为了 NAS 放弃 macOS。** LightIsle 在文件、相册、影音与家庭设备管理等用户体验上参考飞牛 fnOS 等成熟 NAS 产品，但不做另一套 NAS 操作系统。

- **不用刷机或重装系统**：直接安装 Mac App，让现有 Mac mini 在保留办公、开发、娱乐等用途的同时提供 NAS 服务。
- **不强制迁移原有文件**：尊重原有磁盘、目录和 Finder 使用方式，通过用户授权的存储根原位提供文件与媒体能力；不承诺所有系统目录都能直接开放访问。
- **个人与家庭优先**：聚焦家庭成员、照片视频、文件共享、多端访问与容易维护的管理体验。
- **安全和稳定优先**：坚持数据原件安全、物理磁盘身份识别、故障可恢复与持续运行质量，不以功能堆叠牺牲可靠性。

LightIsle 的目标是**补充 macOS 的家庭 NAS 能力**，不是替代 RAID、ZFS 等系统级存储能力。产品目标不等于当前已实现功能；实际限制见 [功能状态](docs/STATUS.md)，完整理念及目标见 [产品原则](docs/PRODUCT.md)。

## 功能一览

| 模块 | 能力 |
| --- | --- |
| **文件与分享** | 浏览、搜索、批量操作、分片续传、回收站、分享链接、WebDAV |
| **照片与影音** | 相册与时间线、照片地图、电影/剧集、字幕、播放进度、按需转码 |
| **多硬盘与成员** | 按物理盘管理存储根；个人文件/照片/视频分类放置；成员每盘独立额度 |
| **连接与任务** | 默认局域网访问；可选 Cloudflare Tunnel、FRP、下载、通知与本地脚本 |
| **Mac 系统管理** | 外接盘状态、Docker Desktop/Colima 管理、监控与应用配置备份 |
| **多端使用** | Web/PWA；Flutter Android、iOS、macOS 客户端 |

**当前边界：** 多盘额度按 `rootID + generation` 独立，普通成员每盘默认 **100 GiB**，同盘三类文件共用。**写入渠道尚未全部纳入硬配额**（API 为 `enforcement=pending`），不能当作已完成的强制限额。Android 后台照片、实盘拔插、音视频兼容与远程访问仍需真机验收。详见 [功能状态](docs/STATUS.md)。

## 技术架构

| 组成 | 技术 | 职责 |
| --- | --- | --- |
| Mac 管理端 | SwiftUI / AppKit | 首次初始化、服务生命周期、本机高权限操作 |
| NAS Core | Go / SQLite | 登录授权、存储根、文件/媒体/任务 API |
| Web / PWA | Vue 3 / TypeScript | 浏览器用户端 |
| 移动及桌面客户端 | Flutter | Android / iOS / macOS 访问已有 NAS |

**主机仅支持 Apple Silicon Mac + macOS 14+**。关闭主窗口可继续在菜单栏运行，明确退出 App 会停止 Core；Flutter 客户端**不是**额外的 NAS 服务端。

## 快速开始

源码构建还需要 **Go 1.26+、Xcode/Swift 6、Node.js/npm**。FFmpeg、aria2、Docker、cloudflared 和 FRP 都是可选依赖。

```bash
git clone https://github.com/lengsukq/LightIsle.git
cd LightIsle
bash scripts/build-macos.sh
open dist/LightIsle.app
```

1. 在 **Mac 原生 App** 首次创建管理员，选择安全、可写的 NAS 专用存储目录。
2. 本机浏览器打开 `http://127.0.0.1:16666/`；如有修改，请使用 Mac App 显示的实际地址。
3. 初始化后默认允许可信家庭局域网 HTTP 访问；需要时在 Mac App 中启用 HTTPS 或配置可选的远程连接。

> [!CAUTION]
> **不要将明文 HTTP 管理端口直接映射到公网。** 使用 HTTPS/安全隧道，并核对客户端证书或连接配置。LightIsle 的每周五份自动备份仅覆盖应用配置和 SQLite；原始数据请单独使用 Time Machine 或其他独立备份介质。

## 开发与构建

```bash
go test -race ./...
go vet ./...
bash scripts/verify-macos.sh

cd apps/flutter
flutter pub get
flutter analyze
flutter test
```

`build-macos.sh` 生成本地 Ad-hoc 签名 App/DMG，不等同于 Apple Developer ID 签名或公证。手动 GitHub Actions 构建与 Android 签名要求见 [开发指南](docs/DEVELOPMENT.md)、[正式发布门禁](docs/PRODUCTION_RELEASE.md)。

```text
apps/macos/    SwiftUI 管理端及原生媒体 Worker
apps/web/      Vue 3 Web/PWA
apps/flutter/  Flutter 客户端
core/          Go Core 与 SQLite
scripts/       构建、测试、发布辅助脚本
docs/          使用、安全、架构与验收规范
```

## 文档与进度

[文档总览](docs/INDEX.md) · [产品理念、目标与边界](docs/PRODUCT.md) · [当前能力](docs/STATUS.md) · [路线图](docs/ROADMAP.md) · [存储与磁盘](docs/STORAGE_AND_DISKS.md) · [Flutter](docs/FLUTTER_CLIENT.md) · [架构](docs/ARCHITECTURE.md) · [安全](docs/SECURITY.md)

## 许可证与商业授权

LightIsle 是**源码公开（source-available）**的个人 NAS 项目，当前项目自有代码按 **[PolyForm Noncommercial License 1.0.0](LICENSE)** 提供（SPDX: `PolyForm-Noncommercial-1.0.0`）。

- **个人与家庭非商业使用免费**：允许在协议范围内查看、运行、修改和分享代码，分发时须保留许可链接及 `Required Notice:` 版权声明。协议也明确允许部分非商业组织用途。
- **商业使用须另行取得书面授权**：包括经营性企业内部部署、商业托管、商品化集成与二次开发销售；具体以 [官方许可条款](LICENSE) 与双方实际签署的商业协议为准，详见 [商业授权说明](COMMERCIAL.md)。
- **此前 MIT 版本不受追溯影响**：本次变更从首次公开包含新 `LICENSE` 的提交或发行版起对相应发布内容生效；已经合法按 MIT 获得的历史版本及代码仍保留原有 MIT 权利。
- **第三方依赖独立授权**：外部 SDK、库、工具和资源不因为本项目换协议而改变自身许可证，参见 [第三方声明](THIRD_PARTY_NOTICES.md)。

欢迎阅读 [贡献指南](CONTRIBUTING.md)；外部版权贡献在合并前需要单独确认双授权所需的权利。由于限制商业用途，本项目不是 OSI 定义下的开源软件。
