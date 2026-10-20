# P0 NAS 核心功能实施与验证状态

> 基线：2026-10-20，开发预览。本文只记录仓库中可核对的能力，并区分三种状态：
>
> - **已实现**：源码、入口和用户路径已存在。
> - **自动化覆盖**：仓库中有 Go 单测/集成测或打包后的 Python 冒烟测试；是否通过以实际执行输出为准，不能由文档代替。
> - **人工验收待完成**：GUI、真实外置盘、断电/空间不足、规模/72 小时、Android 真机、签名公证等。未完成项不得标记为通过。
>
> **当前版本不是正式发布包。** 现有 `dist/LightIsle.app` 只是本机临时签名开发包。

## 范围与状态

| 模块 | 已实现 | 自动化覆盖 | 人工验收待完成 |
| --- | --- | --- | --- |
| 账号与会话 | SQLite `accounts.sqlite` + Argon2id；首任管理员只能由 Mac App 私有 IPC 初始化；管理员可在 Mac App 用 Touch ID/登录密码重置首任管理员；Web 只登录，后续账号由管理员创建；停用账号或重置密码会撤销既有会话。**登录会话有效期 30 天，SQLite 到期时间与 HTTP Cookie 使用同一期限** | auth 存储、角色、服务端登录/会话测试；打包后 `test_native_setup.py` | Touch ID 真实弹窗、GUI 重置流程、多管理员真实登录；没有设备配对/设备撤销模型 |
| 成员文件权限 | SQLite `file_grants`，普通成员默认拒绝；管理员按相对共享根目录的路径授予只读/读写并可撤销；文件下载、预览、上传、批量操作、删除均校验。图库/影视按授权目录在分页前过滤，缩略图/视频流/字幕/进度再按真实路径验证；未授权成员看不到全库计数和私人相册 | `file_permissions_test.go`、`media_permissions_test.go`、`production_permissions_test.go` | 多成员、不同目录、真实浏览器/Android 的端到端验收；外部进程并发替换目录的系统级竞争测试 |
| 同共享卷文件操作 | Web 文件名搜索（最多 30,000 项限量遍历）；同卷改名/移动使用 Darwin `RENAME_EXCL` 防覆盖；文件与目录复制先进入私有临时目录，逐文件校验后一次性发布；管理员可清理内部回收站；回收站按原路径恢复且拒绝同名覆盖 | `operations_test.go`、`copy_tree_test.go`、`store_test.go`、`upload_recovery_test.go` | 5 GiB 续传、10,000+ 文件搜索、特殊文件名/Unicode/大小写、磁盘写满、真实浏览器批量操作 |
| 跨卷安全复制 | 仅 Mac App 通过文件选择器发起：把共享目录内的文件或子目录复制到用户显式选择的目标文件夹（可位于另一存储卷）。目标端临时写入、逐文件数据 `fsync` + SHA-256 校验，并同步目标目录，最后 `RENAME_EXCL` 排他发布；不覆盖目标、不删除源文件，可取消，异常时不发布部分目标。Web/局域网没有此入口 | `cross_volume_test.go`；打包后 `test_native_cross_volume.py` 只有在来源与目标确属不同卷时才执行跨卷路径验证；普通 CI/开发机若同卷会显式跳过，因此不能替代真实第二卷验收 | **真实第二块物理磁盘**、空间不足、拔盘、硬断电、异常退出后隐藏 `.lightisle-transfer-*` 临时目录清理；复制任务的断点续跑未实现 |
| 跨卷移动 | **未实现。** 现有移动只在同一共享卷内使用原子重命名；跨文件系统会返回 `EXDEV`，源文件保持不变。不会自动退化为“复制后删除” | 无跨卷移动测试（因为能力不存在） | 需要先设计可恢复的复制+校验+清理事务，再做真实盘故障注入；在此之前不得在 UI/文档中宣称支持跨磁盘移动 |
| 存储与网络 | Mac 原生「存储」页展示系统盘及 `/Volumes` 外接卷的容量、挂载点、文件系统、只读状态；每五分钟只读查询 `diskutil info -plist` 的 SMART；概览展示网口速率、120 次 CPU/内存/流量短期历史和 Go Core PID/常驻内存 | 服务端系统指标测试、Swift 编译与打包检查 | 真实外置盘/桥接芯片的 SMART、温度/卷异常通知、系统级进程列表、网络指标真实采样；无法读取时显示“未知”而非健康 |
| 备份与恢复 | `lightisle-complete-backup-v2` 备份共享普通文件、账号/图库/影视/任务 SQLite 及部分配置；SQLite 用 `VACUUM INTO` 一致性导出；manifest 记录相对路径、大小和 SHA-256；恢复先逐文件重算校验并写入隔离目录。应用数据库通过 **Mac 所有者批准、停止 Go Core 后执行的离线激活**切换；中断激活可用磁盘日志回滚，残留旧 SQLite `-wal`/`-shm` 时拒绝激活 | `backup_test.go`、`verify_test.go`、`metadata_test.go`、`offline_activation_test.go`、`schedule_test.go`；打包后 `test_native_backup.py`、`test_native_recovery_bundle.py` | 10 GiB 级真实备份/恢复、真实断电和空间不足、Mac GUI 文件选择器、多用户 SMB 环境。**缺少成功激活后的一键逆向回滚、共享文件与数据库的联合灾难恢复、备份轮换/加密/增量** |
| 索引与任务 | Mac App 用 FSEvents 监听共享目录，变更防抖 2 秒后通过私有 IPC 触发扫描；Go Core 启动 30 秒后及每 15 分钟对账。`tasks.sqlite` 持久记录图库、影视、备份的开始/进度/完成/错误/重试，重启时将未完成任务标记为 `interrupted_by_restart`；管理员 Web 可取消/重试媒体扫描，Mac App 可取消备份，Web 用户可中止自己的续传上传 | `journal_test.go`、扫描/取消相关测试、打包冒烟测试 | 10,000+ 文件索引、扫描中重启/断电、App 退出后 FSEvents 不工作、完整历史审计与优先级/限流 |
| 图库与缩略图缓存 | 按需扫描照片/视频，SQLite 索引，部分 EXIF 拍摄时间，时间线、收藏、相册；缩略图首次请求由 macOS `sips` 生成并缓存，单图 64 MiB 输入上限、512 px JPEG。**缓存总量可配置：默认 1 GiB，可在 Mac 设置中调整为 256 MiB–8 GiB，并按最近使用淘汰；Web 无权修改本机缓存设置** | `gallery_test.go`、`thumbnail_test.go`（缓存命中、源版本变更、LRU 淘汰、上限校验、转换失败无残留） | 1 万张素材、HEIC/方向/损坏文件、视频封面、Android 浏览器虚拟滚动与真实照片墙性能 |
| 影视 | 按文件名识别电影/剧集和年份/季集；SQLite 索引、筛选/搜索、管理员改名；MP4/WebM HTTP Range 原片直放；同名 SRT/VTT 字幕；每账号独立续播进度；不兼容格式提示下载 | `cinema_test.go`、打包后 `test_cinema_bundle.py` | 海报/刮削、完整编码探测、MKV/MOV 转码、VideoToolbox/HLS、Android 浏览器真实播放矩阵 |

## 安全原则

1. 仅 Mac App 拥有首任管理员初始化、管理员重置、磁盘授权、备份/恢复、离线数据库激活和跨卷复制的控制权；Web API 不提供这些本机特权能力。
2. 普通成员默认无文件权限。目录路径以相对共享根目录格式配置，`.` 表示整个共享目录；已有成员不会自动获得读写权限。
3. 不覆盖已存在的用户文件。永久清理只作用于 LightIsle 内部回收站，并且仅管理员可执行。
4. Web 会话最长 30 天；退出、停用账号、重置管理员密码会立即使相关会话失效。恢复备份不会带回旧登录会话。
5. 备份包含账号密码哈希和其他私人元数据，目标是受信任的加密磁盘；备份文件夹不得被普通用户读取或上传公网。
6. 跨卷**复制**已实现且有自动化覆盖；跨卷**移动**未实现。对外文案不得把“安全复制”写成“跨卷移动”。
7. 离线激活必须由 Mac 所有者验证身份并停止 Go Core 后执行；它只回滚“中断的激活”，不提供成功激活后的一键回退。

## 仍未通过的 P0 完成门槛

- [ ] 跨卷移动的可恢复事务（复制、校验、发布、源清理、取消/重启恢复），以及真实物理盘的空间不足、拔盘、硬断电和临时目录残留清理。
- [ ] 成功离线激活后的自动一键逆向回滚；共享文件与账号/索引数据库的一致性联合恢复；独立设备上的完整灾难恢复演练。
- [ ] SMART/温度/卷故障告警的实机检测与用户通知；真实外置盘桥接兼容性。
- [ ] 真实 Mac App 窗口的启动、关闭最后窗口、⌘Q、强制终止、睡眠唤醒及多用户权限 GUI 测试。
- [ ] Touch ID/登录密码真实弹窗、管理员重置、离线激活和回滚的人工验收。
- [ ] 1 万+ 文件索引、5 GiB 断点续传、10 GiB 备份/恢复、72 小时稳定运行和 Android 浏览器实机 HTTPS 回归。
- [ ] Developer ID 签名、公证、Gatekeeper 校验和干净机器安装。

**范围说明：** Flutter Android 原生客户端（尚未开始）与 Docker/Colima 管理（可选扩展）**不是本版本的发布阻断项**，除非产品明确承诺纳入。Android **浏览器** HTTPS 仍是必需门禁：README、`docs/MACOS_APP.md` 和 Web/PWA 明确承诺“管理员在 Mac 上开启远程后，可用 Android 浏览器访问”，因此 `scripts/verify-release-qa.py` 保留 `android_lan_https` 检查项。只有产品撤回该浏览器访问承诺时，才应同步移除这项门禁；文档不能单方面跳过。

## 验证命令

```bash
go test ./...
go vet ./...
swift build -c debug
npm run build --prefix apps/web
bash scripts/build-macos.sh
python3 tests/test_native_setup.py
python3 tests/test_native_backup.py
python3 tests/test_cinema_bundle.py
python3 tests/test_app_lifecycle.py
python3 tests/test_native_recovery_bundle.py
python3 tests/test_native_cross_volume.py
python3 tests/test_brand_assets.py
```

`scripts/build-macos.sh` 会运行 Go 测试、Swift 构建、Web 构建和上述打包冒烟测试。这些命令验证基础逻辑、进程生命周期和打包资源，**不覆盖**完整 GUI、真实外置盘、断电恢复、规模测试或公证。
