package tasks

import (
	"errors"
	"time"
)

type Alert struct {
	Code         string `json:"code"`
	Severity     string `json:"severity"`
	Message      string `json:"message"`
	Active       bool   `json:"active"`
	Acknowledged bool   `json:"acknowledged"`
	FirstSeen    int64  `json:"firstSeen"`
	LastSeen     int64  `json:"lastSeen"`
}

var allowedAlerts = map[string]struct{ severity, message string }{
	"storage_offline":      {"critical", "共享存储卷已离线，请检查磁盘连接、挂载路径及供电。"},
	"storage_low_space":    {"warning", "共享存储卷剩余空间不足，请先清理或扩容，再执行大型传输与备份。"},
	"backup_failed":        {"warning", "上次备份未成功，请到任务中心查看错误、检查目标盘和备份计划。"},
	"gallery_scan_failed":  {"warning", "最近一次图库索引未成功完成；现有媒体不会自动删除，请检查存储和日志。"},
	"cinema_scan_failed":   {"warning", "最近一次影视索引未成功完成；请检查存储和扫描任务状态。"},
	"tunnel_disconnected":  {"warning", "Cloudflare Tunnel 意外断开；Core 会按退避自动重启，请到 Mac 应用查看隧道状态。"},
	"trash_cleanup_failed": {"warning", "回收站自动清理未全部完成；部分条目将在下一轮重试，请检查共享盘可用状态。"},
}

// SyncAlert is an idempotent state transition. Polling the same failure never
// creates duplicate notifications or clears an explicit acknowledgement.
func (j *Journal) SyncAlert(code string, active bool) error {
	known, ok := allowedAlerts[code]
	if !ok {
		return errors.New("invalid_alert_code")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	now := time.Now().Unix()
	if active {
		_, err := j.db.Exec(`INSERT INTO system_alerts(code,severity,message,active,acknowledged,first_seen,last_seen)
  VALUES(?,?,?,1,0,?,?)
  ON CONFLICT(code) DO UPDATE SET active=1,
  acknowledged=CASE WHEN system_alerts.active=0 THEN 0 ELSE system_alerts.acknowledged END,
  last_seen=CASE WHEN system_alerts.active=0 THEN excluded.last_seen ELSE system_alerts.last_seen END`,
			code, known.severity, known.message, now, now)
		return err
	}
	_, err := j.db.Exec("UPDATE system_alerts SET active=0,last_seen=? WHERE code=? AND active=1", now, code)
	return err
}

func (j *Journal) Alerts(activeOnly bool) ([]Alert, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	query := `SELECT code,severity,message,active,acknowledged,first_seen,last_seen FROM system_alerts`
	if activeOnly {
		query += " WHERE active=1"
	}
	query += " ORDER BY active DESC,first_seen DESC LIMIT 100"
	rows, err := j.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Alert{}
	for rows.Next() {
		var a Alert
		var active, ack int
		if err := rows.Scan(&a.Code, &a.Severity, &a.Message, &active, &ack, &a.FirstSeen, &a.LastSeen); err != nil {
			return nil, err
		}
		a.Active = active != 0
		a.Acknowledged = ack != 0
		out = append(out, a)
	}
	return out, rows.Err()
}

func (j *Journal) AcknowledgeAlert(code string) error {
	if _, ok := allowedAlerts[code]; !ok {
		return errors.New("invalid_alert_code")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	res, err := j.db.Exec("UPDATE system_alerts SET acknowledged=1 WHERE code=? AND active=1", code)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return errors.New("alert_not_active")
	}
	return nil
}
