package server

import (
	"log"
	"net/http"
	"strings"

	"f1-stream/internal/auth"
)

func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s", r.Method, r.URL.Path, r.RemoteAddr)
		next.ServeHTTP(w, r)
	})
}

func RecoveryMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				log.Printf("panic: %v", err)
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// AuthMiddleware injects user into context if session cookie is present.
func AuthMiddleware(a *auth.Auth) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cookie, err := r.Cookie("session")
			if err == nil && cookie.Value != "" {
				user, err := a.GetSessionUser(cookie.Value)
				if err == nil && user != nil {
					r = r.WithContext(auth.ContextWithUser(r.Context(), user))
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireAuth rejects unauthenticated requests.
func RequireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user := auth.UserFromContext(r.Context())
		if user == nil {
			http.Error(w, `{"error":"authentication required"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// RequireAdmin rejects non-admin requests.
func RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user := auth.UserFromContext(r.Context())
		if user == nil || !user.IsAdmin {
			http.Error(w, `{"error":"admin access required"}`, http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

// OriginCheck validates Origin header on mutation requests (CSRF protection).
func OriginCheck(allowedOrigins []string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS" {
				origin := r.Header.Get("Origin")
				if origin != "" {
					allowed := false
					for _, o := range allowedOrigins {
						if strings.EqualFold(origin, o) {
							allowed = true
							break
						}
					}
					if !allowed {
						http.Error(w, `{"error":"origin not allowed"}`, http.StatusForbidden)
						return
					}
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
