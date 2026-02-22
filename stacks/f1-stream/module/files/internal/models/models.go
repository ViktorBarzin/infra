package models

import (
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
)

type User struct {
	ID          string                `json:"id"`
	Username    string                `json:"username"`
	IsAdmin     bool                  `json:"is_admin"`
	Credentials []webauthn.Credential `json:"credentials"`
	CreatedAt   time.Time             `json:"created_at"`
}

// WebAuthn interface implementation
func (u *User) WebAuthnID() []byte                         { return []byte(u.ID) }
func (u *User) WebAuthnName() string                       { return u.Username }
func (u *User) WebAuthnDisplayName() string                { return u.Username }
func (u *User) WebAuthnCredentials() []webauthn.Credential { return u.Credentials }

type Stream struct {
	ID          string    `json:"id"`
	URL         string    `json:"url"`
	Title       string    `json:"title"`
	SubmittedBy string    `json:"submitted_by"`
	Published   bool      `json:"published"`
	Source      string    `json:"source"`
	CreatedAt   time.Time `json:"created_at"`
}

type ScrapedLink struct {
	ID        string    `json:"id"`
	URL       string    `json:"url"`
	Title     string    `json:"title"`
	Source    string    `json:"source"`
	ScrapedAt time.Time `json:"scraped_at"`
	Stale     bool      `json:"stale"`
}

type Session struct {
	Token     string    `json:"token"`
	UserID    string    `json:"user_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

type HealthState struct {
	URL                 string    `json:"url"`
	ConsecutiveFailures int       `json:"consecutive_failures"`
	LastCheckTime       time.Time `json:"last_check_time"`
	Healthy             bool      `json:"healthy"`
}
