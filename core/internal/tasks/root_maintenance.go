package tasks

import (
	"database/sql"
	"errors"
	"time"
)

// RootMaintenance describes the last code-verifiable background media
// reconciliation of a registered root. No physical path, disk UUID, private
// album, user identity or filename is persisted in this table.
type RootMaintenance struct {
	RootID string `json:"rootID"`
	Generation uint64 `json:"generation"`
	Status string `json:"status"` // pending,running,ok,offline,busy,failed,interrupted
	LastAttempt int64 `json:"lastAttempt"`
	LastSuccess int64 `json:"lastSuccess"`
}

func rootMaintenanceStatusAllowed(status string) bool {
	switch status {
	case "running","ok","offline","busy","failed":
		return true
	}
	return false
}

// UpdateRootMaintenance is called only from Core's opt-in native scheduler.
// Changing a physical generation resets the last-success claim, so an old
// folder's clean index is never advertised as a new binding's success.
func (j *Journal) UpdateRootMaintenance(id string,generation uint64,status string) error {
	if j==nil||j.db==nil||!validRootID(id)||generation==0||!rootMaintenanceStatusAllowed(status){
		return errors.New("invalid_root_maintenance")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	now:=time.Now().Unix()
	success:=int64(0)
	if status=="ok" {success=now}
	_,err:=j.db.Exec(`INSERT INTO root_maintenance(root_id,generation,status,last_attempt,last_success,updated_at)
		VALUES(?,?,?,?,?,?)
		ON CONFLICT(root_id) DO UPDATE SET
		generation=excluded.generation,status=excluded.status,last_attempt=excluded.last_attempt,
		last_success=CASE WHEN excluded.status='ok' THEN excluded.last_success
			WHEN root_maintenance.generation!=excluded.generation THEN 0
			ELSE root_maintenance.last_success END,
		updated_at=excluded.updated_at`,id,generation,status,now,success,now)
	return err
}

// RootMaintenanceStatus reads the current physical generation's status;
// absent rows and prior-generation history are always reported as pending.
func (j *Journal) RootMaintenanceStatus(id string,generation uint64)(RootMaintenance,error){
	pending:=RootMaintenance{RootID:id,Generation:generation,Status:"pending"}
	if j==nil||j.db==nil||!validRootID(id)||generation==0 {
		return pending,errors.New("invalid_root_maintenance")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	var found RootMaintenance
	var loaded int64
	err:=j.db.QueryRow(`SELECT generation,status,last_attempt,last_success FROM root_maintenance WHERE root_id=?`,id).
		Scan(&loaded,&found.Status,&found.LastAttempt,&found.LastSuccess)
	if errors.Is(err,sql.ErrNoRows){return pending,nil}
	if err!=nil{return pending,err}
	if loaded<0||uint64(loaded)!=generation{return pending,nil}
	found.RootID=id
	found.Generation=generation
	return found,nil
}
