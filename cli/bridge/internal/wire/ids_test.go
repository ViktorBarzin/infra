package wire

import "testing"

func TestValidators(t *testing.T) {
	cases := []struct {
		name string
		fn   func(string) bool
		in   string
		want bool
	}{
		{"browser ok", ValidBrowserID, "b_AAAAAAAAAAAAAAAAAAAAAA", true},
		{"browser with url-safe chars", ValidBrowserID, "b_-_AAAAAAAAAAAAAAAAAAAA", true},
		{"browser wrong prefix", ValidBrowserID, "s_AAAAAAAAAAAAAAAAAAAAAA", false},
		{"browser too short", ValidBrowserID, "b_AAAAAAAAAAAAAAAAAAAAA", false},
		{"browser too long", ValidBrowserID, "b_AAAAAAAAAAAAAAAAAAAAAAA", false},
		{"browser bad char", ValidBrowserID, "b_AAAAAAAAAAAAAAAAAAAA+A", false},
		{"browser empty", ValidBrowserID, "", false},
		{"session ok", ValidSessionID, "s_QmFzZTY0dXJsSWRIZXJlAA", true},
		{"session wrong prefix", ValidSessionID, "a_QmFzZTY0dXJsSWRIZXJlAA", false},
		{"action ok", ValidActionID, "a_QmFzZTY0dXJsSWRIZXJlAA", true},
		{"action wrong prefix", ValidActionID, "b_QmFzZTY0dXJsSWRIZXJlAA", false},
		{"blob ok", ValidBlobID, "bl_QmFzZTY0dXJsSWRIZXJlAA", true},
		{"blob wrong prefix", ValidBlobID, "b_QmFzZTY0dXJsSWRIZXJlAAA", false},
		{"tab ok", ValidTabHandle, "t_4k2p9xqa", true},
		{"tab rejects lookalike zero", ValidTabHandle, "t_4k2p9xq0", false},
		{"tab rejects lookalike one", ValidTabHandle, "t_4k2p9xq1", false},
		{"tab rejects lookalike ell", ValidTabHandle, "t_4k2p9xql", false},
		{"tab rejects uppercase", ValidTabHandle, "t_4K2p9xqa", false},
		{"tab too short", ValidTabHandle, "t_4k2p9xq", false},
		{"tab no prefix", ValidTabHandle, "4k2p9xqa", false},
		{"key ok", ValidBrowserKey, "0123456789012345678901234567890123456789012", true},
		{"key too short", ValidBrowserKey, "012345678901234567890123456789012345678901", false},
		{"key has prefix", ValidBrowserKey, "b_0123456789012345678901234567890123456789", false},
		{"pair ok", ValidPairCode, "K7M2QX", true},
		{"pair rejects lowercase", ValidPairCode, "k7m2qx", false},
		{"pair rejects lookalike oh", ValidPairCode, "K7M2QO", false},
		{"pair wrong length", ValidPairCode, "K7M2Q", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.fn(c.in); got != c.want {
				t.Fatalf("%q: got %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestIDKindOf(t *testing.T) {
	cases := []struct {
		in   string
		want IDKind
	}{
		{"b_AAAAAAAAAAAAAAAAAAAAAA", KindBrowser},
		{"s_AAAAAAAAAAAAAAAAAAAAAA", KindSession},
		{"a_AAAAAAAAAAAAAAAAAAAAAA", KindAction},
		{"bl_AAAAAAAAAAAAAAAAAAAAAA", KindBlob},
		{"t_4k2p9xqa", KindTab},
		{"nonsense", KindUnknown},
		{"", KindUnknown},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			if got := IDKindOf(c.in); got != c.want {
				t.Fatalf("IDKindOf(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
