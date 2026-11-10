import 'lightisle_api.dart';

/// Actionable error descriptions shared by ordinary Flutter pages.
String userFacingError(Object error) {
  final raw = error is LightIsleApiException
      ? error.code
      : error.toString().replaceFirst(
          RegExp(
            r'^(Exception|StateError|Error|Bad state|FormatException):\s*',
          ),
          '',
        );
  const labels = <String, String>{
    'authentication_required': '登录状态已失效，请重新登录后重试。',
    'login_required': '请先登录后再执行此操作。',
    'invalid_credentials': '用户名或密码不正确，请检查输入。',
    'admin_only': '只有管理员能够执行此操作，请切换管理员账号。',
    'file_permission_denied': '当前账号没有对应文件或目录的权限，请联系管理员检查授权。',
    'permission_denied': '当前账号没有操作权限，或目标磁盘不可写，请检查授权。',
    'default_root_not_configured': '尚未设置默认 NAS 存储目录。请在 Mac LightIsle「数据与存储 → NAS 存储空间」登记并选择在线硬盘作为默认目录，然后返回重试。原文件不会被移动。',
    'registered_root_required':
        '当前请求没有指定已登记的物理存储目录。请返回选择正确的 NAS 硬盘；管理员可在 Mac「数据与存储」确认绑定。',
    'storage_registry_unavailable':
        '无法读取已登记的存储硬盘配置。请在 Mac LightIsle「数据与存储」检查存储管理状态及服务日志。',
    'storage_root_unavailable':
        '所选存储硬盘未通过连接或身份校验。请在 Mac「数据与存储」检查原硬盘，并按提示确认重连；不会自动切换到其他磁盘。',
    'share_root_offline': '默认共享磁盘当前离线。请在 Mac「数据与存储」检查原硬盘是否在线，并重新确认存储绑定。',
    'storage_unavailable': '当前存储目录的文件服务尚未就绪。请在 Mac「数据与存储」确认默认硬盘已登记且在线，然后重试。',
    'root_services_unavailable': '所选硬盘的服务未就绪，请检查 Mac LightIsle 存储管理服务和原磁盘连接状态。',
    'storage_settings_unavailable':
        '无法读取账户存储设置，请检查 Mac LightIsle 的账户数据库和存储登记状态。',
    'storage_destination_not_assigned':
        '该账号尚未分配存储硬盘，或绑定硬盘已离线。请让管理员在存储管理中检查对应类别的绑定。',
    'storage_migration_required': '该类别的旧目录尚有待迁移数据；请先核对旧硬盘和迁移计划，不能直接将它绑定到另一块盘。',
    'storage_folder_not_empty': '目标存储目录不是空目录，请另选目录或先核对已有数据，避免覆盖。',
    'storage_folder_conflict': '目标存储目录与其他账号或类别冲突，请重新选择独立目录。',
    'storage_accounting_conflict': '存储容量账本与当前文件状态冲突，请核对目标文件和上传任务后重试。',
    'storage_accounting_uncertain': '文件可能已经写入，但容量账本无法确认。请先核对实际文件，避免重复上传。',
    'storage_operation_uncertain': '操作可能已在原硬盘上执行。请重新连接原硬盘并检查文件和回收站，再决定是否重试。',
    'storage_trash_purge_accounting_pending': '为避免误释放其他文件的额度，暂时无法永久清理私人目录的回收站。文件仍可恢复，请等待修复。',
    'trash_accounting_identity_unknown': '该回收站项目缺少完整的身份校验记录，为避免误释放容量额度，暂不支持永久删除；你仍可恢复该文件。',
    'invalid_zip_archive': 'ZIP 压缩包无效或已损坏，请检查文件后重试。',
    'archive_unsafe_entry': '压缩包内包含不安全路径或特殊文件（如符号链接），已拒绝解压。',
    'storage_durability_failure': '文件写入后未能确认持久保存，请检查目标文件状态，不要立即重复执行。',
    'storage_quota_is_per_disk_upgrade_client': '存储配额已改为按物理硬盘计算，请升级客户端后重新设置。',
    'upload_busy': '目标路径正在上传，请继续原任务或先取消，不要重复上传。',
    'upload_timed_out': '上传连接超时，请检查网络后从原任务继续。',
    'upload_server_busy': '上传服务达到并发上限，请稍后继续原任务。',
    'upload_inventory_limit': '上传任务数量已达到安全扫描上限，请管理员清理过期任务后重试。',
    'upload_outcome_uncertain': '上传是否完成尚无法确认，请先刷新目录核对文件，再决定是否重传。',
    'upload_cleanup_accounting_uncertain': '上传暂存可能已清理，但容量预占尚未确认。请重新连接原硬盘，让管理员检查预占和目标文件。',
    'upload_begin_uncertain': '上传任务可能已在原硬盘创建，但结果尚未确认。请检查原硬盘连接，让管理员核对未完成上传和容量预占。',
    'upload_state_corrupt': '原上传任务无法安全恢复，请取消旧任务并重新选择文件。',
    'offset_mismatch': '服务端上传进度已变化，请先刷新原任务进度，不要从旧偏移重复写入。',
    'download_storage_accounting_pending': '下载任务的容量账本尚未确认，暂不能创建新任务。请管理员先检查旧任务。',
    'download_root_unbound': '旧下载任务未绑定原存储硬盘，不能自动重试。请先核对旧文件后重新创建。',
    'download_root_changed': '下载任务的原硬盘身份已变化，请确认旧硬盘及文件后再操作。',
    'download_permission_revoked': '下载目录的写入权限已撤销，请联系管理员确认原目录授权。',
    'media_worker_unavailable': '媒体预览服务未就绪；可先保存原文件，管理员检查 Mac 上媒体处理服务。',
    'task_history_unavailable': '任务记录暂不可用，请检查 Mac 任务服务或数据库后重试。',
    'audit_unavailable': '审计记录服务未就绪，请管理员检查 Mac 服务状态后刷新。',
    'alert_center_unavailable': '异常通知服务未就绪，请检查 Mac 服务状态后刷新。',
    'shared_directory_transition_busy':
        'Mac 正在切换共享存储目录，请稍后刷新。为避免误操作，旧目录的请求已暂停。',
    'legacy_root_transition_busy': 'Mac 正在切换物理存储目录，请稍后刷新，不会自动使用另一块磁盘。',
    'volume_offline': '原图库硬盘已离线或尚未确认重连，请在 Mac 的「数据与存储」重新连接原卷。',
    'shared_volume_offline': '原存储磁盘暂时不可用，请检查硬盘连接及 Mac 端目录绑定。',
    'share_offline': '共享磁盘暂不可用，请检查原磁盘连接并重新连接。',
    'root_unavailable': '共享目录暂时离线，请在 Mac 管理端检查原磁盘。',
    'missing_media_target_unavailable': '原位置没有可确认的已索引文件。请先恢复文件、重新检查，再尝试关联。',
    'missing_media_metadata_conflict': '当前文件已有冲突的观看进度或影视资料。为避免覆盖，旧记录已保留，请先检查当前资料。',
    'automation_unavailable': '脚本服务暂不可用。请在 Mac 上检查自动化目录和执行历史数据库，再点击刷新脚本。',
    'automation_task_changed': '本地任务设置已变更。请刷新脚本并重新打开设置后再保存。',
    'automation_task_running': '任务正在运行，结束后可以删除。',
    'automation_invalid_task': '任务设置无效。请检查 Cron、时区和通知设置。',
    'missing_media_unavailable': '缺失媒体资料暂不可用，请检查原硬盘连接后重试。',
    'missing_media_operation_uncertain': '硬盘连接发生变化，处理结果暂不能确认。请重新连接原硬盘，刷新缺失媒体列表后再操作。',
    'root_generation_changed': '共享目录已发生变化，请刷新目录列表后重新选择。',
    'root_not_found': '所选共享目录已移除，请重新选择。',
    'file_not_found': '文件已不存在，请刷新后重新选择。',
    'not_found': '目标内容不存在或已变化，请刷新后再试。',
    'file_already_exists': '目标位置已有同名文件，请改名或处理冲突。',
    'trash_item_changed': '回收站中的内容与原记录不一致，操作已停止。请在 Mac 上检查原位置和回收站后再处理。',
    'album_not_empty': '相册中仍有照片或其他文件，请先移走或删除内容，再删除空相册。',
    'storage_quota_exceeded': '个人存储额度已用尽，请清理文件或联系管理员。',
    'insufficient_storage_space': '目标磁盘空间不足，请清理空间后重试。',
    'download_unavailable': '下载服务未就绪，请在 Mac 上检查 aria2 是否已安装并启动。',
    'download_root_unavailable': '下载原硬盘已离线，请重新连接后再试。',
    'gallery_unavailable':
        '当前存储根的图库索引服务尚未就绪。请先检查 Mac LightIsle 的存储根是否在线；文件管理仍可能可用。',
    'cinema_unavailable':
        '当前存储根的影视索引服务尚未就绪。请先检查 Mac LightIsle 的存储根是否在线；原始文件不受影响。',
    'database_not_ready': '账户数据库正在初始化，请稍后刷新；若持续失败，请检查 Mac 服务日志。',
    'database_unavailable': '账户数据库当前不可访问，请检查 Mac LightIsle 服务状态和数据库日志。',
    'request_failed': '服务器未能完成请求，请刷新确认状态后重试。',
    'request_header_required':
        '请求缺少必要的安全标识，服务端已拒绝操作。请更新或重新打开 LightIsle 客户端后重试，不要关闭安全校验。',
    'cross_origin_request_rejected':
        '请求来源与 NAS 服务器域名不匹配，服务端已拒绝。请检查连接地址或反向代理的 Origin 配置。',
    'invalid_request': '提交的信息不符合要求，请检查内容后重试。',
    'current_password_invalid': '当前密码不正确',
    'invalid_new_password': '新密码不符合安全要求，请检查密码长度与格式。',
    'session_not_found': '该登录会话已失效，请刷新设备列表。',
    'invalid_session': '登录会话已变化，请刷新设备列表后重试。',
    'user_not_found': '该用户已不存在，请刷新列表。',
    'invalid_smb_request': '共享名称或目录参数无效（不能包含 /、\\、: 等特殊字符）。',
    'smb_share_not_found': '未找到该共享目录，请刷新列表后重试。',
    'smb_share_already_exists': '该目录或同名共享点已存在，请勿重复添加。',
    'smb_elevation_required': '尚未开启三端免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」点击一次「开启免密管理授权」。',
    'smb_protected_path_rejected': '安全保护已拦截：不允许共享 .lightisle-* 内部元数据目录、符号链接或系统根目录。',
    'smb_personal_guest_forbidden': '此共享覆盖成员私人目录。请选择公共子目录，或在 Mac 上关闭访客访问并确认共享。',
    'smb_personal_confirmation_required': '请在 Mac 管理端确认私人目录的系统权限后再共享。',
    'smb_root_offline': '所选 NAS 存储盘当前处于离线状态，请先检查硬盘连接。',
    'smb_operation_failed': 'macOS 文件共享操作未完成，请检查系统共享设置或权限。',
  };
  if (labels.containsKey(raw)) return labels[raw]!;
  final status = error is LightIsleApiException && error.statusCode != null
      ? error.statusCode
      : int.tryParse(
          RegExp(r'^HTTP\s+(\d{3})$').firstMatch(raw)?.group(1) ?? '',
        );
  switch (status) {
    case 400:
      return '提交的数据不符合要求，请检查输入。';
    case 401:
      return '登录状态已失效，请重新登录。';
    case 403:
      return '当前账号无权进行此操作，请联系管理员。';
    case 404:
      return '目标内容已不存在，请刷新后重新选择。';
    case 409:
      return '目标已发生变化，请刷新状态后重新操作。';
    case 408:
      return '请求已超时，请检查网络后重试。';
    case 413:
      return '文件或请求超过服务允许的大小，请调整后重试。';
    case 429:
      return '请求过于频繁，请稍后重试。';
    case 500:
      return '服务器处理请求时发生内部错误，请检查 Mac LightIsle 日志后重试。';
    case 502:
      return 'NAS 与内部服务通信失败，请确认 Mac 上的 Core 服务正在运行。';
    case 503:
      return '服务器返回 HTTP 503，但未提供可识别的故障原因。可能是服务初始化、网关或存储配置问题，请先检查 Mac LightIsle 的运行状态；必要时用下方故障码核对服务日志。';
    case 507:
      return '目标硬盘剩余空间不足，请清理后再重试。';
    case 504:
      return 'NAS 服务响应超时，请检查本机运行状态与网络后重试。';
  }
  // The API client already supplies sanitized, actionable Chinese messages
  // for certificate and connection failures; do not lose those details.
  if (error is LightIsleApiException &&
      error.message.contains(RegExp(r'[\u3400-\u9fff]'))) {
    return error.message;
  }
  if (raw.contains(RegExp(r'[\u3400-\u9fff]'))) return raw;
  if (raw.isEmpty) return '操作未完成，请检查网络及 NAS 状态后重试。';
  final safeCode = RegExp(r'^[a-z][a-z0-9_]{1,80}$').hasMatch(raw);
  return safeCode
      ? '操作未完成，请刷新确认结果后再试。若反复发生，请提供排查标识：$raw'
      : '操作未完成，请刷新确认结果后再试。若反复发生，请联系管理员检查服务日志。';
}

/// Safe, copyable support context. Never expose request URLs, cookies,
/// response bodies or arbitrary exception.toString() on the error screen.
String? errorDiagnosticLabel(Object error) {
  if (error is! LightIsleApiException) return null;
  final code = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(error.code)
      ? error.code
      : 'unknown';
  final status = error.statusCode;
  if (status == null) return '故障码：$code';
  if (status < 100 || status > 599) return '故障码：$code';
  return 'HTTP $status · $code';
}
