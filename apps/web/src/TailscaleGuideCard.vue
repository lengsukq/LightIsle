<script setup lang="ts">
import { onMounted, ref } from "vue";
import { Network, Copy, RefreshCw, ExternalLink } from "lucide-vue-next";
import { apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";

type TailscaleStatus = {
  installed: boolean;
  running: boolean;
  backendState?: string;
  interface?: string;
  ipv4?: string;
  magicDns?: string;
  tailnetName?: string;
  peerCount?: number;
  boundUrl?: string;
  suggestedUrl?: string;
  downloadUrl: string;
};

const status = ref<TailscaleStatus | null>(null);
const loading = ref(false);
const error = ref("");
const copied = ref("");

async function refresh() {
  if (loading.value) return;
  loading.value = true;
  error.value = "";
  try {
    status.value = await apiRequest<TailscaleStatus>("/api/v2/admin/tailscale");
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    loading.value = false;
  }
}

function copyText(text: string, label: string) {
  if (!text) return;
  navigator.clipboard?.writeText(text).then(() => {
    copied.value = label;
    setTimeout(() => {
      if (copied.value === label) copied.value = "";
    }, 2000);
  });
}

onMounted(() => {
  void refresh();
});
</script>

<template>
  <IsleCard
    title="远程访问与组网连接（主推方案 + 高级穿透）"
    subtitle="主推 Tailscale 零配置加密组网：无需公网 IP 或云服务器，开启 Mac 局域网访问后自动双栈绑定本机 100.x 虚拟组网接口与多域名 TLS 证书。"
  >
    <template #icon><Network :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" :loading="loading" @click="refresh">
        <template #icon><RefreshCw :size="14" /></template>
        刷新状态
      </IsleButton>
    </template>

    <div class="ts-body">
      <div class="ts-recommend-banner">
        <strong>主推方案：Tailscale 零配置加密组网</strong>
        <IsleBadge variant="accent" size="sm">推荐日常使用</IsleBadge>
      </div>
      <IsleBanner v-if="error" type="error" compact :message="error" />

      <template v-if="status">
        <div class="ts-status-row">
          <div class="ts-badges">
            <IsleBadge :variant="status.running ? 'online' : status.installed ? 'warning' : 'offline'" dot size="sm">
              {{ status.running ? "Tailscale 在线" : status.installed ? "已安装 · 未连接" : "尚未安装 Tailscale" }}
            </IsleBadge>
            <IsleBadge v-if="status.ipv4" variant="neutral" size="sm">{{ status.ipv4 }}</IsleBadge>
            <IsleBadge v-if="status.magicDns" variant="neutral" size="sm">{{ status.magicDns }}</IsleBadge>
            <IsleBadge v-if="typeof status.peerCount === 'number' && status.peerCount > 0" variant="neutral" size="sm">
              组网设备 {{ status.peerCount }} 台
            </IsleBadge>
          </div>
          <a
            v-if="!status.installed"
            :href="status.downloadUrl"
            target="_blank"
            rel="noopener noreferrer"
            class="ts-download-link"
          >
            前往下载 macOS 版 Tailscale <ExternalLink :size="13" />
          </a>
        </div>

        <div v-if="status.suggestedUrl" class="ts-url-box">
          <div>
            <strong>异地直连地址{{ status.boundUrl ? "（已绑定监听）" : "（开启 Mac 局域网访问后生效）" }}</strong>
            <code>{{ status.suggestedUrl }}</code>
          </div>
          <IsleButton variant="tonal" size="sm" @click="copyText(status.suggestedUrl, 'url')">
            <template #icon><Copy :size="13" /></template>
            {{ copied === "url" ? "已复制地址" : "复制组网地址" }}
          </IsleButton>
        </div>

        <p class="ts-hint">
          在 Mac 与手机安装登录同一 Tailscale 账号后，于轻屿 Mac 端打开「网络与连接 → 局域网访问」，即可在异地通过上方地址满速直连看原图与 4K 影片。
        </p>
      </template>

      <details class="apple-disclosure-card">
        <summary>
          <div class="disclosure-title"><span>高级穿透选项（Cloudflare Tunnel / FRP）</span></div>
        </summary>
        <div class="disclosure-body">
          <p class="ts-hint" style="margin:0">
            若需向未安装 Tailscale 的访客提供免客户端域名访问，可在 LightIsle Mac 端「网络与连接」中配置
            <strong>Cloudflare Tunnel</strong>（支持临时 trycloudflare.com 或自定义域名）或自建 <strong>FRP 客户端（frpc）</strong>。日常个人与家庭使用建议保持以上 Tailscale 主推直连方案，延迟更低且全链路端到端加密。
          </p>
        </div>
      </details>
    </div>
  </IsleCard>
</template>

<style scoped>
.ts-recommend-banner {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 13px;
  color: var(--text-primary);
}
.ts-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.ts-status-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 10px;
}
.ts-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.ts-download-link {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--accent-primary, #0071e3);
  text-decoration: none;
}
.ts-url-box {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border, rgba(0, 0, 0, 0.08));
  background: var(--fluid-card-item-fill, rgba(255, 255, 255, 0.6));
}
.ts-url-box strong {
  display: block;
  font-size: 12.5px;
  margin-bottom: 4px;
}
.ts-url-box code {
  font-size: 12.5px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  user-select: all;
}
.ts-hint {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary, #6e6e73);
  line-height: 1.55;
}
</style>
