<script setup lang="ts">
import { Eye, EyeOff } from "lucide-vue-next";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";

defineProps<{
  authChecking: boolean;
  authServiceError: string;
  configured: boolean;
  authUsername: string;
  authPassword: string;
  showAuthPassword: boolean;
  authSubmitting: boolean;
  authError: string;
}>();

const emit = defineEmits<{
  (e: "check-auth"): void;
  (e: "submit-auth"): void;
  (e: "update:authUsername", value: string): void;
  (e: "update:authPassword", value: string): void;
  (e: "update:showAuthPassword", value: boolean): void;
}>();

const authHelpItems = [
  {
    title: "本地私有与原片保护",
    body: "所有照片、影片与文件均保存在当前 Mac 及接入硬盘，不经过第三方云端中转。",
  },
  {
    title: "账号与密码管理",
    body: "首次管理员账号在 Mac 端 LightIsle.app 中创建；家庭成员账号由管理员登录后在「偏好设置 → 成员与空间」中创建与分配。",
  },
];
</script>

<template>
  <div v-if="authChecking" class="auth-scene">
    <div class="auth-card auth-card--status">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <h2>轻屿 LightIsle</h2>
      <p>正在连接本机空间…</p>
    </div>
  </div>
  <div v-else-if="authServiceError" class="auth-scene">
    <div class="auth-card">
      <div class="auth-brand-row">
        <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
        <div class="auth-brand-meta">
          <h1>暂时无法连接轻屿</h1>
          <p>请确认 Mac 端 LightIsle.app 正在运行</p>
        </div>
      </div>
      <p class="form-error" role="alert">{{ authServiceError }}</p>
      <button type="button" class="auth-submit" :disabled="authChecking" @click="emit('check-auth')">
        {{ authChecking ? "正在重试…" : "重试连接" }}
      </button>
    </div>
  </div>
  <div v-else-if="!configured" class="auth-scene">
    <div class="auth-card">
      <div class="auth-brand-row">
        <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
        <div class="auth-brand-meta">
          <h1>请先在 Mac 端完成初始化</h1>
          <p>打开 LightIsle.app 创建首个管理员账号</p>
        </div>
        <IsleHelpButton
          title="首次启用说明"
          :items="[
            { title: '为什么不能直接在网页注册？', body: '为防止局域网或公网未授权抢注，首个管理员账号仅限在宿主 Mac 本机应用中初始化。' },
            { title: '家庭成员如何登录？', body: '管理员初始化并登录后，可在「偏好设置 → 账号与安全」中为家人创建独立账号与配额。' },
          ]"
        />
      </div>
      <button type="button" class="auth-submit" @click="emit('check-auth')">已完成初始化，刷新状态</button>
    </div>
  </div>
  <div v-else class="auth-scene">
    <form class="auth-card" @submit.prevent="emit('submit-auth')">
      <div class="auth-brand-row">
        <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
        <div class="auth-brand-meta">
          <h1>轻屿</h1>
          <p>登录本地家庭空间</p>
        </div>
        <IsleHelpButton title="登录与本地隐私说明" :items="authHelpItems" />
      </div>
      <label>
        <span>用户名</span>
        <input
          :value="authUsername"
          autofocus
          required
          maxlength="32"
          minlength="3"
          autocomplete="username"
          placeholder="输入用户名"
          @input="emit('update:authUsername', ($event.target as HTMLInputElement).value.trim())"
        />
      </label>
      <label>
        <span>密码</span>
        <div class="password-input-wrap">
          <input
            :value="authPassword"
            required
            :type="showAuthPassword ? 'text' : 'password'"
            minlength="12"
            autocomplete="current-password"
            placeholder="输入密码（至少 12 位）"
            @input="emit('update:authPassword', ($event.target as HTMLInputElement).value)"
          />
          <button
            type="button"
            class="password-eye-btn"
            :title="showAuthPassword ? '隐藏密码' : '显示密码'"
            :aria-label="showAuthPassword ? '隐藏密码' : '显示密码'"
            @click="emit('update:showAuthPassword', !showAuthPassword)"
          >
            <EyeOff v-if="showAuthPassword" :size="15" />
            <Eye v-else :size="15" />
          </button>
        </div>
      </label>
      <p v-if="authError" class="form-error" role="alert">{{ authError }}</p>
      <button class="auth-submit" :disabled="authSubmitting" type="submit">
        {{ authSubmitting ? "正在登录…" : "进入轻屿" }}
      </button>
    </form>
  </div>
</template>

<style scoped>
@keyframes authCardReveal {
  from {
    opacity: 0;
    transform: translate3d(0, 10px, 0) scale(0.982);
  }
  to {
    opacity: 1;
    transform: translate3d(0, 0, 0) scale(1);
  }
}

.auth-card {
  width: min(100%, 384px);
  padding: 28px 28px 24px;
  border-radius: 22px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  box-shadow: var(--shadow-float, var(--fluid-card-shadow));
  gap: 15px;
  animation: authCardReveal 0.28s cubic-bezier(0.22, 1, 0.36, 1) both;
}

.auth-card--status {
  text-align: center;
  align-items: center;
  padding: 32px 26px;
}

.auth-card--status h2 {
  margin: 0;
  font-size: 17px;
  font-weight: 680;
  letter-spacing: -0.015em;
}

.auth-card--status p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}

.auth-brand-row {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 2px;
}

.auth-brand-row .auth-logo {
  width: 42px;
  height: 42px;
  border-radius: 12px;
  margin-bottom: 0;
  flex-shrink: 0;
}

.auth-brand-meta {
  display: grid;
  gap: 2px;
  min-width: 0;
  flex: 1;
}

.auth-brand-meta h1 {
  margin: 0;
  font-size: 19px;
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.25;
  color: var(--text-primary);
}

.auth-brand-meta p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.auth-card label {
  display: grid;
  gap: 6px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}

.auth-card input {
  height: 40px;
  padding: 0 13px;
  border-radius: 11px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  font-size: 13.5px;
}

.auth-submit {
  min-height: 40px;
  border-radius: 999px;
  font-size: 13.5px;
  font-weight: 600;
  margin-top: 4px;
  transition:
    transform 240ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    filter 160ms ease,
    opacity 160ms ease;
}

.auth-submit:active:not(:disabled) {
  transform: scale(0.975);
  transition-duration: 95ms;
}

@media (prefers-reduced-motion: reduce) {
  .auth-card {
    animation: none;
  }
  .auth-submit {
    transition: none;
  }
}
</style>
