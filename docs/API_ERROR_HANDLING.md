# API 错误契约与恢复提示

> 适用于 Go Core、Flutter、Web 以及基于 RootRegistry 的媒体/存储操作。与 [真实设备验收清单](DEVICE_ACCEPTANCE.md)、[功能状态](STATUS.md) 配合使用。此文档是代码设计规范，不代表生产环境及全部真机已部署/验收。

## 一条失败响应必须说明三件事

1. **发生了什么**：后端返回稳定机器码，如 `default_root_not_configured`、`volume_offline`、`file_permission_denied`、`offset_mismatch`，不要只返回 HTTP 503 或异常堆栈。
2. **用户能做什么**：消息明确区分设置默认硬盘、原盘重新连接、登录、申请写入授权、检查上传进度、稍后刷新，不要统一建议“重启 NAS”。
3. **如何排查**：在合适位置提供安全的 `HTTP 503 · default_root_not_configured` 供用户反馈，不暴露请求 URL、Cookie、Access Token、文件真实绝对路径、密码或任意响应文本。

Core API 已识别的错误使用 `{"error":"stable_code"}` JSON（非文件下载本身）；HTTP 状态表达 HTTP 语义，不能代替错误码。未知 5xx/网关响应可能是 HTML，此时客户端仅显示「服务器未提供可识别原因」，不能伪造硬盘离线。

| 类型 | 示例代码 | 实际说明 / 可操作步骤 |
| --- | --- | --- |
| 存储初始化 | `default_root_not_configured` | Mac「数据与存储 → NAS 存储空间」登记并选择在线默认根。禁止自动选取其他硬盘 |
| 存储离线 / 身份变化 | `root_unavailable` / `volume_offline` / `root_generation_changed` | 核实并重连**原硬盘**，重新选择根；禁止旧请求写入新根 |
| 服务初始化 | `gallery_unavailable` / `database_not_ready` / `storage_registry_unavailable` | 核对相应服务或数据库，并允许重新刷新；不能笼统提示硬盘故障 |
| 安全 / 授权 | `authentication_required` / `file_permission_denied` | 重登或联系管理员检查原目录 ACL |
| 安全请求格式 | `request_header_required` / `cross_origin_request_rejected` | Core 坚持拒绝请求，前端应指导更新客户端或检查源地址，**不得为了通过请求关闭 CSRF/Origin 验证** |
| 文件 / 配额 | `file_not_found` / `storage_quota_exceeded` / `insufficient_storage_space` | 刷新、核对目标或清理相应磁盘空间 |
| 上传状态 | `offset_mismatch` / `upload_outcome_uncertain` / `storage_accounting_uncertain` | 仅明确偏移冲突才能安全重新读取进度；不确定是否写入的任务必须先核对，不能直接重传/覆盖 |
| 网络 / 未知状态 | `network_timeout` / HTTP 502/503/504 无有效 JSON | 指出连接/网关/响应问题，提供重试与可用的诊断标识；不猜测某块盘损坏 |

## 客户端实现边界

- **Flutter**：`LightIsleApiException.code`、`statusCode` 是诊断真值；`toString()` 只含安全用户描述，不得通过解析它获取 `error` 代码。`userFacingError` 和 `mediaErrorLabel` 应优先区分具体错误码。文件管理/图库使用 `errorDiagnosticLabel` 显示可复制的故障信息。
- **Web**：普通 HTTP 失败通过 `apiClient.ts` / `apiFailure.ts` 构造经过正则校验的 `code + status`；再由 `userFacingError.ts` 翻译成行动指导，避免独立页面写 `new Error("HTTP " + status)`、`String(error)` 或 `JSON.stringify(response)` 代替错误处理。RootRegistry 异步结果必须继续按根 ID/代际取消，不能因改造消息层破坏请求隔离。
- **后端**：`securityHeaders` 对受保护 API 的跨源/缺少自定义请求头返回 403 JSON 机器码；浏览器表单/WebDAV 的例外条件未放宽。其他可检出的存储/媒体/API 异常继续使用已定义机器码。
- **恢复动作**：只有明确 `offset_mismatch` 的上传 409 可以重新读取旧任务进度。ACL、存储绑定、跨根、写入结果不确定、身份变更必须停止，等用户检查后再操作；绝不自动替换另一根硬盘。

## 回归命令

```text
npm test --prefix apps/web
npm run build --prefix apps/web
cd apps/flutter && flutter test --no-pub
cd apps/flutter && flutter analyze --no-pub
go test ./core/...
git diff --check
```

特别覆盖：Core 403 安全拦截确实阻止写操作且返回 JSON、真实 HTTP 503 `default_root_not_configured` 传到 Flutter、Web 根发现不吞掉服务码、恶意/非 JSON 响应不泄露原文、错误重试成功后旧警告清除。真机 UI、NAS 环境部署及物理双硬盘仍需独立记录。
