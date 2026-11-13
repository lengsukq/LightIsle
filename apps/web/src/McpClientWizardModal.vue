<script setup lang="ts">
import { computed, ref } from "vue";
import { AlertTriangle, Check, Copy, Globe, Laptop, Sparkles, Terminal } from "lucide-vue-next";
import IsleModal from "./IsleModal.vue";
import IsleBadge from "./IsleBadge.vue";

type WizardTab = "gemini" | "claude" | "cursor" | "cloud";

const GEMINI_SERVER_NAME = "轻屿 LightIsle";
const GEMINI_DESCRIPTION = "管理轻屿私有空间的文件、时光相册、私人影院、下载任务与家庭轻应用";
const GEMINI_LOCAL_COMMAND = "/Applications/LightIsle.app/Contents/Resources/core/lightisled mcp";

const props = defineProps<{
  open: boolean;
  mcpEnabled: boolean;
  mcpLanEnabled: boolean;
  mcpToken: string;
  mcpPrompt: string;
  lanMcpPrompt: string;
  lanHttpUrl: string;
  lanSseUrl: string;
  busy?: boolean;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "copy", text: string, notice: string): void;
  (e: "enable-mcp"): void;
  (e: "enable-lan-mcp"): void;
}>();

const activeTab = ref<WizardTab>("gemini");
const copiedKey = ref("");
let copiedTimer: ReturnType<typeof setTimeout> | null = null;

const originBase = computed(() => {
  if (typeof window !== "undefined" && window.location?.origin) {
    return window.location.origin.replace(/\/$/, "");
  }
  return "http://127.0.0.1:16666";
});

const effectiveHttpUrl = computed(() => {
  if (props.lanHttpUrl) return props.lanHttpUrl;
  return `${originBase.value}/api/v2/mcp`;
});

const effectiveSseUrl = computed(() => {
  if (props.lanSseUrl) return props.lanSseUrl;
  return `${originBase.value}/api/v2/mcp/sse`;
});

const tokenDisplay = computed(() => props.mcpToken || "<开启服务后自动生成 Token>");

const claudeDesktopJson = computed(() => JSON.stringify({
  mcpServers: {
    lightisle: {
      command: "/Applications/LightIsle.app/Contents/Resources/core/lightisled",
      args: ["mcp"],
    },
  },
}, null, 2));

const cursorJson = computed(() => {
  const servers: Record<string, unknown> = {
    lightisle: {
      command: "/Applications/LightIsle.app/Contents/Resources/core/lightisled",
      args: ["mcp"],
    },
  };
  if (props.mcpLanEnabled) {
    servers["lightisle-lan"] = {
      type: "streamable-http",
      url: effectiveHttpUrl.value,
      headers: {
        Authorization: `Bearer ${tokenDisplay.value}`,
      },
    };
  }
  return JSON.stringify({ mcpServers: servers }, null, 2);
});

const cloudJson = computed(() => JSON.stringify({
  mcpServers: {
    "lightisle-cloud": {
      type: "streamable-http",
      url: effectiveHttpUrl.value,
      headers: {
        Authorization: `Bearer ${tokenDisplay.value}`,
        "X-LightIsle-MCP-Token": tokenDisplay.value,
      },
    },
  },
}, null, 2));

function triggerCopy(key: string, value: string, notice: string) {
  emit("copy", value, notice);
  copiedKey.value = key;
  if (copiedTimer) clearTimeout(copiedTimer);
  copiedTimer = setTimeout(() => {
    if (copiedKey.value === key) copiedKey.value = "";
  }, 1800);
}
</script>

<template>
  <IsleModal
    v-if="open"
    title="AI Agent 客户端接入向导"
    description="按客户端类型查看 1:1 配置字段或复制 JSON，支持 Gemini 桌面端本地沙盒桥接与局域网 / Cloud MCP。"
    size="lg"
    @close="emit('close')"
  >
    <div class="wizard-wrap">
      <div v-if="!mcpEnabled" class="wizard-alert wizard-alert-info">
        <div class="wizard-alert-body">
          <strong>当前 AI Agent (MCP) 主开关尚未开启</strong>
          <p>请先开启本机服务主开关（开启后默认启用本机免令牌直连，客户端才能连接守护进程）。</p>
        </div>
        <button type="button" class="apps-btn primary" :disabled="busy" @click="emit('enable-mcp')">立即开启主服务</button>
      </div>

      <div class="wizard-tabs" role="tablist" aria-label="选择 MCP 客户端">
        <button
          type="button"
          role="tab"
          :aria-selected="activeTab === 'gemini'"
          class="wizard-tab"
          :class="{ active: activeTab === 'gemini' }"
          @click="activeTab = 'gemini'"
        >
          <Sparkles :size="15" /> Gemini 桌面端
        </button>
        <button
          type="button"
          role="tab"
          :aria-selected="activeTab === 'claude'"
          class="wizard-tab"
          :class="{ active: activeTab === 'claude' }"
          @click="activeTab = 'claude'"
        >
          <Terminal :size="15" /> Claude Desktop
        </button>
        <button
          type="button"
          role="tab"
          :aria-selected="activeTab === 'cursor'"
          class="wizard-tab"
          :class="{ active: activeTab === 'cursor' }"
          @click="activeTab = 'cursor'"
        >
          <Laptop :size="15" /> Cursor
        </button>
        <button
          type="button"
          role="tab"
          :aria-selected="activeTab === 'cloud'"
          class="wizard-tab"
          :class="{ active: activeTab === 'cloud' }"
          @click="activeTab = 'cloud'"
        >
          <Globe :size="15" /> 局域网 / Cloud MCP
        </button>
      </div>

      <!-- Tab 1: Gemini Desktop 1:1 Form -->
      <div v-if="activeTab === 'gemini'" class="wizard-panel">
        <div class="wizard-sandbox-warning" role="note">
          <div class="wizard-sandbox-head">
            <AlertTriangle :size="16" />
            <strong>沙盒设置避坑说明（重要）</strong>
          </div>
          <p>
            Gemini 桌面端默认沙盒仅放行「关联目录」、<code>~/.cache</code> 与 <code>/tmp</code>，不允许直接读取
            <code>~/Library/Application Support/LightIsle</code>。轻屿 Core 已内建本机安全桥接通道：请保持 LightIsle
            正在运行并开启 MCP 主开关，同机即可自动通过 <code>~/.cache/lightisle</code> 与 <code>/tmp</code> 连通；若自定义收紧了沙盒规则，请确保放行 <code>~/.cache</code> 与 <code>/tmp</code>，或直接改选 <strong>Cloud MCP</strong>（填写下方 <code>/api/v2/mcp</code> 端点与 Bearer Token）。
          </p>
        </div>

        <div class="wizard-form-card">
          <div class="wizard-form-title">
            <span>Gemini「设置自定义的关联应用」逐项对照</span>
            <IsleBadge variant="accent" size="sm">1:1 表单字段</IsleBadge>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">选择设置方法</span>
              <div class="wizard-method-pills">
                <span class="wizard-method-chip">同机推荐：<strong>本地 MCP</strong>（stdio）</span>
                <span class="wizard-method-chip">跨设备 / 远程：<strong>Cloud MCP</strong>（HTTP）</span>
              </div>
            </div>
            <div class="wizard-field-actions">
              <button
                type="button"
                class="apps-btn"
                @click="triggerCopy('gemini-method-local', '本地 MCP', '已复制设置方法：本地 MCP')"
              >
                <Check v-if="copiedKey === 'gemini-method-local'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'gemini-method-local' ? '已复制' : '复制「本地 MCP」' }}
              </button>
              <button
                type="button"
                class="apps-btn"
                @click="triggerCopy('gemini-method-cloud', 'Cloud MCP', '已复制设置方法：Cloud MCP')"
              >
                <Check v-if="copiedKey === 'gemini-method-cloud'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'gemini-method-cloud' ? '已复制' : '复制「Cloud MCP」' }}
              </button>
            </div>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">服务器名称</span>
              <code class="wizard-field-val">{{ GEMINI_SERVER_NAME }}</code>
            </div>
            <button
              type="button"
              class="apps-btn primary"
              @click="triggerCopy('gemini-name', GEMINI_SERVER_NAME, '已复制服务器名称')"
            >
              <Check v-if="copiedKey === 'gemini-name'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'gemini-name' ? '已复制' : '复制名称' }}
            </button>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">说明</span>
              <div class="wizard-field-text">{{ GEMINI_DESCRIPTION }}</div>
            </div>
            <button
              type="button"
              class="apps-btn"
              @click="triggerCopy('gemini-desc', GEMINI_DESCRIPTION, '已复制应用说明')"
            >
              <Check v-if="copiedKey === 'gemini-desc'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'gemini-desc' ? '已复制' : '复制说明' }}
            </button>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">命令（本地 MCP）</span>
              <code class="wizard-field-val">{{ GEMINI_LOCAL_COMMAND }}</code>
            </div>
            <button
              type="button"
              class="apps-btn primary"
              @click="triggerCopy('gemini-cmd', GEMINI_LOCAL_COMMAND, '已复制本地 MCP 启动命令')"
            >
              <Check v-if="copiedKey === 'gemini-cmd'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'gemini-cmd' ? '已复制' : '复制命令' }}
            </button>
          </div>
        </div>
      </div>

      <!-- Tab 2: Claude Desktop -->
      <div v-else-if="activeTab === 'claude'" class="wizard-panel">
        <div class="wizard-snippet-card">
          <div class="wizard-snippet-head">
            <div>
              <strong>Claude Desktop（<code>claude_desktop_config.json</code>）</strong>
              <small>同机 stdio 直连，默认免令牌通过本机安全通道通信。</small>
            </div>
            <div class="wizard-field-actions">
              <button
                type="button"
                class="apps-btn primary"
                @click="triggerCopy('claude-json', claudeDesktopJson, '已复制 Claude Desktop MCP JSON')"
              >
                <Check v-if="copiedKey === 'claude-json'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'claude-json' ? '已复制 JSON' : '复制 JSON' }}
              </button>
              <button
                type="button"
                class="apps-btn"
                @click="triggerCopy('claude-prompt', mcpPrompt, '已复制 AI Agent 接入提示词')"
              >
                <Check v-if="copiedKey === 'claude-prompt'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'claude-prompt' ? '已复制提示词' : '复制提示词' }}
              </button>
            </div>
          </div>
          <pre class="wizard-code">{{ claudeDesktopJson }}</pre>
        </div>
      </div>

      <!-- Tab 3: Cursor -->
      <div v-else-if="activeTab === 'cursor'" class="wizard-panel">
        <div class="wizard-snippet-card">
          <div class="wizard-snippet-head">
            <div>
              <strong>Cursor（<code>~/.cursor/mcp.json</code> 或项目 <code>.cursor/mcp.json</code>）</strong>
              <small>默认包含本机 stdio；开启局域网子开关后同步生成 Streamable HTTP 配置。</small>
            </div>
            <button
              type="button"
              class="apps-btn primary"
              @click="triggerCopy('cursor-json', cursorJson, '已复制 Cursor MCP JSON 配置')"
            >
              <Check v-if="copiedKey === 'cursor-json'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'cursor-json' ? '已复制 JSON' : '复制 JSON 配置' }}
            </button>
          </div>
          <pre class="wizard-code">{{ cursorJson }}</pre>
        </div>
      </div>

      <!-- Tab 4: LAN / Cloud MCP -->
      <div v-else class="wizard-panel">
        <div v-if="!mcpLanEnabled" class="wizard-alert wizard-alert-info">
          <div class="wizard-alert-body">
            <strong>局域网 / Cloud MCP 子开关尚未开启</strong>
            <p>跨设备连接或 Gemini Cloud MCP 需要开启「允许局域网 / Cloud MCP 访问」并携带 Bearer Token。</p>
          </div>
          <button type="button" class="apps-btn primary" :disabled="busy" @click="emit('enable-lan-mcp')">立即开启远程访问</button>
        </div>

        <div class="wizard-form-card">
          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">Streamable HTTP URL（Cloud MCP 首选）</span>
              <code class="wizard-field-val">{{ effectiveHttpUrl }}</code>
            </div>
            <button
              type="button"
              class="apps-btn primary"
              @click="triggerCopy('cloud-http', effectiveHttpUrl, '已复制 Streamable HTTP 端点 URL')"
            >
              <Check v-if="copiedKey === 'cloud-http'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'cloud-http' ? '已复制' : '复制 URL' }}
            </button>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">兼容 SSE URL（旧版客户端）</span>
              <code class="wizard-field-val">{{ effectiveSseUrl }}</code>
            </div>
            <button
              type="button"
              class="apps-btn"
              @click="triggerCopy('cloud-sse', effectiveSseUrl, '已复制备用 SSE 端点 URL')"
            >
              <Check v-if="copiedKey === 'cloud-sse'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'cloud-sse' ? '已复制' : '复制 SSE' }}
            </button>
          </div>

          <div class="wizard-field-row">
            <div class="wizard-field-meta">
              <span class="wizard-field-label">Authorization Header（Bearer Token）</span>
              <code class="wizard-field-val">Bearer {{ tokenDisplay }}</code>
            </div>
            <button
              type="button"
              class="apps-btn"
              :disabled="!mcpToken"
              @click="triggerCopy('cloud-auth', `Bearer ${mcpToken}`, '已复制 Bearer 鉴权头')"
            >
              <Check v-if="copiedKey === 'cloud-auth'" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedKey === 'cloud-auth' ? '已复制' : '复制 Header' }}
            </button>
          </div>
        </div>

        <div class="wizard-snippet-card">
          <div class="wizard-snippet-head">
            <div>
              <strong>通用 Cloud / 局域网 <code>mcpServers</code> JSON</strong>
            </div>
            <div class="wizard-field-actions">
              <button
                type="button"
                class="apps-btn primary"
                @click="triggerCopy('cloud-json', cloudJson, '已复制 Cloud MCP JSON 配置')"
              >
                <Check v-if="copiedKey === 'cloud-json'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'cloud-json' ? '已复制' : '复制 JSON' }}
              </button>
              <button
                type="button"
                class="apps-btn"
                @click="triggerCopy('cloud-prompt', lanMcpPrompt, '已复制局域网 MCP 接入提示词')"
              >
                <Check v-if="copiedKey === 'cloud-prompt'" :size="14" />
                <Copy v-else :size="14" />
                {{ copiedKey === 'cloud-prompt' ? '已复制' : '复制接入提示词' }}
              </button>
            </div>
          </div>
          <pre class="wizard-code">{{ cloudJson }}</pre>
        </div>
      </div>
    </div>
  </IsleModal>
</template>

<style scoped>
.wizard-wrap { display: flex; flex-direction: column; gap: 14px; }
.wizard-tabs { display: flex; flex-wrap: wrap; gap: 8px; border-bottom: 1px solid var(--fluid-card-border); padding-bottom: 10px; }
.wizard-tab {
  display: inline-flex; align-items: center; gap: 6px; padding: 7px 13px; border-radius: 999px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-secondary); font-size: 13px; font-weight: 600; cursor: pointer;
  transition: background-color 0.16s ease, color 0.16s ease, border-color 0.16s ease;
}
.wizard-tab.active {
  background: color-mix(in srgb, var(--accent-primary) 14%, transparent);
  border-color: color-mix(in srgb, var(--accent-primary) 42%, transparent);
  color: var(--accent-primary);
}
.wizard-panel { display: flex; flex-direction: column; gap: 12px; }
.wizard-sandbox-warning {
  padding: 12px 14px; border-radius: 12px;
  background: color-mix(in srgb, #f59e0b 11%, var(--fluid-card-item-fill));
  border: 1px solid color-mix(in srgb, #f59e0b 38%, transparent);
}
.wizard-sandbox-head { display: flex; align-items: center; gap: 6px; color: #b45309; font-size: 13px; margin-bottom: 6px; }
:global(.dark) .wizard-sandbox-head { color: #fbbf24; }
.wizard-sandbox-warning p { margin: 0; font-size: 12.5px; line-height: 1.55; color: var(--text-secondary); }
.wizard-alert {
  display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
  padding: 10px 14px; border-radius: 12px; border: 1px solid color-mix(in srgb, var(--accent-primary) 30%, transparent);
  background: color-mix(in srgb, var(--accent-primary) 8%, transparent);
}
.wizard-alert-body strong { display: block; font-size: 13px; color: var(--text-primary); }
.wizard-alert-body p { margin: 3px 0 0; font-size: 12px; color: var(--text-secondary); }
.wizard-form-card, .wizard-snippet-card {
  display: flex; flex-direction: column; gap: 10px; padding: 14px; border-radius: 14px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
}
.wizard-form-title, .wizard-snippet-head {
  display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap;
  font-size: 13px; font-weight: 700; color: var(--text-primary);
}
.wizard-snippet-head small { display: block; font-weight: 400; font-size: 12px; color: var(--text-secondary); margin-top: 2px; }
.wizard-field-row {
  display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
  padding: 10px 12px; border-radius: 10px; background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
}
.wizard-field-meta { display: flex; flex-direction: column; gap: 4px; min-width: 0; flex: 1; }
.wizard-field-label { font-size: 11.5px; font-weight: 600; color: var(--text-secondary); }
.wizard-field-val {
  font-size: 12.5px; word-break: break-all; color: var(--text-primary);
  background: transparent; padding: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
.wizard-field-text { font-size: 13px; color: var(--text-primary); line-height: 1.45; }
.wizard-method-pills { display: flex; flex-wrap: wrap; gap: 8px; }
.wizard-method-chip {
  font-size: 12px; color: var(--text-secondary); padding: 3px 9px; border-radius: 8px;
  background: color-mix(in srgb, var(--accent-primary) 7%, transparent);
}
.wizard-field-actions { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.wizard-code {
  margin: 0; padding: 12px; border-radius: 10px; background: rgba(15, 23, 42, 0.05);
  border: 1px solid var(--fluid-card-border); font-size: 12px; line-height: 1.5;
  overflow-x: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
:global(.dark) .wizard-code { background: rgba(255, 255, 255, 0.04); }
</style>
