// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"errors"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// Typing tells the chat that the user is writing (or stopped).
func (w *WA) Typing(chatID string, on bool) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	state := types.ChatPresencePaused
	if on {
		state = types.ChatPresenceComposing
	}
	return client.SendChatPresence(context.Background(), chat, state, types.ChatPresenceMediaText)
}

// Rename changes a group's name.
func (w *WA) GroupRename(chatID, name string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 25 {
		return errors.New("give the group a name of up to 25 characters")
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	if err := client.SetGroupName(context.Background(), chat, name); err != nil {
		return err
	}
	w.store.SetChatName(chat.String(), name, true)
	w.hub.Publish(Event{Kind: "chats"})
	return nil
}

// GroupTopic changes a group's description.
func (w *WA) GroupTopic(chatID, topic string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	return client.SetGroupTopic(context.Background(), chat, "", "", strings.TrimSpace(topic))
}

// GroupPeople adds people to a group, removes them, or makes them admins.
func (w *WA) GroupPeople(chatID, action string, people []string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	var change whatsmeow.ParticipantChange
	switch action {
	case "add":
		change = whatsmeow.ParticipantChangeAdd
	case "remove":
		change = whatsmeow.ParticipantChangeRemove
	case "promote":
		change = whatsmeow.ParticipantChangePromote
	case "demote":
		change = whatsmeow.ParticipantChangeDemote
	default:
		return errors.New("unknown action")
	}
	var jids []types.JID
	for _, p := range people {
		if j, err := types.ParseJID(p); err == nil {
			jids = append(jids, j)
		}
	}
	if len(jids) == 0 {
		return errors.New("choose who")
	}
	if _, err := client.UpdateGroupParticipants(context.Background(), chat, jids, change); err != nil {
		return err
	}
	w.hub.Publish(Event{Kind: "chats"})
	return nil
}

// PostStatus puts a text on the user's status for the next 24 hours.
func (w *WA) PostStatus(text string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return errors.New("write something")
	}
	if len([]rune(text)) > 700 {
		return errors.New("a status is up to 700 characters")
	}
	// A coloured card, as WhatsApp's own text statuses are.
	msg := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:           proto.String(text),
		BackgroundArgb: proto.Uint32(0xFF128C7E),
		TextArgb:       proto.Uint32(0xFFFFFFFF),
		Font:           waE2E.ExtendedTextMessage_SYSTEM.Enum(),
	}}
	_, err = client.SendMessage(context.Background(), types.StatusBroadcastJID, msg)
	return err
}

// Forward sends a message of one chat to another. Text goes as it is; media
// goes as its caption with a note, since the file is not on the phone twice.
func (w *WA) Forward(fromChat, id, toChat string) (*Message, error) {
	m := w.store.Message(fromChat, id)
	if m == nil {
		return nil, errors.New("that message is gone")
	}
	text := m.Body
	if text == "" {
		return nil, errors.New("only messages with text can be forwarded")
	}
	return w.SendText(toChat, text, "")
}

// Profile is what the user shows: their name, number and about text.
type Profile struct {
	Name  string `json:"name"`
	Phone string `json:"phone"`
	About string `json:"about"`
}

func (w *WA) Profile() (*Profile, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	p := &Profile{Name: client.Store.PushName}
	if client.Store.ID != nil {
		p.Phone = "+" + client.Store.ID.User
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if info, err := client.GetUserInfo(ctx, []types.JID{client.Store.ID.ToNonAD()}); err == nil {
			for _, u := range info {
				p.About = u.Status
			}
		}
	}
	return p, nil
}

func (w *WA) SetAbout(text string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	text = strings.TrimSpace(text)
	if len([]rune(text)) > 139 {
		return errors.New("the about text is up to 139 characters")
	}
	return client.SetStatusMessage(context.Background(), types.SetStatusInput{Text: &text})
}
