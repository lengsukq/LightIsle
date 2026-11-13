# LightIsle Beta 预发布交互与质量检查清单

> 审查日期：2026-11-10（最近复核：2026-11-13 Beta 发版前全端排查收口）
> 状态：**代码整改与自动化回归已完成（UX-001 至 UX-017 及 2026-11-13 全端角色隔离/权限边界/错误码契约/Clean Code 复核），真实物理盘与真机操作验收仍待执行**
> 范围：macOS 管理端、Flutter 客户端、Web 管理端及相关 Go Core 操作链路。
> 用途：记录 Beta 候选版发布前的交互缺口、修复标准与验收证据；此文件属于仓库正式文档，**必须纳入 Git 版本管理，不应加入 `.gitignore`**。

## 1. 发布判断与分级

LightIsle 的文件、照片、影视、账号、存储与备份等主要功能已经形成开发闭环，但**代码和单元测试通过不等于交互及真实设备发布验收通过**。对于家庭 NAS，必须优先保证涉及原始文件和账号的操作能够让用户明确知道：将发生什么、目前进行到哪里、哪些步骤成功、失败后如何恢复。

| 等级 | 发布策略 | 验收要求 |
| --- | --- | --- |
| **P0 / 阻断邀请 Beta** | 候选版必须修复 | 不崩溃、不误导操作结果、不造成身份或存储状态无法辨识；具备回归测试 |
| **P1 / Beta 前优先** | 首个邀请 Beta 建议修复；如暂缓必须限制暴露并明确说明 | 关键操作状态、错误和恢复入口完整，权限边界清楚 |
| **P2 / 体验优化** | 可纳入后续 Beta | 统一视觉、文案、交互与无障碍表现 |

## 2. P0：发布阻断项

### UX-001 成员创建与空间分配的“部分成功”没有可靠的用户恢复路径

- **涉及**：`core/cmd/lightisled/ipc_spaces.go` 的 `create-user`；`apps/macos/Sources/LightIsle/PersonalSpacesSheets.swift` 的 `CreateMemberSpaceSheet`；`apps/flutter/lib/features/settings/new_account_dialog.dart` 与 `accounts_page.dart`。
- **现状**：先创建账号、再分配目录。若分配失败，账号已存在，但 macOS/Flutter 没有统一展示“账号已创建、空间未完成”；macOS 创建弹窗提交后立即关闭。再次提交可能提示用户名已存在。
- **整改**：采用显式状态机（`CreationFlowState` / `AccountCreationPhase`：创建账号 → 分配空间 → 完成/分配失败可重试）；Go IPC `create-user` 在分配失败时仍返回含 `createdUser` 的最新 `result` 快照；分配失败时保留已创建账号 ID、锁定账号字段并提供“仅重试空间分配”与“先关闭（稍后分配）”动作，避免误导用户重复创建。
- **验收**：模拟“账号创建成功、目标盘离线/额度不足导致分配失败”；界面准确展示哪一步成功，重新分配可恢复且无重复账号；重复点击不会产生并发创建请求；提交期间弹窗不会自行消失。
- [x] 已修复　[x] 已补自动化回归（`TestHandleCreateSpaceUser_PartialFailureReturnsCreatedUserAndOverview`）　[ ] 已完成 Mac/Flutter 实际操作验收

### UX-002 macOS 配额整数换算缺少统一的溢出防护

- **涉及**：`apps/macos/Sources/LightIsle/SpaceInputValidation.swift`（`QuotaInputValidator`）、`PersonalSpacesManagementView.swift` 及 `PersonalSpacesSheets.swift`。
- **现状**：若将可解析但极大的 `Int64` 值直接转换为字节，Swift 整数乘法可能产生运行时溢出；部分无效输入无明确内联错误。
- **整改**：抽离纯函数验证器 `QuotaInputValidator.validateGiB(_:minimumBytes:)`，限制允许的 GiB 范围（`0–1,048,576 GiB`）并采用 `multipliedReportingOverflow(by: 1 << 30)`；无效时内联展示原因并禁止提交，若低于当前已入账+预占容量提前展示风险提示。
- **验收**：输入空值、负数、小数、超长数字、极大整数、0、边界值均不会崩溃或错误保存；覆盖建号、分配、修改三个入口及 Swift 自动化测试。
- [x] 已修复　[x] 已补自动化回归（`tests/SpaceInputValidationCheck.swift`）　[ ] 已完成界面验收

## 3. P1：关键流程交互闭环

| 编号 | 页面与代码位置 | 已确认的交互缺口 | 完成标准 | 状态 |
| --- | --- | --- | --- | --- |
| **UX-003** | Flutter `features/settings/automation_page.dart` | `_editingRevision` 声明并用于保存，但打开编辑时没有赋值。服务端虽能对缺省版本使用当前版本，客户端可能不能检测旧表单覆盖 | `_startEdit` 固定任务原始 `revision`，保存时带上；版本冲突提示并提供一键重新加载最新配置 | [x] 已修复 |
| **UX-004** | macOS `PersonalSpacesSheets.swift` 与 Flutter `storage_page_switch.dart` | 长任务主要显示已复制字节和阶段文案，不展示总量、当前文件与完整进度 | Go Core 响应补齐 `totalFiles`/`totalBytes`；以预检/复制/核验/等待确认/清理五阶段展示文件数与字节进度，不捏造百分比 | [x] 已修复（含 `SpaceInputValidationCheck` 与 Go 测试） |
| **UX-005** | Go `user_storage_transfer.go` 与 Flutter `storage_page_switch.dart` | 一次多阶段换盘可能多次弹出管理员密码确认 | 服务端签发绑定 `(session, userID, taskID)` 的 10 分钟内存一次性短期令牌 `confirmationToken`；`confirm_cleanup` 可复用该令牌免二次输密，绝不持久化密码 | [x] 已修复（含 Go & Flutter 测试） |
| **UX-006** | Flutter `file_batch_operations.dart` 与 `files_page_selection.dart` | 批量操作逐个请求，仅最终反馈成功数与失败路径，缺乏逐项进度和失败原因 | 显示实时 `X/Y · 当前文件名` 与“停止后续项”按钮；保留逐项失败原因并支持“仅重试失败项” | [x] 已修复（含 `file_batch_operations_test.dart`） |
| **UX-007** | Flutter `storage_page.dart` 的 `refresh` | 管理员逐成员串行拉取存储策略；单个成员错误可能导致全局失败 | 限制并发（最多 3 路）独立拉取各成员策略；单成员失败仅在该卡片内展示重试入口，不影响其他成员与 `rootsKnown` | [x] 已修复（含 `storage_multi_disk_test.dart`） |
| **UX-008** | macOS `PersonalSpacesManagementView.swift` 与 `PersonalSpacesSheets.swift` 的配额预设 | 点击“50/100/200 GiB”预设会直接调用 `setRootQuota`，不只是填入草稿 | 预设只更新草稿输入框，显示“草稿未保存”提示，用户点击“保存”后才提交 | [x] 已修复 |
| **UX-009** | macOS `CreateMemberSpaceSheet`（`PersonalSpacesSheets.swift`） | 创建过程缺少分步等待态；失败弹窗可能已关闭 | 与 UX-001 同步完成，弹窗交由显式状态机控制，展示分步进度、内联错误与“仅重试空间分配” | [x] 已修复 |
| **UX-010** | macOS `PersonalSpacesSheets.swift` 与 Flutter `storage_page_dialogs.dart` 换盘弹窗描述 | “收藏、私人相册和观看进度保留在原盘记录中”与部分媒体关联可迁移的实现表述不一致 | 按实际实现准确说明：已验证同内容的照片/视频自动迁移个人收藏、私人相册与观看进度；公开分享链接与文件夹相册共享将在切换后失效并列出受影响数 | [x] 已修复 |
| **UX-011** | Web `AppShell.html` / `UserStoragePanel.vue` 与管理端说明 | “Web 只读”的设计承诺与部分后端高风险管理 API 的授权范围需要一致；目前仅换盘 API 具额外密码验证 | 界面与文档如实说明 Web 端主动省略高危写入口、引导前往 Mac/Flutter 操作，且跨盘迁移由服务端强制管理员密码二次核验 | [x] 已修复 |

## 4. P2：易用性与一致性

| 编号 | 位置 | 建议与验收点 | 状态 |
| --- | --- | --- | --- |
| UX-012 | macOS 首次管理员表单 `ContentView+Setup.swift` | 用户名与密码提交前按后端规则实时校验（`AccountInputValidator`），明确指出不合法字符，按钮禁用理由可见 | [x] 已修复（含 `SpaceInputValidationCheck`） |
| UX-013 | macOS 换盘弹窗 `PersonalSpacesSheets.swift` | 固定宽度下主体改为 `ScrollView` + 底部固定操作栏，确保小窗口、大字体和较长错误/分享列表中按钮始终可访问 | [x] 已修复 |
| UX-014 | Flutter 传输任务 `upload_task_center.dart` / `upload_task_center_page.dart` | 正在传输或已有进度的取消动作增加确认弹窗，显示“正在取消并清理服务端临时分片…”，清理未确认时保留错误提示 | [x] 已修复 |
| UX-015 | Web 管理页面及确认逻辑（`ConfirmModal.vue` / `useConfirmDialog.ts`） | 全部 22 处 `window.confirm` 与 1 处 `window.alert` 统一替换为应用内 Liquid Glass 模态确认框，显示标题、影响范围与危险等级 | [x] 已修复（含 `useConfirmDialog.test.ts`） |
| UX-016 | macOS / Flutter / Web 文案 | 面向家庭用户优先用“普通文件与下载、照片、视频、成员专属空间”；`enforcement=pending`、`rootGeneration`、`Users/u<ID>` 转化为易懂中文加次要说明 | [x] 已修复 |
| UX-017 | 首次使用与无在线硬盘引导 | 在 macOS 与 Flutter 新建成员/分配空间弹窗中检测无在线存储硬盘状态，给出先仅建号或先去登记硬盘的可执行引导 | [x] 已修复 |

## 5. 必须补充的真实使用验收

以下是**测试清单，不代表已测试通过**；按实际 Beta 覆盖的平台执行并保存构建号、设备、日志/录像及结论。

- [ ] **首次使用**：干净 Mac 安装、首任管理员创建、没有注册硬盘时的下一步、首次家庭成员登录、局域网发现/手动连接及权限拒绝引导。
- [ ] **成员与配额**：至少 3 个成员跨两个物理盘分配；并行提交、部分成功、离线盘、超额度及越权场景；无重复用户和假成功。
- [ ] **原文件安全**：实际传输 5 GiB 及接近产品上限的文件，测试暂停/恢复/中断、满盘、源文件变化、硬盘拔插；核验 SHA-256，失败保持原件。
- [ ] **换盘**：两块真实物理盘分别测试空白切换、复制核验后清理、直接剪切、断电/退出后继续、分享授权及照片/影片元数据保留或失效提示。
- [ ] **备份与恢复**：明确“配置备份不含原始文件”；在真实设备执行配置恢复预览、离线应用、中断回滚、版本回退，并验证独立 Time Machine/其他原片备份可恢复。
- [ ] **媒体**：万张级相册首次索引、滚动缩略图/放大关闭、真实设备视频/字幕切换，Android 后台与 iOS 前台照片备份的失败与遗漏清单。
- [ ] **交互视觉**：macOS 最低支持系统与当前系统、不同窗口尺寸/动态字体、浅色与深色、键盘与辅助功能导航；Flutter 手机小屏和 Web 移动浏览器。
- [ ] **运行与发布**：保留 Mac mini 已有的连续运行反馈，但仍需对**本次候选构建**独立收集稳定性及设备 QA 证据。对外分发遵循 `docs/PRODUCTION_RELEASE.md` 的签名、公证与 Gatekeeper 条件。

## 6. 验收与提交规则

1. 每项整改应更新本页状态，并附对应测试名/实测证据；未验证的一律保持 `[ ]`。
2. 涉及存储、权限、恢复的 P0/P1 变更需覆盖错误路径和重启路径，不能只测成功路径。
3. 修复时优先复用已有 UI 组件，避免另建一套不一致的确认框、任务提示或错误映射。
4. **不要为赶 Beta 随意移除已有安全校验、跨根隔离、配额验证或原文件保护。**
5. 本文档用于整改跟踪；真正的发布判定仍应以 `docs/PRODUCTION_RELEASE.md` 与 `docs/DEVICE_ACCEPTANCE.md` 的真实证据为准。

## 7. 本次审查的事实边界

上述 UX-001、UX-002、UX-003、UX-006、UX-007、UX-008、UX-010 具有直接源码依据；其余更多属于交互完善建议或需要真实设备复现的体验风险。**记录不等于修复**，不能因为本文档被提交就把待办勾为完成。已有的自动化测试通过也不能替代用户操作验收。
