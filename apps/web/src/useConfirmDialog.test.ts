import assert from "node:assert/strict";
import test from "node:test";
import { requestAlert, requestConfirm, useConfirmDialogState } from "./useConfirmDialog.ts";

test("requestConfirm opens modal state and resolves true on acceptDialog", async () => {
  const { dialogState, acceptDialog } = useConfirmDialogState();
  const promise = requestConfirm({
    title: "移入回收站",
    message: "确认移入回收站？",
    confirmText: "移入",
    variant: "danger",
  });
  assert.equal(dialogState.open, true);
  assert.equal(dialogState.mode, "confirm");
  assert.equal(dialogState.title, "移入回收站");
  assert.equal(dialogState.variant, "danger");
  acceptDialog();
  assert.equal(await promise, true);
  assert.equal(dialogState.open, false);
});

test("requestConfirm resolves false when cancelled or superseded by another dialog", async () => {
  const { dialogState, cancelDialog, acceptDialog } = useConfirmDialogState();
  const first = requestConfirm("第一个确认");
  const second = requestAlert("后续提示");
  assert.equal(await first, false);
  assert.equal(dialogState.mode, "alert");
  acceptDialog();
  await second;
  const third = requestConfirm("第三个确认");
  cancelDialog();
  assert.equal(await third, false);
});
