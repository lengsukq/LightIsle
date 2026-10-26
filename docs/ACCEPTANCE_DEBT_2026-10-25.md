# 真机验收债清单（2026-10-25）

> 本文只登记**代码与自动化测试已完成、但缺少真实设备/外部服务证据**的功能。它不改变 [产品边界](FNOS_PARITY_PRIORITIES.md)；勾选一项前必须留下可复核的验收记录（截图、日志、介质照片或操作记录）。每完成一项，请把对应条目移入「已验收」，同步更新 [当前功能状态](STATUS.md)，并在发布说明中引用。

## 影音（P1-04，开发版 2026-10-25）

- [ ] **ffmpeg 真机转码**：Homebrew ffmpeg 白名单路径下，真实 MKV（多音轨/内嵌字幕）起播、拖动、清晰度切换（480/720/1080）、音轨切换、内嵌字幕抽取为 VTT。
  - 部分证据（2026-10-25）：开发机 `brew install ffmpeg`（ffmpeg 9.0.2，/opt/homebrew/bin）后 `go test ./core/internal/cinema/ -run TestTranscoderRealFFmpeg -v` 四个子测试全过（RemuxMKV / TranscodeMPEG4 / EmbeddedSubtitleExtraction / StatusReportsVersion）。**仍缺**：真实浏览器起播/拖动/清晰度与音轨切换的手动矩阵，未勾选。
  - 部分证据（2026-10-26）：安装 ffmpeg 9.0.2 后重跑 `go test -count=1 ./core/internal/cinema/ ./core/internal/server/`（含 TestTranscoderRealFFmpeg 四子项与"已装 ffmpeg"环境的降级隔离测试）全过。浏览器矩阵仍未做。
- [ ] **浏览器矩阵**：Safari 与 Chromium 下 fMP4-HLS 播放、进度保存、已看标记。
- [ ] **Android HLS**：Flutter 客户端（证书钉扎回环中继路径）播放转码流。
- [ ] **软件编码器兜底**：构造 VideoToolbox 失败场景，验证 libx264 重试与诚实降级（transcode_unavailable 时仅下载）。
- [ ] **TMDB 自动刮削**：真实 Token 下批量刮削准确率与失败降级；豆瓣匹配一次真实结果。
- [ ] **缓存治理**：连续播放多部长片后缓存目录回收（idle TTL 5 分钟、重启清缓存）与磁盘空间守卫生效。

## 下载中心（P2-06，开发版 2026-10-25）

- [ ] **真实任务全生命周期**：公网 HTTP 大文件（≥1 GiB）与一个真实磁力链接，经 Web 任务页创建→进度→暂停/继续→完成发布到共享目录；Core 重启后任务安全中止且可一键重试。
  - 部分证据（2026-10-26，本机临时 Core + 真实公网）：`brew install aria2`（aria2 1.37.0）后，临时数据目录 + 端口 16699 起真实 Core，创建清华镜像 ubuntu-24.04.5.1-desktop-amd64.iso（content-length 6,250,332,160 字节 ≈ 6 GiB）任务：跑至 2510/5961 MiB 后 pause（停在 2763 MiB）→ resume 续传成功；下载完成进入发布。**该次验收还抓到一个真实缺陷**：发布阶段被 `files.Store.Upload` 的 1 GiB HTTP 请求上限拒绝（`download_publish_failed`）——修复为本地暂存发布走独立 `PublishLocal` 上限（与任务上限一致），真实 journal 重试 7.7 秒完成发布并经 SHA-256 复核，落盘字节数与镜像完全一致。`SIGKILL` Core 后新任务诚实标记 `download_restarted` 且一键重试可继续。**仍缺**：Web/Flutter 任务页 UI 上的全流程人工操作、真实磁力（本环境 DHT 无进展，3 分钟元数据解析未完成即取消）。
- [ ] **边界诚实性**：未装 aria2 的机器三端显示 `download_unavailable` 降级文案；单任务大小上限触发即停；同名发布自动改名不覆盖；目标目录授权撤销后发布被拒。
  - 代码级补充（2026-10-26）：临时 Core 回归覆盖无 aria2 时本人历史、取消/删除和本地发布重试、跨用户拒绝、删除暂存/journal 保留共享文件、两文件合计超预算时零发布；Web/Flutter 已补部分发布/明细截断与按阶段操作，下载布局使用模拟数据人工查看。仍需实际任务在两个客户端上的手动闭环，未勾选。
- [ ] 部分证据（2026-10-25）：`TestRealAria2DownloadLifecycle`（aria2 1.37.0 真进程）覆盖 本地 HTTP 下载→发布、同名改名 `(2)`、授权撤销拒发布、慢任务取消→重试→删除记录。
- [ ] 部分证据（2026-10-26）：`TestInterruptedPublicationVerifiesExistingBytesWithoutMakingDuplicates` 覆盖发布中断重试不产生 `(2)` 副本、篡改源必须进入 recovery_required；`TestPublishLocalAcceptsBeyondRequestCap` 锁定 >1 GiB 本地发布通过、HTTP 请求路径仍拒绝。STATUS.md 记录的"部分发布失败重试产生 `a.txt`/`a (2).txt`"缺陷已修复并有回归，此行缺陷从 STATUS 移除。

## 文件夹分享（P2-09，开发版 2026-10-25）

- [ ] **目录 ZIP 全生命周期**：真实媒体目录（含中文/深层级）经公共链接下载、密码/次数语义与单文件一致、撤销后 404；中途断网后浏览器不残留"成功"下载。
- [ ] **边界诚实性**：超过 2 GiB / 2000 项 / 16 层的目录在公开端点收到 413 明确文案；目录删除重建后旧链接 404。

## 高质量相册：时间线与地图回溯（P1-04 增补，开发版 2026-10-25）

- [ ] **GPS 真机提取**：真实 iPhone HEIC 照片与视频（含位置）、相机 JPEG（GPS+相机参数）放入共享目录，扫描或后台回填后：时间线按拍摄时间排序、那年今天命中、详情面板显示相机/镜头/参数/坐标、地图出现正确点位；(0,0) 与无 EXIF 素材不产生位置。
  - 部分证据（2026-10-25）：测试内合成 EXIF JPEG（生成 TIFF IFD，不提交二进制介质）与 media worker fixture 端到端断言 GPS/相机字段；`TestBackfillUpgradesLegacyRowsWithCaptureMetadata` 覆盖老行升级与升级后复用；worker Python 集成含 HEIC GPS 与 MP4 uiso/loci 提取。
- [ ] **地图回溯降级与瓦片配置**：断网或瓦片不可达时自动切点阵模式并出现明确提示与重试；自定义瓦片地址（含自托管）保存后恢复底图；超过 2 万带位置照片时 truncated 标注真实可见。
- [ ] **查看器手势真机**：触屏捏合、双指/双击缩放、单指滑动翻页、滚轮锚点缩放在 Safari/Chromium/手机浏览器的实际表现；HEIC 在不支持解码的浏览器停在 2048 预览。
- [ ] **回填规模与让路**：十万级老库升级后回填进度透出、扫描运行时让路、库关闭可停，结束后 photos/status 不再显示 backfill；跨时区使用时那年今天与前端月分组的时区差异需人工确认可接受。

## 手机照片备份（P2-01）

- [ ] **Android 后台**：WorkManager 在锁屏/省电模式下的实际调度间隔、断网恢复、7 天 TTL 隔离与 Keystore 会话加密。
- [ ] **Android 首跑**：万张级图库首次备份的进度可追踪性与暂停/恢复/取消。
- [ ] **iOS 前台**：真实机型照片权限流程、分页游标持久化、SHA-256 远端复核（iOS 无后台备份，属边界而非缺口）。
- [ ] **大原片与部分失败（2026-10-26 补充）**：真实 iOS >2GiB 视频备份到本机 APFS，逐块校验、暂停/退后台/重连后保持未完成或正确恢复；覆盖接近 32GiB 上限与非 APFS 明确拒绝。iCloud 未落盘原件失败后后续照片继续，重启后仍能看到遗漏并重新扫描重试。当前仅有稀疏文件、小块协议及临时 Core 自动化，未做实际大视频验收。

## 网络访问（P1-02 / P1-08）

- [ ] **WebDAV 挂载**：Finder、Windows 资源管理器、Infuse 三方挂载读写；DELETE 入回收站、按 IP 限速、目录授权过滤。
  - 部分证据（2026-10-26，本机临时 Core）：`osascript` 经 Finder 实际挂载 `http://127.0.0.1:16699/dav/`（macOS webdav fs，/Volumes/dav）；挂载内写入 `from-finder.txt` → HTTP GET 读回一致；curl PUT 后挂载内可读；`rm` 经挂载删除后进入应用回收站（`GET /api/v1/files/trash` 出现 `originalPath: accept-dir/hello.txt`，非永久删除）；无目录授权的成员账号 DAV PROPFIND 被 405 拒绝。WebDAV 加固代码（固定根租约、逐级拒链接、暂存原子发布）首次在真实 Finder 客户端下通过基础读写。**仍缺**：Windows/Infuse、限速、中断/满盘/拔盘、公网 HTTPS 路径。
- [ ] **WebDAV 中断与换根（2026-10-26 补充）**：Finder/Infuse 覆盖期间断网、取消、满盘和拔盘，确认旧原件或明确可恢复副本保留；验证目录复制/移动、条件写入与锁，换共享目录后旧锁不影响新目录。临时目录及竞态测试不能替代真实客户端与实盘失败验证。
- [ ] **Cloudflare Tunnel**：现有 API Token 缺 `Tunnel:Edit` 权限——**需新建 Token 后**验证命名隧道创建/删除/域名绑定/断线告警/有限退避重启；含代理环境（argotunnel 放行）。
- [ ] **局域网 HTTPS**：自签证书指纹在 Flutter 端的首次钉扎流程与过期后行为。

## 数据安全（P0-02）

- [ ] **旧单根换盘权限边界**：真实客户端持续读写/索引/备份期间切换应明确忙碌；确认同一物理根重连保留授权，不同物理根及无法确认旧身份时先撤销旧授权/分享并提示结果；注入归档/根配置写入失败，验证错误反馈及原数据保留。已有临时目录、并发和数据库事务回归，不能代替外置盘验收。真实数据迁移尚未实现，完成条件另见 ROADMAP。
- [ ] **逐根计划备份（仅开发预览）**：可丢弃独立源盘/备份盘上配置每日/每周及保留数量，源/目标拔插、同路径替换、重启、停用/取消、坏计划单根隔离、换代不继承；核对 Mac 自动任务进度与最终结果。已有临时 provider/IPC/计划/保留与生命周期回归，尚无本批实盘证据；单根元数据直接激活仍未实现。
- [ ] **元数据恢复演练**：真实独立介质上执行一次账号/授权/私人相册元数据的备份→停止服务→恢复→验证。
- [ ] **Time Machine 覆盖核查**：外置数据卷确实纳入（或明确排除并警示）。
- [ ] **lightisle-recovery**：离线激活与元数据回退在干净用户账户下走通一次。

## 常驻体验（P0-04）

- [ ] **GUI 生命周期**：关窗留菜单栏、显式退出停 Core、登录项、注销/睡眠唤醒后的服务状态一致性。
- [ ] **升级预检**：从上一版本真实升级一次（含数据库迁移路径）。

## 通知外发（开发版 2026-10-26）

- [ ] **Bark 真机推送**：真实 iPhone 安装 Bark、配置设备 Key 后，磁盘告警/备份失败/下载完成事件推送到手机并在通知中心可见。
- [ ] 部分证据（2026-10-26，本机临时 Core）：`notify set`（base64 IPC）→ `LIGHTISLE_NOTIFY_ON`；`notify test` → 本地 Webhook 接收器收到完整 JSON（source/event/severity/title/body/timestamp）；把低空间阈值调至必触发后 60 秒监控周期内收到 `storage_low_space` 告警推送，severity/message 与告警表一致；内网/回环目标默认拒绝、`allowPrivateTargets` 显式开启后放行；连续失败 3 次进入 5 分钟退避。SSRF/退避/去重由 `core/internal/notify` 单测锁定（`go test -race` 过）。

## 发布门禁（P0-GATE）

- [ ] Developer ID 签名与公证；干净虚拟机安装启动。
- [ ] `scripts/verify-release-qa.py` 的真实硬件、5 GiB/10 GiB/72 小时检查项全量通过。

---

## 已验收

（暂无整条目。上表各节已积累"部分证据"行：真实工具测试（ffmpeg/aria2）、≥1 GiB 公网下载全生命周期与中断恢复、Finder 实际挂载 WebDAV、通知外发 Webhook 全链路均为 2026-10-26 本机真实环境取证；标记整条完成仍需该条目内全部场景（含需真实手机/外接盘/公网的场景）留证。）
