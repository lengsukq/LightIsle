# 原生 Mac 界面实现与验收

日期：2026-10-28。范围为原生管理端；Web、Flutter 的配色输出和业务接口不在本轮改动范围。工作树原有其他修改保留。

## 本轮补充：连续画布与悬浮导航

按用户指定的 [Octopus](https://github.com/bestruirui/octopus) 桌面视觉调整原生实现：小型悬浮导航、同一窗口背景、较大圆角与柔和阴影、自适应入口卡片。保留 LightIsle Logo 和蓝青紫配色；参考只用于视觉关系，没有引入其前端代码、框架、图片或依赖。

移除原生分栏边线和内容分割线；`⌃⌘S` 展开或收起导航文字，展开后可拖动边缘调整宽度，辅助功能 Increment/Decrement 同样可用。系统窗口按钮、快捷键、滚动条、业务操作和窗口生命周期保留。卡片悬停抬起 2pt，导航选中块连续移动，入口卡片错峰淡入。减少动态效果停用位移、缩放与延迟。

本轮日志：`.build/floating-shell-debug.log`、`.build/floating-shell-release.log`、`.build/floating-shell-tests.log`。本机实窗已检查悬浮导航展开、辅助调整宽度（224→240pt）、浅深色、850×570 重排及 1440×900 宽窗。解锁后补查了深色下增强对比度、减少透明度和减少动态效果组合；连续切页仍只选中最后一个入口，正文滚动关闭详情且标题保持固定。仍使用隔离模拟数据，动画没有逐帧 FPS 验收。新截图前缀为 `floating-`，旧截图保留为改造前的验收记录。

发现窗口恢复会覆盖预览指定的大小，已在 Debug 隔离样例中首次显示时设置明确的外窗尺寸；正式窗口不受影响。重新拍摄的 850×570 和 1440×900 截图与指定尺寸一致。最小窗口收起导航时为双列，展开后为单列，滚动到底部可见最后三项。

## 已实现

- 六个主入口：概览、存储、网络与连接、Docker 与应用、个人空间、设置。保留原有 `⌘1`～`⌘9`，增加 `⌘,` 设置和 `⌘[` 返回详情入口。
- 原生窗口中的可调整、可收起悬浮导航；固定页面标题与独立内容滚动区。内容最大宽度受限，窄窗设置行上下排列。选择、详情和滚动记录随管理视图释放，Docker 分类和运行环境在切页返回后保留。
- 存储按磁盘、位置、容量、回收站、配置备份、Time Machine、跨盘操作拆分；连接按本机、局域网、Mac 文件共享、私人网络、Cloudflare、FRP 拆分。设置按六类组织，外部依赖和高级诊断放在工具中按需进入。
- 保留原 Logo，采用蓝、青、紫、靛点缀。实体内容表面、较轻边界和阴影；系统字体和统一间距。原生 `nativeMac` token 独立映射，生成器同时检查品牌色、状态文字和说明文字在五类内容表面的对比度不低于 4.5:1。
- 详情预览使用已有数据：450ms 出现、180ms 离开延迟；点击固定、Escape/外部点击关闭，一次一个，页面滚动及换页关闭。磁盘健康、容器日志和指标仍须明确打开详情后查询。
- 表单离开时提供保存、放弃、继续编辑；保存确认后才清空敏感输入，失败保留输入。Docker 未执行任务输入不会被“保存并离开”自动转换为部署或拉取。局域网开关、回收站规则显示等待与超时原因。
- 160ms 按压/悬停、约 280ms 展开、约 380ms 导航；侧栏选中背景连续移动，内容轻位移和淡入。减少动态效果停用弹簧/位移；减少透明度使用实体浮层，增强对比度加强边界。
- 普通页面读取主机摘要，高级诊断可见时才请求进程列表。原有轻量模式卸载界面、隐藏窗口降低采样和关闭窗口继续服务规则保留。预览延迟任务和滚动观察对象随视图释放。
- 修正截图反馈中的三个具体问题：镜像源菜单行异常撑高、纯说明行文本贴住分隔线、透明标题栏在滚动时叠字。说明文字另有高可读原生颜色，不继续使用偏淡的默认次级色。

实现入口：`ContentView.swift` 负责壳层，各 `ContentView+*.swift` 负责页面；`ManagementNavigation.swift`、`SidebarPage.swift` 负责类型化路由；`LiquidComponents.swift` 负责公共布局与表面；`ManagementShell.swift` 负责悬浮导航辅助、标题栏兼容和卡片进入动效；`DetailPreview.swift` 负责浮层和滚动记忆；`ManagementEdits.swift` 负责子页面草稿协调。业务操作继续使用现有 AppModel、HTTP 和 IPC 能力。

配置备份仍只保护配置、账号、权限和相册元数据；原片由独立备份工具保护。未把开发预览改成正式迁移，也未把 `enforcement=pending` 宣传为完整硬配额。

## 自动验证

以下检查在本机 Apple Silicon、macOS 27 上执行。Debug/Release 使用项目已解析的本地依赖，没有安装新工具或下载资源。

| 检查 | 结果与含义 |
| --- | --- |
| Swift Debug / Release | 两种配置编译通过；部署目标仍为 macOS 14，不代表已在 macOS 14 运行 |
| `scripts/sync-fluid-tokens.py --check` | 生成内容一致；浅深色共 80 组原生文字/表面对比度均至少 4.5:1 |
| `tests/NativePresentationCheck.swift` | 六入口和旧路由/快捷键、预览状态竞争/固定/取消、100 次协调器释放、实际延迟任务和有限数值校验通过 |
| 原生设置行测量 | 宽 490 / 780 / 1044pt；纯说明两行组高度 143 / 123 / 123pt，带菜单与按钮组高度 222 / 148 / 148pt；没有巨大空白或文字挤压 |
| `LightweightModePolicyCheck.swift` | 锁屏偏好、手动覆盖、可见 3 秒 / 隐藏或轻量 60 秒采样策略通过 |
| `ManagementWindowVisibilityCheck.swift` | 100 次隔离 AppKit 打开/隐藏/重开/关闭，窗口观察对象释放和多窗口可见性回归通过 |
| `tests/test_native_metrics_ipc.py` | 使用本轮从当前源码、本地缓存编译的 Core，摘要保留主机/卷信息，完整指标含进程列表，父管道关闭后退出；隔离临时目录通过 |
| `tests/test_brand_assets.py` | 品牌资源与原生初始化/凭据边界检查通过 |
| `git diff --check`、脚本语法 | 通过；生成的 Web CSS 没有本轮差异 |

最初误用了较早的本地 Core 测试二进制，摘要命令等待超时；随后从当前源码重新构建 `.build/lightisled-ui-check`，同一测试通过。没有以旧二进制的结果替代当前源码验证。

本地构建和界面回归日志位于 `.build/redesign-build.log`、`.build/redesign-release.log`、`.build/redesign-tests.log`、`.build/redesign-metrics-ipc.log`。未运行会覆盖整个项目的 `scripts/verify-macos.sh` 全流程；本轮单独执行与原生修改相关的检查。

## 实际窗口检查（隔离样例）

截图来自本机实际运行的 SwiftUI/AppKit 窗口，**数据是标明的静态样例，未连接真实 NAS、Docker 或远程服务**。预览只在 Debug 构建启用，不启动 Core；显示设置覆盖只影响预览窗口，没有改动系统偏好。启动时指定尺寸也仅用于 Debug 样例，避免窗口恢复影响截图标注。

本地[截图浏览页](../.build/design-previews/index.html)汇集最新截图，原图保留在 `.build/design-previews/`：

| 当前悬浮界面 | 证据 |
| --- | --- |
| 六个主入口 | `floating-overview-light.jpg`、`floating-storage-light.jpg`、`floating-connections-light.jpg`、`floating-docker-light.jpg`、`floating-spaces-light.jpg`、`floating-settings-light.jpg` |
| 窄窗收起、展开与滚动 | `floating-settings-850x570.jpg`、`floating-settings-850x570-expanded.jpg`、`floating-settings-850x570-scrolled.jpg` |
| 宽窗、深色、辅助显示组合 | `floating-settings-1440x900.jpg`、`floating-settings-dark.jpg`、`floating-accessible-dark.jpg` |
| 标题固定、展开导航 | `floating-overview-scrolled.jpg`、`floating-settings-expanded.jpg` |

以下为此前版本的状态和交互检查记录，保留用于复核具体问题：

| 检查 | 证据 |
| --- | --- |
| 此前版本：六个主入口、1120×730 | `overview-light.jpg`、`storage-light.jpg`、`connections-light.jpg`、`docker-light.jpg`、`spaces-light.jpg`、`settings-light.jpg` |
| Mac 文件共享说明行 | `sharing-detail-fixed.jpg`，标题、说明和分隔线留白恢复 |
| 850×570 最小外窗 | `docker-850x570-top.jpg`、`docker-850x570.jpg`，侧栏可读、标题完整、表单窄窗重排、内容可滚动 |
| 1440×900 宽窗 | `overview-wide.jpg`，内容保持阅读宽度 |
| 深色与辅助显示覆盖 | `overview-dark.jpg`、`accessible-dark.jpg`；后者同时覆盖增强对比度、减少透明度和减少动态效果 |
| 初始化、空、离线、失败、加载 | `setup-intro.jpg`、`setup-form.jpg`、`empty-storage.jpg`、`offline.jpg`、`service-failure.jpg`、`connecting.jpg` |
| 固定标题、详情和草稿提示 | `overview-scrolled.jpg`、`storage-preview.jpg`、`unsaved-edits.jpg` |

交互实际检查：

- 点击信息入口打开固定详情；Escape 关闭；对页面执行原生滚动后详情关闭。
- 快速切换多个入口后，以最后一次选择为准；旧快捷键与 `⌘,` 仍走统一导航。
- Docker 中填写 `https://example.invalid` 隔离草稿，尝试切页出现三选一提示；继续编辑保留原输入，放弃修改后到达目标概览。没有测试或写入该地址。
- 返回已浏览页面恢复到原阅读区域；滚动记忆按内容像素位置保存，滚动条比例会随重新布局后的内容高度变化。
- 实际窗口中的固定标题不随正文进入标题栏；三种窗口尺寸检查以实际窗口大小为准，而非只检查 Preview 布局。

部分原始截图受当前显示缩放影响在画布右侧/下方带空白，浏览页仅调整展示窗口范围，原始图片不作美化或重绘。

## 复现预览

```sh
swift build -c debug --disable-automatic-resolution
python3 -B scripts/preview-macos-design.py --name Preview
python3 -B scripts/preview-macos-design.py --name Narrow --width 850 --height 570 --page containers --docker 镜像源
python3 -B scripts/preview-macos-design.py --name Sharing --page services --connection 'Mac 文件共享'
python3 -B scripts/preview-macos-design.py --name Dark --appearance dark
python3 -B scripts/preview-macos-design.py --name Accessible --appearance dark --accessible
python3 -B scripts/preview-macos-design.py --name Offline --scenario offline
```

打开命令输出的 `.app`。另支持 `empty`、`setup`、`loading`、`failure`；`--storage`、`--connection` 接受界面中文标题，`--settings` 接受枚举键（如 `notifications`）。预览脚本仅复制本地已编译文件和现有 Logo，不下载资源。

## 尚未取得的真实环境证据

- 当前系统是 macOS 27；macOS 14 的实际运行和旧系统材质回退仍需对应设备检查。
- 未用真实外置盘做重连/换盘、SMART、恢复和容量不足实验；未更改真实管理员密码、Keychain、SMTP、Cloudflare/FRP 或 Docker 配置。样例错误状态不能证明这些外部操作的成功与失败回调均已验收。
- 已验证悬停协调器的真实延迟/取消和点击固定入口，尚未完成全部页面上连续指针快速进出、从按钮移入浮层、VoiceOver 朗读及全键盘焦点巡检。
- 已对主入口、代表性详情和状态进行运行窗口检查，不宣称所有外部依赖详情、所有中文长错误和每一种辅助显示组合都已逐项截图。
- 没有测量动画逐帧 FPS、Instruments 完整页面树、正式 App 与 Core 的连续轻量切换内存曲线或 24–72 小时稳定性。隔离窗口/协调器释放检查不等于完整产品内存验收。

以上限制属于验收证据边界，不能将编译或样例截图表述为正式安装包、真实数据与远程服务的全面验收通过。
