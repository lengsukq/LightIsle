import assert from "node:assert/strict";
import test from "node:test";
import { taskHistoryErrorLabel, taskOperationLabel, taskRunStatusLabel } from "../src/taskHistoryPresentation.js";

test("task history presents operation and terminal states in Chinese", () => {
  assert.equal(taskOperationLabel("scan"), "媒体扫描");
  assert.equal(taskOperationLabel("reconcile"), "增量核对");
  assert.equal(taskOperationLabel("unknown"), "后台任务");
  assert.equal(taskRunStatusLabel({ running: true, lastError: "" }), "进行中");
  assert.equal(taskRunStatusLabel({ running: false, lastError: "" }), "已完成");
  assert.equal(taskRunStatusLabel({ running: false, lastError: "cancelled" }), "已取消");
  assert.equal(taskRunStatusLabel({ running: false, lastError: "scan_limit_reached" }), "已停止：达到处理上限");
  assert.equal(taskRunStatusLabel({ running: false, lastError: "permission denied" }), "运行失败");
});

test("task history translates known failures and preserves an actionable fallback", () => {
  assert.equal(taskHistoryErrorLabel("interrupted_by_restart"), "Mac 服务重启时中断");
  assert.equal(taskHistoryErrorLabel("in_progress_not_restored_from_backup"), "备份时尚在运行，恢复后需手动重新开始");
  assert.equal(taskHistoryErrorLabel("shared_folder_not_mounted"), "共享目录当前不可用");
  assert.equal(taskHistoryErrorLabel("permission denied"), "任务执行失败，请查看详情：permission denied");
  assert.equal(taskHistoryErrorLabel(""), "");
});
