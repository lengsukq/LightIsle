# LightIsle 路线图

> 最后核对：2026-11-02。这里只写**未完成工作和验收条件**；代码事实见 [STATUS](STATUS.md)，产品范围见 [PRODUCT](PRODUCT.md)，真机证据见 [验收清单](DEVICE_ACCEPTANCE.md)。

## 开发范围

长期产品约束（macOS arm64、仅 v2、每盘独立 100 GiB、仅配置备份、不自研联合灾备）在 [PRODUCT](PRODUCT.md) 和 [ADR 0003](adr/0003-personal-homes-and-quota.md) 统一维护；**此处只列仍需完成的工作**。当前账本仍为 `enforcement=pending`。

## 优先级与完成条件

| 优先级 | 要完成的工作 | 验收标准 |
| --- | --- | --- |
| **P0** | 完善私人目录的**全写入路径计费**，或持续明确禁止未支持的通道 | WebDAV、下载发布、复制/移动/恢复、移动端备份等不得绕过成员每盘额度；并发、离线和崩溃后的预占行为可复测，全部覆盖之前不撤销 `pending` |
| **P0** | 多硬盘身份、目录授权和故障恢复 | 真实双盘拔插、同名换盘、旧代际恢复、不同成员访问及失败回滚不串数据；不静默转写其他盘 |
| **P0** | 文件上传、分享、回收站及 WebDAV 安全收口 | 超额、满盘、中断、符号链接、覆盖和撤销后的原件安全与权限核查均通过 |
| **P1** | Flutter 手机照片/影音与离线使用 | Android WorkManager 真机后台、iOS RAW/Live Photo/HEIC/iCloud、离线原片、AirPlay/PiP/DLNA/字幕等真实设备矩阵留证；音乐不做 |
| **P1** | 家庭日常服务稳定性 | 真实下载/磁力与恢复、Docker 运行时已安装/未安装、通知外发、默认 LAN HTTP / 可选 HTTPS、Cloudflare/FRP 实际连通均有明确失败提示 |
| **发布阻断** | 发版质量门禁 | 72 小时长期运行、外接盘故障与恢复演练、真实 Mac/Android/iOS、Developer ID 签名、公证与 Gatekeeper 证据全部齐备 |

## 完成定义

1. 入口、角色授权、物理根代际、SQLite/文件落盘、取消、错误恢复及自动化回归相互一致。
2. 无法确定身份或容量时安全拒绝，而非自动改盘、删除原件或释放不确定预占；存储配额不得因管理员写入绕过目录所有者。
3. 代码级测试和真实硬件/第三方服务验证**分别记录**。构建成功不代表生产验收通过。
4. 新状态只更新 [STATUS](STATUS.md)，独立设备证据记录在 [验收清单](DEVICE_ACCEPTANCE.md)；长期架构调整写 [ADR](adr/0003-personal-homes-and-quota.md)。

## 远期可选（不作为 Beta 验收任务）

可根据实际家庭使用需求再评估：本地 OCR/照片搜索、完整 Live Photo/RAW 支持、APFS clonefile 加速、可撤销的第三方 API Key、云端异地配置快照、受限 ZIP 解压和 UPS 状态引导。仅作为候选，**没有完成或发布承诺**，不得替代上表的存储安全与真机验收。

## 不在个人版范围

不自研 RAID/ZFS/Btrfs、企业级 HA、逐根文件自动备份、跨盘自动迁移、独立开机常驻服务器、完整脚本沙箱。复用 macOS、APFS、SMB、Time Machine、SQLite 和用户主动安装的可选依赖。
