// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"
	"time"
)

// astrad, astraOS's system service: one JSON object per line on its socket
// (astra's docs/IPC.md). astrad knows this program is WhatsAstra from its uid,
// so the notifications are WhatsAstra's.
type Astra struct {
	mu   sync.Mutex
	conn net.Conn
	r    *bufio.Reader
	next int
}

func (a *Astra) socket() string {
	if s := os.Getenv("ASTRA_SOCKET"); s != "" {
		return s
	}
	return "/dev/socket/astrad"
}

func (a *Astra) Call(method string, params any) (json.RawMessage, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for attempt := 0; attempt < 2; attempt++ {
		if a.conn == nil {
			c, err := net.DialTimeout("unix", a.socket(), 3*time.Second)
			if err != nil {
				return nil, err
			}
			a.conn, a.r = c, bufio.NewReaderSize(c, 1<<16)
		}
		a.next++
		id := a.next
		req, _ := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
		a.conn.SetDeadline(time.Now().Add(10 * time.Second))
		if _, err := a.conn.Write(append(req, '\n')); err != nil {
			a.conn.Close()
			a.conn = nil
			continue // astrad restarted: once more on a new connection
		}
		for {
			line, err := a.r.ReadBytes('\n')
			if err != nil {
				a.conn.Close()
				a.conn = nil
				return nil, err
			}
			var reply struct {
				ID     int             `json:"id"`
				Result json.RawMessage `json:"result"`
				Error  *struct {
					Message string `json:"message"`
				} `json:"error"`
			}
			if json.Unmarshal(line, &reply) != nil || reply.ID != id {
				continue // an event, or an older reply
			}
			if reply.Error != nil {
				return nil, errors.New(reply.Error.Message)
			}
			return reply.Result, nil
		}
	}
	return nil, errors.New("astrad is not reachable")
}

// Notify posts a notification, or changes the one with that id; returns its id.
func (a *Astra) Notify(id int, title, body string, args map[string]any) int {
	params := map[string]any{"title": title, "body": body, "args": args}
	if id > 0 {
		params["id"] = id
		params["alert"] = true
		if res, err := a.Call("notifications.update", params); err == nil && string(res) == "true" {
			return id
		}
		delete(params, "id")
		delete(params, "alert")
	}
	res, err := a.Call("notifications.post", params)
	if err != nil {
		return 0
	}
	var n int
	json.Unmarshal(res, &n)
	return n
}

func (a *Astra) Dismiss(id int) {
	if id > 0 {
		a.Call("notifications.dismiss", map[string]any{"id": id})
	}
}
