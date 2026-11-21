<script setup lang="ts">
import { onMounted, ref } from "vue";
import { Network, Copy, RefreshCw, ExternalLink } from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";

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

const guideHelpItems = [
  {
    title: "Tailscale 零配置加密直连（推荐）",
    body: "无需公网 IP 或云服务器。在 Mac 与手机登录同一 Tailscale 账号后，于轻屿 Mac 端打开「网络与连接 → 局域网访问」，即可自动双栈绑定 100.x 组网接口与多域名 TLS 证书，在异地满速直连看原图与 4K 影片。",
  },
  {
    title: "高级穿透选项（Cloudflare Tunnel / FRP）",
    body: "若需向未安装 Tailscale 的访客提供免客户端域名访问，可在 LightIsle Mac 端「网络与连接」中配置 Cloudflare Tunnel 或自建 FRP 客户端（frpc）。",
  },
];

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

async function copyText(text: string, label: string) {
  if (!text) return;
  if (await copyTextToClipboard(text)) {
    copied.value = label;
    setTimeout(() => {
      if (copied.value === label) copied.value = "";
    }, TIMINGS_MS.COPIED_FEEDBACK);
  } else {
    error.value = "浏览器限制自动复制，请手动选中上方组网地址后复制。";
  }
}

onMounted(() => {
  void refresh();
});
</script>

<template>
  <IsleCard
    title="远程访问与加密组网"
    subtitle="无需公网 IP，推荐通过 Tailscale 实现异地原画直连。"
  >
    <template #icon><Network :size="18" /></template>
    <template #actions>
      <IsleHelpButton title="异地组网与高级穿透说明" :items="guideHelpItems" modal-size="md" />
      <IsleButton variant="glass" size="sm" :loading="loading" @click="refresh">
        <template #icon><RefreshCw :size="14" /></template>
        刷新状态
      </IsleButton>
    </template>

    <div class="ts-body">
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
            下载 macOS 版 Tailscale <ExternalLink :size="13" />
          </a>
        </div>

        <div v-if="status.suggestedUrl" class="ts-url-box">
          <div>
            <strong>异地直连地址{{ status.boundUrl ? "（已监听）" : "（开启 Mac 局域网访问后生效）" }}</strong>
            <code>{{ status.suggestedUrl }}</code>
          </div>
          <IsleButton variant="tonal" size="sm" @click="copyText(status.suggestedUrl, 'url')">
            <template #icon><Copy :size="12" /></template>
            {{ copied === "url" ? "已复制地址" : "复制组网地址" }}
          </IsleButton>
        </div>
      </template>
    </div>
  </IsleCard>
</template>

<style scoped>
.ts-body {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.ts-status-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
}
.ts-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.ts-download-link {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 12px;
  font-weight: 600;
  color: var(--accent-primary, #1f5162);
  text-decoration: none;
}
.ts-url-box {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.ts-url-box > div {
  min-width: 0;
  flex: 1 1 200px;
}
.ts-url-box strong {
  display: block;
  font-size: 12px;
  margin-bottom: 3px;
}
.ts-url-box code {
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  user-select: all;
  overflow-wrap: anywhere;
}
</style>
