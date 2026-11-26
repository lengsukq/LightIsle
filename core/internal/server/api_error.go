package server

import (
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/diagnostics"
)

// APIError is the unified, backward-compatible error envelope returned by
// LightIsle Core JSON HTTP endpoints.
//
// Existing clients continue reading "error" (stable machine error code);
// clients can also directly display message, dataSafe and nextAction without
// duplicating translation tables across Web/macOS/Flutter.
type APIError struct {
	Error      string `json:"error"`
	Message    string `json:"message,omitempty"`
	DataSafe   *bool  `json:"dataSafe,omitempty"`
	NextAction string `json:"nextAction,omitempty"`
}

type apiErrorGuidance struct {
	message    string
	dataSafe   bool
	nextAction string
}

var apiErrorCatalog = map[string]apiErrorGuidance{
	"authentication_required": {
		message:    "登录状态已失效或尚未登录。",
		dataSafe:   true,
		nextAction: "请重新登录后继续操作。",
	},
	"admin_only": {
		message:    "此操作仅限管理员执行。",
		dataSafe:   true,
		nextAction: "请使用管理员账号登录，或联系家庭管理员协助处理。",
	},
	"file_permission_denied": {
		message:    "当前账号没有该目录或文件的访问权限。",
		dataSafe:   true,
		nextAction: "请联系管理员在「成员与空间」中确认目录授权。",
	},
	"permission_denied": {
		message:    "Mac 系统或存储目录权限不足，无法完成此次操作。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端检查外置磁盘与目录读写权限后重试。",
	},
	"request_header_required": {
		message:    "请求缺少必需的应用安全校验头，已被拒绝。",
		dataSafe:   true,
		nextAction: "请刷新页面后通过 LightIsle 正常界面重新提交。",
	},
	"cross_origin_request_rejected": {
		message:    "检测到跨站来源请求，出于安全考虑已拦截。",
		dataSafe:   true,
		nextAction: "请直接从 LightIsle 正常访问地址打开页面后重试。",
	},
	"method_not_allowed": {
		message:    "该接口不支持当前的请求方式。",
		dataSafe:   true,
		nextAction: "请更新客户端或通过正常页面操作重试。",
	},
	"invalid_request": {
		message:    "请求参数格式有误或缺少必要字段。",
		dataSafe:   true,
		nextAction: "请检查输入内容后重新提交。",
	},
	"too_many_attempts": {
		message:    "短时间内尝试次数过多，已暂时限制。",
		dataSafe:   true,
		nextAction: "请稍等片刻后再重新尝试。",
	},
	"current_password_invalid": {
		message:    "当前密码不正确，未修改任何账号信息。",
		dataSafe:   true,
		nextAction: "请核对当前密码后重新输入。",
	},
	"invalid_new_password": {
		message:    "新密码不符合安全长度或格式要求。",
		dataSafe:   true,
		nextAction: "请设置至少 12 位的新密码后重试。",
	},
	"user_not_found": {
		message:    "未找到对应的家庭成员账号。",
		dataSafe:   true,
		nextAction: "请刷新成员列表后确认目标账号。",
	},
	"protected_account": {
		message:    "受保护的管理员账号不能通过此入口修改。",
		dataSafe:   true,
		nextAction: "请由该管理员本人登录后修改，或在 Mac 本机管理端处理。",
	},
	"password_reset_failed": {
		message:    "重置成员密码失败，原密码保持不变。",
		dataSafe:   true,
		nextAction: "请稍后重试，若持续失败请检查 Mac 存储空间与服务状态。",
	},
	"database_not_ready": {
		message:    "账号与配置数据库尚未就绪。",
		dataSafe:   true,
		nextAction: "请稍候片刻重试，或在 Mac 管理端查看服务状态。",
	},
	"database_unavailable": {
		message:    "暂时无法读取账号与配置数据库。",
		dataSafe:   true,
		nextAction: "请检查 Mac 管理端运行状态与数据目录权限后重试。",
	},
	"registered_root_required": {
		message:    "旧版单盘共享接口已退役，当前操作需要明确指定存储位置。",
		dataSafe:   true,
		nextAction: "请刷新客户端到最新版本，并从已登记的存储位置重新发起操作。",
	},
	"default_root_not_configured": {
		message:    "尚未配置默认存储位置。",
		dataSafe:   true,
		nextAction: "请前往 Mac 管理端「存储 → 存储位置」添加并选择默认硬盘目录。",
	},
	"root_unavailable": {
		message:    "目标存储硬盘当前离线或未通过物理盘核验，原有数据未被修改。",
		dataSafe:   true,
		nextAction: "请检查硬盘连接并等待重新挂载；若确认不再使用，可在 Mac 管理端解除登记后重新配置。",
	},
	"shared_volume_offline": {
		message:    "共享硬盘当前离线或不可访问，原有文件未受影响。",
		dataSafe:   true,
		nextAction: "请检查硬盘线缆连接并重新挂载后刷新页面。",
	},
	"path_not_allowed": {
		message:    "文件路径不合法或超出允许访问的目录范围。",
		dataSafe:   true,
		nextAction: "请检查文件名与目标路径后重试。",
	},
	"unsupported_file_type": {
		message:    "不支持操作该类型的文件或符号链接。",
		dataSafe:   true,
		nextAction: "请仅对普通文件和文件夹执行此操作。",
	},
	"not_found": {
		message:    "未找到目标文件或目录，可能已被移动或删除。",
		dataSafe:   true,
		nextAction: "请刷新当前列表确认最新状态。",
	},
	"file_already_exists": {
		message:    "目标位置已存在同名文件或文件夹，未覆盖原有数据。",
		dataSafe:   true,
		nextAction: "请更换名称或选择其他冲突处理方式后重试。",
	},
	"trash_item_changed": {
		message:    "回收站中的该项目状态已发生变化，未执行修改。",
		dataSafe:   true,
		nextAction: "请刷新回收站列表后重试。",
	},
	"upload_busy": {
		message:    "同一上传任务正在处理中。",
		dataSafe:   true,
		nextAction: "请等待当前分片完成后再继续。",
	},
	"insufficient_storage_space": {
		message:    "目标硬盘可用空间不足，未写入新数据。",
		dataSafe:   true,
		nextAction: "请清理不需要的文件或切换至其他可用空间充足的硬盘后重试。",
	},
	"upload_inventory_limit": {
		message:    "当前未完成上传任务数量已达上限。",
		dataSafe:   true,
		nextAction: "请先完成或清理已有未完成上传后再上传新文件。",
	},
	"upload_owner_mismatch": {
		message:    "不能操作其他成员创建的上传会话。",
		dataSafe:   true,
		nextAction: "请重新发起属于当前账号的上传任务。",
	},
	"upload_too_large": {
		message:    "文件体积超出当前上传限制，未写入目标目录。",
		dataSafe:   true,
		nextAction: "请确认文件大小限制或拆分文件后重试。",
	},
	"upload_outcome_uncertain": {
		message:    "文件已写入但磁盘落盘确认未完成，请核对目标文件完整性。",
		dataSafe:   false,
		nextAction: "请先检查硬盘连接状态，并在目录中确认文件是否完整，必要时重新上传。",
	},
	"storage_durability_failure": {
		message:    "磁盘同步写入失败，可能因硬盘异常断开或介质故障导致。",
		dataSafe:   false,
		nextAction: "请立即检查硬盘连接与健康状态，确认数据完整后再继续写入。",
	},
	"invalid_file_operation": {
		message:    "无法完成该文件操作，原有文件保持不变。",
		dataSafe:   true,
		nextAction: "请检查目标路径与权限状态后重试。",
	},
	"archive_busy": {
		message:    "当前打包下载任务较多，暂未启动新的打包任务。",
		dataSafe:   true,
		nextAction: "请稍等几秒后重试。",
	},
	"cache_clear_failed": {
		message:    "清理缩略图或缓存文件时部分失败，您的原始照片和文件未受影响。",
		dataSafe:   true,
		nextAction: "请检查 Mac 数据目录与硬盘权限后重试清理。",
	},
	"invalid_smb_request": {
		message:    "SMB 共享请求参数无效。",
		dataSafe:   true,
		nextAction: "请检查共享名称与目标目录设置后重新提交。",
	},
	"smb_share_not_found": {
		message:    "未找到指定的 SMB 共享点。",
		dataSafe:   true,
		nextAction: "请刷新 SMB 共享列表确认当前共享状态。",
	},
	"smb_share_already_exists": {
		message:    "相同名称或目录的 SMB 共享已存在。",
		dataSafe:   true,
		nextAction: "请修改共享名称或直接编辑已有共享点。",
	},
	"smb_elevation_required": {
		message:    "尚未完成 Mac 文件共享（SMB）管理授权，未修改系统共享设置。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端的网络与 SMB 设置中完成一次系统管理员授权后重试。",
	},
	"smb_protected_path_rejected": {
		message:    "不允许通过 SMB 共享系统目录或 LightIsle 内部保护路径。",
		dataSafe:   true,
		nextAction: "请选择已登记的 NAS 共享子目录。",
	},
	"smb_volume_root_rejected": {
		message:    "为保护数据安全，不允许直接将整块磁盘根目录设为 SMB 共享。",
		dataSafe:   true,
		nextAction: "请在磁盘下选择具体业务目录后再开启 SMB 共享。",
	},
	"smb_unmanaged_share_rejected": {
		message:    "该共享点并非 LightIsle 托管的存储目录，远程界面不允许修改。",
		dataSafe:   true,
		nextAction: "如需调整，请在 Mac 本机管理端或 macOS「系统设置 → 通用 → 共享」中操作。",
	},
	"smb_personal_guest_forbidden": {
		message:    "包含个人空间（Users）的目录严禁开启访客免密访问。",
		dataSafe:   true,
		nextAction: "请关闭访客访问开关，或改选不包含个人空间的共享子目录。",
	},
	"smb_personal_confirmation_required": {
		message:    "该目录包含成员个人空间，必须在 Mac 本机管理端显式确认后才能共享。",
		dataSafe:   true,
		nextAction: "请前往 Mac 本机管理端确认后操作，或改选非个人子目录。",
	},
	"smb_root_offline": {
		message:    "目标存储硬盘当前离线，暂无法配置或启用其 SMB 共享。",
		dataSafe:   true,
		nextAction: "请重新连接并挂载硬盘后再重试。",
	},
	"smb_operation_failed": {
		message:    "执行 macOS 文件共享（SMB）操作失败，您的原有文件未受影响。",
		dataSafe:   true,
		nextAction: "请检查 Mac 管理端 SMB 服务状态及系统授权后重试。",
	},
	"automation_invalid_task": {
		message:    "自动化任务配置无效或不符合规范。",
		dataSafe:   true,
		nextAction: "请检查本地 task.json / Cron 表达式与脚本权限后刷新。",
	},
	"automation_task_not_found": {
		message:    "未找到对应的自动化脚本任务。",
		dataSafe:   true,
		nextAction: "请点击刷新任务列表确认本地脚本目录状态。",
	},
	"automation_task_running": {
		message:    "该自动化任务正在执行中，或并发任务槽位已满。",
		dataSafe:   true,
		nextAction: "请等待当前任务执行结束后再重试。",
	},
	"automation_task_changed": {
		message:    "任务配置刚刚被本地文件修改，本次编辑未覆盖您的本地更改。",
		dataSafe:   true,
		nextAction: "请刷新任务列表后基于最新配置重新修改。",
	},
	"automation_unavailable": {
		message:    "自动化调度服务当前不可用。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端检查服务与自动化目录权限后重试。",
	},
	"automation_operation_failed": {
		message:    "自动化任务操作失败。",
		dataSafe:   true,
		nextAction: "请查看任务运行日志并检查本地脚本目录权限后重试。",
	},
	"gallery_unavailable": {
		message:    "相册索引服务当前不可用，您的原始照片未受影响。",
		dataSafe:   true,
		nextAction: "请确认存储硬盘已在线并稍后重试。",
	},
	"cinema_unavailable": {
		message:    "影院媒体库当前不可用，您的原始影片未受影响。",
		dataSafe:   true,
		nextAction: "请确认存储硬盘已在线并稍后重试。",
	},
	"native_only_or_unknown_task": {
		message:    "该任务仅支持在 Mac 本机管理端触发，或任务类型无效。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端执行该操作，或刷新页面重试。",
	},
	"task_already_running": {
		message:    "同类后台任务正在运行中，无需重复启动。",
		dataSafe:   true,
		nextAction: "请等待当前任务完成后再试。",
	},
	"task_retry_failed": {
		message:    "无法启动该后台任务，现有文件未受影响。",
		dataSafe:   true,
		nextAction: "请确认硬盘在线且没有冲突任务后重试。",
	},
	"missing_media_target_unavailable": {
		message:    "找不到可重新关联的目标媒体文件，原有目录文件未被修改。",
		dataSafe:   true,
		nextAction: "请先确认硬盘在线且文件位于允许访问的目录中，再刷新核对列表。",
	},
	"missing_media_metadata_conflict": {
		message:    "目标文件已关联其他媒体记录，未覆写现有相册或影院资料。",
		dataSafe:   true,
		nextAction: "请刷新缺失媒体列表后核对目标文件。",
	},
	"missing_media_unavailable": {
		message:    "暂时无法完成缺失媒体记录核对，原有媒体文件未受影响。",
		dataSafe:   true,
		nextAction: "请稍后重试并确认对应硬盘在线。",
	},
	"missing_media_operation_uncertain": {
		message:    "核对期间硬盘状态发生变化，请重新确认结果。",
		dataSafe:   true,
		nextAction: "请检查硬盘连接并刷新缺失媒体列表确认最新状态。",
	},
	"app_invalid": {
		message:    "轻应用参数或清单配置不合法，未修改现有应用。",
		dataSafe:   true,
		nextAction: "请检查应用配置和存储位置后重试。",
	},
	"app_storage_slot_limit": {
		message:    "轻应用存储位置数量已达到上限。",
		dataSafe:   true,
		nextAction: "请先移除不再使用的其他盘位置后再添加新位置。",
	},
	"app_storage_offline": {
		message:    "轻应用所在的存储硬盘当前离线，原有应用数据未被删除。",
		dataSafe:   true,
		nextAction: "请检查外置硬盘连接并重新挂载后再启动或管理应用。",
	},
	"app_template_not_found": {
		message:    "未在在线插件商店中找到对应的应用。",
		dataSafe:   true,
		nextAction: "请刷新在线插件商店列表后重试。",
	},
	"app_store_unavailable": {
		message:    "暂时无法连接 Git 在线插件商店。",
		dataSafe:   true,
		nextAction: "请检查网络连接，或在应用中心「商店源设置」中配置镜像前缀或自定义 Git 仓库地址后重试。",
	},
	"app_store_plugin_not_found": {
		message:    "未在在线插件商店中找到对应的插件应用。",
		dataSafe:   true,
		nextAction: "请先刷新在线商店目录后重试。",
	},
	"app_store_checksum_mismatch": {
		message:    "下载的插件包 SHA-256 校验未通过，系统已拒绝安装。",
		dataSafe:   true,
		nextAction: "请稍后重试下载，或检查自定义商店仓库中的包摘要是否已同步更新。",
	},
	"app_store_invalid_config": {
		message:    "在线商店源地址或镜像前缀无效。",
		dataSafe:   true,
		nextAction: "请填写有效的 HTTPS 仓库索引地址或镜像前缀，或恢复官方默认源。",
	},
	"app_store_no_update": {
		message:    "当前已安装插件已是商店中的最新版本。",
		dataSafe:   true,
		nextAction: "可先刷新在线商店检查是否有新版本发布。",
	},
	"app_already_exists": {
		message:    "该轻应用已安装，无需重复添加。",
		dataSafe:   true,
		nextAction: "请直接在已安装应用列表中打开或管理它。",
	},
	"app_not_found": {
		message:    "未找到指定的轻应用。",
		dataSafe:   true,
		nextAction: "请刷新应用列表确认该应用是否仍存在于插件目录中。",
	},
	"app_access_forbidden": {
		message:    "当前账号无权访问该轻应用。",
		dataSafe:   true,
		nextAction: "请联系管理员在轻应用权限设置中为您授权。",
	},
	"app_pending_activation": {
		message:    "该轻应用尚未经管理员首次激活确认。",
		dataSafe:   true,
		nextAction: "请由管理员审核并确认激活后再启动使用。",
	},
	"app_running": {
		message:    "轻应用当前正在运行中，暂无法执行此操作。",
		dataSafe:   true,
		nextAction: "请先停止该轻应用后再重试。",
	},
	"app_disabled": {
		message:    "该轻应用的对应功能当前处于停用状态。",
		dataSafe:   true,
		nextAction: "请在应用设置中启用相关功能后重试。",
	},
	"app_busy": {
		message:    "轻应用正在执行另一项操作，请稍候。",
		dataSafe:   true,
		nextAction: "请等待当前操作完成后重试。",
	},
	"app_changed": {
		message:    "轻应用配置文件已被外部修改，未覆盖最新更改。",
		dataSafe:   true,
		nextAction: "请刷新应用详情后重新提交。",
	},
	"app_unavailable": {
		message:    "轻应用运行服务当前不可用。",
		dataSafe:   true,
		nextAction: "请在 Mac 管理端检查服务状态与插件目录后重试。",
	},
	"app_operation_failed": {
		message:    "轻应用操作执行失败，您的个人文件未受影响。",
		dataSafe:   true,
		nextAction: "请查看该应用的运行日志或诊断信息后重试。",
	},
	"mcp_streaming_unsupported": {
		message:    "当前连接不支持 SSE 流式传输。",
		dataSafe:   true,
		nextAction: "请改用标准 MCP HTTP POST 接口或检查反向代理配置。",
	},
	"mcp_sse_limit_reached": {
		message:    "活动 MCP SSE 会话已达上限（16 个）。",
		dataSafe:   true,
		nextAction: "请关闭闲置的 MCP 客户端连接后重试。",
	},
}

// writeAPIError writes a unified, backward-compatible JSON error response.
// It always preserves "error": code and records the error code for diagnostics.
func writeAPIError(w http.ResponseWriter, status int, code, message string, dataSafe bool, nextAction string) {
	diagnostics.SetErrorCode(w, code)
	safe := dataSafe
	jsonReply(w, status, APIError{
		Error:      code,
		Message:    message,
		DataSafe:   &safe,
		NextAction: nextAction,
	})
}

// writeAPIErrorCode looks up user-facing Chinese guidance for code in
// apiErrorCatalog and apiErrorDomainCatalog and emits a unified APIError.
func writeAPIErrorCode(w http.ResponseWriter, status int, code string) {
	if g, ok := apiErrorCatalog[code]; ok {
		writeAPIError(w, status, code, g.message, g.dataSafe, g.nextAction)
		return
	}
	if g, ok := apiErrorDomainCatalog[code]; ok {
		writeAPIError(w, status, code, g.message, g.dataSafe, g.nextAction)
		return
	}
	writeAPIError(w, status, code, "操作未能完成，请稍后重试。", true, "请刷新页面后重试；若问题持续，请在 Mac 管理端查看运行状态。")
}
