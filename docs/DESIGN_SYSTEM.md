# LightIsle Design System — iOS 27 视觉语言

> **产品级强制规范（规划）**：macOS 原生 App、Web/PWA、Flutter Android 统一采用 Apple iOS 27 / macOS 27 设计理念与 Liquid Glass 视觉语言；**不**要求各端硬拷贝 iPhone 的导航方式。功能优先、清晰优先、低占用优先。
>
> 官方依据（以开发时最新 Apple HIG 为准）：[Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass) · [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)。Apple 官方指出：Liquid Glass 应主要用于**控制和导航**层，而非把所有内容卡片都做成玻璃。

## 1. 视觉原则

**固定品牌标识**：以 `scripts/generate-brand-assets.swift` 为唯一图形定义，使用「灵光晶屿与静海之澜」极简棱镜浮岛与 Apple HIG 标准连续超椭圆基底，统一输出 Mac App `.icns`、SwiftUI PNG、Web SVG/favicon、移动端主屏图标。原型中的临时系统符号已不再作为正式 Logo。品牌颜色/形状禁止在其他页面手工复制。详见 [Logo 规范](../assets/brand/README.md)。

1. **内容为主、系统层漂浮**：照片、文件、电影海报为主体；导航栏、工具条、搜索浮层、底部 Tab 等允许有限玻璃效果。
2. **浅色/深色完整适配**：支持跟随系统以及手动选择；颜色用语义 token，而非散落在组件的十六进制颜色。
3. **圆润、轻盈、层级明确**：连续圆角风格、细腻分隔线、克制的阴影与动画；不叠加高强度磨砂。
4. **跨端同一品牌，不同操作习惯**：视觉一致，Mac 鼠标/键盘优先，Android 触控/返回优先，Web 支持鼠标与触控。
5. **运动为反馈，不为装饰**：悬停、点击、过渡、任务状态和界面切换有轻反馈；尊重减少动态效果设置。
6. **可读性和性能优先**：高对比文字、可见焦点、触控面积足够，低性能设备减少实时模糊和复杂背景。

## 2. Token 方案（首版设计目标，真机验收后可调整）

统一以 [design-tokens/tokens.json](../design-tokens/tokens.json) 为语义单源（已创建初版草案），工程实施后生成 Web CSS 变量、SwiftUI 映射、Flutter ThemeExtension。**不要维护三套数值各不相同的手工主题。**

| 类别 | Token | 初始定义 / 规则 |
| --- | --- | --- |
| 颜色 | `surface.base`, `surface.raised`, `surface.glass` | 根据深浅色与系统对比度动态映射 |
| 文字 | `text.primary`, `text.secondary`, `text.disabled` | 必须通过背景对比测试 |
| 强调色 | `accent.primary` / `accent.muted` | 品牌色可调；不得取代风险语义色 |
| 风险色 | `semantic.success/warning/error` | 状态颜色与图标/文字配合，不能仅依赖颜色 |
| 间距 | `space.{1,2,3,4,6,8}` | 4、8、12、16、24、32 pt 基础比例 |
| 圆角 | `radius.{sm,md,lg,xl,pill}` | 8、12、16、24、9999；根据系统原生控件调整 |
| 轮廓 | `stroke.subtle` | 高对比模式提升边界 |
| 触控尺寸 | `control.touch.min` | 约 44 × 44 pt/dp 的移动端目标；Web 可按设备输入模式适配 |
| 动效 | `motion.fast/normal` | 约 120–180ms / 200–280ms；尊重系统减少动态效果 |
| 字体 | `type.body/title/caption` | Dynamic Type / 系统字体与 Android 默认字体兼容中文，禁用固定过小字号 |

表中数字为项目自定初始规范，**不是声称 Apple iOS 27 官方给出的固定尺寸**。

## 3. 玻璃层的使用边界

**应该用于：**
- Mac 工具栏、侧边栏的系统允许位置和浮动搜索/操作栏。
- Web/Android 的顶层导航、底部 Tab、浮层操作菜单与少量主操作按钮。
- 图库、影视全屏查看时覆盖在内容之上的播放/导航控件。

**不应该用于：**
- 所有文件行、相册缩略图、电影海报、统计表格、正文面板。
- 多层玻璃叠加、整个页面背景强模糊、大面积实时 backdrop-filter。
- 可能降低对比度的报警与确认框。
- 长时间保持渲染的不可见 App 窗口和后台页面。

材质等级建议：
- `standard`：所有主内容区，默认不做 blur。
- `glass.regular`：导航/侧边栏/模态操作层，保证文字可读。
- `glass.clear`：仅摄影/视频等内容背景下的轻量浮动控件，并进行对比度保护。
- `opaqueFallback`：减少透明度、高对比、旧系统或性能降级模式。

## 4. 不同平台如何落地

| 平台 | 实现 | 交互结构 |
| --- | --- | --- |
| **macOS App** | SwiftUI/AppKit 原生窗口、悬浮导航、toolbar 与系统材质；仅管理初始化、系统、服务、共享目录 | 轻量原生侧栏 + 系统监控/配置区域；不内嵌文件/图库/影视页面 |
| **Web/PWA** | Vue 3 + CSS 变量、少量 backdrop-filter、容器查询与媒体查询；不强依赖大型特效 UI 框架 | 宽屏侧栏；窄屏底部导航/抽屉；支持鼠标与触控 |
| **Flutter Android** | Material/App 容器之上应用自定义统一 token 与玻璃语义组件；优先 Flutter 内置组件，按需 Clip/BackdropFilter | 底部导航、系统返回、手势、键盘弹出和权限弹窗遵从 Android 习惯 |

- **原生 Mac 与 Web 不重复业务组件**：Mac 原生管理端和 Web 用户端分别维护符合自身功能的导航；共享品牌与设计 tokens，而非互相嵌套 WKWebView。
- macOS App 原生窗口使用实际支持平台的系统材质，不以 Web CSS 伪造整个原生系统窗口。
- Android 仿效 iOS 27 质感而非“强制 iPhone 手势”，系统返回、通知、文件访问权限都遵从 Android 规范。
- 不直接复制 Apple 商标、私有图片资源或不受许可的字体文件。

## 5. 组件清单与统一交互语义

首先定义下列跨端组件与状态：
- `AppShell`、`Sidebar`、`BottomTabBar`、`TopToolbar`、`GlassSearch`；
- `SurfaceCard`、`StatusBadge`、`ProgressTask`、`FileRow`、`PhotoTile`、`MoviePoster`；
- `ConfirmDialog`、`ActionSheet`、`ContextMenu`、`Toast`、`EmptyState`、`ErrorState`、`Skeleton`；
- 表单控件（Button、TextField、Select、Toggle、Slider、Segmented）、图标和快捷动作。

每个组件必须定义：`idle`、`hover/focus`、`pressed`、`loading`、`disabled`、`error` 状态，以及浅/深主题、减少透明度、键盘与触摸交互。危险按钮不得依赖红色玻璃外观来表达风险，必须写清操作名称及后果。

### 各业务模块建议

- **概览**：服务状态、磁盘与网络指标作为简洁实体卡片；关键错误可被直接识别。
- **文件管理**：Mac/大屏提供树状侧栏、列表/网格、拖放、多选；Android 提供底部操作栏、长按多选、面包屑/目录返回；不使用透明文件行。
- **图库**：密集照片网格与时间线、极少遮挡主体的浮动导航；全屏查看控制栏可用玻璃。
- **影视**：沉浸式海报墙、清晰字幕与播放器、易读播放进度；播放时隐藏不必要的磨砂层。
- **系统/硬盘**：监控图表与危险操作区域优先高对比和稳定布局，避免装饰性材质影响阅读。
- **Docker/应用中心**：与其他模块统一图标、间距和操作语义，不额外复刻另一套 UI。

## 6. 性能与可访问性验收

- 启动时不预渲染全部页面；重列表虚拟化与 lazy loading，影视海报与照片用尺寸合适的图像源。
- 大面积实时玻璃不得造成明显 CPU/GPU 占用或掉帧；Web 可自动退化为半透明纯色层或不透明背景。
- 遵守 macOS Reduce Transparency、Increase Contrast、Reduce Motion；Web 遵守 `prefers-reduced-motion` 和 `prefers-reduced-transparency`（有支持时），并有 App 级手动开关；Flutter Android 监听系统无障碍与减少动画设置。
- 对文字、图标与危险操作进行 WCAG AA 对比度检查；完整键盘导航、焦点可见、屏幕阅读器标签。
- Android 中等性能机和 Apple Silicon Mac 实机分别测试文件长列表、图库千图滚动和影视播放。
- 记录 **Mac SwiftUI App + Go Core + 按需 Swift/FFmpeg** 的内存总账；Web 用户界面的浏览器渲染进程单独测量。不能为了玻璃特效牺牲轻量目标。
- 对视觉回归使用截图基准：Mac 亮/暗、Web 桌面/手机宽度、Android 亮/暗、无动画/不透明模式。

## 7. 设计系统维护与验收

1. 设计 Token 以 `design-tokens/tokens.json` 为统一语义源；同步 Mac、Web、Flutter 映射时核对颜色、对比度、文字缩放与高对比模式。
2. Mac 使用系统材质与原生导航，Web 和 Flutter 复用设计语义但分别满足键盘、触摸、返回手势与平台辅助功能。不要为了视觉统一建立冗余的第二套业务组件。
3. 任何新增页面都需核对浅/深主题、减少透明度/动态效果、边界和错误/加载状态，并记录真实设备上的滚动帧率与资源变化。
4. 代码级实现进度见 [STATUS](STATUS.md)，当前任务与真实设备验收分别见 [ROADMAP](ROADMAP.md) 和 [ACCEPTANCE_DEBT](DEVICE_ACCEPTANCE.md)，不再维护过期的 M0–M7 阶段清单。

参考：[macOS App 生命周期](MACOS_APP.md) · [开发指南](DEVELOPMENT.md) · [性能](PERFORMANCE.md) · [路线图](ROADMAP.md)。

## 8. macOS 管理端：品牌色与原生层次（2026-10-28）

本轮按用户后续反馈采用更活泼的蓝、青、紫点缀，而非全灰外观。颜色来自现有晶屿 Logo 的色系；Logo 图形本身保持原样。

- **单源、分平台输出**：`design-tokens/tokens.json` 的 `nativeMac` 保存原生浅深色、品牌色、圆角与动效值；`scripts/sync-fluid-tokens.py` 生成 Swift 映射。Web CSS 输出保持原值，Flutter 映射不受本轮影响。
- **六入口**：概览、存储、网络与连接、Docker 与应用、个人空间、设置。文件/照片/影院属于个人空间详情，外部依赖属于设置工具。旧 `⌘1`～`⌘9` 定位对应页面，`⌘,` 进入设置；菜单通过同一草稿保护入口导航。
- **连续画布与悬浮导航**：按用户指定的 [Octopus 桌面界面](https://github.com/bestruirui/octopus#-screenshots) 与 Apple Liquid Glass / iOS 视觉规范融合空间关系。窗口框架、标题和内容共享带柔和主题色散射光晕（`IsleFluidBackdrop`）的连续背景；悬浮侧边导航栏与底部状态胶囊采用 `IsleGlassBarSurface`（`.ultraThinMaterial` 半透明毛玻璃 + 顶部高光折射边 Specular Rim + 柔和浮动阴影），默认悬浮图标导航，`⌃⌘S` 展开文字标签，展开态与宽度跨重启持久化。卡片采用顶光渐层表面、连续曲率圆角（`.continuous` Squircle）、1px 晶体高光描边与组内 iOS Inset-Grouped 内缩细分隔线；`AppleSettingsRow` 完整应用各业务行的彩色 `iconTint` 圆角图标底座；减少透明度或增强对比度开启时自动切换为实心高对比表面与清晰边框。页面标题固定，正文仍单独裁切滚动，窗口控制区不与内容重叠。
- **颜色层次**：蓝色连接与概览、青色存储、紫色个人空间与设置、靛色应用；选中背景、功能图标和指标使用品牌色，正文使用系统主文字与独立的高可读说明文字色；品牌色、状态文字与说明文字在原生四种内容表面上的对比度由 token 生成器检查（至少 4.5:1）。内容为实体表面，导航/短浮层按系统材质呈现。
- **表单布局**：公共 `SettingsRowLayout` 按可用宽度与操作区实际尺寸选择横排或上下排列。菜单有明确的固有行高；纯说明行和空右列同样参与测量，不用 GeometryReader 修改行宽状态。
- **详情预览**：约 450ms 悬停出现、180ms 离开关闭；移入浮层保留，点击固定，Escape/外部点击关闭。一次仅显示一个；滚动、换页、退出取消延迟任务。信息按钮提供键盘和 VoiceOver 入口，重要错误和恢复操作始终可见。
- **操作反馈**：显式保存的表单支持保留失败输入和离开保护；等待实际保存确认后才清空敏感字段。Docker 中尚未执行的任务输入提示用户完成任务或放弃，不能把“保存草稿”当作自动部署/拉取。连接、回收站规则有等待与超时提示。
- **运动**：悬停/按压约 160ms、展开约 280ms、导航约 380ms；悬浮导航选中块连续移动，卡片悬停抬起 2pt，入口卡片以 35ms 间隔短暂错峰进入。动画由视图状态驱动，可被后续操作打断；减少动态效果关闭位移、缩放和延迟，仅保留短淡入。背景保持静态，不使用持续动画或模糊。
- **诊断按需**：概览只显示主机摘要。进程列表仅在设置→工具→高级诊断可见时请求，沿用已有 `stats` / `stats summary`；隐藏窗口与轻量模式仍保留原有健康采样节奏。

验收证据、预览命令和实际未覆盖范围见 [原生界面验收](MACOS_APP.md#原生界面与回归)。截图是本机实际 SwiftUI 窗口、使用标注的隔离样例，不是实际外置盘或远程服务验收。

## Flutter 用户客户端映射（2026-10-23）

Flutter 复用本文件及 `design-tokens/tokens.json` 的 Fluid Surface 语义，生成入口为 `scripts/sync-flutter-tokens.py`，输出 `apps/flutter/lib/core/generated_isle_tokens.dart`。`IsleSurface`、`IslePageHeader`、`IsleCanvas` 和 `buildIsleTheme` 统一全页面内容卡片、导航、表单、按钮和弹窗；不另设第三套颜色源。

窄屏使用底部导航，宽屏使用侧栏；低高度窗口避免侧栏拥挤。响应式布局按可用空间与文字缩放决定换列和换行，内容设最大宽度。详情页标题和关闭操作固定，媒体与元数据单独滚动。系统浅深色与高对比优先；静态柔和背景和实体内容面板减少动态与透明度对可读性的影响。Flutter 对应的实现与验收见 [Flutter 客户端](FLUTTER_CLIENT.md)。

### Flutter / macOS 视觉对齐（2026-11-02）

Flutter 独立用户客户端与 SwiftUI 管理端共享 **Logo、蓝/青/紫语义色、内容优先的实体卡片、克制的悬浮导航、浅深色和密度规则**；不复制 Mac 管理端的本机 Docker、格式化、证书等宿主操作。适配采用业务窗口的**实际可用宽高**，不能把外层桌面显示器宽度当作页面宽度。

**第二轮已落地（同日）**：不再仅用与 Mac 相近的独立 Flutter 蓝白色板。Flutter 生成器从 `design-tokens/tokens.json` 的 `nativeMac.light/dark/surface` 生成 `IsleTokens.nativeLight/nativeDark` 与 Mac 相同的画布、品牌蓝/青/紫/靛、卡片和圆角。公共 `IslePalette`、`IsleSurface`、`IsleCanvas`、`IslePageHeader`、`IsleAdaptiveGroup` 同时覆盖五个主页面和二级页；Mac 式「家里的 Mac」设备摘要卡在宽屏优先，手机先显示个人空间快捷入口。Mac 客户端标题/侧栏更紧凑，手机仍遵从本机底栏与触控习惯。

**移动端内容层**：短屏、高倍字号优先显示操作和状态，详细的非错误说明使用 `IsleHelpDisclosure` 折叠；**错误、权限后果和破坏性确认不可折叠或省略**。地图屏顶部参数和来源配置可展开、独立滚动，地图/空状态保有剩余高度；目录授权、存储说明、离线照片说明、异常/审计介绍同样采用紧凑层级。全局深浅色取色值自同一生成源而不是各页面自行配制。

| 场景 | Flutter 规范 | SwiftUI 对齐点 |
| --- | --- | --- |
| 手机和窄窗 | 四主栏底部导航（仪表盘、相册、影视、设置）与内嵌快捷工作台；320px 与大字号下只保留图标、完整 tooltip/语义；键盘弹出时让出底部空间 | 操作优先、导航不遮挡输入 |
| 平板 / Mac 客户端 | 符合宽高阈值时浮动侧栏，默认 72px 图标模式；足够宽时允许展开文字，收起后保留当前页；支持顶层 52pt 统一工具栏避让交通灯 | Mac 连续画布 + 可收起悬浮导航，但不强制复制 SwiftUI |
| 工具栏 / 表单 | 按内容剩余宽度和字号切换按钮文字/图标；大字号时**危险操作仍有文字确认**，不隐藏关键入口 | Mac 表单在窄窗自动换行 |
| 图库 / 影院 | 图片为主；有真实照片/海报数据时按屏宽重排，影视卡片底部为文字缩放预留高度 | 不叠加背景大玻璃层；状态和播放能力可识别 |
| 无障碍 / 性能 | 高对比、减少动画时浮动栏和危险确认框自动用不透明背景且不进行实时模糊 | 尊重 Mac Reduce Transparency / Motion 的降级原则 |

本轮以 **320×568、600×840、1024×480、1280×800、1920×1080** 及 1×/2× 字号的壳级回归，另以 320/600/1280 的**真实条目模拟数据**验证照片/影院滚动；还检查下载、分享、任务历史、账号安全、告警/审计、WebDAV、账号、目录授权、存储、上传维护等 11 种二级页面在窄屏 200% 字号与桌面下的布局，修复目录授权硬盘下拉菜单溢出。代码级回归不代表 Android/iOS 实机键盘、VoiceOver/TalkBack 或 GPU 材质性能已验收。测试入口：`apps/flutter/test/layout_alignment_test.dart`、`responsive_shell_test.dart`、`media_responsive_content_test.dart`、`secondary_responsive_test.dart`；真实设备门禁见 [DEVICE_ACCEPTANCE](DEVICE_ACCEPTANCE.md)。

第二轮扩展至 **16 类二级页面 × 5 组窗口/字号**（含 320×568 的 100%/200%、375×812、600×840、1024×700）、四种常见对话框 × 3 组窗口/字号；壳级保留四主栏浅深色与导航切换回归，同时生成主页面和二级页面的本机视觉截图用于人工比对。对播放器复杂状态、软键盘真实弹出、多语言/超长路径和实际外接盘权限尚未做完整真机截图，验收状态不可因此改为完成。

## 普通用户界面与文案规范（2026-10-28）

**LightIsle 是个人家庭 NAS，不是运维控制台。** Mac、Web、Flutter 三端新增或修改用户界面时遵守以下规则：

1. **先说明用户能做什么**：标题以「连接其他设备 / 照片地图 / 下载中心 / 系统文件共享」为主，不把 Bonjour、mDNS、Go Core、PID、Web Mercator、API 请求等实现术语放进页面标题。功能使用或认证确实需要的协议、Key、证书、WebDAV 等词可以保留，首次出现时用一句话解释用途。
2. **一个设置只保留一个入口**：局域网自动发现是底层能力，跟随「允许其他设备连接」自动启停。Mac 服务页面已去掉两块重复的 Bonjour 状态卡，但没有删除原有发现服务和安卓/iOS 查找功能。所有端共用 Mac 配置的业务端口（默认 16666），不要另加局域网随机端口设置。
3. **状态写结果，不写内部机制**：「正在读取」「已连接」「未找到设备」「无法读取位置」优于「等待采样」「核心已就绪」「广播成功」「错误码 403」。状态无法确认时显示「未知 / 尚未检查」，不得把检测到端口说成已正确配置系统共享，不把统计值正常等同全部系统健康。
4. **短句优先，可操作的下一步紧跟错误**：正文通常一到两句，按「发生了什么 → 对用户影响 → 下一步（重试 / 去 Mac 开启 / 检查连接）」排列。原始错误码、路径、技术细节需要时放在可选的诊断详情而不是普通用户主视图；不要吞掉有用的故障原因。
5. **危险操作保留完整风险提示**：HTTP 非加密、删除、硬盘格式化、撤销凭据、重置、外网暴露等仍需明确后果和确认；不能以简化为由删除认证、证书指纹核对、权限校验或容量限制。地图需要说明第三方可能收到访问 IP 和浏览范围，照片原件不发送。
6. **跨端词汇保持一致**：统一称「连接地址」「连接验证信息」「允许其他设备连接」「地图设置」「重新检查」「保存位置」「剩余空间」「文件服务内存」。Mac 仅负责系统与服务设置，Flutter/Web 不重复展示不必要的 Mac 运维控件。
7. **逐步展示高级功能**：常用页面只有核心操作、当前状态和简短帮助；复杂的网络协议、第三方服务、外部依赖、诊断信息留在相应的高级页面或展开区域。不要新增“页面内教程长文”来替代良好的标题与可理解错误。

**本轮已调整**：Mac 服务/连接/端口/系统文件共享文案、重复 Bonjour 卡片；Flutter 自动发现/登录安全提示/照片地图；Web 设备状态/文件检索/下载/分享/照片地图。尚未完成全系统逐页的真实设备视觉验收，后续新增功能和页面需按此规范持续检查。

**后续可继续审查**：Mac Cloudflare/FRP/磁盘管理等高级操作说明是否过长；Flutter WebDAV 与成员存储说明；Web 系统告警与自动化的错误处理和长表单；Android 小屏、多语言、系统大字体、Mac 最小窗口的真实设备可用性。优先通过测试验证信息层级、空状态和按钮可触达性，再做视觉截图回归。
