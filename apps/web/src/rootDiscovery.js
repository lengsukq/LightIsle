const NO_ROOT_ERROR = "共享目录服务返回了无法识别的数据，请刷新页面后重试。";

function errorFromResponse(status, code) {
  if (status === 401 || code === "authentication_required") {
    return "登录状态已失效，请重新登录。";
  }
  if (code === "root_unavailable") {
    return "所选共享目录或磁盘当前离线。请检查 Mac 上的连接状态，再刷新目录列表。";
  }
  if (code === "root_not_found") {
    return "所选共享目录已移除，请刷新目录列表后重新选择。";
  }
  if (code === "file_permission_denied" || status === 403) {
    return "当前账号无权读取共享目录列表，请检查账号状态后重试。";
  }
  if (code === "root_services_unavailable" || status >= 500) {
    return "共享目录服务暂时不可用，请稍后重试。";
  }
  return `暂时无法读取共享目录列表（HTTP ${status}），请重试。`;
}

function isValidRoot(root) {
  return root && typeof root === "object" &&
    typeof root.rootID === "string" && root.rootID.length > 0 &&
    typeof root.name === "string" &&
    Number.isSafeInteger(root.generation) && root.generation > 0 &&
    typeof root.online === "boolean";
}

export async function readRootDiscoveryResponse(response) {
  // The supported single-root Core intentionally leaves this preview API off.
  if (response.status === 404) return { kind: "legacy" };

  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    return { kind: "error", message: errorFromResponse(response.status, payload?.error) };
  }

  let payload;
  try {
    payload = await response.json();
  } catch {
    return { kind: "error", message: NO_ROOT_ERROR };
  }
  if (!payload || !Array.isArray(payload.roots) || !payload.roots.every(isValidRoot)) {
    return { kind: "error", message: NO_ROOT_ERROR };
  }
  return { kind: "roots", roots: payload.roots };
}

export function rootDiscoveryNetworkError(error) {
  if (error instanceof TypeError) {
    return "无法连接到轻屿服务，请检查 Mac 上的服务状态和网络连接。";
  }
  return "读取共享目录列表失败，请重试。";
}

export function describeRootContext({ state, error, hasContext, rootCount, selectedRoot }) {
  if (state === "error" || (state === "multi" && !hasContext && error)) {
    return { kind: "error", title: "无法读取共享目录", message: error || "共享目录服务暂时不可用，请重试。", role: "alert", action: "重试" };
  }
  if (state === "unknown") {
    return { kind: "loading", title: "正在检查共享目录", message: "正在确认当前账号可用的共享目录。", role: "status", action: "" };
  }
  if (state === "multi" && selectedRoot?.online === false) {
    const name = selectedRoot.name ? `“${selectedRoot.name}”` : "所选共享目录";
    return { kind: "offline", title: "共享目录暂时离线", message: `${name}当前不可用。请检查 Mac 上的目录或磁盘是否已连接，再刷新目录列表。`, role: "alert", action: "刷新共享目录" };
  }
  if (state === "multi" && !hasContext) {
    if (rootCount > 0) {
      return { kind: "choose", title: "请选择共享目录", message: "从页面顶部选择一个共享目录后即可继续。", role: "status", action: "" };
    }
    return { kind: "choose", title: "请选择共享目录", message: "当前没有可选的多根目录。仍可从页面顶部选择“原共享目录（兼容）”，继续使用原有单根权限。", role: "status", action: "" };
  }
  return { kind: "ready", title: "", message: "", role: "status", action: "" };
}

export function describeRootOperationFailure(error) {
  const code = error instanceof Error ? error.message : String(error || "");
  if (code === "authentication_required" || code === "HTTP 401") return "登录状态已失效，请重新登录。";
  if (code === "shared_directory_transition_busy") return "Mac 正在切换共享目录。请稍后刷新重试，原请求不会写入新目录。";
  if (code === "file_permission_denied" || code === "HTTP 403") return "当前账号无权访问所选共享目录或路径，权限可能已变更。请重新选择目录或联系管理员确认。";
  if (["root_unavailable", "shared_directory_unavailable", "volume_offline"].includes(code)) return "所选共享目录或磁盘当前离线。请检查 Mac 上的连接状态，再刷新目录列表。";
  if (code === "root_not_found") return "所选共享目录已移除，请刷新目录列表后重新选择。";
  if (["root_services_unavailable", "service_unavailable", "gallery_unavailable", "cinema_unavailable"].includes(code) || /^HTTP 5\d\d$/.test(code)) return "共享目录服务暂时不可用，请稍后重试。";
  if (error instanceof TypeError) return "无法连接到轻屿服务，请检查 Mac 上的服务状态和网络连接。";
  if (error instanceof SyntaxError) return "服务返回的数据无法读取，请刷新后重试。";
  if (code === "request_failed") return "服务暂时无法完成请求，请重试。";
  return code || "读取共享目录失败，请重试。";
}
