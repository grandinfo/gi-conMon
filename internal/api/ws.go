package api

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/grandinfo/gi-conMon/internal/model"
)

// WSMessage is the JSON envelope sent over the WebSocket connection.
type WSMessage struct {
	Type      string `json:"type"`
	TargetID  string `json:"target_id,omitempty"`
	From      string `json:"from,omitempty"`
	To        string `json:"to,omitempty"`
	Timestamp string `json:"timestamp,omitempty"`
	Data      any    `json:"data,omitempty"`
}

// Hub manages a set of WebSocket client connections and broadcasts messages.
type Hub struct {
	mu      sync.RWMutex
	clients map[chan []byte]struct{}
}

// NewHub creates an empty Hub.
func NewHub() *Hub {
	return &Hub{clients: make(map[chan []byte]struct{})}
}

// Subscribe registers a new client channel and returns it.
func (h *Hub) Subscribe() chan []byte {
	ch := make(chan []byte, 32)
	h.mu.Lock()
	h.clients[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

// Unsubscribe removes and closes the client channel.
func (h *Hub) Unsubscribe(ch chan []byte) {
	h.mu.Lock()
	delete(h.clients, ch)
	h.mu.Unlock()
	close(ch)
}

// Broadcast sends msg to all connected clients; slow clients are skipped.
func (h *Hub) Broadcast(msg []byte) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for ch := range h.clients {
		select {
		case ch <- msg:
		default:
			// client too slow; drop message
		}
	}
}

// BroadcastEvent is a convenience helper for status-change events.
func (h *Hub) BroadcastEvent(event *model.Event) {
	msg := WSMessage{
		Type:      "status_changed",
		TargetID:  event.TargetID,
		From:      string(event.FromStatus),
		To:        string(event.ToStatus),
		Timestamp: event.Timestamp.Format(time.RFC3339),
	}
	b, _ := json.Marshal(msg)
	h.Broadcast(b)
}

// handleWS upgrades the connection and streams messages to the client.
// It uses a simple SSE-like long-poll over a raw HTTP response when a
// proper WebSocket library is not available, falling back to JSON streaming.
func (s *Server) handleWS(c *gin.Context) {
	// Use a simple Server-Sent Events (SSE) approach for broad compatibility
	// without adding a gorilla/websocket dependency to the base module.
	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")
	c.Header("Access-Control-Allow-Origin", "*")

	// Send initial snapshot
	states := s.fsm.AllStates()
	snapshot := WSMessage{Type: "snapshot", Data: states}
	snapshotJSON, _ := json.Marshal(snapshot)
	fmt.Fprintf(c.Writer, "data: %s\n\n", snapshotJSON)
	c.Writer.Flush()

	// Subscribe to hub updates
	ch := s.hub.Subscribe()
	defer s.hub.Unsubscribe(ch)

	ctx := c.Request.Context()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			fmt.Fprintf(c.Writer, "data: %s\n\n", msg)
			c.Writer.Flush()
		case <-ticker.C:
			// Heartbeat ping
			fmt.Fprintf(c.Writer, "data: {\"type\":\"ping\"}\n\n")
			c.Writer.Flush()
		}
	}
}
