// SPDX-License-Identifier: GPL-3.0-or-later

// whatsastra-service: WhatsApp for WhatsAstra, on the phone itself.
//
// astraOS runs it as WhatsAstra's background service (app.json "services"):
// as the app's user, with the app's data folder, from the start of the phone,
// so messages and their notifications arrive with the app closed. It links
// this phone to the user's WhatsApp as a companion device (whatsmeow) and
// keeps the chats in its own database.
//
// The app talks to it over HTTP on 127.0.0.1, at the port and with the token
// it writes to files/service.json (readable only by WhatsAstra's user):
//
//	GET  /state                       {status: starting|qr_ready|authenticating|ready|offline, qr, phone, name, error}
//	POST /logout                      unlink this phone
//	GET  /chats                       chats, pinned and most recent first, with phone numbers
//	GET  /contacts                    the address book of the main phone (synced), by name
//	GET  /status                      status updates of the last day, by person
//	GET  /channels                    channels followed; /channelMessages?id= their posts
//	GET  /group?chatId=               a group's name, description and members
//	POST /createGroup {name, participants: [id]}   POST /leaveGroup {chatId}
//	GET  /messages?chatId=&limit=&before=  messages of a chat, oldest first
//	GET  /search?q=                   messages containing text
//	GET  /events?since=               waits (25 s at most) for what changed after event `since`
//	POST /typing {chatId, on}   POST /forward {chatId, id, to}   POST /postStatus {text}
//	POST /groupRename {chatId, name}   POST /groupTopic {chatId, topic}
//	POST /groupPeople {chatId, action: add|remove|promote|demote, people}
//	GET  /profile   POST /setAbout {text}
//	POST /send     {chatId, text, quoteId}
//	POST /sendFile {chatId, path, caption, voice}
//	POST /react    {chatId, id, emoji}
//	POST /revoke   {chatId, id}        delete for everyone
//	POST /focus    {chatId}            the chat on screen ("" none): read, no notifications
//	POST /newChat  {phone}
//	POST /deleteChat {chatId}          from this phone
//	POST /save     {chatId, id}        a message's file into Download/WhatsAstra: {path}
//	GET  /media?chatId=&id=&token=     a message's photo, video, audio or file
//	GET  /avatar?chatId=&token=        a chat's profile photo
//
// Every request carries the token (X-Token header, or token= for images).
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"go.mau.fi/whatsmeow/types"
	_ "modernc.org/sqlite"
)

type Event struct {
	Seq     int64    `json:"seq"`
	Kind    string   `json:"kind"` // state chats message ack reaction deleted
	ChatID  string   `json:"chatId,omitempty"`
	IDs     []string `json:"ids,omitempty"`
	Ack     int      `json:"ack,omitempty"`
	Text    string   `json:"text,omitempty"`
	Message *Message `json:"message,omitempty"`
}

// Hub keeps the latest events for the app's long polls.
type Hub struct {
	mu     sync.Mutex
	seq    int64
	events []Event
	wake   chan struct{}
}

func NewHub() *Hub { return &Hub{wake: make(chan struct{})} }

func (h *Hub) Publish(e Event) {
	h.mu.Lock()
	h.seq++
	e.Seq = h.seq
	h.events = append(h.events, e)
	if len(h.events) > 500 {
		h.events = h.events[len(h.events)-500:]
	}
	close(h.wake)
	h.wake = make(chan struct{})
	h.mu.Unlock()
}

// Since returns the events after seq, waiting for one when there is none yet.
// An app too far behind (older events dropped) gets a "chats" event: reload.
func (h *Hub) Since(ctx context.Context, seq int64) (int64, []Event) {
	for {
		h.mu.Lock()
		cur, wake := h.seq, h.wake
		var out []Event
		if seq > cur {
			seq = 0
		}
		if len(h.events) > 0 && seq < h.events[0].Seq-1 && seq > 0 {
			out = []Event{{Seq: cur, Kind: "chats"}, {Seq: cur, Kind: "state"}}
		} else {
			for _, e := range h.events {
				if e.Seq > seq {
					out = append(out, e)
				}
			}
		}
		h.mu.Unlock()
		if len(out) > 0 || seq == 0 {
			return cur, out
		}
		select {
		case <-wake:
		case <-ctx.Done():
			return cur, nil
		}
	}
}

func dataDir() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return d
	}
	return "data"
}

func main() {
	log.SetFlags(log.LstdFlags)
	dir := dataDir()
	os.MkdirAll(dir, 0o700)
	store, err := OpenStore(filepath.Join(dir, "chats.db"))
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	hub := NewHub()
	wa, err := NewWA(dir, store, hub, &Astra{})
	if err != nil {
		log.Fatalf("whatsapp store: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go wa.Run(ctx)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	tokenBytes := make([]byte, 24)
	rand.Read(tokenBytes)
	token := hex.EncodeToString(tokenBytes)
	info, _ := json.Marshal(map[string]any{"port": ln.Addr().(*net.TCPAddr).Port, "token": token, "pid": os.Getpid()})
	tmp := filepath.Join(dir, "service.json.tmp")
	if err := os.WriteFile(tmp, info, 0o600); err != nil || os.Rename(tmp, filepath.Join(dir, "service.json")) != nil {
		log.Fatalf("cannot write service.json: %v", err)
	}
	log.Printf("listening on %s", ln.Addr())

	srv := &http.Server{Handler: api(wa, store, hub, token), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}

func api(wa *WA, store *Store, hub *Hub, token string) http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, err error) {
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(v)
	}
	body := func(r *http.Request) map[string]any {
		var b map[string]any
		json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20)).Decode(&b)
		if b == nil {
			b = map[string]any{}
		}
		return b
	}
	str := func(b map[string]any, k string) string { s, _ := b[k].(string); return s }

	mux.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) { reply(w, wa.State(), nil) })
	mux.HandleFunc("POST /logout", func(w http.ResponseWriter, r *http.Request) {
		wa.Logout()
		reply(w, map[string]bool{"ok": true}, nil)
	})
	mux.HandleFunc("GET /chats", func(w http.ResponseWriter, r *http.Request) {
		type chatOut struct {
			Chat
			Phone string `json:"phone"`
		}
		out := []chatOut{}
		for _, c := range store.Chats() {
			if c.Name == "" && !c.IsGroup {
				if jid, err := types.ParseJID(c.ID); err == nil {
					c.Name = wa.nameOf(jid)
				}
			}
			out = append(out, chatOut{Chat: c, Phone: wa.Phone(c.ID)})
		}
		reply(w, out, nil)
	})
	mux.HandleFunc("GET /contacts", func(w http.ResponseWriter, r *http.Request) {
		list, err := wa.Contacts()
		reply(w, list, err)
	})
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) { reply(w, wa.Statuses(), nil) })
	mux.HandleFunc("GET /channels", func(w http.ResponseWriter, r *http.Request) {
		list, err := wa.Channels()
		reply(w, list, err)
	})
	mux.HandleFunc("GET /channelMessages", func(w http.ResponseWriter, r *http.Request) {
		list, err := wa.ChannelMessages(r.URL.Query().Get("id"))
		reply(w, list, err)
	})
	mux.HandleFunc("GET /group", func(w http.ResponseWriter, r *http.Request) {
		g, err := wa.GroupInfo(r.URL.Query().Get("chatId"))
		reply(w, g, err)
	})
	mux.HandleFunc("POST /createGroup", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		var people []string
		if list, ok := b["participants"].([]any); ok {
			for _, p := range list {
				if s, ok := p.(string); ok {
					people = append(people, s)
				}
			}
		}
		c, err := wa.CreateGroup(str(b, "name"), people)
		reply(w, c, err)
	})
	mux.HandleFunc("POST /leaveGroup", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"ok": true}, wa.LeaveGroup(str(body(r), "chatId")))
	})
	mux.HandleFunc("GET /messages", func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if limit <= 0 || limit > 200 {
			limit = 60
		}
		before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
		list := store.Messages(r.URL.Query().Get("chatId"), limit, before)
		if list == nil {
			list = []*Message{}
		}
		reply(w, list, nil)
	})
	mux.HandleFunc("GET /search", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		list := []*Message{}
		if len(q) >= 2 {
			if found := store.Search(q, 50); found != nil {
				list = found
			}
		}
		reply(w, list, nil)
	})
	mux.HandleFunc("GET /events", func(w http.ResponseWriter, r *http.Request) {
		since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
		ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
		defer cancel()
		seq, events := hub.Since(ctx, since)
		if events == nil {
			events = []Event{}
		}
		reply(w, map[string]any{"seq": seq, "events": events}, nil)
	})
	mux.HandleFunc("POST /send", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		text := str(b, "text")
		if text == "" || len(text) > 65536 {
			reply(w, nil, errText("write a message"))
			return
		}
		m, err := wa.SendText(str(b, "chatId"), text, str(b, "quoteId"))
		reply(w, m, err)
	})
	mux.HandleFunc("POST /sendFile", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		voice, _ := b["voice"].(bool)
		m, err := wa.SendFile(str(b, "chatId"), str(b, "path"), str(b, "caption"), voice)
		reply(w, m, err)
	})
	mux.HandleFunc("POST /react", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		reply(w, map[string]bool{"ok": true}, wa.React(str(b, "chatId"), str(b, "id"), str(b, "emoji")))
	})
	mux.HandleFunc("POST /revoke", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		reply(w, map[string]bool{"ok": true}, wa.Revoke(str(b, "chatId"), str(b, "id")))
	})
	mux.HandleFunc("POST /focus", func(w http.ResponseWriter, r *http.Request) {
		wa.SetFocus(str(body(r), "chatId"))
		reply(w, map[string]bool{"ok": true}, nil)
	})
	mux.HandleFunc("POST /newChat", func(w http.ResponseWriter, r *http.Request) {
		c, err := wa.NewChat(str(body(r), "phone"))
		reply(w, c, err)
	})
	mux.HandleFunc("POST /typing", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		on, _ := b["on"].(bool)
		reply(w, map[string]bool{"ok": true}, wa.Typing(str(b, "chatId"), on))
	})
	mux.HandleFunc("POST /groupRename", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		reply(w, map[string]bool{"ok": true}, wa.GroupRename(str(b, "chatId"), str(b, "name")))
	})
	mux.HandleFunc("POST /groupTopic", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		reply(w, map[string]bool{"ok": true}, wa.GroupTopic(str(b, "chatId"), str(b, "topic")))
	})
	mux.HandleFunc("POST /groupPeople", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		var people []string
		if list, ok := b["people"].([]any); ok {
			for _, p := range list {
				if s, ok := p.(string); ok {
					people = append(people, s)
				}
			}
		}
		reply(w, map[string]bool{"ok": true}, wa.GroupPeople(str(b, "chatId"), str(b, "action"), people))
	})
	mux.HandleFunc("POST /postStatus", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"ok": true}, wa.PostStatus(str(body(r), "text")))
	})
	mux.HandleFunc("POST /forward", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		m, err := wa.Forward(str(b, "chatId"), str(b, "id"), str(b, "to"))
		reply(w, m, err)
	})
	mux.HandleFunc("GET /profile", func(w http.ResponseWriter, r *http.Request) {
		p, err := wa.Profile()
		reply(w, p, err)
	})
	mux.HandleFunc("POST /setAbout", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"ok": true}, wa.SetAbout(str(body(r), "text")))
	})
	mux.HandleFunc("POST /deleteChat", func(w http.ResponseWriter, r *http.Request) {
		chat := str(body(r), "chatId")
		store.DeleteChat(chat)
		wa.dismiss(chat)
		hub.Publish(Event{Kind: "chats"})
		reply(w, map[string]bool{"ok": true}, nil)
	})
	mux.HandleFunc("POST /save", func(w http.ResponseWriter, r *http.Request) {
		b := body(r)
		path, err := wa.Save(str(b, "chatId"), str(b, "id"))
		reply(w, map[string]string{"path": path}, err)
	})
	mux.HandleFunc("GET /media", func(w http.ResponseWriter, r *http.Request) {
		data, mimeType, err := wa.Media(r.URL.Query().Get("chatId"), r.URL.Query().Get("id"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		if mimeType == "" {
			mimeType = http.DetectContentType(data)
		}
		w.Header().Set("Content-Type", mimeType)
		w.Header().Set("Cache-Control", "private, max-age=86400")
		w.Write(data)
	})
	mux.HandleFunc("GET /avatar", func(w http.ResponseWriter, r *http.Request) {
		data, err := wa.Avatar(r.URL.Query().Get("chatId"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", http.DetectContentType(data))
		w.Header().Set("Cache-Control", "private, max-age=86400")
		w.Write(data)
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		given := r.Header.Get("X-Token")
		if given == "" {
			given = r.URL.Query().Get("token")
		}
		if subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

type errText string

func (e errText) Error() string { return string(e) }
