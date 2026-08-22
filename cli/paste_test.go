package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestBase58EncodeKnownVectors(t *testing.T) {
	// Bitcoin-alphabet base58, the encoding PrivateBin uses for the key in the
	// URL fragment.
	for _, tc := range []struct {
		in   []byte
		want string
	}{
		{[]byte{}, ""},
		{[]byte{0x00}, "1"},
		{[]byte{0x00, 0x00, 0x01}, "112"},
		{[]byte("hello world"), "StV1DL6CwTryKyV"},
		{[]byte{0x61}, "2g"},
	} {
		if got := base58Encode(tc.in); got != tc.want {
			t.Errorf("base58Encode(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestBuildAdataShape(t *testing.T) {
	iv := []byte("0123456789abcdef")
	salt := []byte("saltsalt")
	ad := buildAdata(iv, salt, "plaintext", 0, 0)
	raw, err := json.Marshal(ad)
	if err != nil {
		t.Fatalf("adata must marshal: %v", err)
	}
	var back []interface{}
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if len(back) != 4 {
		t.Fatalf("adata must have 4 elements, got %d: %s", len(back), raw)
	}
	spec, ok := back[0].([]interface{})
	if !ok || len(spec) != 8 {
		t.Fatalf("adata[0] must be the 8-element cipher spec, got %v", back[0])
	}
	if spec[0] != base64.StdEncoding.EncodeToString(iv) {
		t.Errorf("adata[0][0] must be base64(iv), got %v", spec[0])
	}
	if spec[1] != base64.StdEncoding.EncodeToString(salt) {
		t.Errorf("adata[0][1] must be base64(salt), got %v", spec[1])
	}
	if spec[2] != float64(pbkdf2Iterations) || spec[3] != float64(256) || spec[4] != float64(128) {
		t.Errorf("kdf/cipher params wrong: %v", spec)
	}
	if spec[5] != "aes" || spec[6] != "gcm" || spec[7] != "zlib" {
		t.Errorf("cipher identifiers wrong: %v", spec)
	}
	if back[1] != "plaintext" {
		t.Errorf("adata[1] must be the format, got %v", back[1])
	}
}

func TestBuildAdataFlags(t *testing.T) {
	ad := buildAdata([]byte("iv"), []byte("s"), "markdown", 1, 1)
	raw, _ := json.Marshal(ad)
	if !strings.HasSuffix(string(raw), `,"markdown",1,1]`) {
		t.Errorf("discussion/burn flags not carried through: %s", raw)
	}
}

// The round trip is the real test of the crypto: it proves the ciphertext is
// decryptable with the key we hand out, and that the AAD we authenticate is
// byte-identical to the adata we ship (a mismatch there fails the GCM tag).
func TestEncryptPasteRoundTrips(t *testing.T) {
	text := "line one\nline two — with unicode ✓\n"
	enc, err := encryptPaste(text, "plaintext", false)
	if err != nil {
		t.Fatalf("encryptPaste: %v", err)
	}
	got, err := decryptPasteForTest(enc)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != text {
		t.Errorf("round trip mismatch:\n got %q\nwant %q", got, text)
	}
}

func TestEncryptPasteProducesFreshKeyAndIVEachTime(t *testing.T) {
	a, err := encryptPaste("same text", "plaintext", false)
	if err != nil {
		t.Fatal(err)
	}
	b, err := encryptPaste("same text", "plaintext", false)
	if err != nil {
		t.Fatal(err)
	}
	if a.MasterKey == b.MasterKey {
		t.Error("master key must be random per paste")
	}
	if a.Payload.CT == b.Payload.CT {
		t.Error("identical plaintext must not produce identical ciphertext")
	}
}

func TestEncryptPasteBurnAfterReadingFlag(t *testing.T) {
	enc, err := encryptPaste("x", "plaintext", true)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(enc.Payload.ADdata)
	if !strings.HasSuffix(string(raw), `,0,1]`) {
		t.Errorf("burn-after-reading must set the last adata flag: %s", raw)
	}
}

func TestPasteURLPutsKeyInFragment(t *testing.T) {
	got := pasteURL("https://pb.viktorbarzin.me", "abc123", "KEY58", false)
	if got != "https://pb.viktorbarzin.me/?abc123#KEY58" {
		t.Errorf("pasteURL = %q", got)
	}
	// Burn-after-reading pastes take a `#-` fragment so the frontend prompts
	// before spending the single read.
	burn := pasteURL("https://pb.viktorbarzin.me", "abc123", "KEY58", true)
	if burn != "https://pb.viktorbarzin.me/?abc123#-KEY58" {
		t.Errorf("burn pasteURL = %q", burn)
	}
}

func TestParsePasteResponse(t *testing.T) {
	id, deleteToken, err := parsePasteResponse(`{"status":0,"id":"abc123","url":"/?abc123","deletetoken":"tok"}`)
	if err != nil {
		t.Fatalf("parsePasteResponse: %v", err)
	}
	if id != "abc123" || deleteToken != "tok" {
		t.Errorf("got id=%q token=%q", id, deleteToken)
	}
}

func TestParsePasteResponseServerError(t *testing.T) {
	if _, _, err := parsePasteResponse(`{"status":1,"message":"paste too large"}`); err == nil {
		t.Error("want an error when status != 0")
	} else if !strings.Contains(err.Error(), "paste too large") {
		t.Errorf("want the server message surfaced, got %v", err)
	}
}

// A parked service answers the first request with Sablier's loading page, which
// is HTML. That must read as "not awake yet" (retryable), not as a hard failure.
func TestParsePasteResponseLoadingPageIsRetryable(t *testing.T) {
	_, _, err := parsePasteResponse(`<!DOCTYPE html><html><body>privatebin is starting…</body></html>`)
	if err == nil {
		t.Fatal("want an error for a non-JSON body")
	}
	if !isWakingError(err) {
		t.Errorf("an HTML body from a parked service must be retryable, got %v", err)
	}
}

func TestParsePasteResponseRealErrorIsNotRetryable(t *testing.T) {
	_, _, err := parsePasteResponse(`{"status":1,"message":"paste too large"}`)
	if err == nil {
		t.Fatal("want an error")
	}
	if isWakingError(err) {
		t.Error("a valid JSON rejection is final, not a wake retry")
	}
}

func TestParsePasteArgs(t *testing.T) {
	for _, tc := range []struct {
		args   []string
		path   string
		expire string
		burn   bool
		force  bool
		format string
	}{
		{[]string{"a.log"}, "a.log", "1week", false, false, "plaintext"},
		{[]string{"-"}, "-", "1week", false, false, "plaintext"},
		{[]string{"a.log", "--expire", "1day"}, "a.log", "1day", false, false, "plaintext"},
		{[]string{"a.log", "--burn"}, "a.log", "1week", true, false, "plaintext"},
		{[]string{"a.log", "--force"}, "a.log", "1week", false, true, "plaintext"},
		{[]string{"a.md", "--format", "markdown"}, "a.md", "1week", false, false, "markdown"},
	} {
		got, err := parsePasteArgs(tc.args)
		if err != nil {
			t.Fatalf("parsePasteArgs(%v): %v", tc.args, err)
		}
		if got.path != tc.path || got.expire != tc.expire || got.burn != tc.burn || got.force != tc.force || got.format != tc.format {
			t.Errorf("parsePasteArgs(%v) = %+v", tc.args, got)
		}
	}
	if _, err := parsePasteArgs(nil); err == nil {
		t.Error("want a usage error with no argument")
	}
	if _, err := parsePasteArgs([]string{"a.log", "--expire", "nonsense"}); err == nil {
		t.Error("an unsupported expiry must be rejected up front, not by the server")
	}
}
