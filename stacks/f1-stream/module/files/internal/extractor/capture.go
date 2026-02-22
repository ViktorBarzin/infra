package extractor

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"sync/atomic"
	"time"
)

var displayCounter int64 = 99

func nextDisplay() int {
	return int(atomic.AddInt64(&displayCounter, 1))
}

// Capture manages an Xvfb display and separate ffmpeg pipelines for video and audio.
// Audio capture is best-effort — if PulseAudio is unavailable, video still works.
type Capture struct {
	display    int
	xvfbCmd    *exec.Cmd
	videoCmd   *exec.Cmd
	audioCmd   *exec.Cmd
	videoR     *os.File // IVF pipe reader (VP8 frames)
	audioR     *os.File // OGG pipe reader (Opus frames)
}

// NewCapture starts Xvfb on the given display and two ffmpeg processes:
// one for video (x11grab → VP8/IVF) and one for audio (pulse → Opus/OGG).
// Audio is best-effort — if it fails to start, video still works and audioR
// is set to a pipe that will return EOF immediately.
func NewCapture(display, width, height int) (*Capture, error) {
	c := &Capture{display: display}

	// Start Xvfb
	screen := fmt.Sprintf("%dx%dx24", width, height)
	c.xvfbCmd = exec.Command("Xvfb", fmt.Sprintf(":%d", display),
		"-screen", "0", screen, "-ac", "-nolisten", "tcp")
	if err := c.xvfbCmd.Start(); err != nil {
		return nil, fmt.Errorf("capture: failed to start Xvfb: %w", err)
	}

	// Wait for Xvfb to be ready (X11 socket must exist)
	ready := false
	for i := 0; i < 50; i++ {
		socketPath := fmt.Sprintf("/tmp/.X11-unix/X%d", display)
		if _, err := os.Stat(socketPath); err == nil {
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		c.xvfbCmd.Process.Kill()
		c.xvfbCmd.Wait()
		return nil, fmt.Errorf("capture: Xvfb did not start in time for display :%d", display)
	}

	// --- Video pipeline (required) ---
	videoR, videoW, err := os.Pipe()
	if err != nil {
		c.cleanup()
		return nil, fmt.Errorf("capture: video pipe: %w", err)
	}

	c.videoCmd = exec.Command("ffmpeg",
		"-loglevel", "warning",
		"-f", "x11grab", "-framerate", "30",
		"-video_size", fmt.Sprintf("%dx%d", width, height),
		"-i", fmt.Sprintf(":%d", display),
		"-c:v", "libvpx",
		"-quality", "realtime", "-cpu-used", "8",
		"-deadline", "realtime", "-b:v", "2M", "-g", "30",
		"-f", "ivf", "pipe:3",
	)
	c.videoCmd.ExtraFiles = []*os.File{videoW}
	c.videoCmd.Stdout = os.Stderr
	c.videoCmd.Stderr = os.Stderr

	if err := c.videoCmd.Start(); err != nil {
		videoR.Close()
		videoW.Close()
		c.cleanup()
		return nil, fmt.Errorf("capture: failed to start video ffmpeg: %w", err)
	}
	videoW.Close()
	c.videoR = videoR

	go func() {
		if err := c.videoCmd.Wait(); err != nil {
			log.Printf("capture: video ffmpeg exited on display :%d: %v", display, err)
		}
	}()

	// --- Audio pipeline (best-effort) ---
	audioR, audioW, err := os.Pipe()
	if err != nil {
		log.Printf("capture: audio pipe failed on display :%d: %v (continuing without audio)", display, err)
		// Provide a closed pipe so StreamAudio gets EOF immediately
		r, w, _ := os.Pipe()
		w.Close()
		c.audioR = r
		log.Printf("capture: started display :%d (%dx%d) (video only)", display, width, height)
		return c, nil
	}

	c.audioCmd = exec.Command("ffmpeg",
		"-loglevel", "warning",
		"-f", "pulse", "-i", "virtual_sink.monitor",
		"-c:a", "libopus",
		"-b:a", "128k", "-application", "lowdelay",
		"-f", "ogg", "pipe:3",
	)
	c.audioCmd.ExtraFiles = []*os.File{audioW}
	c.audioCmd.Stdout = os.Stderr
	c.audioCmd.Stderr = os.Stderr

	if err := c.audioCmd.Start(); err != nil {
		log.Printf("capture: audio ffmpeg failed to start on display :%d: %v (continuing without audio)", display, err)
		audioR.Close()
		audioW.Close()
		// Provide a closed pipe so StreamAudio gets EOF immediately
		r, w, _ := os.Pipe()
		w.Close()
		c.audioR = r
		c.audioCmd = nil
		log.Printf("capture: started display :%d (%dx%d) (video only)", display, width, height)
		return c, nil
	}
	audioW.Close()
	c.audioR = audioR

	go func() {
		if err := c.audioCmd.Wait(); err != nil {
			log.Printf("capture: audio ffmpeg exited on display :%d: %v", display, err)
		}
	}()

	log.Printf("capture: started display :%d (%dx%d) (video + audio)", display, width, height)
	return c, nil
}

func (c *Capture) cleanup() {
	if c.xvfbCmd != nil && c.xvfbCmd.Process != nil {
		c.xvfbCmd.Process.Kill()
		c.xvfbCmd.Wait()
	}
}

// Close stops ffmpeg processes, Xvfb, and releases pipe resources.
func (c *Capture) Close() {
	if c.videoCmd != nil && c.videoCmd.Process != nil {
		c.videoCmd.Process.Kill()
	}
	if c.audioCmd != nil && c.audioCmd.Process != nil {
		c.audioCmd.Process.Kill()
	}
	if c.videoR != nil {
		c.videoR.Close()
	}
	if c.audioR != nil {
		c.audioR.Close()
	}
	c.cleanup()
	log.Printf("capture: stopped display :%d", c.display)
}
