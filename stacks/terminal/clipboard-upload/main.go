package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	uploadDir  = "/tmp/clipboard-images"
	maxUpload  = 10 << 20 // 10MB
	listenAddr = "0.0.0.0:7683"
)

func main() {
	if err := os.MkdirAll(uploadDir, 0755); err != nil {
		log.Fatalf("Failed to create upload dir: %v", err)
	}

	http.HandleFunc("/upload", handleUpload)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("Clipboard upload service listening on %s, saving to %s", listenAddr, uploadDir)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxUpload)
	if err := r.ParseMultipartForm(maxUpload); err != nil {
		http.Error(w, "File too large (max 10MB)", http.StatusRequestEntityTooLarge)
		return
	}

	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "Missing 'image' field", http.StatusBadRequest)
		return
	}
	defer file.Close()

	ct := header.Header.Get("Content-Type")
	if !strings.HasPrefix(ct, "image/") {
		http.Error(w, "Not an image", http.StatusBadRequest)
		return
	}

	ext := ".png"
	switch ct {
	case "image/jpeg":
		ext = ".jpg"
	case "image/gif":
		ext = ".gif"
	case "image/webp":
		ext = ".webp"
	}

	randBytes := make([]byte, 4)
	rand.Read(randBytes)
	filename := fmt.Sprintf("%s-%s%s", time.Now().Format("20060102-150405"), hex.EncodeToString(randBytes), ext)
	destPath := filepath.Join(uploadDir, filename)

	dest, err := os.Create(destPath)
	if err != nil {
		http.Error(w, "Failed to save", http.StatusInternalServerError)
		return
	}
	defer dest.Close()

	if _, err := io.Copy(dest, file); err != nil {
		os.Remove(destPath)
		http.Error(w, "Failed to save", http.StatusInternalServerError)
		return
	}

	log.Printf("Saved clipboard image: %s (%s, %d bytes)", destPath, ct, header.Size)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"path": destPath})
}
