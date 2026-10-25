# 影音与文件体验实施技术记录（2026-10-25）

> **历史技术记录，不是最新计划或缺口清单。** 保留 ffmpeg/HLS、音轨/字幕、剧集、图库交互等具有复现价值的技术参数及当时的测试项。文中的“第 1/2/3 批”“未实现”均指 2026-10-25 当轮盘点时的开发安排；其中多项功能现已落地。现行能力及真正剩余问题以 [STATUS](STATUS.md) 为准，当前排期以 [ROADMAP](ROADMAP.md) 为准，真实设备未验收项以 [ACCEPTANCE_DEBT](ACCEPTANCE_DEBT_2026-10-25.md) 为准。音乐模块当轮未立项。

## 1. 当轮盘点基线（2026-10-25，非当前缺口）

核心模块（文件、回收站、分享、上传续传、图库、影院、账号授权、审计告警、备份恢复、磁盘、WebDAV、隧道）代码与自动化测试层均已落地，无纯 stub。欠账分三类：

| 类别 | 代表缺口 | 处置 |
| --- | --- | --- |
| 影音硬能力 | MKV/AVI/TS 只能下载播放；刮削逐部手动；影片平铺无剧集；无内嵌字幕/音轨 | **第 1 批（本文第 3 节，当前实施）** |
| 网盘/图库日常体验 | 列表无排序、无冲突处理、手输路径移动、文件管理器无缩略图、图库灯箱只有 512px、无 PDF/HEIC 预览、回收站无自动清理、分享无密码/次数 | 第 2 批（第 4 节） |
| 验收债 + 发布 | WebDAV 挂载/隧道/Android 后台备份/双盘故障/Touch ID 等真机验收；Developer ID 签名公证 | 第 3 批（第 5 节），每批收尾穿插执行 |

## 2. 范围决定（2026-10-25 用户确认）

- 主线：**影音硬能力优先**。
- 转码技术路线：**Homebrew ffmpeg/ffprobe 白名单**（与 Docker/smartctl/cloudflared 同模式，不捆绑不自动下载）；未安装时诚实降级为现有"直接播放/下载 + IINA/VLC 引导"。
- 音乐模块：**暂不立项**（当前零实现，等核心收敛后再评估）。

## 3. 第 1 批：影音硬能力闭环（本轮实施）

### 3.1 ffmpeg/ffprobe 白名单（`core/internal/ffmpegbin`）
- 仅探测 `/opt/homebrew/bin/ffmpeg|ffprobe`、`/usr/local/bin/ffmpeg|ffprobe`；懒探测缓存版本。
- 未装：`GET /api/v1/cinema/transcode/status` 返回 `available=false`，一切转码请求返回原因码 `transcode_unavailable`，前端映射"未安装 FFmpeg，仅支持直接播放/下载（引导 brew install ffmpeg）"。

### 3.2 转码会话管理器（`core/internal/cinema/transcode.go`）
- 会话键 = 影片身份（share|path|size|mtime）+ 档位 + 音轨序号 + 起始时间；两档：
  - **remux（优先）**：h264/hevc + aac 源 → `-c copy` fMP4 HLS，hevc 打 `-tag:v hvc1`；
  - **转码（兜底）**：不兼容编码 → `-c:v h264_videotoolbox -c:a aac`。
- 输出 `<dataDir>/transcode-cache/<session>/`，从请求时间点就近分界起写，磁盘占用有界；空间预检（沿用上传 Fstatfs + 预留模式）不足返回 507 `transcode_insufficient_space`。
- 生命周期：单飞去重、默认并发 2、空闲 5 分钟回收、共享根切换/影片替换即失效、任务入 tasks.Journal。
- 原因码全套：`transcode_unavailable/failed/busy/insufficient_space`。

### 3.3 播放端
- 新端点 `GET /api/v1/cinema/{id}/hls/…`（playlist + segment，复用会话鉴权，segment 相对路径）；`GET /api/v1/cinema/{id}/tracks` 返回音轨/内嵌字幕清单。
- Web：hls.js 打进 bundle（CSP `script-src 'self'` 兼容），按 `browserPlayback` 档位自动切直放/HLS；进度保存复用串行队列。
- Flutter：`video_player` 直接喂 HLS URL（AVFoundation/ExoPlayer 原生）；经既有 loopback media-token 代理，需验收 segment 转发。

### 3.4 内嵌字幕与音轨
- 播放会话启动时 ffprobe 列轨道；文本字幕（subrip/ass/mov_text/webvtt）按需抽取为 SRT 缓存（哈希键），复用 SRT→VTT 管线；ASS 转 SRT 丢样式，UI 注明"样式简化"。
- remux 会话 `-map 0:a:N` 秒切音轨。

### 3.5 剧集聚合
- 新 `series` 表（share/generation 隔离）：series 名、TMDB id、海报、简介；films 增 `series_id`（增量迁移，老库兼容）。
- API：`GET /api/v1/series`、`GET /api/v1/series/{id}`（按季分组 + 每集进度；放在独立前缀是因为 `cinema/series/{id}` 与 `cinema/{id}/poster` 在 net/http ServeMux 中是歧义模式）；平铺列表保留。
- Web/Flutter：剧集网格 → 季选择 → 剧集列表；"继续观看"升级跨集 next-up。

### 3.6 TMDB 自动刮削（Keychain + IPC，对齐隧道 Token 先例）
- TMDB Read Access Token 存 Mac 钥匙串 `dev.lightisle.tmdb`，Mac App 设置页配置；IPC `cinema tmdb set/clear` 下发 Core 仅内存持有；Web 端只读提示"在 Mac App 配置后启用"。
- 后台任务 `cinema/scrape`：遍历 `metadataSource=''`，限速 ≥250ms/请求、可取消、断点续扫；电影 title+year 匹配，剧集 series 名一次匹配应用全季；全程入任务中心与审计；Token 永不进日志/审计/错误文本。

### 3.7 实施状态（2026-10-25 开发版已交付）

**已进入开发版**（单测与构建全绿：`go test ./core/...` 20 包、`apps/web` 41 测试 + build、`flutter analyze` 0 issue + macOS build、`swift build`）：
- ffmpeg/ffprobe 白名单（`core/internal/ffmpegbin`，未装诚实降级 `transcode_unavailable`）；转码会话管理器（`core/internal/cinema/transcode.go`，remux `-c copy`/hevc `hvc1` + VideoToolbox 转码 + libx264 兜底，fMP4 HLS、空闲 5 分钟回收、并发 2、Fstatfs 空间预检 507）；内嵌字幕按需抽取（SRT/ASS→SRT、WebVTT 透传，PGS 标记不可提取）；音轨 `-map 0:a:N` 秒切；剧集聚合（series 表 + 扫描同步 + `/api/v1/series`）；TMDB 自动刮削（Keychain `dev.lightisle.tmdb` + IPC `cinema tmdb set/clear/status` + 后台任务，≥250ms 限速、可取消、断点续扫）；三端 UI（Web hls.js、Flutter 原生 HLS + loopback 中继 HLS 前缀转发、Mac App 设置组）。
- 已知实现边界：单档码率（按源高度自适应，无 ABR）；转码档音轨切换为重启会话；剧集聚合严格按文件名（series 重命名/整季刮削暂缓）；Flutter Web 非 Flutter 支持范围。

**待真机验收**（对照原清单）：
- [ ] `brew install ffmpeg` 后运行 `go test ./core/internal/cinema/ -run TestTranscoderRealFFmpeg`（未安装时该测试显式跳过）：MKV h264/aac remux、MPEG4 转码、内嵌 srt 抽取、双音轨切换、状态版本号。
- [ ] Web：MKV remux 在 Safari/Chrome 起播、拖动、进度续播（会话时间轴 → 原片时间轴换算）；HEVC 在 Safari；内嵌中文字幕可选可显。
- [ ] Flutter：钉扎证书下 HLS 经 loopback 中继前缀转发可播（重点验收 segment 相对路径）；Android ExoPlayer HLS；音轨切换续位。
- [ ] Mac App：TMDB Token 保存/清除/重发（Core 重启后无需重填）；Core 未连接时保存仅入钥匙串。
- [ ] 刮削：配置 Token 后批量任务可启动/取消/续扫，任务中心可见；未配置时三端提示诚实。
- [ ] 未安装 ffmpeg 的机器：三端全部新入口显示降级原因码，无假成功。

### 3.8 已知限制
- 转码画质/码率先用探测码率自适应，不做多码率 ABR（单 variant）。
- ASS 特效字幕仅文本化（不烧录）；需要原样渲染仍走下载 + IINA/VLC。
- 音轨切换在转码档为重启会话（remux 档为秒切）。
- 免费版 Cloudflare 隧道下大码率转码受带宽限制，属网络条件非功能缺陷。

## 4. 第 2 批：网盘/图库日常体验（2026-10-25 开发版已交付，待真机验收）

**本轮实施状态**（go 20 包 / web 41 测试 / flutter 123 测试 / swift 构建全绿）：
- 排序：`files.PageSorted`（name/size/mtime × asc/desc，复合游标向后兼容）+ `GET /files?sort=&dir=` + 三端 UI（Web/Flutter 由前端落地）。
- 冲突：Manager `MoveWithOptions/CopyContextWithOptions`（skip/rename，永不覆盖）+ `POST /uploads` `onConflict=rename`；Web FileOperationDialog（目录树+策略）、Flutter FileDestinationDialog。
- 缩略图：`GET /api/v1/files/thumbnail?path=&size=512|2048`（gallery 路径版 LRU、worker `--max-pixel`、file-manager 条目 prune 豁免）+ Web/Flutter 文件列表缩略图。
- 预览：previewFile 白名单加 PDF；HEIC 走 2048 端点；PhotosView 灯箱渐进加载（512→2048→原图）+ 双击缩放拖拽；Flutter 照片详情双击缩放 + 2048。
- 回收站 TTL：`SweepTrashExpired`（每小时、每轮限量 100）+ `trash-retention.json`（默认关）+ IPC `trash retention` + Mac 设置组 + `GET /api/v1/trash/retention` 只读展示 + `trash_cleanup_failed` 告警 + tasks journal kind "trash"。
- 分享增强：密码（argon2 摘要）+ 次数上限（原子扣减）+ 公共 401 自包含 HTML 密码表单（15 分钟内存授权 Cookie、按链接+地址限流 10 次/15 分钟、404 均一化）+ 三端创建/列表 UI。
- 设置重组：Web 设置页二级分类（账号与安全/文件与分享/存储与磁盘/任务与通知，URL `?group=` 同步）；Mac 偏好与安全 Picker 四分段（Environment 驱动组可见性）。

### 4.1 影院体验增补（2026-10-25 第二轮，开发版已交付）

- **清晰度选择**：转码会话加 `quality` 档位（source/1080/720/480，按源高封顶不放大）；低档强制转码 + `-vf scale=-2:H` + 码率按目标高；会话键按档位隔离缓存；直接播放的影片选低档也走转码，选回原画自动拆会话回直放。三端清晰度菜单（Web/Flutter）。
- **历史播放**：`GET/DELETE /api/v1/cinema/history`（按 updated_at 倒序、授权过滤、仅本人）；Web"历史记录"chip + Flutter"历史播放"chip，含清空历史（仅清自己）。
- **倍速播放**：0.75–2x（Web playbackRate / Flutter setPlaybackSpeed），直放与转码会话均生效，换会话自动恢复。
- **标记已看/未看**：`POST /api/v1/cinema/{id}/watched`（upsert 进度行；未看同时归零 position；已看保留 position/duration）；两端详情页按钮 + "从头播放"。
- 测试：cinema 包新增 quality/scale/码率、History 排序/隔离/清除、MarkWatched 语义单测；Flutter media_pages 测试更新（清晰度下拉断言）。

**待真机验收**：
- [ ] 排序游标翻页稳定性（大目录 + size/mtime desc）；老客户端游标兼容。
- [ ] 冲突：同目录连传同名文件自动改名 `(2)(3)`；移动到占用目录 skip 提示。
- [ ] 缩略图：HEIC/视频出图；2048 预览用于灯箱与 HEIC 预览；LRU 预算淘汰。
- [ ] 回收站 TTL：Mac 配置后每小时清理生效、离线盘静默跳过、失败出告警。
- [ ] 分享：密码表单流程（错误密码限流）、次数耗尽后 404、审计记录。
- [ ] 设置重组：Web 四组导航与移动端 chips；Mac 分段切换。

| 项 | 最小范围 | 验收标准 |
| --- | --- | --- |
| 文件列表排序 | API `sort=name/size/mtime ±dir`，默认 name 升序兼容 | 三端列表可切排序 |
| 冲突处理 | move/copy/上传同名统一策略：跳过/替换/自动改名（` (2)` 后缀），409 语义保留 | 同名上传不再直接失败 |
| 目录选择器 | Web 树形选择器、Flutter 目录选择，替换 prompt/文本框 | 移动复制零手输路径 |
| 文件管理器缩略图 | 复用 gallery worker+缓存，授权过滤 | 图片/视频列表出图 |
| 图库原图查看器 | 512px 占位 → 2048px 中图（HEIC 经 worker 转 JPEG）→ 原图渐进加载 | 灯箱可看原图，HEIC 全流程可用 |
| 预览扩展 | previewFile 白名单加 HEIC（转 JPEG）、PDF（浏览器原生） | 文件页可预览 HEIC/PDF |
| 回收站自动清理 | TTL（默认关，显式开启）+ 清理前告警 | 开启后到期项自动清理并入审计 |
| 分享增强 | 分享密码（摘要存储）+ 下载次数上限 | 公共链接可验证密码/计数 |

## 5. 当轮第 3 批建议（是否完成以当前状态文档为准）

- SMART 状态变化联动持久告警；member 角色通知可见性按类别授权。
- Android 后台备份真机验收收口；iOS 前台备份。
- 既有验收债集中执行：WebDAV Finder/Infuse 挂载、API Key 隧道绑 `nas.lengsu.top`、双盘拔插/满盘/断电、Touch ID/GUI 生命周期、72 小时。
- Developer ID 签名 + 公证 + `verify-release-qa.py` 真实门禁跑通。

## 6. 明确不做（延续 [FNOS_PARITY_PRIORITIES](FNOS_PARITY_PRIORITIES.md)）

音乐模块、文件夹/相册分享（P2-09，确有需求再扩）、PC 同步盘（系统 SMB/WebDAV 替代）、配额/RAID/自建全文搜索平台、下载中心/DLNA、联合灾备、**不把 ffmpeg 变成 Core 运行前置依赖**（未安装必须完整可用）。
