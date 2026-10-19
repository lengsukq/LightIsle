# LightIsle Design System — iOS 27 视觉语言

> **产品级强制规范（规划）**：macOS 原生 App、Web/PWA、Flutter Android 统一采用 Apple iOS 27 / macOS 27 设计理念与 Liquid Glass 视觉语言；**不**要求各端硬拷贝 iPhone 的导航方式。功能优先、清晰优先、低占用优先。
>
> 官方依据（以开发时最新 Apple HIG 为准）：[Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass) · [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)。Apple 官方指出：Liquid Glass 应主要用于**控制和导航**层，而非把所有内容卡片都做成玻璃。

## 1. 视觉原则

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
| **macOS App** | SwiftUI/AppKit 原生 NavigationSplitView、toolbar、系统 Material/Liquid Glass；仅管理初始化、系统、服务、共享目录 | 轻量原生侧栏 + 系统监控/配置区域；不内嵌文件/图库/影视页面 |
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

## 7. 开发实施顺序

1. M0：确定这份规范与 token 命名、基础设计样式。
2. M1：建立语义主题、SwiftUI 原生 App Shell、Vue Web Shell 与 Android 浏览器适配；完成概览页深浅色和 reduced transparency。
3. M2–M4：文件、图库、影视统一组件，不为每个模块单独写一套导航/弹窗。
4. M6：Flutter Android 映射同一语义 tokens，Android 手势/权限独立适配。
5. M7：跨端视觉回归、性能与可访问性门禁。

参考：[macOS App 生命周期](MACOS_APP.md) · [开发指南](DEVELOPMENT.md) · [性能](PERFORMANCE.md) · [路线图](ROADMAP.md)。

