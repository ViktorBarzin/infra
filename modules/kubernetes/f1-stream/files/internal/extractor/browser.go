package extractor

import (
	"log"
	"os/exec"
)

const maxConcurrentSessions = 10

var sessionSem chan struct{}

// Init starts dbus, PulseAudio, and prepares the session semaphore.
func Init() {
	// Start dbus (Chrome needs it for accessibility/service queries)
	if err := exec.Command("mkdir", "-p", "/var/run/dbus").Run(); err == nil {
		if err := exec.Command("dbus-daemon", "--system", "--nofork").Start(); err != nil {
			log.Printf("extractor: warning: failed to start dbus: %v", err)
		}
	}

	if err := exec.Command("pulseaudio", "--start", "--exit-idle-time=-1").Run(); err != nil {
		log.Printf("extractor: warning: failed to start PulseAudio: %v", err)
	}
	// Create a null-sink as the default audio target for all sessions
	exec.Command("pactl", "load-module", "module-null-sink",
		"sink_name=virtual_sink",
		"sink_properties=device.description=VirtualSink").Run()
	exec.Command("pactl", "set-default-sink", "virtual_sink").Run()

	sessionSem = make(chan struct{}, maxConcurrentSessions)
	log.Println("extractor: initialized")
}

// Stop kills PulseAudio.
func Stop() {
	exec.Command("pulseaudio", "--kill").Run()
	log.Println("extractor: stopped")
}
