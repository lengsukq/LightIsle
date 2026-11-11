<script setup lang="ts">
import { computed } from 'vue'
import { useConfirmDialogState } from './useConfirmDialog.ts'
import IsleModal from './IsleModal.vue'
import IsleButton from './IsleButton.vue'

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

function onModalClose() {
  if (isBusy.value) return
  if (dialogState.mode === 'alert') {
    acceptDialog()
  } else {
    cancelDialog()
  }
}
</script>

<template>
  <IsleModal
    :open="dialogState.open"
    :title="dialogState.title"
    size="sm"
    role="alertdialog"
    :z-index="'var(--z-confirm, 9999)'"
    :show-close="false"
    :close-on-backdrop="!isBusy"
    :close-on-esc="!isBusy"
    @close="onModalClose"
  >
    <p class="confirm-modal-body">{{ dialogState.message }}</p>

    <template #footer>
      <div class="confirm-modal-actions">
        <IsleButton
          v-if="dialogState.mode === 'confirm'"
          variant="glass"
          :disabled="isBusy"
          @click="cancelDialog"
        >
          {{ dialogState.cancelText }}
        </IsleButton>
        <IsleButton
          :variant="dialogState.variant === 'danger' ? 'danger' : 'primary'"
          :disabled="isBusy"
          @click="acceptDialog"
        >
          {{ dialogState.confirmText }}
        </IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.confirm-modal-body {
  margin: 0;
  font-size: 14px;
  line-height: 1.6;
  color: var(--text-secondary, #64748b);
  white-space: pre-line;
}

.confirm-modal-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 10px;
}
</style>
