package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"f1-stream/internal/auth"
	"f1-stream/internal/extractor"
	"f1-stream/internal/healthcheck"
	"f1-stream/internal/models"
	"f1-stream/internal/scraper"
	"f1-stream/internal/server"
	"f1-stream/internal/store"
)

func main() {
	listenAddr := envOr("LISTEN_ADDR", ":8080")
	dataDir := envOr("DATA_DIR", "/data")
	scrapeInterval := envDuration("SCRAPE_INTERVAL", 15*time.Minute)
	validateTimeout := envDuration("SCRAPER_VALIDATE_TIMEOUT", 10*time.Second)
	adminUsername := os.Getenv("ADMIN_USERNAME")
	sessionTTL := envDuration("SESSION_TTL", 720*time.Hour)
	headlessEnabled := os.Getenv("HEADLESS_EXTRACT_ENABLED") == "true"
	rpID := envOr("WEBAUTHN_RPID", "localhost")
	rpOrigin := envOr("WEBAUTHN_ORIGIN", "http://localhost:8080")
	rpDisplayName := envOr("WEBAUTHN_DISPLAY_NAME", "F1 Stream")

	// Initialize store
	st, err := store.New(dataDir)
	if err != nil {
		log.Fatalf("failed to init store: %v", err)
	}

	// Seed default streams
	if err := st.SeedStreams(defaultStreams()); err != nil {
		log.Printf("warning: failed to seed streams: %v", err)
	}

	// Initialize auth
	origins := strings.Split(rpOrigin, ",")
	a, err := auth.New(st, rpDisplayName, rpID, origins, adminUsername, sessionTTL)
	if err != nil {
		log.Fatalf("failed to init auth: %v", err)
	}

	// Initialize scraper
	sc := scraper.New(st, scrapeInterval, validateTimeout)

	// Initialize health checker
	healthInterval := envDuration("HEALTH_CHECK_INTERVAL", 5*time.Minute)
	healthTimeout := envDuration("HEALTH_CHECK_TIMEOUT", 10*time.Second)
	hc := healthcheck.New(st, healthInterval, healthTimeout)

	// Initialize server
	srv := server.New(st, a, sc, origins, headlessEnabled)

	// Start scraper in background
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Initialize headless browser if enabled
	if headlessEnabled {
		extractor.Init()
		defer extractor.Stop()
		// Configure TURN server if provided
		if turnURL := os.Getenv("TURN_URL"); turnURL != "" {
			turnSecret := os.Getenv("TURN_SHARED_SECRET")
			turnInternalURL := os.Getenv("TURN_INTERNAL_URL")
			extractor.SetTURNConfig(turnURL, turnSecret, turnInternalURL)
		}
		log.Println("headless video extraction enabled")
	}

	go sc.Run(ctx)
	go hc.Run(ctx)

	// Clean expired sessions periodically
	go func() {
		sessionTicker := time.NewTicker(1 * time.Hour)
		defer sessionTicker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-sessionTicker.C:
				st.CleanExpiredSessions()
			}
		}
	}()

	httpSrv := &http.Server{
		Addr:    listenAddr,
		Handler: srv.Handler(),
	}

	go func() {
		<-ctx.Done()
		log.Println("shutting down server...")
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		httpSrv.Shutdown(shutdownCtx)
	}()

	log.Printf("starting server on %s", listenAddr)
	if err := httpSrv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
	log.Println("server stopped")
}

func defaultStreams() []models.Stream {
	now := time.Now()
	streams := []struct {
		url, title string
	}{
		{"https://wearechecking.live/streams-pages/motorsports", "WeAreChecking - Motorsports"},
		{"https://vipleague.im/formula-1-schedule-streaming-links", "VIPLeague - F1"},
		{"https://www.vipbox.lc/", "VIPBox"},
		{"https://f1box.me/", "F1Box"},
		{"https://1stream.vip/formula-1-streams/", "1Stream - F1"},
	}
	var result []models.Stream
	for i, s := range streams {
		result = append(result, models.Stream{
			ID:          fmt.Sprintf("default-%d", i),
			URL:         s.url,
			Title:       s.title,
			SubmittedBy: "system",
			Published:   true,
			Source:      "system",
			CreatedAt:   now,
		})
	}
	return result
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			log.Printf("warning: invalid %s=%q, using default %v", key, v, fallback)
			return fallback
		}
		return d
	}
	return fallback
}
