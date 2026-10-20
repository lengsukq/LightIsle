# LightIsle 正式生产发布与拒绝条件

**当前状态：未达到正式发布标准。** 现有 `scripts/build-macos.sh` 仅生成本机开发签名的应用，不能将它作为已经签名、公证、真机验证的正式产品交付。

## 已加入仓库的生产安全机制

- 用户访问控制按目录路径授权；拒绝共享树内的符号链接别名，搜索仅访问明确授权的子树，回收站只显示和恢复有权写入的目录；普通用户停用后现有会话立即失效。外部进程并发替换目录仍需要进一步进行系统级竞争条件测试。
- 媒体库目录级读取权限已落地：图库与影视的 SQLite 查询在分页前按目录前缀限定，缩略图、影片流、字幕、进度读写按实际媒体路径独立授权，未授权用户不能按 ID 猜测私人媒体。图库的全局相册结构暂时由管理员管理；收藏元数据写入需要对应目录的写权限，成员独立收藏/相册仍需设计。
- 上传的 `*.part` 内容按块 `fsync`，`*.json` 使用临时文件和原子改名保存**已提交偏移**。异常退出恢复时会删除未提交尾部字节，防止上传内容错位。
- `tasks.sqlite` 保存图库、影视、备份的运行结果、处理数量、错误及重试次数；重启后记录未完成任务为 `interrupted_by_restart`，但**不会**自动执行备份恢复操作。
- 共享目录根路径变更、拔盘或同名目录被替换时，现有磁盘句柄停止接受新操作；管理员确认后可手动重连。
- `lightisle-complete-backup-v2` 使用一致性 SQLite 快照和校验和，包含 `tasks.sqlite`；账号备份不会保存活跃 Web Session，恢复文件先放入隔离目录，不覆盖原始数据。
- Mac 原生「存储」页可使用 Touch ID/系统登录密码验证身份，停止 Core 后交给内置 `lightisle-recovery` 离线校验并激活数据库，旧数据库保存到 `LightIsle-MetadataRollback-*`；恢复中断会写入磁盘日志并阻止 Core 继续启动，用户可由原生错误页选择回滚。**共享文件不会自动覆盖。**
- 同一共享卷内的文件与目录移动使用 macOS 的排他性原子重命名；目录复制先建立独立临时树、校验逐文件内容再原子发布，取消或异常时不发布部分目录。
- Mac 本机「存储 → 跨磁盘安全复制」可以把共享目录内的文件/子目录复制到 Mac 用户显式选择的另一个目录（含其他存储卷），采用目标端临时写入、逐文件 SHA-256 验证、`fsync`、`RENAME_EXCL` 原子提交，不会覆盖已有文件或删除源文件。仅有 Mac 私有 IPC 可以调用，Web/局域网没有跨卷文件路径访问权限。意外断电可能留下隐藏的 `.lightisle-transfer-*` 临时目录，必须由所有者确认安全后清理。
- Mac 原生存储页查询 `diskutil` 只读 SMART 状态，未提供/不支持/超时均显示未知，不以绿色健康提示代替真实设备状态。

## 阻止生产发布的功能缺口

1. **文件可靠性**：同卷和跨卷复制都已有阶段式原子发布与校验；但是跨卷**移动**（包括源文件保留和可回退的清理事务）、可续执行的持久任务队列、断电/拔盘时的空间一致性和超大文件压力/故障注入尚未完成，不能将当前接口称为完全事务化跨磁盘文件管理。
2. **灾难恢复**：Mac 所有者批准的离线数据库激活和中断回滚已有真实代码与自动测试，但缺少**成功恢复之后的一键逆向回滚**、共享文件/元数据联合恢复、旧 SQLite WAL 异常恢复及独立设备上的真实断电演练。
3. **索引/任务**：任务状态已持久化，但尚无断电后复制任务断点续跑、完整历史记录或分配优先级/磁盘 IO 调度。
4. **设备状态**：已有卷使用情况、Core 内存/网络指标和只读 SMART 状态，但外接盘驱动桥兼容性、温度、电源与卷故障报警未完成实机验收。
5. **发布基础**：开发签名不能通过 Gatekeeper 生产签名验收；缺少 Developer ID、公证与 App 实机兼容性测试。

## 离线数据库激活与修复

推荐通过 Mac「存储 → 从备份恢复」恢复并校验，再点击「验证 Mac 所有者身份并离线应用数据库」。应用会停止 Go Core，执行 SQLite 结构/完整性/哈希验证；如本机存在旧版 `-wal` 或 `-shm`，出于数据安全会拒绝激活。旧数据库及设置保存在 `LightIsle-MetadataRollback-*`，不要自行删除。共享文件仍在独立目录，需要人工验证后再选择性移动。

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
```

这不会自动应用在已正常完成的恢复之后进行的逆向回滚，也不会自动合并共享目录文件。操作前必须保留独立原始备份，且旧数据库旁若残留 SQLite WAL/SHM 应先确认并处理，**不要直接删除未知 WAL 文件**。

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

QA 报告必须包含 `reviewer`、`hardware`、最近 30 天的 `date`（ISO 日期）和 `signedOff: true`。每一项 `checks` 的名字在 `scripts/verify-release-qa.py` 中定义，对每项提交真实 `{"pass":true,"evidence":"测试视频/日志/报告路径"}`。未执行的项目**不要**填为通过。

该门禁先运行 Go Vet/Race 与整个本机打包冒烟测试，再为内置 Go Core 和 App 采用 Developer ID + hardened runtime 重新签名，提交 Apple Notary Service，装订 notarization ticket，并通过 Gatekeeper 校验。缺少任何条件都会停止发布。

## 真机验收重点

建议至少在最低支持的 macOS 14 和当前稳定 macOS 版本上分别测试：多用户不同权限访问、特殊文件名、相册/影片关联权限、拔盘后再挂载、5 GiB 续传恢复、10 GiB 一致性备份/恢复、10,000+ 文件索引、72 小时持续运行、睡眠唤醒、关闭最后窗口退出 Go Core、Android 局域网 HTTPS，以及**真实离线恢复加回滚**。

如任一关键功能仍无法复现或没有可重复的验收记录，版本应保持开发状态，不应将“自动化构建成功”表述为“生产上线通过”。
