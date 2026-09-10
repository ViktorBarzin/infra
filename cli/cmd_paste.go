package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func pasteCommands() []Command {
	return []Command{
		{Path: []string{"paste"}, Tier: TierWrite,
			Summary: "share a log/config as an encrypted privatebin link: paste <file|-> [--expire 1week] [--burn] [--force]", Run: pasteCreate},
	}
}

// wakeAttempts/wakeDelay bound how long we wait for a parked service. PrivateBin
// is Sablier-enrolled, so the first request wakes it and is answered by a
// loading page rather than the app; the paste is retried until the app itself
// responds.
const (
	wakeAttempts = 12
	wakeDelay    = 5 * time.Second
)

func pasteCreate(args []string) error {
	opts, err := parsePasteArgs(args)
	if err != nil {
		return err
	}

	var content []byte
	if opts.path == "-" {
		if content, err = io.ReadAll(os.Stdin); err != nil {
			return fmt.Errorf("cannot read stdin: %w", err)
		}
	} else if content, err = os.ReadFile(opts.path); err != nil {
		return fmt.Errorf("cannot read %s: %w", opts.path, err)
	}
	if len(content) == 0 {
		return fmt.Errorf("nothing to paste (empty input)")
	}
	if err := guardContent(gitleaksScan, content, opts.force, "paste"); err != nil {
		return err
	}

	enc, err := encryptPaste(string(content), opts.format, opts.burn)
	if err != nil {
		return err
	}
	enc.Payload.Meta = map[string]interface{}{"expire": opts.expire}
	body, err := json.Marshal(enc.Payload)
	if err != nil {
		return err
	}

	id, deleteToken, err := postPasteWithWake(body)
	if err != nil {
		return err
	}

	fmt.Println(pasteURL(privatebinHost, id, enc.MasterKey, opts.burn))
	if deleteToken != "" {
		fmt.Fprintf(os.Stderr, "delete: %s/?pasteid=%s&deletetoken=%s\n", privatebinHost, id, deleteToken)
	}
	return nil
}

// postPasteWithWake POSTs the paste, retrying while the response says the
// service is still coming up.
func postPasteWithWake(body []byte) (id, deleteToken string, err error) {
	client := &http.Client{Timeout: 30 * time.Second}
	for attempt := 1; attempt <= wakeAttempts; attempt++ {
		var raw string
		raw, err = postPaste(client, body)
		if err == nil {
			id, deleteToken, err = parsePasteResponse(raw)
			if err == nil {
				return id, deleteToken, nil
			}
		}
		if !isWakingError(err) {
			return "", "", err
		}
		if attempt == 1 {
			fmt.Fprintln(os.Stderr, "privatebin is parked — waking it, this takes a few seconds…")
		}
		if attempt < wakeAttempts {
			time.Sleep(wakeDelay)
		}
	}
	return "", "", fmt.Errorf("privatebin did not finish waking after %s: %w", time.Duration(wakeAttempts)*wakeDelay, err)
}

func postPaste(client *http.Client, body []byte) (string, error) {
	req, err := http.NewRequest("POST", privatebinHost+"/", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	// PrivateBin only treats a request as an API call when this header is set;
	// without it the create endpoint returns the HTML page instead.
	req.Header.Set("X-Requested-With", "JSONHttpRequest")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errWaking, err) // connection trouble is worth a retry
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 500 {
		return "", fmt.Errorf("%w: privatebin returned %s", errWaking, resp.Status)
	}
	return string(raw), nil
}
