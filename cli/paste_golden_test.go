package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// This is a real paste created through the PrivateBin web UI on the deployed
// instance (privatebin/nginx-fpm-alpine:2.0.6) on 2026-08-15, captured verbatim
// from the server. Decrypting it with our own code proves we agree with
// PrivateBin's actual JavaScript — not merely with ourselves.
//
// A round-trip test cannot catch a shared misunderstanding: our first
// implementation round-tripped perfectly while producing pastes the frontend
// could not read, because it wrote zlib-wrapped DEFLATE where PrivateBin writes
// raw DEFLATE (the adata field is labelled "zlib" either way). This vector is
// what makes that class of mistake fail in CI instead of in the browser.
const (
	goldenPasteKey58 = "4KRWtGCXTBYTDC3EefTM7B5CxtFjvGcHRr7aiJnow9Jz"
	goldenPasteADdata = `[["y/CKDt99aGLYMgI1cqeRzw==","Q1iCv7OyUpg=",100000,256,128,"aes","gcm","zlib"],"plaintext",0,0]`
	goldenPasteCT     = "CxUqMp6Q2Bm4eANC5X9SLwZJVs4c5XkyDQH1hRGnZACf80tR4VzpnlxLsO6dxYYqRRhc4CF5u77NqfJevKAqipFl1IQalfrhqIpwby8="
	goldenPasteText   = "REFERENCE PASTE from the real UI\nsecond line\n"
)

func TestDecryptsAPasteMadeByPrivateBinItself(t *testing.T) {
	var adata []interface{}
	if err := json.Unmarshal([]byte(goldenPasteADdata), &adata); err != nil {
		t.Fatalf("golden adata: %v", err)
	}
	got, err := decryptPasteForTest(encryptedPaste{
		Payload:   pastePayload{V: 2, ADdata: adata, CT: goldenPasteCT},
		MasterKey: goldenPasteKey58,
	})
	if err != nil {
		t.Fatalf("cannot decrypt a paste PrivateBin created — our format has diverged from the deployed frontend: %v", err)
	}
	if got != goldenPasteText {
		t.Errorf("decrypted %q, want %q", got, goldenPasteText)
	}
}

// Guards the specific mistake above from the other direction: what we produce
// must not carry a zlib header, or the frontend cannot inflate it.
func TestOurCiphertextUsesRawDeflateNotZlib(t *testing.T) {
	enc, err := encryptPaste("hello", "plaintext", false)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := decryptRawForTest(enc)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	// A zlib stream starts with 0x78 and a valid 2-byte header checksum; raw
	// DEFLATE does not.
	if len(plain) >= 2 && plain[0] == 0x78 && (uint16(plain[0])<<8|uint16(plain[1]))%31 == 0 {
		t.Errorf("compressed payload looks like zlib (starts %#x %#x); PrivateBin expects raw DEFLATE", plain[0], plain[1])
	}
}

func TestGoldenAdataMatchesWhatWeGenerate(t *testing.T) {
	// The cipher spec we emit must be identical, field for field, to what the
	// real frontend emitted (only the random iv/salt differ).
	var golden []interface{}
	if err := json.Unmarshal([]byte(goldenPasteADdata), &golden); err != nil {
		t.Fatal(err)
	}
	gspec := golden[0].([]interface{})

	ours := buildAdata([]byte("0123456789abcdef"), []byte("saltsalt"), "plaintext", 0, 0)
	raw, _ := json.Marshal(ours)
	var back []interface{}
	json.Unmarshal(raw, &back)
	ospec := back[0].([]interface{})

	for i := 2; i < len(gspec); i++ { // skip iv+salt, which are random
		if gspec[i] != ospec[i] {
			t.Errorf("cipher spec field %d: ours=%v, PrivateBin's=%v", i, ospec[i], gspec[i])
		}
	}
	for i := 1; i < len(golden); i++ {
		if golden[i] != back[i] {
			t.Errorf("adata field %d: ours=%v, PrivateBin's=%v", i, back[i], golden[i])
		}
	}
	if !strings.Contains(string(raw), `"aes"`) {
		t.Errorf("sanity: adata should name the cipher: %s", raw)
	}
}
