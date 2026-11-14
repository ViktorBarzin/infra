# === learn pod — pages.viktorbarzin.me (+ the plans.viktorbarzin.me redirect) ===
#
# Started 2026-07-09 as the Authentik-gated viewer for the /teach skill's
# learning workspaces: a Caddy container serving a git tree, kept fresh by a
# git-sync sidecar (30s poll, SSH deploy key). Viktor explicitly preferred
# everything codified in Terraform over the v1 devvm-Caddy live serving
# ("devvm is not supposed to host prod services"); the trade-off — content
# appears on PUSH (~30-60s), not on file-write — is accepted. Decision +
# history: viktor/learn docs/adr/0002 (supersedes 0001, the devvm design).
# Since 2026-07-10 the same pod also serves the published HTML pages
# (infra#72), and since 2026-07-27 that is ALL it serves: learn.viktorbarzin.me
# moved to the separate 'learning' app stack, so the learn/ tree has no route
# here. The pod name is historical.
#
# Content source (2026-11-03): the PRIVATE Forgejo repo viktor/pages, whose
# root is the site (one dir per user, shared/, assets/, tools/). Until then it
# was the pages/ subdir of the GitHub monorepo ViktorBarzin/monorepo, which was
# dissolved that day; viktor/pages carries its history. Forgejo only, with no
# GitHub push-mirror, by Viktor's decision. The /teach lessons went to
# viktor/learn, which nothing here syncs.
#
# Access is GROUP-GATED at the edge, then per-identity in the Caddyfile:
# Authentik admits "Home Server Admins" (vbarzin, emil.barzin) plus "Pages
# Readers" (see module "ingress_pages"), and each admitted identity gets its own
# static try_files list. The two admins read every space (2026-08-09, so a link
# handed to the other one resolves instead of 404ing). A Pages Reader reads only
# their own space — added 2026-09-03 for Anca, whose prep page lives in
# pages/anca/ and who should not inherit the admins' 100+ published pages.
# Valia (2026-10-11) reads her own pages/valia/ plus pages/shared/.
# pages/<user>/ is an authoring namespace, not an access boundary; unlisted
# identities still get 403. Before that date each identity was pinned to its
# own directory, which meant a page URL handed to the other person resolved
# against THEIR directory and 404'd — sharing a link simply did not work.
# In-cluster callers could spoof the header by curling the Service directly —
# same trust class as ttyd/t3-dispatch, recorded in the ADR.
#
# Deploy key: read-only on Forgejo viktor/pages ("learn-viewer git-sync
# (read-only)"), private key + Forgejo's SSH host key in Vault secret/learn
# (forgejo_ssh, forgejo_known_hosts) → ExternalSecret → Secret learn-git-creds,
# keys ssh + known_hosts (git-sync's default paths under /etc/git-secret). The
# old ssh / known_hosts properties held the GitHub monorepo key.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "learn" {
  metadata {
    name = "learn"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# SSH deploy key for git-sync: Vault secret/learn → Secret learn-git-creds
resource "kubernetes_manifest" "git_creds_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "learn-git-creds"
      namespace = kubernetes_namespace.learn.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "learn-git-creds"
      }
      data = [
        {
          secretKey = "ssh"
          remoteRef = {
            key      = "learn"
            property = "forgejo_ssh"
          }
        },
        {
          secretKey = "known_hosts"
          remoteRef = {
            key      = "learn"
            property = "forgejo_known_hosts"
          }
        },
      ]
    }
  }
}

resource "kubernetes_config_map" "caddyfile" {
  metadata {
    name      = "learn-caddyfile"
    namespace = kubernetes_namespace.learn.metadata[0].name
  }
  data = {
    Caddyfile          = <<-EOT
      {
      	admin off
      	auto_https off
      }
      # --- pages sandbox (ADR-0042, docs/plans/2026-11-12-pages-rich-content-design.md) ---
      # Every page on pages.viktorbarzin.me is two documents on one URL: the
      # SHELL (a browser navigation, Sec-Fetch-Dest: document) is the fixed file
      # pages-shell.html from this ConfigMap, the only document that runs with
      # the site's real origin; it frames the same URL, and that RAW response
      # (Sec-Fetch-Dest: iframe, or anything else) is the page from git with a
      # CSP sandbox, so page scripts get an opaque origin: no cookies, no
      # storage, no reading other Spaces. The pages ingresses skip Traefik's
      # shared csp-headers middleware (skip_default_csp), because Traefik
      # REPLACES a backend's CSP; these snippets set frame-ancestors instead.
      # Keep the sandbox flags in step with SANDBOX in pages-shell.html.
      (pages_frame_ancestors) {
      	header Content-Security-Policy "frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
      }
      # Takes an optional matcher: Caddy runs a matcher-less `header` AFTER the
      # matched ones, so the legacy override below only works if this one is
      # matched too.
      (pages_sandbox_private) {
      	header {args[0]} Content-Security-Policy "sandbox allow-scripts allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox allow-downloads allow-pointer-lock allow-top-navigation-by-user-activation; frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
      	# Cloudflare caches images, scripts and media by URL whatever the
      	# cookie, so a signed-in 200 would be served to the next visitor at that
      	# edge without Authentik ever seeing them (found 2026-11-12). private
      	# keeps every shared cache out; no-cache makes browsers revalidate.
      	header Cache-Control "private, no-cache"
      	header Vary Sec-Fetch-Dest
      	header X-Content-Type-Options nosniff
      }
      # /c/ and /p/ are readable without signing in, so they also allow any
      # page to frame or fetch them (CORS *), which nested frames and a
      # Bundle's own fetch("data.json") from the opaque origin need.
      (pages_sandbox_public) {
      	header Content-Security-Policy "sandbox allow-scripts allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox allow-downloads allow-pointer-lock allow-top-navigation-by-user-activation"
      	header Access-Control-Allow-Origin *
      	# Not cached at Cloudflare either: an unshared link or a rotated Bundle
      	# URL must stop serving its files at once, not when the edge copy ages out.
      	header Cache-Control "private, no-cache"
      	header Vary Sec-Fetch-Dest
      	header X-Content-Type-Options nosniff
      	header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noai, noimageai"
      	header Referrer-Policy no-referrer
      }
      (pages_shell) {
      	root * /etc/caddy
      	rewrite * /pages-shell.html
      	header Content-Security-Policy "frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me; object-src 'none'; base-uri 'none'; script-src 'self' 'unsafe-inline'; frame-src 'self'"
      	header Cache-Control no-store
      	header Vary Sec-Fetch-Dest
      	header X-Content-Type-Options nosniff
      	file_server
      }
      # Pages written before the sandbox that load files from a SIBLING
      # directory, or call localStorage unguarded. A single page has no Bundle
      # URL, so in the sandbox their images would go out without the sign-in
      # cookie and fail. All are Viktor's own, in pages/wizard; they keep the
      # old serving (no shell, no sandbox) until republished as Bundles.
      (pages_legacy_paths) {
      	path /2026-09-11-live-display-upscale.html /wizard/2026-09-11-live-display-upscale.html
      	path /2026-09-24-orchestrator-bake-off.html /wizard/2026-09-24-orchestrator-bake-off.html
      	path /2026-09-24-text-composer-redesign.html /wizard/2026-09-24-text-composer-redesign.html
      	path /2026-09-27-text-view-t3-pass.html /wizard/2026-09-27-text-view-t3-pass.html
      	path /paladin-sources.html /wizard/paladin-sources.html /paladin-video.html /wizard/paladin-video.html
      	# Trip clips (97 MB): kept off the no-login Bundle URLs on purpose.
      	path /reels /reels/* /wizard/reels /wizard/reels/*
      }
      :8080 {
      	# An encoded slash (%2F) has no business in a pages URL, and it is how
      	# a request could reach a path Traefik never routed: Traefik resolves
      	# ".." but passes %2F, Caddy matches the cleaned path. Refused outright.
      	@pages_encoded_slash {
      		host pages.viktorbarzin.me
      		expression {http.request.uri}.matches("(?i)%2f|%5c")
      	}
      	handle @pages_encoded_slash {
      		respond "Bad Request" 400
      	}
      	# host/auth-agnostic health endpoint so the caddy readiness probe
      	# stays green now that the learn.* handler was removed (repointed).
      	handle /healthz {
      		respond "ok" 200
      	}
      	# pages.viktorbarzin.me/prep/ — PUBLIC, no login (2026-09-03). Viktor asked
      	# for a link anyone can open and edit, for Anca's interview prep, so this
      	# path is carved out of the gated host by its own ingress
      	# (module "ingress_prep" below, auth = "public"). Requests arrive bound to
      	# Authentik's `guest` user, so this handle deliberately does NOT look at
      	# X-Authentik-Username: it must serve an identity no other handle matches.
      	# It sits FIRST so nothing downstream can shadow it, and its root is
      	# pinned to pages/anca so the rest of the tree stays unreachable from a
      	# public request. The page's shared state is a separate service on
      	# /prep/api (module "ingress_prep_api"); everything under /prep that is
      	# not a real file falls back to the page itself.
      	@pages_prep {
      		host pages.viktorbarzin.me
      		path /prep /prep/*
      	}
      	handle @pages_prep {
      		root * /repo/src/current/anca
      		uri strip_prefix /prep
      		try_files {path} {path}index.html /index.html
      		file_server
      	}
      	# pages.viktorbarzin.me/pe-summit-trip/ — PUBLIC, no login (2026-10-10).
      	# Viktor's trip planner for the October PE Summit road trip, opened by a
      	# travel companion without an Authentik account. Same shape as /prep: its
      	# own ingress (module "ingress_pe_summit_trip", auth = "none"), matched on
      	# path rather than identity, placed before the identity handles, root
      	# pinned to the one directory so nothing else in pages/ is reachable.
      	# The bare path redirects to the trailing slash because the page loads its
      	# photos by relative path.
      	@pages_pe_summit_trip {
      		host pages.viktorbarzin.me
      		path /pe-summit-trip /pe-summit-trip/*
      	}
      	handle @pages_pe_summit_trip {
      		redir /pe-summit-trip /pe-summit-trip/ 308
      		root * /repo/src/current/wizard/pe-summit-trip
      		uri strip_prefix /pe-summit-trip
      		try_files {path} {path}index.html /index.html
      		file_server
      	}
      	# pages.viktorbarzin.me/homelab/ — PUBLIC, no login (2026-10-20). The
      	# homelab showcase (docs/plans/2026-10-20-homelab-showcase-design.md),
      	# a static bundle the daily .woodpecker/showcase.yml run publishes to
      	# pages/showcase/homelab through pages-publish /publish-bundle. Same
      	# carve-out shape as /pe-summit-trip, root pinned to the one directory.
      	@pages_homelab {
      		host pages.viktorbarzin.me
      		path /homelab /homelab/*
      	}
      	handle @pages_homelab {
      		redir /homelab /homelab/ 308
      		root * /repo/src/current/showcase/homelab
      		uri strip_prefix /homelab
      		try_files {path} {path}index.html /index.html
      		file_server
      	}
      	# pages.viktorbarzin.me/vietnam/ — PUBLIC, no login (2026-10-25). Viktor's
      	# Vietnam travel guide, sent to a friend without an Authentik account. Same
      	# carve-out shape as /pe-summit-trip, root pinned to the one directory.
      	@pages_vietnam {
      		host pages.viktorbarzin.me
      		path /vietnam /vietnam/*
      	}
      	handle @pages_vietnam {
      		redir /vietnam /vietnam/ 308
      		root * /repo/src/current/wizard/vietnam
      		uri strip_prefix /vietnam
      		try_files {path} {path}index.html /index.html
      		file_server
      	}
      	# pages.viktorbarzin.me: per-user page spaces (<user>/) + a shared area
      	# (shared/), served from the git-synced viktor/pages tree, whose root is
      	# the site. The comments below say pages/<user>/ for the same dirs.
      	# Every page is readable by every identity that clears the Authentik gate
      	# (allowed-groups "Home Server Admins" — see the ingress below); the
      	# per-user split is a NAMESPACE for authoring, not an access boundary
      	# (Viktor, 2026-08-09). Each identity still maps to STATIC try_files
      	# candidates — the untrusted X-Authentik-Username header is never
      	# interpolated into a path, so a spoofed value can't drive traversal.
      	# Own space is tried FIRST so existing bare-filename URLs keep resolving
      	# to their author's page; the other spaces are the fallback, which is what
      	# makes a handed-over link work instead of 404ing. /assets/* is the shared
      	# stylesheet+mermaid. plans.viktorbarzin.me 301-redirects here (renamed
      	# from plans/ 2026-07-26). learn.viktorbarzin.me is served by the separate 'learning' app stack
      	# (PWA; repointed 2026-07-27).
      	# In-cluster callers can still spoof the header (same trust class as
      	# ttyd, per ADR) — accepted for this 3-user homelab (Viktor, 2026-07-26).
      	# /assets/ is PUBLIC since 2026-11-12 (module "ingress_pages_assets"):
      	# a sandboxed page's requests carry no sign-in cookie, so the stylesheet
      	# and the vendored libraries (assets/VERSIONS.md) must load without one.
      	# Module scripts and fonts from an opaque origin are CORS requests, hence *.
      	# Nothing private lives here; the publish service never writes assets/.
      	@pages_assets {
      		host pages.viktorbarzin.me
      		path /assets/*
      	}
      	handle @pages_assets {
      		import pages_frame_ancestors
      		header Access-Control-Allow-Origin *
      		header Cache-Control "public, max-age=3600"
      		header X-Content-Type-Options nosniff
      		root * /repo/src/current
      		file_server
      	}
      	# Watched by job blackbox-pages-public (stacks/monitoring) and gatus on
      	# mx2 through a canary Bundle that must never be republished.
      	# /c/<cap>/ — the Bundle URL (module "ingress_pages_bundles", no auth).
      	# c/<cap> in viktor/pages is a symlink to <space>/<bundle>, written by
      	# pages-publish and rotated on every publish of that Bundle. Readable by
      	# anyone holding the 128-bit cap: that is the accepted trade-off in the
      	# design doc. Only a 32-hex first segment is served and dotfiles (the
      	# marker naming the cap) never are.
      	@pages_cap {
      		host pages.viktorbarzin.me
      		path /c/*
      	}
      	handle @pages_cap {
      		@pages_cap_bad not path_regexp ^/c/[0-9a-f]{32}/
      		respond @pages_cap_bad "Not Found" 404
      		import pages_sandbox_public
      		root * /repo/src/current
      		file_server {
      			hide .*
      		}
      	}
      	# /p/<token>/ — a public link (module "ingress_pages_public", no auth,
      	# no Turnstile). p/<token> is a symlink into a Space, written by
      	# pages-publish /share and removed by /unshare. Same shell and sandbox as
      	# a private page, so Rybbit counts it the same way.
      	@pages_public {
      		host pages.viktorbarzin.me
      		path /p/*
      	}
      	handle @pages_public {
      		@pages_public_bad not path_regexp ^/p/[0-9a-f]{32}(/|$)
      		respond @pages_public_bad "Not Found" 404
      		@pages_public_bare path_regexp ^/p/[0-9a-f]{32}$
      		redir @pages_public_bare {path}/ 308
      		@pages_public_shell {
      			method GET
      			header Sec-Fetch-Dest document
      			path */ *.html
      			not query raw=*
      			not query print-pdf=*
      		}
      		handle @pages_public_shell {
      			import pages_shell
      		}
      		handle {
      			import pages_sandbox_public
      			root * /repo/src/current
      			file_server {
      				hide .*
      			}
      		}
      	}
      	# A revoked or mistyped public link: say so in the frame rather than
      	# leave the shell blank. Bundle URLs get the same short answer.
      	handle_errors 404 {
      		@pages_public_gone {
      			host pages.viktorbarzin.me
      			path /p/* /c/*
      		}
      		handle @pages_public_gone {
      			header Content-Type "text/html; charset=utf-8"
      			respond "<!doctype html><meta charset=utf-8><title>Link not available</title><body style='font:17px/1.6 system-ui,sans-serif;padding:2rem;color:#52514e'><p>This link is not available. It may have been revoked by the person who shared it.</p></body>" 404
      		}
      	}
      	@plans_redirect host plans.viktorbarzin.me
      	handle @plans_redirect {
      		redir https://pages.viktorbarzin.me{uri} permanent
      	}
      	# The shell for every other browser navigation to a page. It is the same
      	# fixed file for everyone and holds nothing private, so it is served
      	# before the identity handles; the frame's request then goes through
      	# them as before. ?raw and reveal's ?print-pdf skip it, which is how a
      	# page is printed (browsers print only the visible part of a frame).
      	@pages_shell {
      		host pages.viktorbarzin.me
      		method GET
      		header Sec-Fetch-Dest document
      		path / */ *.html
      		not path /assets/* /_t/* /outpost.goauthentik.io/* /tools/* /.*
      		not query raw=*
      		not query print-pdf=*
      		not {
      			import pages_legacy_paths
      		}
      		# Anca's space is one hand-written app (the Citadel prep page, also
      		# public at /prep/) that keeps state in localStorage and registers a
      		# service worker, both of which the sandbox forbids. Her handle
      		# below serves it as before.
      		not header_regexp X-Authentik-Username ^ancaelena98(@.*)?$
      	}
      	handle @pages_shell {
      		import pages_shell
      	}
      	@pages_shared {
      		host pages.viktorbarzin.me
      		path /shared/*
      		header_regexp X-Authentik-Username ^(vbarzin|emil\.barzin|valentinakolevabarzina)(@.*)?$
      	}
      	handle @pages_shared {
      		import pages_sandbox_private *
      		root * /repo/src/current
      		file_server
      	}
      	# tools/ is the renderer's source, not published content — the
      	# try_files fallthrough below would otherwise expose it at /tools/*.
      	# Top-level dotfiles too: the document root is now the git-sync worktree
      	# itself, whose .git file names the clone's path.
      	@pages_tools {
      		host pages.viktorbarzin.me
      		path /tools/* /.*
      	}
      	handle @pages_tools {
      		respond "Not Found" 404
      	}
      	@pages_wizard {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^vbarzin(@.*)?$
      	}
      	handle @pages_wizard {
      		@pages_wizard_legacy {
      			import pages_legacy_paths
      		}
      		@pages_wizard_sandboxed {
      			not {
      				import pages_legacy_paths
      			}
      		}
      		import pages_sandbox_private @pages_wizard_sandboxed
      		header @pages_wizard_legacy Content-Security-Policy "frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
      		root * /repo/src/current
      		try_files /wizard{path} /wizard{path}index.html /emo{path} /emo{path}index.html /shared{path} /shared{path}index.html
      		file_server
      	}
      	# Anca (ancaelena98@gmail.com, display name "Anca Milea" — verified against
      	# the live Authentik user list 2026-09-03; the OTHER account matching
      	# "anca", anca.r.cristian10@gmail.com, last logged in Jul 2025 and is not
      	# the one to use). Added 2026-09-03 so she can read her Citadel interview
      	# prep at pages.viktorbarzin.me. Her try_files list is DELIBERATELY just
      	# her own space: unlike the two admin handles above she gets no fallback
      	# into /wizard, /emo or /shared, so admitting her to the host does not
      	# hand her every page published here.
      	@pages_anca {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^ancaelena98(@.*)?$
      	}
      	handle @pages_anca {
      		# Her document ROOT is her own directory, not the pages tree with a
      		# /anca prefix in try_files. That distinction is the whole control:
      		# Caddy's try_files falls back to the UNCHANGED path when no candidate
      		# exists, so a prefixed try_files over the whole tree still served
      		# /wizard/<page>.html and a 42KB /wizard/ index to her (measured
      		# 2026-09-03 against the live pod before this was pinned). Pinning the
      		# root means a path outside her space cannot resolve at all. The two
      		# admin handles above keep the prefixed form because they are supposed
      		# to read every space, so the same fallback is harmless there.
      		# No sandbox: see the Anca exception on @pages_shell.
      		import pages_frame_ancestors
      		header Cache-Control "private, no-cache"
      		root * /repo/src/current/anca
      		try_files {path} {path}index.html
      		file_server
      	}
      	# Valia (valentinakolevabarzina@gmail.com, verified against the live
      	# Authentik user list 2026-10-11). A Pages Reader like Anca, but with two
      	# spaces: her own pages/valia/ first, then pages/shared/, which is where
      	# pages written for the family in Sofia live (/shared/* URLs reach her
      	# through @pages_shared above). Each space gets its OWN pinned root, the
      	# same control as Anca's handle, rather than one root over the pages tree
      	# with prefixed try_files. The prefixed form leaked twice when tested
      	# against caddy 2.10.2 before landing: with no match, try_files leaves the
      	# path unchanged, and {path} is decoded but not cleaned, so
      	# /%2e%2e/wizard/<page>.html turned /valia{path} into a path outside her
      	# space. A pinned root is joined safely, so neither case resolves.
      	@pages_valia {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^valentinakolevabarzina(@.*)?$
      	}
      	handle @pages_valia {
      		import pages_sandbox_private *
      		@pages_valia_own file {
      			root /repo/src/current/valia
      			try_files {path} {path}index.html
      		}
      		handle @pages_valia_own {
      			root * /repo/src/current/valia
      			rewrite {file_match.relative}
      			file_server
      		}
      		handle {
      			root * /repo/src/current/shared
      			try_files {path} {path}index.html =404
      			file_server
      		}
      	}
      	@pages_emo {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^emil\.barzin(@.*)?$
      	}
      	handle @pages_emo {
      		@pages_emo_legacy {
      			import pages_legacy_paths
      		}
      		@pages_emo_sandboxed {
      			not {
      				import pages_legacy_paths
      			}
      		}
      		import pages_sandbox_private @pages_emo_sandboxed
      		header @pages_emo_legacy Content-Security-Policy "frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
      		root * /repo/src/current
      		try_files /emo{path} /emo{path}index.html /wizard{path} /wizard{path}index.html /shared{path} /shared{path}index.html
      		file_server
      	}
      	handle {
      		import pages_frame_ancestors
      		respond "Forbidden" 403
      	}
      }
    EOT
    "pages-shell.html" = file("${path.module}/pages-shell.html")
  }
}

resource "kubernetes_deployment" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "learn"
      # DELIBERATELY NOT sablier-enrolled (un-enrolled 2026-07-12, Viktor):
      # this pod serves plans.viktorbarzin.me — the plan-review surface he
      # opens on the go — and learn.viktorbarzin.me; both must load instantly,
      # so it stays always-on despite passing the ADR-0022 eligibility
      # checklist. ~40Mi idle; the cold re-clone wait isn't worth it here.
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "learn"
      }
    }
    template {
      metadata {
        labels = {
          app = "learn"
        }
        annotations = {
          # Roll the pod when the Caddyfile changes (config mounts don't restart pods)
          "viktorbarzin.me/caddyfile-sha" = sha1(join("", [kubernetes_config_map.caddyfile.data["Caddyfile"], kubernetes_config_map.caddyfile.data["pages-shell.html"]]))
        }
      }
      spec {
        security_context {
          # git-sync SSH key readability (official git-sync docs/ssh.md pattern)
          fs_group = 65533
        }

        container {
          name  = "git-sync"
          image = "registry.k8s.io/git-sync/git-sync:v4.8.0"
          args = [
            # In-cluster Service name, so a sync depends on neither the
            # git.viktorbarzin.me record nor the MetalLB address behind it.
            # forgejo_known_hosts pins Forgejo's host key under this name.
            "--repo=git@forgejo-ssh.forgejo.svc.cluster.local:viktor/pages.git",
            "--ref=master",
            "--period=30s",
            "--depth=1",
            # --root must be a SUBDIR of the volume (git-sync README)
            "--root=/repo/src",
            "--link=current",
          ]
          security_context {
            run_as_user = 65533
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
          }
          volume_mount {
            name       = "git-secret"
            mount_path = "/etc/git-secret"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              # 256Mi since 2026-11-10: a git fetch of viktor/pages reached 119 MB on
              # its own and the 128Mi cgroup OOM-killed git and git-sync (KernelOOMKiller).
              # 512Mi since 2026-11-12: Bundles put images and clips in the repo
              # (up to 25 MiB per publish), so each fetch can carry more.
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "caddy"
          image = "docker.io/library/caddy:2.11.9-alpine"
          port {
            container_port = 8080
            name           = "http"
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
            read_only  = true
          }
          volume_mount {
            name       = "caddyfile"
            mount_path = "/etc/caddy"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            # /healthz is host/auth-agnostic (Caddyfile handler), so readiness
            # stays green after the learn.* handler was removed (2026-07-27)
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "repo"
          empty_dir {}
        }
        volume {
          name = "git-secret"
          secret {
            secret_name = "learn-git-creds"
            # 0400 — SSH refuses laxer keys; fsGroup 65533 grants git-sync read
            default_mode = "0400"
          }
        }
        volume {
          name = "caddyfile"
          config_map {
            name = kubernetes_config_map.caddyfile.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }

  depends_on = [kubernetes_manifest.git_creds_external_secret]
}

resource "kubernetes_service" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "learn"
    }
  }

  spec {
    selector = {
      app = "learn"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}


# pages.viktorbarzin.me — per-user private page spaces + a shared area (the
# viktor/pages repo; the tree was plans/ until 2026-07-26 and lived in the
# monorepo until 2026-11-03; rendered + pushed by publish-page / pages-publish).
# Served by the SAME learn pod; the Caddyfile above routes by Host and per-user
# by X-Authentik-Username. The homepage tile lives here.
module "ingress_pages" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "pages"
  service_name    = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  # "Home Users" (stacks/authentik/home-users.tf) gets past Authentik here, and
  # the Caddyfile above still decides WHICH space each identity sees: a Home
  # User with no handle of their own falls through to the 403. The host has its
  # own forward_single application listed in
  # stacks/authentik/forward-auth-apps.json, which must name the same groups
  # (scripts/check-allowed-groups.py enforces that before plan).
  allowed_groups = ["Home Server Admins", "Home Users"]
  # Caddy sets the CSP per path (the sandbox on raw pages, frame-ancestors on
  # the shell and assets); Traefik's shared CSP middleware would replace it.
  skip_default_csp = true
  # No Uptime Kuma [External] monitor (Viktor, 2026-11-12): it followed the
  # redirect to the Authentik login page, so it watched Authentik, not pages.
  # The pages paths are watched by job blackbox-pages-public (stacks/monitoring)
  # and by gatus on mx2 through Cloudflare (stacks/backup-mx).
  external_monitor = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Pages"
    "gethomepage.dev/description"  = "Published pages — plans/specs/designs (git-backed)"
    "gethomepage.dev/icon"         = "mdi-file-document-multiple"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = "app=learn"
  }
}

# plans.viktorbarzin.me — kept only so Traefik still routes the OLD hostname to
# the pod, where the Caddyfile 301-redirects it to pages.* (name stays "plans"
# so this is an in-place annotation change, not a destroy/recreate). No homepage
# tile — it's a redirect, not a destination. Retire once old links age out.
module "ingress_plans" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "plans"
  homepage_group  = "Productivity"
  service_name    = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}


# === pages.viktorbarzin.me/prep/ — the public, editable prep page ===
#
# Anca's Citadel interview prep needed a link that opens with no login, keeps
# edits anyone makes, and still works on a plane (Viktor, 2026-09-03). The page
# itself is static and served by the Caddy handle above; these resources are the
# state behind it.
#
# Why a small service rather than something already running: `homelab how` and
# the service catalog have no public read/write JSON store, the artifact runtime
# turns organisation-internal the moment it declares a database, and Nextcloud's
# WebDAV sends no CORS headers so a browser cannot reach it cross-origin. Same
# origin was the deciding factor — /prep/api sits on pages.viktorbarzin.me, so
# the page needs no CORS at all when online, and the downloaded offline copy
# (Origin: null) is the only caller that relies on the wildcard the service does
# send.
#
# The write path is UNAUTHENTICATED on purpose. That was Viktor's call in
# exchange for a link a non-technical reader can just open. What makes it
# survivable: every write snapshots the previous document and 50 are kept, so a
# wipe is one copy away from undone; bodies, key counts and value lengths are
# capped; and writes are rate limited per address. See app/prep_sync.py.

resource "kubernetes_persistent_volume_claim" "prep_sync" {
  metadata {
    name      = "prep-sync-data"
    namespace = kubernetes_namespace.learn.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "nfs-pve"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  # The document is a few KB. NFS rather than local-path so a node move does not
  # lose it, and 1Gi because that is the smallest the class bothers with.
  wait_until_bound = false
}

resource "kubernetes_config_map" "prep_sync_code" {
  metadata {
    name      = "prep-sync-code"
    namespace = kubernetes_namespace.learn.metadata[0].name
  }
  data = {
    "prep_sync.py" = file("${path.module}/app/prep_sync.py")
  }
}

resource "kubernetes_deployment" "prep_sync" {
  metadata {
    name      = "prep-sync"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "prep-sync"
    }
  }
  spec {
    replicas = 1
    # One writer at a time. The service serialises writes on an in-process lock,
    # so a second replica could interleave two read-modify-write cycles on the
    # same NFS file and lose one side's merge.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "prep-sync"
      }
    }
    template {
      metadata {
        labels = {
          app = "prep-sync"
        }
        annotations = {
          # Restart when the code changes; the ConfigMap mount alone would not.
          "checksum/code" = sha256(file("${path.module}/app/prep_sync.py"))
        }
      }
      spec {
        container {
          name    = "prep-sync"
          image   = "library/python:3.15.2-slim"
          command = ["python", "/app/prep_sync.py"]
          port {
            container_port = 8080
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          volume_mount {
            name       = "code"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          security_context {
            # NFS export squashes, and the proven pattern on this server
            # (stacks/poison-fountain) writes as uid 0.
            run_as_user = 0
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }
        }
        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map.prep_sync_code.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prep_sync.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }
}

resource "kubernetes_service" "prep_sync" {
  metadata {
    name      = "prep-sync"
    namespace = kubernetes_namespace.learn.metadata[0].name
  }
  spec {
    selector = {
      app = "prep-sync"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# The public page. Same HOST as the gated ingress above, carved out by path:
# Traefik picks the longest matching rule, and the explicit priority makes that
# ordering a decision rather than a coincidence. dns_type = "none" because
# pages.viktorbarzin.me already has its record, and a second one would fight
# over it. anti_ai_scraping is forced ON: this is a public page and there is no
# reason to let it be harvested.
#
# auth = "none", not "public", and the difference is not cosmetic. "public"
# attaches Authentik's public forward-auth, which is supposed to auto-bind a
# guest but currently 302s an anonymous visitor to a login page instead —
# measured 2026-09-03 against resume.viktorbarzin.me and echo.viktorbarzin.me,
# both of which show the same login screen, so this is estate-wide and not
# specific to this stack (see the open authentik embedded-outpost issue). "none"
# attaches no auth middleware at all, which is what "anyone with the link opens
# it" actually requires, and it is also the only posture the downloaded offline
# copy can sync from: that page runs on file:// with no cookie for this domain,
# so any redirect to Authentik would fail its fetch.
module "ingress_prep" {
  source         = "../../modules/kubernetes/ingress_factory"
  name           = "prep"
  homepage_group = "Productivity"
  host           = "pages"
  # Turnstile gate on this public page (2026-10-16). A carve-out path, so the
  # factory leaves it off by default; the page is HTML people open in a browser.
  turnstile       = true
  ingress_path    = ["/prep"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": the page anyone with the link should open with no login. Not
  # "public", which currently 302s anonymous visitors to a login page (measured
  # estate-wide 2026-09-03), and not a posture the offline file:// copy can sync from.
  auth              = "none"
  dns_type          = "none"
  external_monitor  = false
  anti_ai_scraping  = true
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    # A carve-out on a host that already has its dashboard tile, so it stays
    # out of the catalog rather than listing pages twice.
    "gethomepage.dev/enabled" = "false"
  }
}

# pages.viktorbarzin.me/pe-summit-trip/ — Viktor's trip planner, public with no
# login so a travel companion without an account can open it (2026-10-10). Same
# carve-out pattern as ingress_prep above, including auth = "none" rather than
# "public" for the reason given there.
module "ingress_pe_summit_trip" {
  source         = "../../modules/kubernetes/ingress_factory"
  name           = "pe-summit-trip"
  homepage_group = "Productivity"
  host           = "pages"
  # Turnstile gate on this public page (2026-10-16). A carve-out path, so the
  # factory leaves it off by default; the page is HTML people open in a browser.
  turnstile       = true
  ingress_path    = ["/pe-summit-trip"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a static trip page meant for people without an account; nothing else on pages is reachable through it (Caddy pins the root).
  auth              = "none"
  dns_type          = "none"
  external_monitor  = false
  anti_ai_scraping  = true
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
}

# pages.viktorbarzin.me/vietnam/ — a Vietnam travel guide, public with no login
# so a friend without an account can open it from a shared link (2026-10-25).
# Same carve-out pattern as ingress_pe_summit_trip. Link-preview bots get through
# the shared Anubis via the vietnam-link-previews rule in stacks/turnstile-gate.
module "ingress_vietnam_guide" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "vietnam-guide"
  host            = "pages"
  turnstile       = true
  ingress_path    = ["/vietnam"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a static page meant for people without an account; nothing else on pages is reachable through it (Caddy pins the root).
  auth              = "none"
  dns_type          = "none"
  external_monitor  = false
  anti_ai_scraping  = true
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
}

# pages.viktorbarzin.me/homelab/ — the homelab showcase, public with no login so
# other homelabbers can open it from a shared link (2026-10-20, ADR-0037). Same
# carve-out pattern as ingress_pe_summit_trip. Link-preview bots that the shared
# Anubis would otherwise challenge are let through by the
# showcase-link-previews rule in stacks/turnstile-gate.
module "ingress_homelab_showcase" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "homelab-showcase"
  host            = "pages"
  turnstile       = true
  ingress_path    = ["/homelab"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a static page meant for people without an account; nothing else on pages is reachable through it (Caddy pins the root).
  auth              = "none"
  dns_type          = "none"
  external_monitor  = false
  anti_ai_scraping  = true
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
}

# The state API. Separate module call because these paths need a different
# backend, and separate settings: no anti-AI middleware, which inspects the user
# agent and has no business on a JSON endpoint, and a body cap in front of the
# service's own. auth = "none" for the same two reasons as the page above, and
# one more: a cookie dance in front of a JSON endpoint breaks every non-browser
# caller, which is the case stacks/insta2spotify already warns about.
module "ingress_prep_api" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "prep-api"
  homepage_group  = "Productivity"
  host            = "pages"
  ingress_path    = ["/prep/api"]
  service_name    = kubernetes_service.prep_sync.metadata[0].name
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a JSON state endpoint for that page, called from the page and
  # from its downloaded offline copy. A cookie dance in front of it breaks every
  # non-browser caller, which stacks/insta2spotify already warns about.
  auth             = "none"
  dns_type         = "none"
  external_monitor = false
  anti_ai_scraping = false
  max_body_size    = "512k"
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "200"
    # An API path behind the page, not something anyone browses to.
    "gethomepage.dev/enabled" = "false"
  }
}


# === pages rich content (2026-11-12, ADR-0042) ===
# docs/plans/2026-11-12-pages-rich-content-design.md. Three public carve-outs
# on the gated host, each matched by Caddy on PATH before any identity handle,
# with root pinned to its own tree:
#   /assets/  the stylesheet and vendored libraries. A sandboxed page's
#             requests carry no sign-in cookie, so these must load without one.
#   /c/<cap>/ the Bundle URL: a Bundle's files, behind a 128-bit random cap.
#   /p/<tok>/ a public link to a page or Bundle, until it is unshared.
# Paths end in "/" because ingress_factory paths are string prefixes: "/c"
# would also take /composer/ and /camera-specs/ out from behind Authentik.

# A client can send its own X-Authentik-* headers. Behind forward auth Traefik
# overwrites them from the outpost; on these auth-free routes nothing does, so
# strip them before Caddy, whose identity handles trust X-Authentik-Username.
# The Caddy path handles are terminal, so this is the second line of defence.
resource "kubernetes_manifest" "strip_authentik_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip-authentik-headers"
      namespace = kubernetes_namespace.learn.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Authentik-Username"     = ""
          "X-Authentik-Groups"       = ""
          "X-Authentik-Email"        = ""
          "X-Authentik-Name"         = ""
          "X-Authentik-Uid"          = ""
          "X-Authentik-Entitlements" = ""
        }
      }
    }
  }
}

module "ingress_pages_assets" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "pages-assets"
  host            = "pages"
  ingress_path    = ["/assets/"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a stylesheet and public open-source libraries, loaded by sandboxed pages whose requests carry no sign-in cookie.
  auth = "none"
  # Subresources: a browser never asks for an HTML page here, and a challenge would only break the page that loads them.
  turnstile         = false
  dns_type          = "none"
  external_monitor  = false
  anti_ai_scraping  = true
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
  depends_on = [kubernetes_manifest.strip_authentik_headers]
}

module "ingress_pages_bundles" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "pages-bundles"
  host            = "pages"
  ingress_path    = ["/c/"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a Bundle's files, loaded inside a sandboxed frame whose requests carry no sign-in cookie; the 128-bit cap in the path is the gate.
  auth = "none"
  # Loaded inside a frame and by fetch(); a challenge page there would only break the Bundle.
  turnstile         = false
  search_noindex    = true
  anti_ai_scraping  = true
  skip_default_csp  = true
  dns_type          = "none"
  external_monitor  = false
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
  depends_on = [kubernetes_manifest.strip_authentik_headers]
}

module "ingress_pages_public" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "pages-public"
  host            = "pages"
  ingress_path    = ["/p/"]
  service_name    = "learn"
  port            = 80
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # auth = "none": a public link anyone holding it may open (decision 7); the 128-bit token in the path is the gate.
  auth = "none"
  # Decision 7 of the design: no Turnstile on public links, so a link opens for whoever it was sent to.
  turnstile         = false
  search_noindex    = true
  anti_ai_scraping  = true
  skip_default_csp  = true
  dns_type          = "none"
  external_monitor  = false
  extra_middlewares = ["learn-strip-authentik-headers@kubernetescrd"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.priority" = "150"
    "gethomepage.dev/enabled"                       = "false"
  }
  depends_on = [kubernetes_manifest.strip_authentik_headers]
}
