// Shared user-facing error translation. API codes are diagnostic identifiers,
// not suitable as the sole instruction shown in a daily-use UI.
// Keep specific operation messages in the calling screen when more precise.
import { diagnosticID } from "./betaDiagnostics.ts";

const labels: Record<string, string> = {
  network_request_failed: "无法连接到 NAS，请确认 Mac 服务已启动并检查网络后重试。",
  authentication_required: "登录状态已失效，请重新登录后重试。",
  login_required: "请先登录，再执行此操作。",
  invalid_credentials: "用户名或密码不正确，请检查输入后重试。",
  admin_only: "只有管理员能执行这项操作，请切换管理员账号。",
  file_permission_denied: "当前账号没有此文件或目录的操作权限，请联系管理员检查授权。",
  computer_access_disabled: "电脑文件访问已关闭，请在 Mac 的轻屿设置中开启。",
  computer_permission_denied: "电脑文件访问权限已关闭或被撤销，或 Mac 未允许读取此位置。",
  computer_folder_changed: "授权文件夹或所在磁盘已变化，请管理员检查后重新授权。",
  computer_path_invalid: "此路径不可访问，或包含符号链接及特殊文件。",
  computer_file_not_found: "文件不存在或磁盘已断开，请检查连接后刷新。",
  computer_file_unavailable: "无法读取此位置，请检查 Mac 文件权限和磁盘连接。",
  computer_access_unavailable: "电脑文件服务暂不可用，请检查 Mac 服务。",
  computer_grant_failed: "未能保存成员权限，请检查账号状态后重试。",
  permission_denied: "没有操作权限或目标磁盘不可写，请检查目录授权及文件系统。",
  root_generation_changed: "存储目录已发生变化，请刷新共享目录并重新选择。",
  root_context_changed: "共享目录正在切换，请重新进入当前页面后重试。",
  root_not_found: "所选共享目录已被移除，请刷新列表后重新选择。",
  root_scope_unavailable: "共享目录尚未准备好，请在 Mac 管理端检查配置，再刷新页面。",
  root_unavailable: "共享目录暂时离线，请检查原硬盘连接，再在 Mac 管理端重新连接。",
  volume_offline: "媒体所在的原硬盘当前离线，或重新挂载后尚未确认。请在 Mac 的「数据与存储」检查并重新连接原卷。",
  shared_volume_offline: "原存储磁盘当前不可用，请检查硬盘连接及 Mac 上的目录绑定，重新连接后重试。",
  shared_directory_unavailable: "共享目录当前不可用，请在 Mac 管理端检查存储设置与磁盘连接。",
  shared_directory_transition_busy: "Mac 正在切换存储目录，当前操作未完成。请等待切换结束后刷新重试。",
  storage_destination_not_assigned: "当前账号没有可用的存储位置，或原硬盘离线。请让管理员重新检查目录分配。",
  insufficient_storage_space: "目标磁盘空间不足，请清理容量或更换可用存储后重试。",
  storage_quota_exceeded: "个人存储额度已用尽，请清理文件或联系管理员调整额度。",
  file_already_exists: "目标位置已有同名文件，为避免覆盖，请选择其他名称或处理冲突。",
  trash_item_changed: "回收站中的内容与原记录不一致，操作已停止。请在 Mac 上检查原位置和回收站后再处理。",
  invalid_archive_selection: "选择的媒体无效，请刷新列表并重新选择。",
  archive_limit_exceeded: "所选原文件合计超过 2 GiB，请减少选择后分批下载。",
  invalid_zip_archive: "ZIP 压缩包无效或已损坏，请检查文件后重试。",
  archive_unsafe_entry: "压缩包内包含不安全路径或特殊文件（如符号链接），已拒绝解压。",
  archive_busy: "当前打包下载较多，请稍后重试。",
  archive_source_changed: "原文件在打包期间发生变化，请刷新图库后重试。",
  album_not_empty: "相册中仍有照片或其他文件，请先移走或删除内容，再删除空相册。",
  not_found: "目标内容已不存在或发生变化，请刷新后重新选择。",
  file_not_found: "文件已不存在或被移动，请刷新目录列表后重试。",
  invalid_request: "提交的内容不符合要求，请检查输入后再试。",
  invalid_id: "所选内容已失效，请重新选择。",
  path_not_allowed: "该路径不允许访问，或包含保留名称，请选择授权范围内的目录。",
  scan_running: "媒体扫描正在进行，请等待本次扫描结束。",
  scan_directory_changed: "检查期间目录发生变化，结果尚未核对完成。文件未删除，请在文件操作结束后重新检查。",
  cancelled: "检查已取消，结果尚未核对完成；可重新检查。",
  missing_media_target_unavailable: "原位置没有可确认的已索引文件。请先恢复文件、重新检查，再尝试关联。",
  missing_media_metadata_conflict: "当前文件已有会冲突的观看进度或影视资料。为避免覆盖，旧记录已保留，请先检查当前资料。",
  automation_unavailable: "脚本服务暂不可用。请在 Mac 上检查自动化目录和执行历史数据库，再点击刷新脚本。",
  automation_task_not_found: "未找到该自动化脚本任务，可能已在本地目录移除，请点击刷新脚本。",
  automation_task_changed: "本地任务设置已变更。请刷新脚本并重新打开设置后再保存。",
  automation_task_running: "任务正在运行，结束后可以删除。",
  automation_invalid_task: "任务设置无效。请检查 Cron、时区和通知设置。",
  automation_operation_failed: "自动化任务操作未能完成，请查看运行日志或 Mac 服务状态后重试。",
  mcp_disabled: "AI Agent (MCP) 开发者服务当前处于关闭状态。请先在 Mac 管理端手动开启 MCP 服务后再试。",
  app_origin_isolated: "为保护主站账号与数据安全，轻应用内的脚本不允许直接调用轻屿核心管理接口。",
  app_not_found: "所选轻应用不存在或已被移除，请刷新应用中心列表。",
  app_already_exists: "应用目录或同名应用已存在，请更换标识或刷新应用中心列表。",
  app_template_not_found: "未找到对应的官方轻应用模板，请刷新应用中心或更新客户端。",
  app_forbidden: "当前账号没有访问该轻应用的权限，请联系管理员在应用中心授权。",
  app_access_forbidden: "当前账号没有访问该轻应用的权限，请联系管理员在应用中心授权。",
  app_pending_activation: "该轻应用由外部工具创建或修改，需先在应用中心由管理员确认激活后才能运行。",
  app_disabled: "该轻应用当前已停用，请先启用后再打开。",
  app_busy: "该轻应用当前正在处理另一项操作，请稍候片刻再试。",
  app_changed: "应用配置已在磁盘或另一窗口更新，请刷新应用列表后重试。",
  app_running: "轻应用仍在运行中，请先停止进程后再删除。",
  app_invalid: "轻应用配置无效，请检查 Cron 表达式、休眠时长或权限设置。",
  app_operation_failed: "轻应用操作未能完成，请查看应用运行日志后重试。",
  app_storage_slot_limit: "应用数据存储位置已达上限（仅支持 1 个内置盘和 1 个其他盘）。如需更换请先修改或移除现有位置。",
  app_storage_offline: "所选应用存储磁盘当前处于离线或不可写状态，请检查硬盘连接及磁盘读写权限。",
  app_unavailable: "应用中心服务暂不可用，请在 Mac 上检查插件目录与服务状态后重试。",
  apps_unavailable: "应用中心服务暂不可用，请在 Mac 上检查插件目录与服务状态后重试。",
  invalid_smb_request: "共享名称或目录参数无效（不能包含 /、\\、: 等特殊字符）。",
  smb_share_not_found: "未找到该共享目录，请刷新列表后重试。",
  smb_share_already_exists: "该目录或同名共享点已存在，请勿重复添加。",
  smb_elevation_required: "尚未开启三端免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」点击一次「开启免密管理授权」。",
  smb_protected_path_rejected: "安全保护已拦截：不允许共享 .lightisle-* 内部元数据目录、回收站、符号链接或系统根目录。",
  smb_volume_root_rejected: "安全保护已拦截：不能直接将整个外置磁盘挂载点设为共享，请选择磁盘内的具体文件夹（或先在存储位置中登记为 NAS 存储盘）。",
  smb_unmanaged_share_rejected: "该共享点不属于已登记的轻屿 NAS 存储目录，请在 Mac 管理端操作。",
  smb_personal_guest_forbidden: "此共享覆盖成员私人目录。请选择公共子目录，或在 Mac 上关闭访客访问并确认共享。",
  smb_personal_confirmation_required: "请在 Mac 管理端确认私人目录的系统权限后再共享。",
  smb_root_offline: "所选 NAS 存储盘当前处于离线状态，请先检查硬盘连接。",
  smb_operation_failed: "macOS 文件共享操作未完成，请检查系统共享设置或权限。",
  invalid_dav_request: "请求无效，请检查标签长度（64 字符以内）。",
  dav_credential_limit_reached: "最多创建 8 个 WebDAV 密码，请先撤销不再使用的密码。",
  dav_credential_failed: "WebDAV 密码操作未完成，请重试。",
  dav_credential_not_found: "该密码已被撤销或不存在，请刷新列表。",
  dav_unauthorized: "WebDAV 用户名或独立密码不正确，请使用 WebDAV 专用密码重新连接。",
  dav_remount_required: "默认盘或存储目录代次已变化，请断开旧挂载并复制新 WebDAV 地址重新连接。",
  dav_mount_not_found: "该 WebDAV 挂载地址不存在或当前账号无权访问，请刷新并复制最新地址。",
  dav_replace_unsupported_save_as: "当前磁盘文件系统不支持安全原子覆盖（如 ExFAT），请另存为新文件名后再替换。",
  dav_invalid_destination: "WebDAV 目标路径无效或跨越了不同硬盘挂载，请在同一挂载内操作。",
  dav_copy_unavailable: "目录复制暂存或发布未完成，原目录未受影响，请检查空间与连接后重试。",
  dav_destination_exists: "目标位置已存在同名目录或文件，为保护双方数据已拒绝覆盖。",
  dav_source_destination_overlap: "源路径与目标路径互相包含或指向同一对象，已拒绝复制或移动。",
  dav_cross_owner_move: "不支持跨账号或跨公共与私人目录直接移动，请改用复制功能。",
  dav_busy: "WebDAV 并发请求较多，请稍后重试。",
  dav_upload_too_large: "WebDAV 单文件上传超过 32 GiB 上限。",
  dav_metadata_too_large: "WebDAV 元数据请求过大，已拒绝处理。",
  dav_invalid_metadata: "WebDAV 元数据请求格式无效，请重试。",
  dav_access_denied: "当前账号没有该 WebDAV 路径的读写权限。",
  missing_media_unavailable: "缺失媒体资料暂不可用，请检查原硬盘连接后重试。",
  missing_media_operation_uncertain: "硬盘连接发生变化，处理结果暂不能确认。请重新连接原硬盘，刷新缺失媒体列表后再操作。",
  scan_already_running: "媒体扫描正在进行，请等待本次扫描结束。",
  gallery_unavailable: "此盘图库暂时不可用。可先从文件管理查看原件，请管理员检查对应磁盘的图库索引。",
  gallery_failed: "无法读取图库，请检查 NAS 连接和存储状态后重试。",
  cinema_unavailable: "此盘影院暂时不可用。可先从文件管理查看原件，请管理员检查对应磁盘的影视索引。",
  cinema_volume_offline: "影片所在硬盘离线，请重新连接原硬盘后再打开。",
  invalid_strm_url: "STRM 直链地址格式无效，请检查协议与链接内容。",
  forbidden_strm_url: "STRM 直链目标地址受安全策略限制，不允许访问本机或受限网络地址。",
  tmdb_token_not_configured: "尚未在 Mac 管理端配置 TMDB Token，请先配置后再匹配影视资料。",
  douban_web_unavailable: "当前无法访问豆瓣网页搜索建议，请检查网络或改用 TMDB / 本地 NFO。",
  transcode_insufficient_space: "当前缓存空间不足，无法启动在线转码。可清理转码缓存或直接下载原片观看。",
  transcode_busy: "当前在线转码任务已达并发上限，请等待片刻再试或直接下载原片。",
  transcode_failed: "在线转码未能启动或中途中断，未改动原视频文件；可重试或下载原片观看。",
  media_worker_unavailable: "媒体预览处理服务未就绪，请检查 Mac 后端服务；可先保存或下载原始文件。",
  asset_changed_rescan_required: "原始媒体文件已经更改，请重新扫描图库后重试。",
  file_changed_rescan_required: "文件在扫描后已被修改或移动，未删除任何内容；请重新扫描确认后再清理。",
  must_keep_one_photo: "每组相似照片至少需要保留 1 张原片，不能将整组全部移入回收站。",
  must_keep_one_file: "每组重复文件至少需要保留 1 份原件，不能将整组全部移入回收站。",
  invalid_person_name: "人物姓名长度不能超过 40 个字符，且不能包含换行或控制字符。",
  cannot_merge_same_person: "请选择两个不同的人物分组进行合并。",
  invalid_search_mode: "无效的搜索范围，请切换搜索模式后重试。",
  invalid_person_id: "所选人物分组已失效，请刷新人物列表后重新选择。",
  person_share_requires_owned_photos: "只能分享自己上传或拥有访问权限的人物相册。",
  invalid_person_share: "人物相册分享目标无效，请刷新成员列表后重试。",
  admin_confirmation_required: "此高风险操作需要输入当前管理员密码进行二次确认。",
  admin_confirmation_invalid: "管理员二次确认密码不正确，请核对后重试。",
  invalid_limit: "分页数量超出允许范围，请刷新后重试。",
  download_unavailable: "下载中心未就绪。请检查 Mac 是否安装 aria2，并确认下载服务已启动。",
  download_invalid_request: "下载链接或目标文件夹无效，请核对链接及写入权限。",
  download_limit_reached: "进行中的下载任务已达到上限，请先完成或取消其他任务。",
  too_many_shares: "有效分享链接已达到上限，请在文件管理中撤销不再需要的链接。",
  file_too_large_to_share: "此文件超过 32 GiB，暂不能创建分享链接。",
  unsupported_file_identity: "无法确认原文件身份，请刷新列表后重试。",
  download_root_unavailable: "下载目标所在的原硬盘已离线，请重新连接后再重试。",
  download_root_changed: "下载任务绑定的硬盘发生变化，请核对原硬盘及目标文件后再操作。",
  download_permission_revoked: "下载目标目录的写入权限已撤销，请联系管理员重新授权。",
  download_network_admin_only: "只有管理员可以发起或继续网络下载。",
  upload_server_busy: "上传通道已满，请稍后重试。",
  upload_timed_out: "上传长时间未收到数据，请检查连接后重试。",
  password_service_busy: "密码验证繁忙，请稍后重试。",
  download_publish_failed: "下载已经完成，但保存到共享目录失败。请确认硬盘空间与权限后重试，不要覆盖已有文件。",
  download_staging_lost: "下载暂存文件已丢失，请重新创建或重试任务。",
  download_gone: "下载进程已结束且暂存会话不存在，请重试该任务。",
  drive_discovery_unavailable: "macOS 暂时无法列出硬盘，请检查设备连接和系统权限后刷新。",
  drive_identity_changed_refresh_required: "磁盘身份发生变化，请刷新磁盘列表，确认是原设备后再操作。",
  drive_in_use_or_protected: "该硬盘正被 NAS 或其他任务使用。请停止相关任务并确认数据安全后重试。",
  drive_operation_busy: "另一项磁盘操作正在进行，请等待完成。",
  drive_operation_not_supported: "当前设备不支持此操作，可在 macOS「磁盘工具」中查看。",
  diskutil_operation_failed: "macOS 未能完成操作，设备可能正在使用中；请检查系统磁盘工具。",
  service_unavailable: "LightIsle 服务暂时不可用，请确认 Mac App 仍在运行后重试。",
  root_services_unavailable: "当前硬盘对应的服务未就绪，请先在 Mac 检查原盘连接及服务启动状态。",
  request_failed: "服务器未能完成请求，请刷新确认当前状态后再重试。",
  request_header_required: "当前客户端没有携带必要的安全请求标识，服务端已拒绝操作。请刷新或更新 LightIsle 客户端后重试，勿关闭安全校验。",
  cross_origin_request_rejected: "服务端拒绝了跨站请求。请从已配置的 NAS 正式访问地址进入 LightIsle，检查代理或域名配置。",
  default_root_not_configured: "尚未设置默认 NAS 存储目录。请在 Mac LightIsle「数据与存储 → NAS 存储空间」登记在线硬盘并设为默认，随后刷新。",
  registered_root_required: "此操作需要指定已登记的物理存储根。请重新选择对应硬盘，不能自动切换到另一块盘。",
  storage_registry_unavailable: "无法读取存储硬盘登记配置。请在 Mac「数据与存储」检查磁盘管理服务状态。",
  storage_root_unavailable: "所选物理硬盘不可用或身份未确认，请在 Mac「数据与存储」检查原硬盘并确认重新连接。",
  storage_unavailable: "存储文件服务未就绪。请先确认 Mac 上已正确登记、连接并选中存储硬盘。",
  share_root_offline: "共享磁盘暂时离线。请在 Mac「数据与存储」核实原硬盘并重新确认绑定。",
  database_not_ready: "账户数据库尚未初始化完成，请稍后刷新；持续失败请检查 Mac 的服务日志。",
  database_unavailable: "账户数据库暂时无法访问，请在 Mac 检查服务和数据库状态。",
  upload_inventory_limit: "上传任务数量已达到安全上限，请清理过期任务后再试。",
  upload_outcome_uncertain: "上传结果暂不能确认，可能已经保存文件。请先刷新目录核对，不要直接重新覆盖。",
  upload_cleanup_accounting_uncertain: "上传暂存可能已清理，但容量预占尚未确认。请重新连接原硬盘，在管理员任务中心检查预占和目标文件。",
  upload_begin_uncertain: "上传任务可能已在原硬盘创建，但结果尚未确认。请检查原硬盘连接，并让管理员在任务中心核对未完成上传和容量预占。",
  upload_state_corrupt: "旧上传任务状态不完整，无法安全恢复。请取消旧任务并重新上传。",
  storage_durability_failure: "服务端未能确认文件持久写入，请刷新目标目录核对后再操作。",
  storage_accounting_uncertain: "文件写入状态与容量账本尚未核对，请不要重复上传或删除原件，联系管理员检查。",
  storage_accounting_conflict: "文件与容量记录不一致，操作未执行。请管理员检查原文件及存储用量后重试。",
  storage_operation_uncertain: "操作可能已在原硬盘上执行，但硬盘连接或身份发生变化。请重新连接原硬盘并检查文件和回收站，再决定是否重试。",
  storage_trash_purge_accounting_pending: "为避免误释放其他文件的存储额度，暂时无法永久清理私人目录的回收站。文件仍在回收站，可以恢复；请等待此功能修复。",
  trash_accounting_identity_unknown: "该回收站项目缺少完整的身份校验记录，为避免误释放容量额度，暂不支持永久删除；你仍可恢复该文件。",
  storage_quota_is_per_disk_upgrade_client: "存储额度已改为按物理硬盘计算。请升级客户端后重新设置。",
  storage_migration_required: "原数据目录仍有待迁移数据，请先完成显式迁移或保留旧硬盘绑定。",
  storage_folder_not_empty: "目标存储目录已有文件，不能作为空目录初始化。请另选路径或手动确认迁移。",
  storage_folder_conflict: "目标存储路径与已有账户目录冲突，请重新选择。",
};

const httpLabels: Record<number, string> = {
  400: "提交的数据不符合要求，请检查填写内容。",
  401: "登录状态已失效，请重新登录后再操作。",
  403: "当前账号没有执行此操作的权限，请联系管理员。",
  404: "目标内容已不存在，请刷新页面重新选择。",
  408: "请求已超时，请检查网络后重试。",
  409: "目标状态已变化，当前操作未完成；请刷新后再重试。",
  413: "文件或请求超过系统允许的大小。",
  429: "请求过于频繁，请稍后再试。",
  500: "NAS 内部处理失败，请检查 Mac 上的服务状态。",
  502: "NAS 服务连接异常，请确认 LightIsle Core 正在运行。",
  503: "服务器返回 HTTP 503，但没有提供可识别的原因。可能是存储配置、后台服务或网关问题，请核对故障码和 Mac 日志。",
  504: "服务响应超时，请检查网络并稍后重试。",
  507: "目标磁盘空间不足，请释放容量后重试。",
};

type ErrorWithMeta = Error & { code?: unknown; status?: unknown };

function codeFrom(error: unknown): string {
  if (
    error instanceof Error &&
    typeof (error as ErrorWithMeta).code === "string" &&
    /^[a-z][a-z0-9_.-]{1,63}$/.test((error as ErrorWithMeta).code as string)
  ) {
    return (error as ErrorWithMeta).code as string;
  }
  const raw = error instanceof Error ? error.message : String(error ?? "");
  if (raw.length < 512 && raw.startsWith("{")) {
    try {
      const parsed = JSON.parse(raw) as { error?: unknown };
      if (typeof parsed?.error === "string") return parsed.error;
    } catch {
      /* plain error */
    }
  }
  return raw.replace(/^(Exception|Error|StateError):\s*/, "").trim();
}

export function describeUserFacingError(error: unknown): string {
  const requestID = error instanceof Error && "requestID" in error ? diagnosticID(error.requestID) : null;
  const message = describeError(error);
  return requestID ? `${message}（故障编号 ${requestID}）` : message;
}

function describeError(error: unknown): string {
  const code = codeFrom(error);
  const rawStatus = error instanceof Error ? (error as ErrorWithMeta).status : undefined;
  const status =
    typeof rawStatus === "number" &&
    Number.isInteger(rawStatus) &&
    rawStatus >= 100 &&
    rawStatus <= 599
      ? rawStatus
      : null;
  const diagnostic =
    status === null
      ? ""
      : `（HTTP ${status}${/^[a-z][a-z0-9_.-]{1,63}$/.test(code) ? " · " + code : ""}）`;
  if (Object.hasOwn(labels, code)) return labels[code] + diagnostic;
  if (error instanceof TypeError) return "无法连接到 NAS，请确认 Mac 服务已启动并检查网络后重试。";
  if (error instanceof SyntaxError) return "服务返回了无法解析的数据，请刷新页面后重试。";
  const match = /^HTTP\s+(\d{3})$/.exec(code);
  if (match) return httpLabels[Number(match[1])] ?? "网络请求未完成，请检查连接后重试。";
  if (!code) return "操作未完成，请刷新确认状态后重试。";
  // Natural-language messages (including server-provided localized details)
  // should not be replaced by a vague generic prompt.
  if (/[\u3400-\u9fff]/.test(code)) return code + diagnostic;
  // Unknown internal codes remain available to support, without showing a
  // bare identifier as if it were actionable instructions.
  const hint = /^[a-z][a-z0-9_]{1,80}$/.test(code) ? "（排查标识：" + code + "）" : "";
  return (
    (status !== null && httpLabels[status]
      ? httpLabels[status]
      : "操作未完成，请刷新确认状态后重试；如持续发生，请联系管理员排查。") +
    hint +
    diagnostic
  );
}
