import 'lightisle_api.dart';

/// Actionable error descriptions shared by ordinary Flutter pages.
String userFacingError(Object error) {
  final raw = error is LightIsleApiException
      ? error.code
      : error.toString().replaceFirst(RegExp(r'^(Exception|StateError|Error|Bad state):\s*'), '');
  const labels = <String, String>{
    'authentication_required': '登录状态已失效，请重新登录后重试。',
    'login_required': '请先登录后再执行此操作。',
    'invalid_credentials': '用户名或密码不正确，请检查输入。',
    'admin_only': '只有管理员能够执行此操作，请切换管理员账号。',
    'file_permission_denied': '当前账号没有对应文件或目录的权限，请联系管理员检查授权。',
    'permission_denied': '当前账号没有操作权限，或目标磁盘不可写，请检查授权。',
    'volume_offline': '原图库硬盘已离线或尚未确认重连，请在 Mac 的「数据与存储」重新连接原卷。',
    'shared_volume_offline': '原存储磁盘暂时不可用，请检查硬盘连接及 Mac 端目录绑定。',
    'share_offline': '共享磁盘暂不可用，请检查原磁盘连接并重新连接。',
    'root_unavailable': '共享目录暂时离线，请在 Mac 管理端检查原磁盘。',
    'root_generation_changed': '共享目录已发生变化，请刷新目录列表后重新选择。',
    'root_not_found': '所选共享目录已移除，请重新选择。',
    'file_not_found': '文件已不存在，请刷新后重新选择。',
    'not_found': '目标内容不存在或已变化，请刷新后再试。',
    'file_already_exists': '目标位置已有同名文件，请改名或处理冲突。',
    'storage_quota_exceeded': '个人存储额度已用尽，请清理文件或联系管理员。',
    'insufficient_storage_space': '目标磁盘空间不足，请清理空间后重试。',
    'download_unavailable': '下载服务未就绪，请在 Mac 上检查 aria2 是否已安装并启动。',
    'download_root_unavailable': '下载原硬盘已离线，请重新连接后再试。',
    'gallery_unavailable': '图库服务暂不可用，请确认 Mac 上的 LightIsle 正在运行。',
    'cinema_unavailable': '影视服务暂不可用，请确认 Mac 上的 LightIsle 正在运行。',
    'request_failed': '服务器未能完成请求，请刷新确认状态后重试。',
    'invalid_request': '提交的信息不符合要求，请检查内容后重试。',
    'current_password_invalid': '当前密码不正确',
    'invalid_new_password': '新密码不符合安全要求，请检查密码长度与格式。',
    'session_not_found': '该登录会话已失效，请刷新设备列表。',
    'invalid_session': '登录会话已变化，请刷新设备列表后重试。',
    'user_not_found': '该用户已不存在，请刷新列表。',
  };
  if (labels.containsKey(raw)) return labels[raw]!;
  final status = error is LightIsleApiException && error.statusCode != null
      ? error.statusCode
      : int.tryParse(RegExp(r'^HTTP\s+(\d{3})$').firstMatch(raw)?.group(1) ?? '');
  switch (status) {
    case 400: return '提交的数据不符合要求，请检查输入。';
    case 401: return '登录状态已失效，请重新登录。';
    case 403: return '当前账号无权进行此操作，请联系管理员。';
    case 404: return '目标内容已不存在，请刷新后重新选择。';
    case 409: return '目标已发生变化，请刷新状态后重新操作。';
    case 429: return '请求过于频繁，请稍后重试。';
    case 503: return 'NAS 服务或硬盘暂时不可用，请检查 Mac 的运行和存储状态。';
    case 507: return '目标硬盘剩余空间不足，请清理后再重试。';
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
