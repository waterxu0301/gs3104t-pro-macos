"""Local HTTP server: static web frontend + JSON API. Binds 127.0.0.1 only."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .api import Api

WEB_DIR = Path(__file__).resolve().parent.parent / 'framework' / 'web'


class Handler(BaseHTTPRequestHandler):
    api: Api = None

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/':
            path = '/index.html'
        target = (WEB_DIR / path.lstrip('/')).resolve()
        if not str(target).startswith(str(WEB_DIR.resolve())) or not target.is_file():
            self.send_error(404)
            return
        types = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
                 '.css': 'text/css; charset=utf-8', '.png': 'image/png',
                 '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml'}
        body = target.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', types.get(target.suffix, 'application/octet-stream'))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/api':
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', 0))
        try:
            request = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError) as e:
            response = {'api_version': 2, 'id': None, 'ok': False,
                        'error': {'code': 'invalid_json', 'message': str(e),
                                  'may_have_partial_changes': False}}
        else:
            response = self.api.dispatch(request)
        body = json.dumps(response, ensure_ascii=False).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


class ReusableServer(ThreadingHTTPServer):
    allow_reuse_address = True


def serve(host='127.0.0.1', port=8340, api=None):
    Handler.api = api or Api()
    server = ReusableServer((host, port), Handler)
    print(f'GANSS 驱动框架已启动: http://{host}:{port}/  (Ctrl+C 退出)')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
