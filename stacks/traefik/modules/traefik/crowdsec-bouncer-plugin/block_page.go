package crowdsec_bouncer_plugin

import (
	"net"
	"net/http"
	"strings"
	"time"
)

// The two kinds of block page. pageBanned: the client address holds a ban
// decision. pageRequestBlocked: AppSec refused this one request.
const (
	pageBanned = iota
	pageRequestBlocked
)

// wantsHTML reports whether the client is a browser asking for a page. Only an
// explicit text/html in Accept counts; "*/*" alone is what curl and most HTTP
// libraries send.
func wantsHTML(req *http.Request) bool {
	return strings.Contains(strings.ToLower(req.Header.Get("Accept")), "text/html")
}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;", "'", "&#39;")

// blockPage renders the page. It is one self-contained document: a banned
// client's request for a stylesheet, script or image would be blocked too, so
// the page loads nothing. It never names the scenario or rule that fired.
func blockPage(kind int, ip net.IP, host string, now time.Time) string {
	title, lead, advice := "Your address is blocked",
		"The security filter on this site has blocked requests from your network address. "+
			"This happens when a device on your network sends many failed or unusual requests, "+
			"for example an app that keeps using an expired login.",
		"Most blocks lift by themselves within 4 hours. If you think this is a mistake, "+
			"send the details below to Viktor."
	if kind == pageRequestBlocked {
		title, lead, advice = "This request was blocked",
			"The security filter on this site blocked this request because it looked like an attack. "+
				"Your address is not blocked.",
			"Go back and continue. If this keeps happening, send the details below to Viktor."
	}
	addr := "unknown"
	if ip != nil {
		addr = ip.String()
	}
	esc := htmlEscaper.Replace
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>` + esc(title) + `</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--muted:#5d6675;--line:#e2e5ea;--accent:#c2410c}
@media (prefers-color-scheme:dark){:root{--bg:#12151b;--card:#1b2029;--fg:#e8ebf0;--muted:#9aa3b2;--line:#2b313c;--accent:#fb923c}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:520px;width:100%;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:32px}
.badge{display:inline-block;font-size:13px;font-weight:600;letter-spacing:.04em;color:var(--accent);margin-bottom:8px}
h1{font-size:24px;line-height:1.25;margin:0 0 14px}
p{margin:0 0 14px}
.muted{color:var(--muted)}
dl{display:grid;grid-template-columns:auto 1fr;gap:6px 16px;margin:22px 0 0;padding-top:18px;border-top:1px solid var(--line);font-size:14px}
dt{color:var(--muted)}
dd{margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
</style>
</head>
<body>
<main>
<div class="badge">403 FORBIDDEN</div>
<h1>` + esc(title) + `</h1>
<p>` + esc(lead) + `</p>
<p class="muted">` + esc(advice) + `</p>
<dl>
<dt>Address</dt><dd>` + esc(addr) + `</dd>
<dt>Site</dt><dd>` + esc(host) + `</dd>
<dt>Time</dt><dd>` + esc(now.UTC().Format("2006-01-02 15:04:05")) + ` UTC</dd>
</dl>
</main>
</body>
</html>
`
}
