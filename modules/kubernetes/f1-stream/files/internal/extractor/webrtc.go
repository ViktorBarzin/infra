package extractor

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/ivfreader"
	"github.com/pion/webrtc/v4/pkg/media/oggreader"
)

// TURNCredentials holds ephemeral TURN credentials generated from a shared secret.
type TURNCredentials struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

// GenerateTURNCredentials creates time-limited TURN credentials using the
// shared secret (TURN REST API / coturn --use-auth-secret).
func GenerateTURNCredentials(turnURL, sharedSecret string, ttl time.Duration) TURNCredentials {
	expiry := time.Now().Add(ttl).Unix()
	username := fmt.Sprintf("%d", expiry)

	mac := hmac.New(sha1.New, []byte(sharedSecret))
	mac.Write([]byte(username))
	credential := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	return TURNCredentials{
		URLs:       []string{turnURL},
		Username:   username,
		Credential: credential,
	}
}

// MediaStream wraps a pion WebRTC PeerConnection with VP8 video and Opus audio tracks.
type MediaStream struct {
	pc         *webrtc.PeerConnection
	videoTrack *webrtc.TrackLocalStaticSample
	audioTrack *webrtc.TrackLocalStaticSample
}

// NewMediaStream creates a PeerConnection with VP8 + Opus tracks and an ICE callback.
// The cancel function is called when ICE fails to trigger session cleanup.
func NewMediaStream(iceServers []webrtc.ICEServer, onICE func(*webrtc.ICECandidate), cancel context.CancelFunc) (*MediaStream, error) {
	config := webrtc.Configuration{
		ICEServers: iceServers,
	}

	pc, err := webrtc.NewPeerConnection(config)
	if err != nil {
		return nil, err
	}

	videoTrack, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8},
		"video", "stream",
	)
	if err != nil {
		pc.Close()
		return nil, err
	}

	audioTrack, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus},
		"audio", "stream",
	)
	if err != nil {
		pc.Close()
		return nil, err
	}

	if _, err = pc.AddTrack(videoTrack); err != nil {
		pc.Close()
		return nil, err
	}
	if _, err = pc.AddTrack(audioTrack); err != nil {
		pc.Close()
		return nil, err
	}

	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("webrtc: ICE connection state: %s", state.String())
		if state == webrtc.ICEConnectionStateFailed {
			log.Printf("webrtc: ICE failed, cancelling session")
			cancel()
			return
		}
		if state == webrtc.ICEConnectionStateConnected {
			// Log selected candidate pair
			if stats := pc.GetStats(); stats != nil {
				for _, s := range stats {
					if cp, ok := s.(webrtc.ICECandidatePairStats); ok && cp.Nominated {
						log.Printf("webrtc: selected candidate pair: local=%s remote=%s",
							cp.LocalCandidateID, cp.RemoteCandidateID)
					}
				}
			}
			// Start periodic stats logging
			go func() {
				ticker := time.NewTicker(10 * time.Second)
				defer ticker.Stop()
				for range ticker.C {
					if pc.ICEConnectionState() != webrtc.ICEConnectionStateConnected &&
						pc.ICEConnectionState() != webrtc.ICEConnectionStateCompleted {
						return
					}
					stats := pc.GetStats()
					for _, s := range stats {
						if out, ok := s.(webrtc.OutboundRTPStreamStats); ok {
							log.Printf("webrtc: outbound-rtp kind=%s bytes=%d packets=%d",
								out.Kind, out.BytesSent, out.PacketsSent)
						}
					}
				}
			}()
		}
	})

	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("webrtc: peer connection state: %s", state.String())
	})

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			log.Printf("webrtc: gathered ICE candidate: type=%s addr=%s:%d",
				c.Typ.String(), c.Address, c.Port)
			if onICE != nil {
				onICE(c)
			}
		}
	})

	return &MediaStream{
		pc:         pc,
		videoTrack: videoTrack,
		audioTrack: audioTrack,
	}, nil
}

// Offer creates an SDP offer, sets it as local description, and returns the SDP string.
func (m *MediaStream) Offer() (string, error) {
	offer, err := m.pc.CreateOffer(nil)
	if err != nil {
		return "", err
	}
	if err := m.pc.SetLocalDescription(offer); err != nil {
		return "", err
	}
	return offer.SDP, nil
}

// SetAnswer sets the remote SDP answer.
func (m *MediaStream) SetAnswer(sdp string) error {
	return m.pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  sdp,
	})
}

// AddICECandidate adds a remote ICE candidate.
func (m *MediaStream) AddICECandidate(init webrtc.ICECandidateInit) error {
	return m.pc.AddICECandidate(init)
}

// StreamVideo reads VP8 frames from an IVF stream and writes them to the video track.
// Blocks until the reader returns an error or the context is cancelled.
func (m *MediaStream) StreamVideo(r io.Reader, ctx context.Context) {
	ivf, _, err := ivfreader.NewWith(r)
	if err != nil {
		log.Printf("webrtc: ivf reader error: %v", err)
		return
	}

	duration := time.Second / 30

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		frame, _, err := ivf.ParseNextFrame()
		if err != nil {
			if err != io.EOF {
				log.Printf("webrtc: video frame error: %v", err)
			}
			return
		}

		if err := m.videoTrack.WriteSample(media.Sample{
			Data:     frame,
			Duration: duration,
		}); err != nil {
			log.Printf("webrtc: video write error: %v", err)
			return
		}
	}
}

// StreamAudio reads Opus pages from an OGG stream and writes them to the audio track.
// Blocks until the reader returns an error or the context is cancelled.
func (m *MediaStream) StreamAudio(r io.Reader, ctx context.Context) {
	ogg, _, err := oggreader.NewWith(r)
	if err != nil {
		log.Printf("webrtc: ogg reader error: %v", err)
		return
	}

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		page, _, err := ogg.ParseNextPage()
		if err != nil {
			if err != io.EOF {
				log.Printf("webrtc: audio page error: %v", err)
			}
			return
		}

		if err := m.audioTrack.WriteSample(media.Sample{
			Data:     page,
			Duration: 20 * time.Millisecond,
		}); err != nil {
			log.Printf("webrtc: audio write error: %v", err)
			return
		}
	}
}

// Close closes the underlying PeerConnection.
func (m *MediaStream) Close() {
	if m.pc != nil {
		m.pc.Close()
	}
}
