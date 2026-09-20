package wire

import "strings"

// Identifier prefixes. Every id carries one so a misrouted id fails with a
// clear message instead of a 404.
const (
	PrefixBrowser = "b_"
	PrefixSession = "s_"
	PrefixAction  = "a_"
	PrefixBlob    = "bl_"
	PrefixTab     = "t_"
)

// Alphabets.
const (
	// alphabetBase64URL is what the server's random ids are encoded with.
	alphabetBase64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	// TabHandleAlphabet is lowercase because an agent types a handle into a
	// shell. PairCodeAlphabet is uppercase because a human reads a code off a
	// screen. Both drop the characters people misread.
	TabHandleAlphabet = "23456789abcdefghjkmnpqrstuvwxyz"
	PairCodeAlphabet  = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
)

// Lengths, in characters, of the random part of each id.
const (
	idBodyLen        = 22
	BrowserKeyLen    = 43
	TabHandleBodyLen = 8
	PairCodeLen      = 6
)

// IDKind names the kind of object an identifier points at.
type IDKind string

const (
	KindBrowser IDKind = "browser"
	KindSession IDKind = "session"
	KindAction  IDKind = "action"
	KindBlob    IDKind = "blob"
	KindTab     IDKind = "tab"
	KindUnknown IDKind = "unknown"
)

func hasBody(s, prefix string, bodyLen int, alphabet string) bool {
	if !strings.HasPrefix(s, prefix) {
		return false
	}
	body := s[len(prefix):]
	if len(body) != bodyLen {
		return false
	}
	for _, r := range body {
		if !strings.ContainsRune(alphabet, r) {
			return false
		}
	}
	return true
}

// ValidBrowserID reports whether s is a well-formed browserId.
func ValidBrowserID(s string) bool {
	return hasBody(s, PrefixBrowser, idBodyLen, alphabetBase64URL)
}

// ValidSessionID reports whether s is a well-formed sessionId.
func ValidSessionID(s string) bool {
	return hasBody(s, PrefixSession, idBodyLen, alphabetBase64URL)
}

// ValidActionID reports whether s is a well-formed actionId.
func ValidActionID(s string) bool {
	return hasBody(s, PrefixAction, idBodyLen, alphabetBase64URL)
}

// ValidBlobID reports whether s is a well-formed blobId.
func ValidBlobID(s string) bool {
	return hasBody(s, PrefixBlob, idBodyLen, alphabetBase64URL)
}

// ValidTabHandle reports whether s is a well-formed tab handle. Handles are
// minted by the extension and are scoped to one browser, so a handle that
// looks valid may still be unknown to the browser it is sent to.
func ValidTabHandle(s string) bool {
	return hasBody(s, PrefixTab, TabHandleBodyLen, TabHandleAlphabet)
}

// ValidBrowserKey reports whether s is a well-formed browserKey. The key
// carries no prefix, because it is a secret rather than a reference.
func ValidBrowserKey(s string) bool {
	return hasBody(s, "", BrowserKeyLen, alphabetBase64URL)
}

// ValidPairCode reports whether s is a well-formed pair code.
func ValidPairCode(s string) bool {
	return hasBody(s, "", PairCodeLen, PairCodeAlphabet)
}

// IDKindOf names what kind of object an identifier points at, or KindUnknown
// when it is not a well-formed id of any kind. The blob prefix is checked
// before the browser prefix, because "bl_" also starts with "b".
func IDKindOf(s string) IDKind {
	switch {
	case ValidBlobID(s):
		return KindBlob
	case ValidBrowserID(s):
		return KindBrowser
	case ValidSessionID(s):
		return KindSession
	case ValidActionID(s):
		return KindAction
	case ValidTabHandle(s):
		return KindTab
	default:
		return KindUnknown
	}
}
