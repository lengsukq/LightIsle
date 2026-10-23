# LightIsle 正式生产发布与拒绝条件

**当前状态：未达到正式发布标准。** 现有 `scripts/build-macos.sh` 仅生成本机开发签名的应用，不能将它作为已经签名、公证、真机验证的正式产品交付。本文的“已加入”只表示代码与自动化测试在仓库中存在；真实磁盘、GUI、规模/72 小时、Android 实机、Touch ID、公证和 Gatekeeper 验收仍须人工完成并留存证据。

> **2026-10-23 最新个人版范围裁剪：** [fnOS 个人版规划](FNOS_PARITY_PRIORITIES.md) 已决定复用 macOS/Time Machine/SQLite，**不建设企业级文件+数据库联合事务恢复、目录跨卷事务引擎或自研增量备份系统**。下方保留原有工程缺口事实，但这些未开发的高级功能**不再自动成为个人版发行阻断项**。必须做的仍是安全文件操作、独立备份覆盖说明、可验证的 SQLite 元数据恢复、权限与跨卷真实故障测试及签名公证。**本次只有文档变更；现有 verify-release-qa.py 的 5 GiB/10 GiB/72 小时等强制检查未调整，严禁填假结果跳过**。

## 已加入仓库的生产安全机制

- 用户访问控制按目录路径授权；拒绝共享树内的符号链接别名，搜索仅访问明确授权的子树，回收站只显示和恢复有权写入的目录；普通用户停用后现有会话立即失效。外部进程并发替换目录仍需要进一步进行系统级竞争条件测试。
- 媒体库目录级读取权限已落地：图库与影视的 SQLite 查询在分页前按目录前缀限定，缩略图、影片流、字幕、进度读写按实际媒体路径独立授权，未授权用户不能按 ID 猜测私人媒体。图库的全局相册结构暂时由管理员管理；收藏元数据写入需要对应目录的写权限，成员独立收藏/相册仍需设计。
- Web 登录会话采用 30 天期限；SQLite 的 `expires_at` 与 HTTP Cookie 的 `MaxAge` 由同一策略驱动，避免两处期限漂移。停用账号、重置首任管理员密码和主动退出都会使相关会话失效。
- 上传的 `*.part` 内容按块 `F_FULLFSYNC`，`*.json` 使用临时文件和原子改名保存**已提交偏移**。异常退出恢复时会删除未提交尾部字节，防止上传内容错位。
- `tasks.sqlite` 保存图库、影视、备份的运行结果、处理数量、错误及重试次数；重启后记录未完成任务为 `interrupted_by_restart`，但**不会**自动执行备份恢复操作。
- 共享目录根路径变更、拔盘或同名目录被替换时，现有磁盘句柄停止接受新操作；管理员确认后可手动重连。
- `lightisle-complete-backup-v2` 使用一致性 SQLite 快照和校验和，包含 `tasks.sqlite`；账号备份不会保存活跃 Web Session，恢复文件先放入隔离目录，不覆盖原始数据。
- Mac 原生「存储」页可使用 Touch ID/系统登录密码验证身份，停止 Core 后交给内置 `lightisle-recovery` 离线校验并激活数据库，旧数据库保存到 `LightIsle-MetadataRollback-*`；恢复中断会写入磁盘日志并阻止 Core 继续启动，用户可由原生错误页选择回滚。**共享文件不会自动覆盖。**
- 同一共享卷内的文件与目录移动使用 macOS 的排他性原子重命名；目录复制先建立独立临时树、校验逐文件内容再原子发布，取消或异常时不发布部分目录。
- Mac 本机「存储 → 跨磁盘安全复制」可以把共享目录内的文件/子目录复制到 Mac 用户显式选择的另一个目录（含其他存储卷），采用目标端临时写入、逐文件数据 `fsync` 与目录项 `fsync`、SHA-256 验证及 `RENAME_EXCL` 原子提交，不会覆盖已有文件或删除源文件。仅有 Mac 私有 IPC 可以调用，Web/局域网没有跨卷文件路径访问权限。意外断电可能留下隐藏的 `.lightisle-transfer-*` 临时目录，必须由所有者确认安全后清理。
- 图库缩略图缓存有总量上限，默认 1 GiB、可在 Mac 设置中调整为 256 MiB–8 GiB，并按最近使用淘汰；Web 无权修改该本机设置。缓存可删除重建，不修改原始媒体。
- Mac 原生存储页查询 `diskutil` 只读 SMART 状态，未提供/不支持/超时均显示未知，不以绿色健康提示代替真实设备状态。

## 现有缺口与个人版发布边界

1. **文件可靠性（必须验收已提供的操作）**：同卷复制/移动和跨卷复制已有阶段式原子发布与校验；Mac 私有控制面已有**单文件**日志化安全移动（源文件仅进入可恢复回收站）。目录级跨卷事务移动与通用持久队列不在个人版范围，**不得把尚未实现的事务能力宣传为已提供**；已提供的复制/上传/单文件移动仍须在满盘、拔盘、数据变化和超大文件场景实测，失败不得覆盖目标或永久删源。
2. **轻量恢复（必须验收已提供的操作）**：Mac 所有者批准的离线数据库激活、旧数据库保留、**中断回滚**及**成功后的单独元数据回退**已有代码与自动测试；仍须在真实设备演练、保留旧副本、校验不可再生数据（账号、授权、私人相册）及异常 WAL/数据库切换场景。**共享文件与元数据的跨资源联合自动恢复不再计划自研，也不是个人版功能门禁**。通过 macOS Time Machine/独立备份盘保护文件；恢复来源可能不同步，明确提示并允许重扫派生索引。
3. **索引/任务（按实际承诺范围验收）**：任务状态已持久化，部分扫描/传输能力仍缺更好的检查点和诊断；个人版不开发企业级持久 IO 调度器。对已开放的长任务应确保失败可见、原件安全、可手动重试或恢复，不把所有队列的重启断点续跑当作强制交付。
4. **设备状态**：已有卷使用情况、Core 内存/网络指标和只读 SMART 状态，但外接盘驱动桥兼容性、温度、电源与卷故障报警未完成实机验收。
5. **发布基础**：开发签名不能通过 Gatekeeper 生产签名验收；缺少 Developer ID、公证与 App 实机兼容性测试。

**本版本不作为阻断项的能力：** Flutter Android 原生客户端（未创建）和 Docker/Colima 管理（可选扩展）。除非产品明确把它们纳入本版本。Android **浏览器** HTTPS 是否必需，取决于产品是否保留 README/MACOS_APP 中的浏览器访问承诺；当前承诺存在，因此该检查项保留，不能因未开发原生 App 而跳过。

## 离线数据库激活与修复

推荐通过 Mac「存储 → 从备份恢复」恢复并校验，再点击「验证 Mac 所有者身份并离线应用数据库」。应用会停止 Go Core，执行 SQLite 结构/完整性/哈希验证；如本机存在旧版 `-wal` 或 `-shm`，出于数据安全会拒绝激活。旧数据库及设置保存在 `LightIsle-MetadataRollback-*`，不要自行删除。共享文件仍在独立目录，需要人工验证后再选择性移动。

**这是“所有者批准的离线激活”，不是自动灾难恢复：**

- 激活成功后，原生 Mac 已有受本机所有者认证保护的元数据回退入口，辅助程序也支持先 `list` 再显式 `rollback --transaction-id`；但它**仅回退元数据**，不会自动逆向还原共享文件，尚缺真实设备的完整演练。
- 内置 `recover` 只处理“上次激活被中断、Core 拒绝启动”的情况；成功激活后的元数据回退由独立 `rollback` 操作负责。
- 共享文件与数据库不会联合切换，必须人工核对版本和目录内容。

紧急情况下可在**完全退出 LightIsle.app 后**使用内置辅助程序（文件路径中的 `LightIsle.app` 根据实际安装位置调整），所有路径均必须指向本机用户的私有 Application Support 目录：

```bash
RECOVERY='/Applications/LightIsle.app/Contents/Resources/core/lightisle-recovery'
STAGE='LightIsle-RestoredMetadata-<实际生成的名称>'
"$RECOVERY" --operation verify --stage "$STAGE"
# 核实正确后才执行，会替换现用账号/索引/设置数据库：
"$RECOVERY" --operation activate --stage "$STAGE" \
  --confirm I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT
# 仅在上次离线激活中断、Core 拒绝启动时使用：
"$RECOVERY" --operation recover \
  --confirm RESTORE_PREVIOUS_METADATA
# 成功激活后的元数据版本回退是独立操作；先列出可回退的事务，再按实际 ID 审核：
"$RECOVERY" --operation list
# 以下是单独的元数据回退（不会逆向移动共享文件）；必须先确保 App 已停止：
"$RECOVERY" --operation rollback --transaction-id '<来自 list 的事务 ID>' \
  --confirm ROLLBACK_OFFLINE_METADATA
```

`rollback` 只回退符合条件的元数据激活版本，**不会自动合并或回退共享目录文件**。操作前必须保留独立原始备份，且旧数据库旁若残留 SQLite WAL/SHM 应先确认并处理，**不要直接删除未知 WAL 文件**。

## 两类构建，不能混用

```bash
# 仅供本机开发/测试：
bash scripts/build-macos.sh

# 生产候选构建：会拒绝未签名/未公证/未验收的版本。
export LIGHTISLE_DEVELOPER_ID='Developer ID Application: <您的公司或个人> (<TeamID>)'
export LIGHTISLE_NOTARY_PROFILE='<notarytool 已登记的钥匙串配置名称>'
export LIGHTISLE_QA_REPORT='/absolute/path/to/qa-results.json'
bash scripts/release-macos.sh
```

必须先有具备 Apple Developer ID 的 Apple 开发者账号，并用 `xcrun notarytool store-credentials` 在本机钥匙串保存凭据。不要把证书、密码、API Key 或 QA 测试证据提交到 Git。

QA 报告必须包含 `reviewer`、测试 Mac 型号与 macOS 版本（`hardware.model` / `hardware.os`，或等价描述）、最近 30 天的 `date`（ISO 日期）和 `signedOff: true`。每一项 `checks` 的名字在 `scripts/verify-release-qa.py` 中定义，对每项提交真实 `{"pass":true,"evidence":"测试视频/日志/报告路径"}`；附件路径相对 QA JSON 所在目录解析，也可使用绝对路径，且必须指向可读、非空的普通文件。未执行的项目**不要**填为通过。自动化测试和 CI 通过**不能**替代这些人工证据；JSON 的自述和附件内容仍需发布负责人独立复核。

该门禁先运行 Go Vet/Race 与整个本机打包冒烟测试，再为内置 Go Core 和 App 采用 Developer ID + hardened runtime 重新签名，提交 Apple Notary Service，装订 notarization ticket，并通过 Gatekeeper 校验。最终分发物是装订后重新生成的 `dist/LightIsle.zip`；脚本将其解压，再次检查 App、Core、Recovery 仅为 arm64、签名与票据。提交 Apple 的临时 `LightIsle-notary-submit.zip` 会清理，不作为分发物。缺少任何条件都会停止发布。实际签名/公证仍需真实凭据与验收，脚本静态回归不等于公证完成。

## 真机验收重点

建议至少在最低支持的 macOS 14 和当前稳定 macOS 版本上分别测试：多用户不同权限访问、特殊文件名、相册/影片关联权限、拔盘后再挂载、5 GiB 续传恢复、10 GiB 一致性备份/恢复、10,000+ 文件索引、72 小时持续运行、睡眠唤醒、**关闭最后窗口仍运行并能从菜单栏恢复；明确退出才停 Go Core**、Android 局域网 HTTPS，以及**真实离线恢复加回滚**。同时检查 Time Machine 目标/源卷排除诊断、用户登录项、防空闲休眠、Bonjour 广播/撤销和本机通知的授权与实际到达。现有 QA JSON 检查项名称不变，但应按此处的最新行为采集证据。

**以下仍未完成人工验收，不得在发布说明中标记通过：** 真实外置盘/第二块物理盘的已提供跨卷复制及空间不足/拔盘/断电保护、已提供的单文件日志化移动（缺实机验证）、成功离线激活后的元数据回退、独立 Time Machine 备份目标和原始 NAS 数据卷覆盖核查、1 万文件/5 GiB/10 GiB/72 小时规模、真实 GUI 生命周期、Touch ID 弹窗、Android 实机 HTTPS、Developer ID 签名/公证/Gatekeeper。**目录级事务化移动与自动联合灾备不再作为计划中的个人版验收功能**，不可对外宣称已支持。

如任一关键功能仍无法复现或没有可重复的验收记录，版本应保持开发状态，不应将“自动化构建成功”表述为“生产上线通过”。

**平台与范围：** 后端固定为 macOS arm64/Apple Silicon，本版本只在 Apple Silicon macOS 上构建与验收。Android/iOS 原生客户端不在当前计划；Docker/Colima 管理为后续可选扩展。

**Android 浏览器 HTTPS 是必需门禁。** README 和 [macOS App 生命周期](MACOS_APP.md) 承诺：管理员在 Mac 上开启远程访问后，可用 Android 浏览器登录并完成主要 NAS 操作。因此 `scripts/verify-release-qa.py` 中的 `android_lan_https` 必须保留，直到产品正式撤回该承诺；不能因为“没有原生 App”而跳过浏览器验收。
