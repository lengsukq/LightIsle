// Translate public API failure codes to actionable map messages. Never treat
// an offline volume as an empty photo library or silently bypass its binding.
export function describePhotoMapFailure(reason) {
  const code = reason instanceof Error ? reason.message : String(reason || "");
  switch (code) {
    case "volume_offline":
    case "shared_volume_offline":
    case "root_unavailable":
    case "shared_directory_unavailable":
      return "照片所在的存储目录当前离线，或原硬盘重新挂载后尚未确认。请在 Mac 管理端的「数据与存储」检查原硬盘与目录绑定，必要时重新连接原盘，然后重试。不会自动改用其他同名硬盘。";
    case "root_generation_changed":
    case "root_context_changed":
      return "图库所选存储目录已发生变化，请刷新共享目录列表后重新进入地图。";
    case "file_permission_denied":
    case "HTTP 403":
      return "当前账号没有读取此图库目录的权限，请联系管理员检查目录授权。";
    case "authentication_required":
    case "HTTP 401":
      return "登录状态已失效，请重新登录后再查看地图。";
    case "gallery_unavailable":
      return "图库服务暂时不可用，请确认 Mac 上 LightIsle Core 已启动后重试。";
    default:
      if (reason instanceof TypeError) return "无法连接到 NAS，请检查 Mac 服务及网络连接后重试。";
      return "读取照片位置信息失败（" + (code || "未知错误") + "），请重试。";
  }
}
