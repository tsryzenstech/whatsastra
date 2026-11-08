// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"database/sql"
	"strings"
	"sync"
	"time"
)

// Chats and messages as WhatsAstra shows them. whatsmeow keeps the keys and the
// contacts; WhatsApp itself keeps no history for a linked device, so what the
// phone gets (live, and the history sync after linking) is kept here.
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

type Chat struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	IsGroup         bool   `json:"isGroup"`
	UnreadCount     int    `json:"unreadCount"`
	Timestamp       int64  `json:"timestamp"`
	LastMessage     string `json:"lastMessage"`
	LastMessageType string `json:"lastMessageType"`
	LastFromMe      bool   `json:"lastFromMe"`
	LastAck         int    `json:"lastAck"`
	Archived        bool   `json:"archived"`
	Pinned          bool   `json:"pinned"`
}

type Quote struct {
	ID         string `json:"id"`
	Body       string `json:"body"`
	Type       string `json:"type"`
	SenderName string `json:"senderName"`
}

type Message struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	Sender     string `json:"sender"`
	SenderName string `json:"senderName"`
	FromMe     bool   `json:"fromMe"`
	Timestamp  int64  `json:"timestamp"`
	Type       string `json:"type"` // text image video audio voice document sticker location contact deleted
	Body       string `json:"body"`
	HasMedia   bool   `json:"hasMedia"`
	Mime       string `json:"mime,omitempty"`
	FileName   string `json:"fileName,omitempty"`
	Seconds    int    `json:"seconds,omitempty"`
	Ack        int    `json:"ack"` // 0 sending, 1 sent, 2 delivered, 3 read, -1 failed
	Quote      *Quote `json:"quote,omitempty"`
	Reaction   string `json:"reaction,omitempty"`
	// The encrypted media's description (a serialized whatsmeow message), to
	// download it when the user opens it.
	media []byte
}

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS chats (
	id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', is_group INTEGER NOT NULL DEFAULT 0,
	unread INTEGER NOT NULL DEFAULT 0, ts INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS messages (
	id TEXT NOT NULL, chat TEXT NOT NULL, sender TEXT NOT NULL DEFAULT '', sender_name TEXT NOT NULL DEFAULT '',
	from_me INTEGER NOT NULL, ts INTEGER NOT NULL, type TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
	has_media INTEGER NOT NULL DEFAULT 0, mime TEXT NOT NULL DEFAULT '', file_name TEXT NOT NULL DEFAULT '',
	seconds INTEGER NOT NULL DEFAULT 0, ack INTEGER NOT NULL DEFAULT 1,
	quote_id TEXT NOT NULL DEFAULT '', quote_body TEXT NOT NULL DEFAULT '', quote_type TEXT NOT NULL DEFAULT '',
	quote_sender TEXT NOT NULL DEFAULT '', reaction TEXT NOT NULL DEFAULT '', media BLOB,
	PRIMARY KEY (chat, id));
CREATE INDEX IF NOT EXISTS messages_by_time ON messages (chat, ts);`)
	if err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// Chat names: a contact's, a group's subject. Only a better one replaces the old.
func (s *Store) SetChatName(id, name string, isGroup bool) {
	if name == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`INSERT INTO chats (id, name, is_group) VALUES (?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET name = excluded.name, is_group = excluded.is_group`, id, name, isGroup)
}

func (s *Store) ChatName(id string) string {
	var name string
	s.db.QueryRow(`SELECT name FROM chats WHERE id = ?`, id).Scan(&name)
	return name
}

func (s *Store) SetChatState(id string, archived, pinned bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`INSERT INTO chats (id, archived, pinned, is_group) VALUES (?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET archived = excluded.archived, pinned = excluded.pinned`,
		id, archived, pinned, strings.HasSuffix(id, "@g.us"))
}

// AddMessage stores a message (again: the same id replaces it) and moves its chat
// to the top; an unread one from someone else counts. Returns whether it is new.
func (s *Store) AddMessage(m *Message, unread bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	var exists int
	s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE chat = ? AND id = ?`, m.ChatID, m.ID).Scan(&exists)
	q := Quote{}
	if m.Quote != nil {
		q = *m.Quote
	}
	_, err := s.db.Exec(`INSERT OR REPLACE INTO messages (id, chat, sender, sender_name, from_me, ts, type, body, has_media,
		mime, file_name, seconds, ack, quote_id, quote_body, quote_type, quote_sender, reaction, media)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.ChatID, m.Sender, m.SenderName, m.FromMe, m.Timestamp, m.Type, m.Body, m.HasMedia,
		m.Mime, m.FileName, m.Seconds, m.Ack, q.ID, q.Body, q.Type, q.SenderName, m.Reaction, m.media)
	if err != nil {
		return false
	}
	add := 0
	if unread && exists == 0 && !m.FromMe {
		add = 1
	}
	s.db.Exec(`INSERT INTO chats (id, is_group, unread, ts) VALUES (?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET unread = unread + ?, ts = MAX(ts, excluded.ts)`,
		m.ChatID, strings.HasSuffix(m.ChatID, "@g.us"), add, m.Timestamp, add)
	return exists == 0
}

func (s *Store) SetUnread(chat string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`INSERT INTO chats (id, unread, is_group) VALUES (?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET unread = excluded.unread`, chat, n, strings.HasSuffix(chat, "@g.us"))
}

// SetAck raises the delivery state of my messages (never lowers it).
func (s *Store) SetAck(chat string, ids []string, ack int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range ids {
		s.db.Exec(`UPDATE messages SET ack = ? WHERE chat = ? AND id = ? AND ack < ?`, ack, chat, id, ack)
	}
}

func (s *Store) SetReaction(chat, id, emoji string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`UPDATE messages SET reaction = ? WHERE chat = ? AND id = ?`, emoji, chat, id)
}

func (s *Store) MarkDeleted(chat, id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`UPDATE messages SET type = 'deleted', body = '', has_media = 0, media = NULL WHERE chat = ? AND id = ?`, chat, id)
}

func (s *Store) DeleteChat(chat string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`DELETE FROM messages WHERE chat = ?`, chat)
	s.db.Exec(`DELETE FROM chats WHERE id = ?`, chat)
}

func (s *Store) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`DELETE FROM messages`)
	s.db.Exec(`DELETE FROM chats`)
}

const messageColumns = `id, chat, sender, sender_name, from_me, ts, type, body, has_media, mime, file_name, seconds, ack,
	quote_id, quote_body, quote_type, quote_sender, reaction`

func scanMessage(rows interface{ Scan(...any) error }) (*Message, error) {
	m := &Message{}
	var q Quote
	err := rows.Scan(&m.ID, &m.ChatID, &m.Sender, &m.SenderName, &m.FromMe, &m.Timestamp, &m.Type, &m.Body, &m.HasMedia,
		&m.Mime, &m.FileName, &m.Seconds, &m.Ack, &q.ID, &q.Body, &q.Type, &q.SenderName, &m.Reaction)
	if q.ID != "" {
		m.Quote = &q
	}
	return m, err
}

// Messages of a chat, oldest first: the last `limit` before `before` (0: the latest).
func (s *Store) Messages(chat string, limit int, before int64) []*Message {
	if before <= 0 {
		before = time.Now().Unix() + 86400
	}
	rows, err := s.db.Query(`SELECT `+messageColumns+` FROM messages WHERE chat = ? AND ts < ? ORDER BY ts DESC LIMIT ?`,
		chat, before, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		if m, err := scanMessage(rows); err == nil {
			out = append(out, m)
		}
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func (s *Store) Message(chat, id string) *Message {
	row := s.db.QueryRow(`SELECT `+messageColumns+` FROM messages WHERE chat = ? AND id = ?`, chat, id)
	m, err := scanMessage(row)
	if err != nil {
		return nil
	}
	return m
}

func (s *Store) MediaOf(chat, id string) (string, []byte) {
	var kind string
	var media []byte
	s.db.QueryRow(`SELECT type, media FROM messages WHERE chat = ? AND id = ?`, chat, id).Scan(&kind, &media)
	return kind, media
}

// Search finds messages containing text, newest first.
func (s *Store) Search(text string, limit int) []*Message {
	rows, err := s.db.Query(`SELECT `+messageColumns+` FROM messages WHERE body LIKE ? ESCAPE '\' ORDER BY ts DESC LIMIT ?`,
		"%"+strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(text)+"%", limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		if m, err := scanMessage(rows); err == nil {
			out = append(out, m)
		}
	}
	return out
}

func (s *Store) Chats() []Chat {
	rows, err := s.db.Query(`SELECT c.id, c.name, c.is_group, c.unread, c.ts, c.archived, c.pinned,
		COALESCE(m.body, ''), COALESCE(m.type, ''), COALESCE(m.from_me, 0), COALESCE(m.ack, 0)
		FROM chats c LEFT JOIN messages m ON m.rowid = (
			SELECT rowid FROM messages WHERE chat = c.id ORDER BY ts DESC LIMIT 1)
		WHERE c.ts > 0 AND c.id != 'status@broadcast' ORDER BY c.pinned DESC, c.ts DESC LIMIT 500`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []Chat{}
	for rows.Next() {
		var c Chat
		if rows.Scan(&c.ID, &c.Name, &c.IsGroup, &c.UnreadCount, &c.Timestamp, &c.Archived, &c.Pinned,
			&c.LastMessage, &c.LastMessageType, &c.LastFromMe, &c.LastAck) == nil {
			out = append(out, c)
		}
	}
	return out
}

// Statuses of the last day, newest first.
func (s *Store) Statuses(since int64) []*Message {
	rows, err := s.db.Query(`SELECT `+messageColumns+` FROM messages WHERE chat = 'status@broadcast' AND ts > ? ORDER BY ts DESC LIMIT 300`, since)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		if m, err := scanMessage(rows); err == nil {
			out = append(out, m)
		}
	}
	return out
}

// PruneStatuses forgets statuses older than a day.
func (s *Store) PruneStatuses(before int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec(`DELETE FROM messages WHERE chat = 'status@broadcast' AND ts < ?`, before)
}
