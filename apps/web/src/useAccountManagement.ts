import { ref } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";

export type ManagedAccount = {
  id: number;
  username: string;
  role: "admin" | "member";
  enabled: boolean;
  createdAt: number;
};

export type AccountManagementDependencies = {
  isAdmin: () => boolean;
  read: <T>(path: string) => Promise<T>;
  write: <T>(path: string, method: "POST" | "PATCH", body?: object) => Promise<T>;
  logout: () => Promise<void>;
  onOwnPasswordChanged: () => void;
};

/**
 * Web account viewing (read-only member roster) and self-service password change.
 * Privileged account creation, disablement, member password resets, and storage grants
 * are restricted to Mac / Flutter clients.
 */
export function useAccountManagement(deps: AccountManagementDependencies) {
  const accounts = ref<ManagedAccount[]>([]);
  const userError = ref("");
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
    currentPassword.value = "";
    nextPassword.value = "";
    repeatPassword.value = "";
    passwordBusy.value = false;
    passwordError.value = "";
  }

  async function loadAccounts() {
    if (!deps.isAdmin()) return;
    const request = generation;
    userError.value = "";
    try {
      const result = await deps.read<{ users: ManagedAccount[] }>("/api/v2/users");
      if (request === generation && deps.isAdmin()) accounts.value = result.users;
    } catch (error) {
      if (request === generation && deps.isAdmin()) {
        userError.value = "读取账号列表失败：" + describeUserFacingError(error);
      }
    }
  }

  async function changeOwnPassword() {
    if (passwordBusy.value) return;
    passwordError.value = "";
    if (
      nextPassword.value.length < 12 ||
      nextPassword.value.length > 256 ||
      nextPassword.value.trim() !== nextPassword.value
    ) {
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
      passwordError.value = labels[code] ?? "修改密码失败：" + describeUserFacingError(error);
    } finally {
      if (request === generation) passwordBusy.value = false;
    }
  }

  return {
    accounts,
    userError,
    currentPassword,
    nextPassword,
    repeatPassword,
    passwordBusy,
    passwordError,
    loadAccounts,
    changeOwnPassword,
    resetAccountState,
  };
}
