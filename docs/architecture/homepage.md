# Homepage Dashboard (home.viktorbarzin.me)

## Overview

The cluster uses [Homepage](https://gethomepage.dev/) as a service dashboard at `home.viktorbarzin.me`. It auto-discovers services via Kubernetes ingress annotations — no manual service list to maintain.

## Architecture

```
Browser → Cloudflare → Traefik → nginx cache proxy → Homepage (port 3000)
```

- **Homepage** (ghcr.io/gethomepage/homepage:v1.10.1) runs in namespace `homepage` with RBAC enabled for K8s API access
- **nginx cache proxy** sits in front, caching `/api/` responses for 24h with stale-while-revalidate (prevents Homepage from hitting K8s API on every page load)
- **Ingress** at `home.viktorbarzin.me` routes through the cache proxy

Stack: `stacks/homepage/main.tf`

## Service Auto-Discovery

Homepage discovers services from **ingress annotations** across all namespaces. The `ingress_factory` module automatically adds these annotations to every ingress it creates.

### How It Works

1. Homepage's ServiceAccount has cluster-wide RBAC to read ingresses
2. On startup (and periodically), it scans all ingresses for `gethomepage.dev/*` annotations
3. Services appear grouped and ordered by their annotation values

### Annotations

The `ingress_factory` module (`modules/kubernetes/ingress_factory/main.tf`) sets these defaults on every ingress:

| Annotation | Default Value | Purpose |
|------------|---------------|---------|
| `gethomepage.dev/enabled` | `"true"` | Show on dashboard (set `homepage_enabled = false` to hide) |
| `gethomepage.dev/name` | Derived from ingress `name` (hyphens → spaces) | Display name |
| `gethomepage.dev/group` | Auto-detected from namespace (see mapping below) | Dashboard section |
| `gethomepage.dev/href` | `https://<host>.viktorbarzin.me` | Click-through URL |
| `gethomepage.dev/icon` | `<name>.png` | Icon (from [Dashboard Icons](https://github.com/walkxcode/dashboard-icons)) |

### Overriding Defaults

Pass `extra_annotations` in the `ingress_factory` module call to override any default:

```hcl
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "my-app"
  name            = "my-app"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/name"         = "My Custom Name"
    "gethomepage.dev/description"  = "What this service does"
    "gethomepage.dev/icon"         = "si-spotify"        # Simple Icons prefix
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""                  # Show pod status widget
  }
}
```

To hide a service from the dashboard:

```hcl
module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  # ...
  homepage_enabled = false
}
```

### Namespace → Group Mapping

The `ingress_factory` module auto-maps namespaces to dashboard groups:

| Namespace | Group |
|-----------|-------|
| monitoring, prometheus, technitium, traefik, metallb-system, dbaas, mailserver | Infrastructure |
| authentik, crowdsec | Identity & Security |
| woodpecker, forgejo | Development & CI |
| immich, servarr, navidrome | Media & Entertainment |
| frigate, home-assistant, reverse-proxy | Smart Home |
| ollama | AI & Data |
| nextcloud | Productivity |
| n8n, changedetection | Automation |
| finance | Finance & Personal |
| homepage | Core Platform |
| *(everything else)* | Other |

Override with `homepage_group` variable or `gethomepage.dev/group` annotation.

### Dashboard Layout

Groups are configured in `stacks/homepage/values.yaml` under `config.settings.layout`. Each group has a `style` (row) and `columns` count. To add a new group, add it to the layout config and apply.

### Adding a New Service

No action needed — just use the `ingress_factory` module. The service will appear automatically on the next Homepage refresh cycle. To customize:

1. Set `extra_annotations` with `gethomepage.dev/*` keys for custom name, description, icon
2. Set `homepage_group` variable if the namespace auto-mapping doesn't fit
3. Use `"gethomepage.dev/pod-selector" = ""` to show pod health status

### Icon Sources

Homepage supports multiple icon formats:
- **Dashboard Icons**: `<name>.png` (e.g., `grafana.png`) — [browse available icons](https://github.com/walkxcode/dashboard-icons)
- **Simple Icons**: `si-<name>` (e.g., `si-spotify`) — [browse at simpleicons.org](https://simpleicons.org)
- **Material Design**: `mdi-<name>` (e.g., `mdi-home`)
- **URL**: Full URL to any image

### Caching

The nginx cache proxy caches Homepage's `/api/` responses for 24h with background refresh. This means:
- New services appear within seconds (Homepage refreshes its K8s scan periodically)
- Widget data (pod status, resource usage) is cached but refreshes in the background
- If Homepage restarts, cached data serves until it's back
