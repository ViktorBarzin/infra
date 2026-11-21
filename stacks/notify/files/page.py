"""The notify pipe's settings page: https://notify.viktorbarzin.me.

Each person sets where to reach them (Phone, Email, Slack), which alerts
reach them on which of those Channels, and which Channels get Notifications
sent to them by name. Saving writes their Authentik attributes (subs.py);
Authentik then pushes their Phone and Email to apprise-api by itself
(stacks/authentik/notify.tf).

  GET  /            every alert, by rule group, with a search box
  GET  /a/<alert>   one alert: the link in Slack posts and in emails
  GET  /how         how the pipe works, with its diagram
  POST /save        the rows that changed; the rest stay as they were
  POST /test        send the signed-in person a test of one alert, on the
                    Channels its row has selected (preview.py)

Who is asking comes from X-authentik-username (and X-authentik-groups), set
by Traefik's forward auth. The listener is reachable inside the cluster too,
so a request must also carry the X-Notify-Ingress-Proof value that only the
ingress adds (stacks/notify/ingress.tf). A POST must come from this page's
own origin.

Each row carries a hidden field with its choice ("inherit" or "push,slack")
and another with the value the page showed. The page's script sends only the
rows that changed, and the save refuses a row that someone changed since the
page was loaded (subs.Conflict).
"""

import hmac
import html
import json
import logging
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import adapter
import preview
import slack
import subs

log = logging.getLogger("notify-page")

CHIPS = (("push", "Phone"), ("email", "Email"), ("slack", "Slack"))
INSTANCES = (("none", "None"), ("ha-sofia", "ha-sofia"), ("ha-london", "ha-london"))
TEMPLATE = re.compile(r"\{\{.*?\}\}")
TESTS_PER_MINUTE = 6
CHANNEL_WORDS = {"push": "your phone", "email": "your email", "slack": "your Slack DMs"}


def esc(value) -> str:
    return html.escape(str(value), quote=True)


def chips(kind, key, value, stored=False, extra="") -> str:
    """One row's Phone / Email / Slack chips. `value` is the choice to show;
    kind "a" (alert) may inherit from its group. `stored`, when given, is the
    stored value the save compares against, if it differs from `value`."""
    shown = subs.show(value)
    if kind != "a" and shown == "inherit":
        shown = ""
    orig = shown if stored is False else subs.show(stored)
    out = ['<span class="chips" data-kind="%s">' % kind]
    for ch, label in CHIPS:
        out.append('<button type="button" class="chip c-%s" data-ch="%s" aria-pressed="false">%s</button>' % (ch, ch, label))
    if kind == "a":
        out.append('<button type="button" class="reset" title="Follow the group again" hidden>&#8634;</button>')
    out.append('<input type="hidden" name="%s" value="%s" disabled>' % (esc(key), esc(shown)))
    out.append('<input type="hidden" name="o:%s" value="%s" disabled>' % (esc(key), esc(orig)))
    out.append(extra + "</span>")
    return "".join(out)


def test_button(name) -> str:
    return '<button type="button" class="test" data-alert="%s" title="Send yourself a test of this alert">Test</button>' % esc(name)


def summary_text(alert) -> str:
    return TEMPLATE.sub("…", alert.get("summary") or "")


STYLE = """
:root{--bg:#fff;--fg:#1a1a1a;--muted:#666;--line:#e3e3e3;--card:#f7f7f7;--accent:#2f6fed;--accent-fg:#fff;--ghost:#dbe6fb;--bad:#b3261e;--c1:#2f6fed;--c2:#14a38b}
@media (prefers-color-scheme:dark){:root{--bg:#121212;--fg:#eee;--muted:#9a9a9a;--line:#2c2c2c;--card:#1b1b1b;--accent:#4b82f0;--ghost:#25324d;--bad:#f2b8b5;--c1:#5b8ff5;--c2:#2bc4a8}}
*{box-sizing:border-box}[hidden]{display:none!important}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,sans-serif}
main{max-width:780px;margin:0 auto;padding:16px 16px 96px}
h1{font-size:22px;margin:8px 0 4px}h2{font-size:17px;margin:28px 0 8px}
.top{display:flex;justify-content:space-between;align-items:baseline;gap:12px;flex-wrap:wrap}
.muted{color:var(--muted);font-size:13px}.banner{padding:10px 14px;border-radius:8px;margin:12px 0;background:var(--ghost)}
.banner.bad{background:transparent;border:1px solid var(--bad);color:var(--bad)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:4px 14px;margin:8px 0}
.field{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;justify-content:space-between;padding:10px 0;border-top:1px solid var(--line)}
.field:first-child{border-top:none}.field label.t{font-weight:500}
input[type=text],input[type=email],select{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);min-width:220px}
.chips{display:inline-flex;align-items:center;gap:4px;flex:none}
.chip{font:inherit;font-size:13px;padding:3px 10px;border:1px solid var(--line);border-radius:999px;background:transparent;color:var(--fg);cursor:pointer}
.chip.on{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.chip.ghost{background:var(--ghost);border-style:dashed}
.reset{font:inherit;background:transparent;border:0;color:var(--muted);cursor:pointer;padding:0 4px}
.acts{display:flex;gap:8px;align-items:center;flex:none;margin-left:auto}
.row,.field{flex-wrap:wrap}.row>div:first-child,.field>div:first-child{flex:1 1 220px;min-width:0}
button.test{font:inherit;background:transparent;color:var(--accent);border:1px solid var(--line);border-radius:7px;padding:3px 10px;font-size:13px;cursor:pointer}
button.test:disabled{opacity:.5;cursor:default}
.tst{font-size:12px;color:var(--muted);margin-top:2px}.tst.bad{color:var(--bad)}
.ghead{display:flex;gap:8px;align-items:center;justify-content:space-between;padding:10px 0 4px;flex-wrap:wrap}
.ghead b{font-size:15px}
details{padding:0 0 8px}summary{cursor:pointer;color:var(--muted);font-size:13px}
.row{display:flex;gap:10px;align-items:center;justify-content:space-between;padding:7px 0 7px 14px;border-top:1px solid var(--line)}
.row .name{font-size:14px;word-break:break-word}.row .sum{color:var(--muted);font-size:12px}
.from{font-size:11px;color:var(--muted);margin-left:6px}
.group{border-top:1px solid var(--line)}.group:first-of-type{border-top:none}
#q{width:100%;margin:4px 0 8px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--bg);border-top:1px solid var(--line);padding:10px 16px;text-align:center}
button.save{font:inherit;background:var(--accent);color:var(--accent-fg);border:0;border-radius:8px;padding:8px 22px;cursor:pointer}
button.save:disabled{opacity:.45;cursor:default}
a{color:var(--accent)}
svg{width:100%;height:auto;display:block}
.how p{margin:8px 0}
"""

SCRIPT = """
function rowOf(el){return el.closest('.row,.ghead,.field');}
function val(chipsEl){return chipsEl.querySelector('input[type=hidden]:not([name^="o:"])');}
function groupSet(chipsEl){
  var g=chipsEl.closest('.group'); if(!g) return [];
  var v=val(g.querySelector('.ghead .chips')).value; return v?v.split(','):[];
}
function paint(chipsEl){
  var input=val(chipsEl), v=input.value, inh=(v==='inherit'), set=inh?groupSet(chipsEl):(v?v.split(','):[]);
  chipsEl.querySelectorAll('.chip').forEach(function(c){
    var on=set.indexOf(c.dataset.ch)>=0;
    c.classList.toggle('on',on&&!inh); c.classList.toggle('ghost',on&&inh); c.setAttribute('aria-pressed',on?'true':'false');
  });
  var r=chipsEl.querySelector('.reset'); if(r) r.hidden=inh;
  var row=rowOf(chipsEl), from=row&&row.querySelector('.from'); if(from) from.hidden=!(inh&&set.length);
  // Changed = differs from what the page loaded; only changed rows are sent.
  // (data-initial, not defaultValue: on a hidden input, setting .value also
  // rewrites its default.)
  if(input.dataset.initial===undefined) input.dataset.initial=input.value;
  var orig=chipsEl.querySelector('input[name^="o:"]'), changed=(input.value!==input.dataset.initial);
  input.disabled=!changed; orig.disabled=!changed;
  updateSave();
}
function dirty(){
  var f=document.querySelector('form'); if(!f) return false;
  if(f.querySelector('.chips input[type=hidden]:not([name^="o:"]):not([disabled])')) return true;
  return Array.prototype.some.call(f.querySelectorAll('input[type=text],input[type=email],select'),function(el){
    if(el.id==='q') return false;
    if(el.tagName==='SELECT') return Array.prototype.some.call(el.options,function(o){return o.selected!==o.defaultSelected;});
    return el.value!==el.defaultValue;
  });
}
function updateSave(){
  document.querySelectorAll('button.save').forEach(function(b){var d=!dirty(); b.disabled=d; b.title=d?'Nothing changed yet':'';});
}
document.addEventListener('input',function(e){if(e.target.id!=='q') updateSave();});
document.addEventListener('change',updateSave);
function paintGroup(g){g.querySelectorAll('.chips').forEach(paint);}
function effective(chipsEl){var v=val(chipsEl).value; return v==='inherit'?groupSet(chipsEl):(v?v.split(','):[]);}
document.addEventListener('click',function(e){
  var chip=e.target.closest('.chip');
  if(chip){
    var c=chip.closest('.chips'), input=val(c), set=effective(c), ch=chip.dataset.ch, i=set.indexOf(ch);
    if(i>=0) set.splice(i,1); else set.push(ch);
    input.value=['push','email','slack'].filter(function(x){return set.indexOf(x)>=0;}).join(',');
    var g=c.closest('.group'); if(c.dataset.kind==='g'&&g) paintGroup(g); else paint(c);
    return;
  }
  var reset=e.target.closest('.reset');
  if(reset){var c2=reset.closest('.chips'); val(c2).value='inherit'; paint(c2); return;}
  var b=e.target.closest('button.test'); if(!b) return;
  var row=rowOf(b), st=row.querySelector('.tst'), cs=row.querySelector('.chips');
  b.disabled=true; st.className='tst'; st.textContent='Sending a test...';
  fetch('/test',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams({alert:b.dataset.alert,channels:cs?effective(cs).join(','):''})})
  .then(function(r){return r.json();})
  .then(function(j){st.className=j.ok?'tst':'tst bad'; st.textContent=j.message;})
  .catch(function(){st.className='tst bad'; st.textContent='No answer. Reload the page to sign in again.';})
  .then(function(){b.disabled=false;});
});
document.querySelectorAll('.chips').forEach(paint);
updateSave();
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
"""

NAV = '<a href="/">Settings</a> · <a href="/how">How it works</a>'


def layout(title, body) -> bytes:
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>%s</title><style>%s</style></head><body><main>%s</main><script>%s</script></body></html>"
        % (esc(title), STYLE, body, SCRIPT)
    ).encode()


def header(title, user) -> str:
    return '<div class="top"><h1>%s</h1><span class="muted">%s</span></div><div class="muted">Signed in as %s</div>' % (
        esc(title), NAV, esc(user["username"]))


def channels_section(notify, account_email, is_admin) -> str:
    instance = notify.get("push_instance") or "none"
    options = "".join(
        '<option value="%s"%s>%s</option>' % (v, " selected" if v == instance else "", t) for v, t in INSTANCES
    )
    slack_help = "Direct messages from the homelab bot. In Slack: your profile, the three dots, Copy member ID."
    if is_admin:
        slack_help += " As an admin you may enter a channel instead, such as #alerts."
    return (
        "<h2>Where to reach you</h2><div class=\"card\">"
        '<div class="field"><label class="t" for="pi">Phone: Home Assistant instance</label>'
        '<select id="pi" name="push_instance">%s</select></div>'
        '<div class="field"><div><label class="t" for="ps">Phone: notify service</label>'
        '<div class="muted">Your Companion app\'s service in Home Assistant, like mobile_app_your_iphone.</div></div>'
        '<input type="text" id="ps" name="push_service" value="%s" placeholder="mobile_app_your_iphone" autocapitalize="off" spellcheck="false"></div>'
        '<div class="field"><div><label class="t" for="em">Email</label><div class="muted">Empty means your account email.</div></div>'
        '<input type="email" id="em" name="email" value="%s" placeholder="%s"></div>'
        '<div class="field"><div><label class="t" for="sl">Slack</label><div class="muted">%s</div></div>'
        '<input type="text" id="sl" name="slack_target" value="%s" placeholder="U01AB2CD3EF" autocapitalize="off" spellcheck="false"></div>'
        '<div class="field"><div><span class="t">Notifications sent to you by name</span></div>%s</div>'
        "</div>"
    ) % (options, esc(notify.get("push_service") or ""), esc(notify.get("email") or ""), esc(account_email or ""),
         esc(slack_help), esc(notify.get("slack_target") or ""), chips("d", "default", notify.get("default")))


def full_page(user, notify, catalog, saved, is_admin=False) -> bytes:
    groups = notify.get("groups") or {}
    alerts = notify.get("alerts") or {}
    total = sum(len(g["alerts"]) for g in catalog)
    out = [
        header("Notifications", user),
        '<div class="banner">Saved.</div>' if saved else "",
        '<form method="post" action="/save"><input type="hidden" name="next" value="/">',
        channels_section(notify, user.get("email"), is_admin),
        "<h2>What you get</h2>",
        '<div class="muted">%d alerts in %d rule groups. Tap Phone, Email or Slack to choose; you can pick several. '
        "A group choice also covers alerts added to it later. A choice on one alert wins over its group; "
        "&#8634; makes it follow the group again.</div>" % (total, len(catalog)),
        '<input type="text" id="q" placeholder="Search alerts or groups" autocomplete="off">',
        '<div class="card">',
    ]
    listed = set()
    for g in catalog:
        rows = []
        for a in g["alerts"]:
            listed.add(a["name"])
            rows.append(
                '<div class="row"><div><span class="name">%s</span><span class="from" hidden>from group</span>'
                '<div class="sum">%s</div><div class="tst" aria-live="polite"></div></div>'
                '<span class="acts">%s%s</span></div>'
                % (esc(a["name"]), esc(summary_text(a)), test_button(a["name"]), chips("a", "a:" + a["name"], alerts.get(a["name"])))
            )
        out.append(
            '<section class="group" data-name="%s"><div class="ghead"><b>%s</b>%s</div>'
            "<details><summary>%d alert%s</summary>%s</details></section>"
            % (esc(g["name"]), esc(g["name"]), chips("g", "g:" + g["name"], groups.get(g["name"])),
               len(g["alerts"]), "" if len(g["alerts"]) == 1 else "s", "".join(rows))
        )
    out.append("</div>")
    others = sorted(a for a in alerts if a not in listed)
    if others:
        out.append("<h2>Alerts outside the rule list</h2><div class=\"muted\">Chosen earlier; no rules API lists them now.</div><div class=\"card\">")
        for name in others:
            out.append('<div class="row"><div><span class="name">%s</span><div class="tst" aria-live="polite"></div></div>'
                       '<span class="acts">%s%s</span></div>' % (esc(name), test_button(name), chips("a", "a:" + name, alerts[name])))
        out.append("</div>")
    out.append('<div class="bar"><button type="submit" class="save">Save</button></div></form>')
    return layout("Notifications", "".join(out))


def alert_page(user, notify, name, catalog, groups_of, saved) -> bytes:
    chosen = notify.get("groups") or {}
    own = (notify.get("alerts") or {}).get(name)
    in_groups = groups_of(name)
    summary, sizes = "", {}
    for g in catalog:
        sizes[g["name"]] = len(g["alerts"])
        for a in g["alerts"]:
            if a["name"] == name and not summary:
                summary = summary_text(a)
    have = subs.available(notify, user.get("email"))
    # On this page the alert row shows what the person gets now, groups included.
    current = own if subs.as_set(own) is not None else subs.as_list(subs.channels_for(notify, name, in_groups))
    out = [
        header(name, user),
        '<div class="muted">%s</div>' % esc(summary) if summary else "",
        '<div class="banner">Saved.</div>' if saved else "",
        '<div class="banner">Set up %s on <a href="/">the full page</a> before choosing them.</div>'
        % " and ".join(CHANNEL_WORDS[c].replace("your ", "") for c in ("push", "email", "slack") if c not in have)
        if len(have) < 3 else "",
        '<form method="post" action="/save"><input type="hidden" name="next" value="/a/%s"><div class="card">' % esc(name),
        '<div class="field"><div><span>Just this alert</span><div class="tst" aria-live="polite"></div></div>'
        '<span class="acts">%s%s</span></div>' % (test_button(name), chips("x", "a:" + name, current, stored=own)),
    ]
    for g in in_groups:
        out.append(
            '<div class="field"><div><span>Whole %s group (%d alerts), and alerts added to it later</span></div>%s</div>'
            % (esc(g), sizes.get(g, 0), chips("g", "g:" + g, chosen.get(g)))
        )
    if not in_groups:
        out.append('<div class="field muted">No rules API lists this alert in a rule group.</div>')
    out.append('</div><button type="submit" class="save">Save</button></form><p><a href="/">All alerts and your Channels</a></p>')
    return layout(name, "".join(out))


HOW_SVG = """
<svg viewBox="0 0 720 392" role="img" aria-label="How the notify pipe works">
<defs>
 <marker id="m1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" style="fill:var(--c1)"/></marker>
 <marker id="m2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" style="fill:var(--c2)"/></marker>
 <marker id="m3" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" style="fill:var(--muted)"/></marker>
</defs>
<style>
 .bx{fill:var(--card);stroke:var(--line);stroke-width:1.2}.b1{stroke:var(--c1);stroke-width:1.6}.b2{stroke:var(--c2);stroke-width:1.6}
 .t{font:600 13px system-ui,sans-serif;fill:var(--fg)}.s{font:10.5px system-ui,sans-serif;fill:var(--muted)}
 .a1{stroke:var(--c1);stroke-width:2;fill:none}.a2{stroke:var(--c2);stroke-width:2;fill:none}
 .a3{stroke:var(--muted);stroke-width:1.4;fill:none;stroke-dasharray:4 3}.pod{fill:none;stroke:var(--muted);stroke-dasharray:3 3}
</style>
<rect class="pod" x="306" y="52" width="148" height="326" rx="12"/>
<text class="s" x="380" y="371" text-anchor="middle">one pod: notify-adapter</text>
<rect class="bx b1" x="10" y="70" width="120" height="56" rx="9"/><text class="t" x="70" y="94" text-anchor="middle">Alert rules</text><text class="s" x="70" y="111" text-anchor="middle">Prometheus + Loki</text>
<rect class="bx b1" x="165" y="70" width="120" height="56" rx="9"/><text class="t" x="225" y="94" text-anchor="middle">Alertmanager</text><text class="s" x="225" y="111" text-anchor="middle">every alert, one route</text>
<rect class="bx b1" x="320" y="70" width="120" height="56" rx="9"/><text class="t" x="380" y="94" text-anchor="middle">Router</text><text class="s" x="380" y="111" text-anchor="middle">who wants this alert?</text>
<rect class="bx b1" x="475" y="70" width="110" height="56" rx="9"/><text class="t" x="530" y="94" text-anchor="middle">Apprise</text><text class="s" x="530" y="111" text-anchor="middle">Phone and Email</text>
<rect class="bx b1" x="610" y="30" width="100" height="46" rx="9"/><text class="t" x="660" y="51" text-anchor="middle">Phone</text><text class="s" x="660" y="66" text-anchor="middle">HA Companion</text>
<rect class="bx b1" x="610" y="96" width="100" height="46" rx="9"/><text class="t" x="660" y="117" text-anchor="middle">Email</text><text class="s" x="660" y="132" text-anchor="middle">our mailserver</text>
<rect class="bx b1" x="610" y="170" width="100" height="46" rx="9"/><text class="t" x="660" y="191" text-anchor="middle">Slack</text><text class="s" x="660" y="206" text-anchor="middle">a DM or #alerts</text>
<path class="a1" d="M130,98 L163,98" marker-end="url(#m1)"/><path class="a1" d="M285,98 L318,98" marker-end="url(#m1)"/>
<path class="a1" d="M440,98 L473,98" marker-end="url(#m1)"/>
<path class="a1" d="M585,88 L608,58" marker-end="url(#m1)"/><path class="a1" d="M585,108 L608,118" marker-end="url(#m1)"/>
<path class="a1" d="M440,118 C520,150 560,186 608,190" marker-end="url(#m1)"/>
<path class="a3" d="M70,70 C70,20 380,20 380,68" marker-end="url(#m3)"/><text class="s" x="225" y="30" text-anchor="middle">rule groups (which group is this alert in?)</text>
<path class="a3" d="M225,126 C225,210 300,236 420,236 L606,206" marker-end="url(#m3)"/>
<text class="s" x="232" y="256">6 root-cause alerts also go straight to #alerts</text>
<rect class="bx b2" x="10" y="292" width="120" height="56" rx="9"/><text class="t" x="70" y="316" text-anchor="middle">You</text><text class="s" x="70" y="333" text-anchor="middle">phone or laptop</text>
<rect class="bx b2" x="320" y="292" width="120" height="56" rx="9"/><text class="t" x="380" y="312" text-anchor="middle">This page</text><text class="s" x="380" y="327" text-anchor="middle">choose, Test</text>
<rect class="bx b2" x="475" y="292" width="110" height="56" rx="9"/><text class="t" x="530" y="316" text-anchor="middle">Authentik</text><text class="s" x="530" y="333" text-anchor="middle">your settings</text>
<path class="a2" d="M130,320 L318,320" marker-end="url(#m2)"/><text class="s" x="224" y="312" text-anchor="middle">sign in, pick alerts</text>
<path class="a2" d="M440,320 L473,320" marker-end="url(#m2)"/><text class="s" x="456" y="312" text-anchor="middle">save</text>
<path class="a2" d="M565,292 L565,128" marker-end="url(#m2)"/><text class="s" x="571" y="276">your Phone</text><text class="s" x="571" y="288">+ Email</text>
<path class="a3" d="M495,292 C480,240 420,170 400,128" marker-end="url(#m3)"/><text class="s" x="472" y="196">reads who</text><text class="s" x="472" y="208">wants what</text>
</svg>
"""


def how_page(user) -> bytes:
    body = header("How it works", user) + """
<div class="how">
<p>Every alert from Prometheus and Loki goes to Alertmanager, and from there to one place: the Router in the notify-adapter. Nothing else decides who hears about an alert.</p>
""" + HOW_SVG + """
<p><b>Blue: an alert reaching you.</b> The Router reads everyone's choices and the alert's rule group. It posts Slack itself and hands Phone and Email to Apprise.</p>
<p><b>Green: you choosing.</b> This page saves your choices on your Authentik account. Authentik then gives Apprise your phone and email address.</p>
<p><b>Dashed: side paths.</b> The Router asks Prometheus which rule group an alert belongs to. Six alerts about the pipe's own foundations (NotifyPipeDown, NotifyDeliveryFailing, NodeDown, NFSServerUnresponsive, AuthentikDown, PowerOutage) also post straight to #alerts, so they arrive even when the Router cannot.</p>
<p><b>When something is down.</b> If Authentik does not answer, the Router uses the last copy of everyone's choices it saved. If Slack or Apprise does not answer, Alertmanager sends the alert again later; a Channel that already got it is skipped.</p>
<p><b>Nobody chose it.</b> When a critical or security alert fires and reaches no one, #alerts gets one line saying so, with a link to turn it on.</p>
<p><b>Test</b> sends an alert as it would really look, to the Channels selected on its row: from when it last fired, or with realistic made-up values.</p>
</div>"""
    return layout("How it works", body)


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

    def username(self):
        """-> the signed-in username, or None after replying 403."""
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
        return username

    def is_admin(self) -> bool:
        groups = (self.headers.get("X-authentik-groups") or "").split("|")
        return self.server.admin_group in groups

    def identify(self):
        """-> the Authentik user, or None after replying."""
        username = self.username()
        if not username:
            return None
        user = self.server.directory.user(username)
        if user is None:
            self.reply(403, message_page("No account found for %s." % username, "/"))
        return user

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        saved = "saved=1" in url.query
        try:
            if url.path == "/favicon.ico":
                return self.reply(204)
            if url.path == "/how":
                user = self.identify()
                if user:
                    self.reply(200, how_page(user))
            elif url.path == "/":
                user = self.identify()
                if user:
                    notify = (user.get("attributes") or {}).get("notify") or {}
                    self.reply(200, full_page(user, notify, self.server.rules.catalog(), saved, self.is_admin()))
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

    def form(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        pairs = urllib.parse.parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        return {k: v[-1] for k, v in pairs.items()}

    def answer(self, code, ok, message, **extra):
        body = json.dumps(dict(extra, ok=ok, message=message)).encode()
        self.reply(code, body, "application/json")

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/test":
            return self.test()
        if path != "/save":
            return self.reply(404, message_page("Not found.", "/"))
        if not self.same_origin():
            return self.reply(403, message_page("Save from https://notify.viktorbarzin.me itself.", "/"))
        username = self.username()
        if not username:
            return
        form = self.form()
        back = form.pop("next", "/")
        if not back.startswith("/") or back.startswith("//"):
            back = "/"
        srv = self.server
        admin = self.is_admin()

        def change(user):
            notify = (user.get("attributes") or {}).get("notify") or {}
            new = subs.apply_form(notify, form, srv.rules.groups_of, user.get("email") or "", admin)
            log.info("save by %s: %s", username, json.dumps(diff(notify, new), sort_keys=True))
            return new

        try:
            srv.directory.update(username, change)
        except subs.Conflict as e:
            return self.reply(409, message_page(str(e), back))
        except subs.Invalid as e:
            return self.reply(400, message_page(str(e), back))
        except subs.Unavailable as e:
            log.error("save: %s", e)
            return self.reply(503, message_page("Authentik did not answer, so nothing was saved. Try again in a minute.", "/"))
        self.reply(303, b"", headers={"Location": back.split("?")[0] + "?saved=1"})

    def test(self):
        """Send the signed-in person a test of one alert, built like a real one."""
        if not self.same_origin():
            return self.answer(403, False, "Send tests from https://notify.viktorbarzin.me itself.")
        srv = self.server
        try:
            user = self.identify()
            if not user:
                return
            form = self.form()
            name = form.get("alert", "")
            if not subs.ALERTNAME.fullmatch(name):
                return self.answer(400, False, "No such alert.")
            notify = (user.get("attributes") or {}).get("notify") or {}
            have = subs.available(notify, user.get("email") or "")
            target = subs.slack_target(notify)
            # Test exactly the Channels the row has selected, Slack target
            # included: a channel such as #alerts is only possible for an
            # admin, who chose it. Only a row that is off falls back.
            selected = [c for c in subs.CHANNELS if c in form.get("channels", "").split(",")]
            wanted = [c for c in selected if c in have]
            not_set_up = [c for c in selected if c not in have]
            note = ""
            if not selected:
                wanted = [c for c in ("push", "email", "slack") if c in have][:1]
                if wanted:
                    note = " This alert is off for you, so the test went to %s." % self.where(wanted[0], target)
            if not wanted:
                if not_set_up:
                    return self.answer(400, False, "Set up %s first, on the full page." % " and ".join(CHANNEL_WORDS[c] for c in not_set_up))
                return self.answer(400, False, "Set up a phone, an email address or Slack first.")
            if not_set_up:
                note += " Not set up yet: %s." % " and ".join(CHANNEL_WORDS[c] for c in not_set_up)
            if not srv.allow_test(user["username"]):
                return self.answer(429, False, "That is %d tests this minute; wait a little." % TESTS_PER_MINUTE)

            rule = srv.rules.rule(name) or {"name": name, "labels": {}, "annotations": {}, "query": "", "alerts": []}
            sample = preview.sample(rule, srv.prom, time.time())
            n = adapter.build({"status": "firing", "alerts": [sample["alert"]]})
            n["title"] = "Test: " + n["title"]
            results = {}
            for ch in wanted:
                if ch == "slack":
                    results[ch] = srv.slack.post(target, slack.test_message(n))
                    continue
                m = n
                if ch == "email":
                    m = dict(n, body=n["body"] + "\n\nChange what you get: %s/a/%s" % (srv.page_url, urllib.parse.quote(name)))
                results[ch] = srv.apprise.send(m, [subs.channel_tag(user["username"], ch)])
        except subs.Unavailable as e:
            log.error("test: %s", e)
            return self.answer(503, False, "Apprise, Slack or Authentik did not answer. Try again in a minute.")
        log.info("test %s for %s: %s (%s)", name, user["username"], results, sample["source"])
        ok = [self.where(c, target) for c, r in results.items() if r == "sent"]
        bad = [self.where(c, target) for c, r in results.items() if r != "sent"]
        if not bad:
            return self.answer(200, True, "Sent to %s (%s): %s%s" % (" and ".join(ok), sample["source"], n["title"], note),
                               source=sample["source"], title=n["title"])
        message = "Could not send to %s. Save your settings once, then try again." % " and ".join(bad)
        if ok:
            message = "Sent to %s, but not to %s." % (" and ".join(ok), " and ".join(bad))
        return self.answer(502, False, message + note)

    @staticmethod
    def where(channel, target) -> str:
        if channel == "slack" and target and target.startswith("#"):
            return target
        return CHANNEL_WORDS[channel]


def diff(old: dict, new: dict) -> dict:
    """What a save changed, for the log: {key: [before, after]}."""
    out = {}
    for key in sorted(set(old) | set(new)):
        if key in ("groups", "alerts"):
            a, b = old.get(key) or {}, new.get(key) or {}
            for k in sorted(set(a) | set(b)):
                if subs.show(a.get(k)) != subs.show(b.get(k)):
                    out["%s:%s" % (key[0], k)] = [subs.show(a.get(k)), subs.show(b.get(k))]
        elif old.get(key) != new.get(key):
            out[key] = [old.get(key), new.get(key)]
    return out


def make_server(address, directory, rules, proof_file, page_url, apprise=None, prom=None,
                slack_client=None, admin_group="Home Server Admins") -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(address, Handler)
    server.directory = directory
    server.rules = rules
    server.proof_file = proof_file
    server.page_url = page_url.rstrip("/")
    server.apprise = apprise
    server.prom = prom
    server.slack = slack_client
    server.admin_group = admin_group
    parts = urllib.parse.urlsplit(page_url)
    server.origin = "%s://%s" % (parts.scheme, parts.netloc)
    tests, lock = {}, threading.Lock()

    def allow_test(username) -> bool:
        now = time.monotonic()
        with lock:
            recent = [t for t in tests.get(username, []) if now - t < 60]
            if len(recent) >= TESTS_PER_MINUTE:
                tests[username] = recent
                return False
            tests[username] = recent + [now]
            return True

    server.allow_test = allow_test
    return server
