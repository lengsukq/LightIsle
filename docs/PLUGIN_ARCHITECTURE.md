# LightIsle（轻屿）原生多语言插件与按需应用系统（Plugin & On-Demand Architecture）

> **架构设计蓝图、家庭级安全边界与内置开发者 MCP 规范（v2.1 实用精简版）**
> *面向 LightIsle 宿主研发、本地扩展开发者及外部 AI Coding Agent 的技术规范。本文档定义多语言按需插件、家庭轻应用中心与内置开发者 MCP Server 的目标架构及适度安全边界；当前已合入代码的能力见 [功能状态](STATUS.md)，已实现的纯脚本定时调度见 [本地脚本与通知](AUTOMATION_AGENT.md)，排期优先级见 [路线图](ROADMAP.md)。*

---

## 目录
1. [背景与核心动机](#一背景与核心动机)
2. [核心理念：三态生命周期、按成员授权与适度边界](#二核心理念三态生命周期按成员授权与适度边界)
3. [插件与应用标准规范（Plugin Specification v2）](#三插件与应用标准规范plugin-specification-v2)
4. [多语言兼容与轻量化工程指南（Static HTML / Python / Java / Node / Go / Rust）](#四多语言兼容与轻量化工程指南static-html--python--java--node--go--rust)
5. [LightIsle 宿主端架构设计（Go Core）](#五lightisle-宿主端架构设计go-core)
6. [macOS 原生端、Web 与 Flutter 三端「应用中心」与 MCP 调试台](#六macos-原生端web-与-flutter-三端应用中心与-mcp-调试台)
7. [全功能管理与开发者 MCP Server（Unified `lightisle-mcp` v2.0）](#七全功能管理与开发者-mcp-serverunified-lightisle-mcp-v20)
8. [第一示范参考项目：`cpe-monitor` 深度解构与改造方案](#八第一示范参考项目cpe-monitor-深度解构与改造方案)
9. [分阶段落地里程碑（Implementation Roadmap）](#九分阶段落地里程碑implementation-roadmap)
10. [个人与家庭软件的安全与复杂度边界（六大问题取舍矩阵）](#十个人与家庭软件的安全与复杂度边界六大问题取舍矩阵)
11. [内置引导提示词与 AI Agent 自主开发协议（Bootstrap & System Prompt）](#十一内置引导提示词与-ai-agent-自主开发协议bootstrap--system-prompt)

---

## 一、背景与核心动机

### 1.1 现状与痛点
- **宿主定位**：LightIsle 的核心愿景是“**让手头的 Apple Silicon Mac（尤其是常开的 Mac mini）成为轻量、私有的家庭 NAS，而不破坏 macOS 原生体验**”（见 [产品原则与目标](PRODUCT.md)）。
- **零散应用的“端口与穿透地狱”**：家庭服务器常部署多个实用小工具（如 5G CPE 监控、家庭记账本、局域网测速、快递/账单看板等）。传统做法下每个应用各自占用端口、各自配穿透、各自写登录，难以统一管理与分配给家人使用。
- **拒绝 Docker VM 内存税与低频 Web 常驻税**：
  - 在 macOS 上跑 Docker，仅 Linux 虚拟机基础底噪就要吞噬 **1GB~2.5GB 内存**（见 [Docker 与可选外部工具](LOCAL_SERVICES.md)）；
  - 即便跑原生进程，四五个几天才看一次的 Node.js / Python / JVM 监控面板 24 小时常驻也会白白吃掉几百 MB 内存；而很多报表看板其实只需静态 HTML，根本不需要常驻后端进程。

### 1.2 核心破局
1. **三态前端按需运行**：支持 `static`（纯静态 HTML，永远 `0 MB`）、`on-demand`（按需唤醒动态后端，闲置自动 `SIGTERM` 归零 `0 MB`）与 `persistent`（24/7 常驻看门狗）。
2. **双端内嵌「应用中心」与成员级 ACL**：管理员可按应用分配访问权限（仅管理员 / 指定家庭成员 / 全员可用），家人打开 Web 或 Flutter 应用中心即可直接使用被授权的应用。
3. **内置 `lightisled mcp` 开发者服务**：外部 AI Agent 连接本机 `stdio` MCP 自动读取规范、生成脚手架（默认 `admin_only` 仅管理员可见）、静态校验并触发热重载。
4. **守住家庭软件的安全底线，不堆企业级伪沙箱**：用极简、无副作用的工程手段解决同源 API 越权、回环端口身份头防伪、`automation.Manager` 任务 ID 兼容与代码/数据目录分离，不引入破坏正常脚本运行的虚假沙箱或复杂审批流。

---

## 二、核心理念：三态生命周期、按成员授权与适度边界

遵循 [AGENTS.md](../AGENTS.md) **“优先完善正常使用体验，错误提示清楚，恢复操作简单，不为了个人项目堆企业级功能”** 的最高原则：

```
                   ┌──────────────────────────────────────────────┐
                   │     LightIsle 应用网关 (/apps/<app-id>/*)    │
                   │  • 成员级 ACL + 单次 Launch Ticket 握手       │
                   │  • 剥离宿主 Cookie + 注入 LIGHTISLE_PROXY_SECRET│
                   └──────────────────────┬───────────────────────┘
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                 ▼
┌───────────────────────────────┐ ┌───────────────────────────────┐ ┌───────────────────────────────┐
│ 模式 A：纯静态 (Static HTML)  │ │ 模式 B：按需唤醒 (On-Demand)  │ │ 模式 C：持久常驻 (Persistent) │
│ [报表 / 纯前端 / Cron 生成页] │ │ [默认 / 低频交互后端推荐]     │ │ [长连接 / 实时业务专用]       │
├───────────────────────────────┤ ├───────────────────────────────┤ ├───────────────────────────────┤
│ • 无需启动任何子进程 (0 MB)   │ │ • 无访问时：进程完全退出(0MB) │ │ • 24/7 持续运行，随宿主自启   │
│ • Go Core 直接托管静态目录    │ │ • 访问到达：Singleflight 拉起 │ │ • 崩溃退避重启 + 熔断保护     │
│ • 0ms 瞬时打开，配合 Cron 更新│ │ • 闲置超时：SIGTERM 释放内存  │ │ • 零冷启动延迟，适合高频服务  │
└───────────────────────────────┘ └───────────────────────────────┘ └───────────────────────────────┘
                                                  │
                                                  ▼
                                  [后台周期 Cron 采集 / 静态生成]
                                  直接桥接 core/internal/automation (任务 ID: app-<id>)
                                  + 独立数据目录 ($LIGHTISLE_PLUGIN_DATA_DIR)
```

---

## 三、插件与应用标准规范（Plugin Specification v2）

### 3.1 代码目录与数据目录分离（轻量约定，零 UI 负担）
为了避免 AI Agent 更新插件代码时误删业务数据库（如 SQLite），LightIsle 通过**一个标准环境变量约定**实现代码与数据自然分离：

1. **插件定义与代码目录（`LIGHTISLE_PLUGIN_DIR`）**：
   `~/Library/Application Support/LightIsle/plugins/<plugin-id>/`
   ```text
   plugins/
   └── cpe-monitor/
       ├── plugin.json         # [必选] 应用元数据、访问权限、Web 模式与 Cron 声明
       ├── icon.svg            # [可选] 应用矢量图标（48x48）
       ├── ui/                 # [可选] mode="static" 时的纯静态前端目录 (含 index.html)
       ├── run-cron.sh         # [可选] 后台周期任务入口脚本 (chmod 700，含 Shebang)
       ├── run-web.sh          # [可选] 动态 Web 启动脚本 (chmod 700，含 Shebang，必须使用 exec)
       ├── email.html          # [可选] 供 Cron 通知使用的邮件 HTML 模板 (64 KiB 上限)
       └── env.json            # [可选] 应用私有环境变量 (chmod 600，绝不经 API 回显)
   ```
2. **插件持久化数据目录（`LIGHTISLE_PLUGIN_DATA_DIR`）**：
   - Go Core 启动 `run-web.sh` 与 `run-cron.sh` 前，自动创建并注入环境变量 `LIGHTISLE_PLUGIN_DATA_DIR=~/Library/Application Support/LightIsle/plugin-data/<plugin-id>/`（若插件需将大数据存放在外置硬盘，也可在自己的 `env.json` 中自定义覆盖路径，无需宿主维护复杂的跨盘绑定状态机）；
   - **备份边界**：LightIsle 的每周应用配置快照（Backup）仅备份系统核心 SQLite 与配置，天然不包含 `plugins/` 代码依赖与 `plugin-data/` 业务数据。

### 3.2 `plugin.json` 清单定义
- **ID 命名与 `automation.Manager` 兼容**：插件 `id` 必须匹配 `^[a-z][a-z0-9-]{0,40}$`。当桥接注册到 `automation.Manager` 时，系统自动使用任务 ID **`app-<id>`**（完全符合 `automation` 现有的 `^[a-z][a-z0-9-]{0,47}$` 规则与文件锁命名，无需带冒号）。

```json
{
  "schemaVersion": 2,
  "id": "cpe-monitor",
  "name": "CPE 流量与设备监控",
  "version": "1.0.0",
  "author": "Leo",
  "description": "监控 H153 5G CPE 流量套餐、信号质量与短信同步",
  "category": "network",
  "icon": "icon.svg",

  "access": {
    "policy": "admin_only",
    "allowedUserIDs": []
  },

  "cron": {
    "enabled": true,
    "entry": "run-cron.sh",
    "schedule": {
      "cron": "*/15 * * * *",
      "timezone": "Asia/Shanghai"
    },
    "timeoutSeconds": 60,
    "notification": {
      "events": ["failure", "timeout"],
      "channels": ["wecom", "email", "bark"],
      "email": {
        "mode": "content",
        "file": "email.html",
        "subject": "CPE 监控采集异常告警"
      }
    }
  },

  "web": {
    "enabled": true,
    "mode": "on-demand",
    "runtime": "node",
    "entry": "run-web.sh",
    "staticDir": "ui",
    "port": 0,
    "basePath": "/apps/cpe-monitor",
    "idleTimeoutSeconds": 900,
    "readyTimeoutSeconds": 10,
    "healthCheckPath": "/apps/cpe-monitor",
    "autoRestart": true,
    "restartLimit": 5
  }
}
```

---

## 四、多语言兼容与轻量化工程指南（Static HTML / Python / Java / Node / Go / Rust）

### 4.1 反向代理子路径（`BASE_PATH`）与轻量代理防伪密钥（`LIGHTISLE_PROXY_SECRET`）
Go Core 启动 `run-web.sh` 时会自动注入干净的白名单环境变量：
- `PORT=<动态分配的空闲回环端口>`
- `HOST=127.0.0.1` / `HOSTNAME=127.0.0.1`
- `BASE_PATH=/apps/<plugin-id>`
- `LIGHTISLE_PLUGIN_DIR=<插件代码目录>`
- `LIGHTISLE_PLUGIN_DATA_DIR=<插件持久化数据目录>`
- **`LIGHTISLE_PROXY_SECRET=<每次启动随机生成的 32 字节十六进制密钥>`**

> **轻量代理防伪约定**：
> Go Core 反代转发请求至 `127.0.0.1:$PORT` 时，会注入请求头 `X-LightIsle-Proxy-Secret` 以及当前登录用户的 `X-LightIsle-User-ID`、`X-LightIsle-Username`、`X-LightIsle-Role`。插件只需校验 `req.headers['x-lightisle-proxy-secret'] === process.env.LIGHTISLE_PROXY_SECRET`，即可安全实现免二次登录，防止本机其他进程直连 `127.0.0.1:$PORT` 伪造身份头。

### 4.2 纯静态 HTML 轻应用指南与内置官方精选模板（`mode: "static"`，0 MB 进程开销）
- `run-cron.sh` 定时运行采集脚本，将最新结果写入 `ui/data.json`；`ui/index.html` 通过相对路径 `fetch('./data.json')` 或 `localStorage` 渲染看板，常驻与浏览期间子进程内存均为 **0 MB**。
- `core/internal/apps/builtin_templates.go` 随包内置 4 款零外部依赖的官方精选静态家庭轻应用模板（`network-pulse` 家庭网络脉搏哨兵、`family-subscriptions` 家庭订阅与续费管家、`warranty-vault` 家电数码保修卡库、`family-board` 家庭共享备忘白板），支持管理员通过 `GET /api/v2/apps/templates` 与 `POST /api/v2/apps/templates/{id}/install` 一键安装并按成员授权开放。

### 4.3 Python / Java / Node.js / Go / Rust 轻量化模版
- **Python (FastAPI)**：优先使用 `.venv/bin/python`，传入 `--host 127.0.0.1 --port "$PORT" --root-path "${BASE_PATH:-}" --workers 1`。
- **Java (GraalVM / JVM)**：JVM 强制添加 `-XX:+UseSerialGC -Xms16m -Xmx64m -XX:TieredStopAtLevel=1 -Xss256k`。
- **Node.js (Next.js standalone)**：添加 `--max-old-space-size=64 --optimize-for-size`。
- **Go / Rust**：原生 `arm64` 单二进制，内存 `6MB ~ 12MB`，冷启动 `< 5ms`。

---

## 五、LightIsle 宿主端架构设计（Go Core）

### 5.1 模块职责划分
```text
core/internal/automation/
└── plugins.go        # 扩展 automation.Manager 原生支持 plugins/<id> 任务 (ID: app-<id>)，共用锁/历史/邮件模板

core/internal/apps/
├── types.go          # PluginManifest v2 定义、ID 校验、PublicApp 视图（含 lastError / diagnostic）与 AppsSystemConfig
├── diagnostics.go    # 启动/校验/崩溃根因诊断（AppDiagnostic：原因、stderr 关键输出、排查步骤、修复办法、数据安全说明）与浏览器网关 HTML 诊断页
├── manager.go        # 按需扫描、成员 ACL 校验、非管理员诊断/路径隔离、原子更新 plugin.json、进程组清理
├── instance.go       # 动态子进程状态机（Singleflight 唤醒锁、动态端口、启动期 stderr 捕获与阶段区分、闲置 SIGTERM、看门狗）
├── proxy.go          # Launch Ticket 握手、反代 Header 剥离与身份头注入、网关诊断页回退、/api/v2/* Referer 越权守卫
├── mcp.go            # 内置 Stdio 与 JSON-RPC 2.0 MCP Server（暴露 3 个规范 Resource 与 9 个辅助开发/远程调试 Tool）
├── mcp_remote.go     # 局域网 MCP 配置快照、Token 轮换、ExecuteDebugMCP 交互式调试与 ProbeApp 网关 HTTP 探针
├── mcp_debug.go      # 远程文件读写（os.Root 隔离）、进程启停、日志拉取、探针调试工具与最近 50 条 MCP 调用追踪日志
└── mcp_templates.go  # 内置插件 v2 规范、UI 主题规范与自动化规范模板常量
```

### 5.2 兼顾正常前端体验的浏览器同源边界与可信本地插件模型
如果完全禁用 Iframe 的 `allow-same-origin`（置入 `null` Origin），会导致家庭应用正常的 `localStorage`、相对 Cookie、SSE 与 Next.js/Vue 路由报错不可用。为此，LightIsle 明确采用 **“仅 Mac 主人本机安装可信插件（非不可信第三方代码沙盒）+ 服务端凭据剥离与实时会话校验”** 的务实方案：
1. **明确同源信任边界（非浏览器强 Origin 沙盒）**：
   - Web 应用中心使用 `<iframe sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads">`，保留 `allow-same-origin` 以支持家庭应用的 `localStorage`、WebSocket 与 SSE，同时禁止 `allow-top-navigation`；
   - 由于同时开启 `allow-scripts` 与 `allow-same-origin` 在浏览器规范中不构成针对恶意第三方 JS 的强 Origin 隔离，且无 `Referer` 请求仍可访问同源接口，**本机制定位为防止正常家庭插件误调宿主 API 的工程护栏，而非面向不可信第三方代码的浏览器沙盒**（插件与 `automation/scripts` 一样仅由 Mac 主人在本机受控安装；若未来开放第三方不可信插件市场，必须引入独立端口或子域名实现真正的浏览器 Origin 隔离）。
2. **服务端 `/api/v2/*` 跨路径请求拦截**：
   - 在 `core/internal/server/` 中，所有 `/api/v2/*` 接口检查 `Referer`：凡是 `Referer` 路径以 `/apps/` 开头的请求，直接拒绝（`403 Forbidden: app_origin_isolated`）。
3. **宿主凭据完整剥离、一次性 Ticket 兑换与实时账户状态校验**：
   - Go Core 将 `/apps/{id}/*` 请求转发给动态插件子进程前，显式剥离客户端传入的 `Authorization`、`Proxy-Authorization`、所有客户端伪造的 `X-LightIsle-*` 头以及所有 `lightisle_*` Cookie（含 `lightisle_session` 与 `lightisle_app_<id>`），随后再由网关注入权威的 `X-LightIsle-Proxy-Secret` 与 `X-LightIsle-User-*` 身份头，确保插件后端绝无法获取宿主 Bearer Token 或 Session Cookie；
   - 客户端通过 `POST /api/v2/apps/{id}/launch` 获取 60 秒单次 `__li_ticket`，网关校验并立即销毁该 Ticket 后写入 AES-256-GCM 加密的 `HttpOnly` 路径限定 Cookie `lightisle_app_<id>`（`Path=/apps/<id>`，内部仅存 `GrantID` 映射，绝不回传原始 `SessionToken`），并 `302 Found` 重定向至干净的 `/apps/<id>/`（URL 中绝不驻留长期会话凭据）；每次访问均通过 `auth.Store` 实时校验账号启用状态、主会话有效性及最新角色，一旦退出登录、停用账号或调整权限，旧插件 Cookie 立即失效。
4. **插件业务数据一致性备份与清单校验恢复（`ExportAppData` / `RestoreAppData`）**：
   - 支持最高 `512 MiB` 的插件业务数据归档导出与恢复（`GET /api/v2/apps/{id}/data-backup`、`POST /api/v2/apps/{id}/data-restore`）；
   - 导出时对 SQLite 数据库强制执行 `VACUUM INTO` 一致性快照（若快照失败立即中止导出，绝不退回跳过 WAL/SHM 的原始文件复制），先在服务端临时文件完成构建与校验后再流式返回 `200 OK`；
   - 归档内嵌 `backup-manifest.json`（含 `schemaVersion: 1`、`appId`、非空 `dataFileCount` 及逐文件大小与 SHA-256 摘要）；恢复时先在独立暂存目录完成解压与全量清单/SHA-256/插件 ID 核验（校验失败不停止正在运行的插件进程，也不触碰原数据目录），校验通过后才切换数据目录并在失败时自动回滚及恢复原运行状态。

---

## 六、macOS 原生端、Web 与 Flutter 三端「应用中心」与 MCP 调试台

- **普通家庭成员视图（Web / Flutter）**：仅展示管理员已首次激活且授权给自己访问的应用卡片，点击后在内嵌工作台中直接免密打开，隐藏底层内存、运行模式与 Cron 设置；当插件启动失败或网关不可达时，仅向普通成员展示脱敏的友好提示（「应用暂时无法打开，已保留应用数据，请联系管理员检查」），绝不泄漏宿主机目录路径、脚本内容或 `stderr` 堆栈。
- **插件启动与运行异常可解释诊断（`AppDiagnostic` + 浏览器网关诊断页）**：当插件在清单/脚本校验、启动前环境检查、子进程拉起（如 `exit 127` 缺少运行时、缺少 `node_modules`/`.next`/`.venv` 构建产物、端口占用、TCC 权限拦截、脚本 `exit 0` 未前台常驻、健康检查 `HTTP 5xx` 或未监听 `$PORT`）或运行期崩溃时，Go Core 自动提取关键 `stderr/stdout` 摘要并生成结构化 `diagnostic`（`summary`、`reason`、`logExcerpt`、`checks` 排查步骤、`solutions` 解决办法及 `dataSafe` 数据安全说明）；管理员在 macOS 原生端（插件卡片与二级详情页）、Web 应用中心、Flutter 应用中心及浏览器直接打开 `/apps/<id>/` 网关页时均可直接查看完整排障指引，无需手动翻找后台进程输出。
- **macOS 原生管理端（`Docker 与应用` 顶栏三模式切换 + `设置 → 通知` 快捷入口）**：
  - 在 `Docker 与应用` 页面顶部提供 **「轻应用与插件」**、**「MCP 开发者与调试」** 与 **「Docker 容器」** 三模式切换（由 `NativeAppsModel.swift` 经 `apps <op>` 私有 IPC 与 Core 通信）；
  - **轻应用与插件**：一级列表展示插件运行状态/内存/端口、首次激活确认、唤醒/停止/重启与默认浏览器免密打开；新建多语言插件脚手架采用受限高度弹窗，而点击「管理与日志」则进入全宽二级详情页（`AppPluginDetailView`，带统一顶栏返回与未保存修改保护），集中承载实时 stdout/stderr 与 Cron 执行记录、家庭成员访问权限、Web/Cron 生命周期配置、`NSSavePanel`/`NSOpenPanel` `plugin-data` 一致性归档导出与恢复、插件卸载，以及在 Finder 中直达 `plugins/<id>` 与 `plugin-data/<id>` 目录；
  - **MCP 控制台与调试**：提供本机 Stdio MCP 与局域网 HTTP/SSE MCP 双开关、Bearer Token 查看/复制/轮换、一键复制本机/局域网提示词与 `mcpServers` JSON、**MCP 交互式调试器（MCP Inspector，支持动态拉取并调用全量 82 个系统管理与插件开发工具）**、**轻应用网关 HTTP 探针（Gateway Probe）** 以及 **MCP 实时调用追踪日志（最近 50 条）**。
- **Web 与 Flutter 管理员视图**：
  - 查看实时状态（`静态就绪 0 MB` / `休眠中 0 MB` / `运行中 28 MB`）、活跃连接数与授权范围徽章；
  - 提供本机与局域网 MCP 开关、Token 轮换、提示词复制、成员权限分配、生命周期抽屉、各账户独立 Agent 连接令牌（`AgentConnections.vue`），以及内嵌的**「局域网 MCP 与调试台」**弹窗（动态加载 `tools/list` 全量 82 个管理与插件工具、发送网关 HTTP 探针与查看/清空调用追踪日志）。

---

## 七、全功能管理与开发者 MCP Server（Unified `lightisle-mcp` v2.0）

```bash
# 方式 1：本机 Stdio 接入（优先通过回环桥接运行中的 lightisled 守护进程，共享全部 82 个管理与开发工具）
lightisled mcp --data-dir "$HOME/Library/Application Support/LightIsle"

# 方式 2：局域网 Streamable HTTP / SSE 远程接入（支持管理员 MCP Token 或各账户独立 li_mcp_... 令牌）
POST http://<Mac-LAN-IP>:16666/api/v2/mcp
GET  http://<Mac-LAN-IP>:16666/api/v2/mcp/sse
Authorization: Bearer <MCP_TOKEN_OR_LI_MCP_TOKEN>
```

### 7.1 开关控制、身份分级、强制审计与极高危隔离边界
- **持久化与三端同步**：系统级开关保存在 `<DataDir>/apps-config.json`（`{"mcpEnabled": false, "mcpLanEnabled": false}`，**默认全部关闭**）。管理员可在 **macOS 原生 App**、**Web 应用中心** 或 **Flutter 应用中心** 随时开启/关闭（`PUT /api/v2/apps/mcp`）或轮换 256-bit 管理员令牌（`POST /api/v2/apps/mcp/token/rotate`）；普通 `/api/v2/apps` 响应绝不附带 `mcpToken` 明文（仅专用 `/api/v2/apps/mcp` 接口对已认证管理员返回）。此外，家庭成员与管理员均可在「设置 → Agent 连接」签发独立可撤销的 `li_mcp_...` 令牌（`POST /api/v2/auth/mcp-connections`，支持只读 `canWrite=false` 或读写 `canWrite=true`）。
- **局域网与反代阻断边界**：`/api/v2/mcp*` 仅允许本机回环（`127.0.0.1`/`::1`）及 RFC1918/ULA 私有局域网地址直连；凡公网来源 IP 或携带 `Forwarded`、`X-Forwarded-*`、`CF-Connecting-IP`、`X-Real-IP` 等反向代理头的请求一律返回 `403 mcp_lan_only`，防止经本机 Cloudflare/FRP 隧道绕过局域网限制。
- **全量持久审计与脱敏追踪**：每一次 `tools/call`（无论只读查询还是配置修改）均通过 `BeginMCPAudit` → `FinishMCPAudit` 记入 SQLite `audit_events` 持久审计表，并同步写入 `mcp-debug-log.json`（最近 50 条，自动对 `password`、`secret`、`token`、URL 查询串/磁力链接、`env.json` 与 `content` 文件正文脱敏）。
- **极高危操作硬隔离（永不向 MCP 开放）**：严禁开放磁盘抹除/格式化/分区、存储根注销删除（`DELETE /roots/{id}`）、回收站永久物理清空（文件删除仅提供移入可恢复回收站的 `lightisle_move_to_trash`）、任意宿主机 Shell 命令执行、密码哈希或 Mac Keychain 凭据读取（SMTP/Bark/Cloudflare/TMDB 等）、停用管理员账户或重置管理员密码，以及未激活插件自批准（`pendingActivation: true` 仍必须在 UI 显式确认）。

### 7.2 规范资源（4 项）与统一工具矩阵（9 大域共 82 个 Tool）

| 类型 / 领域 | 名称 / 代表工具 | 功能描述与权限边界 |
| :--- | :--- | :--- |
| **Resource** | `lightisle://specs/mcp-security` | 全功能管理 MCP 安全边界、权限分级、持久审计说明与极高危禁区清单。 |
| **Resource** | `lightisle://specs/plugin-v2` | 多语言轻应用规范、`LIGHTISLE_PROXY_SECRET` 校验、`LIGHTISLE_PLUGIN_DATA_DIR` 隔离与启动模板。 |
| **Resource** | `lightisle://specs/ui-theme` | LightIsle Liquid Glass 视觉令牌与深浅色自适应 CSS 变量规范。 |
| **Resource** | `lightisle://specs/automation-v1` | 纯定时脚本（`automation/scripts`）与邮件 HTML 模板规范。 |
| **1. 系统与审计** | `health_check`、`get_system_status`、`get_system_history`、`get_cache_settings`、`set_cache_settings`、`clear_cache`、`list_audit_events` | 查看 Mac 主机 CPU/内存/网络/运行时间、调整派生缓存上限或清理缓存、查询审计事件（管理写操作限管理员 + `canWrite`）。 |
| **2. 磁盘与多盘存储根** | `list_disks`、`get_disk_smart`、`list_roots`、`get_root`、`update_root`、`get_storage_overview`、`list_storage_quotas`、`set_member_disk_quota`、`reconcile_storage_quota`、`list_personal_spaces` | 查询物理磁盘与 SMART 状态、查看/重命名在线存储根、查询或调整成员逐盘配额账本与重算核对（不开放注销删除存储根）。 |
| **3. 文件与安全回收站** | `list_files`、`search_files`、`stat_file`、`read_text_file`、`create_folder`、`rename_entry`、`move_entry`、`copy_entry`、`extract_archive`、`lightisle_move_to_trash`、`list_trash`、`restore_from_trash`、`list_shares`、`create_share`、`revoke_share` | 按当前令牌所属用户及逐盘目录授权浏览/搜索/读取文本、整理目录、管理限时分享；删除仅移入可恢复回收站，不提供永久物理清空。 |
| **4. 照片图库与影院** | `list_photos`、`list_albums`、`create_album`、`share_folder_album`、`trigger_gallery_scan`、`list_cinema_items`、`get_cinema_detail`、`trigger_cinema_scan`、`rematch_cinema_metadata` | 查询照片时间线与相册、管理私人/共享文件夹相册、触发图库或影院增量扫描及手动重匹配影视元数据。 |
| **5. 下载中心** | `list_downloads`、`create_download`、`pause_download`、`resume_download`、`cancel_download`、`retry_download_publish` | 查看下载队列、由管理员创建 HTTP/磁力下载任务（URL 凭据自动审计脱敏）、暂停/恢复/取消及重试本地目录发布。 |
| **6. 成员与目录授权** | `list_users`、`create_member`、`set_member_enabled`、`reset_member_password`、`list_user_file_grants`、`set_user_file_grants`、`list_dav_Overview` | 管理员查看成员名册、创建普通家庭成员、启停普通成员或重置普通成员密码（硬拦截对管理员账户的停用与改密）、配置逐盘读写目录授权。 |
| **7. 本地定时脚本** | `list_automation_tasks`、`get_automation_task`、`update_automation_task`、`run_automation_task`、`get_automation_logs`、`list_notification_channels`、`test_notification_channel` | 查看本地 `automation/scripts` 任务、修改启停/Cron/通知事件（完整保留本地邮件模板配置）、立即触发单次运行、读取只读执行日志与测试通知渠道（不回显任何渠道密钥）。 |
| **8. 轻应用与插件开发** | `lightisle_get_environment`、`lightisle_list_apps`、`lightisle_scaffold_app`、`lightisle_validate_and_reload`、`lightisle_read_plugin_file`、`lightisle_write_plugin_file`、`lightisle_app_action`、`lightisle_get_app_logs`、`lightisle_probe_app`、`set_app_access`、`update_app_config` | 完整保留并统一审计原有 9 个插件脚手架/读写/启停/网关探针工具，同时支持查询与更新已激活轻应用的家庭成员访问策略与运行生命周期配置。 |
| **9. 后台任务与维护** | `list_background_tasks`、`cancel_background_task`、`list_system_alerts`、`dismiss_system_alert`、`list_pending_upload_reservations`、`cleanup_expired_uploads` | 查看或取消可中断后台任务、查看与确认系统告警、核查未完成上传预占与清理过期分片暂存。 |

---

## 八、第一示范参考项目：`cpe-monitor` 深度解构与改造方案

1. **反代子路径与 `LIGHTISLE_PROXY_SECRET` 免密鉴权（`src/lib/auth.ts`）**：
   - 在 `next.config.ts` 中支持 `basePath: process.env.BASE_PATH || ''`；
   - 在 `src/lib/auth.ts` 的 `getSession()` 中：当 `process.env.LIGHTISLE_PROXY_SECRET` 非空且请求头 `x-lightisle-proxy-secret === process.env.LIGHTISLE_PROXY_SECRET` 时，直接信任 `x-lightisle-user-id` 与 `x-lightisle-username` 免二次登录；未通过网关直连 `127.0.0.1:$PORT` 的请求仍需走原有的密码校验。
2. **代码与数据目录分离（`LIGHTISLE_PLUGIN_DATA_DIR`）**：
   - 数据库路径支持优先读取 `process.env.LIGHTISLE_PLUGIN_DATA_DIR`，升级代码时数据库不受影响。
3. **单次静默采集（`scripts/collect-once.mjs`）**：
   - 由 `automation.Manager`（任务 ID：`app-cpe-monitor`）每 15 分钟唤醒运行 1 秒即退，平时 `0 MB` 内存。

---

## 九、分阶段落地里程碑（Implementation Roadmap）

| 阶段 | 目标与交付物 | 验证标准 |
| :--- | :--- | :--- |
| **Phase 1: 核心引擎与 `automation` 桥接 (Go Core)** | 实现 `core/internal/automation/plugins.go`（`app-<id>` 兼容注册）与 `core/internal/apps/`（三态生命周期、`LIGHTISLE_PROXY_SECRET` 注入、`/api/v2/*` Referer 越权拦截、`LIGHTISLE_PLUGIN_DATA_DIR` 隔离、成员 ACL 与 Launch Ticket）。 | `go test -race ./core/internal/apps/... ./core/internal/automation/... ./core/internal/server/...` 全绿。 |
| **Phase 2: `lightisled mcp` 与 `cpe-monitor` 实装** | 实现 `lightisled mcp` 子命令与 4 个 Tool；完成 `cpe-monitor` 的 `basePath`、`LIGHTISLE_PROXY_SECRET` 与单次采集适配。 | 验证 MCP JSON-RPC 交互闭环；验证 `cpe-monitor` 按需唤醒、闲置休眠与代理防伪校验。 |
| **Phase 3: Web / Flutter / macOS 三端「应用中心」** | 实现 Web 与 Flutter「应用中心」（内嵌工作台、成员权限分配、生命周期抽屉、MCP 提示词复制）及 macOS 原生端快捷入口。 | Web、Flutter、macOS 全量构建与测试通过；`python3 -B scripts/check-docs.py` 0 错误。 |

---

## 十、个人与家庭软件的安全与复杂度边界（六大问题取舍矩阵）

遵循 [AGENTS.md](../AGENTS.md) 的产品定位，我们对六个潜在架构风险采取 **“真风险必防，伪沙箱不堆”** 的务实取舍：

| 级别 | 关注问题 | 我们的判断与适度边界方案 |
| :--- | :--- | :--- |
| **P0-1** | **插件与宿主共用浏览器 Origin** | **明确可信本地插件定位 + 服务端凭据完整剥离 + Referer 护栏**：<br>1. 明确插件与 `automation` 同属“仅 Mac 主人本机安装的可信家庭工具”，同源 `allow-scripts allow-same-origin` Iframe 旨在保障 `localStorage`/SSE 可用而非第三方不可信代码沙盒（若未来开放第三方插件需引入独立 Origin）；<br>2. 反代转发前完整剥离 `Authorization`、`Proxy-Authorization`、客户端 `X-LightIsle-*` 头与全部 `lightisle_*` Cookie；<br>3. 应用 Cookie 关联真实用户与主会话并实时校验账号/角色状态，退出登录、禁用账号或权限撤销立即失效；<br>4. 服务端拦截 `Referer: .../apps/...` 对 `/api/v2/*` 的误调用（`403 app_origin_isolated`）。 |
| **P0-2** | **插件进程拥有 Mac 用户权限** | **遵守 `AGENTS.md`「脚本以当前 Mac 用户权限运行，没有虚假沙箱」**：<br>1. 不引入已废弃且易导致 Node/Python/串口报错的 `sandbox-exec` 伪沙箱；<br>2. 保持“仅 Mac 主人可在本机放脚本、家庭成员仅能通过 Web/App 使用”的信任边界；<br>3. 做好环境变量卫生（仅注入白名单基础变量 + 本插件 `env.json`，不泄漏宿主内部凭据）。 |
| **P0-3** | **回环端口 `127.0.0.1` 身份头信任** | **极简 `LIGHTISLE_PROXY_SECRET` 比对**：<br>每次启动子进程注入随机环境变量 `LIGHTISLE_PROXY_SECRET`，反代转发时附带请求头 `X-LightIsle-Proxy-Secret`；插件一行比对即可防本机其他进程伪造 `X-LightIsle-User-ID`，无需搞复杂 HMAC 签名。 |
| **P1-1** | **Cron 复用协议与任务 ID 兼容性** | **原生 `app-<id>` 命名与目录直读**：<br>插件 ID 限制为 `^[a-z][a-z0-9-]{0,40}$`，注册到 `automation.Manager` 时使用合法任务 ID `app-<id>`（无冒号，100% 兼容现有 `^[a-z][a-z0-9-]{0,47}$`），并在 `automation/plugins.go` 中直接打开 `plugins/<id>` `os.Root`，不依赖跨目录软链接。 |
| **P1-2** | **MCP 允许 Agent 自动执行与热重载** | **默认 `admin_only` + 仅静态校验热重载**：<br>`lightisle_scaffold_app` 默认将权限设为 `admin_only`（不会自动暴露给家人）；`lightisle_validate_and_reload` 仅做静态 Schema/权限校验并刷新列表（新应用默认处于 `on-demand` 休眠态 `0 MB`），无需繁琐的企业级工单审批即可由管理员一键打开验收。 |
| **P1-3** | **数据目录与备份边界不清** | **1 个环境变量分离代码与数据，不造复杂跨盘状态机**：<br>自动注入 `LIGHTISLE_PLUGIN_DATA_DIR=<DataDir>/plugin-data/<id>`，让插件代码与 SQLite 数据自然分离；宿主配置备份天然排除 `plugins/` 与 `plugin-data/`。 |

---

## 十一、内置引导提示词与 AI Agent 自主开发协议（Bootstrap & System Prompt）

### 11.1 内置「一键连接 LightIsle MCP」引导提示词

```markdown
请帮我将当前 Mac 上的「LightIsle（轻屿）全功能管理与开发 MCP Server」安装并注册到你的 MCP 配置文件中：

- **MCP 服务名称**：`lightisle`
- **传输方式**：`stdio`（本机直连守护进程回环桥接）或 `http`（`http://<Mac-LAN-IP>:16666/api/v2/mcp`）
- **可执行命令**：`/Applications/LightIsle.app/Contents/Resources/core/lightisled`
- **命令参数**：`["mcp", "--data-dir", "~/Library/Application Support/LightIsle"]`

**操作要求**：
1. 请自动检测你当前所处的 Agent 环境（如 Claude Code、Codex、Cursor 或 Antigravity MCP 配置），写入上述 `lightisle` MCP 配置；
2. 配置完成后，请先读取 `lightisle://specs/mcp-security` 与 `lightisle://specs/plugin-v2` 资源，并调用 `health_check` 或 `lightisle_get_environment` 验证连接是否成功；
3. 你可以通过该 MCP 查询和操控 LightIsle 的存储配额、文件与回收站、图库相册、影院刮削、下载任务、家庭成员目录授权、本地定时脚本与轻应用插件；所有调用均会被审计记录，删除文件只允许移入回收站，涉及未激活插件首次上线或高影响配置变更时请先向我确认。
```

### 11.2 内置在 `lightisle://specs/plugin-v2` 中的 AI Agent 核心开发规范

```markdown
# LightIsle（轻屿）轻应用与插件开发者 AI Agent 指令规范 (v2.1)

你是一个专门在 Apple Silicon macOS 环境下，为家庭私有 NAS 系统「LightIsle（轻屿）」开发与适配扩展轻应用（Mini-Apps & Plugins）的资深全栈系统工程师。请严格遵守以下协议，不要修改 LightIsle 宿主自身的 Go/Swift/Flutter/Web 源码。

## 1. 自主工作流原则
1. **自动感知环境**：先调用 `lightisle_get_environment` 与 `lightisle_list_apps`，获取真实的 `pluginsDir`、`pluginDataDir`、家庭成员列表与已配置通知渠道。
2. **仅在关键业务决策时向用户提问**：
   - 技术细节（端口、路径、权限、`BASE_PATH`、`LIGHTISLE_PROXY_SECRET` 校验、`LIGHTISLE_PLUGIN_DATA_DIR` 数据分离）全部由你自动处理；
   - 仅在需确认【应用向哪些家庭成员开放】【Cron 采集频率与通知渠道】【外部硬件/API 账号密码】时向用户提问。

## 2. 五大核心工程规范
1. **代码与数据目录分离（`$LIGHTISLE_PLUGIN_DATA_DIR`）**：
   - 插件产生的所有 SQLite 数据库、缓存与状态文件**优先保存在 `$LIGHTISLE_PLUGIN_DATA_DIR` 目录下**，避免重写代码目录时丢失数据。
2. **轻量代理防伪校验（`$LIGHTISLE_PROXY_SECRET`）**：
   - 当插件需要根据 `X-LightIsle-User-ID` / `X-LightIsle-Role` 免密登录时，请先校验 `req.headers['x-lightisle-proxy-secret'] === process.env.LIGHTISLE_PROXY_SECRET`。
3. **三态前端模式（优先选择最轻方案）**：
   - `mode: "static"`（纯静态 HTML，首选 0 MB 方案）：`run-cron.sh` 定时生成数据，前端用相对路径读取；
   - `mode: "on-demand"`（按需唤醒动态后端，默认推荐）：监听 `127.0.0.1:$PORT`，支持 `BASE_PATH=/apps/<id>`，闲置自动休眠归零；
   - `mode: "persistent"`（24/7 常驻）：仅用于确需实时后台长连接的服务。
4. **必须使用 `exec` 启动主进程**：
   - `run-web.sh` 最后一行必须使用 `exec`（如 `exec node server.js`），确保进程信号直接送达业务进程。
5. **一键校验与热重载**：
   - 编写完成后，调用 `lightisle_validate_and_reload` 工具完成合规检查并触发本机 LightIsle 热重载。
```
