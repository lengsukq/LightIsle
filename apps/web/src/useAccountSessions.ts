import { ref } from "vue";
import { describeUserFacingError } from "./userFacingError.js";

export type LoginSession = {
  id: string;
  createdAt: number;
  expiresAt: number;
  current: boolean;
};

type SessionDependencies = {
  authenticated: () => boolean;
  read: <T>(path: string) => Promise<T>;
  logoutCurrent: () => Promise<void>;
  onCurrentLogout: () => void;
  confirm: (message: string) => boolean;
  revoke: (path: string) => Promise<void>;
};

/** Session administration is separate from directory/root permissions.
 * A monotonically increasing generation prevents responses from an old login
 * being rendered after logout or an account switch.
 */
export function useAccountSessions(deps: SessionDependencies) {
  const loginSessions = ref<LoginSession[]>([]);
  const sessionsLoading = ref(false);
  const sessionsLoaded = ref(false);
  const sessionsTruncated = ref(false);
  const sessionsError = ref("");
  const sessionsMessage = ref("");
  let generation = 0;

  function reset() {
    generation++;
    loginSessions.value = [];
    sessionsLoading.value = false;
    sessionsLoaded.value = false;
    sessionsTruncated.value = false;
    sessionsError.value = "";
    sessionsMessage.value = "";
  }

  async function loadLoginSessions() {
    if (!deps.authenticated() || sessionsLoading.value) return;
    const current = ++generation;
    sessionsLoading.value = true;
    sessionsError.value = "";
    sessionsMessage.value = "";
    try {
      const result = await deps.read<{ sessions: LoginSession[]; truncated: boolean }>("/api/v2/auth/sessions");
      if (current !== generation || !deps.authenticated()) return;
      loginSessions.value = result.sessions;
      sessionsTruncated.value = result.truncated;
      sessionsLoaded.value = true;
    } catch (error) {
      if (current === generation && deps.authenticated()) {
        sessionsError.value = "读取会话失败：" + describeUserFacingError(error);
      }
    } finally {
      if (current === generation) sessionsLoading.value = false;
    }
  }

  async function revokeLoginSession(target: LoginSession | "others") {
    if (sessionsLoading.value || !deps.authenticated()) return;
    const prompt = target === "others"
      ? "确定退出其他所有设备？当前设备会保持登录。"
      : target.current
        ? "确定退出当前设备？需要重新输入密码。"
        : "确定退出这个会话？";
    if (!deps.confirm(prompt)) return;
    const current = ++generation;
    sessionsLoading.value = true;
    sessionsError.value = "";
    sessionsMessage.value = "";
    try {
      const endpoint = target === "others"
        ? "/api/v2/auth/sessions/others"
        : "/api/v2/auth/sessions/" + encodeURIComponent(target.id);
      await deps.revoke(endpoint);
      if (current !== generation || !deps.authenticated()) return;
      if (target !== "others" && target.current) {
        await deps.logoutCurrent();
        deps.onCurrentLogout();
      } else {
        sessionsLoading.value = false;
        await loadLoginSessions();
        if (current === generation - 1 && deps.authenticated()) {
          sessionsMessage.value = "已撤销所选会话，其他设备下次请求时将需要重新登录。";
        }
      }
    } catch (error) {
      if (current === generation && deps.authenticated()) {
        sessionsError.value = "退出设备失败：" + describeUserFacingError(error);
      }
    } finally {
      if (current === generation) sessionsLoading.value = false;
    }
  }

  return {
    loginSessions, sessionsLoading, sessionsLoaded, sessionsTruncated,
    sessionsError, sessionsMessage, loadLoginSessions, revokeLoginSession,
    reset,
  };
}
