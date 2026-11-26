<script setup lang="ts">
import { Comment, Text, computed, useSlots } from "vue";
import { Info, CheckCircle2, AlertTriangle, AlertCircle, WifiOff, X } from "lucide-vue-next";
import { splitUserFacingErrorText } from "../../api/userFacingError.ts";

export type IsleBannerType = "info" | "success" | "warning" | "error" | "offline";

const props = withDefaults(
  defineProps<{
    type?: IsleBannerType;
    title?: string;
    message?: string;
    detail?: string;
    closable?: boolean;
    compact?: boolean;
  }>(),
  {
    type: "info",
    title: "",
    message: "",
    detail: "",
    closable: false,
    compact: false,
  }
);

const emit = defineEmits<{
  (e: "close"): void;
}>();

const slots = useSlots();

defineSlots<{
  default?: (props: Record<string, never>) => any;
  icon?: (props: Record<string, never>) => any;
  action?: (props: Record<string, never>) => any;
}>();

const plainSlotText = computed<string | null>(() => {
  const rendered = slots.default?.();
  if (!rendered || rendered.length === 0) return null;
  let text = "";
  for (const vnode of rendered) {
    if (vnode.type === Comment) continue;
    if (vnode.type === Text && typeof vnode.children === "string") {
      text += vnode.children;
    } else {
      return null;
    }
  }
  return text.trim() ? text : null;
});

const parsedDisplay = computed(() => {
  const sourceText = plainSlotText.value ?? (props.message || "");
  if (!sourceText) {
    return {
      useParsedText: false,
      message: "",
      technicalDetail: props.detail || null,
    };
  }
  const split = splitUserFacingErrorText(sourceText);
  const technicalDetail = props.detail || split.technicalDetail;
  const shouldSeparate = Boolean(split.technicalDetail) || Boolean(props.message && !slots.default);
  return {
    useParsedText: shouldSeparate,
    message: split.message,
    technicalDetail,
  };
});

const defaultIcon = computed(() => {
  switch (props.type) {
    case "success":
      return CheckCircle2;
    case "warning":
      return AlertTriangle;
    case "error":
      return AlertCircle;
    case "offline":
      return WifiOff;
    case "info":
    default:
      return Info;
  }
});
</script>

<template>
  <aside
    class="isle-banner"
    :class="[
      `type-${type}`,
      {
        'is-compact': compact,
      },
    ]"
    role="status"
    aria-live="polite"
  >
    <div class="isle-banner-icon-col" aria-hidden="true">
      <slot name="icon">
        <component :is="defaultIcon" :size="compact ? 15 : 16" class="isle-banner-default-icon" />
      </slot>
    </div>

    <div class="isle-banner-content">
      <div v-if="title" class="isle-banner-title">{{ title }}</div>
      <div v-if="$slots.default || message" class="isle-banner-message">
        <template v-if="parsedDisplay.useParsedText">{{ parsedDisplay.message }}</template>
        <slot v-else>{{ message }}</slot>
      </div>
      <details v-if="parsedDisplay.technicalDetail" class="isle-banner-tech">
        <summary>技术详情</summary>
        <code>{{ parsedDisplay.technicalDetail }}</code>
      </details>
    </div>

    <div v-if="$slots.action" class="isle-banner-actions">
      <slot name="action" />
    </div>

    <button
      v-if="closable"
      type="button"
      class="isle-banner-close-btn"
      title="关闭提示"
      aria-label="关闭提示"
      @click="emit('close')"
    >
      <X :size="14" />
    </button>
  </aside>
</template>

<style scoped>
.isle-banner {
  display: flex;
  align-items: flex-start;
  flex-wrap: wrap;
  gap: 10px;
  padding: 10px 14px;
  border-radius: 12px;
  border: 1px solid transparent;
  box-sizing: border-box;
  transition: transform var(--motion-normal, 260ms) var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)), opacity var(--motion-normal, 260ms) ease;
}

.isle-banner.is-compact {
  align-items: center;
  padding: 7px 12px;
  gap: 8px;
}

.isle-banner-icon-col {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  padding-top: 2px;
}

.isle-banner.is-compact .isle-banner-icon-col {
  padding-top: 0;
}

.isle-banner-content {
  flex: 1 1 180px;
  min-width: 0;
  font-size: 12.5px;
  line-height: 1.5;
}

.isle-banner-title {
  font-weight: 650;
  font-size: 13px;
  letter-spacing: -0.01em;
  margin-bottom: 1px;
}

.isle-banner.is-compact .isle-banner-title {
  margin-bottom: 0;
  display: inline;
  margin-right: 6px;
}

.isle-banner-message {
  color: var(--text-secondary, #64748b);
  word-break: break-word;
}

.isle-banner.is-compact .isle-banner-message {
  display: inline;
}

.isle-banner-tech {
  margin-top: 4px;
  font-size: 11px;
  color: var(--text-tertiary, #94a3b8);
}

.isle-banner-tech summary {
  cursor: pointer;
  user-select: none;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.isle-banner-tech code {
  display: block;
  margin-top: 3px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px;
  color: var(--text-secondary, #64748b);
  word-break: break-all;
}

.isle-banner-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
}

.isle-banner-close-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  border-radius: 9999px;
  border: none;
  background: transparent;
  color: var(--text-secondary, #64748b);
  cursor: pointer;
  padding: 0;
  margin-left: 2px;
  transition: background 0.15s ease, color 0.15s ease;
  flex-shrink: 0;
}

.isle-banner-close-btn:hover {
  background: rgba(120, 136, 165, 0.15);
  color: var(--text-primary, #1e293b);
}

.isle-banner.type-info {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 7%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--accent-primary, #2563eb) 24%, var(--fluid-card-border));
  color: var(--text-primary);
}
.isle-banner.type-info .isle-banner-icon-col,
.isle-banner.type-info .isle-banner-title {
  color: var(--accent-primary, #2563eb);
}

.isle-banner.type-success {
  background: color-mix(in srgb, var(--success, #10b981) 8%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--success, #10b981) 24%, var(--fluid-card-border));
  color: var(--text-primary);
}
.isle-banner.type-success .isle-banner-icon-col,
.isle-banner.type-success .isle-banner-title {
  color: var(--success, #059669);
}

.isle-banner.type-warning {
  background: color-mix(in srgb, var(--warning, #f59e0b) 9%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--warning, #f59e0b) 28%, var(--fluid-card-border));
  color: var(--text-primary);
}
.isle-banner.type-warning .isle-banner-icon-col,
.isle-banner.type-warning .isle-banner-title {
  color: var(--warning, #d97706);
}

.isle-banner.type-error {
  background: color-mix(in srgb, var(--error, #ef4444) 8%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--error, #ef4444) 28%, var(--fluid-card-border));
  color: var(--text-primary);
}
.isle-banner.type-error .isle-banner-icon-col,
.isle-banner.type-error .isle-banner-title {
  color: var(--error, #dc2626);
}

.isle-banner.type-offline {
  background: color-mix(in srgb, var(--text-secondary, #64748b) 8%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--text-secondary, #64748b) 26%, var(--fluid-card-border));
  color: var(--text-primary);
}
.isle-banner.type-offline .isle-banner-icon-col {
  color: var(--text-secondary, #64748b);
}
.isle-banner.type-offline .isle-banner-title {
  color: var(--text-primary);
}

@media (prefers-reduced-motion: reduce) {
  .isle-banner,
  .isle-banner-close-btn {
    transition: none;
  }
}
</style>
