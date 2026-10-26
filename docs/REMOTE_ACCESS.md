# WebDAV 与 Cloudflare Tunnel 远程访问

## 局域网连接协议

Mac 原生管理端「局域网访问 → 连接协议」默认启用 HTTPS，自动生成本地证书；没有 HTTPS 条件时，可在确认明文风险后主动启用 HTTP。服务监听仅绑定私有 IPv4 网卡，不自动修改路由器端口映射。关闭服务会停止 Bonjour 广播。

Bonjour 的 _lightisle._tcp TXT scheme 指明 https 或 http；旧版广播未提供 TXT 时仍按 HTTPS 处理。Android/iOS 发现仅接受私有数字 IP、合法协议和相符的 URL。Flutter 登录页默认「强制使用 HTTPS」，关闭需用户明确确认；只允许私有局域网 HTTP，拒绝公网 HTTP。**客户端允许 HTTP 并不自动更改 Mac 服务配置，两个选项需匹配。**

HTTP 下密码、会话 Cookie、WebDAV 凭据及文件均为明文，存在同网络窃听和中间人风险。仅供可信家庭内网使用，不能将该端口映射到公网；推荐优先 HTTPS。

> 合并旧 `TUNNEL_WEBDAV_DISK_PLAN_2026-10-24.md` 中 WebDAV / Tunnel 的长期有效部分；硬盘与 SMART 已移入 [STORAGE_AND_DISKS.md](STORAGE_AND_DISKS.md)。当前是可选开发版功能，公网配置、手机网络及第三方客户端仍需要真实验证。

## WebDAV（`/dav/`）

- `core/internal/dav` 使用 Go WebDAV handler。浏览器 Cookie 不充当 WebDAV 凭据；用户在 Web/Flutter 设置页为自己生成独立随机密码，**仅创建时展示一次**，服务端只存摘要、最多 8 条，支持按条撤销。HTTP Basic 失败限流，链接为当前源的 `/dav/`。
- 授权与文件 API 相同：管理员有全根访问；普通成员仅在获授权子目录中可读，写操作还必须有写授权；祖先目录可列目录结构但不得泄露未授权子项。`.lightisle-*` 内部文件始终拒绝。
- DELETE 与覆盖 MOVE 进入应用回收站而非不可恢复物理删除；PUT 前进行空间预检（非持久空间预留）。WebDAV PUT **不提供独立分片续传**；第三方客户端的大文件传输重试行为需验证。
- 一次请求固定共享根的文件描述符与管理器租约，切换共享目录须等请求释放；每个路径分量拒绝符号链接，不能通过同一根内的链接绕过子目录授权。目录枚举过滤内部暂存、回收站、链接及特殊文件。
- PUT 先写同目录私有暂存，完整接收、同步并复查当前授权、父目录和目标版本后才原子发布；中断、取消或发布前失败保留旧文件。COPY 同样检查源读取完成及源权限，先判断不存在的目标必须以不替换方式发布。覆盖后的清理错误不能被误报为写入失败。极端回退失败时保留旧副本并记录本机恢复线索，需要所有者人工处理，不提供跨目录联合事务。
- COPY/MOVE 覆盖目标先进入应用回收站；后续步骤失败时原目标可能已从活动目录移入回收站，需人工核对和恢复。这不等同于整个目录复制或移动的事务式回滚。WebDAV 锁存于内存，Core 重启或共享根切换后不保留；切换根后客户端需要重新申请锁。
- DELETE 的对象复核与底层移入回收站不是跨所有文件 API 的联合事务；若另一接口在窄窗口替换同名对象，后来对象仍可能被移入回收站。内容与回收站记录保留，但严格的并发条件删除仍有待完善，不能将其宣称为文件系统级快照删除。
- API `GET/POST /api/v1/dav/credentials`、`DELETE /api/v1/dav/credentials/{id}` 均限登录用户管理自己的凭据。创建/撤销不会暴露其他成员密码。

## Cloudflare Tunnel（可选）

- 只读取白名单位置已安装的 `cloudflared`，不捆绑、不下载、不自动安装；缺失时引导用户自行 `brew install cloudflared`。
- 隧道子进程由 Mac App/Core 管理。Core 退出隧道一并停止；连接中断有有限退避/最多次数的重启与持久 `tunnel_disconnected` 提醒；不会试图替用户修改 macOS 系统守护服务。
- 快速模式使用 `cloudflared tunnel --url http://127.0.0.1:<port> --no-autoupdate`；分配的 `trycloudflare.com` 地址随机、可能变化，**只适合临时测试**，不是稳定生产域名。
- API Token 模式允许 Mac 本地创建/读取隧道、绑定主机名、更新 Ingress 和受控 DNS CNAME。只删除自己隧道关联的域名记录；遇到指向其他隧道的冲突必须失败，不自动覆盖用户其他 Cloudflare 配置。Token 进入 macOS 钥匙串，不进入日志、公共 API、审计或持久明文配置。
- Mac 私有 IPC `tunnel status`、`tunnel quick on`、`tunnel off` 以及受限高级 API 命令。入口在 Mac 设置而非浏览器的主机命令执行接口。Cloudflare Token 所需权限应按最小授权原则配置，例如 Tunnel 编辑/账户读取和指定 Zone/DNS 访问。
- 代理/TUN 环境、Ingress 多端并发编辑、免费试用条件和用户自有域名 DNS TTL 属外部运行因素，务必单独实际验收。

### Token 配置、忘记与重启恢复（现有实现约束）

- **首次配置**：Go Core 接受 `tunnel api configure` 携带的新 Token 并验证 Cloudflare 账号，无须预先拥有已配置的 API Token。其他需要授权的隧道账号操作仍必须先有合法凭据。Core 的 `configure` 回执带 `operation` 标记；Mac 只在这个回执确认后才保存暂存的新 Token，普通 `accounts` 查询不视为保存成功。
- **钥匙串出错**：保存新凭据时优先更新已有 Keychain 项；失败不先删除旧凭据，向 Mac 管理页明确报错。未验证/发送失败的明文暂存不会被持久化。
- **“忘记 API Token”**：钥匙串删除失败时提示并保留可见状态；本机删除成功后通过私有 `tunnel api forget` 清除 Core 内存中的 API Token，Core 回复 `forgotten`。若 Core 不在线则无进程内令牌需要清理。此操作**不撤销 Cloudflare 官方账号中签发的 Token，也不自动停止已运行的 Tunnel**；需要停止访问时仍须单独停用隧道和按需在 Cloudflare 端撤销令牌。
- **Core 重启**：Core 的 API Token 只留在进程内存。Mac 在子进程退出时清除旧“已配置”缓存状态，重启后从 Keychain 加载并重新验证，不依赖上一次的界面状态。
- **协议和测试**：命令操作白名单与大小限制在 `apps/macos/Sources/LightIsle/TunnelWireCodec.swift`，响应模型在 `TunnelPayloadParser.swift`；服务端实现在 `core/cmd/lightisled/tunnel_control.go`，首次配置与忘记令牌测试在 `tunnel_control_auth_test.go`。自动化单测通过不替代用真实 Cloudflare Token、网络断线、权限收回与 Mac 钥匙串故障进行人工验证。

## FRP 穿透客户端（可选，Mac 本机管理）

- Mac 「服务 → FRP 穿透」进入页面后按需自动查询 **GitHub 官方 Releases 版本列表**，显示最新稳定版及历史版本，也可手动点击「获取版本」刷新，选择后「下载安装 / 更换版本」。仅管理 `frpc`，不捆绑客户端、不提供 `frps` 服务端；用户需要自己的 frps 地址、鉴权令牌及代理映射。
- 版本目录来自 GitHub Releases REST API，单次最多扫描 4 页（每页 100 项），只接受形如 `vX.Y.Z` 的官方 Tag 和匹配 `frp_X.Y.Z_darwin_arm64.tar.gz` 的原版资源。官方 API 返回的 SHA-256 必须可验证且实际压缩包摘要匹配后才安装；没有 ARM64 包或没有摘要的较早版本会显示「不可安装」，**不会绕过校验**。无需随 LightIsle 更新才能看到后续发行版本；GitHub 网络故障或 API 限流时显示错误并保留正在运行的版本。
- 下载中和 frpc 正在运行时禁止覆盖二进制文件。用户须先停止运行中的 frpc 再升级或降级，下载安装失败不动原有二进制及配置；下载成功写入本地安装版本元数据，重启后能显示真实已选版本，旧版本无元数据则显示「版本未知」，不虚报固定版本。切换版本可能与原 TOML 或远端 frps 不兼容，需要自行核对。
- 安装位置：`~/Library/Application Support/LightIsle/frp/frpc`；配置：同目录下 `frpc.toml`。第一次访问会生成仅当前用户可读的 TOML 示例（含占位值）；**之后绝不会自动覆盖**，不会将 TOML 密钥写入 Web 接口或诊断输出。通过 macOS 默认文件关联打开，未配置 TOML 编辑器时在 Finder 定位。
- 必须编辑占位值并主动点击启动。FRP 不随 Core 启动而自动启用，也不修改路由器、防火墙、系统服务、LaunchAgent。Core 退出后由系统进程上下文终止所启动的 frpc。停止后手动启动即可应用已编辑配置。
- Mac 与 Core 仅通过可信父进程 stdin `frp status/versions/install <version>/start/stop` 交换状态；**无远程 HTTP 控制接口**。用户界面只传版本字符串，实际下载源及摘要均经 Go Core 版本列表缓存核实。运行中仅证明本地 frpc 进程存在，**不代表远端 frps 已连接或映射可访问**；连接成功需在真实 frps 上验收。
- 严禁把允许 HTTP 的 LightIsle 登录端口直接暴露到公网。应优先设置 HTTPS、可信证书、强密码和最小化公网端口暴露；测试映射前需要用户确认相关风险。TOML 是本机敏感文件，不要把 Token 提交到 Git。

## 建议验收

1. 局域网 HTTPS 先测试账号登录/登出和成员目录隔离；验证未显式开启远程服务时没有 LAN 监听。
2. Finder `⌘K`/Infuse 挂载 WebDAV，验证读写、撤销密码、成员的越权目录不可见及移动到回收站。
3. 临时 Cloudflare URL 登录、停止后失效、断网恢复和 Clash/TUN 情况；公网只能通过 HTTPS 使用。
4. Token 模式先以无其他重要路由的测试域名验证绑定/撤销/重启，**不可在无人确认时删除现有隧道或 DNS**。
5. 真正对外开放前复核 [SECURITY.md](SECURITY.md) 和 [PRODUCTION_RELEASE.md](PRODUCTION_RELEASE.md)；功能代码存在不代表 SSL、DNS、账户最小权限及公网防护已验收。
