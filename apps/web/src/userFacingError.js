// Shared user-facing error translation. API codes are diagnostic identifiers,
// not suitable as the sole instruction shown in a daily-use UI.
// Keep specific operation messages in the calling screen when more precise.
const labels = {
  authentication_required:"登录状态已失效，请重新登录后重试。",
  login_required:"请先登录，再执行此操作。",
  invalid_credentials:"用户名或密码不正确，请检查输入后重试。",
  admin_only:"只有管理员能执行这项操作，请切换管理员账号。",
  file_permission_denied:"当前账号没有此文件或目录的操作权限，请联系管理员检查授权。",
  permission_denied:"没有操作权限或目标磁盘不可写，请检查目录授权及文件系统。",
  root_generation_changed:"存储目录已发生变化，请刷新共享目录并重新选择。",
  root_context_changed:"共享目录正在切换，请重新进入当前页面后重试。",
  root_not_found:"所选共享目录已被移除，请刷新列表后重新选择。",
  root_scope_unavailable:"共享目录尚未准备好，请在 Mac 管理端检查配置，再刷新页面。",
  root_unavailable:"共享目录暂时离线，请检查原硬盘连接，再在 Mac 管理端重新连接。",
  volume_offline:"媒体所在的原硬盘当前离线，或重新挂载后尚未确认。请在 Mac 的「数据与存储」检查并重新连接原卷。",
  shared_volume_offline:"原存储磁盘当前不可用，请检查硬盘连接及 Mac 上的目录绑定，重新连接后重试。",
  shared_directory_unavailable:"共享目录当前不可用，请在 Mac 管理端检查存储设置与磁盘连接。",
  shared_directory_transition_busy:"Mac 正在切换存储目录，当前操作未完成。请等待切换结束后刷新重试。",
  storage_destination_not_assigned:"当前账号没有可用的存储位置，或原硬盘离线。请让管理员重新检查目录分配。",
  insufficient_storage_space:"目标磁盘空间不足，请清理容量或更换可用存储后重试。",
  storage_quota_exceeded:"个人存储额度已用尽，请清理文件或联系管理员调整额度。",
  file_already_exists:"目标位置已有同名文件，为避免覆盖，请选择其他名称或处理冲突。",
  not_found:"目标内容已不存在或发生变化，请刷新后重新选择。",
  file_not_found:"文件已不存在或被移动，请刷新目录列表后重试。",
  invalid_request:"提交的内容不符合要求，请检查输入后再试。",
  invalid_id:"所选内容已失效，请重新选择。",
  path_not_allowed:"该路径不允许访问，或包含保留名称，请选择授权范围内的目录。",
  scan_running:"媒体扫描正在进行，请等待本次扫描结束。",
  scan_already_running:"媒体扫描正在进行，请等待本次扫描结束。",
  gallery_unavailable:"图库服务暂时不可用，请确认 Mac 上的 LightIsle Core 正在运行。",
  gallery_failed:"无法读取图库，请检查 NAS 连接和存储状态后重试。",
  cinema_unavailable:"影视服务暂时不可用，请确认 Mac 上的 LightIsle Core 正在运行。",
  cinema_volume_offline:"影片所在硬盘离线，请重新连接原硬盘后再打开。",
  media_worker_unavailable:"媒体预览组件暂不可用，请尝试下载原文件或重新启动 LightIsle。",
  asset_changed_rescan_required:"原始媒体文件已经更改，请重新扫描图库后重试。",
  gallery_scan_running:"图库正在扫描，请稍后查看结果。",
  download_unavailable:"下载中心未就绪。请检查 Mac 是否安装 aria2，并确认下载服务已启动。",
  download_invalid_request:"下载链接或目标文件夹无效，请核对链接及写入权限。",
  download_limit_reached:"进行中的下载任务已达到上限，请先完成或取消其他任务。",
  download_root_unavailable:"下载目标所在的原硬盘已离线，请重新连接后再重试。",
  download_root_changed:"下载任务绑定的硬盘发生变化，请核对原硬盘及目标文件后再操作。",
  download_permission_revoked:"下载目标目录的写入权限已撤销，请联系管理员重新授权。",
  download_publish_failed:"下载已经完成，但保存到共享目录失败。请确认硬盘空间与权限后重试，不要覆盖已有文件。",
  download_staging_lost:"下载暂存文件已丢失，请重新创建或重试任务。",
  download_gone:"下载进程已结束且暂存会话不存在，请重试该任务。",
  drive_discovery_unavailable:"macOS 暂时无法列出硬盘，请检查设备连接和系统权限后刷新。",
  drive_identity_changed_refresh_required:"磁盘身份发生变化，请刷新磁盘列表，确认是原设备后再操作。",
  drive_in_use_or_protected:"该硬盘正被 NAS 或其他任务使用。请停止相关任务并确认数据安全后重试。",
  drive_operation_busy:"另一项磁盘操作正在进行，请等待完成。",
  drive_operation_not_supported:"当前设备不支持此操作，可在 macOS「磁盘工具」中查看。",
  diskutil_operation_failed:"macOS 未能完成操作，设备可能正在使用中；请检查系统磁盘工具。",
  service_unavailable:"LightIsle 服务暂时不可用，请确认 Mac App 仍在运行后重试。",
  root_services_unavailable:"所选目录对应的服务尚未就绪，请检查 Mac App 和存储连接后重试。",
  request_failed:"服务器未能完成请求，请刷新确认当前状态后再重试。",
};

const httpLabels={
  400:"提交的数据不符合要求，请检查填写内容。",
  401:"登录状态已失效，请重新登录后再操作。",
  403:"当前账号没有执行此操作的权限，请联系管理员。",
  404:"目标内容已不存在，请刷新页面重新选择。",
  408:"请求已超时，请检查网络后重试。",
  409:"目标状态已变化，当前操作未完成；请刷新后再重试。",
  413:"文件或请求超过系统允许的大小。",
  429:"请求过于频繁，请稍后再试。",
  500:"NAS 内部处理失败，请检查 Mac 上的服务状态。",
  502:"NAS 服务连接异常，请确认 LightIsle Core 正在运行。",
  503:"NAS 服务或存储暂不可用，请检查 Mac 上的硬盘与服务状态。",
  504:"服务响应超时，请检查网络并稍后重试。",
  507:"目标磁盘空间不足，请释放容量后重试。",
};

function codeFrom(error){
  const raw=error instanceof Error?error.message:String(error??"");
  if(raw.length<512&&raw.startsWith("{")){
    try {const parsed=JSON.parse(raw);if(typeof parsed?.error==="string")return parsed.error;}catch{/* plain error */}
  }
  return raw.replace(/^(Exception|Error|StateError):\s*/,"").trim();
}
export function describeUserFacingError(error){
  const code=codeFrom(error);
  if(Object.hasOwn(labels,code))return labels[code];
  if(error instanceof TypeError)return "无法连接到 NAS，请确认 Mac 服务已启动并检查网络后重试。";
  if(error instanceof SyntaxError)return "服务返回了无法解析的数据，请刷新页面后重试。";
  const match=/^HTTP\s+(\d{3})$/.exec(code);
  if(match)return httpLabels[Number(match[1])]??"网络请求未完成，请检查连接后重试。";
  if(!code)return "操作未完成，请刷新确认状态后重试。";
  // Natural-language messages (including server-provided localized details)
  // should not be replaced by a vague generic prompt.
  if(/[\u3400-\u9fff]/.test(code))return code;
  // Unknown internal codes remain available to support, without showing a
  // bare identifier as if it were actionable instructions.
  const hint=/^[a-z][a-z0-9_]{1,80}$/.test(code)?"（排查标识："+code+"）":"";
  return "操作未完成，请刷新确认状态后重试；如持续发生，请联系管理员排查。"+hint;
}
