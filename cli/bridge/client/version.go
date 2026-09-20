package client

// Version is the browser-bridge release this client came from. One vX.Y.Z
// tag drives the server image, the extension's manifest version and this
// constant, and the build refuses to publish when the three disagree.
//
// `homelab browser bridge` reports it, which is how a stale vendored copy of
// this package becomes visible rather than mysterious.
const Version = "0.1.0"
