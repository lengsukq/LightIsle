import { ref } from "vue";
import { describeUserFacingError } from "./userFacingError.js";

export type ManagedAccount = {
  id: number;
  username: string;
  role: "admin" | "member";
  enabled: boolean;
  createdAt: number;
};

type AccountManagementDependencies = {
  isAdmin: () => boolean;
  read: <T>(path: string) => Promise<T>;
  write: <T>(path: string, method: "POST" | "PATCH", body?: object) => Promise<T>;
  confirm: (message: string) => boolean;
  logout: () => Promise<void>;
  onOwnPasswordChanged: () => void;
  storageRoot: () => { id: string; generation: number } | null;
  assignStorage: (accountId: number, category: string, root: { id: string; generation: number }) => Promise<void>;
  storageChanged: () => void;
};

/** Admin account mutations and password flows do not depend on file browsing UI.
 * Membership changes and requests are checked against the current account role.
 */
export function useAccountManagement(deps: AccountManagementDependencies) {
  const accounts = ref<ManagedAccount[]>([]);
  const newUsername = ref("");
  const newPassword = ref("");
  const newRole = ref<"admin" | "member">("member");
  const userError = ref("");
  const userBusy = ref(false);
  const resetMember = ref<ManagedAccount | null>(null);
  const resetPassword = ref("");
  const resetConfirm = ref("");
  const resetBusy = ref(false);
  const resetError = ref("");
  const resetNotice = ref("");
  const currentPassword = ref("");
  const nextPassword = ref("");
  const repeatPassword = ref("");
  const passwordBusy = ref(false);
  const passwordError = ref("");
  let generation = 0;

  function resetAccountState() {
    generation++;
    accounts.value = [];
    userError.value = "";
    userBusy.value = false;
    resetMember.value = null;
    resetPassword.value = "";
    resetConfirm.value = "";
    resetBusy.value = false;
    resetError.value = "";
    resetNotice.value = "";
    currentPassword.value = "";
    nextPassword.value = "";
    repeatPassword.value = "";
    passwordBusy.value = false;
    passwordError.value = "";
  }

  async function loadAccounts() {
    if (!deps.isAdmin()) return;
    const request = generation;
    try {
      const result = await deps.read<{ users: ManagedAccount[] }>("/api/v2/users");
      if (request === generation && deps.isAdmin()) accounts.value = result.users;
    } catch (_) {
      if (request === generation && deps.isAdmin()) userError.value = "读取账号列表失败";
    }
  }

  async function addAccount() {
    if (!deps.isAdmin() || userBusy.value) return;
    const request = generation;
    userError.value = "";
    userBusy.value = true;
    try {
      const created = await deps.write<{ id: number; username: string }>(
        "/api/v2/users", "POST",
        { username: newUsername.value, password: newPassword.value, role: newRole.value },
      );
      if (request !== generation || !deps.isAdmin()) return;
      newUsername.value = "";
      newPassword.value = "";
      await loadAccounts();
      const root = deps.storageRoot();
      if (root) {
        const assigned: string[] = [];
        for (const category of ["files", "photos", "videos"]) {
          if (request !== generation || !deps.isAdmin() || deps.storageRoot()?.id !== root.id ||
              deps.storageRoot()?.generation !== root.generation) {
            userError.value = "成员存储硬盘已变化，请在「成员存储空间」中重新检查分配。";
            return;
          }
          try {
            await deps.assignStorage(created.id, category, root);
            assigned.push(category);
          } catch (error) {
            if (request === generation && deps.isAdmin()) {
              deps.storageChanged();
              userError.value = `账号“${created.username}”已创建，但只有 ${assigned.length}/3 个专属目录创建成功。请在下方「成员存储空间」中重试分配：${String(error)}`;
            }
            return;
          }
        }
        deps.storageChanged();
      } else {
        userError.value = `账号“${created.username}”已创建，但还没有选定在线的多根存储硬盘。请在「成员存储空间」中分配文件、照片和视频目录。`;
      }
    } catch (error) {
      if (request !== generation || !deps.isAdmin()) return;
      const code = error instanceof Error ? error.message : "";
      userError.value = code === "username_exists" ? "用户名已存在"
        : code === "invalid_account" ? "用户名或密码不满足要求"
          : "创建失败：" + describeUserFacingError(error);
    } finally {
      if (request === generation) userBusy.value = false;
    }
  }

  async function toggleAccount(account: ManagedAccount) {
    if (!deps.isAdmin()) return;
    const request = generation;
    userError.value = "";
    try {
      await deps.write("/api/v2/users/" + account.id, "PATCH", { enabled: !account.enabled });
      if (request === generation && deps.isAdmin()) await loadAccounts();
    } catch (error) {
      if (request === generation && deps.isAdmin()) userError.value = "更新账号失败：" + describeUserFacingError(error);
    }
  }

  function openMemberReset(account: ManagedAccount) {
    if (account.role !== "member" || !account.enabled || !deps.isAdmin()) return;
    resetMember.value = account;
    resetPassword.value = "";
    resetConfirm.value = "";
    resetError.value = "";
    resetNotice.value = "";
  }

  function closeMemberReset() {
    if (resetBusy.value) return;
    resetMember.value = null;
    resetPassword.value = "";
    resetConfirm.value = "";
    resetError.value = "";
  }

  async function submitMemberReset() {
    const account = resetMember.value;
    if (!account || resetBusy.value || !deps.isAdmin()) return;
    resetError.value = "";
    if (resetPassword.value.length < 12 || resetPassword.value.length > 256 ||
        resetPassword.value.trim() !== resetPassword.value) {
      resetError.value = "密码长度需为 12–256 位，且两端不能有空格。";
      return;
    }
    if (resetPassword.value !== resetConfirm.value) {
      resetError.value = "两次输入的密码不一致。";
      return;
    }
    if (!deps.confirm("确认修改“" + account.username + "”的登录密码？该成员的所有会话将被撤销。")) return;
    const request = generation;
    resetBusy.value = true;
    try {
      await deps.write("/api/v2/users/" + encodeURIComponent(String(account.id)) + "/password", "POST",
        { password: resetPassword.value });
      if (request !== generation || !deps.isAdmin()) return;
      resetMember.value = null;
      resetPassword.value = "";
      resetConfirm.value = "";
      resetNotice.value = "已更新“" + account.username + "”的密码并使原有会话失效。";
    } catch (error) {
      if (request !== generation || !deps.isAdmin()) return;
      const code = error instanceof Error ? error.message : "request_failed";
      const labels: Record<string, string> = {
        invalid_new_password: "新密码不符合安全要求。",
        protected_account: "该账号不可重置或已停用。",
        user_not_found: "找不到该账号，请刷新列表。",
      };
      resetError.value = labels[code] ?? ("重置失败：" + code);
    } finally {
      if (request === generation) resetBusy.value = false;
    }
  }

  async function changeOwnPassword() {
    if (passwordBusy.value) return;
    passwordError.value = "";
    if (nextPassword.value.length < 12 || nextPassword.value.length > 256 ||
        nextPassword.value.trim() !== nextPassword.value) {
      passwordError.value = "新密码必须为 12–256 位，且不能以空格开头或结尾。";
      return;
    }
    if (nextPassword.value !== repeatPassword.value) {
      passwordError.value = "两次输入的新密码不一致。";
      return;
    }
    if (currentPassword.value === nextPassword.value) {
      passwordError.value = "新密码不能与旧密码相同。";
      return;
    }
    const request = generation;
    passwordBusy.value = true;
    try {
      await deps.write("/api/v2/auth/password", "POST", {
        currentPassword: currentPassword.value,
        newPassword: nextPassword.value,
      });
      if (request !== generation) return;
      currentPassword.value = "";
      nextPassword.value = "";
      repeatPassword.value = "";
      await deps.logout();
      deps.onOwnPasswordChanged();
    } catch (error) {
      if (request !== generation) return;
      const code = error instanceof Error ? error.message : "request_failed";
      const labels: Record<string, string> = {
        current_password_invalid: "当前密码不正确。",
        invalid_new_password: "新密码不符合安全要求。",
        too_many_attempts: "尝试次数过多，请稍后再试。",
      };
      passwordError.value = labels[code] ?? ("修改密码失败：" + code);
    } finally {
      if (request === generation) passwordBusy.value = false;
    }
  }

  return {
    accounts, newUsername, newPassword, newRole, userError, userBusy,
    resetMember, resetPassword, resetConfirm, resetBusy, resetError, resetNotice,
    currentPassword, nextPassword, repeatPassword, passwordBusy, passwordError,
    loadAccounts, addAccount, toggleAccount, openMemberReset, closeMemberReset,
    submitMemberReset, changeOwnPassword, resetAccountState,
  };
}
