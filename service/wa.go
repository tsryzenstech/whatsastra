// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// WhatsApp, linked as a companion device of the user's phone, through whatsmeow
// (MPL-2.0): the multi-device protocol, end to end encrypted to this phone.
type WA struct {
	dir       string
	container *sqlstore.Container
	client    *whatsmeow.Client
	store     *Store
	hub       *Hub
	astra     *Astra

	mu       sync.Mutex
	status   string // starting, qr_ready, authenticating, ready, offline
	qr       string // data URL of the code to scan
	lastErr  string
	focus    string         // the chat the app shows (no notification for it)
	reset    chan struct{}  // ends the session: unlinked from here
	notified map[string]int // chat -> notification id
	unseen   map[string]int // chat -> messages in its notification
	language string
}

func NewWA(dir string, store *Store, hub *Hub, astra *Astra) (*WA, error) {
	container, err := sqlstore.New(context.Background(), "sqlite",
		"file:"+filepath.Join(dir, "whatsmeow.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)",
		waLog.Stdout("store", "WARN", false))
	if err != nil {
		return nil, err
	}
	return &WA{dir: dir, container: container, store: store, hub: hub, astra: astra, status: "starting",
		reset: make(chan struct{}, 1), notified: map[string]int{}, unseen: map[string]int{}, language: os.Getenv("ASTRA_LANGUAGE")}, nil
}

func (w *WA) setStatus(status, qr, errText string) {
	w.mu.Lock()
	changed := w.status != status || w.qr != qr
	w.status, w.qr, w.lastErr = status, qr, errText
	w.mu.Unlock()
	if changed {
		w.hub.Publish(Event{Kind: "state"})
	}
}

func (w *WA) State() map[string]any {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := map[string]any{"status": w.status, "qr": w.qr, "error": w.lastErr}
	if w.client != nil && w.client.Store.ID != nil {
		out["phone"] = w.client.Store.ID.User
		out["name"] = w.client.Store.PushName
	}
	return out
}

// Run connects, and links with a QR code when this phone is not linked yet.
// It returns when the context ends; a lost connection is retried by whatsmeow.
func (w *WA) Run(ctx context.Context) {
	for ctx.Err() == nil {
		if err := w.session(ctx); err != nil {
			log.Printf("whatsapp: %v", err)
			w.setStatus("offline", "", err.Error())
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
		}
	}
}

func (w *WA) session(ctx context.Context) error {
	device, err := w.container.GetFirstDevice(ctx)
	if err != nil {
		return err
	}
	client := whatsmeow.NewClient(device, waLog.Stdout("whatsapp", "WARN", false))
	client.EnableAutoReconnect = true
	client.AutoTrustIdentity = true
	w.mu.Lock()
	w.client = client
	w.mu.Unlock()
	loggedOut := make(chan struct{}, 1)
	client.AddEventHandler(func(evt any) {
		if _, ok := evt.(*events.LoggedOut); ok {
			select {
			case loggedOut <- struct{}{}:
			default:
			}
		}
		w.handle(evt)
	})

	if client.Store.ID == nil {
		qrs, err := client.GetQRChannel(ctx)
		if err != nil {
			return err
		}
		if err := client.Connect(); err != nil {
			return err
		}
		for item := range qrs {
			switch item.Event {
			case "code":
				png, err := qrcode.Encode(item.Code, qrcode.Medium, 512)
				if err == nil {
					w.setStatus("qr_ready", "data:image/png;base64,"+base64.StdEncoding.EncodeToString(png), "")
				}
			case "success":
				w.setStatus("authenticating", "", "")
			default: // timeout, error: a new code on the next round
				client.Disconnect()
				return nil
			}
		}
	} else {
		w.setStatus("authenticating", "", "")
		if err := client.Connect(); err != nil {
			return err
		}
	}

	select {
	case <-ctx.Done():
		client.Disconnect()
		return nil
	case <-loggedOut:
		client.Disconnect()
		w.forget()
		return nil
	case <-w.reset:
		client.Disconnect()
		return nil
	}
}

// forget drops the link and everything WhatsAstra kept (logout, or unlinked
// from the main phone).
func (w *WA) forget() {
	w.mu.Lock()
	client := w.client
	w.mu.Unlock()
	if client != nil && client.Store.ID != nil {
		client.Store.Delete(context.Background())
	}
	w.store.Clear()
	os.RemoveAll(filepath.Join(w.dir, "media"))
	w.mu.Lock()
	for _, id := range w.notified {
		go w.astra.Dismiss(id)
	}
	w.notified, w.unseen = map[string]int{}, map[string]int{}
	w.mu.Unlock()
	w.setStatus("starting", "", "")
	w.hub.Publish(Event{Kind: "chats"})
}

// Logout unlinks this phone (the main phone's list of linked devices loses
// it) and starts over with a new code.
func (w *WA) Logout() {
	w.mu.Lock()
	client := w.client
	w.mu.Unlock()
	if client == nil {
		return
	}
	if client.Store.ID != nil {
		// Not connected: forgotten here anyway; the main phone drops it later.
		client.Logout(context.Background())
	}
	w.forget()
	select {
	case w.reset <- struct{}{}:
	default:
	}
}

func (w *WA) handle(evt any) {
	switch e := evt.(type) {
	case *events.Connected:
		w.setStatus("ready", "", "")
		go w.refreshNames()
	case *events.Disconnected:
		w.mu.Lock()
		if w.status == "ready" {
			w.status = "authenticating"
		}
		w.mu.Unlock()
		w.hub.Publish(Event{Kind: "state"})
	case *events.StreamReplaced:
		w.setStatus("offline", "", "WhatsApp is open on another device of this kind")
	case *events.Message:
		w.onMessage(e, true)
	case *events.HistorySync:
		w.onHistory(e)
	case *events.Receipt:
		ack := 0
		switch e.Type {
		case types.ReceiptTypeDelivered:
			ack = 2
		case types.ReceiptTypeRead, types.ReceiptTypeReadSelf, types.ReceiptTypePlayed:
			ack = 3
		}
		if ack == 0 {
			return
		}
		chat := e.Chat.ToNonAD().String()
		if e.IsFromMe && ack == 3 {
			// Read on another device of mine: no longer unread here.
			w.store.SetUnread(chat, 0)
			w.dismiss(chat)
			w.hub.Publish(Event{Kind: "chats"})
			return
		}
		ids := make([]string, len(e.MessageIDs))
		for i, id := range e.MessageIDs {
			ids[i] = string(id)
		}
		w.store.SetAck(chat, ids, ack)
		w.hub.Publish(Event{Kind: "ack", ChatID: chat, IDs: ids, Ack: ack})
	case *events.PushName:
		if e.JID.Server == types.DefaultUserServer {
			if w.store.ChatName(e.JID.ToNonAD().String()) == "" {
				w.store.SetChatName(e.JID.ToNonAD().String(), e.NewPushName, false)
			}
		}
	case *events.GroupInfo:
		if e.Name != nil {
			w.store.SetChatName(e.JID.String(), e.Name.Name, true)
			w.hub.Publish(Event{Kind: "chats"})
		}
	case *events.JoinedGroup:
		w.store.SetChatName(e.JID.String(), e.GroupInfo.Name, true)
		w.hub.Publish(Event{Kind: "chats"})
	case *events.Archive:
		if e.Action != nil {
			w.store.SetChatState(e.JID.String(), e.Action.GetArchived(), false)
			w.hub.Publish(Event{Kind: "chats"})
		}
	case *events.LoggedOut:
		log.Printf("whatsapp: unlinked (%v)", e.Reason)
	}
}

// The name to show for someone: their contact name, else what they call themselves.
func (w *WA) nameOf(jid types.JID) string {
	if w.client == nil {
		return ""
	}
	c, err := w.client.Store.Contacts.GetContact(context.Background(), jid.ToNonAD())
	if err != nil || !c.Found {
		return ""
	}
	for _, n := range []string{c.FullName, c.FirstName, c.BusinessName, c.PushName} {
		if n != "" {
			return n
		}
	}
	return ""
}

func (w *WA) chatName(chat types.JID) string {
	if chat.Server == types.GroupServer {
		if name := w.store.ChatName(chat.String()); name != "" {
			return name
		}
		if info, err := w.client.GetGroupInfo(context.Background(), chat); err == nil {
			w.store.SetChatName(chat.String(), info.Name, true)
			return info.Name
		}
		return ""
	}
	if n := w.nameOf(chat); n != "" {
		return n
	}
	return w.store.ChatName(chat.String())
}

// refreshNames gives every chat the best name known (contacts arrive with the
// app state after linking).
func (w *WA) refreshNames() {
	time.Sleep(5 * time.Second)
	for _, c := range w.store.Chats() {
		jid, err := types.ParseJID(c.ID)
		if err != nil {
			continue
		}
		if name := w.chatName(jid); name != "" && name != c.Name {
			w.store.SetChatName(c.ID, name, jid.Server == types.GroupServer)
		}
	}
	if groups, err := w.client.GetJoinedGroups(context.Background()); err == nil {
		for _, g := range groups {
			w.store.SetChatName(g.JID.String(), g.Name, true)
		}
	}
	w.hub.Publish(Event{Kind: "chats"})
}

// convert turns a WhatsApp message into WhatsAstra's; nil for what is not shown
// (protocol messages, reactions: applied to their message instead).
func (w *WA) convert(info types.MessageInfo, msg *waE2E.Message) *Message {
	chat := info.Chat.ToNonAD()
	m := &Message{ID: string(info.ID), ChatID: chat.String(), Sender: info.Sender.ToNonAD().String(),
		FromMe: info.IsFromMe, Timestamp: info.Timestamp.Unix(), Ack: 1, Type: "text"}
	if !info.IsFromMe {
		m.SenderName = w.nameOf(info.Sender)
		if m.SenderName == "" {
			m.SenderName = info.PushName
		}
	}
	if msg == nil {
		return nil
	}
	if msg.GetEphemeralMessage() != nil {
		msg = msg.GetEphemeralMessage().GetMessage()
	}
	if msg.GetViewOnceMessage() != nil {
		msg = msg.GetViewOnceMessage().GetMessage()
	}
	var ctxInfo *waE2E.ContextInfo
	media := func(kind string, sub proto.Message, mimeType, caption string) {
		m.Type, m.HasMedia, m.Mime, m.Body = kind, true, mimeType, caption
		if raw, err := proto.Marshal(sub); err == nil {
			m.media = append([]byte(kind+"\n"), raw...)
		}
	}
	switch {
	case msg.Conversation != nil:
		m.Body = msg.GetConversation()
	case msg.ExtendedTextMessage != nil:
		m.Body = msg.GetExtendedTextMessage().GetText()
		ctxInfo = msg.GetExtendedTextMessage().GetContextInfo()
	case msg.ImageMessage != nil:
		im := msg.GetImageMessage()
		media("image", im, im.GetMimetype(), im.GetCaption())
		ctxInfo = im.GetContextInfo()
	case msg.VideoMessage != nil:
		v := msg.GetVideoMessage()
		media("video", v, v.GetMimetype(), v.GetCaption())
		m.Seconds = int(v.GetSeconds())
		ctxInfo = v.GetContextInfo()
	case msg.AudioMessage != nil:
		a := msg.GetAudioMessage()
		kind := "audio"
		if a.GetPTT() {
			kind = "voice"
		}
		media(kind, a, a.GetMimetype(), "")
		m.Seconds = int(a.GetSeconds())
		ctxInfo = a.GetContextInfo()
	case msg.DocumentMessage != nil:
		d := msg.GetDocumentMessage()
		media("document", d, d.GetMimetype(), d.GetCaption())
		m.FileName = d.GetFileName()
		ctxInfo = d.GetContextInfo()
	case msg.StickerMessage != nil:
		s := msg.GetStickerMessage()
		media("sticker", s, s.GetMimetype(), "")
	case msg.LocationMessage != nil:
		l := msg.GetLocationMessage()
		m.Type = "location"
		m.Body = fmt.Sprintf("%s\nhttps://maps.google.com/?q=%f,%f", l.GetName(), l.GetDegreesLatitude(), l.GetDegreesLongitude())
		m.Body = strings.TrimSpace(m.Body)
	case msg.ContactMessage != nil:
		m.Type = "contact"
		m.Body = msg.GetContactMessage().GetDisplayName()
	case msg.ReactionMessage != nil:
		r := msg.GetReactionMessage()
		w.store.SetReaction(chat.String(), r.GetKey().GetID(), r.GetText())
		w.hub.Publish(Event{Kind: "reaction", ChatID: chat.String(), IDs: []string{r.GetKey().GetID()}, Text: r.GetText()})
		return nil
	case msg.ProtocolMessage != nil:
		p := msg.GetProtocolMessage()
		if p.GetType() == waE2E.ProtocolMessage_REVOKE {
			w.store.MarkDeleted(chat.String(), p.GetKey().GetID())
			w.hub.Publish(Event{Kind: "deleted", ChatID: chat.String(), IDs: []string{p.GetKey().GetID()}})
		}
		return nil
	default:
		return nil // polls, calls, keys...: nothing to show
	}
	if ctxInfo != nil && ctxInfo.GetStanzaID() != "" {
		q := &Quote{ID: ctxInfo.GetStanzaID()}
		if quoted := ctxInfo.GetQuotedMessage(); quoted != nil {
			if quoted.GetConversation() != "" {
				q.Body = quoted.GetConversation()
			} else if quoted.GetExtendedTextMessage() != nil {
				q.Body = quoted.GetExtendedTextMessage().GetText()
			} else if quoted.GetImageMessage() != nil {
				q.Type, q.Body = "image", quoted.GetImageMessage().GetCaption()
			} else if quoted.GetVideoMessage() != nil {
				q.Type = "video"
			} else if quoted.GetAudioMessage() != nil {
				q.Type = "voice"
			} else if quoted.GetDocumentMessage() != nil {
				q.Type, q.Body = "document", quoted.GetDocumentMessage().GetFileName()
			} else if quoted.GetStickerMessage() != nil {
				q.Type = "sticker"
			}
		}
		if p, err := types.ParseJID(ctxInfo.GetParticipant()); err == nil && ctxInfo.GetParticipant() != "" {
			if w.client.Store.ID != nil && p.User == w.client.Store.ID.User {
				q.SenderName = "me"
			} else {
				q.SenderName = w.nameOf(p)
				if q.SenderName == "" {
					q.SenderName = "+" + p.User
				}
			}
		}
		m.Quote = q
	}
	return m
}

func (w *WA) onMessage(e *events.Message, live bool) {
	m := w.convert(e.Info, e.Message)
	if m == nil {
		return
	}
	if e.Info.Chat.Server == types.BroadcastServer {
		return // status updates
	}
	if name := w.chatName(e.Info.Chat.ToNonAD()); name != "" && !e.Info.IsFromMe || e.Info.Chat.Server == types.GroupServer {
		if name != "" {
			w.store.SetChatName(m.ChatID, name, e.Info.Chat.Server == types.GroupServer)
		}
	}
	w.mu.Lock()
	focused := w.focus == m.ChatID
	w.mu.Unlock()
	isNew := w.store.AddMessage(m, live && !focused)
	if !isNew || !live {
		return
	}
	w.hub.Publish(Event{Kind: "message", Message: m})
	if m.FromMe {
		w.dismiss(m.ChatID) // answered from the main phone
	} else if focused {
		w.markRead(m.ChatID)
	} else {
		w.notify(m)
	}
}

func (w *WA) onHistory(e *events.HistorySync) {
	for _, conv := range e.Data.GetConversations() {
		chat, err := types.ParseJID(conv.GetID())
		if err != nil || chat.Server == types.BroadcastServer {
			continue
		}
		if conv.GetName() != "" {
			w.store.SetChatName(chat.String(), conv.GetName(), chat.Server == types.GroupServer)
		}
		for _, hm := range conv.GetMessages() {
			evt, err := w.client.ParseWebMessage(chat, hm.GetMessage())
			if err != nil {
				continue
			}
			if m := w.convert(evt.Info, evt.Message); m != nil {
				switch hm.GetMessage().GetStatus() {
				case 3: // server ack
					m.Ack = 1
				case 4:
					m.Ack = 2
				case 5, 6:
					m.Ack = 3
				}
				w.store.AddMessage(m, false)
			}
		}
		w.store.SetUnread(chat.String(), int(conv.GetUnreadCount()))
		if conv.GetArchived() || conv.GetPinned() > 0 {
			w.store.SetChatState(chat.String(), conv.GetArchived(), conv.GetPinned() > 0)
		}
	}
	w.hub.Publish(Event{Kind: "chats"})
}

func (w *WA) it() bool { return strings.HasPrefix(w.language, "it") }

func (w *WA) preview(m *Message) string {
	labels := map[string][2]string{
		"image": {"📷 Photo", "📷 Foto"}, "video": {"🎥 Video", "🎥 Video"}, "voice": {"🎤 Voice message", "🎤 Messaggio vocale"},
		"audio": {"🎵 Audio", "🎵 Audio"}, "document": {"📄 Document", "📄 Documento"}, "sticker": {"Sticker", "Sticker"},
		"location": {"📍 Location", "📍 Posizione"}, "contact": {"👤 Contact", "👤 Contatto"},
	}
	text := m.Body
	if l, ok := labels[m.Type]; ok {
		label := l[0]
		if w.it() {
			label = l[1]
		}
		if text == "" || m.Type == "location" {
			text = label
		} else {
			text = label + ": " + text
		}
	}
	return text
}

// notify keeps one notification per chat with its newest message.
func (w *WA) notify(m *Message) {
	chat := w.store.ChatName(m.ChatID)
	if chat == "" {
		chat = "+" + strings.Split(m.ChatID, "@")[0]
	}
	body := w.preview(m)
	if strings.HasSuffix(m.ChatID, "@g.us") && m.SenderName != "" {
		body = m.SenderName + ": " + body
	}
	w.mu.Lock()
	w.unseen[m.ChatID]++
	count := w.unseen[m.ChatID]
	id := w.notified[m.ChatID]
	w.mu.Unlock()
	title := chat
	if count > 1 {
		if w.it() {
			title = fmt.Sprintf("%s (%d messaggi)", chat, count)
		} else {
			title = fmt.Sprintf("%s (%d messages)", chat, count)
		}
	}
	go func() {
		n := w.astra.Notify(id, title, body, map[string]any{"chatId": m.ChatID})
		w.mu.Lock()
		if n > 0 {
			w.notified[m.ChatID] = n
		}
		w.mu.Unlock()
	}()
}

func (w *WA) dismiss(chat string) {
	w.mu.Lock()
	id := w.notified[chat]
	delete(w.notified, chat)
	delete(w.unseen, chat)
	w.mu.Unlock()
	if id > 0 {
		go w.astra.Dismiss(id)
	}
}

func (w *WA) SetFocus(chat string) {
	w.mu.Lock()
	w.focus = chat
	w.mu.Unlock()
	if chat != "" {
		w.markRead(chat)
	}
}

// markRead sends read receipts for the unread messages of a chat.
func (w *WA) markRead(chat string) {
	w.dismiss(chat)
	jid, err := types.ParseJID(chat)
	if err != nil {
		return
	}
	var ids []types.MessageID
	var sender types.JID
	var last time.Time
	for _, m := range w.store.Messages(chat, 30, 0) {
		if m.FromMe {
			continue
		}
		ids = append(ids, types.MessageID(m.ID))
		if s, err := types.ParseJID(m.Sender); err == nil {
			sender = s
		}
		last = time.Unix(m.Timestamp, 0)
	}
	w.store.SetUnread(chat, 0)
	w.hub.Publish(Event{Kind: "chats"})
	if len(ids) == 0 || w.client == nil || !w.client.IsConnected() {
		return
	}
	if jid.Server != types.GroupServer {
		sender = jid
	}
	go w.client.MarkRead(context.Background(), ids, last, jid, sender)
}

func (w *WA) connected() (*whatsmeow.Client, error) {
	w.mu.Lock()
	client := w.client
	w.mu.Unlock()
	if client == nil || client.Store.ID == nil {
		return nil, errors.New("WhatsApp is not linked")
	}
	if !client.IsConnected() {
		return nil, errors.New("not connected to WhatsApp right now")
	}
	return client, nil
}

func (w *WA) contextFor(chat types.JID, quoteID string) *waE2E.ContextInfo {
	if quoteID == "" {
		return nil
	}
	q := w.store.Message(chat.String(), quoteID)
	if q == nil {
		return nil
	}
	info := &waE2E.ContextInfo{StanzaID: proto.String(q.ID), QuotedMessage: &waE2E.Message{Conversation: proto.String(q.Body)}}
	participant := q.Sender
	if q.FromMe && w.client.Store.ID != nil {
		participant = w.client.Store.ID.ToNonAD().String()
	}
	info.Participant = proto.String(participant)
	return info
}

func (w *WA) sent(chat types.JID, id types.MessageID, ts time.Time, m *Message) *Message {
	m.ID, m.ChatID, m.FromMe, m.Timestamp, m.Ack = string(id), chat.String(), true, ts.Unix(), 1
	w.store.AddMessage(m, false)
	w.hub.Publish(Event{Kind: "message", Message: m})
	return m
}

func (w *WA) SendText(chatID, text, quoteID string) (*Message, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{}
	if ci := w.contextFor(chat, quoteID); ci != nil {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}
	} else {
		msg.Conversation = proto.String(text)
	}
	resp, err := client.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return nil, err
	}
	m := &Message{Type: "text", Body: text}
	if q := w.store.Message(chat.String(), quoteID); q != nil {
		m.Quote = &Quote{ID: q.ID, Body: q.Body, Type: q.Type, SenderName: q.SenderName}
	}
	return w.sent(chat, resp.ID, resp.Timestamp, m), nil
}

// SendFile sends a photo, a video, a voice message or any file from the phone.
func (w *WA) SendFile(chatID, path, caption string, voice bool) (*Message, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > 100<<20 {
		return nil, errors.New("files up to 100 MB")
	}
	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mimeType == "" {
		mimeType = http.DetectContentType(data)
	}
	kind := "document"
	switch {
	case voice:
		kind = "voice"
	case strings.HasPrefix(mimeType, "image/") && mimeType != "image/gif":
		kind = "image"
	case strings.HasPrefix(mimeType, "video/"):
		kind = "video"
	case strings.HasPrefix(mimeType, "audio/"):
		kind = "audio"
	}
	mediaType := map[string]whatsmeow.MediaType{"image": whatsmeow.MediaImage, "video": whatsmeow.MediaVideo,
		"audio": whatsmeow.MediaAudio, "voice": whatsmeow.MediaAudio, "document": whatsmeow.MediaDocument}[kind]
	up, err := client.Upload(context.Background(), data, mediaType)
	if err != nil {
		return nil, err
	}
	size := proto.Uint64(uint64(len(data)))
	msg := &waE2E.Message{}
	var sub proto.Message
	switch kind {
	case "image":
		im := &waE2E.ImageMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, Mimetype: &mimeType,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: size, Caption: proto.String(caption)}
		msg.ImageMessage, sub = im, im
	case "video":
		v := &waE2E.VideoMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, Mimetype: &mimeType,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: size, Caption: proto.String(caption)}
		msg.VideoMessage, sub = v, v
	case "audio", "voice":
		a := &waE2E.AudioMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, Mimetype: &mimeType,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: size, PTT: proto.Bool(voice)}
		msg.AudioMessage, sub = a, a
	default:
		name := filepath.Base(path)
		d := &waE2E.DocumentMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, Mimetype: &mimeType,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: size, FileName: &name,
			Caption: proto.String(caption)}
		msg.DocumentMessage, sub = d, d
	}
	resp, err := client.SendMessage(context.Background(), chat, msg)
	if err != nil {
		return nil, err
	}
	m := &Message{Type: kind, Body: caption, HasMedia: true, Mime: mimeType}
	if kind == "document" {
		m.FileName = filepath.Base(path)
	}
	if raw, err := proto.Marshal(sub); err == nil {
		m.media = append([]byte(kind+"\n"), raw...)
	}
	// Keep a copy: it is shown at once, without downloading it again.
	os.MkdirAll(filepath.Join(w.dir, "media"), 0o700)
	os.WriteFile(w.mediaPath(chat.String(), string(resp.ID)), data, 0o600)
	return w.sent(chat, resp.ID, resp.Timestamp, m), nil
}

func (w *WA) React(chatID, messageID, emoji string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	m := w.store.Message(chatID, messageID)
	if m == nil {
		return errors.New("no such message")
	}
	sender := chat
	if s, err := types.ParseJID(m.Sender); err == nil && m.Sender != "" {
		sender = s
	}
	if m.FromMe && client.Store.ID != nil {
		sender = client.Store.ID.ToNonAD()
	}
	_, err = client.SendMessage(context.Background(), chat, client.BuildReaction(chat, sender, types.MessageID(messageID), emoji))
	if err == nil {
		w.store.SetReaction(chatID, messageID, emoji)
		w.hub.Publish(Event{Kind: "reaction", ChatID: chatID, IDs: []string{messageID}, Text: emoji})
	}
	return err
}

func (w *WA) Revoke(chatID, messageID string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	chat, err := types.ParseJID(chatID)
	if err != nil {
		return err
	}
	_, err = client.SendMessage(context.Background(), chat, client.BuildRevoke(chat, types.EmptyJID, types.MessageID(messageID)))
	if err == nil {
		w.store.MarkDeleted(chatID, messageID)
		w.hub.Publish(Event{Kind: "deleted", ChatID: chatID, IDs: []string{messageID}})
	}
	return err
}

// NewChat finds a phone number on WhatsApp.
func (w *WA) NewChat(phone string) (*Chat, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	if len(digits) < 6 {
		return nil, errors.New("write the number with its country code")
	}
	res, err := client.IsOnWhatsApp(context.Background(), []string{"+" + digits})
	if err != nil {
		return nil, err
	}
	if len(res) == 0 || !res[0].IsIn {
		return nil, errors.New("this number is not on WhatsApp")
	}
	jid := res[0].JID.ToNonAD()
	name := w.nameOf(jid)
	w.store.SetChatName(jid.String(), name, false)
	return &Chat{ID: jid.String(), Name: name}, nil
}

func (w *WA) mediaPath(chat, id string) string {
	safe := strings.NewReplacer("/", "_", "@", "_", ":", "_").Replace(chat + "_" + id)
	return filepath.Join(w.dir, "media", safe)
}

// Media downloads (once) and returns a message's photo, video, audio or file.
func (w *WA) Media(chatID, id string) ([]byte, string, error) {
	m := w.store.Message(chatID, id)
	if m == nil || !m.HasMedia {
		return nil, "", errors.New("no media")
	}
	path := w.mediaPath(chatID, id)
	if data, err := os.ReadFile(path); err == nil {
		return data, m.Mime, nil
	}
	client, err := w.connected()
	if err != nil {
		return nil, "", err
	}
	_, raw := w.store.MediaOf(chatID, id)
	nl := strings.IndexByte(string(raw), '\n')
	if nl < 0 {
		return nil, "", errors.New("this media can no longer be downloaded")
	}
	kind, body := string(raw[:nl]), raw[nl+1:]
	var dl whatsmeow.DownloadableMessage
	switch kind {
	case "image":
		v := &waE2E.ImageMessage{}
		err = proto.Unmarshal(body, v)
		dl = v
	case "video":
		v := &waE2E.VideoMessage{}
		err = proto.Unmarshal(body, v)
		dl = v
	case "audio", "voice":
		v := &waE2E.AudioMessage{}
		err = proto.Unmarshal(body, v)
		dl = v
	case "document":
		v := &waE2E.DocumentMessage{}
		err = proto.Unmarshal(body, v)
		dl = v
	case "sticker":
		v := &waE2E.StickerMessage{}
		err = proto.Unmarshal(body, v)
		dl = v
	default:
		return nil, "", errors.New("unknown media")
	}
	if err != nil {
		return nil, "", err
	}
	data, err := client.Download(context.Background(), dl)
	if err != nil {
		return nil, "", err
	}
	os.MkdirAll(filepath.Join(w.dir, "media"), 0o700)
	os.WriteFile(path, data, 0o600)
	return data, m.Mime, nil
}

// Avatar returns the profile photo of a chat (kept for a day).
func (w *WA) Avatar(chatID string) ([]byte, error) {
	path := filepath.Join(w.dir, "media", "avatar_"+strings.NewReplacer("@", "_", ".", "_").Replace(chatID))
	if st, err := os.Stat(path); err == nil && time.Since(st.ModTime()) < 24*time.Hour {
		if st.Size() == 0 {
			return nil, errors.New("no photo")
		}
		return os.ReadFile(path)
	}
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(chatID)
	if err != nil {
		return nil, err
	}
	os.MkdirAll(filepath.Join(w.dir, "media"), 0o700)
	info, err := client.GetProfilePictureInfo(context.Background(), jid, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || info == nil {
		os.WriteFile(path, nil, 0o600) // none: do not ask again today
		return nil, errors.New("no photo")
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	buf := make([]byte, 0, 32<<10)
	tmp := make([]byte, 32<<10)
	for {
		n, err := resp.Body.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if err != nil || len(buf) > 2<<20 {
			break
		}
	}
	os.WriteFile(path, buf, 0o600)
	return buf, nil
}

// Save copies a message's file to the shared storage (Download/WhatsAstra), where
// the Files app and the other apps find it. Needs the MEDIA permission.
func (w *WA) Save(chatID, id string) (string, error) {
	data, mimeType, err := w.Media(chatID, id)
	if err != nil {
		return "", err
	}
	m := w.store.Message(chatID, id)
	name := m.FileName
	if name == "" {
		ext := ".bin"
		if exts, _ := mime.ExtensionsByType(mimeType); len(exts) > 0 {
			ext = exts[len(exts)-1]
		}
		name = time.Unix(m.Timestamp, 0).Format("WhatsAstra 2006-01-02 15.04.05") + ext
	}
	root := os.Getenv("ASTRA_MEDIA_DIR")
	if root == "" {
		root = "/data/media/0"
	}
	dir := filepath.Join(root, "Download", "WhatsAstra")
	if err := os.MkdirAll(dir, 0o775); err != nil {
		return "", errors.New("allow WhatsAstra to use your files to save it")
	}
	base := strings.TrimSuffix(filepath.Base(name), filepath.Ext(name))
	path := filepath.Join(dir, filepath.Base(name))
	for i := 2; ; i++ {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			break
		}
		path = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", base, i, filepath.Ext(name)))
	}
	if err := os.WriteFile(path, data, 0o664); err != nil {
		return "", err
	}
	return path, nil
}
