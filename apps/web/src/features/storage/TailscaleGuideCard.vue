<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  Check,
  CheckCircle2,
  Copy,
  Download,
  ExternalLink,
  Network,
  RefreshCw,
  ShieldAlert,
} from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
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

const statusTone = computed<"online" | "warning" | "offline">(() => {
  if (!status.value) return "offline";
  if (status.value.running) return "online";
  if (status.value.installed) return "warning";
  return "offline";
});

const statusHeadline = computed(() => {
  if (!status.value) return "";
  if (status.value.running) return "Tailscale 加密组网已在线";
  if (status.value.installed) return "Tailscale 已安装，尚未登录连接";
  return "尚未检测到 Tailscale";
});

const statusSummary = computed(() => {
  if (!status.value) return "";
  if (status.value.running) {
    const parts: string[] = [];
    if (status.value.interface) parts.push(`接口 ${status.value.interface}`);
    if (typeof status.value.peerCount === "number" && status.value.peerCount > 0) {
      parts.push(`组网设备 ${status.value.peerCount} 台`);
    }
    if (endpointInfo.value) {
      parts.push(`${endpointInfo.value.protocol} :${endpointInfo.value.port} ${endpointInfo.value.listening ? "已监听" : "待开启"}`);
    }
    return parts.length ? parts.join(" · ") : "已加入 Tailnet 加密直连通道";
  }
  if (status.value.installed) {
    return "请在 Mac 菜单栏打开 Tailscale 并登录账号，连接后自动识别 100.x 直连地址";
  }
  return "在 Mac 安装并登录 Tailscale 后，手机与平板可在异地满速直连看原图与 4K 影片";
});

const isFullyReady = computed(() => Boolean(status.value?.running && status.value?.boundUrl));

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
          <div class="ts-hero-row" :class="`is-${statusTone}`">
            <div class="ts-hero-lead">
              <span class="ts-status-icon" :class="`is-${statusTone}`" aria-hidden="true">
                <CheckCircle2 v-if="status.running" :size="18" />
                <ShieldAlert v-else-if="status.installed" :size="18" />
                <Download v-else :size="18" />
              </span>
              <div class="ts-hero-copy">
                <div class="ts-hero-title">
                  <strong>{{ statusHeadline }}</strong>
                  <IsleBadge :variant="statusTone" dot size="sm">
                    {{ status.running ? "在线" : status.installed ? "待连接" : "未安装" }}
                  </IsleBadge>
                </div>
                <p class="ts-hero-sub ts-tabular">{{ statusSummary }}</p>
              </div>
            </div>
            <a
              v-if="!status.installed"
              :href="status.downloadUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="ts-download-btn"
            >
              <span>下载 macOS 版</span>
              <ExternalLink :size="13" aria-hidden="true" />
            </a>
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

          <div v-if="status.ipv4 || status.magicDns" class="ts-row">
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
            </div>
          </div>
        </IsleGroupedList>

        <IsleDisclosure
          v-if="isFullyReady"
          variant="inline"
          title="查看异地直连三步配置说明"
          subtitle="设备已在线监听，新增手机或电视端时可展开核对"
        >
          <IsleGroupedList variant="item" flush>
            <div class="ts-step-row">
              <div class="ts-step-main">
                <span class="ts-step-num is-done" aria-hidden="true"><CheckCircle2 :size="14" /></span>
                <div class="ts-step-copy">
                  <strong>在 Mac 与客户端登录同一 Tailscale 账号</strong>
                  <small>两端加入同一个 Tailnet 后自动建立加密直连通道</small>
                </div>
              </div>
              <IsleBadge variant="online" size="sm">已就绪</IsleBadge>
            </div>
            <div class="ts-step-row">
              <div class="ts-step-main">
                <span class="ts-step-num is-done" aria-hidden="true"><CheckCircle2 :size="14" /></span>
                <div class="ts-step-copy">
                  <strong>在轻屿 Mac 端开启「局域网访问」双栈监听</strong>
                  <small class="ts-tabular">自动绑定 100.x 接口（端口 :{{ endpointInfo?.port ?? "443" }}）并下发局域网/组网证书</small>
                </div>
              </div>
              <IsleBadge variant="online" size="sm">已监听</IsleBadge>
            </div>
            <div class="ts-step-row">
              <div class="ts-step-main">
                <span class="ts-step-num is-done" aria-hidden="true"><CheckCircle2 :size="14" /></span>
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
        </IsleDisclosure>

        <IsleGroupedList
          v-else
          title="异地直连步骤"
          subtitle="三步完成手机、平板或电视终端的点对点加密直连"
          variant="item"
          flush
        >
          <div class="ts-step-row">
            <div class="ts-step-main">
              <span class="ts-step-num ts-tabular" :class="{ 'is-done': status.running, 'is-active': !status.running }">
                <CheckCircle2 v-if="status.running" :size="14" />
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
              <span class="ts-step-num ts-tabular" :class="{ 'is-done': Boolean(status.boundUrl), 'is-active': status.running && !status.boundUrl }">
                <CheckCircle2 v-if="status.boundUrl" :size="14" />
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
            <IsleBadge v-else variant="neutral" size="sm">待就绪</IsleBadge>
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
  gap: 16px;
}

.ts-loading-hint {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}

.ts-tabular {
  font-variant-numeric: tabular-nums;
}

/* Unified Status Hero */
.ts-hero-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px 16px;
  padding: 15px 16px;
}

.ts-hero-row.is-online {
  background: color-mix(in srgb, var(--success, #167a54) 5%, transparent);
}

.ts-hero-row.is-warning {
  background: color-mix(in srgb, var(--warning, #9a5506) 5%, transparent);
}

.ts-hero-lead {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1 1 260px;
}

.ts-status-icon {
  width: 38px;
  height: 38px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}

.ts-status-icon.is-online {
  background: color-mix(in srgb, var(--success, #167a54) 12%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--success, #167a54) 26%, transparent);
  color: var(--success, #167a54);
}

.ts-status-icon.is-warning {
  background: color-mix(in srgb, var(--warning, #9a5506) 12%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--warning, #9a5506) 26%, transparent);
  color: var(--warning, #9a5506);
}

.ts-hero-copy {
  display: grid;
  gap: 3px;
  min-width: 0;
  flex: 1;
}

.ts-hero-title {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.ts-hero-title strong {
  font-size: 13.5px;
  font-weight: 650;
  color: var(--text-primary);
}

.ts-hero-sub {
  margin: 0;
  font-size: 12px;
  line-height: 1.45;
  color: var(--text-secondary);
}

.ts-download-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 32px;
  padding: 0 13px;
  border-radius: 9999px;
  background: color-mix(in srgb, var(--accent-primary) 10%, var(--fluid-card-top, #ffffff));
  border: 1px solid color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
  color: var(--accent-primary);
  font-size: 12px;
  font-weight: 600;
  text-decoration: none;
  white-space: nowrap;
  flex-shrink: 0;
  transition: background-color 150ms ease, border-color 150ms ease;
}

.ts-download-btn:hover {
  background: color-mix(in srgb, var(--accent-primary) 16%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--accent-primary) 38%, var(--fluid-card-border));
}

.ts-download-btn:focus-visible {
  outline: 2px solid var(--accent-primary);
  outline-offset: 2px;
}

/* Address & Copy Rows */
.ts-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 10px 14px;
  padding: 13px 16px;
}

.ts-pill-list {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.ts-copy-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 5px 10px;
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
  display: grid;
  gap: 2px;
  min-width: 0;
  flex: 1 1 200px;
}

.ts-url-info strong {
  display: block;
  font-size: 12.5px;
  font-weight: 620;
  color: var(--text-primary);
}

.ts-url-info code {
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  color: var(--text-secondary);
  user-select: all;
  overflow-wrap: anywhere;
}

/* Setup Steps */
.ts-step-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px 16px;
  flex-wrap: wrap;
  padding: 14px 16px;
}

.ts-step-main {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1 1 240px;
}

.ts-step-num {
  width: 26px;
  height: 26px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 650;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.ts-step-num.is-active {
  border-color: color-mix(in srgb, var(--accent-primary) 32%, transparent);
  background: color-mix(in srgb, var(--accent-primary) 10%, var(--fluid-card-top));
  color: var(--accent-primary);
}

.ts-step-num.is-done {
  border-color: color-mix(in srgb, var(--success, #167a54) 35%, transparent);
  background: color-mix(in srgb, var(--success, #167a54) 12%, transparent);
  color: var(--success, #167a54);
}

.ts-step-copy {
  display: grid;
  gap: 2px;
  min-width: 0;
}

.ts-step-copy strong {
  font-size: 13px;
  font-weight: 620;
  color: var(--text-primary);
  line-height: 1.4;
}

.ts-step-copy small {
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.45;
}

@media (prefers-reduced-motion: reduce) {
  .ts-copy-pill,
  .ts-download-btn {
    transition: none;
  }
}
</style>
