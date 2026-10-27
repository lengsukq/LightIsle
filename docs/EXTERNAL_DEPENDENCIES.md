# Mac 外部依赖管理

LightIsle 是个人 NAS 管理工具，**不随 App 捆绑第三方可执行程序**。Mac 原生管理端提供独立的「外部依赖」页面，用于统一查看本机可选工具与执行明确授权的安装操作；Web 和 Flutter 用户端不具备本机安装权限，也不公开任何安装用 HTTP API。

## 页面与安装方式

打开 Mac App 左侧「系统管理 → 外部依赖」，按需检查：

| 可选组件 | Homebrew 包 | 检测命令 | 功能 |
| --- | --- | --- | --- |
| FFmpeg | `ffmpeg` | `ffmpeg` | 媒体探测、字幕与按需转码 |
| aria2 | `aria2` | `aria2c` | 下载中心的 HTTP/FTP/磁力任务 |
| smartmontools | `smartmontools` | `smartctl` | 外置硬盘 SMART 详情（可能还需要授权） |
| cloudflared | `cloudflared` | `cloudflared` | Cloudflare Tunnel 客户端 |

页面打开时检测可执行文件是否存在，**不自动安装、更新、卸载，也不自行探测/执行任意命令**。用户点击某个未安装项的「安装」、审阅绝对路径和命令并确认后，才执行固定白名单 `/opt/homebrew/bin/brew install <package>`（或 `/usr/local/bin/brew`）。不使用 Shell 拼接、`sudo`、远程 API 和后台常驻安装任务。

- 未在标准路径检测到 Homebrew 时，页面显示**完整手动安装向导**，提供两种官方方案：
  1. **图形化安装**：打开 [Homebrew 官方 GitHub 最新发布页](https://github.com/Homebrew/brew/releases/latest)，下载适用于 Apple Silicon 的 .pkg，按照安装向导完成安装。
  2. **终端安装**：一键复制 [Homebrew 官网](https://brew.sh/zh-cn/)的原始安装命令，打开终端后由用户亲自粘贴并确认。LightIsle 只复制，不执行远程脚本，不请求 macOS 管理员密码。
- 完成后点击「重新检测 Homebrew」，即可启用依赖安装按钮。如果仅**终端**无法识别 brew，可以复制 eval "$(/opt/homebrew/bin/brew shellenv)" 恢复当前终端环境，之后按照 Homebrew 安装器的提示写入 ~/.zprofile；Mac 原生 App 仍通过可信的绝对路径查找 brew，不需要修改 Shell PATH。
- 官方 Homebrew 当前主要支持 macOS 15 及更新版本；项目最低 macOS 14 对应的机器会显示兼容性提醒，不能承诺在不受支持的操作系统上安装成功。
- 安装任务在 Mac 的后台执行，不阻塞界面；同一时间只允许运行一次。可查看最近一次有限长度的输出/错误日志，临时日志在安装结束后清理。不长期记录外部下载内容。
- 安装后再次检查实际命令文件；Homebrew 返回成功但找不到可执行文件时必须明确提示，不能报告“已安装”。如有代理、磁盘权限或 Homebrew 命令行工具故障，请按日志在 Mac 上修复。
- 这里只报告「命令行工具已检测到」，不等于服务已启动、配置完成或设备权限足够。Go Core 可能在启动时检查工具路径，安装后需要刷新对应功能页面，必要时重新启动 LightIsle。
- **Docker Desktop/Colima 不会由 LightIsle 安装**；页面仅引导到已有 Docker 管理入口。**FRP 由网络设置中的独立官方版本列表、SHA-256 校验下载流程管理**，不能重复用 Homebrew 覆盖运行中的 frpc。

## 验证与安全边界

- `swift build -c release` 用来检查 Mac 界面与安装管理代码可编译。
- 固定安装命令白名单冒烟测试（**不会安装任何软件**）：

  ```bash
  swiftc -parse-as-library apps/macos/Sources/LightIsle/ExternalDependencySupport.swift \
    tests/external_dependency_catalog_smoke.swift -o .build/lightisle-dependency-smoke
  .build/lightisle-dependency-smoke
  ```
- 本地安装具有磁盘写入/下载风险，必须由用户在 Mac 原生界面确认；若用户缺少 Homebrew、网络无法访问源或环境要求管理员密码，需要按具体提示自行处理。
- 当前没有自动安装真实软件包的 CI 测试。自动化编译通过**不等于**已在不同 Mac、代理或 Homebrew 版本上完整验收安装。功能仍属于 Beta。
