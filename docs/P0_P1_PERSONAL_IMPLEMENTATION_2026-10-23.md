# 个人版 P0/P1 本轮代码交付与未完成项（2026-10-23）

> 本文件是**当前未提交工作区的增量交付记录**。最新产品范围见 [fnOS 个人版排期](FNOS_PARITY_PRIORITIES.md)。本轮未修改 macOS 数据卷、真实用户备份目的地、系统 SMB 设置、Docker 配置或已有 NAS 文件。Swift 编译通过与 Go 自动化通过不等于真机/正式发行验收。

## 本轮已接代码

| 范围 | 代码实现 | 仍需验证/补齐 |
| --- | --- | --- |
| P0-01 文件/卷身份 | 修复 Go Core 内部旧模块路径、重复 import、迁移队列遗漏的 macOS 文件身份函数；支持非特权进程读到的 `st_gen=0`，仍校验卷 UUID、inode、birth time；新增身份测试 | 真正外置双物理盘、断电/满盘/路径被替换的实机测试；**没有开放新的自动删除源目录流程** |
| P0-02 Time Machine 兜底 | Mac 存储页增加只读 `tmutil destinationinfo -X` 与 `tmutil isexcluded` 检测；显示目标数量/名称、LightIsle 元数据与 NAS 共享目录被标记排除与否、异常/不确定；可打开系统设置 | `[Included]` **不是**实际备份成功的证明；需另检查源数据卷在备份中的真实覆盖、最近成功时间、独立目的地与一次元数据真实恢复演练 |
| P0-04 App 常驻 | SwiftUI `MenuBarExtra`、关窗不退出、菜单栏恢复主窗口、明确退出优雅停止 Core；`SMAppService.mainApp` 登录项开关；Core 在线时可选 ProcessInfo 禁止空闲睡眠，离线释放 | 实际 GUI 关窗/⌘Q、强杀、注销、唤醒、FileVault 与不同 macOS 版本；**不保证无人登录时在线** |
| P1-01 macOS SMB | 原有只读 TCP 445/跳转系统设置保留，增加系统 ACL 与轻屿账号隔离说明；Time Machine 目标检查入口 | 真实 SMB 共享用户/访问权限、作为其他 Mac 的 Time Machine 备份目的地的指导与验证 |
| P1-03 Bonjour | 原生 `_lightisle._tcp` 服务广播，绑定 Core 在线与 HTTPS 已开启状态，禁用/退出时停止广播；Mac Info.plist 写入本地网络用途与服务声明 | Flutter 浏览/发现端对接、网络切换与真实多网卡/HTTPS 证书指纹测试；Tailscale/EasyTier 向导尚无 |
| P1-05 原生通知 | 用户开启并授权后使用 UserNotifications 发送 Core 异常、备份操作失败、共享根离线事件；同类事件限频，错误信息不含用户文件名 | 低空间/升级失败/全部持久告警外发、系统通知权限真机到达与后台显示验证 |

## 未完成 / 不可标记为已交付

- **P0-03 多根 + 按根授权**：ADR 已确定，但 API/上传/分享/媒体/备份的全链路 rootID 隔离仍未完成；不能启用仅半实现的多根。
- **P0-02 的生产级兜底**：Time Machine 提示与 SQLite 恢复功能应在真实外置备份盘和本机管理员操作下验证，不提供联合跨资源事务恢复。
- **P1-02 WebDAV**：未实现；实现时必须设计与 Web Cookie 独立、可撤销的凭证和同一套根授权。
- **P1-03 客户端自动发现与私有组网向导**：Bonjour 的 Mac 广播端已接入，但尚不能宣称手机端已自动发现。
- **P1-04 图库/影院规模与兼容**：延用既有功能；尚需真实 10k+ 素材/分页/转封装或 VideoToolbox 实测。
- **P1-05 完整告警覆盖**、**P1-06 Spotlight 授权搜索**、**P1-07 元数据恢复预览与手工重扫**：尚未完成。
- **P0-GATE 正式发布**：Developer ID/公证、真实设备、长时运行、Android LAN HTTPS、断电/恢复证明均未完成。

## 检验记录与边界

- SwiftUI `swift build -c debug --product LightIsle` 通过（菜单栏、Time Machine、Bonjour 和通知功能编译后）。
- Go `go test ./...` 与 `go vet ./...` 通过（修复既有内部 import 和 macOS st_gen 判定后）。
- `go test -race ./...` **通过**（全部 Go Core 包）；以上测试**不代替**真人操作、外置硬盘拔插、Time Machine 备份或管理员登录项授权实测。
- 现有全部用户工作区改动保留；**本轮未执行 git commit / push / tag**。

需要续做时，先以 [个人版最新 P0/P1](FNOS_PARITY_PRIORITIES.md) 和本记录核对当前代码，避免从历史企业级任务中恢复已经取消的联合灾备开发。

## 第二批：排除真机验收的功能代码续做

> 仍处于未提交开发工作区。**本批不能把 P0/P1 全部划为完成**。以下按代码、自动化测试和用户可用范围分别说明。

| 任务 | 已落地代码 | 尚未落地 / 不允许开放的范围 |
| --- | --- | --- |
| **P0-03 共享根身份** | 新增 `core/internal/roots`：持久 `rootID`、卷 UUID/目录 inode+创建时间绑定、重叠及上下级根拒绝、最大 16 根、租约、显式重绑/移除和离线/损坏配置失败封闭；旧 `shared-root.json` 迁移为未绑定根，原生所有者确认前不自动访问；Core 启动加载登记簿 | **没有提供 Web/API v2 多根文件/图库/影视/上传/分享/备份完整路由**。当前继续以单根 v1 安全提供服务；不能声称多根可用 |
| **P0-03 按根授权** | 新增 `root_file_grants(user_id,root_id,path,can_write)` SQLite 表和 `SetRootGrant/RemoveRootGrant/CanAccessRoot/UserCanWriteRoot`；测试证实根 A 不能继承根 B 或旧 `file_grants` 权限、撤权生效、非法路径拒绝 | API v2 各业务 handler 尚未完成逐根租约和 ACL；**新授权表不开放危险 Web 管理入口** |
| **P1-03 私有组网引导** | Mac 网络页面增加 Tailscale、EasyTier 使用说明和证书指纹提醒，不修改本机 VPN/防火墙 | 自动检测 VPN 状态、客户端自动发现与网络变化联调未完成 |
| **P1-05 macOS 低空间通知** | 基于现有卷指标，已接低于 5 GiB 或低于 5% 的可选通知，按卷键节流 | 升级失败、全部后台持久告警的统一转发仍未完成 |
| **P1-06 macOS Spotlight 搜索** | 文件 API `GET /api/v1/files/search?engine=spotlight` 可选调用 macOS `mdfind`，仅对已有 `SearchRoots` 授权子树查询，限制超时和输出体积，返回路径经 `os.Root` 与原授权二次检查；未索引时仍可遍历文件名。Web 端增加内容搜索开关 | 真实系统 Spotlight 索引类型、外置卷和大目录性能尚未实测；**并非所有文本/媒体内容都保证可被索引**，多根授权搜索仍依赖未来 P0-03 路由 |
| **P1-07 恢复后的媒体重建** | Mac “账号与配置回退”加入手动重建图库/影视索引按钮，调用现有 Go Core `index scan`；原始文件不被自动恢复/删除 | 元数据恢复的差异预览、受损关系诊断与交叉卷文件重绑定仍需实现 |
| **P0-02 Time Machine** | 最近可查询的系统备份位置、目标和排除列表加入 Mac 只读诊断 | 系统返回的历史备份不能代替实际备份覆盖证明；仍需真实外置数据盘、目的地和 SQLite 恢复演练 |

**回归记录**：新增 registry、legacy 迁移与按根授权用例通过，`go test ./...` 全部 Go 包通过；Web `npm run build --prefix apps/web`（包含 Vue TypeScript 校验）通过；Mac `swift build -c debug --product LightIsle` 的相关变更也已通过编译。未来正式发布仍需按 [发布门禁](PRODUCTION_RELEASE.md) 验证。尚未运行全部打包 smoke/跨卷规模测试，不得因此宣称完成生产发行。

### 本批后续补充（持久告警与系统原生备份）

- **持久告警转 Mac 通知**：`lightisled` 增加仅 Mac 父进程 stdin IPC 可访问的 `alerts status`，返回最多 100 条告警；Mac 每分钟在 Core 在线时最多轮询一次，解析白名单事件（卷离线、备份失败、图库扫描失败、影院扫描失败等）、确认后不通知、恢复时清理节流键。与直接报告的同类失败共用去重键，**仅使用用户开启且系统授权的本地通知**。不是远程推送服务，不增加 Web 提权入口。低空间已有独立每卷限频通知；升级失败告警仍未覆盖。
- **Time Machine/SMB**：本机只读检查增加 `tmutil latestbackup` 可查询的历史备份位置；Mac 网络页补充系统 SMB 文件共享和把独立目录作为**其他 Mac Time Machine 备份目的地**的两种不同配置引导。两者均不改系统账号/ACL，不把备份历史位置误判成 NAS 外接源卷真实受保护。
- **编译与自动化**：增补后 `swift build -c debug --product LightIsle` 编译成功；Core `go test ./core/cmd/lightisled ./core/internal/tasks ./core/internal/roots ./core/internal/auth` 通过。全量 Go Race/Vet 应以各次完成状态单独记载，不用之前通过的记录代替最新代码验证。

### 第三次补充：关窗后轮询可靠性与多根配置备份

- **关窗不影响告警**：移除 `ContentView` 绑定窗口的 3 秒定时轮询；改在 Mac `AppModel.launch()` 成功启动 Core 进程后创建单实例 `servicePollingTask`，由 App 持有而不依赖主窗口，Core 异常退出和显式 Stop 都会取消；后台菜单栏常驻时继续刷新指标与持久告警，无重复窗口轮询。此改动通过 Swift Debug 编译，仍需真实 GUI 关窗/后台通知到达验收。
- **`shared-roots.json` 随元数据备份**：在现有完整备份元数据白名单、manifest 验证、离线元数据激活和 rollback 内一并处理新根登记簿；旧备份无此文件仍可恢复。新增自动化测试确认恢复阶段保留该文件的字节内容，`go test ./core/internal/backup` 通过。不引入全自动联合灾备，不会自动将恢复的根绑定到未知磁盘。
