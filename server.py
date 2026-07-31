#!/usr/bin/env python3
"""Simple HTTP server that serves webapp files and proxies Solr API requests to avoid CORS issues."""

import http.server
import urllib.request
import urllib.error
import sys
import os

SOLR_BASE = os.environ.get("SOLR_BASE", "http://localhost:8983")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
# Bind to loopback by default; this process is an open proxy to Solr (including
# /solr/admin and update/delete), so don't expose it on all interfaces unless
# explicitly asked via BIND_HOST.
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")

class SolrProxyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/solr/"):
            self._proxy_to_solr()
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/solr/"):
            self._proxy_to_solr(method="POST")
        else:
            self.send_error(405, "Method Not Allowed")

    def _proxy_to_solr(self, method="GET"):
        target_url = f"{SOLR_BASE}{self.path}"
        try:
            body = None
            headers = {}
            if method == "POST":
                content_length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_length) if content_length else b""
                ct = self.headers.get("Content-Type", "application/json")
                headers["Content-Type"] = ct

            req = urllib.request.Request(target_url, data=body, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=30) as resp:
                response_data = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", len(response_data))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(response_data)
        except urllib.error.HTTPError as e:
            error_body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(error_body)
        except Exception as e:
            error_msg = str(e).encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(error_msg)

    def log_message(self, format, *args):
        # Only the request-log call passes the request line as a string in
        # args[0]; error logs (log_error) pass an HTTPStatus/int instead, so
        # guard the membership test to avoid "argument of type 'HTTPStatus'
        # is not a container" TypeErrors that crash the request handler.
        first = args[0] if args else ""
        if isinstance(first, str) and "/solr/" in first:
            super().log_message(format, *args)

if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    server = http.server.HTTPServer((BIND_HOST, PORT), SolrProxyHandler)
    print(f"   SolrSearch server running at http://{BIND_HOST}:{PORT}")
    print(f"   Proxying Solr requests to {SOLR_BASE}")
    print(f"   Press Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
