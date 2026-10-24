# 硬盘管理完善 + WebDAV + Cloudflare Tunnel 交付记录（2026-10-24）

本轮三项功能已进入开发版，遵循既有边界：Core 托管、Mac App 私有 IPC 控制、外部二进制白名单、凭据入钥匙串。本文记录实现范围、安全设计与**待真机验收清单**。

## 1. 硬盘管理完善

### SMART 健康详情（`core/internal/diskhealth`）
- 白名单探测 smartctl（`/opt/homebrew/bin/smartctl`、`/usr/local/bin/smartctl`），`smartctl --json -a /dev/diskN`，12 秒超时 + 256 KiB 输出上限；解析型号、序列号、固件、温度、SMART 结论、通电时长、已用寿命（NVMe `percentage_used` / ATA 177）。
- **诚实降级**（原因码，前端映射中文）：`smartctl_not_installed`（引导 `brew install smartmontools`）、`smartctl_permission_required`（macOS 无 root 直读设备受限，回退 diskutil 基础状态）、`smartctl_device_unsupported`（USB 桥接不支持）、`smartctl_query_failed`。**不引入特权助手**，因此多数外置盘在无 root 时只能看到 diskutil 的 Verified/Failing 基础状态——这是如实呈现，不是缺陷掩饰。
- 每盘结果缓存 5 分钟。HTTP：`GET /api/v1/admin/disks/{id}/smart`（管理员）；IPC：`disk smart <id>`。
- UI：Web 硬盘管理卡片"健康详情"展开区；Mac App 磁盘卡片同款。

### 容量与告警增强
- 低空间告警阈值可配置：`core/internal/tasks/threshold.go` 持久化到数据目录 `storage-alerts.json`（默认沿用 2 GiB / 5%）；IPC `alerts threshold`（查询）/ `alerts threshold <b64>`（设置）；任一阈值命中即告警，两项同时为 0 会被拒绝。
- Mac App「数据与存储」新增"低空间告警阈值"设置组；Web 硬盘管理显示用量百分比与"存储卷概览"（来自 `/api/v1/system` 的 volumes）。

### 磁盘活动监控
- `core/internal/system/metrics_darwin_arm64.go` 经 IOKit 枚举整盘 IOMedia（`diskN`）读取 IOStorage 累计计数，按采样差值计算读写速率（首帧与计数回绕不产生速率；零流量合成卷被过滤），随 `Snapshot.DiskIO` 下发。
- UI：Web 概览"硬件规格"区、Mac 存储页每个卷卡片显示实时读写速率。

## 2. WebDAV（完整读写，`/dav/`）

- 依赖 `golang.org/x/net/webdav`；新增 `core/internal/dav` 包 + `core/internal/auth/dav.go` 凭证存储。
- **认证**：独立 WebDAV 密码——服务端生成 24 字符随机串、仅展示一次、只存 SHA-256 摘要（`dav_credentials` 表）；每用户上限 8 条、可撤销、记录最近使用。Basic 认证失败按客户端地址限流（15 分钟窗口 30 次）。与 Web Cookie / `X-LightIsle-Request` 完全隔离（双向）。
- **授权**：与 Web 文件 API 同一套模型——admin 全根；member 仅授权子树（可写授权才可写，祖先目录可列不可写）；目录列举逐条过滤未授权条目（对齐 Web 的 canSee 行为）；`.lightisle-` 内部路径一律拒绝。
- **安全删除**：DELETE / MOVE 覆盖经 `files.MoveToTrash` 进应用回收站，永不物理删除。PUT 前对共享根做 statfs 余量预检（64 MiB 保留）。LOCK/UNLOCK 使用 webdav 内置 MemLS。
- **路由**：`mux.Handle("/dav/")` 挂在本地与 LAN HTTPS 监听器；CSRF 请求头校验对 `/dav/` 豁免（安全响应头仍全局生效）。
- **客户端自服务**：Web 设置页"WebDAV 访问"卡片与 Flutter 设置页"WebDAV 访问"，含地址展示（`当前源/dav/`）、凭证创建/撤销与 Finder/Windows/Infuse 连接指引。
- 公开 API：`GET/POST /api/v1/dav/credentials`、`DELETE /api/v1/dav/credentials/{id}`（均 requireLogin，仅管理本人凭证）。

## 3. Cloudflare Tunnel（免费 + API Key 管理）

- **cloudflared 二进制**：仅探测 Homebrew 白名单路径；未安装时 UI 引导 `brew install cloudflared`。不捆绑、不自动下载。与用户机器上已存在的其他 cloudflared 实例（如系统 LaunchDaemon）互不干扰。
- **进程监督**（`core/internal/tunnel`）：子进程绑定 Core 生命周期（Core 退隧道必死）；环境剥离代理变量与 `CLOUDFLARE_*`（规避 Clash 等 TUN/代理对 argotunnel 控制通道的劫持）；SIGTERM→超时 SIGKILL；输出上限。意外退出自动重启（20/40/60 秒退避，上限 3 次），**在线超过 1 分钟才重置重启预算**（防止闪断死循环）；进入持久告警 `tunnel_disconnected`，恢复在线自动消除。
- **免费模式**：`cloudflared tunnel --url http://127.0.0.1:<port> --no-autoupdate`，从输出解析 `https://*.trycloudflare.com` 地址。随机域名每次启动变化，仅供测试。
- **API Key 模式**（`core/internal/cloudflareapi`）：
  - `tunnel api configure` 验证 Token 并发现账户；随后支持 tunnels 列表/创建/删除（`cleanup_on` 清理连接）、取隧道 Token、读写 Ingress 配置、zones 列表、DNS CNAME 增删。
  - **一键绑定主机名** = `EnsureHostnameRoute`（已存在且指向同一隧道则复用；指向他处则拒绝，绝不静默改写）+ 读-改-写 Ingress（保留他人规则，catch-all 恒在末位）。
  - **移除主机名** = 删除 Ingress 规则 + 仅当 CNAME 属于本隧道时删除该记录。
  - 错误映射中文（Token 无效/权限不足等）；**Token 永不进日志、错误文本或审计**。
- **IPC**：`tunnel status` / `tunnel quick on` / `tunnel run <b64>` / `tunnel off` / `tunnel api <op> [b64]`；状态推送 `LIGHTISLE_TUNNEL_STATE`。
- **Mac App**：设置页新增"Cloudflare Tunnel（可选）"组（二进制状态、状态行、免费模式启停 + 地址复制、API Key 管理入口、高级粘贴隧道 Token）；管理窗口提供 Token 引导（所需权限：Account:Read、Cloudflare Tunnel:Edit、Zone:Read、DNS:Edit）、隧道列表、新建/删除、启动/停止、主机名绑定表。API Token 存钥匙串 `dev.lightisle.tunnel`，Core 每次就绪后自动重发。

## 4. 待真机验收清单

- [ ] smartctl 两态：安装 smartmontools 后外置盘健康详情；无权限/无桥接支持的降级提示是否如实。
- [ ] SMART 提权：点击"使用管理员权限读取"弹系统密码框一次，多盘连续读取基本免弹（5 分钟缓存）；结果同步到 Web 端；取消授权无报错残留；配置 sudoers 免密后不再弹窗。
- [ ] 阈值：设置 3 GiB/10% 后人为填满存储卷，60 秒内出现 storage_low_space 告警；回调低阈值恢复。
- [ ] IO 速率：大文件复制时 Web 概览与 Mac 存储页速率非零；空闲时显示"空闲"。
- [ ] WebDAV：Finder ⌘K 挂载读写、重命名、删除入回收站；成员账号仅见授权子树；撤销密码后已挂载客户端失效；Infuse 远程挂载（经隧道）。
- [ ] 免费隧道：启停、临时域名可访问登录页、停止后域名失效。
- [ ] API Key 模式：真实 Token 建隧道 → 绑定 `nas.lengsu.top` → 启动 → 公网 HTTPS 访问；删除隧道前二次确认；误选已有隧道不破坏其路由（读改写验证）。
- [ ] 代理环境：Clash TUN 开启时隧道可连（已剥离代理环境变量，仍需实测）。
- [ ] Core 重启：API Token 自动重发后无需重新填写即可管理；`tunnel_disconnected` 告警在恢复后自动消除。

## 5. SMART 提权（2026-10-25 增补）

Core 以普通权限运行，无法直读设备 SMART；只有 Mac App 能弹出 macOS 授权对话框。采集流程放在 Mac App 侧：

1. 用户在磁盘卡片点"使用管理员权限读取…"（显式手势，绝不自动弹窗）；
2. Mac App 先静默执行 `sudo -n smartctl --json -a /dev/diskN`——若用户已配置 sudoers 免密白名单（App 内提供完全手动的指引，不代写 sudoers），直接成功、永不弹窗；
3. 否则执行 `do shell script "…smartctl…" with administrator privileges` 弹出系统密码框；sudo 授权约 5 分钟缓存，连续多块盘基本只弹一次；
4. 成功后结果经私有 IPC `disk smart report` 推回 Core 缓存（同 5 分钟 TTL），**Web 端"健康详情"在同一 TTL 内也能看到完整数据**。

安全设计：提权命令是固定模板，唯一变量是盘号（严格解析，`disk[0-9]+(s[0-9]+)?`），无任何用户字符串进入 shell；密码由 macOS 安全代理处理，不经过应用代码；用户取消则静默回退；退出 App 无任何残留进程。

## 6. 已知限制

- smartctl 在 macOS 上直读设备通常需要 root；未配置 sudoers 白名单且用户未授权时，只能提供 diskutil 级 SMART 状态（弹窗提权/免密白名单均可解锁完整数据，见第 5 节）。
- 免费快速隧道受 Cloudflare 条款限制（测试用途），域名随机且不可保留。
- WebDAV 上传不经过分片续传机制（大文件依赖客户端 PUT 重试）；低空间预检是预防性的，非硬保证。
- 隧道 Ingress 采用读-改-写，极端并发下（多端同时编辑同一隧道）仍以 Cloudflare 侧最后写入为准。
