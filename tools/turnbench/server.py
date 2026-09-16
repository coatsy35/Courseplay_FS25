"""Loopback-only, read-only test bench. Run from any working directory."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import traceback

from engine import ROOT, SOURCES, compare, implement_catalogue

STATIC = Path(__file__).resolve().parent / 'web'
SLOTS = threading.BoundedSemaphore(2)
FILES = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'),
         '/captures': ('captures.html', 'text/html'), '/captures.js': ('captures.js', 'text/javascript'),
         '/captures.css': ('captures.css', 'text/css'),
         '/style.css': ('style.css', 'text/css'), '/lucide.min.js': ('lucide.min.js', 'text/javascript')}


class ModelSourceError(RuntimeError):
    """A running server has lost files, for example after a Git branch switch."""


def validate_model_sources():
    missing = [name for name in SOURCES if not (ROOT / name).is_file()]
    if missing:
        raise ModelSourceError(
            'Bench source files are missing: ' + ', '.join(missing) +
            '. Restart the server from the dedicated codex/turnbench checkout.')


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, mime='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', mime + '; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def local_request(self):
        host = self.headers.get('Host', '')
        valid = host in (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}')
        origin = self.headers.get('Origin')
        if not valid or (origin and origin != f'http://{host}'):
            self.send(403, b'{"error":"Local same-origin requests only"}')
            return False
        return True

    def do_GET(self):
        if not self.local_request():
            return
        if self.path == '/api/captures' or self.path.startswith('/api/captures/'):
            from captured import catalogue, recording
            try:
                data=catalogue() if self.path=='/api/captures' else recording(self.path.removeprefix('/api/captures/'))
                self.send(200,json.dumps(data,allow_nan=False).encode())
            except ValueError as exc:
                self.send(404,json.dumps({'error':str(exc)}).encode())
            return
        if self.path == '/api/implements':
            self.send(200,json.dumps(implement_catalogue()).encode())
            return
        entry = FILES.get(self.path.split('?')[0])
        if entry is None:
            self.send(404, b'{"error":"Not found"}')
        else:
            name, mime = entry
            self.send(200, (STATIC/name).read_bytes(), mime)

    def do_POST(self):
        if not self.local_request():
            return
        if self.path != '/api/simulate':
            self.send(404, b'{"error":"Not found"}')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 8192 or self.headers.get('Content-Type') != 'application/json':
                raise ValueError('Expected a JSON scenario under 8 KB')
            data = json.loads(self.rfile.read(length))
            with SLOTS:
                validate_model_sources()
                result = compare(data)
            self.send(200, json.dumps(result, allow_nan=False).encode())
        except ModelSourceError as exc:
            self.send(409, json.dumps({'error':str(exc)}).encode())
        except (ValueError, TypeError) as exc:
            self.send(400, json.dumps({'error':str(exc)}).encode())
        except Exception:
            traceback.print_exc()
            self.send(500, b'{"error":"Lua/model execution failed. See the server log."}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    validate_model_sources()
    # Port 0 asks the OS for an available port; occupied ports are never taken over.
    with ThreadingHTTPServer(('127.0.0.1', args.port), Handler) as server:
        print(f'Turn bench: http://127.0.0.1:{server.server_port}', flush=True)
        print(f'Model source: {ROOT}', flush=True)
        server.serve_forever()
