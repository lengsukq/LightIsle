package auth

import (
	"strings"
	"time"
)

const MaxAuditHistory = 20000
const AuditRetentionDays = 90

type AuditEvent struct {
	ID        int64  `json:"id"`
	ActorID   int64  `json:"actorId"`
	Action    string `json:"action"`
	Target    string `json:"target"`
	Outcome   string `json:"outcome"`
	CreatedAt int64  `json:"createdAt"`
}

// AppendAudit never accepts client-supplied text beyond a route *pattern*
// or a fixed event category. It intentionally cannot record request bodies,
// file/share bearer URLs, passwords, session IDs or arbitrary user input.
func (s *Store) AppendAudit(actorID int64, action, target, outcome string) error {
	if actorID <= 0 || len(action) < 2 || len(action) > 48 || len(target) < 2 || len(target) > 128 ||
		strings.ContainsAny(action, "\r\n\x00 /") || strings.ContainsAny(target, "\r\n\x00?&#") ||
		(outcome != "success" && outcome != "denied" && outcome != "failed") {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("INSERT INTO audit_events(actor_id,action,target,outcome,created_at) VALUES(?,?,?,?,?)",
		actorID, action, target, outcome, time.Now().Unix()); err != nil {
		return err
	}
	// Bound both storage and retention. Keep a little overlap for timestamps
	// so a burst cannot grow the table beyond MaxAuditHistory.
	if _, err := tx.Exec(`DELETE FROM audit_events WHERE created_at<?
 OR id<=(SELECT COALESCE(MAX(id),0)-? FROM audit_events)`,
		time.Now().Add(-AuditRetentionDays*24*time.Hour).Unix(), MaxAuditHistory); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ListAudit(actorSession string, beforeID int64, limit int) ([]AuditEvent, int64, error) {
	actor, ok := s.Identity(actorSession)
	if !ok || actor.Role != RoleAdmin {
		return nil, 0, ErrForbidden
	}
	if beforeID < 0 || limit < 1 || limit > 100 {
		return nil, 0, ErrInput
	}
	query := `SELECT id,actor_id,action,target,outcome,created_at FROM audit_events`
	args := []any{}
	if beforeID > 0 {
		query += " WHERE id<?"
		args = append(args, beforeID)
	}
	query += " ORDER BY id DESC LIMIT ?"
	args = append(args, limit+1)
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	result := []AuditEvent{}
	for rows.Next() {
		var entry AuditEvent
		if err := rows.Scan(&entry.ID, &entry.ActorID, &entry.Action, &entry.Target, &entry.Outcome, &entry.CreatedAt); err != nil {
			return nil, 0, err
		}
		result = append(result, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	next := int64(0)
	if len(result) > limit {
		result = result[:limit]
		next = result[len(result)-1].ID
	}
	return result, next, nil
}
