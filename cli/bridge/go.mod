// TEMPORARY VENDOR. This is a copy of the client and wire packages from
// /home/wizard/code/browser-bridge at commit 75efb557, carried here because
// github.com/ViktorBarzin/browser-bridge has no remote yet and none of the
// three builders of this CLI can fetch it: the hourly rebuild in
// t3-provision-users.sh, scripts/workstation/setup-devvm.sh, and the GHA
// Docker build, whose context is cli/ alone. A relative replace pointing
// outside cli/ breaks the last two.
//
// Publishing that module deletes this directory and the two lines it needs in
// ../go.mod. Nothing else changes: the import path the CLI uses here is the
// real one.
//
// The requires of the upstream go.mod are the server's (redis, miniredis).
// client and internal/wire import nothing but the standard library, so this
// file lists none.
module github.com/ViktorBarzin/browser-bridge

go 1.21
