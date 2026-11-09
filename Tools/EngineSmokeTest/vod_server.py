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
  /redirect/<n>/...               redirected <n> times (302) before the file: relative Location headers, then absolute
  /cookie/...                     redirected once with Set-Cookie, the file only with that cookie (tokenized panels)
  /auth/...                       Basic authentication, user "user" and password "pass" (401 otherwise)
  /flaky/<bytes>/...              every response breaks off after <bytes> bytes: the connection is shut down before
                                  the end of the body (a FIN before the Content-Length; a reset, SO_LINGER 0, is not
                                  always delivered over the loopback interface, and the client then waits its timeout)
  /to/<port>/...                  redirected (302) to the same path without /to/<port> on http://127.0.0.1:<port>
                                  (another server); /tocreds/<port>/... the same with user:pass@ in the Location
  /nocontentrange/...             206 for range requests, but without Content-Range or Accept-Ranges (malformed)
  /stall/<ms>/...                 every response stops for <ms> milliseconds after its first 256 KB (or half of it,
                                  when smaller: an HLS segment)
  /stallonce/<ms>/...             the same, only the first response for this address (query included) since the start
  /stallnth/<n>/<ms>/...          the same, only the <n>th response for a .ts file under this prefix (an HLS segment;
                                  the playlists, keys and other segments are sent at once)
  /headersonly/...                the status line and headers without Content-Type or Content-Length, then nothing for
                                  60 s (a server that hangs after answering)
  /chunked/...                    chunked transfer encoding, no Content-Length and no byte ranges (live servers)
  /icy/...                        a SHOUTcast status line ("ICY 200 OK") instead of HTTP's
Range requests get 206 with Content-Range unless the path starts with /norange or /chunked (or /nocontentrange). With --log-headers every
request's User-Agent, Range, Accept-Encoding, Cookie and Authorization headers are logged.
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
    log_headers = False
    # /oneconn: the latest response of each file (an account plays one file at a time).
    generations = {}
    # /busy: files with a response being sent.
    busy = set()
    # /stallonce: the addresses that stalled already.
    stalled = set()
    # /stallnth: the .ts responses of each prefix and directory so far.
    segment_counts = {}
    lock = threading.Lock()

    def log_message(self, fmt, *args):
        print("[vod-server] " + (fmt % args), flush=True)

    def handle(self):
        # A client that cancels a request resets its connection: not an error of the server.
        try:
            super().handle()
        except OSError:
            pass

    def redirect(self, location, cookie=None):
        self.send_response(302)
        self.send_header("Location", location)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def resolve(self):
        parts = urlsplit(self.path)
        path = parts.path
        ranges, rate = True, None
        self.latency = 0.0
        self.status = None
        self.seek_delay = 0.0
        self.one_connection = False
        self.refuses_second = False
        self.redirects = None
        self.to = None
        self.content_range = True
        self.cookie = False
        self.auth = False
        self.flaky = None
        self.stall = 0.0
        self.chunked = False
        self.icy = False
        self.headers_only = False
        stall_nth = None
        while True:
            m = re.match(r"^/redirect/(\d+)(/.*)$", path)
            if m:
                self.redirects, path = int(m.group(1)), m.group(2)
                continue
            m = re.match(r"^/to(creds)?/(\d+)(/.*)$", path)
            if m:
                self.to, path = (int(m.group(2)), m.group(1) is not None), m.group(3)
                continue
            if path.startswith("/nocontentrange/"):
                self.content_range, path = False, path[len("/nocontentrange"):]
                continue
            if path.startswith("/cookie/"):
                self.cookie, path = True, path[len("/cookie"):]
                continue
            if path.startswith("/auth/"):
                self.auth, path = True, path[len("/auth"):]
                continue
            m = re.match(r"^/flaky/(\d+)(/.*)$", path)
            if m:
                self.flaky, path = int(m.group(1)), m.group(2)
                continue
            m = re.match(r"^/stall(once)?/(\d+)(/.*)$", path)
            if m:
                with Handler.lock:
                    first = self.path not in Handler.stalled
                    Handler.stalled.add(self.path)
                if m.group(1) is None or first:
                    self.stall = int(m.group(2)) / 1000.0
                path = m.group(3)
                continue
            m = re.match(r"^/stallnth/(\d+)/(\d+)(/.*)$", path)
            if m:
                stall_nth = (int(m.group(1)), int(m.group(2)) / 1000.0, m.group(0)[:len(m.group(0)) - len(m.group(3))])
                path = m.group(3)
                continue
            if path.startswith("/headersonly/"):
                self.headers_only, path = True, path[len("/headersonly"):]
                continue
            if path.startswith("/chunked/"):
                self.chunked, ranges, path = True, False, path[len("/chunked"):]
                continue
            if path.startswith("/icy/"):
                self.icy, path = True, path[len("/icy"):]
                continue
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
        if stall_nth is not None and name.endswith(".ts"):
            key = (stall_nth[2], os.path.dirname(name))
            with Handler.lock:
                count = Handler.segment_counts.get(key, 0) + 1
                Handler.segment_counts[key] = count
            if count == stall_nth[0]:
                self.stall = stall_nth[1]
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
        if Handler.log_headers:
            print("[vod-server] headers %s user-agent=%r range=%r accept-encoding=%r cookie=%r authorization=%s icy=%r" % (
                self.path, self.headers.get("User-Agent"), self.headers.get("Range"), self.headers.get("Accept-Encoding"),
                self.headers.get("Cookie"), "yes" if self.headers.get("Authorization") else "no", self.headers.get("Icy-MetaData")), flush=True)
        full, ranges, rate = self.resolve()
        if self.redirects is not None:
            # /redirect/<n>/...: to the same path with /redirect/<n-1> (none after the last), relative for odd n and absolute
            # for even n.
            replacement = "" if self.redirects <= 1 else "/redirect/%d" % (self.redirects - 1)
            target = re.sub(r"/redirect/\d+", replacement, self.path, count=1)
            if self.redirects % 2 == 0:
                target = "http%s://%s%s" % ("s" if self.headers.get("X-Forwarded-Proto") == "https" else "", self.headers.get("Host"), target)
            self.redirect(target)
            return
        if self.to is not None:
            # /to/<port>/...: the rest of the address (query included) on another server.
            port, creds = self.to
            rest = re.sub(r"^/to(creds)?/\d+", "", self.path, count=1)
            self.redirect("http://%s127.0.0.1:%d%s" % ("user:pass@" if creds else "", port, rest))
            return
        if self.cookie and "fluxo-token=1" not in (self.headers.get("Cookie") or ""):
            self.redirect(self.path, cookie="fluxo-token=1; Path=/")
            return
        if self.auth:
            import base64
            expected = "Basic " + base64.b64encode(b"user:pass").decode()
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="fluxo"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
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
        if self.headers_only:
            # Headers without a type or a length, then nothing.
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            time.sleep(60)
            return
        if self.icy:
            # SHOUTcast's status line, which is not HTTP.
            self.wfile.write(b"ICY 200 OK\r\n")
            self.send_header("Content-Type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))
            self.send_header("icy-name", "Fluxo test")
            self.end_headers()
            self.close_connection = True
        else:
            self.send_response(status)
            self.send_header("Content-Type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))
            if self.chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(end - start + 1))
            if ranges and self.content_range:
                self.send_header("Accept-Ranges", "bytes")
            if status == 206 and self.content_range:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
        if head:
            return
        remaining = end - start + 1
        # A stall comes after 256 KB, or half of a smaller response (an HLS segment).
        stall_after = min(256 * 1024, remaining // 2)
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
                    count = min(65536, remaining)
                    if self.flaky is not None:
                        if sent >= self.flaky:
                            # Broken off before the end of the body, as a server that crashes or a network that
                            # drops it. (A shutdown, whose FIN always arrives; a reset sometimes never does over the
                            # loopback interface.)
                            self.close_connection = True
                            self.connection.shutdown(socket.SHUT_RDWR)
                            self.connection.close()
                            return
                        count = min(count, self.flaky - sent)
                    if self.stall > 0 and sent >= stall_after:
                        time.sleep(self.stall)
                        self.stall = 0
                    chunk = f.read(count)
                    if not chunk:
                        break
                    if self.chunked:
                        self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                    else:
                        self.wfile.write(chunk)
                    remaining -= len(chunk)
                    sent += len(chunk)
                    if rate:
                        ahead = sent / rate - (time.monotonic() - began)
                        if ahead > 0:
                            time.sleep(ahead)
            if self.chunked and remaining == 0:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18930)
    parser.add_argument("--root", required=True)
    parser.add_argument("--log-headers", action="store_true")
    args = parser.parse_args()
    Handler.root = os.path.abspath(args.root)
    Handler.log_headers = args.log_headers
    server = ThreadingHTTPServer((HOST, args.port), Handler)
    server.daemon_threads = True
    print(f"[vod-server] serving {Handler.root} on http://{HOST}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
