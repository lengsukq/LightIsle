package auth

import (
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	familyBoardMaxContentRunes = 500
	familyBoardDefaultLimit    = 50
	familyBoardMaxLimit        = 200
)

var (
	allowedBoardTags = map[string]bool{
		"留言": true,
		"提醒": true,
		"采购": true,
		"心愿": true,
	}
	allowedBoardColors = map[string]bool{
		"amber":  true,
		"blue":   true,
		"rose":   true,
		"sage":   true,
		"violet": true,
	}
)

// FamilyBoardMessage is a persistent household bulletin card shared across all
// signed-in family members. Pinned messages sort first, followed by reverse
// chronological order (newest first).
type FamilyBoardMessage struct {
	ID             int64  `json:"id"`
	AuthorUserID   int64  `json:"authorUserId"`
	AuthorUsername string `json:"authorUsername"`
	AuthorRole     string `json:"authorRole"`
	Content        string `json:"content"`
	Tag            string `json:"tag"`
	Color          string `json:"color"`
	Pinned         bool   `json:"pinned"`
	PinnedAt       int64  `json:"pinnedAt,omitempty"`
	PinnedBy       string `json:"pinnedBy,omitempty"`
	CreatedAt      int64  `json:"createdAt"`
}

func normalizeBoardInput(content, tag, color string) (string, string, string, error) {
	trimmed := strings.TrimSpace(content)
	count := utf8.RuneCountInString(trimmed)
	if count < 1 || count > familyBoardMaxContentRunes {
		return "", "", "", ErrInput
	}
	cleanTag := strings.TrimSpace(tag)
	if cleanTag == "" {
		cleanTag = "留言"
	}
	if !allowedBoardTags[cleanTag] {
		return "", "", "", ErrInput
	}
	cleanColor := strings.TrimSpace(strings.ToLower(color))
	if cleanColor == "" {
		cleanColor = "amber"
	}
	if !allowedBoardColors[cleanColor] {
		return "", "", "", ErrInput
	}
	return trimmed, cleanTag, cleanColor, nil
}

func scanFamilyBoardMessage(scanner interface{ Scan(...any) error }) (FamilyBoardMessage, error) {
	var msg FamilyBoardMessage
	var pinned int
	err := scanner.Scan(
		&msg.ID,
		&msg.AuthorUserID,
		&msg.AuthorUsername,
		&msg.AuthorRole,
		&msg.Content,
		&msg.Tag,
		&msg.Color,
		&pinned,
		&msg.PinnedAt,
		&msg.PinnedBy,
		&msg.CreatedAt,
	)
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	msg.Pinned = pinned == 1
	return msg, nil
}

// ListFamilyBoardMessages returns family board messages ordered with pinned
// messages first, then reverse chronologically by creation time and id.
func (s *Store) ListFamilyBoardMessages(actorToken string, limit int) ([]FamilyBoardMessage, error) {
	if _, ok := s.Identity(actorToken); !ok {
		return nil, ErrForbidden
	}
	if limit <= 0 {
		limit = familyBoardDefaultLimit
	}
	if limit > familyBoardMaxLimit {
		limit = familyBoardMaxLimit
	}
	rows, err := s.readDB().Query(`
		SELECT id, author_user_id, author_username, author_role, content, tag, color, pinned, pinned_at, pinned_by, created_at
		FROM family_board_messages
		ORDER BY pinned DESC, pinned_at DESC, created_at DESC, id DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]FamilyBoardMessage, 0)
	for rows.Next() {
		msg, err := scanFamilyBoardMessage(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, msg)
	}
	return list, rows.Err()
}

// CreateFamilyBoardMessage lets any signed-in family member (admin or member)
// post a new message card to the household message board.
func (s *Store) CreateFamilyBoardMessage(actorToken, content, tag, color string) (FamilyBoardMessage, error) {
	actor, ok := s.Identity(actorToken)
	if !ok {
		return FamilyBoardMessage{}, ErrForbidden
	}
	cleanContent, cleanTag, cleanColor, err := normalizeBoardInput(content, tag, color)
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	now := time.Now().Unix()
	res, err := s.db.Exec(`
		INSERT INTO family_board_messages
			(author_user_id, author_username, author_role, content, tag, color, pinned, pinned_at, pinned_by, created_at)
		VALUES (?, ?, ?, ?, ?, ?, 0, 0, '', ?)`,
		actor.ID, actor.Username, actor.Role, cleanContent, cleanTag, cleanColor, now)
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	return FamilyBoardMessage{
		ID:             id,
		AuthorUserID:   actor.ID,
		AuthorUsername: actor.Username,
		AuthorRole:     actor.Role,
		Content:        cleanContent,
		Tag:            cleanTag,
		Color:          cleanColor,
		Pinned:         false,
		CreatedAt:      now,
	}, nil
}

// SetFamilyBoardMessagePinned lets an administrator pin or unpin any message.
func (s *Store) SetFamilyBoardMessagePinned(actorToken string, id int64, pinned bool) (FamilyBoardMessage, error) {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return FamilyBoardMessage{}, ErrForbidden
	}
	if id <= 0 {
		return FamilyBoardMessage{}, ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	defer tx.Rollback()
	if err := requireAdminSessionTx(tx, actorToken, actor.ID); err != nil {
		return FamilyBoardMessage{}, err
	}
	pinVal := 0
	var pinnedAt int64
	pinnedBy := ""
	if pinned {
		pinVal = 1
		pinnedAt = time.Now().Unix()
		pinnedBy = actor.Username
	}
	res, err := tx.Exec(`
		UPDATE family_board_messages
		SET pinned=?, pinned_at=?, pinned_by=?
		WHERE id=?`, pinVal, pinnedAt, pinnedBy, id)
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return FamilyBoardMessage{}, err
	}
	if affected == 0 {
		return FamilyBoardMessage{}, ErrNotFound
	}
	row := tx.QueryRow(`
		SELECT id, author_user_id, author_username, author_role, content, tag, color, pinned, pinned_at, pinned_by, created_at
		FROM family_board_messages WHERE id=?`, id)
	msg, err := scanFamilyBoardMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return FamilyBoardMessage{}, ErrNotFound
		}
		return FamilyBoardMessage{}, err
	}
	if err := tx.Commit(); err != nil {
		return FamilyBoardMessage{}, err
	}
	return msg, nil
}

// DeleteFamilyBoardMessage lets an administrator delete any message, and lets
// an ordinary member delete only their own messages.
func (s *Store) DeleteFamilyBoardMessage(actorToken string, id int64) error {
	actor, ok := s.Identity(actorToken)
	if !ok {
		return ErrForbidden
	}
	if id <= 0 {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if actor.Role == RoleAdmin {
		if err := requireAdminSessionTx(tx, actorToken, actor.ID); err != nil {
			return err
		}
		res, err := tx.Exec(`DELETE FROM family_board_messages WHERE id=?`, id)
		if err != nil {
			return err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if affected == 0 {
			return ErrNotFound
		}
		return tx.Commit()
	}
	var authorID int64
	err = tx.QueryRow(`SELECT author_user_id FROM family_board_messages WHERE id=?`, id).Scan(&authorID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if authorID != actor.ID {
		return ErrForbidden
	}
	res, err := tx.Exec(`DELETE FROM family_board_messages WHERE id=? AND author_user_id=?`, id, actor.ID)
	if err != nil {
		return err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return ErrNotFound
	}
	return tx.Commit()
}
