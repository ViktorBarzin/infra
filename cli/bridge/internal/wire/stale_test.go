package wire

import "testing"

// Chrome never auto-updates an extension loaded with "Load unpacked", which
// is how this is installed. So a fixed server and a stale extension is the
// normal state after any extension change, not an edge case.
//
// On 2026-09-21 that cost two debugging cycles: a browser running the
// pre-fix build looked identical to one running the fix, because both said
// 0.1.0, and the only way to tell was to download the served bundle and grep
// it. Whoever is looking has to be told, in words, without asking.
func TestExtensionStaleness(t *testing.T) {
	for _, tc := range []struct {
		name       string
		ext, serve string
		wantStale  bool
	}{
		{"same version is fine", "0.1.1", "0.1.1", false},
		{"older extension is stale", "0.1.0", "0.1.1", true},
		{"much older is stale", "0.1.0", "0.2.0", true},
		// A newer extension than the server is a developer mid-iteration.
		// It is not the failure this exists to catch, and nagging about it
		// would train people to ignore the warning that matters.
		{"newer extension is not stale", "0.2.0", "0.1.1", false},
		// Unknown on either side must stay quiet. A false alarm here sends
		// someone reinstalling a build that was never the problem.
		{"unknown extension version", "", "0.1.1", false},
		{"unknown server version", "0.1.0", "", false},
		{"dev server build", "0.1.0", "0.0.0-dev", false},
		{"unparseable", "banana", "0.1.1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExtensionIsStale(tc.ext, tc.serve); got != tc.wantStale {
				t.Errorf("ExtensionIsStale(%q, %q) = %v, want %v", tc.ext, tc.serve, got, tc.wantStale)
			}
		})
	}
}
