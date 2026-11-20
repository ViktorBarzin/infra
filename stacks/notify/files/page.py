"""The notify pipe's settings page: https://notify.viktorbarzin.me.

Each person sets where to reach them (phone, email), what to get (rule groups
and single alerts) and what to do with Notifications sent to them by name.
Saving writes their Authentik attributes (subs.py); Authentik then pushes the
new Channels to apprise-api by itself (stacks/authentik/notify.tf).

  GET  /            every alert, by rule group, with a search box
  GET  /a/<alert>   one alert: the link in Slack posts and in emails
  POST /save        any subset of the fields; the rest stay as they were

Who is asking comes from X-authentik-username, set by Traefik's forward auth.
The listener is reachable inside the cluster too, so a request must also carry
the X-Notify-Ingress-Proof value that only the ingress adds (stacks/notify,
ingress.tf). A save must come from this page's own origin.
"""

import hmac
import html
import logging
import re
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import subs

log = logging.getLogger("notify-page")

LABELS = {"off": "Off", "push": "Phone", "email": "Email"}
INSTANCES = (("none", "None"), ("ha-sofia", "ha-sofia"), ("ha-london", "ha-london"))
TEMPLATE = re.compile(r"\{\{.*?\}\}")


def esc(value) -> str:
    return html.escape(str(value), quote=True)


class Ids:
    def __init__(self):
        self.n = 0

    def __call__(self) -> str:
        self.n += 1
        return "r%d" % self.n


def seg(ids, name, current, inherit=False) -> str:
    """Off / Phone / Email as radio buttons; `inherit` adds a hidden 'from
    group' radio that stays checked until the person picks a value."""
    out = ['<span class="seg">']
    if inherit:
        out.append('<input type="radio" name="%s" value="inherit"%s class="inh" hidden>' % (esc(name), " checked" if current == "inherit" else ""))
    for value in ("off", "push", "email"):
        rid = ids()
        out.append(
            '<input type="radio" name="%s" value="%s"%s id="%s"><label for="%s" class="v-%s">%s</label>'
            % (esc(name), value, " checked" if current == value else "", rid, rid, value, LABELS[value])
        )
    out.append("</span>")
    return "".join(out)


def summary_text(alert) -> str:
    return TEMPLATE.sub("…", alert.get("summary") or "")


STYLE = """
:root{--bg:#fff;--fg:#1a1a1a;--muted:#666;--line:#e3e3e3;--card:#f7f7f7;--accent:#2f6fed;--accent-fg:#fff;--ghost:#dbe6fb;--bad:#b3261e}
@media (prefers-color-scheme:dark){:root{--bg:#121212;--fg:#eee;--muted:#9a9a9a;--line:#2c2c2c;--card:#1b1b1b;--accent:#4b82f0;--ghost:#25324d;--bad:#f2b8b5}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,sans-serif}
main{max-width:760px;margin:0 auto;padding:16px 16px 96px}
h1{font-size:22px;margin:8px 0 4px}h2{font-size:17px;margin:28px 0 8px}
.muted{color:var(--muted);font-size:13px}.banner{padding:10px 14px;border-radius:8px;margin:12px 0;background:var(--ghost)}
.banner.bad{background:transparent;border:1px solid var(--bad);color:var(--bad)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:4px 14px;margin:8px 0}
.field{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;justify-content:space-between;padding:10px 0;border-top:1px solid var(--line)}
.field:first-child{border-top:none}.field label.t{font-weight:500}
input[type=text],input[type=email],select{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);min-width:220px}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden;flex:none}
.seg input{position:absolute;opacity:0;pointer-events:none}
.seg label{padding:4px 10px;font-size:13px;cursor:pointer;user-select:none}
.seg label+input+label{border-left:1px solid var(--line)}
.seg input:checked+label{background:var(--accent);color:var(--accent-fg)}
.row[data-inh=off] .v-off,.row[data-inh=push] .v-push,.row[data-inh=email] .v-email{background:var(--ghost)}
.ghead{display:flex;gap:8px;align-items:center;justify-content:space-between;padding:10px 0 4px}
.ghead b{font-size:15px}
details{padding:0 0 8px}summary{cursor:pointer;color:var(--muted);font-size:13px}
.row{display:flex;gap:10px;align-items:center;justify-content:space-between;padding:7px 0 7px 14px;border-top:1px solid var(--line)}
.row .name{font-size:14px;word-break:break-word}.row .sum{color:var(--muted);font-size:12px}
.from{font-size:11px;color:var(--muted);margin-left:6px}
.group{border-top:1px solid var(--line)}.group:first-of-type{border-top:none}
#q{width:100%;margin:4px 0 8px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--bg);border-top:1px solid var(--line);padding:10px 16px;text-align:center}
button{font:inherit;background:var(--accent);color:var(--accent-fg);border:0;border-radius:8px;padding:8px 22px;cursor:pointer}
a{color:var(--accent)}
"""

SCRIPT = """
function refresh(){
  document.querySelectorAll('.group').forEach(function(g){
    var c=g.querySelector('.ghead input:checked'), gv=c?c.value:'off';
    g.querySelectorAll('.row').forEach(function(r){
      var inh=r.querySelector('input.inh').checked;
      r.dataset.inh=inh?gv:'';
      r.querySelector('.from').hidden=!inh||gv==='off';
    });
  });
}
document.addEventListener('change',refresh);
var q=document.getElementById('q');
if(q){q.addEventListener('input',function(){
  var t=q.value.trim().toLowerCase();
  document.querySelectorAll('.group').forEach(function(g){
    var all=!t||g.dataset.name.toLowerCase().indexOf(t)>=0, any=all;
    g.querySelectorAll('.row').forEach(function(r){
      var hit=all||r.textContent.toLowerCase().indexOf(t)>=0;
      r.hidden=!hit; any=any||hit;
    });
    g.hidden=!any;
    var d=g.querySelector('details'); if(d){d.open=!!t&&any&&!all;}
  });
});}
refresh();
"""


def layout(title, body) -> bytes:
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>%s</title><style>%s</style></head><body><main>%s</main><script>%s</script></body></html>"
        % (esc(title), STYLE, body, SCRIPT)
    ).encode()


def channels_section(notify, account_email) -> str:
    instance = notify.get("push_instance") or "none"
    options = "".join(
        '<option value="%s"%s>%s</option>' % (v, " selected" if v == instance else "", t) for v, t in INSTANCES
    )
    default = notify.get("default") or "off"
    defaults = "".join(
        '<option value="%s"%s>%s</option>' % (v, " selected" if v == default else "", LABELS[v]) for v in ("off", "push", "email")
    )
    return (
        "<h2>Where to reach you</h2><div class=\"card\">"
        '<div class="field"><label class="t" for="pi">Phone: Home Assistant instance</label>'
        '<select id="pi" name="push_instance">%s</select></div>'
        '<div class="field"><div><label class="t" for="ps">Phone: notify service</label>'
        '<div class="muted">Your Companion app\'s service in Home Assistant, like mobile_app_your_iphone.</div></div>'
        '<input type="text" id="ps" name="push_service" value="%s" placeholder="mobile_app_your_iphone" autocapitalize="off" spellcheck="false"></div>'
        '<div class="field"><div><label class="t" for="em">Email</label><div class="muted">Empty means your account email.</div></div>'
        '<input type="email" id="em" name="email" value="%s" placeholder="%s"></div>'
        '<div class="field"><label class="t" for="df">Notifications sent to you by name</label>'
        '<select id="df" name="default">%s</select></div>'
        "</div>"
    ) % (options, esc(notify.get("push_service") or ""), esc(notify.get("email") or ""), esc(account_email or ""), defaults)


def full_page(user, notify, catalog, saved) -> bytes:
    ids = Ids()
    groups = notify.get("groups") or {}
    alerts = notify.get("alerts") or {}
    total = sum(len(g["alerts"]) for g in catalog)
    out = [
        "<h1>Notifications</h1><div class=\"muted\">Signed in as %s</div>" % esc(user["username"]),
        '<div class="banner">Saved.</div>' if saved else "",
        '<form method="post" action="/save"><input type="hidden" name="next" value="/">',
        channels_section(notify, user.get("email")),
        "<h2>What you get</h2>",
        '<div class="muted">%d alerts in %d rule groups. A group choice also covers alerts added to it later; '
        "a choice on one alert wins over its group.</div>" % (total, len(catalog)),
        '<input type="text" id="q" placeholder="Search alerts or groups" autocomplete="off">',
        '<div class="card">',
    ]
    listed = set()
    for g in catalog:
        rows = []
        for a in g["alerts"]:
            listed.add(a["name"])
            current = alerts.get(a["name"], "inherit")
            rows.append(
                '<div class="row"><div><span class="name">%s</span><span class="from" hidden>from group</span>'
                '<div class="sum">%s</div></div>%s</div>'
                % (esc(a["name"]), esc(summary_text(a)), seg(ids, "a:" + a["name"], current, inherit=True))
            )
        out.append(
            '<section class="group" data-name="%s"><div class="ghead"><b>%s</b>%s</div>'
            "<details><summary>%d alert%s</summary>%s</details></section>"
            % (esc(g["name"]), esc(g["name"]), seg(ids, "g:" + g["name"], groups.get(g["name"], "off")),
               len(g["alerts"]), "" if len(g["alerts"]) == 1 else "s", "".join(rows))
        )
    out.append("</div>")
    others = sorted(a for a in alerts if a not in listed)
    if others:
        out.append("<h2>Alerts outside the rule list</h2><div class=\"muted\">Chosen earlier; Prometheus does not list them now.</div><div class=\"card\">")
        for name in others:
            out.append('<div class="field"><span>%s</span>%s</div>' % (esc(name), seg(ids, "a:" + name, alerts[name])))
        out.append("</div>")
    out.append('<div class="bar"><button type="submit">Save</button></div></form>')
    return layout("Notifications", "".join(out))


def alert_page(user, notify, name, catalog, groups_of, saved) -> bytes:
    ids = Ids()
    chosen = notify.get("groups") or {}
    own = (notify.get("alerts") or {}).get(name)
    in_groups = groups_of(name)
    if own in subs.CHOICES:
        current = own
    else:
        derived = sorted(subs.channels_for(notify, name, in_groups))
        current = derived[0] if derived else "off"
    summary, sizes = "", {}
    for g in catalog:
        sizes[g["name"]] = len(g["alerts"])
        for a in g["alerts"]:
            if a["name"] == name and not summary:
                summary = summary_text(a)
    no_phone = "push" not in subs.available(notify, user.get("email"))
    out = [
        "<h1>%s</h1>" % esc(name),
        '<div class="muted">%s</div>' % esc(summary) if summary else "",
        '<div class="banner">Saved.</div>' if saved else "",
        '<div class="banner">Your phone is not set up yet: <a href="/">add it on the full page</a>.</div>' if no_phone else "",
        '<form method="post" action="/save"><input type="hidden" name="next" value="/a/%s"><div class="card">' % esc(name),
        '<div class="field"><span>Just this alert</span>%s</div>' % seg(ids, "a:" + name, current),
    ]
    for g in in_groups:
        out.append(
            '<div class="field"><span>Whole %s group (%d alerts), and alerts added to it later</span>%s</div>'
            % (esc(g), sizes.get(g, 0), seg(ids, "g:" + g, chosen.get(g, "off")))
        )
    if not in_groups:
        out.append('<div class="field muted">Prometheus lists this alert in no rule group.</div>')
    out.append('</div><button type="submit">Save</button></form><p><a href="/">All alerts and your phone and email</a></p>')
    return layout(name, "".join(out))


def message_page(text, back) -> bytes:
    return layout("Notifications", '<div class="banner bad">%s</div><p><a href="%s">Back</a></p>' % (esc(text), esc(back)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(fmt, *args)

    def reply(self, code, body=b"", ctype="text/html; charset=utf-8", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def identify(self):
        """-> the Authentik user, or None after replying."""
        try:
            with open(self.server.proof_file) as f:
                proof = f.read().strip()
        except OSError:
            proof = ""
        sent = self.headers.get("X-Notify-Ingress-Proof") or ""
        username = self.headers.get("X-authentik-username") or ""
        if not proof or not hmac.compare_digest(sent.encode(), proof.encode()) or not username:
            self.reply(403, message_page("Open this page through https://notify.viktorbarzin.me.", "/"))
            return None
        user = self.server.directory.user(username)
        if user is None:
            self.reply(403, message_page("No account found for %s." % username, "/"))
        return user

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        saved = "saved=1" in url.query
        try:
            if url.path == "/":
                user = self.identify()
                if user:
                    notify = (user.get("attributes") or {}).get("notify") or {}
                    self.reply(200, full_page(user, notify, self.server.rules.catalog(), saved))
            elif url.path.startswith("/a/"):
                name = urllib.parse.unquote(url.path[3:])
                if not subs.ALERTNAME.fullmatch(name):
                    return self.reply(404, message_page("No such alert.", "/"))
                user = self.identify()
                if user:
                    notify = (user.get("attributes") or {}).get("notify") or {}
                    rules = self.server.rules
                    self.reply(200, alert_page(user, notify, name, rules.catalog(), rules.groups_of, saved))
            else:
                self.reply(404, message_page("Not found.", "/"))
        except subs.Unavailable as e:
            log.error("page: %s", e)
            self.reply(503, message_page("Authentik did not answer. Try again in a minute.", "/"))

    def same_origin(self) -> bool:
        origin = self.headers.get("Origin")
        if origin:
            return origin == self.server.origin
        return (self.headers.get("Referer") or "").startswith(self.server.origin + "/")

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path != "/save":
            return self.reply(404, message_page("Not found.", "/"))
        if not self.same_origin():
            return self.reply(403, message_page("Save from https://notify.viktorbarzin.me itself.", "/"))
        try:
            user = self.identify()
            if not user:
                return
            length = int(self.headers.get("Content-Length") or 0)
            form = {k: v[-1] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode(), keep_blank_values=True).items()}
            back = form.pop("next", "/")
            if not back.startswith("/") or back.startswith("//"):
                back = "/"
            notify = (user.get("attributes") or {}).get("notify") or {}
            try:
                new = subs.apply_form(notify, form, self.server.rules.groups_of, user.get("email") or "")
            except subs.Invalid as e:
                return self.reply(400, message_page(str(e), back))
            self.server.directory.save(user, new)
            log.info("saved settings of %s", user["username"])
            self.reply(303, b"", headers={"Location": back.split("?")[0] + "?saved=1"})
        except subs.Unavailable as e:
            log.error("save: %s", e)
            self.reply(503, message_page("Authentik did not answer, so nothing was saved. Try again in a minute.", "/"))


def make_server(address, directory, rules, proof_file, page_url) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(address, Handler)
    server.directory = directory
    server.rules = rules
    server.proof_file = proof_file
    parts = urllib.parse.urlsplit(page_url)
    server.origin = "%s://%s" % (parts.scheme, parts.netloc)
    return server
