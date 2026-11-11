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
  write: <T>(path: string, method: "POST" | "PATCH" | "PUT", body?: object) => Promise<T>;
  logout: () => Promise<void>;
  onOwnPasswordChanged: () => void;
  confirm?: (options: { title: string; message: string }) => Promise<boolean>;
};

/**
 * Web account management (admin member creation, enable/disable, password reset)
 * and self-service password change.
 */
export function useAccountManagement(deps: AccountManagementDependencies) {
  const accounts = ref<ManagedAccount[]>([]);
  const userError = ref("");
  const currentPassword = ref("");
  const nextPassword = ref("");
  const repeatPassword = ref("");
  const passwordBusy = ref(false);
  const passwordError = ref("");

  const newUsername = ref("");
  const newPassword = ref("");
  const creatingUser = ref(false);
  const createUserError = ref("");
  const createUserNotice = ref("");

  const memberActionBusy = ref(false);
  const memberActionError = ref("");
  const memberActionNotice = ref("");

  const resetTargetUser = ref<ManagedAccount | null>(null);
  const resetMemberNewPassword = ref("");
  const resetMemberRepeatPassword = ref("");
  const resetMemberBusy = ref(false);
  const resetMemberError = ref("");

  const computerFilesStatus = ref<{ enabled: boolean; mode: string } | null>(null);
  const computerGrantUser = ref<ManagedAccount | null>(null);
  const computerGrantMode = ref<"none" | "folders" | "all">("none");
  const computerGrantFolders = ref<string[]>([]);
  const computerGrantFolderInput = ref("");
  const computerGrantBusy = ref(false);
  const computerGrantError = ref("");
  const computerGrantNotice = ref("");
  const computerGrantModeOptions = [
    { value: "none", label: "无权限" },
    { value: "folders", label: "指定文件夹" },
    { value: "all", label: "整台电脑（只读）" },
  ];

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
    newUsername.value = "";
    newPassword.value = "";
    creatingUser.value = false;
    createUserError.value = "";
    createUserNotice.value = "";
    memberActionBusy.value = false;
    memberActionError.value = "";
    memberActionNotice.value = "";
    resetTargetUser.value = null;
    resetMemberNewPassword.value = "";
    resetMemberRepeatPassword.value = "";
    resetMemberBusy.value = false;
    resetMemberError.value = "";
    computerFilesStatus.value = null;
    computerGrantUser.value = null;
    computerGrantMode.value = "none";
    computerGrantFolders.value = [];
    computerGrantFolderInput.value = "";
    computerGrantBusy.value = false;
    computerGrantError.value = "";
    computerGrantNotice.value = "";
  }

  async function loadComputerFilesStatus() {
    const request = generation;
    try {
      const status = await deps.read<{ enabled: boolean; mode: string }>("/api/v2/computer-files/status");
      if (request === generation) computerFilesStatus.value = status;
    } catch {
      if (request === generation) computerFilesStatus.value = null;
    }
  }

  async function editComputerGrants(account: ManagedAccount) {
    if (!deps.isAdmin() || account.role === "admin") return;
    computerGrantUser.value = account;
    computerGrantError.value = "";
    computerGrantNotice.value = "";
    computerGrantFolderInput.value = "";
    computerGrantBusy.value = true;
    const request = generation;
    try {
      const grant = await deps.read<{ mode: "none" | "folders" | "all"; folders: { path: string }[] }>(
        `/api/v2/computer-files/grants/${account.id}`,
      );
      if (request !== generation) return;
      computerGrantMode.value = grant.mode;
      computerGrantFolders.value = (grant.folders ?? []).map((f) => f.path);
    } catch (e) {
      if (request === generation) {
        computerGrantError.value = "读取电脑文件授权失败：" + describeUserFacingError(e);
      }
    } finally {
      if (request === generation) computerGrantBusy.value = false;
    }
  }

  function addComputerGrantFolder() {
    const p = computerGrantFolderInput.value.trim();
    if (!p || computerGrantFolders.value.includes(p)) return;
    computerGrantFolders.value.push(p);
    computerGrantFolderInput.value = "";
  }

  function removeComputerGrantFolder(p: string) {
    computerGrantFolders.value = computerGrantFolders.value.filter((item) => item !== p);
  }

  async function saveComputerGrants() {
    const target = computerGrantUser.value;
    if (!deps.isAdmin() || !target || computerGrantBusy.value) return;
    if (computerGrantMode.value === "folders" && computerGrantFolders.value.length === 0) {
      computerGrantError.value = "请至少添加一个允许访问的文件夹路径，或前往「电脑文件」页面浏览选择。";
      return;
    }
    if (
      computerGrantMode.value === "all" &&
      deps.confirm &&
      !(await deps.confirm({
        title: "授权整台电脑",
        message: "该成员可以查看和下载 Mac 允许轻屿读取的所有文件，包括其他成员的私人文件。确认授权？",
      }))
    ) {
      return;
    }
    computerGrantError.value = "";
    computerGrantNotice.value = "";
    computerGrantBusy.value = true;
    const request = generation;
    try {
      await deps.write(`/api/v2/computer-files/grants/${target.id}`, "PUT", {
        mode: computerGrantMode.value,
        paths: computerGrantFolders.value,
      });
      if (request === generation) {
        computerGrantNotice.value = `已保存成员「${target.username}」的电脑文件访问权限。`;
      }
    } catch (e) {
      if (request === generation) {
        computerGrantError.value = "保存电脑文件授权失败：" + describeUserFacingError(e);
      }
    } finally {
      if (request === generation) computerGrantBusy.value = false;
    }
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

  async function createMemberAccount() {
    if (!deps.isAdmin() || creatingUser.value) return;
    createUserError.value = "";
    createUserNotice.value = "";
    const username = newUsername.value.trim();
    if (username.length < 3 || username.length > 32) {
      createUserError.value = "用户名长度需为 3–32 个字符。";
      return;
    }
    if (
      newPassword.value.length < 12 ||
      newPassword.value.length > 256 ||
      newPassword.value.trim() !== newPassword.value
    ) {
      createUserError.value = "初始密码必须为 12–256 位，且不能以空格开头或结尾。";
      return;
    }
    const request = generation;
    creatingUser.value = true;
    try {
      await deps.write("/api/v2/users", "POST", {
        username,
        password: newPassword.value,
        role: "member",
      });
      if (request !== generation) return;
      newUsername.value = "";
      newPassword.value = "";
      createUserNotice.value = `已创建成员账号「${username}」。`;
      await loadAccounts();
    } catch (error) {
      if (request !== generation) return;
      const code = error instanceof Error ? error.message : "request_failed";
      const labels: Record<string, string> = {
        user_exists: "该用户名已存在，请换一个名称。",
        invalid_username: "用户名格式不符合要求（建议使用字母、数字、下划线或短横线）。",
        invalid_password: "初始密码不符合安全要求（需 12–256 位且首尾无空格）。",
      };
      createUserError.value = labels[code] ?? "创建成员账号失败：" + describeUserFacingError(error);
    } finally {
      if (request === generation) creatingUser.value = false;
    }
  }

  async function toggleMemberEnabled(account: ManagedAccount) {
    if (!deps.isAdmin() || memberActionBusy.value || account.role === "admin") return;
    memberActionError.value = "";
    memberActionNotice.value = "";
    const targetEnabled = !account.enabled;
    const request = generation;
    memberActionBusy.value = true;
    try {
      await deps.write(`/api/v2/users/${account.id}`, "PATCH", {
        enabled: targetEnabled,
      });
      if (request !== generation) return;
      memberActionNotice.value = targetEnabled
        ? `已启用成员「${account.username}」。`
        : `已停用成员「${account.username}」，其登录会话与公开分享已撤销。`;
      await loadAccounts();
    } catch (error) {
      if (request !== generation) return;
      memberActionError.value = "更新账号状态失败：" + describeUserFacingError(error);
    } finally {
      if (request === generation) memberActionBusy.value = false;
    }
  }

  function openResetMemberPassword(account: ManagedAccount) {
    if (account.role === "admin") return;
    resetTargetUser.value = account;
    resetMemberNewPassword.value = "";
    resetMemberRepeatPassword.value = "";
    resetMemberError.value = "";
  }

  function closeResetMemberPassword() {
    resetTargetUser.value = null;
    resetMemberNewPassword.value = "";
    resetMemberRepeatPassword.value = "";
    resetMemberError.value = "";
  }

  async function submitResetMemberPassword() {
    const target = resetTargetUser.value;
    if (!deps.isAdmin() || !target || resetMemberBusy.value) return;
    resetMemberError.value = "";
    if (
      resetMemberNewPassword.value.length < 12 ||
      resetMemberNewPassword.value.length > 256 ||
      resetMemberNewPassword.value.trim() !== resetMemberNewPassword.value
    ) {
      resetMemberError.value = "新密码必须为 12–256 位，且不能以空格开头或结尾。";
      return;
    }
    if (resetMemberNewPassword.value !== resetMemberRepeatPassword.value) {
      resetMemberError.value = "两次输入的新密码不一致。";
      return;
    }
    const request = generation;
    resetMemberBusy.value = true;
    try {
      await deps.write(`/api/v2/users/${target.id}/password`, "POST", {
        password: resetMemberNewPassword.value,
      });
      if (request !== generation) return;
      memberActionNotice.value = `已重置成员「${target.username}」的密码，其已有登录会话已失效。`;
      closeResetMemberPassword();
    } catch (error) {
      if (request !== generation) return;
      resetMemberError.value = "重置成员密码失败：" + describeUserFacingError(error);
    } finally {
      if (request === generation) resetMemberBusy.value = false;
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
    newUsername,
    newPassword,
    creatingUser,
    createUserError,
    createUserNotice,
    memberActionBusy,
    memberActionError,
    memberActionNotice,
    resetTargetUser,
    resetMemberNewPassword,
    resetMemberRepeatPassword,
    resetMemberBusy,
    resetMemberError,
    computerFilesStatus,
    computerGrantUser,
    computerGrantMode,
    computerGrantFolders,
    computerGrantFolderInput,
    computerGrantBusy,
    computerGrantError,
    computerGrantNotice,
    computerGrantModeOptions,
    loadAccounts,
    loadComputerFilesStatus,
    createMemberAccount,
    toggleMemberEnabled,
    openResetMemberPassword,
    closeResetMemberPassword,
    submitResetMemberPassword,
    editComputerGrants,
    addComputerGrantFolder,
    removeComputerGrantFolder,
    saveComputerGrants,
    changeOwnPassword,
    resetAccountState,
  };
}
