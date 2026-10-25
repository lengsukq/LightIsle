# WebDAV 与 Cloudflare Tunnel 远程访问

> 合并旧 `TUNNEL_WEBDAV_DISK_PLAN_2026-10-24.md` 中 WebDAV / Tunnel 的长期有效部分；硬盘与 SMART 已移入 [STORAGE_AND_DISKS.md](STORAGE_AND_DISKS.md)。当前是可选开发版功能，公网配置、手机网络及第三方客户端仍需要真实验证。

## WebDAV（`/dav/`）

- `core/internal/dav` 使用 Go WebDAV handler。浏览器 Cookie 不充当 WebDAV 凭据；用户在 Web/Flutter 设置页为自己生成独立随机密码，**仅创建时展示一次**，服务端只存摘要、最多 8 条，支持按条撤销。HTTP Basic 失败限流，链接为当前源的 `/dav/`。
- 授权与文件 API 相同：管理员有全根访问；普通成员仅在获授权子目录中可读，写操作还必须有写授权；祖先目录可列目录结构但不得泄露未授权子项。`.lightisle-*` 内部文件始终拒绝。
- DELETE 与覆盖 MOVE 进入应用回收站而非不可恢复物理删除；PUT 前进行空间预检（非持久空间预留）。WebDAV PUT **不提供独立分片续传**；第三方客户端的大文件传输重试行为需验证。
- API `GET/POST /api/v1/dav/credentials`、`DELETE /api/v1/dav/credentials/{id}` 均限登录用户管理自己的凭据。创建/撤销不会暴露其他成员密码。

## Cloudflare Tunnel（可选）

- 只读取白名单位置已安装的 `cloudflared`，不捆绑、不下载、不自动安装；缺失时引导用户自行 `brew install cloudflared`。
- 隧道子进程由 Mac App/Core 管理。Core 退出隧道一并停止；连接中断有有限退避/最多次数的重启与持久 `tunnel_disconnected` 提醒；不会试图替用户修改 macOS 系统守护服务。
- 快速模式使用 `cloudflared tunnel --url http://127.0.0.1:<port> --no-autoupdate`；分配的 `trycloudflare.com` 地址随机、可能变化，**只适合临时测试**，不是稳定生产域名。
- API Token 模式允许 Mac 本地创建/读取隧道、绑定主机名、更新 Ingress 和受控 DNS CNAME。只删除自己隧道关联的域名记录；遇到指向其他隧道的冲突必须失败，不自动覆盖用户其他 Cloudflare 配置。Token 进入 macOS 钥匙串，不进入日志、公共 API、审计或持久明文配置。
- Mac 私有 IPC `tunnel status`、`tunnel quick on`、`tunnel off` 以及受限高级 API 命令。入口在 Mac 设置而非浏览器的主机命令执行接口。Cloudflare Token 所需权限应按最小授权原则配置，例如 Tunnel 编辑/账户读取和指定 Zone/DNS 访问。
- 代理/TUN 环境、Ingress 多端并发编辑、免费试用条件和用户自有域名 DNS TTL 属外部运行因素，务必单独实际验收。

## 建议验收

1. 局域网 HTTPS 先测试账号登录/登出和成员目录隔离；验证未显式开启远程服务时没有 LAN 监听。
2. Finder `⌘K`/Infuse 挂载 WebDAV，验证读写、撤销密码、成员的越权目录不可见及移动到回收站。
3. 临时 Cloudflare URL 登录、停止后失效、断网恢复和 Clash/TUN 情况；公网只能通过 HTTPS 使用。
4. Token 模式先以无其他重要路由的测试域名验证绑定/撤销/重启，**不可在无人确认时删除现有隧道或 DNS**。
5. 真正对外开放前复核 [SECURITY.md](SECURITY.md) 和 [PRODUCTION_RELEASE.md](PRODUCTION_RELEASE.md)；功能代码存在不代表 SSL、DNS、账户最小权限及公网防护已验收。
