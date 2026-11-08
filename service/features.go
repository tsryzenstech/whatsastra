// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/draw"
	_ "image/jpeg"
	"image/png"
	"math"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// Contact is someone in the address book of the main phone (synced with the
// link), or someone met in a chat.
type Contact struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Phone string `json:"phone"`
}

// Contacts lists the people WhatsApp knows, by name.
func (w *WA) Contacts() ([]Contact, error) {
	if w.client == nil || w.client.Store.ID == nil {
		return nil, errors.New("WhatsApp is not linked")
	}
	all, err := w.client.Store.Contacts.GetAllContacts(context.Background())
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []Contact{}
	for jid, c := range all {
		pn := w.phoneJID(jid)
		if pn.Server != types.DefaultUserServer || seen[pn.User] || pn.User == w.client.Store.ID.User {
			continue
		}
		name := c.FullName
		if name == "" {
			name = c.FirstName
		}
		if name == "" {
			name = c.BusinessName
		}
		if name == "" {
			name = c.PushName
		}
		if name == "" {
			continue // only people with a name: the others are numbers met in groups
		}
		seen[pn.User] = true
		out = append(out, Contact{ID: pn.String(), Name: name, Phone: "+" + pn.User})
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

// Status is one person's status updates of the last day.
type Status struct {
	ID    string     `json:"id"`
	Name  string     `json:"name"`
	Phone string     `json:"phone"`
	Time  int64      `json:"timestamp"`
	Items []*Message `json:"items"`
}

func (w *WA) Statuses() []Status {
	since := time.Now().Add(-24 * time.Hour).Unix()
	w.store.PruneStatuses(since)
	byPerson := map[string]*Status{}
	var order []string
	for _, m := range w.store.Statuses(since) {
		s := byPerson[m.Sender]
		if s == nil {
			jid, _ := types.ParseJID(m.Sender)
			name := w.nameOf(jid)
			if name == "" {
				name = m.SenderName
			}
			s = &Status{ID: m.Sender, Name: name, Phone: w.Phone(m.Sender), Time: m.Timestamp}
			byPerson[m.Sender] = s
			order = append(order, m.Sender)
		}
		s.Items = append([]*Message{m}, s.Items...) // oldest first, as they are watched
	}
	out := make([]Status, 0, len(order))
	for _, id := range order {
		out = append(out, *byPerson[id])
	}
	return out
}

// Channel is a WhatsApp channel the user follows.
type Channel struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Subscribers int    `json:"subscribers"`
	Verified    bool   `json:"verified"`
}

func (w *WA) Channels() ([]Channel, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	list, err := client.GetSubscribedNewsletters(context.Background())
	if err != nil {
		return nil, err
	}
	out := []Channel{}
	for _, n := range list {
		if n == nil {
			continue
		}
		out = append(out, Channel{ID: n.ID.String(), Name: n.ThreadMeta.Name.Text, Description: n.ThreadMeta.Description.Text,
			Subscribers: n.ThreadMeta.SubscriberCount, Verified: n.ThreadMeta.VerificationState == types.NewsletterVerificationStateVerified})
		w.store.SetChatName(n.ID.String(), n.ThreadMeta.Name.Text, false)
	}
	return out, nil
}

// ChannelMessages are a channel's latest posts, oldest first. They are public:
// their media is downloaded without keys.
func (w *WA) ChannelMessages(id string) ([]*Message, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(id)
	if err != nil {
		return nil, err
	}
	posts, err := client.GetNewsletterMessages(context.Background(), jid, &whatsmeow.GetNewsletterMessagesParams{Count: 50})
	if err != nil {
		return nil, err
	}
	out := []*Message{}
	for _, p := range posts {
		if p == nil || p.Message == nil {
			continue
		}
		m := w.convert(types.MessageInfo{MessageSource: types.MessageSource{Chat: jid, Sender: jid},
			ID: p.MessageID, Timestamp: p.Timestamp}, p.Message)
		if m == nil {
			continue
		}
		m.SenderName = ""
		w.store.AddMessage(m, false) // keeps the media's description for /media
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Timestamp < out[j].Timestamp })
	return out, nil
}

// Member is someone in a group.
type Member struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Phone string `json:"phone"`
	Admin bool   `json:"admin"`
	Me    bool   `json:"me"`
}

type Group struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Topic   string   `json:"topic"`
	Members []Member `json:"members"`
	IAdmin  bool     `json:"iAmAdmin"`
}

func (w *WA) GroupInfo(id string) (*Group, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(id)
	if err != nil {
		return nil, err
	}
	info, err := client.GetGroupInfo(context.Background(), jid)
	if err != nil {
		return nil, err
	}
	g := &Group{ID: id, Name: info.Name, Topic: info.Topic, Members: []Member{}}
	for _, p := range info.Participants {
		pn := p.PhoneNumber
		if pn.IsEmpty() {
			pn = w.phoneJID(p.JID)
		}
		me := client.Store.ID != nil && (pn.User == client.Store.ID.User || p.JID.User == client.Store.ID.User ||
			(client.Store.LID.User != "" && p.LID.User == client.Store.LID.User))
		name := w.nameOf(p.JID)
		if name == "" && !pn.IsEmpty() {
			name = w.nameOf(pn)
		}
		if name == "" {
			name = p.DisplayName
		}
		phone := ""
		if pn.Server == types.DefaultUserServer {
			phone = "+" + pn.User
		}
		g.Members = append(g.Members, Member{ID: p.JID.String(), Name: name, Phone: phone, Admin: p.IsAdmin || p.IsSuperAdmin, Me: me})
		if me && (p.IsAdmin || p.IsSuperAdmin) {
			g.IAdmin = true
		}
	}
	sort.SliceStable(g.Members, func(i, j int) bool {
		if g.Members[i].Admin != g.Members[j].Admin {
			return g.Members[i].Admin
		}
		return strings.ToLower(g.Members[i].Name) < strings.ToLower(g.Members[j].Name)
	})
	w.store.SetChatName(id, info.Name, true)
	return g, nil
}

func (w *WA) CreateGroup(name string, people []string) (*Chat, error) {
	client, err := w.connected()
	if err != nil {
		return nil, err
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 25 {
		return nil, errors.New("give the group a name of up to 25 characters")
	}
	var jids []types.JID
	for _, p := range people {
		if j, err := types.ParseJID(p); err == nil {
			jids = append(jids, j)
		}
	}
	if len(jids) == 0 {
		return nil, errors.New("choose who is in the group")
	}
	info, err := client.CreateGroup(context.Background(), whatsmeow.ReqCreateGroup{Name: name, Participants: jids})
	if err != nil {
		return nil, err
	}
	w.store.SetChatName(info.JID.String(), info.Name, true)
	w.store.SetChatState(info.JID.String(), false, false)
	w.hub.Publish(Event{Kind: "chats"})
	return &Chat{ID: info.JID.String(), Name: info.Name, IsGroup: true}, nil
}

func (w *WA) LeaveGroup(id string) error {
	client, err := w.connected()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(id)
	if err != nil {
		return err
	}
	return client.LeaveGroup(context.Background(), jid)
}

// round turns a profile photo into a round PNG (transparent corners), so the
// app shows it round without masking it itself.
func round(data []byte) []byte {
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return data
	}
	b := src.Bounds()
	side := b.Dx()
	if b.Dy() < side {
		side = b.Dy()
	}
	off := image.Pt(b.Min.X+(b.Dx()-side)/2, b.Min.Y+(b.Dy()-side)/2)
	out := image.NewNRGBA(image.Rect(0, 0, side, side))
	draw.Draw(out, out.Bounds(), src, off, draw.Src)
	r := float64(side) / 2
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			dx, dy := float64(x)+0.5-r, float64(y)+0.5-r
			d := dx*dx + dy*dy
			// A one pixel soft edge.
			if d > r*r {
				out.SetNRGBA(x, y, color.NRGBA{})
			} else if d > (r-1)*(r-1) {
				c := out.NRGBAAt(x, y)
				c.A = uint8(float64(c.A) * (r - math.Sqrt(d)))
				out.SetNRGBA(x, y, c)
			}
		}
	}
	var buf bytes.Buffer
	if png.Encode(&buf, out) != nil {
		return data
	}
	return buf.Bytes()
}
