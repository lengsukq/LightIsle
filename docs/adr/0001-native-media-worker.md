# ADR 0001：macOS 系统媒体 Worker

日期：2026-10-22。状态：已实施；仅 macOS arm64。

## 背景与决定

个人 NAS 需要正确显示手机照片方向和视频封面，并能说明原片的实际播放能力。Core 不应根据扩展名伪造编码信息，也不能为了查看私人素材自动下载解码器或外部媒体。

随应用分发 `lightisle-media-worker`，使用系统 ImageIO 和 AVFoundation。Go Core 管理每次短任务的生命周期；Worker 不提供网络服务、不读取数据库，也不接受任意源路径。FFmpeg、转码和外部元数据服务仍是独立的后续决策。

## 协议与资源边界

Core 使用子进程参数调用 `probe`、`thumbnail` 或 `poster`，源文件通过只读 fd 3 继承；`--name` 仅传 basename。生成操作接收 Core 私有缓存目录里的绝对 JPEG 输出路径，Worker 用 `O_EXCL | O_NOFOLLOW` 和 `0600` 创建，拒绝覆盖。源文件由 Core 经过共享根与权限检查后打开。

stdout 只输出一个 version=1 的 JSON 对象，包含 status、kind、mime、container、videoCodec、audioCodec、durationSeconds、width、height、orientation、capturedAt 和 error 的适用字段。成功退出 0；不支持也退出 0 并返回 unsupported；错误使用非零退出状态。Core 校验协议、字段与退出状态的对应关系，不把损坏素材当作缺失 Worker 回退。

- 单任务超时 20 秒，Core 内并行上限 2。
- stdout 上限 32 KiB，stderr 上限 4 KiB；不把日志作为协议解析。
- 照片生成最大边 512 像素、应用 EXIF 方向变换；视频封面最大边 640 像素，应用轨道变换。JPEG 输出最多 8 MiB。
- 照片沿用完整内容哈希和 64 MiB 源上限；照片和视频共用默认 1 GiB、可配置 256 MiB–8 GiB 的 LRU 派生缓存。方向渲染升级会使旧缓存失效。
- 视频通过基于 pread 的 AVAssetResourceLoader 按范围读取，不把整个电影复制到临时目录。资源加载请求取消后停止读取。
- 请求取消或超时终止子进程；Worker 另监测父进程，失去父进程后退出。应用的 Core 管道 EOF 生命周期保持不变。

默认只定位 Core 同目录的随包 Worker，显式覆盖须使用本地绝对路径；不搜索 PATH、不自动安装。Worker 不可用或明确不支持某照片格式时，照片缩略图才回退系统 sips。

## 结果与限制

真实容器信息用于 MIME 与保守的直放能力分类；界面区分可直放、可尝试和仅下载。一次媒体探测不等于所有浏览器/音轨均可播放。封面是原片截帧；尚未实现外部海报、侧载元数据和按需转码。

自动化覆盖本机构造的带方向 HEIC、真实 H.264 MP4、改扩展名、损坏媒体、排他输出、原件保留及 1 GiB 稀疏视频内存边界。浏览器实际验证了一个合成 H.264 样本。完整编码/设备矩阵、10 GiB 实片、1 万素材、强制退出和物理磁盘验收继续保留为未完成项。

主要实现：`apps/macos/Sources/LightIsleMediaWorker/main.swift`、`core/internal/mediaworker/`、`core/internal/gallery/thumbnail.go` 和 `video_thumbnail.go`。验收入口：`tests/test_media_worker.py`、`tests/test_personal_media_bundle.py`、`scripts/build-macos.sh`。
