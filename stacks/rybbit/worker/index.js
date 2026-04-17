// Rybbit analytics injection via Cloudflare Worker
// Injects the rybbit tracking script into HTML responses using HTMLRewriter.
// Deployed as a route-based worker on *.viktorbarzin.me/*

// Site ID mapping: hostname → rybbit site ID
// These were previously injected via Traefik's rewrite-body plugin (broken on v3.6).
const SITE_IDS = {
  "viktorbarzin.me": "da853a2438d0",
  "www.viktorbarzin.me": "da853a2438d0",
  "actualbudget.viktorbarzin.me": "3e6b6b68088a",
  "crowdsec.viktorbarzin.me": "d09137795ccc",
  "cyberchef.viktorbarzin.me": "7c460afc68c4",
  "dawarich.viktorbarzin.me": "0abfd409f2fb",
  "pma.viktorbarzin.me": "942c76b8bd4d",
  "pgadmin.viktorbarzin.me": "7cef78e30485",
  "audiobookshelf.viktorbarzin.me": "17a5c7fbb077",
  "calibre.viktorbarzin.me": "ce5f8aed6bbb",
  "stacks.viktorbarzin.me": "b38fda4285df",
  "f1.viktorbarzin.me": "7e69786f66d5",
  "frigate.viktorbarzin.me": "0d4044069ff5",
  "highlights-immich.viktorbarzin.me": "602167601c6b",
  "immich.viktorbarzin.me": "35eedb7a3d2b",
  "mail.viktorbarzin.me": "082f164faa7d",
  "navidrome.viktorbarzin.me": "8a3844ff75ba",
  "networking-toolbox.viktorbarzin.me": "50e38577e41c",
  "nextcloud.viktorbarzin.me": "5a3bfe59a3fe",
  "ollama.viktorbarzin.me": "e73bebea399f",
  "paperless-ngx.viktorbarzin.me": "be6d140cbed8",
  "privatebin.viktorbarzin.me": "3ae810b0476d",
  "wrongmove.viktorbarzin.me": "edee05de453d",
  "rybbit.viktorbarzin.me": "3c476801a777",
  "send.viktorbarzin.me": "c1b8f8aa831b",
  "stirling-pdf.viktorbarzin.me": "a55ac54ec749",
  "uptime-kuma.viktorbarzin.me": "8fef77b1f7fe",
  "vaultwarden.viktorbarzin.me": "b8fc85e18683",
};

// Default site ID for any proxied host not in the map above.
// Set to null to skip injection for unmapped hosts.
const DEFAULT_SITE_ID = null;

class HeadInjector {
  constructor(siteId) {
    this.siteId = siteId;
  }

  element(element) {
    element.prepend(
      `<script src="https://rybbit.viktorbarzin.me/api/script.js" data-site-id="${this.siteId}" defer></script>`,
      { html: true }
    );
  }
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const hostname = url.hostname;

    // Look up site ID for this hostname
    const siteId = SITE_IDS[hostname] || DEFAULT_SITE_ID;

    // Fetch the origin response
    const response = await fetch(request);

    // Only inject into HTML responses that have a site ID
    const contentType = response.headers.get("content-type") || "";
    if (!siteId || !contentType.includes("text/html")) {
      return response;
    }

    // Use HTMLRewriter to inject the script before </head>
    return new HTMLRewriter()
      .on("head", new HeadInjector(siteId))
      .transform(response);
  },
};
