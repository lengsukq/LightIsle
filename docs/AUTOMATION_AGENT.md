# LightIsle 自动化任务 · 外部 Agent / 本地脚本约定

此文档既是 LightIsle 的脚本协议，也是可直接复制给**用户自己安装的** Codex、Claude Code、OpenCode 或其他本地 Agent 的提示词。**LightIsle 不内置 Agent、脚本编辑器、依赖管理器，也不负责安装 Python/Node。**

## 用户可以交给外部 Agent 的提示词

> 请在当前 Mac 的 LightIsle **实际应用数据目录**下创建或维护自动化脚本。先检查本机实际 data-dir，不要猜测目录位置。请遵守以下文件协议，保留用户已有的 task.json 字段。完成后检查 JSON、脚本入口、Shebang、文件权限、Cron 和时区；任务默认保持 disabled，交由用户在 LightIsle 的 Web 管理端启用。不要修改 LightIsle 的 Go/Swift/Web 源码。
>
> 目标任务需求：【在这里填写脚本目的、执行时间及通知要求】
>
> 每个任务位于 `automation/scripts/<task-id>/`，目录名与 task.json 的 id 必须一致。入口文件需可执行（如 `chmod 700 run.sh`）。所有运行环境用户自行准备，脚本应以非 0 退出码反映失败。脚本运行时输出的日志不能包含密钥或访问令牌。
>
> 任务如需邮件通知，可使用 LightIsle 内置带外边框的 HTML 邮件模板（`notification.email.mode=\"builtin\"`，默认）；**内容模式**（`mode=\"content\"`）使用 LightIsle 品牌标题、外边框和页脚，只将你编写的 HTML 片段文件放入邮件内容区域；**完整自定义模式**（`mode=\"custom\"`）由你提供完整 HTML 文档，整个替换品牌模板。请将 HTML 写成任务目录中的独立文件，并在 `notification.email.file` 指定其文件名。LightIsle 的 Web 页面不会编辑该 HTML 文件。
>
> HTML 文件允许安全占位符：`{{task.name}}`、`{{task.id}}`、`{{run.state}}`、`{{run.message}}`、`{{run.finishedAt}}`、`{{run.exitCode}}`，动态值会自动进行 HTML 转义。不要使用模板执行代码、外部远程模板、密钥占位符，也不要把私密环境变量插入邮件。邮件始终提供纯文本替代内容。HTML 文件上限 64 KiB；只可引用本任务目录内的普通文件，不能使用 ../、绝对路径或软链接。
>
> 对于邮件通知，请在 `notification.channels` 增加 `email` 并选择发送事件（失败、超时、成功）。SMTP 账号/密码以及企业微信、钉钉、Bark、Webhook 密钥**只能由管理员在 Mac 的通知渠道设置中配置**，不要放进 task.json 或 env.json。任务 JSON 只保存渠道 ID。
>
> 如果需要编辑脚本内容，请直接修改 Mac 本地文件。完成后告诉用户到 Web「自动化」点击刷新；不需要调用注册 API，也不要创建文件监听器或常驻进程。最后列出已创建的文件、Cron、时区、邮件模板模式和如何验证。

## 文件与 JSON 格式

```text
LightIsle data-dir/
└── automation/
    ├── automation.sqlite          # 执行记录与状态，用户无需编辑
    └── scripts/
        └── disk-report/
            ├── task.json          # 由外部 Agent/本地编辑器维护
            ├── env.json           # 可选环境变量，敏感文件应 chmod 600
            ├── run.sh             # 需可执行，包含 Shebang
            └── email.html         # 可选邮件 HTML 模板
```

```json
{
  "schemaVersion": 1,
  "id": "disk-report",
  "name": "每日磁盘报告",
  "description": "检查外置磁盘的使用状态",
  "enabled": false,
  "entry": "run.sh",
  "args": [],
  "envFile": "env.json",
  "schedule": {
    "cron": "0 8 * * *",
    "timezone": "Asia/Shanghai"
  },
  "timeoutSeconds": 600,
  "notification": {
    "events": ["failure", "timeout", "success"],
    "channels": ["email", "bark"],
    "email": {
      "mode": "content",
      "file": "email.html",
      "subject": "LightIsle 每日磁盘报告"
    }
  }
}
```

`notification.email` 仅影响 **Email** 渠道；企业微信、钉钉、Bark 和普通 Webhook 继续使用摘要文本。 `mode` 有三个合法值：

| 模式 | 文件字段 | 最终邮件效果 |
|---|---|---|
| `builtin`（默认） | 不填 | LightIsle 默认品牌模板，带完整外框与简明执行结果 |
| `content` | `email.html` | 保留 LightIsle 外框/页眉/页脚，中间插入任务的 HTML 片段 |
| `custom` | `email.html` | 整封邮件的 HTML 均由任务提供，完全覆盖内置模板 |

**内容模式**示例（任务内的 `email.html`）：

```html
<h2 style="margin:0 0 12px;color:#28456a">磁盘检查结果</h2>
<p>任务：{{task.name}}</p>
<p>执行状态：{{run.message}}（退出码 {{run.exitCode}}）</p>
<p>完成时间：{{run.finishedAt}}</p>
```

**完整自定义模式**示例（同样保存为任务内的 `email.html`）：

```html
<!doctype html>
<html lang="zh-CN"><head><meta charset="UTF-8"></head>
<body style="background:#121a29;color:white;padding:24px">
<h1>专属 NAS 报表</h1><p>{{task.name}}：{{run.message}}</p>
</body></html>
```

环境变量示例：

```json
{
  "REPORT_DIR": "/Volumes/Storage/Reports",
  "API_TOKEN": "local-secret"
}
```

## 调度和安全边界

- Core 启动时扫描；管理员打开 Web 自动化页或主动点击刷新时重新扫描。不做每分钟文件系统扫描。
- 调度使用五段 Cron（分 时 日 月 周）及 IANA 时区，不支持秒级或 `@every`。
- 运行时使用 Mac 本地已有可执行解释器；LightIsle 不自动下载运行环境。
- 任务同一时间只允许执行一次，全局最多两个并发，默认超时 600 秒、最大 3600 秒。错过的 Cron 不补跑。
- 最近每任务保留 30 条执行记录，单次输出截断在 64 KiB。
- 只有管理员有查看、刷新、启停、修改 Cron、删任务和只读日志权限；代码、env.json、HTML 文件只由本地工具编辑。
- Web 修改 Cron/通知事件/渠道时，`notification.email` 字段必须保留，不能覆盖 Agent 的邮件模板设置。
- 脚本作为运行 LightIsle Core 的 Mac 用户执行，**不具备容器沙箱**；请勿导入不可信脚本。
- 通知模板不允许访问 env.json、系统密钥或完整 stdout/stderr；只会替换上述固定状态占位符。
- **当前 Beta 不会将本地脚本、email.html 或 env.json 自动复制进应用配置快照**；请用 macOS Time Machine 或其他本地备份方案保护这些由用户自己维护的文件。未来若要纳入配置备份，也不得默认把 env.json 中的密钥明文放入快照。

## 通知渠道管理

管理员在 Mac 端通知设置中填写 SMTP（465 TLS / 587 STARTTLS）、企业微信群机器人 Webhook、钉钉自定义机器人 Webhook（可选加签）、Bark 和通用 Webhook。凭据只保存在本机 Keychain，经 Mac App 的私有 IPC 下发 Core 内存；Web 只接收已配置渠道 ID。

默认建议仅失败和超时发送通知；成功通知明确按任务开启，避免高频消息。
