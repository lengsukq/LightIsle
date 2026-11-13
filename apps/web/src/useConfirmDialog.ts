import { reactive } from 'vue'

export interface ConfirmDialogOptions {
  title?: string
  message: string
  confirmText?: string
  cancelText?: string
  variant?: 'default' | 'danger'
  busy?: boolean
}

export interface AlertDialogOptions {
  title?: string
  message: string
  confirmText?: string
  busy?: boolean
}

interface ActiveDialogState {
  open: boolean
  mode: 'confirm' | 'alert'
  title: string
  message: string
  confirmText: string
  cancelText: string
  variant: 'default' | 'danger'
  busy: boolean
}

const dialogState = reactive<ActiveDialogState>({
  open: false,
  mode: 'confirm',
  title: '请确认操作',
  message: '',
  confirmText: '确认',
  cancelText: '取消',
  variant: 'default',
  busy: false,
})

let activeResolver: ((accepted: boolean) => void) | null = null

function settleCurrentDialog(accepted: boolean): void {
  if (dialogState.busy) return
  const resolve = activeResolver
  activeResolver = null
  dialogState.open = false
  dialogState.busy = false
  if (resolve) {
    resolve(accepted)
  }
}

export function requestConfirm(options: ConfirmDialogOptions | string): Promise<boolean> {
  if (activeResolver) {
    dialogState.busy = false
    settleCurrentDialog(false)
  }
  const normalized: ConfirmDialogOptions =
    typeof options === 'string' ? { message: options } : options
  dialogState.mode = 'confirm'
  dialogState.title = normalized.title || '请确认操作'
  dialogState.message = normalized.message
  dialogState.confirmText = normalized.confirmText || '确认'
  dialogState.cancelText = normalized.cancelText || '取消'
  dialogState.variant = normalized.variant || 'default'
  dialogState.busy = Boolean(normalized.busy)
  dialogState.open = true
  return new Promise<boolean>((resolve) => {
    activeResolver = resolve
  })
}

export async function requestAlert(options: AlertDialogOptions | string): Promise<void> {
  if (activeResolver) {
    dialogState.busy = false
    settleCurrentDialog(false)
  }
  const normalized: AlertDialogOptions =
    typeof options === 'string' ? { message: options } : options
  dialogState.mode = 'alert'
  dialogState.title = normalized.title || '提示'
  dialogState.message = normalized.message
  dialogState.confirmText = normalized.confirmText || '知道了'
  dialogState.cancelText = ''
  dialogState.variant = 'default'
  dialogState.busy = Boolean(normalized.busy)
  dialogState.open = true
  await new Promise<boolean>((resolve) => {
    activeResolver = resolve
  })
}

export function useConfirmDialogState() {
  return {
    dialogState,
    acceptDialog: () => settleCurrentDialog(true),
    cancelDialog: () => settleCurrentDialog(false),
  }
}
