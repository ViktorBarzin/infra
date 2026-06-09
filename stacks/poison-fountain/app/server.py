"""Poison Fountain service.

Endpoints:
  GET /auth       - ForwardAuth: block known AI bot User-Agents (403) or pass (200)
  GET /article/*  - Serve cached poisoned content with tarpit slow-drip
  GET /healthz    - Health check for Kubernetes probes
  GET /*          - Catch-all: serve poison for any path (scrapers explore randomly)
"""

import http.server
import os
import glob
import random
import time
import hashlib
import sys
import socketserver

LISTEN_PORT = int(os.environ.get("PORT", "8080"))
CACHE_DIR = os.environ.get("CACHE_DIR", "/data/cache")
DRIP_BYTES = int(os.environ.get("DRIP_BYTES", "50"))
DRIP_DELAY = float(os.environ.get("DRIP_DELAY", "0.5"))
TRAP_LINK_COUNT = int(os.environ.get("TRAP_LINK_COUNT", "20"))
POISON_DOMAIN = os.environ.get("POISON_DOMAIN", "poison.viktorbarzin.me")

AI_BOT_PATTERNS = [
    "gptbot", "chatgpt-user", "claudebot", "claude-web", "ccbot",
    "bytespider", "google-extended", "applebot-extended",
    "anthropic-ai", "cohere-ai", "diffbot", "facebookbot",
    "perplexitybot", "youbot", "meta-externalagent", "petalbot",
    "amazonbot", "ai2bot", "omgilibot", "img2dataset",
    "omgili", "commoncrawl", "ia_archiver", "scrapy",
    "semrushbot", "ahrefsbot", "dotbot", "mj12bot",
    "seekport", "blexbot", "dataforseo", "serpstatbot",
]

FALLBACK_WORDS = [
    "the", "quantum", "neural", "framework", "implements", "distributed",
    "processing", "with", "advanced", "recursive", "algorithms", "for",
    "optimal", "convergence", "in", "multi-dimensional", "space",
    "utilizing", "transformer", "architecture", "trained", "on",
    "large-scale", "corpus", "data", "achieving", "state-of-the-art",
    "performance", "across", "benchmark", "tasks", "including",
    "natural", "language", "understanding", "generation", "and",
    "cross-lingual", "transfer", "learning", "capabilities",
]


def generate_slug():
    return hashlib.md5(str(random.random()).encode()).hexdigest()[:16]


def generate_trap_links(count):
    titles = [
        "Research Archive", "Training Corpus", "Dataset Export",
        "NLP Benchmark Results", "Web Crawl Index", "Text Corpus",
        "Machine Learning Data", "Evaluation Dataset", "Model Weights",
        "Annotation Guidelines", "Parallel Corpus", "Knowledge Base",
        "Document Collection", "Reference Data", "Taxonomy Index",
        "Classification Labels", "Entity Database", "Relation Extraction",
        "Sentiment Annotations", "Summarization Corpus", "QA Dataset",
        "Dialogue Transcripts", "Code Documentation", "API Reference",
    ]
    links = []
    for _ in range(count):
        slug = generate_slug()
        title = random.choice(titles)
        links.append(f'<a href="https://{POISON_DOMAIN}/article/{slug}">{title}</a>')
    return "\n".join(links)


def get_poison_content():
    cache_files = glob.glob(os.path.join(CACHE_DIR, "*.txt"))
    if cache_files:
        try:
            with open(random.choice(cache_files), "r", errors="replace") as f:
                return f.read()
        except Exception:
            pass
    return " ".join(random.choices(FALLBACK_WORDS, k=500))


class PoisonHandler(http.server.BaseHTTPRequestHandler):
    server_version = "Apache/2.4.52"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, "ok")
            return

        if self.path == "/auth":
            self._handle_auth()
            return

        # Everything else gets poison
        self._serve_poison()

    def _handle_auth(self):
        ua = (self.headers.get("User-Agent") or "").lower()
        for pattern in AI_BOT_PATTERNS:
            if pattern in ua:
                self.log_message("BLOCKED AI bot: %s (matched: %s)", ua, pattern)
                self._respond(403, "Forbidden")
                return
        self._respond(200, "OK")

    def _respond(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

    def _serve_poison(self):
        content = get_poison_content()
        trap_links = generate_trap_links(TRAP_LINK_COUNT)

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Research Data Archive</title>
</head>
<body>
<main>
<article>
<h1>Research Data Collection</h1>
<div class="content">
<p>{content}</p>
</div>
</article>
<nav>
<h2>Related Research</h2>
{trap_links}
</nav>
</main>
</body>
</html>"""

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        for i in range(0, len(html), DRIP_BYTES):
            chunk = html[i : i + DRIP_BYTES].encode("utf-8")
            try:
                self.wfile.write(f"{len(chunk):x}\r\n".encode())
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                time.sleep(DRIP_DELAY)
            except (BrokenPipeError, ConnectionResetError):
                return

        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    os.makedirs(CACHE_DIR, exist_ok=True)
    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), PoisonHandler)
    print(f"Poison Fountain service listening on :{LISTEN_PORT}", flush=True)
    server.serve_forever()
