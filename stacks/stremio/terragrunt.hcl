include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# stremio — self-hosted Stremio streaming server with NVENC transcoding (infra#80).
# Custom image (ghcr.io/viktorbarzin/stremio-nvenc): tsaridas layout re-based to
# glibc + jellyfin-ffmpeg 4.4.1-4 NVENC, bundled web client + nginx basic-auth
# (auth ALSO on the /{infohash} torrent path — no open torrent gateway). Public,
# NON-PROXIED (bypasses Cloudflare's CDN-video ToS); the app's basic-auth is the
# gate. One time-slice of the shared T4 + a reserved 1500 MiB gpumem seat that
# fits under the 14000 advertised budget once portal-stt is decommissioned.
# Torrenting kept enabled as a backup (Sofia egress). HITL: agent drafts;
# operator presence-claims the T4 + applies from the MAIN checkout (git-crypt).
