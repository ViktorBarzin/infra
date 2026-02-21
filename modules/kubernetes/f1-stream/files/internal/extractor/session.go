package extractor

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/chromedp/cdproto/fetch"
	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"
	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/pion/webrtc/v4"
)

const (
	sessionTimeout   = 5 * time.Minute
	defaultViewportW = 1280
	defaultViewportH = 720
	turnCredentialTTL = 24 * time.Hour
)

var (
	turnURL          string
	turnSharedSecret string
	turnInternalURL  string
)

// SetTURNConfig sets the TURN server URL, shared secret, and optional internal URL.
// The internal URL is used by pion (server-side) to avoid hairpin NAT issues.
// The public URL is sent to the browser client.
func SetTURNConfig(url, secret, internalURL string) {
	turnURL = url
	turnSharedSecret = secret
	turnInternalURL = internalURL
	if turnInternalURL == "" {
		turnInternalURL = "turn:coturn.coturn.svc.cluster.local:3478"
	}
	log.Printf("extractor: TURN configured: public=%s internal=%s", url, turnInternalURL)
}

var adDomains = []string{
	"doubleclick.net", "googlesyndication.com", "googleadservices.com",
	"google-analytics.com", "adnxs.com", "criteo.com", "outbrain.com",
	"taboola.com", "amazon-adsystem.com", "popads.net", "popcash.net",
	"juicyads.com", "exoclick.com", "trafficjunky.com", "propellerads.com",
	"adsterra.com", "hilltopads.net", "revcontent.com", "mgid.com",
}

type inputMsg struct {
	Type      string                   `json:"type"`
	X         float64                  `json:"x"`
	Y         float64                  `json:"y"`
	Button    int                      `json:"button"`
	DeltaX    float64                  `json:"deltaX"`
	DeltaY    float64                  `json:"deltaY"`
	Key       string                   `json:"key"`
	Code      string                   `json:"code"`
	Mods      int                      `json:"modifiers"`
	Width     int                      `json:"width"`
	Height    int                      `json:"height"`
	SDP       string                   `json:"sdp"`
	Candidate *webrtc.ICECandidateInit `json:"candidate"`
}

// HandleBrowserSession upgrades to WebSocket and runs a remote browser session
// with WebRTC video/audio streaming and CDP input relay.
func HandleBrowserSession(w http.ResponseWriter, r *http.Request, pageURL string) {
	// Check session capacity
	select {
	case sessionSem <- struct{}{}:
		defer func() { <-sessionSem }()
	default:
		http.Error(w, `{"error":"too many active browser sessions"}`, http.StatusServiceUnavailable)
		return
	}

	conn, _, _, err := ws.UpgradeHTTP(r, w)
	if err != nil {
		log.Printf("extractor: session: ws upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Allocate display and start capture pipeline
	display := nextDisplay()
	viewW, viewH := defaultViewportW, defaultViewportH

	cap, err := NewCapture(display, viewW, viewH)
	if err != nil {
		sendWSError(conn, "failed to start capture: "+err.Error())
		log.Printf("extractor: session: capture error: %v", err)
		return
	}
	defer cap.Close()

	// Start Chrome on the virtual display
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", false),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("disable-software-rasterizer", true),
		chromedp.Flag("disable-dev-shm-usage", true),
		chromedp.Flag("disable-extensions", true),
		chromedp.Flag("disable-background-networking", true),
		chromedp.ModifyCmdFunc(func(cmd *exec.Cmd) {
			cmd.Env = append(os.Environ(), fmt.Sprintf("DISPLAY=:%d", display))
		}),
		chromedp.Flag("autoplay-policy", "no-user-gesture-required"),
		chromedp.Flag("window-size", fmt.Sprintf("%d,%d", viewW, viewH)),
		chromedp.WSURLReadTimeout(30 * time.Second),
	)
	allocCtx, allocCancel := chromedp.NewExecAllocator(ctx, opts...)
	defer allocCancel()

	tabCtx, tabCancel := chromedp.NewContext(allocCtx)
	defer tabCancel()

	var wsMu sync.Mutex

	// Build ICE servers for pion (server-side) — uses internal TURN URL to avoid hairpin NAT
	iceServers := []webrtc.ICEServer{
		{URLs: []string{"stun:stun.l.google.com:19302"}},
	}
	var turnCreds *TURNCredentials
	if turnURL != "" && turnSharedSecret != "" {
		// Server-side: use internal k8s DNS for TURN to bypass NAT
		internalCreds := GenerateTURNCredentials(turnInternalURL, turnSharedSecret, turnCredentialTTL)
		turnCreds = &internalCreds
		iceServers = append(iceServers, webrtc.ICEServer{
			URLs:           internalCreds.URLs,
			Username:       internalCreds.Username,
			Credential:     internalCreds.Credential,
			CredentialType: webrtc.ICECredentialTypePassword,
		})
	}

	// Build ad-blocking fetch patterns
	adPatterns := make([]*fetch.RequestPattern, 0, len(adDomains))
	for _, domain := range adDomains {
		adPatterns = append(adPatterns, &fetch.RequestPattern{
			URLPattern: fmt.Sprintf("*://*.%s/*", domain),
		})
	}

	// Set up event listeners before navigation
	chromedp.ListenTarget(tabCtx, func(ev interface{}) {
		switch e := ev.(type) {
		case *fetch.EventRequestPaused:
			go chromedp.Run(tabCtx, fetch.FailRequest(e.RequestID, network.ErrorReasonBlockedByClient))
		case *page.EventFrameNavigated:
			if e.Frame.ParentID == "" {
				go sendURLUpdate(tabCtx, conn, &wsMu, e.Frame.URL)
			}
		case *page.EventNavigatedWithinDocument:
			go sendURLUpdate(tabCtx, conn, &wsMu, e.URL)
		}
	})

	// Enable fetch interception (ad blocking) and navigate
	if err := chromedp.Run(tabCtx,
		fetch.Enable().WithPatterns(adPatterns),
		chromedp.Navigate(pageURL),
		chromedp.WaitReady("body"),
	); err != nil {
		sendWSError(conn, "navigation failed")
		log.Printf("extractor: session: navigate error for %s: %v", pageURL, err)
		return
	}

	// Create WebRTC media stream
	mediaStream, err := NewMediaStream(iceServers, func(c *webrtc.ICECandidate) {
		data, _ := json.Marshal(map[string]interface{}{
			"type":      "ice",
			"candidate": c.ToJSON(),
		})
		wsMu.Lock()
		wsutil.WriteServerMessage(conn, ws.OpText, data)
		wsMu.Unlock()
	}, cancel)
	if err != nil {
		sendWSError(conn, "WebRTC setup failed")
		log.Printf("extractor: session: webrtc error: %v", err)
		return
	}
	defer mediaStream.Close()

	// Create and send SDP offer
	sdp, err := mediaStream.Offer()
	if err != nil {
		sendWSError(conn, "WebRTC offer failed")
		log.Printf("extractor: session: offer error: %v", err)
		return
	}

	// Send ICE config to client — uses PUBLIC TURN URL (for browser to reach from internet)
	clientICE := []map[string]interface{}{
		{"urls": []string{"stun:stun.l.google.com:19302"}},
	}
	if turnCreds != nil {
		// Client-side: use public IP for TURN (browser connects from internet)
		publicCreds := GenerateTURNCredentials(turnURL, turnSharedSecret, turnCredentialTTL)
		clientICE = append(clientICE, map[string]interface{}{
			"urls":       publicCreds.URLs,
			"username":   publicCreds.Username,
			"credential": publicCreds.Credential,
		})
	}
	iceMsg, _ := json.Marshal(map[string]interface{}{
		"type":       "iceServers",
		"iceServers": clientICE,
	})
	wsMu.Lock()
	wsutil.WriteServerMessage(conn, ws.OpText, iceMsg)
	wsMu.Unlock()

	offerMsg, _ := json.Marshal(map[string]interface{}{
		"type": "offer",
		"sdp":  sdp,
	})
	wsMu.Lock()
	wsutil.WriteServerMessage(conn, ws.OpText, offerMsg)
	wsMu.Unlock()

	// Send ready message with viewport dimensions
	readyMsg, _ := json.Marshal(map[string]interface{}{
		"type":   "ready",
		"width":  viewW,
		"height": viewH,
	})
	wsMu.Lock()
	wsutil.WriteServerMessage(conn, ws.OpText, readyMsg)
	wsMu.Unlock()

	// Start streaming video and audio from capture pipes
	go mediaStream.StreamVideo(cap.videoR, ctx)
	go mediaStream.StreamAudio(cap.audioR, ctx)

	log.Printf("extractor: session: started for %s (display :%d)", pageURL, display)

	// Inactivity timer — cancels session after no client input
	inactivity := time.NewTimer(sessionTimeout)
	defer inactivity.Stop()
	go func() {
		select {
		case <-inactivity.C:
			log.Printf("extractor: session: inactivity timeout for %s", pageURL)
			cancel()
		case <-ctx.Done():
		}
	}()

	// Read loop — process signaling and input messages
	for {
		msgs, err := wsutil.ReadClientMessage(conn, nil)
		if err != nil {
			break
		}
		for _, m := range msgs {
			if m.OpCode != ws.OpText {
				continue
			}

			// Reset inactivity timer
			if !inactivity.Stop() {
				select {
				case <-inactivity.C:
				default:
				}
			}
			inactivity.Reset(sessionTimeout)

			var msg inputMsg
			if err := json.Unmarshal(m.Payload, &msg); err != nil {
				continue
			}

			switch msg.Type {
			case "answer":
				if err := mediaStream.SetAnswer(msg.SDP); err != nil {
					log.Printf("extractor: session: set answer error: %v", err)
				}
			case "ice":
				if msg.Candidate != nil {
					if err := mediaStream.AddICECandidate(*msg.Candidate); err != nil {
						log.Printf("extractor: session: add ICE error: %v", err)
					}
				}
			case "back":
				chromedp.Run(tabCtx, chromedp.NavigateBack())
			case "forward":
				chromedp.Run(tabCtx, chromedp.NavigateForward())
			default:
				handleInput(tabCtx, &msg)
			}
		}
	}

	log.Printf("extractor: session: ended for %s", pageURL)
}

func handleInput(ctx context.Context, msg *inputMsg) {
	switch msg.Type {
	case "mousemove":
		chromedp.Run(ctx,
			input.DispatchMouseEvent(input.MouseMoved, msg.X, msg.Y))
	case "mousedown":
		chromedp.Run(ctx,
			input.DispatchMouseEvent(input.MousePressed, msg.X, msg.Y).
				WithButton(mapButton(msg.Button)).WithClickCount(1))
	case "mouseup":
		chromedp.Run(ctx,
			input.DispatchMouseEvent(input.MouseReleased, msg.X, msg.Y).
				WithButton(mapButton(msg.Button)))
	case "scroll":
		chromedp.Run(ctx,
			input.DispatchMouseEvent(input.MouseWheel, msg.X, msg.Y).
				WithDeltaX(msg.DeltaX).WithDeltaY(msg.DeltaY))
	case "keydown":
		chromedp.Run(ctx,
			input.DispatchKeyEvent(input.KeyDown).
				WithKey(msg.Key).WithCode(msg.Code).
				WithModifiers(input.Modifier(msg.Mods)))
	case "keyup":
		chromedp.Run(ctx,
			input.DispatchKeyEvent(input.KeyUp).
				WithKey(msg.Key).WithCode(msg.Code).
				WithModifiers(input.Modifier(msg.Mods)))
	}
}

func mapButton(jsButton int) input.MouseButton {
	switch jsButton {
	case 1:
		return input.Middle
	case 2:
		return input.Right
	default:
		return input.Left
	}
}

func sendURLUpdate(tabCtx context.Context, conn net.Conn, mu *sync.Mutex, currentURL string) {
	var canBack, canForward bool
	var entries []*page.NavigationEntry
	var currentIndex int64

	if err := chromedp.Run(tabCtx, chromedp.ActionFunc(func(ctx context.Context) error {
		var err error
		currentIndex, entries, err = page.GetNavigationHistory().Do(ctx)
		return err
	})); err == nil {
		canBack = currentIndex > 0
		canForward = int(currentIndex) < len(entries)-1
	}

	data, _ := json.Marshal(map[string]interface{}{
		"type":       "url",
		"url":        currentURL,
		"canBack":    canBack,
		"canForward": canForward,
	})
	mu.Lock()
	wsutil.WriteServerMessage(conn, ws.OpText, data)
	mu.Unlock()
}

func sendWSError(conn net.Conn, msg string) {
	data, _ := json.Marshal(map[string]string{"type": "error", "message": msg})
	wsutil.WriteServerMessage(conn, ws.OpText, data)
}
