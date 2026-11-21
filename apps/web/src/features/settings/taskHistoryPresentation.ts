export type TaskRunPresentation = { running: boolean; lastError: string };

const failureLabels = new Map<string, string>([
  ["cancelled", "任务已取消"],
  ["interrupted_by_restart", "Mac 服务重启时中断"],
  ["in_progress_not_restored_from_backup", "备份时尚在运行，恢复后需手动重新开始"],
  ["scan_limit", "达到扫描上限，请缩小共享目录后重试"],
  ["scan_limit_reached", "达到扫描上限，请缩小共享目录后重试"],
  ["scan_directory_changed", "扫描期间目录发生变化，请在文件操作结束后重新检查"],
  ["shared_folder_not_mounted", "共享目录当前不可用"],
  ["share_changed", "扫描期间共享目录发生变化"],
  ["share_changed_or_offline", "扫描期间共享目录断开或发生变化"],
  ["cinema_volume_offline", "影视目录当前不可用"],
  ["backup_schedule_save_failed", "备份计划保存失败"],
  ["upload_cleanup_failed", "上传清理未完成，请检查未完成上传和容量预占"],
  ["upload_cleanup_needs_review", "部分上传或预占无法自动确认，已保留供检查"],
  ["upload_cleanup_more", "仍有过期上传，稍后会继续处理"],
  ["upload_cleanup_cancelled", "上传清理已中断，未确认的预占会保留"],
  ["upload_cleanup_status_unavailable", "无法记录清理状态，请检查上传和预占"],
]);

export function taskOperationLabel(operation: string): string {
  if (operation === "scan") return "媒体扫描";
  if (operation === "reconcile") return "增量核对";
  if (operation === "backup") return "文件备份";
  if (operation === "expired-cleanup") return "过期上传清理";
  return "后台任务";
}

export function taskRunStatusLabel(run: TaskRunPresentation): string {
  if (run.running) return "进行中";
  if (!run.lastError) return "已完成";
  if (run.lastError === "cancelled") return "已取消";
  if (run.lastError === "scan_limit" || run.lastError === "scan_limit_reached") {
    return "已停止：达到处理上限";
  }
  return "运行失败";
}

export function taskHistoryErrorLabel(error: string | undefined): string {
  if (!error) return "";
  return failureLabels.get(error) ?? `任务执行失败，请查看详情：${error}`;
}
