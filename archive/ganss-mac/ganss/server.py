"""Local HTTP server: static frontend + /api JSON endpoint. macOS local use."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .api import dispatch

WEB_DIR = Path(__file__).resolve().parent.parent / 'web'


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', 'http://127.0.0.1:*')
        self.send_header('Cache-Control', 'no-store')

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
        self.send_response(200)
        self.send_header('Content-Type', types.get(target.suffix, 'application/octet-stream'))
        self._cors()
        body = target.read_bytes()
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
            response = dispatch(request)
        except (json.JSONDecodeError, ValueError) as e:
            response = {'api_version': 1, 'id': None, 'ok': False,
                        'error': {'code': 'invalid_json', 'message': str(e),
                                  'may_have_partial_changes': False}}
        body = json.dumps(response, ensure_ascii=False).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self._cors()
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 8340), Handler)
    print('GANSS GS3104T PRO 本地驱动已启动: http://127.0.0.1:8340/  (Ctrl+C 退出)')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
