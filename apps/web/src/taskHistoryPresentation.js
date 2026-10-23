const failureLabels = new Map([
  ["cancelled", "任务已取消"],
  ["interrupted_by_restart", "Mac 服务重启时中断"],
  ["in_progress_not_restored_from_backup", "备份时尚在运行，恢复后需手动重新开始"],
  ["scan_limit", "达到扫描上限，请缩小共享目录后重试"],
  ["scan_limit_reached", "达到扫描上限，请缩小共享目录后重试"],
  ["shared_folder_not_mounted", "共享目录当前不可用"],
  ["share_changed", "扫描期间共享目录发生变化"],
  ["share_changed_or_offline", "扫描期间共享目录断开或发生变化"],
  ["cinema_volume_offline", "影视目录当前不可用"],
  ["backup_schedule_save_failed", "备份计划保存失败"],
]);

export function taskOperationLabel(operation) {
  if (operation === "scan") return "媒体扫描";
  if (operation === "reconcile") return "增量核对";
  if (operation === "backup") return "文件备份";
  return "后台任务";
}

export function taskRunStatusLabel(run) {
  if (run.running) return "进行中";
  if (!run.lastError) return "已完成";
  if (run.lastError === "cancelled") return "已取消";
  if (run.lastError === "scan_limit" || run.lastError === "scan_limit_reached") return "已停止：达到处理上限";
  return "运行失败";
}

export function taskHistoryErrorLabel(error) {
  if (!error) return "";
  return failureLabels.get(error) ?? `任务执行失败，请查看详情：${error}`;
}
