package wire

import (
	"strconv"
	"strings"
)

// ExtensionIsStale reports whether an extension build is older than the
// server's.
//
// This exists because Chrome never auto-updates an extension installed with
// "Load unpacked", which is how this one is installed: Chrome refuses to
// force-install an off-store extension on a Mac that is not MDM-enrolled or
// cloud-managed, so the signed CRX and its update manifest go unused. Every
// extension fix therefore leaves a person running the old code until they
// re-download and reload, with nothing on screen saying so.
//
// It answers false whenever it cannot be sure. A newer extension than the
// server is someone iterating, and an unknown or unparseable version on
// either side is not evidence of anything. A warning that cries wolf is
// worse than none, because the one time it matters it will be ignored.
func ExtensionIsStale(extension, server string) bool {
	ext, ok := parseSemver(extension)
	if !ok {
		return false
	}
	srv, ok := parseSemver(server)
	if !ok {
		return false
	}
	for i := range ext {
		if ext[i] != srv[i] {
			return ext[i] < srv[i]
		}
	}
	return false
}

// parseSemver reads a bare MAJOR.MINOR.PATCH. Anything carrying a pre-release
// or build suffix, such as the 0.0.0-dev a local `go build` stamps, is
// rejected: a developer running an unversioned server must not be told their
// extension is out of date.
func parseSemver(v string) ([3]int, bool) {
	var out [3]int
	v = strings.TrimSpace(v)
	if v == "" {
		return out, false
	}
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}
