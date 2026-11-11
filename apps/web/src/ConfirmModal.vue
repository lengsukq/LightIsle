<script setup lang="ts">
import { computed, onMounted, onUnmounted } from 'vue'
import { useConfirmDialogState } from './useConfirmDialog.ts'

const props = withDefaults(
  defineProps<{
    busy?: boolean
  }>(),
  {
    busy: false,
  }
)

const { dialogState, acceptDialog, cancelDialog } = useConfirmDialogState()
const isBusy = computed(() => Boolean(props.busy || dialogState.busy))

function dismissOnEscape() {
  if (!dialogState.open || isBusy.value) return
  if (dialogState.mode === 'alert') {
    acceptDialog()
  } else {
    cancelDialog()
  }
}

function onWindowKeydown(event: KeyboardEvent) {
  if (!dialogState.open || isBusy.value) return
  if (event.key === 'Escape') {
    event.preventDefault()
    dismissOnEscape()
  }
}

function onBackdropClick() {
  if (isBusy.value) return
  if (dialogState.mode === 'alert') {
    acceptDialog()
  } else {
    cancelDialog()
  }
}

onMounted(() => window.addEventListener('keydown', onWindowKeydown))
onUnmounted(() => window.removeEventListener('keydown', onWindowKeydown))
</script>

<template>
  <Teleport to="body">
    <div
      v-if="dialogState.open"
      class="confirm-modal-backdrop"
      role="alertdialog"
      aria-modal="true"
      :aria-label="dialogState.title"
      tabindex="-1"
      @click.self="onBackdropClick"
      @keydown.esc.prevent="dismissOnEscape"
    >
      <div class="confirm-modal-card">
        <header class="confirm-modal-header">
          <strong>{{ dialogState.title }}</strong>
        </header>
        <p class="confirm-modal-body">{{ dialogState.message }}</p>
        <footer class="confirm-modal-actions">
          <button
            v-if="dialogState.mode === 'confirm'"
            type="button"
            class="confirm-btn secondary"
            :disabled="isBusy"
            @click="cancelDialog"
          >
            {{ dialogState.cancelText }}
          </button>
          <button
            type="button"
            class="confirm-btn"
            :class="dialogState.variant === 'danger' ? 'danger' : 'primary'"
            :disabled="isBusy"
            autofocus
            @click="acceptDialog"
          >
            {{ dialogState.confirmText }}
          </button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.confirm-modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: 9999;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
  background: rgba(15, 23, 42, 0.45);
  -webkit-backdrop-filter: blur(10px) saturate(160%);
  backdrop-filter: blur(10px) saturate(160%);
}

.confirm-modal-card {
  width: min(440px, 100%);
  padding: 24px;
  border-radius: var(--radius-lg, 20px);
  background: var(--fluid-card-fill, var(--surface-glass, rgba(255, 255, 255, 0.86)));
  -webkit-backdrop-filter: blur(28px) saturate(180%);
  backdrop-filter: blur(28px) saturate(180%);
  color: var(--text-primary, #1d1d1f);
  border: 1px solid var(--stroke-glass, rgba(255, 255, 255, 0.75));
  box-shadow: var(--shadow-float, 0 24px 52px rgba(15, 23, 42, 0.24)),
    0 0 0 1px var(--stroke-subtle, rgba(0, 0, 0, 0.06));
  display: grid;
  gap: 14px;
}

.confirm-modal-header strong {
  font-size: 16px;
  font-weight: 700;
  letter-spacing: -0.2px;
}

.confirm-modal-body {
  margin: 0;
  font-size: 13.5px;
  line-height: 1.65;
  color: var(--text-secondary, #6e6e73);
  white-space: pre-line;
}

.confirm-modal-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 10px;
  margin-top: 6px;
}

.confirm-modal-actions .confirm-btn {
  appearance: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 36px;
  padding: 8px 18px;
  border-radius: var(--radius-sm, 10px);
  font: inherit;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.2;
  cursor: pointer;
  border: 1px solid var(--fluid-card-border, var(--stroke-subtle, rgba(0, 0, 0, 0.1)));
  background: var(--fluid-card-item-fill, var(--surface-raised, rgba(255, 255, 255, 0.88)));
  color: var(--text-primary, #1d1d1f);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04), inset 0 1px 0 var(--stroke-glass, rgba(255, 255, 255, 0.65));
  transition: transform 150ms cubic-bezier(0.22, 1, 0.36, 1),
    background 150ms ease,
    border-color 150ms ease,
    box-shadow 150ms ease,
    filter 150ms ease;
}

.confirm-modal-actions .confirm-btn.secondary:hover:not(:disabled) {
  background: var(--fluid-card-hover, var(--surface-elevated, #ffffff));
  border-color: var(--stroke-strong, rgba(0, 0, 0, 0.18));
}

.confirm-modal-actions .confirm-btn.primary {
  background: linear-gradient(145deg, var(--accent-secondary, #5b8bf7), var(--accent-primary, #0071e3));
  color: #ffffff;
  border-color: transparent;
  box-shadow: 0 6px 16px var(--accent-glow, rgba(0, 113, 227, 0.28)),
    inset 0 1px 0 rgba(255, 255, 255, 0.28);
}

.confirm-modal-actions .confirm-btn.primary:hover:not(:disabled) {
  filter: brightness(1.06);
}

.confirm-modal-actions .confirm-btn.danger {
  background: linear-gradient(145deg, #ff5b52, var(--error, #ff3b30));
  color: #ffffff;
  border-color: transparent;
  box-shadow: 0 6px 16px rgba(255, 59, 48, 0.28),
    inset 0 1px 0 rgba(255, 255, 255, 0.26);
}

.confirm-modal-actions .confirm-btn.danger:hover:not(:disabled) {
  filter: brightness(1.06);
}

.confirm-modal-actions .confirm-btn:active:not(:disabled) {
  transform: scale(0.98);
}

.confirm-modal-actions .confirm-btn:focus-visible {
  outline: none;
  box-shadow: 0 0 0 3px var(--accent-muted, rgba(0, 113, 227, 0.18));
}

.confirm-modal-actions .confirm-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
  transform: none;
}
</style>
