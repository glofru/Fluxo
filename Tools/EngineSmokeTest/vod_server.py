#!/usr/bin/env python3
"""Loopback-only on-demand media server for the Fluxo VOD seek checks.

Serves the files of a media directory, bound to 127.0.0.1 only, the way IPTV panels serve movies:
  /<file>                         the file (e.g. /h264.mkv)
  /movie/user/pass/<file>         Xtream Codes style path (also /series/..., /live/... and /user/pass/<file>)
  /movie/user/pass/<stem>         the same without extension (content type from the file)
  /play.php?stream=<file>         a PHP style endpoint
  /norange/...                    any of the above without byte range support (200 with the whole body)
  /slow/<kbps>/...                any of the above throttled to <kbps> kilobytes per second
  /lat/<ms>/...                   any of the above answered after <ms> milliseconds (the round trips and the time to
                                  first byte of a phone on Wi-Fi far from the server; e.g. /lat/250/slow/2500/...)
  /oneconn/...                    any of the above with one connection per account, as IPTV panels limit it: a new
                                  request ends the response still being sent (the newest connection wins)
  /busy/...                       one connection per account, the other way: a request while a response is still
                                  being sent is refused (403, "maximum connections reached")
  /status/<code>/...              always answers <code> (a dead channel: 403 for an expired account, 404, 5xx)
  /seekdelay/<ms>/...             a request for a byte range that does not start at 0 (a seek) is answered after
                                  <ms> milliseconds, the first byte of the file at once (a server slow to seek)
Range requests get 206 with Content-Range unless the path starts with /norange.
"""
import argparse
import os
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HOST = "127.0.0.1"
TYPES = {".mp4": "video/mp4", ".mkv": "video/x-matroska", ".ts": "video/mp2t", ".m3u8": "application/vnd.apple.mpegurl",
         ".avi": "video/x-msvideo", ".webm": "video/webm"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    root = "."
    # /oneconn: the latest response of each file (an account plays one file at a time).
    generations = {}
    # /busy: files with a response being sent.
    busy = set()
    lock = threading.Lock()

    def log_message(self, fmt, *args):
        print("[vod-server] " + (fmt % args), flush=True)

    def resolve(self):
        parts = urlsplit(self.path)
        path = parts.path
        ranges, rate = True, None
        self.latency = 0.0
        self.status = None
        self.seek_delay = 0.0
        self.one_connection = False
        self.refuses_second = False
        while True:
            if path.startswith("/busy/"):
                self.refuses_second, path = True, path[len("/busy"):]
                continue
            if path.startswith("/oneconn/"):
                self.one_connection, path = True, path[len("/oneconn"):]
                continue
            if path.startswith("/norange/"):
                ranges, path = False, path[len("/norange"):]
                continue
            m = re.match(r"^/status/(\d{3})(/.*)$", path)
            if m:
                self.status, path = int(m.group(1)), m.group(2)
                continue
            m = re.match(r"^/seekdelay/(\d+)(/.*)$", path)
            if m:
                self.seek_delay, path = int(m.group(1)) / 1000.0, m.group(2)
                continue
            m = re.match(r"^/lat/(\d+)(/.*)$", path)
            if m:
                self.latency, path = int(m.group(1)) / 1000.0, m.group(2)
                continue
            m = re.match(r"^/slow/(\d+)(/.*)$", path)
            if m:
                rate, path = int(m.group(1)) * 1024, m.group(2)
                continue
            break
        if path.endswith(".php"):
            name = parse_qs(parts.query).get("stream", [""])[0]
        else:
            name = path
            m = re.match(r"^/(?:(?:movie|series|live)/)?[^/]+/[^/]+/(.+)$", path)
            if m:
                name = m.group(1)
        name = name.lstrip("/")
        if ".." in name:
            return None, ranges, rate
        full = os.path.join(self.root, name)
        if not os.path.isfile(full):
            for candidate in sorted(os.listdir(os.path.dirname(full) or self.root)):
                stem, _ = os.path.splitext(candidate)
                if stem == os.path.basename(name):
                    full = os.path.join(os.path.dirname(full), candidate)
                    break
        return (full if os.path.isfile(full) else None), ranges, rate

    def do_HEAD(self):
        self.handle_request(head=True)

    def do_GET(self):
        self.handle_request(head=False)

    def handle_request(self, head):
        full, ranges, rate = self.resolve()
        if self.latency > 0:
            time.sleep(self.latency)
        if self.status is not None:
            self.send_response(self.status)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if full is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.refuses_second and not head:
            with Handler.lock:
                refused = full in Handler.busy
                if not refused:
                    Handler.busy.add(full)
            if refused:
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                self.send_file(full, ranges, rate, head)
            finally:
                with Handler.lock:
                    Handler.busy.discard(full)
            return
        self.send_file(full, ranges, rate, head)

    def send_file(self, full, ranges, rate, head):
        size = os.path.getsize(full)
        start, end = 0, size - 1
        status = 200
        header = self.headers.get("Range")
        if ranges and header:
            m = re.match(r"bytes=(\d*)-(\d*)", header)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                elif m.group(2):
                    start = max(0, size - int(m.group(2)))
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
        if status == 206 and start > 0 and self.seek_delay > 0:
            time.sleep(self.seek_delay)
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))
        self.send_header("Content-Length", str(end - start + 1))
        if ranges:
            self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            return
        remaining = end - start + 1
        began = time.monotonic()
        sent = 0
        generation = None
        if self.one_connection:
            with Handler.lock:
                generation = Handler.generations.get(full, 0) + 1
                Handler.generations[full] = generation
        try:
            with open(full, "rb") as f:
                f.seek(start)
                while remaining > 0:
                    if generation is not None and Handler.generations.get(full) != generation:
                        # A newer connection of the account: this one is dropped mid-response.
                        self.close_connection = True
                        self.connection.shutdown(socket.SHUT_RDWR)
                        break
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    sent += len(chunk)
                    if rate:
                        ahead = sent / rate - (time.monotonic() - began)
                        if ahead > 0:
                            time.sleep(ahead)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18930)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    Handler.root = os.path.abspath(args.root)
    server = ThreadingHTTPServer((HOST, args.port), Handler)
    server.daemon_threads = True
    print(f"[vod-server] serving {Handler.root} on http://{HOST}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
