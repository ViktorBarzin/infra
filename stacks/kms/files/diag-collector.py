import json
from http.server import BaseHTTPRequestHandler, HTTPServer

MAX = 16384

class Handler(BaseHTTPRequestHandler):
    def _respond(self, code):
        self.send_response(code)
        self.send_header('Content-Length', '0')
        self.end_headers()
    def do_POST(self):
        if self.path.rstrip('/') != '/diag':
            self._respond(404); return
        try:
            n = int(self.headers.get('Content-Length', 0) or 0)
            n = min(n, MAX) if n > 0 else 0
            raw = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
            obj = json.loads(raw) if raw.strip() else {}
            if not isinstance(obj, dict):
                obj = {'_raw': str(obj)[:1000]}
            ip = self.headers.get('X-Forwarded-For', self.client_address[0]).split(',')[0].strip()
            obj['_ip'] = ip
            print('KMSDIAG ' + json.dumps(obj, separators=(',', ':'))[:MAX], flush=True)
        except Exception as e:
            print('KMSDIAG_ERR ' + repr(e)[:500], flush=True)
        self._respond(204)
    def do_GET(self):
        self._respond(200 if self.path.rstrip('/') in ('/healthz', '/diag') else 404)
    def log_message(self, *a):
        pass

if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 9102), Handler).serve_forever()
