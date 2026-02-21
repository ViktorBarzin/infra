package proxy

import (
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// hopHeaders are headers that should not be forwarded by proxies.
var hopHeaders = map[string]bool{
	"Connection":          true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailers":            true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
}

// antiFrameHeaders are headers we strip to allow iframe embedding.
var antiFrameHeaders = []string{
	"X-Frame-Options",
	"Content-Security-Policy",
	"Content-Security-Policy-Report-Only",
	"X-Content-Type-Options",
}

// forwardHeaders are request headers we copy from the client to the upstream.
// NOTE: Accept-Encoding is intentionally omitted so Go's Transport handles
// compression transparently (adds gzip, auto-decompresses response body).
// This ensures we can do text replacements on HTML/CSS bodies.
var forwardHeaders = []string{
	"User-Agent",
	"Accept",
	"Accept-Language",
	"Cookie",
	"Referer",
	"Range",
	"If-None-Match",
	"If-Modified-Since",
	"Cache-Control",
}

// jsShimTemplate is injected into HTML responses to intercept JS-initiated requests.
// It patches fetch, XMLHttpRequest, WebSocket, and EventSource to route through the proxy.
const jsShimTemplate = `<script data-proxy-shim="1">(function(){
var P='/proxy/%s';
var O='%s';
var H=location.origin;
function b64(s){return btoa(s).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/g,'');}
function rw(u){
if(!u||typeof u!=='string')return u;
if(u.startsWith('/proxy/'))return u;
if(u.startsWith(H+'/proxy/'))return u.slice(H.length);
if(u.startsWith(H+'/')){var hp=u.slice(H.length);return P+hp;}
if(u.startsWith(H))return P+'/';
if(u.startsWith('/'))return P+u;
if(u.startsWith(O))return P+u.slice(O.length);
try{var p=new URL(u);if(p.protocol==='http:'||p.protocol==='https:'){return'/proxy/'+b64(p.origin)+p.pathname+p.search+p.hash;}}catch(e){}
return u;
}
var _f=window.fetch;
window.fetch=function(i,o){
if(typeof i==='string')i=rw(i);
else if(i&&i.url)i=new Request(rw(i.url),i);
return _f.call(this,i,o);
};
var _xo=XMLHttpRequest.prototype.open;
XMLHttpRequest.prototype.open=function(m,u){var a=[].slice.call(arguments);a[1]=rw(u);return _xo.apply(this,a);};
var _ws=window.WebSocket;
window.WebSocket=function(u,p){return new _ws(rw(u),p);};
window.WebSocket.prototype=_ws.prototype;
window.WebSocket.CONNECTING=_ws.CONNECTING;
window.WebSocket.OPEN=_ws.OPEN;
window.WebSocket.CLOSING=_ws.CLOSING;
window.WebSocket.CLOSED=_ws.CLOSED;
if(window.EventSource){var _es=window.EventSource;window.EventSource=function(u,o){return new _es(rw(u),o);};window.EventSource.prototype=_es.prototype;}
var _ce=document.createElement.bind(document);
document.createElement=function(t){
var el=_ce(t);
var tag=t.toLowerCase();
if(tag==='script'||tag==='iframe'||tag==='img'||tag==='link'||tag==='source'||tag==='video'||tag==='audio'){
var _ss=Object.getOwnPropertyDescriptor(HTMLElement.prototype,'src')||Object.getOwnPropertyDescriptor(el.__proto__,'src');
if(_ss&&_ss.set){Object.defineProperty(el,'src',{get:function(){return _ss.get?_ss.get.call(this):'';},set:function(v){_ss.set.call(this,rw(v));},configurable:true});}
}
return el;
};
/* Neutralize anti-debug: override setInterval/setTimeout to skip debugger-based detection */
var _si=window.setInterval;
window.setInterval=function(fn,ms){
if(typeof fn==='function'){var s=fn.toString();if(s.indexOf('debugger')!==-1||s.indexOf('devtool')!==-1)return 0;}
if(typeof fn==='string'&&(fn.indexOf('debugger')!==-1||fn.indexOf('devtool')!==-1))return 0;
return _si.apply(this,arguments);
};
var _st=window.setTimeout;
window.setTimeout=function(fn,ms){
if(typeof fn==='function'){var s=fn.toString();if(s.indexOf('debugger')!==-1||s.indexOf('devtool')!==-1)return 0;}
if(typeof fn==='string'&&(fn.indexOf('debugger')!==-1||fn.indexOf('devtool')!==-1))return 0;
return _st.apply(this,arguments);
};
/* Override eval and Function to strip debugger statements */
var _eval=window.eval;
window.eval=function(s){if(typeof s==='string')s=s.replace(/\bdebugger\b\s*;?/g,'');return _eval.call(this,s);};
var _Fn=Function;
window.Function=function(){var a=[].slice.call(arguments);if(a.length>0){var last=a.length-1;if(typeof a[last]==='string')a[last]=a[last].replace(/\bdebugger\b\s*;?/g,'');}return _Fn.apply(this,a);};
window.Function.prototype=_Fn.prototype;
/* Block loading of known anti-debug scripts */
var _ael=HTMLScriptElement.prototype.setAttribute;
HTMLScriptElement.prototype.setAttribute=function(n,v){
if(n==='src'&&typeof v==='string'&&(v.indexOf('disable-devtool')!==-1||v.indexOf('devtools-detect')!==-1)){return;}
return _ael.apply(this,arguments);
};
})();</script>`

// NewHandler returns an http.Handler that serves the reverse proxy at /proxy/.
// URL structure: /proxy/{base64_origin}/{path...}
func NewHandler() http.Handler {
	client := &http.Client{
		Timeout: 30 * 1000000000, // 30s
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse // don't follow redirects
		},
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Parse: /proxy/{base64_origin}/{path...}
		trimmed := strings.TrimPrefix(r.URL.Path, "/proxy/")
		if trimmed == "" || trimmed == r.URL.Path {
			http.Error(w, "bad proxy URL", http.StatusBadRequest)
			return
		}

		// Split into base64 segment and remaining path
		slashIdx := strings.Index(trimmed, "/")
		var b64Origin, pathAndQuery string
		if slashIdx == -1 {
			b64Origin = trimmed
			pathAndQuery = "/"
		} else {
			b64Origin = trimmed[:slashIdx]
			pathAndQuery = trimmed[slashIdx:]
		}

		originBytes, err := base64.RawURLEncoding.DecodeString(b64Origin)
		if err != nil {
			// Try standard encoding with padding
			originBytes, err = base64.StdEncoding.DecodeString(b64Origin)
			if err != nil {
				http.Error(w, "invalid base64 origin", http.StatusBadRequest)
				return
			}
		}
		origin := string(originBytes)

		// Validate origin is a valid URL
		originURL, err := url.Parse(origin)
		if err != nil || (originURL.Scheme != "http" && originURL.Scheme != "https") {
			http.Error(w, "invalid origin URL", http.StatusBadRequest)
			return
		}

		// Build upstream URL
		targetURL := origin + pathAndQuery
		if r.URL.RawQuery != "" {
			targetURL += "?" + r.URL.RawQuery
		}

		log.Printf("proxy: %s %s -> %s", r.Method, r.URL.Path, targetURL)

		// Create upstream request
		upReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, r.Body)
		if err != nil {
			http.Error(w, "failed to create request", http.StatusInternalServerError)
			return
		}

		// Copy selected headers
		for _, h := range forwardHeaders {
			if v := r.Header.Get(h); v != "" {
				upReq.Header.Set(h, v)
			}
		}
		// Reconstruct the original Referer from the client's proxy-rewritten Referer.
		// The client sends e.g. "https://f1.viktorbarzin.me/proxy/{b64origin}/path"
		// and we need to decode that back to "https://original.com/path".
		upReq.Header.Set("Referer", decodeProxyReferer(r.Header.Get("Referer"), origin))

		// Fetch upstream
		resp, err := client.Do(upReq)
		if err != nil {
			log.Printf("proxy: upstream fetch failed: %v", err)
			http.Error(w, "upstream fetch failed", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		log.Printf("proxy: %s %s <- %d (%s)", r.Method, r.URL.Path, resp.StatusCode, resp.Header.Get("Content-Type"))

		// Handle redirects: rewrite Location header through proxy
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			loc := resp.Header.Get("Location")
			if loc != "" {
				rewritten := rewriteRedirect(loc, origin, b64Origin)
				w.Header().Set("Location", rewritten)
				log.Printf("proxy: redirect %s -> %s", loc, rewritten)
			}
			w.WriteHeader(resp.StatusCode)
			return
		}

		// Copy response headers, stripping anti-frame, hop-by-hop, and encoding headers.
		// Content-Encoding is stripped because Go's Transport already decompressed the body.
		// Content-Length is stripped because we may rewrite the body (changing its length).
		for key, vals := range resp.Header {
			if hopHeaders[key] {
				continue
			}
			if strings.EqualFold(key, "Content-Encoding") || strings.EqualFold(key, "Content-Length") {
				continue
			}
			skip := false
			for _, ah := range antiFrameHeaders {
				if strings.EqualFold(key, ah) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}
			for _, v := range vals {
				w.Header().Add(key, v)
			}
		}

		// Add permissive CORS headers so cross-origin XHR/fetch from the iframe works
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")

		w.WriteHeader(resp.StatusCode)

		// For HTML responses, rewrite URLs and inject JS shim
		ct := resp.Header.Get("Content-Type")
		if strings.Contains(ct, "text/html") {
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("proxy: failed to read HTML body: %v", err)
				return
			}
			rewritten := rewriteHTML(string(body), origin, b64Origin)
			w.Write([]byte(rewritten))
			return
		}

		// For CSS responses, rewrite url() references
		if strings.Contains(ct, "text/css") {
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("proxy: failed to read CSS body: %v", err)
				return
			}
			rewritten := rewriteCSS(string(body), origin, b64Origin)
			w.Write([]byte(rewritten))
			return
		}

		// For JavaScript responses, strip debugger statements
		if strings.Contains(ct, "javascript") || strings.Contains(ct, "ecmascript") {
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("proxy: failed to read JS body: %v", err)
				return
			}
			cleaned := debuggerStmtRe.ReplaceAllString(string(body), "/* */")
			w.Write([]byte(cleaned))
			return
		}

		// Stream other responses directly
		io.Copy(w, resp.Body)
	})
}

// rewriteRedirect rewrites a Location header value to route through the proxy.
func rewriteRedirect(loc, origin, b64Origin string) string {
	// Absolute URL on the same origin
	if strings.HasPrefix(loc, origin) {
		path := strings.TrimPrefix(loc, origin)
		return "/proxy/" + b64Origin + path
	}
	// Absolute URL on a different origin — proxy it too
	parsed, err := url.Parse(loc)
	if err != nil {
		return loc
	}
	if parsed.IsAbs() {
		newOrigin := parsed.Scheme + "://" + parsed.Host
		newB64 := base64.RawURLEncoding.EncodeToString([]byte(newOrigin))
		return "/proxy/" + newB64 + parsed.RequestURI()
	}
	// Relative URL — it will resolve naturally
	return loc
}

// Precompiled regexes for root-relative URL rewriting in HTML attributes.
// Matches src="/...", href="/...", action="/...", poster="/..." but NOT "//..." (protocol-relative).
var rootRelativeAttrRe = regexp.MustCompile(`((?:src|href|action|poster|data)\s*=\s*["'])/([^/"'][^"']*)`)

// Matches url("/...") or url('/...') or url(/...) in inline styles — but NOT url("//...")
var rootRelativeCSSRe = regexp.MustCompile(`(url\(\s*["']?)/([^/"')[^"')]*)(["']?\s*\))`)

// crossOriginIframeSrcRe matches <iframe src="https://..."> to proxy cross-origin embeds.
var crossOriginIframeSrcRe = regexp.MustCompile(`(<iframe[^>]*\ssrc\s*=\s*["'])(https?://[^"']+)(["'])`)

// disableDevtoolRe matches <script> tags that load disable-devtool or similar anti-debug libraries.
var disableDevtoolRe = regexp.MustCompile(`(?i)<script[^>]*(?:disable-devtool|devtools-detect)[^>]*>(?:</script>)?`)

// adScriptRe matches <script> tags that load common ad/popup libraries.
var adScriptRe = regexp.MustCompile(`(?i)<script[^>]*(?:acscdn\.com|popunder|popads|juicyads)[^>]*>\s*(?:</script>)?`)

// adInlineRe matches inline <script> blocks that call ad popup functions.
var adInlineRe = regexp.MustCompile(`(?i)<script[^>]*>\s*(?:aclib\.run|popunder|pop_)\w*\([^)]*\);\s*</script>`)

// contextMenuBlockRe matches inline scripts that block right-click and dev tools shortcuts.
var contextMenuBlockRe = regexp.MustCompile(`(?i)<script[^>]*>\s*document\.addEventListener\(\s*'contextmenu'[\s\S]{0,500}?</script>`)

// debuggerStmtRe matches debugger statements in JavaScript.
var debuggerStmtRe = regexp.MustCompile(`\bdebugger\b\s*;?`)

// rewriteHTML replaces URLs and injects the JS shim to intercept runtime requests.
func rewriteHTML(body, origin, b64Origin string) string {
	proxyPrefix := "/proxy/" + b64Origin

	// 1. Rewrite absolute URLs matching the target origin
	escaped := regexp.QuoteMeta(origin)
	absRe := regexp.MustCompile(escaped + `(/[^"'\s>)]*)?`)
	body = absRe.ReplaceAllStringFunc(body, func(match string) string {
		path := strings.TrimPrefix(match, origin)
		if path == "" {
			path = "/"
		}
		return proxyPrefix + path
	})

	// 2. Rewrite root-relative URLs in HTML attributes (src="/...", href="/...", etc.)
	// Skip URLs already rewritten by step 1 (starting with /proxy/)
	body = rootRelativeAttrRe.ReplaceAllStringFunc(body, func(match string) string {
		m := rootRelativeAttrRe.FindStringSubmatch(match)
		if len(m) < 3 {
			return match
		}
		// m[2] is the path after the leading "/", skip if already proxied
		if strings.HasPrefix(m[2], "proxy/") {
			return match
		}
		return m[1] + proxyPrefix + "/" + m[2]
	})

	// 3. Rewrite root-relative URLs in inline CSS url() references
	// Skip URLs already rewritten by step 1 (starting with /proxy/)
	body = rootRelativeCSSRe.ReplaceAllStringFunc(body, func(match string) string {
		m := rootRelativeCSSRe.FindStringSubmatch(match)
		if len(m) < 4 {
			return match
		}
		if strings.HasPrefix(m[2], "proxy/") {
			return match
		}
		return m[1] + proxyPrefix + "/" + m[2] + m[3]
	})

	// 4. Rewrite cross-origin iframe src attributes to route through proxy
	body = crossOriginIframeSrcRe.ReplaceAllStringFunc(body, func(match string) string {
		m := crossOriginIframeSrcRe.FindStringSubmatch(match)
		if len(m) < 4 {
			return match
		}
		prefix, iframeURL, quote := m[1], m[2], m[3]
		parsed, err := url.Parse(iframeURL)
		if err != nil {
			return match
		}
		iframeOrigin := parsed.Scheme + "://" + parsed.Host
		iframeB64 := base64.RawURLEncoding.EncodeToString([]byte(iframeOrigin))
		return prefix + "/proxy/" + iframeB64 + parsed.RequestURI() + quote
	})

	// 5. Strip anti-debugging scripts (disable-devtool, devtools-detect)
	body = disableDevtoolRe.ReplaceAllString(body, "")

	// 5b. Strip ad/popup scripts and context menu blockers
	body = adScriptRe.ReplaceAllString(body, "")
	body = adInlineRe.ReplaceAllString(body, "")
	body = contextMenuBlockRe.ReplaceAllString(body, "")

	// 5c. Strip debugger statements from inline scripts
	body = debuggerStmtRe.ReplaceAllString(body, "/* */")

	// 6. Inject JS shim right after <head> to intercept fetch/XHR/WebSocket
	shim := fmt.Sprintf(jsShimTemplate, b64Origin, origin)
	headIdx := strings.Index(strings.ToLower(body), "<head>")
	if headIdx != -1 {
		insertPos := headIdx + len("<head>")
		body = body[:insertPos] + shim + body[insertPos:]
	} else {
		// No <head> tag — prepend to body
		body = shim + body
	}

	return body
}

// rewriteCSS replaces root-relative url() references in CSS to route through the proxy.
func rewriteCSS(body, origin, b64Origin string) string {
	proxyPrefix := "/proxy/" + b64Origin

	// Rewrite absolute URLs matching origin
	escaped := regexp.QuoteMeta(origin)
	absRe := regexp.MustCompile(escaped + `(/[^"'\s)]*)?`)
	body = absRe.ReplaceAllStringFunc(body, func(match string) string {
		path := strings.TrimPrefix(match, origin)
		if path == "" {
			path = "/"
		}
		return proxyPrefix + path
	})

	// Rewrite root-relative url() references, skip already-proxied
	body = rootRelativeCSSRe.ReplaceAllStringFunc(body, func(match string) string {
		m := rootRelativeCSSRe.FindStringSubmatch(match)
		if len(m) < 4 {
			return match
		}
		if strings.HasPrefix(m[2], "proxy/") {
			return match
		}
		return m[1] + proxyPrefix + "/" + m[2] + m[3]
	})

	return body
}

// decodeProxyReferer takes the client's Referer (which points to a proxy URL)
// and decodes it back to the original upstream URL. This is critical for
// cross-origin requests where the upstream checks the Referer (e.g. HLS servers).
// Falls back to origin+"/" if decoding fails.
func decodeProxyReferer(clientReferer, fallbackOrigin string) string {
	if clientReferer == "" {
		return fallbackOrigin + "/"
	}

	// Find /proxy/ in the Referer URL path
	idx := strings.Index(clientReferer, "/proxy/")
	if idx == -1 {
		return fallbackOrigin + "/"
	}

	// Extract everything after /proxy/
	rest := clientReferer[idx+len("/proxy/"):]
	if rest == "" {
		return fallbackOrigin + "/"
	}

	// Split into base64 segment and remaining path
	slashIdx := strings.Index(rest, "/")
	var b64Seg, pathPart string
	if slashIdx == -1 {
		b64Seg = rest
		pathPart = "/"
	} else {
		b64Seg = rest[:slashIdx]
		pathPart = rest[slashIdx:]
	}

	// Decode the base64 origin
	originBytes, err := base64.RawURLEncoding.DecodeString(b64Seg)
	if err != nil {
		originBytes, err = base64.StdEncoding.DecodeString(b64Seg)
		if err != nil {
			return fallbackOrigin + "/"
		}
	}

	return string(originBytes) + pathPart
}
