// probe.go: unauthenticated path-health surface for the in-cluster t3-probe.
// /probe/* is carved out of Authentik (stacks/t3code `module "ingress_probe"`)
// so a synthetic client can hold a long-lived WebSocket here via two routes
// (Cloudflare edge vs internal Traefik) and attribute connection drops to a
// path segment. It echoes tiny frames and reaches no t3 instance — nothing
// user-grade is exposed.
package main

import (
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

// Reap connections whose client went silent; the probe pings every 10s, so 90s
// of silence means the peer is gone even if TCP never noticed.
const probeIdleLimit = 90 * time.Second

var probeUpgrader = websocket.Upgrader{
	// No cookies or credentials are at stake on an echo endpoint, and the
	// probe connects without a browser Origin — checking it would only break it.
	CheckOrigin: func(*http.Request) bool { return true },
}

func registerProbe(mux *http.ServeMux) {
	mux.HandleFunc("/probe/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/probe/ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := probeUpgrader.Upgrade(w, r, nil)
		if err != nil {
			return // Upgrade has already written the HTTP error
		}
		defer c.Close()
		for {
			if err := c.SetReadDeadline(time.Now().Add(probeIdleLimit)); err != nil {
				return
			}
			mt, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			if err := c.WriteMessage(mt, msg); err != nil {
				return
			}
		}
	})
}
