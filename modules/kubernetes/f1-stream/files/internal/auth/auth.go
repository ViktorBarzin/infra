package auth

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sync"
	"time"

	"f1-stream/internal/models"
	"f1-stream/internal/store"

	"github.com/go-webauthn/webauthn/webauthn"
)

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,30}$`)

type Auth struct {
	store         *store.Store
	webauthn      *webauthn.WebAuthn
	adminUsername string
	sessionTTL    time.Duration

	// In-memory storage for WebAuthn ceremony session data (short-lived)
	regSessions   map[string]*webauthn.SessionData
	loginSessions map[string]*webauthn.SessionData
	mu            sync.Mutex
}

func New(s *store.Store, rpDisplayName, rpID string, rpOrigins []string, adminUsername string, sessionTTL time.Duration) (*Auth, error) {
	wconfig := &webauthn.Config{
		RPDisplayName: rpDisplayName,
		RPID:          rpID,
		RPOrigins:     rpOrigins,
	}
	w, err := webauthn.New(wconfig)
	if err != nil {
		return nil, fmt.Errorf("webauthn init: %w", err)
	}
	return &Auth{
		store:         s,
		webauthn:      w,
		adminUsername:  adminUsername,
		sessionTTL:    sessionTTL,
		regSessions:   make(map[string]*webauthn.SessionData),
		loginSessions: make(map[string]*webauthn.SessionData),
	}, nil
}

// BeginRegistration starts the WebAuthn registration ceremony.
func (a *Auth) BeginRegistration(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if !usernameRe.MatchString(req.Username) {
		http.Error(w, `{"error":"username must be 3-30 chars, alphanumeric or underscore"}`, http.StatusBadRequest)
		return
	}

	existing, err := a.store.GetUserByName(req.Username)
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	if existing != nil {
		http.Error(w, `{"error":"username already taken"}`, http.StatusConflict)
		return
	}

	id, err := randomID()
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}

	isAdmin := false
	if a.adminUsername != "" && req.Username == a.adminUsername {
		isAdmin = true
	} else if a.adminUsername == "" {
		count, err := a.store.UserCount()
		if err == nil && count == 0 {
			isAdmin = true
		}
	}

	user := &models.User{
		ID:        id,
		Username:  req.Username,
		IsAdmin:   isAdmin,
		CreatedAt: time.Now(),
	}

	options, session, err := a.webauthn.BeginRegistration(user)
	if err != nil {
		log.Printf("BeginRegistration error: %v", err)
		http.Error(w, `{"error":"failed to begin registration"}`, http.StatusInternalServerError)
		return
	}

	a.mu.Lock()
	a.regSessions[req.Username] = session
	a.mu.Unlock()

	// Clean up session after 5 minutes
	go func() {
		time.Sleep(5 * time.Minute)
		a.mu.Lock()
		delete(a.regSessions, req.Username)
		a.mu.Unlock()
	}()

	// Store user temporarily - will be committed on finish
	// We create the user now so FinishRegistration can look it up
	if err := a.store.CreateUser(*user); err != nil {
		http.Error(w, `{"error":"failed to create user"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(options)
}

// FinishRegistration completes the WebAuthn registration ceremony.
func (a *Auth) FinishRegistration(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
	}
	// Username is passed as query param since body is the attestation response
	username := r.URL.Query().Get("username")
	if username == "" {
		// Try to decode from a wrapper
		http.Error(w, `{"error":"username required"}`, http.StatusBadRequest)
		return
	}
	req.Username = username

	a.mu.Lock()
	session, ok := a.regSessions[req.Username]
	if ok {
		delete(a.regSessions, req.Username)
	}
	a.mu.Unlock()

	if !ok {
		http.Error(w, `{"error":"no registration in progress"}`, http.StatusBadRequest)
		return
	}

	user, err := a.store.GetUserByName(req.Username)
	if err != nil || user == nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusBadRequest)
		return
	}

	credential, err := a.webauthn.FinishRegistration(user, *session, r)
	if err != nil {
		log.Printf("FinishRegistration error: %v", err)
		http.Error(w, `{"error":"registration failed"}`, http.StatusBadRequest)
		return
	}

	user.Credentials = append(user.Credentials, *credential)
	if err := a.store.UpdateUserCredentials(user.ID, user.Credentials); err != nil {
		http.Error(w, `{"error":"failed to save credential"}`, http.StatusInternalServerError)
		return
	}

	// Create session
	token, err := a.store.CreateSession(user.ID, a.sessionTTL)
	if err != nil {
		http.Error(w, `{"error":"failed to create session"}`, http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil,
		MaxAge:   int(a.sessionTTL.Seconds()),
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"id":       user.ID,
		"username": user.Username,
		"is_admin": user.IsAdmin,
	})
}

// BeginLogin starts the WebAuthn login ceremony.
func (a *Auth) BeginLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	user, err := a.store.GetUserByName(req.Username)
	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}
	if user == nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if len(user.Credentials) == 0 {
		http.Error(w, `{"error":"no credentials registered"}`, http.StatusBadRequest)
		return
	}

	options, session, err := a.webauthn.BeginLogin(user)
	if err != nil {
		log.Printf("BeginLogin error: %v", err)
		http.Error(w, `{"error":"failed to begin login"}`, http.StatusInternalServerError)
		return
	}

	a.mu.Lock()
	a.loginSessions[req.Username] = session
	a.mu.Unlock()

	go func() {
		time.Sleep(5 * time.Minute)
		a.mu.Lock()
		delete(a.loginSessions, req.Username)
		a.mu.Unlock()
	}()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(options)
}

// FinishLogin completes the WebAuthn login ceremony.
func (a *Auth) FinishLogin(w http.ResponseWriter, r *http.Request) {
	username := r.URL.Query().Get("username")
	if username == "" {
		http.Error(w, `{"error":"username required"}`, http.StatusBadRequest)
		return
	}

	a.mu.Lock()
	session, ok := a.loginSessions[username]
	if ok {
		delete(a.loginSessions, username)
	}
	a.mu.Unlock()

	if !ok {
		http.Error(w, `{"error":"no login in progress"}`, http.StatusBadRequest)
		return
	}

	user, err := a.store.GetUserByName(username)
	if err != nil || user == nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusBadRequest)
		return
	}

	credential, err := a.webauthn.FinishLogin(user, *session, r)
	if err != nil {
		log.Printf("FinishLogin error: %v", err)
		http.Error(w, `{"error":"login failed"}`, http.StatusUnauthorized)
		return
	}

	// Update credential sign count
	for i, c := range user.Credentials {
		if string(c.ID) == string(credential.ID) {
			user.Credentials[i].Authenticator.SignCount = credential.Authenticator.SignCount
			break
		}
	}
	if err := a.store.UpdateUserCredentials(user.ID, user.Credentials); err != nil {
		log.Printf("Failed to update credential sign count: %v", err)
	}

	token, err := a.store.CreateSession(user.ID, a.sessionTTL)
	if err != nil {
		http.Error(w, `{"error":"failed to create session"}`, http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil,
		MaxAge:   int(a.sessionTTL.Seconds()),
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"id":       user.ID,
		"username": user.Username,
		"is_admin": user.IsAdmin,
	})
}

// Logout clears the session.
func (a *Auth) Logout(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err == nil {
		a.store.DeleteSession(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

// Me returns the current user info.
func (a *Auth) Me(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if user == nil {
		http.Error(w, `{"error":"not authenticated"}`, http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"id":       user.ID,
		"username": user.Username,
		"is_admin": user.IsAdmin,
	})
}

// GetSessionUser returns the user for a session token.
func (a *Auth) GetSessionUser(token string) (*models.User, error) {
	sess, err := a.store.GetSession(token)
	if err != nil || sess == nil {
		return nil, err
	}
	return a.store.GetUserByID(sess.UserID)
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", b), nil
}
