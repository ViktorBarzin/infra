package main

import (
	"bytes"
	"compress/flate"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"strings"

	"golang.org/x/crypto/pbkdf2"
)

// PrivateBin is zero-knowledge: the server only ever sees ciphertext, and the
// key lives in the URL fragment (which browsers never send upstream). That is
// why this verb does the cryptography locally instead of POSTing plaintext.
//
// Format v2, as deployed (privatebin/nginx-fpm-alpine:2.0.6):
//   https://github.com/privatebin/privatebin/wiki/Encryption-format

const (
	privatebinHost   = "https://pb.viktorbarzin.me"
	pbkdf2Iterations = 100000
	pbkdf2KeySizeBit = 256
	gcmTagSizeBit    = 128
	masterKeyBytes   = 32
	ivBytes          = 16
	saltBytes        = 8
)

// base58Alphabet is the Bitcoin alphabet PrivateBin encodes the key with.
const base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// base58Encode encodes b, preserving leading zero bytes as leading '1's (the
// big-integer conversion loses them otherwise).
func base58Encode(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	zeros := 0
	for zeros < len(b) && b[zeros] == 0 {
		zeros++
	}
	num := new(big.Int).SetBytes(b)
	radix := big.NewInt(58)
	mod := new(big.Int)
	var out []byte
	for num.Sign() > 0 {
		num.DivMod(num, radix, mod)
		out = append(out, base58Alphabet[mod.Int64()])
	}
	for i := 0; i < zeros; i++ {
		out = append(out, base58Alphabet[0])
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return string(out)
}

// buildAdata assembles the "additional authenticated data": the cipher
// parameters plus the paste's display settings. It is sent in the clear but
// authenticated by GCM, so it must be serialised identically for encryption and
// decryption.
func buildAdata(iv, salt []byte, format string, openDiscussion, burnAfterReading int) []interface{} {
	return []interface{}{
		[]interface{}{
			base64.StdEncoding.EncodeToString(iv),
			base64.StdEncoding.EncodeToString(salt),
			pbkdf2Iterations,
			pbkdf2KeySizeBit,
			gcmTagSizeBit,
			"aes",
			"gcm",
			"zlib",
		},
		format,
		openDiscussion,
		burnAfterReading,
	}
}

// pastePayload is the request body PrivateBin's create endpoint expects.
type pastePayload struct {
	V      int                    `json:"v"`
	ADdata []interface{}          `json:"adata"`
	CT     string                 `json:"ct"`
	Meta   map[string]interface{} `json:"meta"`
}

// encryptedPaste bundles what the caller needs: the body to POST and the key to
// put in the fragment (which never leaves this machine except in that URL).
type encryptedPaste struct {
	Payload   pastePayload
	MasterKey string // base58, for the URL fragment
}

// encryptPaste compresses, encrypts, and packages text for the create endpoint.
func encryptPaste(text, format string, burn bool) (encryptedPaste, error) {
	var out encryptedPaste

	master := make([]byte, masterKeyBytes)
	iv := make([]byte, ivBytes)
	salt := make([]byte, saltBytes)
	for _, buf := range [][]byte{master, iv, salt} {
		if _, err := rand.Read(buf); err != nil {
			return out, fmt.Errorf("cannot generate random material: %w", err)
		}
	}

	// The plaintext is a JSON document, so attachments and future fields have
	// somewhere to live; today it carries just the paste body.
	blob, err := json.Marshal(map[string]string{"paste": text})
	if err != nil {
		return out, err
	}
	// PrivateBin labels this "zlib" in adata but the bytes are RAW DEFLATE
	// with no zlib header or adler32 trailer. compress/zlib would add both,
	// and the frontend reports the resulting inflate failure as "waiting on
	// user to provide a password", which is easy to misread as a key problem.
	var compressed bytes.Buffer
	zw, err := flate.NewWriter(&compressed, flate.DefaultCompression)
	if err != nil {
		return out, err
	}
	if _, err := zw.Write(blob); err != nil {
		return out, err
	}
	if err := zw.Close(); err != nil {
		return out, err
	}

	// No paste password, so the passphrase is the master key alone.
	key := pbkdf2.Key(master, salt, pbkdf2Iterations, pbkdf2KeySizeBit/8, sha256.New)

	burnFlag := 0
	if burn {
		burnFlag = 1
	}
	adata := buildAdata(iv, salt, format, 0, burnFlag)
	aad, err := json.Marshal(adata)
	if err != nil {
		return out, err
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return out, err
	}
	gcm, err := cipher.NewGCMWithNonceSize(block, ivBytes)
	if err != nil {
		return out, err
	}
	ct := gcm.Seal(nil, iv, compressed.Bytes(), aad)

	out.Payload = pastePayload{
		V:      2,
		ADdata: adata,
		CT:     base64.StdEncoding.EncodeToString(ct),
	}
	out.MasterKey = base58Encode(master)
	return out, nil
}

// decryptPasteForTest reverses encryptPaste. It exists so the round-trip test
// can prove the ciphertext is actually decryptable with the key we hand out and
// that the authenticated adata matches byte-for-byte.
func decryptPasteForTest(e encryptedPaste) (string, error) {
	plain, err := decryptRawForTest(e)
	if err != nil {
		return "", err
	}
	zr := flate.NewReader(bytes.NewReader(plain))
	defer zr.Close()
	raw, err := io.ReadAll(zr)
	if err != nil {
		return "", err
	}
	var doc struct {
		Paste string `json:"paste"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return "", err
	}
	return doc.Paste, nil
}

// decryptRawForTest returns the still-compressed plaintext, so a test can
// assert on the compression framing itself.
func decryptRawForTest(e encryptedPaste) ([]byte, error) {
	master, err := base58Decode(e.MasterKey)
	if err != nil {
		return nil, err
	}
	spec, ok := e.Payload.ADdata[0].([]interface{})
	if !ok {
		return nil, errors.New("malformed adata")
	}
	iv, err := base64.StdEncoding.DecodeString(spec[0].(string))
	if err != nil {
		return nil, err
	}
	salt, err := base64.StdEncoding.DecodeString(spec[1].(string))
	if err != nil {
		return nil, err
	}
	key := pbkdf2.Key(master, salt, pbkdf2Iterations, pbkdf2KeySizeBit/8, sha256.New)
	aad, err := json.Marshal(e.Payload.ADdata)
	if err != nil {
		return nil, err
	}
	ct, err := base64.StdEncoding.DecodeString(e.Payload.CT)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCMWithNonceSize(block, len(iv))
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, iv, ct, aad)
	if err != nil {
		return nil, fmt.Errorf("GCM open failed (adata mismatch or bad key): %w", err)
	}
	return plain, nil
}

func base58Decode(s string) ([]byte, error) {
	num := big.NewInt(0)
	radix := big.NewInt(58)
	for _, r := range s {
		idx := strings.IndexRune(base58Alphabet, r)
		if idx < 0 {
			return nil, fmt.Errorf("invalid base58 character %q", r)
		}
		num.Add(num.Mul(num, radix), big.NewInt(int64(idx)))
	}
	decoded := num.Bytes()
	zeros := 0
	for zeros < len(s) && s[zeros] == base58Alphabet[0] {
		zeros++
	}
	return append(make([]byte, zeros), decoded...), nil
}

// pasteURL assembles the shareable link. The key sits in the fragment, which
// browsers do not transmit — the server can never read the paste.
func pasteURL(base, id, key string, burn bool) string {
	frag := key
	if burn {
		// `#-` makes the frontend confirm before spending the single read.
		frag = "-" + key
	}
	return strings.TrimSuffix(base, "/") + "/?" + id + "#" + frag
}

// errWaking marks a response that means "the service has not finished waking",
// as opposed to a genuine rejection.
var errWaking = errors.New("service still waking")

func isWakingError(err error) bool { return errors.Is(err, errWaking) }

// parsePasteResponse reads the create endpoint's reply. A non-JSON body means
// we reached Sablier's loading page rather than the app, which is retryable.
func parsePasteResponse(body string) (id, deleteToken string, err error) {
	var r struct {
		Status      int    `json:"status"`
		ID          string `json:"id"`
		URL         string `json:"url"`
		DeleteToken string `json:"deletetoken"`
		Message     string `json:"message"`
	}
	if e := json.Unmarshal([]byte(strings.TrimSpace(body)), &r); e != nil {
		return "", "", fmt.Errorf("%w: got a non-JSON response (%s)", errWaking, truncateForError(body))
	}
	if r.Status != 0 {
		msg := r.Message
		if msg == "" {
			msg = fmt.Sprintf("status %d", r.Status)
		}
		return "", "", fmt.Errorf("PrivateBin rejected the paste: %s", msg)
	}
	if r.ID == "" {
		return "", "", fmt.Errorf("PrivateBin returned no paste id")
	}
	return r.ID, r.DeleteToken, nil
}

// pasteExpiryOptions are the values PrivateBin accepts. Validated locally so a
// typo fails immediately instead of silently becoming the server default.
var pasteExpiryOptions = []string{"5min", "10min", "1hour", "1day", "1week", "1month", "1year", "never"}

type pasteArgs struct {
	path   string
	expire string
	format string
	burn   bool
	force  bool
}

func parsePasteArgs(args []string) (pasteArgs, error) {
	out := pasteArgs{expire: "1week", format: "plaintext"}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--burn":
			out.burn = true
		case a == "--force":
			out.force = true
		case a == "--expire" && i+1 < len(args):
			out.expire = args[i+1]
			i++
		case a == "--format" && i+1 < len(args):
			out.format = args[i+1]
			i++
		case a == "-" && out.path == "":
			out.path = "-"
		case !strings.HasPrefix(a, "-") && out.path == "":
			out.path = a
		}
	}
	if out.path == "" {
		return out, fmt.Errorf("usage: homelab paste <file|-> [--expire %s] [--burn] [--format plaintext|markdown|syntaxhighlighting] [--force]",
			strings.Join(pasteExpiryOptions, "|"))
	}
	if !contains(pasteExpiryOptions, out.expire) {
		return out, fmt.Errorf("--expire must be one of: %s", strings.Join(pasteExpiryOptions, ", "))
	}
	if !contains([]string{"plaintext", "markdown", "syntaxhighlighting"}, out.format) {
		return out, fmt.Errorf("--format must be plaintext, markdown, or syntaxhighlighting")
	}
	return out, nil
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
