package server

import (
	"encoding/json"
	"html"
	"log"
	"net/http"
	"strings"

	"f1-stream/internal/auth"
	"f1-stream/internal/extractor"
	"f1-stream/internal/proxy"
	"f1-stream/internal/scraper"
	"f1-stream/internal/store"
)

type Server struct {
	store           *store.Store
	auth            *auth.Auth
	scraper         *scraper.Scraper
	mux             *http.ServeMux
	headlessEnabled bool
}

func New(s *store.Store, a *auth.Auth, sc *scraper.Scraper, origins []string, headlessEnabled bool) *Server {
	srv := &Server{
		store:           s,
		auth:            a,
		scraper:         sc,
		mux:             http.NewServeMux(),
		headlessEnabled: headlessEnabled,
	}
	srv.registerRoutes(origins)
	return srv
}

func (s *Server) Handler() http.Handler {
	return s.mux
}

func (s *Server) registerRoutes(origins []string) {
	// Apply middleware chain
	authMw := AuthMiddleware(s.auth)
	originMw := OriginCheck(origins)

	// Static files
	fs := http.FileServer(http.Dir("static"))
	s.mux.Handle("GET /static/", http.StripPrefix("/static/", fs))
	s.mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, "static/index.html")
	})

	// Health
	s.mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	// Reverse proxy for iframe embedding (strips anti-framing headers)
	proxyHandler := proxy.NewHandler()
	s.mux.Handle("GET /proxy/", proxyHandler)
	s.mux.Handle("POST /proxy/", proxyHandler)
	s.mux.Handle("HEAD /proxy/", proxyHandler)
	s.mux.Handle("OPTIONS /proxy/", proxyHandler)

	// Public API - wrap with middleware
	wrapAll := func(h http.HandlerFunc) http.Handler {
		return RecoveryMiddleware(LoggingMiddleware(originMw(authMw(h))))
	}

	// Auth endpoints
	s.mux.Handle("POST /api/auth/register/begin", wrapAll(s.auth.BeginRegistration))
	s.mux.Handle("POST /api/auth/register/finish", wrapAll(s.auth.FinishRegistration))
	s.mux.Handle("POST /api/auth/login/begin", wrapAll(s.auth.BeginLogin))
	s.mux.Handle("POST /api/auth/login/finish", wrapAll(s.auth.FinishLogin))
	s.mux.Handle("POST /api/auth/logout", wrapAll(s.auth.Logout))
	s.mux.Handle("GET /api/auth/me", wrapAll(s.auth.Me))

	// Public streams
	s.mux.Handle("GET /api/streams/public", wrapAll(s.handlePublicStreams))
	s.mux.Handle("GET /api/streams/{id}/browse", wrapAll(s.handleBrowseStream))

	// Scraped links
	s.mux.Handle("GET /api/scraped", wrapAll(s.handleScrapedLinks))
	s.mux.Handle("POST /api/scraped/refresh", wrapAll(s.handleTriggerScrape))
	s.mux.Handle("POST /api/scraped/{id}/import", wrapAll(s.handleImportScraped))

	// Authenticated endpoints
	s.mux.Handle("GET /api/streams/mine", wrapAll(RequireAuth(s.handleMyStreams)))
	s.mux.Handle("POST /api/streams", wrapAll(s.handleSubmitStream))
	s.mux.Handle("DELETE /api/streams/{id}", wrapAll(s.handleDeleteStream))

	// Admin endpoints
	s.mux.Handle("PUT /api/streams/{id}/publish", wrapAll(RequireAdmin(s.handleTogglePublish)))
	s.mux.Handle("GET /api/admin/streams", wrapAll(RequireAdmin(s.handleAllStreams)))
	s.mux.Handle("POST /api/admin/scrape", wrapAll(RequireAdmin(s.handleTriggerScrape)))
}

func (s *Server) handlePublicStreams(w http.ResponseWriter, r *http.Request) {
	streams, err := s.store.PublicStreams()
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(streams)
}

func (s *Server) handleScrapedLinks(w http.ResponseWriter, r *http.Request) {
	links, err := s.store.GetActiveScrapedLinks()
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if links == nil {
		w.Write([]byte("[]"))
		return
	}
	json.NewEncoder(w).Encode(links)
}

func (s *Server) handleImportScraped(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	link, err := s.store.GetScrapedLinkByID(id)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	if err := s.store.PublishScrapedStream(link.URL, link.Title); err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func (s *Server) handleMyStreams(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	streams, err := s.store.UserStreams(user.ID)
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if streams == nil {
		w.Write([]byte("[]"))
		return
	}
	json.NewEncoder(w).Encode(streams)
}

func (s *Server) handleSubmitStream(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())

	var req struct {
		URL   string `json:"url"`
		Title string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	req.URL = strings.TrimSpace(req.URL)
	req.Title = strings.TrimSpace(req.Title)

	if req.URL == "" {
		http.Error(w, `{"error":"url required"}`, http.StatusBadRequest)
		return
	}
	if len(req.URL) > 2048 {
		http.Error(w, `{"error":"url too long"}`, http.StatusBadRequest)
		return
	}
	if !strings.HasPrefix(req.URL, "https://") && !strings.HasPrefix(req.URL, "http://") {
		http.Error(w, `{"error":"url must start with http:// or https://"}`, http.StatusBadRequest)
		return
	}
	if req.Title == "" {
		req.Title = req.URL
	}
	req.Title = html.EscapeString(req.Title)

	submittedBy := "anonymous"
	published := true
	if user != nil {
		submittedBy = user.ID
		published = false
	}

	stream, err := s.store.AddStream(req.URL, req.Title, submittedBy, published, "user")
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(stream)
}

func (s *Server) handleDeleteStream(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	id := r.PathValue("id")

	var userID string
	var isAdmin bool
	if user != nil {
		userID = user.ID
		isAdmin = user.IsAdmin
	}

	if err := s.store.DeleteStream(id, userID, isAdmin); err != nil {
		if strings.Contains(err.Error(), "not authorized") {
			http.Error(w, `{"error":"not authorized"}`, http.StatusForbidden)
			return
		}
		if strings.Contains(err.Error(), "not found") {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func (s *Server) handleTogglePublish(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.TogglePublish(id); err != nil {
		http.Error(w, `{"error":"stream not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func (s *Server) handleAllStreams(w http.ResponseWriter, r *http.Request) {
	streams, err := s.store.LoadStreams()
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(streams)
}

func (s *Server) handleTriggerScrape(w http.ResponseWriter, r *http.Request) {
	s.scraper.TriggerScrape()
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true,"message":"scrape triggered"}`))
}

func (s *Server) handleBrowseStream(w http.ResponseWriter, r *http.Request) {
	if !s.headlessEnabled {
		http.Error(w, `{"error":"browser sessions not available"}`, http.StatusNotFound)
		return
	}

	id := r.PathValue("id")
	streams, err := s.store.LoadStreams()
	if err != nil {
		log.Printf("server: browse: failed to load streams: %v", err)
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}

	var streamURL string
	var found bool
	for _, st := range streams {
		if st.ID == id {
			if !st.Published {
				http.Error(w, `{"error":"stream not found"}`, http.StatusNotFound)
				return
			}
			streamURL = st.URL
			found = true
			break
		}
	}
	if !found {
		http.Error(w, `{"error":"stream not found"}`, http.StatusNotFound)
		return
	}

	extractor.HandleBrowserSession(w, r, streamURL)
}
