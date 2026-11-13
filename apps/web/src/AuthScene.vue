<script setup lang="ts">
import { Eye, EyeOff } from "lucide-vue-next";

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
</script>

<template>
  <div v-if="authChecking" class="auth-scene">
    <div class="auth-card" style="text-align: center; align-items: center;">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <h2>轻屿 LightIsle</h2>
      <p>正在读取本机账户安全状态…</p>
    </div>
  </div>
  <div v-else-if="authServiceError" class="auth-scene">
    <div class="auth-card">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">本机私有服务</span>
      <h1>暂时无法连接轻屿</h1>
      <p class="form-error" role="alert">{{ authServiceError }}</p>
      <button type="button" class="auth-submit" :disabled="authChecking" @click="emit('check-auth')">
        {{ authChecking ? "正在重试…" : "重试连接" }}
      </button>
    </div>
  </div>
  <div v-else-if="!configured" class="auth-scene">
    <div class="auth-card">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">首次启用向导</span>
      <h1>请先在 Mac 上初始化轻屿</h1>
      <p>首次管理员账号请在 Mac 端 LightIsle.app 中创建，Web 不开放未授权注册。</p>
      <button type="button" class="auth-submit" @click="emit('check-auth')">已完成初始化，刷新状态</button>
      <small>其他家庭成员账号可在登录后前往设置创建。</small>
    </div>
  </div>
  <div v-else class="auth-scene">
    <form class="auth-card" @submit.prevent="emit('submit-auth')">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">个人私密空间</span>
      <h1>欢迎回到轻屿</h1>
      <p>登录你的本地私有空间。</p>
      <label>
        用户名
        <input
          :value="authUsername"
          autofocus
          required
          maxlength="32"
          minlength="3"
          autocomplete="username"
          placeholder="输入账号用户名"
          @input="emit('update:authUsername', ($event.target as HTMLInputElement).value.trim())"
        />
      </label>
      <label>
        密码
        <div class="password-input-wrap">
          <input
            :value="authPassword"
            required
            :type="showAuthPassword ? 'text' : 'password'"
            minlength="12"
            autocomplete="current-password"
            placeholder="输入至少 12 位密码"
            @input="emit('update:authPassword', ($event.target as HTMLInputElement).value)"
          />
          <button
            type="button"
            class="password-eye-btn"
            :title="showAuthPassword ? '隐藏密码' : '显示密码'"
            :aria-label="showAuthPassword ? '隐藏密码' : '显示密码'"
            @click="emit('update:showAuthPassword', !showAuthPassword)"
          >
            <EyeOff v-if="showAuthPassword" :size="16" />
            <Eye v-else :size="16" />
          </button>
        </div>
      </label>
      <p v-if="authError" class="form-error" role="alert">{{ authError }}</p>
      <button class="auth-submit" :disabled="authSubmitting" type="submit">
        {{ authSubmitting ? "正在验证…" : "登录轻屿空间" }}
      </button>
      <small>数据安全保护 · 原片与文件均存放于本地 Mac</small>
    </form>
  </div>
</template>
