#!/usr/bin/env python3
"""GitHub, as far as the repository Worker (linux/repo/worker.js) uses it:
release assets, each a redirect to where it is stored, as GitHub's are, and
the `packages` branch's raw files.

Usage: github.py <port> <assets> <branch>

<assets> holds each release's files as <tag>/<asset>, and <branch> the
branch's tree. While <assets>/.refuse-worker exists, it answers the Worker's
requests, which worker.mjs marks, as GitHub answers Cloudflare's addresses
over its limit: 429, try again in five minutes. Clients it sent here are
served as usual."""

import http.server
import os
import sys
import urllib.parse

port, assets, branch = int(sys.argv[1]), sys.argv[2], sys.argv[3]
RELEASES = '/hronro/ime-jd/releases/download/'
RAW = '/raw/hronro/ime-jd/packages/'
STORAGE = '/storage/'
REFUSAL = b'<!DOCTYPE html><title>Rate limit &middot; GitHub</title><h1>Access has been restricted</h1>'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._answer(body=True)

    def do_HEAD(self):
        self._answer(body=False)

    def _answer(self, body):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if self.headers.get('X-Imejd-Worker') and os.path.exists(os.path.join(assets, '.refuse-worker')):
            self.send_response(429)
            self.send_header('Retry-After', '300')
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(REFUSAL)))
            self.end_headers()
            if body:
                self.wfile.write(REFUSAL)
        elif path.startswith(RELEASES):
            self.send_response(302)
            self.send_header('Location', STORAGE + path[len(RELEASES):])
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif path.startswith(STORAGE):
            self._file(assets, path[len(STORAGE):], body)
        elif path.startswith(RAW):
            self._file(branch, path[len(RAW):], body)
        else:
            self._status(404, body)

    def _file(self, root, relative, body):
        file = os.path.realpath(os.path.join(root, relative))
        if not file.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(file):
            self._status(404, body)
            return
        with open(file, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if body:
            self.wfile.write(data)

    def _status(self, status, body):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, format, *args):
        by = 'worker' if self.headers.get('X-Imejd-Worker') else 'client'
        sys.stderr.write(f'github: {by}: ' + format % args + '\n')


http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
