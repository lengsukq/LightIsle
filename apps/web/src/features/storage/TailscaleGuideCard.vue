<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  Network,
  Copy,
  Check,
  RefreshCw,
  ExternalLink,
  CheckCircle2,
} from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";

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

const endpointInfo = computed(() => {
  const raw = status.value?.boundUrl || status.value?.suggestedUrl || "";
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    const port = parsed.port || (parsed.protocol === "https:" ? "443" : "80");
    return {
      protocol: parsed.protocol === "https:" ? "HTTPS" : "HTTP",
      port,
      listening: Boolean(status.value?.boundUrl),
    };
  } catch {
    return {
      protocol: "HTTPS",
      port: "443",
      listening: Boolean(status.value?.boundUrl),
    };
  }
});

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
      <button
        type="button"
        class="storage-header-refresh"
        :disabled="loading"
        aria-label="刷新组网状态"
        title="刷新组网状态"
        @click="refresh"
      >
        <RefreshCw :size="14" :class="{ 'is-spinning': loading }" />
      </button>
    </template>

    <div class="ts-body">
      <p v-if="loading && !status" class="ts-loading-hint" role="status">正在读取 Tailscale 组网状态…</p>
      <IsleBanner v-if="error" type="error" compact>
        {{ error }}
        <template v-if="!status" #action>
          <IsleButton variant="glass" size="sm" :loading="loading" @click="refresh">重试</IsleButton>
        </template>
      </IsleBanner>

      <template v-if="status">
        <IsleGroupedList variant="item" flush>
          <div class="ts-row">
            <div class="ts-badges">
              <IsleBadge :variant="status.running ? 'online' : status.installed ? 'warning' : 'offline'" dot size="sm">
                {{ status.running ? "Tailscale 在线" : status.installed ? "已安装 · 未连接" : "尚未安装 Tailscale" }}
              </IsleBadge>
              <IsleBadge v-if="typeof status.peerCount === 'number' && status.peerCount > 0" variant="neutral" size="sm" class="ts-tabular">
                组网设备 {{ status.peerCount }} 台
              </IsleBadge>
              <IsleBadge v-if="status.interface" variant="neutral" size="sm" class="ts-tabular">
                {{ status.interface }}
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

          <div v-if="status.ipv4 || status.magicDns || endpointInfo" class="ts-row">
            <div class="ts-pill-list ts-tabular">
              <button
                v-if="status.ipv4"
                type="button"
                class="ts-copy-pill"
                :class="{ 'is-copied': copied === 'ipv4' }"
                title="点击复制 Tailscale IPv4"
                @click="copyText(status.ipv4, 'ipv4')"
              >
                <span class="ts-pill-label">IPv4</span>
                <code>{{ status.ipv4 }}</code>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="copied === 'ipv4'" key="ok" :size="12" />
                  <Copy v-else key="copy" :size="12" />
                </Transition>
              </button>

              <button
                v-if="status.magicDns"
                type="button"
                class="ts-copy-pill"
                :class="{ 'is-copied': copied === 'dns' }"
                title="点击复制 MagicDNS 域名"
                @click="copyText(status.magicDns, 'dns')"
              >
                <span class="ts-pill-label">MagicDNS</span>
                <code>{{ status.magicDns }}</code>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="copied === 'dns'" key="ok" :size="12" />
                  <Copy v-else key="copy" :size="12" />
                </Transition>
              </button>

              <IsleBadge v-if="endpointInfo" :variant="endpointInfo.listening ? 'online' : 'neutral'" dot size="sm" class="ts-tabular">
                {{ endpointInfo.protocol }} 端口 :{{ endpointInfo.port }} · {{ endpointInfo.listening ? "已监听" : "待开启" }}
              </IsleBadge>
            </div>
          </div>

          <div v-if="status.suggestedUrl" class="ts-row ts-url-row">
            <div class="ts-url-info">
              <strong>异地直连地址{{ status.boundUrl ? "（已监听）" : "（开启 Mac 局域网访问后生效）" }}</strong>
              <code class="ts-tabular">{{ status.suggestedUrl }}</code>
            </div>
            <IsleButton
              variant="tonal"
              size="sm"
              :class="{ 'is-copied': copied === 'url' }"
              @click="copyText(status.suggestedUrl, 'url')"
            >
              <template #icon>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="copied === 'url'" key="ok" :size="12" />
                  <Copy v-else key="copy" :size="12" />
                </Transition>
              </template>
              {{ copied === "url" ? "已复制地址" : "复制组网地址" }}
            </IsleButton>
          </div>
        </IsleGroupedList>

        <IsleGroupedList
          title="异地直连步骤"
          subtitle="三步完成手机、平板或电视终端的点对点加密直连"
          variant="item"
          flush
        >
          <div class="ts-step-row">
            <div class="ts-step-main">
              <span class="ts-step-num ts-tabular" :class="{ 'is-done': status.running }">
                <CheckCircle2 v-if="status.running" :size="13" />
                <template v-else>1</template>
              </span>
              <div class="ts-step-copy">
                <strong>在 Mac 与客户端登录同一 Tailscale 账号</strong>
                <small>两端加入同一个 Tailnet 后自动建立加密直连通道</small>
              </div>
            </div>
            <IsleBadge :variant="status.running ? 'online' : status.installed ? 'warning' : 'neutral'" size="sm">
              {{ status.running ? "已就绪" : status.installed ? "待连接" : "未安装" }}
            </IsleBadge>
          </div>

          <div class="ts-step-row">
            <div class="ts-step-main">
              <span class="ts-step-num ts-tabular" :class="{ 'is-done': Boolean(status.boundUrl) }">
                <CheckCircle2 v-if="status.boundUrl" :size="13" />
                <template v-else>2</template>
              </span>
              <div class="ts-step-copy">
                <strong>在轻屿 Mac 端开启「局域网访问」双栈监听</strong>
                <small class="ts-tabular">自动绑定 100.x 接口（端口 :{{ endpointInfo?.port ?? "443" }}）并下发局域网/组网证书</small>
              </div>
            </div>
            <IsleBadge :variant="status.boundUrl ? 'online' : 'neutral'" size="sm">
              {{ status.boundUrl ? "已监听" : "待开启" }}
            </IsleBadge>
          </div>

          <div class="ts-step-row">
            <div class="ts-step-main">
              <span class="ts-step-num ts-tabular">3</span>
              <div class="ts-step-copy">
                <strong>使用直连地址访问网页或挂载 WebDAV</strong>
                <small>可直接在浏览器打开，或配合上方 WebDAV 地址与独立密码接入 Infuse</small>
              </div>
            </div>
            <IsleButton
              v-if="status.suggestedUrl"
              variant="glass"
              size="sm"
              @click="copyText(status.suggestedUrl, 'step-url')"
            >
              <template #icon>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="copied === 'step-url'" key="ok" :size="12" />
                  <Copy v-else key="copy" :size="12" />
                </Transition>
              </template>
              {{ copied === "step-url" ? "已复制" : "复制地址" }}
            </IsleButton>
          </div>
        </IsleGroupedList>
      </template>
    </div>
  </IsleCard>
</template>

<style scoped>
.ts-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.ts-loading-hint {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.ts-tabular {
  font-variant-numeric: tabular-nums;
}
.ts-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px 12px;
  padding: 11px 16px;
}
.ts-badges,
.ts-pill-list {
  display: flex;
  align-items: center;
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
.ts-copy-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 9px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-primary);
  font-size: 11.5px;
  cursor: pointer;
  transition: border-color 150ms ease, background-color 150ms ease, color 150ms ease;
}
.ts-copy-pill:hover {
  border-color: var(--accent-primary);
  color: var(--accent-primary);
}
.ts-copy-pill.is-copied {
  border-color: color-mix(in srgb, var(--success, #167a54) 45%, transparent);
  color: var(--success, #167a54);
}
.ts-pill-label {
  font-size: 10.5px;
  color: var(--text-tertiary);
  font-weight: 600;
}
.ts-copy-pill code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11.5px;
}
.ts-url-info {
  min-width: 0;
  flex: 1 1 200px;
}
.ts-url-info strong {
  display: block;
  font-size: 12px;
  margin-bottom: 2px;
}
.ts-url-info code {
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  user-select: all;
  overflow-wrap: anywhere;
}
.ts-step-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 11px 16px;
}
.ts-step-main {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1 1 220px;
}
.ts-step-num {
  width: 22px;
  height: 22px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  font-size: 11.5px;
  font-weight: 650;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.ts-step-num.is-done {
  border-color: color-mix(in srgb, var(--success, #167a54) 35%, transparent);
  background: color-mix(in srgb, var(--success, #167a54) 12%, transparent);
  color: var(--success, #167a54);
}
.ts-step-copy {
  display: grid;
  gap: 1px;
  min-width: 0;
}
.ts-step-copy strong {
  font-size: 12.5px;
  font-weight: 620;
  color: var(--text-primary);
}
.ts-step-copy small {
  font-size: 11.5px;
  color: var(--text-secondary);
  line-height: 1.4;
}
@media (prefers-reduced-motion: reduce) {
  .ts-copy-pill {
    transition: none;
  }
}
</style>
