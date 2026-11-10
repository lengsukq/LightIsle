<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useConfirmDialogState } from './useConfirmDialog'

const { dialogState, acceptDialog, cancelDialog } = useConfirmDialogState()

function onKeydown(event: KeyboardEvent) {
  if (!dialogState.open) return
  if (event.key === 'Escape') {
    event.preventDefault()
    if (dialogState.mode === 'alert') {
      acceptDialog()
    } else {
      cancelDialog()
    }
  }
}

onMounted(() => window.addEventListener('keydown', onKeydown))
onUnmounted(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <Teleport to="body">
    <div
      v-if="dialogState.open"
      class="confirm-modal-backdrop"
      role="alertdialog"
      aria-modal="true"
      :aria-label="dialogState.title"
      @click.self="dialogState.mode === 'alert' ? acceptDialog() : cancelDialog()"
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
            class="secondary"
            @click="cancelDialog"
          >
            {{ dialogState.cancelText }}
          </button>
          <button
            type="button"
            :class="dialogState.variant === 'danger' ? 'danger' : 'primary'"
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
  background: rgba(15, 23, 42, 0.48);
  backdrop-filter: blur(8px);
}

.confirm-modal-card {
  width: min(440px, 100%);
  padding: 20px;
  border-radius: 16px;
  background: var(--surface-elevated, #ffffff);
  color: var(--text-primary, #0f172a);
  border: 1px solid rgba(148, 163, 184, 0.25);
  box-shadow: 0 20px 48px rgba(15, 23, 42, 0.24);
  display: grid;
  gap: 14px;
}

.confirm-modal-header strong {
  font-size: 16px;
  font-weight: 700;
}

.confirm-modal-body {
  margin: 0;
  font-size: 14px;
  line-height: 1.55;
  color: var(--text-secondary, #334155);
  white-space: pre-line;
}

.confirm-modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 10px;
}
</style>
