# LightIsle 当前功能状态

> **代码核对：2026-11-10，Beta 开发预览。** 本页描述仓库中现行代码实现与尚未验收的边界。
>
> **Mac mini 常驻稳定性实机验收（用户反馈登记：2026-11-05）**：用户已在实际部署 LightIsle 的 **Mac mini** 上连续运行 **7 天（168 小时）**，确认期间**无异常、无自动退出，服务正常**。本项为**已完成的用户实机验证**；仓库未附第三方复核日志或精确起止时间，正式发布门禁证据仍须单独核实；图库、备份、磁盘异常、性能等其他实机项目不得由此推定通过。详见 [真实设备验收记录](DEVICE_ACCEPTANCE.md)。
>
> **最新本地自动化记录（2026-11-10，Beta 预发布 UX-001～UX-017 完善与 Clean Code 收口后）**：
> - **Flutter**：`flutter test --no-pub` **全量通过（589 项通过、1 项按原配置跳过）**；`flutter analyze --no-pub` **0 警告/0 错误**。
> - **Web**：`node --test` **207 项全部通过**（含 `useConfirmDialog.test.ts` 与多根组件 `v-show` 保活隔离校验）；TypeScript 检查与 Vite 生产构建通过。
> - **Go Core**：`go vet ./core/...` 与 `go test ./core/...` 全量 29 个包通过（含 `create-user` 部分成功恢复、换盘 `totalFiles`/`totalBytes` 进度及两阶段免二次输密 `confirmationToken` 竞态回归）。
> - **macOS Swift**：`swift build -c debug` 与 `SpaceInputValidationCheck` 等原生校验器测试通过。
> - **全仓 Clean Code 行数红线**：`core/`、`apps/macos/Sources/`、`apps/flutter/lib/`、`apps/web/src/` 全部生产源码文件均 **≤ 797 行**（严格低于 800 行上限）。
> - **文档中心**：`python3 -B scripts/check-docs.py` 检查通过，所有内部链接与锚点严格闭环。

> **前一轮换盘及上传回归**：换盘三种方式、旧盘授权隔离、失败后重新核验回收和上传创建重试的 Go 定向竞态测试通过；Flutter 相关 36 项、Web 199 项及 Mac 管理端构建通过。全量 Go 检查中的系统磁盘识别和本机监听类测试受当前执行环境限制；双物理盘和手机实机门禁仍待补齐。

## 现行代码实现进展

### 家庭 Beta 的存储与脚本收口

本轮 Go 全量、换盘与脚本等定向竞态检查、Flutter 静态分析及 586 项测试（1 项按原配置跳过）、Web 199 项及生产构建、Swift 构建和临时应用包冒烟通过。本机 5 GiB 实传、重启续传和 SHA-256 校验见 [设备验收记录](DEVICE_ACCEPTANCE.md#完整家庭-beta)。

- 换盘任务在目标只发布了部分目录时，可用原任务重新核验两盘和暂存/已发布目录，再继续提交。遇到目标内容变动保留源文件、已写入目标和预占。已匹配源/目标身份及内容的个人收藏、私人相册和观看进度随文件关联，任务提供受影响的公开链接与共享相册清单。
- Core 的脚本目录或执行历史不可用时，文件和媒体服务仍可启动。Mac 管理端可打开实际脚本目录，Web/Flutter 显示下次执行、上次结果及各渠道发送状态。启动时记录执行，重启时标记未完成记录，重叠或并发额度耗尽的调度保留跳过原因。设置保存按任务版本防止旧编辑覆盖本地配置。
- SMB 新增与启用共享时，Core 拦截覆盖成员私人目录的访客访问。涉及私人目录的新增和启用须经 Mac 管理端确认，实际系统 ACL 和旧共享点换盘仍待实盘验证。
- Mac 管理端的 Time Machine 检查按已登记存储根展示排除状态，并独立检查脚本目录。离线根显示待核实，是否已有可恢复的独立备份仍由实际恢复确认。

### 1. Flutter 四主栏导航、仪表盘工作台与体验对齐
- **主导航收敛为四栏与视图保持**：Flutter 底部/侧栏主导航固定为「仪表盘、相册、影视、设置」四项，切页保留已挂载视图与滚动状态；「文件管理」移入仪表盘顶部快捷工作台首卡与页头主按钮，在仪表盘内嵌打开并带有返回条，同时保留存储卷卡片、图库/影视及设置的二级文件入口。
- **仪表盘（Dashboard）重构**：合并轻屿服务内存指标至 Mac 状态区、去重已关联物理卷的 NAS 目录列表，并在存在离线根目录或异常任务时置顶提示横幅；统一修复任务历史与任务行的 `processed ?? progress` 进度字段读取，规范化回收站、上传、刮削任务名称。
- **相册体验对齐 Google Photos**：时间线顶部新增「回忆与精选（那年今日 / 星标精选 / 家庭佳作 / 动态影像 / 足迹地图）」横向漫游卡；「足迹地图（照片地图回溯）」升级为带封面缩略图预览框与数量角标的地图图钉、单击图钉即出位置照片缩略图网格抽屉（支持「上一处 / 下一处」足迹漫游、「放大此区域」及在地图上直接进入全屏查看器浏览并返回原位置，消除连点只放大不弹窗问题），并限制缩放范围（`minZoom: 2.5`、`maxZoom: 18`）与单世界边界（防止无限放大白屏或缩小时重复多个世界地图）；支持「紧凑网格 / 舒适视图」密度切换、每个月份标题右侧一键全选/取消全选当月照片；EXIF 筛选面板支持按相机型号、是否含 GPS 及自定义起止拍摄日期范围多维筛选；相册总览整合文件夹相册、智能合集与私人/共享相册；文件夹相册（真实目录）支持多选照片一键复制/移动；服务端支持接收方主动退出共享（`DELETE /api/v2/photos/folder-albums/{name}/shares/{memberID}` 支持 `me`），Web 与 Flutter 均提供「退出共享」按钮。
- **影视体验对齐 Netflix**：顶部收敛为单行 Netflix 风格分类胶囊（首页、电影、剧集、继续观看、观看历史、待匹配），并在「待匹配」视图直接展示管理员 TMDB 增量刮削控制栏；首页提供全宽响应式巨幕 Billboard（桌面与手机通用，复用海报内存缓存）、`#E50914` 红色观看进度条、「TOP 10 高分口碑精选」大号描边序号海报栏及海报悬浮/点按微缩放动效；影片详情页与剧集详情页统一使用 `IsleAppBar` 避让 macOS 交通灯，剧集页支持按季筛选，影片详情页内嵌管理员元数据匹配面板（无需先播放视频即可导入本地 NFO、免凭据搜索豆瓣或在线搜索 TMDB 匹配）。
- **文件与自动化完善**：只读共享目录允许「复制 / 批量复制到」有写权限的目标目录，文件列表与回收站均支持下拉刷新，清除搜索自动恢复搜索前所在目录，重命名默认选中扩展名前的主文件名，目标目录选择器支持一键定位到来源目录及就地新建子文件夹；Flutter 设置页新增管理员「本机脚本自动化」面板（完整保留本地脚本 `notification.email` 邮件模板配置，支持查看 30 次运行日志、启停与 Cron 编辑），账号、WebDAV 与目录授权页统一使用 `userFacingError` 中文错误转换。
- **全端返回层级与媒体顺手度优化（2026-11-09）**：`ClientShell`、`PhotosPage`、`CinemaPage` 接入 `PopScope` 系统返回拦截（优先退出多选/搜索/筛选或从内嵌文件页与非首页标签返回仪表盘）；相册支持在相册视图内批量「移出相册」、批量「取消收藏」、点击相册胶囊 `×` 一键返回全部照片，全屏查看器删除/移动单张照片后连续浏览下一张并实时回写详情变更；影视海报与巨幕提供独立「详情与简介」入口直达 `CinemaFilmOverview`（含豆瓣/TMDB/NFO 匹配），退出播放自动刷新继续观看横栏与历史记录；播放器视图拆分为 `cinema_detail_player_view.dart`、`cinema_detail_player_controls.dart` 与 `cinema_detail_player_sheets.dart`；「关于轻屿（`AboutPage`）」升级为网页级滚动叙事（Scrollytelling）与 60fps 连续放映画布（含章节锚点导航、一键自动巡礼及五幕自绘动态演示舞台，拆分为 `about_page.dart`、`about_hero_and_footer.dart`、`about_showcase_sections.dart`、`about_showcase_widgets.dart` 与 `about_showcase_painters.dart`），保持全部生产源码 ≤ 800 行。
- **多服务器/多账号登录历史、一键切换与访问延迟展示（2026-11-09）**：新增 `LoginHistoryStore`（`apps/flutter/lib/core/login_history_store.dart`），通过 iOS/macOS 独立 Keychain 服务（`.login-history`，关闭 iCloud 同步）与 Android 独立 Keystore AES-256-GCM 密文存储（`lightisle_login_history_aes_v1`），按规范化「`服务器 Origin + 小写账号名`」唯一键自动保存登录凭据与证书指纹（上限 12 条，退出当前会话不清除历史，修改密码成功后同步更新）；`LoginPage` 新增「历史登录账号」列表（支持点按回填、一键直接登录、单条删除与全部清空）和服务器地址栏下方的 `CurrentServerLatencyBar`；`SettingsPage` 顶部身份卡新增「切换账号」入口与 `showAccountSwitcherDialog`（`account_switcher_dialog.dart`），支持在已登录状态下对比各服务器/域名延迟并一键切换账号；内置 `probeServerLatency` 对去重后的 `server + 证书指纹` 并发探测 `/api/v2/auth/status` HTTP RTT（连接预热 + Keep-Alive 计时），展示 `🟢 <80ms`、`🟡 80–250ms`、`🔴 >250ms`、`离线 / 超时` 及 `HTTPS 证书需核对` 状态徽章。
- **macOS 系统文件共享（SMB）三端接管**：接管 macOS 原生文件共享（`com.apple.smbd` + `/usr/sbin/sharing`），开启后局域网内 Finder「网络」、Windows「网络」、iOS「文件」及 Infuse/VLC 自动通过系统原生 `_smb._tcp` Bonjour 与 NetBIOS 发现 Mac；支持在 **Mac 原生端**（`网络与连接 → Mac 文件共享`）、**Web 管理端**（`管理设置 → 文件与连接`）和 **Flutter 客户端**（`设置 → 管理员控制台 → Mac 文件共享 (SMB)`）三端统一查看与管理 SMB 服务开关、局域网搜索名、连接地址及 NAS 共享点（新增、只读/访客/启用/编辑属性、取消登记）；Mac 端提供一键写入/撤销受 `visudo -cf` 校验的 `/etc/sudoers.d/lightisle-smb` 免密白名单，使三端无需重复弹窗即可控制 SMB；将原每 3 秒探测 `127.0.0.1:445`（会意外唤醒 `launchd` 下的 `smbd`）改为非唤醒式 `launchctl print system/com.apple.smbd` 检查；严格拦截 `.lightisle-*`、`.Trash`、符号链接与裸系统卷根，当共享整块 NAS 根目录或 `Users` 目录时在三端显式标记 `exposesPersonalDirs` 风险提醒。
- **macOS 服务跨重启状态保持、工作台交互与 Liquid Glass / iOS 质感升级（2026-11-09）**：新增 `ServicePersistencePolicy.swift`（`FRPPersistencePolicy` 与 `TunnelPersistencePolicy`）及回归测试 `tests/ServicePersistencePolicyCheck.swift`，使 **FRP 穿透**与 **Cloudflare Tunnel（免费快速隧道 / 命名隧道 / 手动 Token 隧道）** 与局域网访问一致记住用户的启停选择并在 App/Core 重启后单次自动恢复（若配置或远端鉴权失败则停止循环并明确提示）；同步持久化侧边栏展开态与宽度、Docker 上下文（Docker Desktop / Colima）与镜像加速偏好，修复设置页缩略图缓存上限初始显示未同步及 `forgetTunnelAPIToken` 误清天地图状态的串扰问题，并在 `handleCoreReady` 时主动同步 SMB 状态。视觉与交互层升级 `LiquidComponents.swift`、`DetailPreview.swift` 与 `ContentView*.swift`：移除收起侧边栏下方被挤压成两行的「正在运行」小方框，合并至顶栏右上角单行毛玻璃状态胶囊（`● 正在运行 · :16666 ⌄`，点击弹出本机/局域网地址一键复制与刷新面板）；统一一二级页面顶栏层级（二级页面顶栏直接融合 `< 父级` 返回按钮、分类图标徽章与子页标题，消除双标题栏堆叠，点击左侧导航自动回到对应主入口）；重构「网络与连接」顶部双栏快捷工作台（本机回环 + 局域网实时开关与一键复制）、「存储」顶部默认卷容量进度条与访达直达按钮、「个人空间」顶部一跳打开 Web 磁贴、「存储 → 磁盘设备」扁平化列表（消除嵌套二级钻取与双返回按钮）；为 `IsleDestinationRow` 补齐防截断双层排版与实时状态胶囊（`IsleStatusPill`），统一 `RootManagementView`、`DockerManagementView` 及设置页按钮规范。
- **Flutter 统一样式令牌中心、内置 Liquid Glass 组件库与第一视觉体验升级（2026-11-09）**：扩展 `scripts/sync-flutter-tokens.py` 导出圆角、间距、动效与流光阴影令牌，新建全端唯一样式令牌中心 `apps/flutter/lib/core/isle_style.dart`（统一管理 `IsleRadius`、`IsleShapes` iOS 连续曲率超椭圆 `ContinuousRectangleBorder`、`IsleSpace`、`IsleMotion`、`IsleGlass`、`IsleShadows`、`IsleLayout`、`IslePalette` 与 `IsleDecorations`）以及内置组件库 `isle_ui.dart` / `isle_controls.dart`（抽离 `IsleGlassSurface`、`IslePillButton`、`IsleCapsuleChip`、`IsleSearchBar`、`IsleSelectionBar`、`IsleLoadingState`、`IslePressable` 等标准组件）。升级启动幕布（`StartupCurtain` 双源呼吸光晕 + 连续曲率流光徽章底座 + 磨砂胶囊流光进度条）、会话重连页（`_SessionReconnectPage` 液态玻璃浮层）、登录页（`LoginFlowBackground` 4 源极光丝带画布 + `LoginPage` 液态玻璃表单面板、特性胶囊与 3 步引导卡 + 局域网发现加载器）以及首页仪表盘（`IsleDeviceHero` 连续曲率渐变徽标、`DashboardQuickLinks` 4 色玻璃折射入口卡与级联入场、`IsleBentoStatCard` 4 色活力进度条），统一将概览、相册、影院的初始加载态替换为 `IsleLoadingState`；重构 `IsleFluidTabSwitcher`（两段式无残影曲线 `tabExitInterval` + `tabEnterInterval` + `ClipRect` + 中途打断衔接）、新增 `IsleAnimatedExpand` 与 `IsleModeSwitcher`，彻底消除切页生硬与文字重叠。
- **三端协同多级缓存架构与可视化缓存管理（2026-11-09）**：构建「L0 视图状态保持 + L1 内存 LRU/SWR + L2 本机磁盘持久化 + L3 服务端派生缓存与 ETag 协商」四级缓存体系。**Flutter 端**修复 `IsleFluidTabSwitcher` 因激活/非激活分支顶层 Widget 类型不同导致切页卸载销毁子页面 `State` 的问题，并在 `ClientShell` 内嵌文件工作台与仪表盘之间复用保活树；新增 `IsleCacheManager`（`isle_cache_manager.dart`）与 `IsleDataCache`（`isle_data_cache.dart`）统一管理「相册与文件缩略图、影视海报与剧照、足迹地图与瓦片、页面列表与元数据快照」四类 L1+L2 缓存，`AuthenticatedMediaImage` 支持同步命中 L1 零闪烁渲染并接入照片网格与海报墙，`NasMapTileClient` 与 `CachedPublicMapTileClient` 接入本机地图瓦片缓存。**Web 端**移除 `AppShell.html` 顶层 `:key="active"` 强制销毁，对已访问的主页面与相册子视图（时间线/相册/足迹地图）采用 `v-show` 保活，切回文件页保留当前目录与已加载列表，新增 `useIsleCache.ts` 统一统计与管理四类本地缓存。**Go Core 服务端**为缩略图与海报统一输出基于 SHA-256 缓存键的 `ETag` 并以源文件修改时间响应 `304 Not Modified`（`serveCachedJPEG`），为天地图瓦片代理新增 L1 内存 + L2 磁盘 LRU 缓存（`core/internal/maptiles/cache.go`）及 `ETag` 协商，放行 CSP `img-src https:` 外部底图瓦片，并提供 `GET /api/v2/cache/status` 与管理员 `POST /api/v2/admin/cache/clear` 接口。**缓存管理页**：Flutter（`设置 → 文件与连接 → 缓存与本地存储管理`，`CacheManagementPage`）与 Web（`设置 → 缓存管理`，`CacheManagementPanel.vue`）均提供分类进度条、逐项字节与条目统计、按类别勾选清理、一键清空本机临时缓存、离线原件安全隔离入口及 NAS 服务端派生缓存统计与清理（绝不触碰用户原始照片、视频或文件）。
- **对标成熟个人 NAS 细节完善与原画直传本地解码（2026-11-10）**：
  - **影视原画直传本地解码与无 FFmpeg 自动回退**：`GET /api/v2/cinema/{id}/stream?direct=1` 支持任意已授权影片文件的 HTTP Range 字节流直传（`.mkv`、`.mov`、`.mp4`、`.avi`、`.ts` 等）；当服务端未安装 FFmpeg（`/hls/session` 返回 `transcode_unavailable`）时，Flutter 客户端与 Web 端自动回退至原画直传本地解码，不再阻断播放；即便已安装 FFmpeg，用户也可在设置页（「影视播放与本地解码」）或播放器画质菜单（「本地硬解」）主动开启「优先本地解码（原画直传）」，并支持字幕时间轴微调（`±0.5s`）与一键生成 6 小时受限直链唤起 IINA / Infuse / VLC 外部播放器。
  - **外挂字幕多后缀与 `.ass`/`.ssa` 转换**：`FindSubtitle` 支持匹配 `.zh`、`.chs`、`.sc`、`.cht`、`.tc`、`.en`、`.eng` 等常见字幕后缀及 `.vtt`、`.srt`、`.ass`、`.ssa` 格式，服务端自动解码 UTF-8 BOM / UTF-16LE / UTF-16BE 并将 ASS/SSA 对话行剥离特效标签后转换为标准 WebVTT。
  - **安装即用与 macOS 原生文件/磁盘体验**：`aria2bin.Locate()` 与 `downloads.Manager` 支持免重启热探测后装的 `aria2c`；同卷文件复制优先调用 macOS `unix.Clonefileat`（`CLONE_NOFOLLOW`）实现 APFS 写时复制（CoW）秒级克隆并回退至 `copyVerified`；Mac 端首次引导提供一键选用访达可见的 `~/LightIsle` 目录，并在概览与网络页提供局域网连接二维码弹窗；Docker 运行中且映射了 TCP 端口的容器提供一键「打开网页」入口。
  - **文件搜索、公开分享预览页与个人子目录复制入账**：文件搜索支持按类型（图片、视频、音频、文档、压缩包、文件夹）过滤及从搜索结果「打开所在目录」；公开分享单文件上限提升至 `32 GiB`，新增 `?view=1` 轻量预览落地页与 `?inline=1` 预览流；私人目录支持将子文件夹递归复制并逐文件预占/入账（保留分类根目录自身复制的边界保护）；手机照片前台备份新增可选「按拍摄年月分目录（`YYYY/MM`）」开关，照片详情新增「在足迹地图中查看」一键跳转定位。

### 2. 个人空间、配额账本与文件生命周期受控清理
- **全员个人空间与配额管理闭环（macOS 原生端 + Flutter 管理端 + Web 只读化，2026-11-10）**：
  - **数据存放分层**：账号与系统基础配置（`accounts.sqlite`、`shared-roots.json` 等）保留在 Mac 系统盘（`~/Library/Application Support/LightIsle`）；所有成员及管理员的个人分类数据（`Users/u<ID>/<files|photos|videos>`）与相册缩略图缓存（`<rootPath>/.lightisle-appdata/thumbnails-generation-<gen>`）均存放在所选存储硬盘（支持外置硬盘）内。
  - **管理员默认无限配额與自身目录绑定**：`StoragePolicy` 显式输出 `role` 与 `unlimited: true`（管理员账号默认无限配额，仅受所选物理磁盘实际剩余空间限制）；管理员可在 macOS 原生端与 Flutter 端为自己和所有成员分配存储硬盘、绑定分类目录与新建子目录。
  - **个人空间换盘任务**：Mac 与 Flutter 提供复制并核验后删除、直接剪切、启用空白新目录。Core 持久化任务进度和提交标记，预占目标额度并校验发布对象；旧源只移入精确标记的回收站。受影响的旧分享需由所有者重新授权。双物理盘和断电故障仍需实机验证。
  - **macOS 原生「个人空间」管理中心与统一数据迁移入口**：新增 `PersonalSpacesModel.swift`、`PersonalSpacesManagementView.swift` 与 `StoragePermissionHelper.swift`，将跨盘数据复制与迁移统一收口至「个人空间」页面（移除「存储 → 存储位置」旧数据复制卡片与「存储 → 跨盘复制与移动」重复入口，避免多处迁移入口混乱）；支持在「个人空间」内直接检测外置硬盘、一键将外置盘设为主存储并就地发起四种换盘模式（复制并核验后回收源文件、仅复制、直接剪切、启用空白新目录）；打开换盘弹窗或切换账号时自动读取并展示待确认（`verified`）、中断（`interrupted`）、源盘待清理（`source_pending`）或失败任务的阶段进度、核对目录（`reviewPath`）与底层诊断详情（`errorDetail`），支持一键继续确认、恢复或取消释放预留而不再卡在 `shared_directory_busy`；修复外置 exFAT 磁盘 0 字节暂存文件写入后簇分配更新 inode 及不支持硬链接导致的 `path_not_allowed` / `ENOTSUP` 问题，并在目录读写权限不足时通过 `StoragePermissionHelper` 主动调起 `NSOpenPanel` 文件夹授权或 macOS 管理员权限修复目录归属后继续执行。
  - **Flutter 精致目录选择组件与 Web 权限收口**：新增符合 Liquid Glass / iOS 连续曲率超椭圆风格的 `IsleFolderBrowserCard` / `IsleFolderPickerSheet`（面包屑胶囊、读写权限徽章、当前层实时筛选、就地新建子文件夹）；将创建/停用账号、重置成员密码、目录授权修改、空间分配、配额修改与跨盘迁移等高危写操作收口至 Flutter 客户端与 Mac 原生管理端，Web 端收敛为只读查看与在线占用核对。
- **私人回收站受控永久清理与账本释放**：私人目录所有者或管理员永久删除回收站项目时，先验证回收站暂存对象身份（`device + inode`）与账本中的 `StorageObjectIdentity` 完全一致，仅在文件/目录内全部账本记录均可一对一核实且物理清理确认完成、未发生同路径换盘时释放对应配额；历史无身份记录、外部未入账文件或换盘异常会拒绝清理并保留原件与账本。
- **私人目录文件夹重命名/同根移动与受控 ZIP 在线解压**：支持私人目录在同存储根、同一所有者内重命名或移动（含原子更新目录前缀账本与防覆盖冲突）；支持将 `.zip` 归档受控在线解压到同级独立子目录（`POST /api/v2/files/extract`，拒绝路径穿越、符号链接及超限归档，私人目录先按解压总字节预占额度并在逐项核实身份后提交账本）。
- **WebDAV 私人目录受控读写**：默认根下已获授权的私人目录（`Users/u<ID>/...`）支持 WebDAV `PUT`、`MKCOL`、`DELETE`（移入应用回收站）及同根同所有者重命名 `MOVE`，写入与覆盖均走同一物理根代际配额账本与回收站身份登记；跨所有者移动与私人目录 `COPY` 仍安全拒绝。
- **配额整体状态**：当前写入渠道尚未完全覆盖系统级直接写盘等通道，配额整体状态仍保持 **`enforcement=pending` / `usageComplete=false`**。

### 3. 图库相册软链接与影视增量刮削
- **受控软链接共享文件夹相册**：文件夹相册所有者可将相册共享给同盘有照片目录授权的成员（默认只读、可选可写），在接收方 `Users/u<member>/photos/` 下创建指向 `../../u<owner>/photos/<album>` 的受控相对软链接；图库扫描、缩略图/原图读取及授权可写上传均在服务端校验 `shared_folder_albums` 授权，成员向可写共享相册上传时计入**相册所有者**在该盘的配额账本。
- **影视自动识别、自动增量刮削、天地图与未匹配分类**：只要在 Mac App「设置 → 媒体服务」填好 TMDB Token 或天地图 Key，服务端与各端（Flutter App / Web）即默认自动启用，无需用户在客户端再次手动点击「启用在线地图」或「开始自动刮削」，也不在客户端提供关闭开关（仅可在 Mac 端清除或不填写 Key/Token 来关闭），彻底消除客户端本地存储授权失败（如 Android「无法保存地图授权」）阻断地图使用的问题。添加影片后，服务端将触发防抖缩短至 2 秒并允许新扫描自动抢占正在运行的后台刮削并在扫描结束后重新续接；`IdentifyPath`（`core/internal/cinema/identify.go`）支持自动剥离发布站/字幕组方括号前缀与分辨率/编码/字幕后缀、识别中文与 `EP`/`SxxExx` 季集号及继承父级影片/剧集/季目录名称与年份；后台自动刮削支持中英双语片名拆分检索、匹配 TMDB `original_title` / `original_name`（使英文或中英双语文件名可直接自动匹配中文片名与海报）、本地 `.nfo` 自动兜底及剧集元数据同步下发至单集，Web 与 Flutter 端在自动扫描与自动刮削完成时均自动刷新影片列表、首页推荐架与剧集视图。

### 4. 存储身份、离线处理与备份恢复
- **删除与恢复的换盘反馈**：单项移入回收站、恢复、共享项目永久清理在操作后重新核对物理根；若发生同路径换盘，提示操作结果不确定，要求回原硬盘检查目录和回收站。批量删除在发现身份变化后停止后续操作，逐项区分结果不确定与未执行。
- **缺失媒体处理反馈**：关联或放弃成功后立即移除已处理项；页面打开时跟踪正在进行的检查，结束后自动刷新；Web 标签隐藏或 Flutter 应用进入后台时暂停查询，返回后恢复。
- **配置恢复演练**：在隔离测试中验证配置快照、校验、离线激活和回退；核对成员只读授权、各根独立额度、未完成预占、文件身份、私人相册及旧会话失效，并确认原文件不随配置恢复被覆盖。
- **授权迁移**：自有代码许可采用 PolyForm Noncommercial 1.0.0，商业授权协议与第三方组件声明已健全。

### 5. 原生多语言插件、按需轻应用中心与受控开发者 MCP（2026-11-10）
- **三态轻应用运行引擎（`core/internal/apps`）与 `automation` 桥接（`core/internal/automation/plugins.go`）**：支持 `static`（纯静态 HTML，永远 `0 MB`，内置 `network-pulse` 示范轻应用开箱即用）、`on-demand`（按需唤醒动态后端，`Singleflight` 并发唤醒锁、带进程组归属核验 `verifyPortOwnedByInstance` 的 `127.0.0.1` 动态空闲端口分配、活跃 WebSocket/SSE 流计数、闲置超时 `SIGTERM` 自动休眠归零 `0 MB`）与 `persistent`（24/7 常驻指数退避看门狗）；插件 Cron 任务通过合法 ID `app-<id>` 原生桥接至 `automation.Manager`，共享五段 Cron、FD 3 文件锁、`automation.sqlite` 最近 30 次执行历史及邮件 HTML 模板通知。
- **可信本地插件同源边界、一次性 Ticket 兑换与首次激活强制保护**：明确采用“仅管理员本机安装可信插件”模型（`Content-Security-Policy: frame-ancestors 'self'` + `sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"` + `referrerpolicy="no-referrer"`），保留插件完整的 `localStorage`、`Cookie`、`SSE` 与 `WebSocket` 能力；服务端拦截源于 `/apps/` 的跨路径 `/api/v2/*` 请求（`403 app_origin_isolated`），反代转发前完整剥离 `Authorization`、`Proxy-Authorization`、客户端伪造的 `X-LightIsle-*` 头与全部 `lightisle_*` Cookie，再注入随机 `X-LightIsle-Proxy-Secret` 与 `X-LightIsle-User-*` 身份头；通过 `POST /api/v2/apps/{id}/launch` 签发 60 秒一次性 `__li_ticket`，兑换为 AES-256-GCM 加密的 `Path=/apps/{id}` `HttpOnly` Cookie 并 `302` 重定向至干净的 `/apps/{id}/`（URL 不含长期凭据，且每次请求实时核对 `auth.Store` 会话与账户状态）；MCP 新热重载插件的 `pendingActivation` 状态持久化于 `apps-config.json`，并在 `CanAccess`、`ServeApp`、`WakeApp`、`/launch` 与 `/start` 全链路统一强制拦截，仅管理员显式启动或保存配置方可解除。
- **插件业务数据一致性备份与清单校验恢复（上限 512 MiB）**：`ExportAppData` 对 SQLite 数据库强制执行 `VACUUM INTO` 一致性快照（快照失败立即中止导出，绝不退回跳过 WAL/SHM 的原始文件复制），内嵌 `backup-manifest.json`（含 `schemaVersion: 1`、`appId`、非空 `dataFileCount` 与逐文件 SHA-256 校验和），并由服务端先写入临时文件完成校验后再响应 `200 OK`；`RestoreAppData` 在停止运行中实例前先于暂存目录完成解压与插件身份、版本、非空业务数据清单及 SHA-256 完整性核验，失败时保留原运行状态与原数据目录并在切换异常时自动回滚；Flutter 客户端通过已认证 `LightIsleApi.download` 直接下载备份归档。
- **三端同步手动开关的内置开发者 MCP（`lightisled mcp`）**：`lightisled` 内置 Stdio JSON-RPC 2.0 MCP 子命令，暴露 `lightisle://specs/plugin-v2`、`lightisle://specs/automation-v1` 及 `lightisle_get_environment`、`lightisle_list_apps`、`lightisle_scaffold_app`（支持 `python`/`node`/`go`/`rust`/`java`/`shell`/`static` 多语言模板，默认 `admin_only` 且拒绝覆盖已存在的插件 ID）、`lightisle_validate_and_reload` 四个工具；MCP 总开关（`mcpEnabled`，默认关闭）持久化于 `<DataDir>/apps-config.json`，支持在 **macOS 原生端（设置页）**、**Web 管理端（应用中心）** 与 **Flutter 管理端（应用中心）** 实时手动开启或关闭，并提供一键复制 AI Agent 接入提示词。
- **三端「应用中心」与第一示范项目 `cpe-monitor` 实装**：Web（`AppsCenterView.vue` 内嵌 Iframe 工作台）与 Flutter（`AppsCenterPage` / `AppsCenterSheets` 浏览器会话工作台）均支持普通成员（仅展示已激活且已授权应用）与管理员（MCP 开关、成员级 ACL 分配、运行模式/休眠时长设置、运行日志、业务数据导出与恢复）双视角；`/Users/leo/Documents/code/cpe-monitor` 已完成 `BASE_PATH`、`LIGHTISLE_PROXY_SECRET` 恒定时间鉴权与 `scripts/collect-once.mjs` 单次静默采集适配。详见 [插件与按需应用架构](PLUGIN_ARCHITECTURE.md)。

## 实现与限制

| 模块 | 当前代码能力 | 仍需关注 |
| --- | --- | --- |
| **Mac 主机** | SwiftUI/AppKit 管理 Core 运行、管理员初始化、本地私有 IPC、菜单栏继续运行；原生媒体 Worker | 实际系统权限、休眠/唤醒、72h 常驻及正式签名未验收 |
| **API / 身份** | Go Core 只注册 `/api/v2/...` 及根限定 `/api/v2/roots/{rootID}/...`；Argon2id、会话撤销、角色与目录授权 | 旧 v1 客户端不可用；不开放远程宿主高权限操作 |
| **文件管理** | Web/Flutter 文件列表、搜索、预览、分片续传、范围下载、批量操作、ZIP 打包与受控 ZIP 在线解压、私人目录文件夹重命名/同根移动、回收站/恢复与身份核验后的私人回收站永久清理、受限分享；Flutter 文件图片与视频复用图库同一个查看器，常见 JPEG/PNG/WebP/GIF 全屏默认加载原图；PDF/`pdfx`、文本和其他应用打开入口并存 | 同名换盘时普通/分片上传及复制写入后再校验物理根身份并保留不确定账本，但满盘/突然断盘/覆盖竞态与大文件真实硬件测试仍缺 |
| **WebDAV** | 独立可撤销凭据、目录授权、受控 PUT 和覆盖回收站；默认根内获授权的私人目录支持浏览、分段读取、计入配额账本的受控 `PUT`/`MKCOL`、移入回收站的 `DELETE` 及同所有者重命名 `MOVE` | 私人目录 `COPY` 与跨所有者移动仍安全拒绝；只能访问默认根，不提供独立 PUT 分块续传；真实 Finder/Infuse 与中断测试未完成 |
| **照片图库** | 索引、缩略图、共享及私人相册、文件夹相册受控软链接共享（只读/可写，可写计入所有者额度）、时间线、收藏、EXIF/GPS、相机型号/定位/日期范围多维筛选、地图；Flutter 可读离线原件；上传/复制/恢复自定义目录中的常见图片与视频扩展名后由服务端防抖触发对应扫描 | 大图库/地图瓦片、RAW/Live Photo 实机体验及权限矩阵仍待验；扫描是异步的，暂不承诺即时可见 |
| **影视** | 电影/剧集、NFO/TMDB、扫描完成后自动衔接后台增量 TMDB 刮削、「待匹配」分类筛选与手动修正、字幕/音轨、原片播放、播放进度、可选 FFmpeg/HLS；Flutter 原生播放器与部分投屏入口；影视原件删除按当前用户文件写权限显示，文件管理和影院遵循同一服务端授权 | 不保证所有格式、HDR、字幕设备通用；AirPlay/PiP/DLNA 及成员授权撤销的真机交互需实测 |
| **多硬盘** | RootRegistry 为唯一运行时存储身份，Mac 可直接选择已登记/新专用目录作为默认 rootID，**不触发迁移**；旧数据复制采用异步可取消的预览、空间检查、冲突跳过、进度持久化，Core 重启把未完成任务标记为中断，成功后请求目标图库/影院扫描；文件/媒体、WebDAV、下载发布、配置备份及原生监控使用注册根 | 迁移仅普通文件、照片和影视原文件，恢复依赖重新扫描并跳过已存在的目标文件（不是同一文件的字节级续传）；**Users 私人目录、媒体数据库、成员授权、收藏/观看历史不自动迁移**；真实多 TB 硬盘拔插/空间不足/恢复待验收 |
| **成员配额** | `user_storage_root_quotas` 已按成员/每个物理根代际独立设置；新根默认 **100 GiB**，同盘分类共用，管理员不限；普通/分片上传及复制经受控预占，模拟同名换盘故障时保证不自动释放不确定预占、不会误报可靠写入 | **`enforcement=pending` / `usageComplete=false`**：WebDAV、下载发布等私人写入通道仍采取安全拒绝而非全面计费，不能宣传全渠道硬配额 |
| **照片备份** | Flutter Android/iOS 前台照片上传；Android Kotlin WorkManager 根限定后台**照片**任务；部分离线原件缓存与哈希校验 | Android 后台、iOS iCloud/RAW/Live Photo、大原片及真实弱网待验；不提供 iOS 后台系统级完整备份 |
| **下载** | 可选 aria2 下载中心；管理员可发起或继续网络下载，成员仍可管理自己的旧任务及恢复本地发布；无 aria2 时保留历史和错误提示 | 磁力、外网和跨盘发布实测；私人目录未纳入全渠道配额时限制写入 |
| **远程访问** | LAN HTTP 默认可启用；按需 HTTPS、Cloudflare Tunnel、FRP 客户端；WebDAV 复用受保护监听；管理员三端（Mac / Web / Flutter）接管 macOS 原生 SMB 文件共享（`/api/v2/admin/smb*` + 本机私有 IPC），Mac 端支持一键开启/撤销 `/etc/sudoers.d/lightisle-smb` 最小命令免密白名单。frpc 意外退出后按有限退避策略自动重启（最多 4 次），手动停止取消重试，鉴权/配置错误不循环，Mac 界面明确展示恢复与取消入口 | **严禁直接公网明文 HTTP**；SMB 使用 macOS 系统本机账号鉴权且写入不经过 LightIsle 配额账本；FRP 进程重启不代表映射成功，公网实际连通、长期离线恢复与认证失败均需外部服务验收 |
| **Docker 与外部工具** | 管理已存在 Docker Desktop/Colima；按需检测 FFmpeg、aria2、smartctl、cloudflared | 不内置引擎/工具，不静默下载；真实环境与权限可能不同 |
| **脚本、通知与系统状态** | JSON/Cron 本地脚本、任务日志、告警、系统资源历史及若干外发通知适配 | 运行脚本使用本机用户权限，不是沙箱；真实接收端需测试 |
| **应用配置备份** | Mac 本机手动与每周自动配置/SQLite 快照，保留最近 **5 份**；本机验证后恢复 | **不备份原始文件、照片和视频**；异盘/断电真实恢复尚待验收 |
| **Web 与 Flutter** | Vue 3 Web/PWA；Flutter Android/iOS/macOS 文件、图库、影视、账号等功能；响应式 UI 对齐 Mac 视觉规范，管理员/普通成员分别使用对应 Dashboard 和高密度设置页，含窄屏、200% 字号、媒体列表及二级页回归 | 无法以 widget/单测通过代替真机视觉、无障碍、键盘避让与后台/系统权限测试 |
| **社区构建** | 本地 Ad-hoc DMG、手动 GitHub Actions 预览构建 | **未完成** Developer ID、公证、Gatekeeper 和完整 QA，非正式稳定版 |

- **Core 常驻恢复**：Mac App 对意外退出和连续三次本机健康检查失败按 2、10、30 秒限次恢复，确认旧进程退出后才启动替代。启动端口被占用时，可换端口后立即重试，或确认并强制停止可核对的本机占用进程。数据目录和离线恢复阻断有明确原因。管理命令拥堵与任务历史、备份计划、分盘媒体索引异常分别提示。关闭窗口继续监测，退出 App 取消恢复。详见 [Mac 进程生命周期](MACOS_APP.md#核心服务恢复与故障隔离)。
- **续传任务查询**：新版 Web 和 Flutter 在创建上传前保留客户端任务编号，创建响应丢失后按原账号和硬盘查询；重复创建同一任务不会重复预占。
- **Android 后台照片授权**：设置显示授权有效期、上次扫描至相册末尾的时间和续授权入口，实际 WorkManager 调度与完整性仍按设备清单验收。

## 后端性能

- 图库/影院按最多 200 项批量读取索引并用短事务提交，探测在事务外执行；未变化照片只更新扫描标记，影院复用有效探测结果，保留用户确认的元数据和观看记录。
- 文件排序分页提前排除无法入选的候选项；空缩略图缓存不查询全媒体库；下载进度和活动告警没有变化时不重复写入 SQLite；指标/任务历史按索引边界保留。
- 回收站元数据读取限制为 64 KiB，异常大文件、链接和 FIFO 不会被完整读入内存，原件保留。未更改成员授权、物理根校验或 `enforcement=pending`。
- 上传完成、文件复制/移动、回收站删除/恢复使用服务端按物理根防抖的媒体扫描触发，不再要求成员调用管理员扫描接口；默认根的全局媒体扫描取消/重试映射到 RootRegistry 默认根，主机级任务列表和历史继续保留配置备份等记录，独立根仍由独立任务中心管理。Mac 对每个在线存储根使用相同的 FSEvents 监听，普通子目录变更只扫描对应范围。内部缩略图、上传暂存和回收站写入不触发媒体扫描。Core 启动后逐盘补扫，重连可触发本盘核对，稳定时每 24 小时由一套任务兜底。
- 局部合成对照、复现方式与仍缺的实际负载证据见 [性能文档](PERFORMANCE.md)。不能将分配量下降等同于整进程 RSS 或真实设备验收。

## 代码维护性与职责收敛

- Flutter 图库和影院批量分享统一调用有物理根绑定的 `publicFileShareUri`，避免在多盘模式下手工拼接旧的全局分享路径。认证 API 的根限定规则已独立封装并补单测。
- Flutter 文件管理的选择工具栏和上传任务列表、影院详情头部已拆为只负责展示和操作回调的组件；媒体分页响应解析已共用纯解析模块。权限判断、任务持久化和请求代次控制仍由原有服务维护。
- Web 将主题、色彩氛围、侧栏偏好及快捷键生命周期移入独立 composable；Go 主程序已抽离地图、TMDB 和回收站保留规则的私有 IPC 处理器，下载任务的 owner 绑定数据库查询移入专门文件。
- macOS 将离线元数据恢复的预览格式化、恢复工具调用及目录解析从 `AppModel` 中拆出，所有者认证与确认流程仍由管理端主状态模型负责。
- 后续收敛：Web 主机遥测与请求取消已移入 `useHostTelemetry`，账号退出会清理状态并拒绝迟到的管理员遥测；Flutter 文件管理新增不可变选择快照，失效路径不能被误判为可写，批量操作确认期间若切换了物理根、目录或选择则阻止执行；Go 下载任务持久化 UPDATE 只允许修改显式列，不能覆盖所属账号和物理根绑定；macOS Core 消息重用现有 Base64URL 解码器。
- 本轮继续：Web 账号会话操作抽入 `useAccountSessions`，文件分享与物理根代次/账户绑定抽入 `useFileShares`；文件搜索按根代次丢弃迟到结果、批量删除复核当前根与选择。Flutter 影院 HLS 会话启动与首片段轮询移入独立服务并补超时/取消测试。macOS 私有设置 IPC 转为 `CoreIPCSettingsEvent` 的类型化解析；Go 本机 IPC 磁盘、SMART、空间告警阈值、通知操作分别处理，下载引擎调度与数据库任务查询分离。
- 2026-11-04 P1：Flutter 文件管理目录分页、搜索和回收站查询已移入 `FileBrowserRepository`，呈现响应须校验请求代次和物理根身份；图库和影视共用 `MediaScanPoller` 来管理扫描完成和页面可见性下的轮询；影院进度串行保存和 NFO/TMDB 请求分别拆至独立服务。Web 的账号/改密/每盘目录初始分配与文件浏览列表、搜索分别抽入 `useAccountManagement`、`useFileBrowser`，账号注销或换盘后丢弃旧响应；统一选择框组件收敛为 `AppleSelect.vue`，彻底替代原生浏览器 `<select>`，实现 Liquid Glass 毛玻璃菜单、键盘导航、视口自适应避让与全模块覆盖。macOS 状态协议解码移至 `CoreIPCReportEvent`，主模型负责在 MainActor 上更新状态。
- 继续收敛：Flutter 文件批量操作通过 `FileBatchOperations` 统一不可变计划、目标路径冲突判断、逐项失败反馈和最多 50 项限制，并在操作途中切盘时停止后续写入；影院 DLNA 临时公开分享的建立、失败撤销与播放会话移入 `CinemaDlnaCastService`，用户确认仍留在详情 UI。Web 回收站列表、恢复、永久删除与保留策略抽入 `useFileTrash`，切根/登出/关闭页面时失效迟到响应。均保留服务端原有的身份与权限校验。
- 最新职责拆分：Flutter 文件管理将文本 QuickLook 弹框抽至 `FileTextPreviewDialog`、目录媒体播放列表构建抽至 `FileMediaPlaylist`，继续复用图库唯一播放 UI；文本预览在异步读取后复核页面、目录和物理根，禁止切盘后展示旧文件。影院字幕 HTTP/本地选择与 WebVTT 解析收敛至 `CinemaSubtitleRepository`，播放界面对字幕应用同时复核影片 ID、根身份和请求代次。macOS Go Core 子进程可执行文件定位、启动参数/管道配置和正常退出→终止→强制结束策略移至 `CoreProcessBootstrap`，主模型仍管理启动代际、状态显示及 READY/EXIT 事件。
- 本次继续：Flutter 共享/私人相册 CRUD、关联增删和列表解析统一交由 `PhotoAlbumRepository`；批量加入私人相册使用选择快照，按物理根、列表代次和选择校验后逐项写入，切换硬盘后不再继续操作。影院下一集搜索独立为 `CinemaEpisodeNavigator`，仅在剧名唯一匹配且片源仍处于原硬盘时跳转；PiP 前后台暂停规则收敛至 `CinemaPipLifecyclePolicy`。macOS 显式停止与意外退出共享 `resetCorePeripheralState`、`releaseCoreRuntime`，废弃旧代际的磁盘、隧道、进程连接及内存授权状态，保留持久配置。
- 后续模块收敛：Flutter 图库/影视的 24 小时批量分享与图库桌面批量导出统一到 `MediaBatchOperations`，保存/分享的顺序、部分失败及最多 10 条分享限制有独立测试；使用选择快照与物理根代次防止切盘后继续发出请求，手机端继续复用唯一的原生批量文件导出服务，增加文件下载前后与系统选择器打开前的根校验。图库两处操作确认统一复用 `confirmAction`。macOS 跨盘复制的本机路径选择、安全移动确认、目标共享根目录/符号链接过滤与 IPC 请求编码拆至 `CrossDiskExportCoordinator`，`AppModel` 保留进程状态、重新检查共享根与管道及任务反馈；Go Core 仍权威检查物理卷、日志化拷贝和 SHA-256 校验。
- 本轮维护性整理：Go 备份回滚清单与执行、WebDAV 写入事务、上传会话与发布、多盘请求处理按职责拆分；Flutter 设置页拆开账号、目录授权和上传维护，共用组件按展示区域分组，HTTP 传输与本机媒体转发独立；Web 样式按原级联顺序拆分。接口、授权和物理根校验沿用原有实现，自动测试不能替代真实硬盘及设备验收。
- 本轮完成源码长文件整理：仓库纳入统计的 Go、Dart、Swift、Web 源码及测试文件均不超过 1000 行；Web 主页面的外壳模板、主页、上传协调和影院播放分别归位，macOS 主模型按职责拆分。失败的播放进度不会阻塞其他根的排队保存，页面关闭或刷新后未保存的进度仍无法恢复；上传取消后退出失败可重新发起上传。若服务端已创建上传任务但响应在取消时丢失，客户端可能拿不到任务 ID，管理员可在上传维护中清理过期任务。以上是代码与自动回归结果，不代表真实硬盘及设备验收通过。
- 全仓 Clean Code 与模块解耦（2026-11-09）：清理历史遗留空目录（`core/internal/migration`、`core/internal/migrationpreview`、`apps/macos/Tests`），并将 Go Core、Flutter、Web 与 macOS Swift 全部生产源码文件收敛至 800 行以内（Go 最高 781 行、Flutter `lib/` 最高 777 行、Web `src/` 最高 797 行、macOS Swift 最高 646 行）。Go Core 将 `lightisled/main.go` 的备份/跨盘导出/管理远程 IPC、`files` 的回收站索引与物理根租约校验、`dav` 的持久化状态读写、`auth` 的 SQLite Schema 演进、`cinema` 的 FFprobe 探测与字幕提取、`gallery` 的缩略图磁盘缓存读写、`downloads` 的 aria2 进程/RPC 生命周期及 `backup` 的恢复/离线校验分别解耦为独立同包文件；Flutter 将 `LightIsleApi` 文件与目录接口、`StartupCurtain`、`ClientShell` 顶栏/底栏与通知弹窗、存储对话框、网络诊断自绘 Painter、相册总览/查看器顶底栏/地图聚合模型及影院首页横栏/数据模型按职责拆分；Web 将 `PhotosView.vue`（2260 行 → 711 行）、`CinemaView.vue`（1100 行 → 753 行）、`App.vue`（997 行 → 750 行）与 `fluid.css`（982 行 → 664 行）拆分为独立 Composable（`usePhotoAlbums`、`usePhotoBatchActions`、`usePhotoGridAndModal`、`usePhotoFolderAlbums`、`usePhotoTimelineScrubber`、`useCinemaMetadata`、`useCinemaSeriesAndHistory`、`useFileActionsAndGrants`、`useOverviewAndDisclosures`）与样式表（`fluid-files.css`）；macOS 将 Docker 操作、存储备份/离线恢复视图、Core 进程输出消费及 `LightIsleMediaWorker` 数据模型与主流程分离。所有 `/api/v2` 与根限定契约、物理根 `device + inode` 校验、`enforcement=pending` 及本地脚本邮件配置保持完全不变。
- Beta 预发布交互闭环与 Clean Code 二次收敛（2026-11-10，对应 [预发布检查清单](BETA_PRE_RELEASE_CHECKLIST.md) `UX-001`～`UX-017`）：
  - **成员创建部分成功恢复与配额防溢出（`UX-001`、`UX-002`、`UX-008`、`UX-009`、`UX-012`、`UX-017`）**：Go 本机 IPC `create-user`（`core/cmd/lightisled/ipc_spaces.go`）在初始空间分配失败时同时返回含 `createdUser` 的最新快照；macOS 抽离纯验证器 `SpaceInputValidation.swift`（`QuotaInputValidator` 防 `Int64` 乘法溢出、`AccountInputValidator` 实时校验用户名与密码）及独立弹窗文件 `PersonalSpacesSheets.swift`（`PersonalSpacesManagementView.swift` 由 815 行降至 495 行），Flutter 抽离 `new_account_dialog.dart`（`accounts_page.dart` 由 511 行降至 277 行），双端均通过显式状态机展示分步进度、无在线硬盘引导与“仅重试空间分配”，且配额快捷档位只修改草稿、点击保存才提交。
  - **跨盘迁移五阶段进度、两阶段免二次输密与并发隔离（`UX-004`、`UX-005`、`UX-007`、`UX-010`、`UX-013`）**：Go Core 将换盘树克隆/校验/发布/清理拆至 `user_storage_switch_media.go`（`user_storage_switch_task.go` 降至 590 行），在响应中输出 `totalFiles`/`totalBytes`，并新增绑定 `(session, userID, taskID)` 的 10 分钟内存短期令牌 `confirmationToken`；Flutter 将换盘逻辑拆至 `storage_page_switch.dart`，复用短期令牌免除 `confirm_cleanup` 二次密码弹窗，并以最多 3 路受控并发独立拉取各成员存储策略（单成员失败仅局部提示重试）；macOS 与 Flutter 换盘弹窗统一五阶段进度条、可滚动主体与固定底栏，并准确说明同内容媒体收藏/私人相册/进度自动迁移而公开分享与共享相册需重新建立。
  - **自动化乐观锁、文件批量进度/重试、上传取消确认与 Web 模态确认统一（`UX-003`、`UX-006`、`UX-011`、`UX-014`、`UX-015`、`UX-016`）**：Flutter 自动化编辑补齐 `_editingRevision` 乐观锁赋值与冲突重载；文件批量操作新增 `FileBatchFailure` / `FileBatchProgress`，展示实时 `X/Y · 当前文件名`、可中途停止、详细失败原因及“仅重试失败项”；上传任务中心对进行中任务增加取消确认弹窗与 `aborting` 清理态提示；Web 新增 `useConfirmDialog.ts` 与 `ConfirmModal.vue`，将全部 22 处 `window.confirm` 与 1 处 `window.alert` 统一替换为应用内 Liquid Glass 模态确认框；Go `smbmgmt/manager.go` 拆出 `validation.go`，确保全仓无任何超过 800 行的生产源码文件。
- 原生多语言按需轻应用中心与受控开发者 MCP（2026-11-10，见 [原生多语言插件与按需应用系统](PLUGIN_ARCHITECTURE.md)）：
  - **Go Core 三态轻应用引擎与 `automation` 桥接（`core/internal/apps`、`core/internal/automation/plugins.go`、`core/internal/server/apps.go`）**：支持 `static`（0 MB 纯静态托管，首次初始化自动生成 `network-pulse` 示范应用）、`on-demand`（Singleflight 并发唤醒、动态回环端口、闲置超时 `SIGTERM` 归零内存）与 `persistent`（异常退出指数退避自愈）；插件 Cron 自动以 `app-<id>` 注册至 `automation.Manager` 并复用邮件模板与通知中心；网关层完整剥离 `Authorization`、`Proxy-Authorization`、客户端 `X-LightIsle-*` 头及 `lightisle_*` Cookie 后注入 `LIGHTISLE_PROXY_SECRET` 与真实用户身份头，且 `VerifyAppCookie`/`ConsumeTicket` 每次实时校验主会话与账号启用/角色状态。
  - **受控 `lightisled mcp` 与三端应用中心（Web `AppsCenterView.vue`、Flutter `apps_center_page.dart`、macOS 设置页）**：内置 `lightisled mcp`（`stdio` JSON-RPC 2.0）默认关闭，由管理员在 macOS/Web/Flutter 手动开启，且 `lightisle_scaffold_app` 对已存在插件 ID 返回 `app_already_exists` 防止覆盖用户配置；三端统一采用 `admin_only` / `selected_members` / `all_members` 权限枚举并支持按需局部更新 `access` / `web` / `cron` 模块（兼容无 Cron 的纯静态应用）；完成 `cpe-monitor` 在 `plugins/cpe-monitor` 的按需唤醒、数据目录隔离与定时采集适配。当前同源 Iframe（`allow-scripts allow-same-origin`）面向 Mac 主人本机安装的可信家庭插件，不等同于不可信第三方代码的浏览器 Origin 沙盒。
  - **Web 三端自适应（Desktop / Pad / Mobile）与交互体验对齐 Flutter（2026-11-10）**：修复 `PhotosView.vue` 与 `CinemaView.vue` 因顶层 `<Teleport>` 多根 Fragment 导致 `v-show` 保活失效、切页后多页面上下粘连堆叠的问题（统一将 `<Teleport>` 收拢至单根容器内并增加原生 `<div v-show>` 包装层与外框去卡片化）；全局顶栏合一（共享目录切换器内嵌顶栏、Pad `768px–1080px` 自动收起为 `76px` 图标导航栏、移动端 `5 格底栏 + 更多抽屉` 补齐自动化与偏好设置入口）；相册 6 行工具栏收敛为 2 行紧凑工具条 + 按需 EXIF 筛选抽屉 + 底部悬浮多选 HUD（`PhotosBatchBar.vue`），补齐「回忆与精选」横栏、「紧凑/舒适」网格密度切换与月份标题一键「全选当月」；影院将管理员 TMDB 批量/自动刮削面板（`CinemaTmdbPanel.vue`）按需仅在「待匹配」视图显示，统一单行分类胶囊与底部多选 HUD；文件页新增列表/网格双视图切换、行内搜索与按需新建文件夹弹层。

## 重要存储约定

- **每盘独立额度与按需扩容目录**：每个成员在 A 盘、B 盘拥有相互独立的每盘额度（默认 100 GiB，同一盘的 `files / photos / videos` 共享该盘一份额度）。管理员在创建成员或为成员分配硬盘空间时（`POST /api/v2/roots/{rootID}/users/{userID}/storage` 或带可选 `quotaBytes` 的 `PUT /api/v2/roots/{rootID}/users/{userID}/storage/{category}`）即可直接配置该盘限额（支持快捷档位与 `0–1048576 GiB` 自定义，也可先只分配硬盘空间与限额、暂不创建分类目录）；后续可随时在该盘补充未分配的分类目录、新建个人子目录，并通过 `PUT /api/v2/users/{id}/storage/roots/{rootID}/quota` 自由修改配额，不会覆盖已有自定义限额。账本记录的 `accountedBytes` 与 `reservedBytes` 不等同于实际整盘扫描用量；离线代际也不能直接清零，`enforcement=pending` 保持不变。
- **根身份优先**：离线盘不自动转向另一盘，同路径/同名新设备也不自动继承旧权限。管理员放弃已移除旧根的绑定，表示重新建空目录，**不会物理删除或迁移旧数据**。
- **配置快照不是数据备份**：请另行使用 Time Machine 或独立存储备份文件原件，避免将唯一数据留在 Beta。
- **接口单版本**：全局和指定根均为 v2；文档中的历史 v1 记录不得作为当前调用示例。

## 完成状态如何判定

**已有代码入口** → **单测/静态检查通过** → **模拟接口/临时介质回归** → **真实设备与服务验收** → **正式签名发布**。后一阶段不因前一阶段通过而自动成立。

详细约定：[存储与磁盘](STORAGE_AND_DISKS.md) · [Flutter](FLUTTER_CLIENT.md) · [安全](SECURITY.md) · [架构](ARCHITECTURE.md) · [产品范围](PRODUCT.md)。
