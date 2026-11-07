#!/usr/bin/env python3
"""Loopback-only test streams for the Fluxo player (see README.md, "Test streams").

Serves on 127.0.0.1 only (never another interface; the simulator shares the Mac's loopback):

  /playlist.m3u        an M3U playlist with every stream below
  /hls/live.m3u8       live HLS (2 s segments, a 2 minute DVR window), played directly by AVPlayer
  /live/test-pattern   live raw MPEG-TS over HTTP, as IPTV servers send it (the remux engine path);
  /live.ts             the same; every client gets its own real-time ffmpeg encoder, at most
                       MAX_LIVE_CLIENTS at once (more get 503, so a retry loop cannot start many encoders)
  /live/two-audio      live raw MPEG-TS with two audio tracks (English AAC, German AC-3), as DVB channels have;
                       the remux engine offers both in the Audio and Subtitles menu
  /movie/clip.mp4      a 60 s on-demand MP4 (byte ranges supported)
  /movie/clip.ts       the same clip as an on-demand MPEG-TS file
  /movie/clip.mkv      the same clip as a Matroska file (AVPlayer cannot play it: downloads convert it to MP4)
  /movie/play/42       the Matroska clip at an extensionless Xtream-style path (no type in the URL)
  /movie/tracks/…      the HLS of /tracks/ at a movie path (a movie of an Xtream-style playlist), for downloads
  /movie/slow.mp4      (or /movie/clip.mp4?slow=1) the MP4 clip sent at about 300 KB/s, so a download shows its progress, pause and resume
  /tracks/master.m3u8  a 60 s on-demand HLS with two audio renditions (English, Italiano: an audio description)
                       and two WebVTT subtitle renditions (English SDH, Italiano), for the player's Audio and
                       Subtitles menu
  /movie/tracks.mkv    a 60 s on-demand Matroska file with two audio tracks (English AAC, Italian AC-3) and
                       SubRip English, ASS Italian and forced English subtitles (the remux engine turns them into
                       HLS renditions)
  /subtitles/clip.srt  a SubRip file for the 60 s clips (Load Subtitle File…, the `subtitle-file:` debug route)
  /logo/<n>.png        a 200x120 gradient logo (n = 0 to 239), used by the "large" debug seed
  /poster/<n>.png      a 240x360 gradient poster

The content is synthetic (ffmpeg test patterns and a sine tone), so there is nothing to protect and no
authentication; the loopback bind is what keeps it private.
"""

import argparse
import colorsys
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HOST = "127.0.0.1"
# Real-time encoders of the raw MPEG-TS streams that may run at once.
MAX_LIVE_CLIENTS = 4

CONTENT_TYPES = {
    ".mkv": "video/x-matroska",
    ".m3u8": "application/vnd.apple.mpegurl",
    ".m3u": "audio/x-mpegurl",
    ".ts": "video/mp2t",
    ".mp4": "video/mp4",
    ".vtt": "text/vtt",
    ".srt": "application/x-subrip",
}


def log(message):
    print(f"[test-stream] {message}", flush=True)


def gradient_png(width, height, number):
    """A PNG with a vertical gradient whose hue comes from `number` (standard library only)."""
    hue = (number * 47 % 360) / 360
    top = [int(c * 255) for c in colorsys.hsv_to_rgb(hue, 0.65, 0.95)]
    bottom = [int(c * 255) for c in colorsys.hsv_to_rgb((hue + 0.08) % 1, 0.9, 0.45)]
    rows = []
    for y in range(height):
        t = y / max(1, height - 1)
        pixel = bytes(int(a + (b - a) * t) for a, b in zip(top, bottom))
        rows.append(b"\x00" + pixel * width)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


class Streams:
    """Owns the work directory, the on-demand clips and the live HLS encoder."""

    def __init__(self, ffmpeg, work, port):
        self.ffmpeg = ffmpeg
        self.work = work
        self.port = port
        self.hls_dir = os.path.join(work, "hls")
        self.clip_mp4 = os.path.join(work, "clip.mp4")
        self.clip_ts = os.path.join(work, "clip.ts")
        self.clip_mkv = os.path.join(work, "clip.mkv")
        self.tracks_dir = os.path.join(work, "tracks")
        self.tracks_mkv = os.path.join(work, "tracks.mkv")
        self.clip_srt = os.path.join(work, "clip.srt")
        self.hls_process = None
        self.stopping = threading.Event()
        self.clients = set()
        self.clients_lock = threading.Lock()

    @property
    def base_url(self):
        return f"http://{HOST}:{self.port}"

    def prepare_clips(self):
        if os.path.exists(self.clip_mp4) and os.path.exists(self.clip_ts):
            self.prepare_matroska()
            return
        log("generating the 60 s on-demand clips")
        subprocess.run(
            [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
             "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=60",
             "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=60",
             "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", "60",
             "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", self.clip_mp4],
            check=True)
        subprocess.run(
            [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", self.clip_mp4,
             "-c", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "mpegts", self.clip_ts],
            check=True)
        self.prepare_matroska()

    def prepare_matroska(self):
        """/movie/clip.mkv (and /movie/play/42): the MP4 clip remuxed to Matroska."""
        if os.path.exists(self.clip_mkv):
            return
        subprocess.run(
            [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", self.clip_mp4,
             "-c", "copy", "-f", "matroska", self.clip_mkv],
            check=True)

    def prepare_tracks(self):
        """The on-demand HLS with alternate audio and subtitles (/tracks/): the video with the English audio,
        an Italian audio-only rendition (tagged as an audio description), and one WebVTT subtitle file per
        language, each as a single-segment playlist."""
        master = os.path.join(self.tracks_dir, "master.m3u8")
        if os.path.exists(master):
            return
        log("generating the on-demand HLS with audio and subtitle renditions")
        os.makedirs(self.tracks_dir, exist_ok=True)
        common = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
        hls = ["-f", "hls", "-hls_time", "4", "-hls_playlist_type", "vod"]
        subprocess.run(
            common + ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=60",
                      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=60",
                      "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", "60",
                      "-c:a", "aac", "-b:a", "96k"] + hls
            + ["-hls_segment_filename", os.path.join(self.tracks_dir, "main-%03d.ts"), os.path.join(self.tracks_dir, "main.m3u8")],
            check=True)
        subprocess.run(
            common + ["-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=60", "-c:a", "aac", "-b:a", "96k"] + hls
            + ["-hls_segment_filename", os.path.join(self.tracks_dir, "audio-it-%03d.ts"), os.path.join(self.tracks_dir, "audio-it.m3u8")],
            check=True)
        texts = {"en": "[Music] Subtitle line {} in English", "it": "Sottotitolo {} in italiano"}
        for language, text in texts.items():
            # The MPEG-TS segments start at 1.4 s (90 kHz clock): the cues are mapped onto that timeline.
            cues = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000", ""]
            for index in range(12):
                start = index * 5
                cues += [f"00:00:{start:02d}.000 --> 00:00:{start + 4:02d}.000", text.format(index + 1), ""]
            with open(os.path.join(self.tracks_dir, f"subs-{language}.vtt"), "w") as file:
                file.write("\n".join(cues))
            with open(os.path.join(self.tracks_dir, f"subs-{language}.m3u8"), "w") as file:
                file.write("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:60\n#EXT-X-PLAYLIST-TYPE:VOD\n"
                           f"#EXTINF:60.0,\nsubs-{language}.vtt\n#EXT-X-ENDLIST\n")
        with open(master, "w") as file:
            file.write(
                "#EXTM3U\n#EXT-X-VERSION:4\n"
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES\n'
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Italiano",LANGUAGE="it",DEFAULT=NO,AUTOSELECT=YES,'
                'CHARACTERISTICS="public.accessibility.describes-video",URI="audio-it.m3u8"\n'
                '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,'
                'CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound",'
                'URI="subs-en.m3u8"\n'
                '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Italiano",LANGUAGE="it",DEFAULT=NO,AUTOSELECT=YES,'
                'URI="subs-it.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,AUDIO="aud",SUBTITLES="subs"\n'
                "main.m3u8\n")

    def prepare_tracks_matroska(self):
        """/movie/tracks.mkv and /subtitles/clip.srt."""
        if os.path.exists(self.tracks_mkv) and os.path.exists(self.clip_srt):
            return
        log("generating the Matroska clip with audio tracks and subtitles")
        english, italian, forced = (os.path.join(self.work, name) for name in ("mkv-en.srt", "mkv-it.ass", "mkv-forced.srt"))
        with open(english, "w") as file:
            for index in range(12):
                start = index * 5
                file.write(f"{index + 1}\n00:00:{start:02d},500 --> 00:00:{start + 4:02d},000\n"
                           f"<i>Matroska</i> English subtitle {index + 1}\nsecond line\n\n")
        with open(italian, "w") as file:
            file.write("[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\n"
                       "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, "
                       "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
                       "Alignment, MarginL, MarginR, MarginV, Encoding\n"
                       "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1\n\n"
                       "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
            for index in range(12):
                start = index * 5
                file.write(f"Dialogue: 0,0:00:{start:02d}.50,0:00:{start + 4:02d}.00,Default,,0,0,0,,"
                           f"Sottotitolo {{\\i1}}Matroska{{\\i0}} {index + 1}\\Nin italiano\n")
        with open(forced, "w") as file:
            file.write("1\n00:00:02,000 --> 00:00:04,000\n[SIGN: forced]\n")
        subprocess.run(
            [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
             "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=60",
             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=60",
             "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=60",
             "-i", english, "-i", italian, "-i", forced,
             "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3", "-map", "4", "-map", "5",
             "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", "60",
             "-c:a:0", "aac", "-b:a:0", "128k", "-c:a:1", "ac3", "-b:a:1", "192k",
             "-c:s:0", "srt", "-c:s:1", "ass", "-c:s:2", "srt",
             "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=ita",
             "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=ita", "-metadata:s:s:2", "language=eng",
             # A title that ends in a multi-byte character: the master playlist keeps it whole (NAME, and so the
             # names a Chromecast receiver shows; the player's menu shows the language's own name).
             "-metadata:s:s:1", "title=Italiano – Novità",
             "-disposition:a:0", "default", "-disposition:a:1", "0", "-disposition:s:0", "0", "-disposition:s:1", "0",
             "-disposition:s:2", "forced", self.tracks_mkv],
            check=True)
        with open(self.clip_srt, "w", encoding="utf-8") as file:
            for index in range(15):
                start = index * 4
                # Even cues: an entity that stays text ("&amp;lt;" is "&lt;"), then a blank line holding
                # spaces and a tab, as files from the wild have: each cue stays on its own.
                text = "Fish &amp; chips, &amp;lt;b&amp;gt; is text" if index % 2 else "<i>Fluxo test clip</i>"
                separator = " \t\n" if index % 2 else "\n"
                file.write(f"{index + 1}\n00:00:{start:02d},200 --> 00:00:{start + 3:02d},600\n"
                           f"External subtitle {index + 1}, from a <b>.srt</b> file\n{text}\n{separator}")

    def check_files(self):
        """Fails at startup when a file the server advertises is missing, rather than with a 404 in the middle of a
        test (a missing clip once hid every Matroska download test)."""
        advertised = {
            "/movie/clip.mp4": self.clip_mp4,
            "/movie/clip.ts": self.clip_ts,
            "/movie/clip.mkv": self.clip_mkv,
            "/tracks/master.m3u8": os.path.join(self.tracks_dir, "master.m3u8"),
            "/movie/tracks.mkv": self.tracks_mkv,
            "/subtitles/clip.srt": self.clip_srt,
        }
        missing = [path for path, file in advertised.items() if not os.path.isfile(file) or os.path.getsize(file) == 0]
        if missing:
            raise SystemExit(f"test_stream_server: not generated: {', '.join(missing)}")

    def live_input_arguments(self, pattern):
        return ["-re", "-f", "lavfi", "-i", f"{pattern}=size=1280x720:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-pix_fmt", "yuv420p",
                "-g", "60", "-b:v", "2500k", "-c:a", "aac", "-b:a", "128k"]

    def start_hls(self):
        shutil.rmtree(self.hls_dir, ignore_errors=True)
        os.makedirs(self.hls_dir)
        threading.Thread(target=self._run_hls, daemon=True).start()

    def _run_hls(self):
        # Restarted if it ever exits, so a long session keeps a live stream.
        while not self.stopping.is_set():
            command = [self.ffmpeg, "-hide_banner", "-loglevel", "error"] + self.live_input_arguments("testsrc2") + [
                "-f", "hls", "-hls_time", "2", "-hls_list_size", "60",
                "-hls_flags", "delete_segments+omit_endlist+program_date_time",
                "-hls_segment_filename", os.path.join(self.hls_dir, "seg-%05d.ts"),
                os.path.join(self.hls_dir, "live.m3u8")]
            self.hls_process = subprocess.Popen(command, stdin=subprocess.DEVNULL)
            self.hls_process.wait()
            if not self.stopping.is_set():
                log("the HLS encoder exited; restarting it")
                time.sleep(1)

    def playlist(self):
        base = self.base_url
        entries = [
            ("Test Pattern (HLS)", "Test Streams", f"{base}/hls/live.m3u8"),
            ("Test Pattern (MPEG-TS)", "Test Streams", f"{base}/live/test-pattern"),
            ("Test Clip (MP4)", "Test On Demand", f"{base}/movie/clip.mp4"),
            ("Test Clip (MPEG-TS)", "Test On Demand", f"{base}/movie/clip.ts"),
            ("Test Clip (Audio and Subtitles)", "Test On Demand", f"{base}/tracks/master.m3u8"),
            ("Test Clip (Matroska Tracks)", "Test On Demand", f"{base}/movie/tracks.mkv"),
            ("Test Pattern (Two Audio Tracks)", "Test Streams", f"{base}/live/two-audio"),
        ]
        lines = ["#EXTM3U"]
        for name, group, url in entries:
            lines.append(f'#EXTINF:-1 tvg-id="FluxoTest.test" tvg-name="{name}" group-title="{group}",{name}')
            lines.append(url)
        return ("\n".join(lines) + "\n").encode()

    def open_live_encoder(self, two_audio=False):
        """A new real-time encoder, or None when MAX_LIVE_CLIENTS are already running."""
        if two_audio:
            command = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-re",
                       "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30",
                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                       "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
                       "-map", "0:v", "-map", "1:a", "-map", "2:a",
                       "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-pix_fmt", "yuv420p",
                       "-g", "60", "-b:v", "2500k", "-c:a:0", "aac", "-b:a:0", "128k", "-c:a:1", "ac3", "-b:a:1", "192k",
                       "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=deu",
                       "-f", "mpegts", "pipe:1"]
        else:
            command = [self.ffmpeg, "-hide_banner", "-loglevel", "error"] + self.live_input_arguments("testsrc") + [
                "-f", "mpegts", "pipe:1"]
        with self.clients_lock:
            if len(self.clients) >= MAX_LIVE_CLIENTS:
                return None
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
            self.clients.add(process)
        return process

    def close_live_encoder(self, process):
        with self.clients_lock:
            self.clients.discard(process)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()

    def stop(self):
        self.stopping.set()
        if self.hls_process and self.hls_process.poll() is None:
            self.hls_process.terminate()
        with self.clients_lock:
            clients = list(self.clients)
        for process in clients:
            self.close_live_encoder(process)


class Handler(BaseHTTPRequestHandler):
    streams = None
    verbose = False
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        if self.verbose:
            log(f"{self.address_string()} {format % args}")

    def do_HEAD(self):
        self.handle_request(send_body=False)

    def do_GET(self):
        self.handle_request(send_body=True)

    def handle_request(self, send_body):
        path = urlsplit(self.path).path
        if path == "/playlist.m3u":
            self.send_bytes(self.streams.playlist(), CONTENT_TYPES[".m3u"], send_body)
        elif path in ("/live/test-pattern", "/live.ts"):
            self.send_live_ts(send_body)
        elif path == "/live/two-audio":
            self.send_live_ts(send_body, two_audio=True)
        elif path.startswith("/hls/"):
            name = path[len("/hls/"):]
            # Only plain file names of the HLS directory.
            if not re.fullmatch(r"[A-Za-z0-9_-]+\.(m3u8|ts)", name):
                self.send_error(404)
                return
            self.send_file(os.path.join(self.streams.hls_dir, name), send_body, cacheable=name.endswith(".ts"))
        elif path.startswith("/tracks/") or path.startswith("/movie/tracks/"):
            name = path.split("/tracks/", 1)[1]
            # Only plain file names of the tracks directory.
            if not re.fullmatch(r"[A-Za-z0-9_-]+\.(m3u8|ts|vtt)", name):
                self.send_error(404)
                return
            self.send_file(os.path.join(self.streams.tracks_dir, name), send_body, cacheable=not name.endswith(".m3u8"))
        elif re.fullmatch(r"/(logo|poster)/\d{1,3}\.png", path):
            kind, number = path[1:-len(".png")].split("/")
            size = (200, 120) if kind == "logo" else (240, 360)
            self.send_bytes(gradient_png(size[0], size[1], int(number)), "image/png", send_body, cache="max-age=3600")
        elif path == "/movie/clip.mp4":
            # "?slow=1" sends it like /movie/slow.mp4 (a series episode whose download shows its progress).
            slow = "slow=1" in (urlsplit(self.path).query or "")
            self.send_file(self.streams.clip_mp4, send_body, cacheable=not slow, bytes_per_second=300 * 1024 if slow else None)
        elif path == "/movie/clip.ts":
            self.send_file(self.streams.clip_ts, send_body, cacheable=True)
        elif path in ("/movie/clip.mkv", "/movie/play/42"):
            self.send_file(self.streams.clip_mkv, send_body, cacheable=True)
        elif path == "/movie/slow.mp4":
            self.send_file(self.streams.clip_mp4, send_body, cacheable=False, bytes_per_second=300 * 1024)
        elif path == "/movie/tracks.mkv":
            self.send_file(self.streams.tracks_mkv, send_body, cacheable=True)
        elif path == "/subtitles/clip.srt":
            self.send_file(self.streams.clip_srt, send_body, cacheable=True)
        else:
            self.send_error(404)

    def send_bytes(self, body, content_type, send_body, cache="no-store"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def send_live_ts(self, send_body, two_audio=False):
        process = None
        if send_body:
            process = self.streams.open_live_encoder(two_audio=two_audio)
            if process is None:
                log(f"refused a live MPEG-TS client: {MAX_LIVE_CLIENTS} encoders are already running")
                self.send_response(503)
                self.send_header("Retry-After", "5")
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return
        try:
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPES[".ts"])
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            while process is not None:
                chunk = process.stdout.read1(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            if process is not None:
                self.streams.close_live_encoder(process)

    def send_file(self, file_path, send_body, cacheable, bytes_per_second=None):
        try:
            size = os.path.getsize(file_path)
            handle = open(file_path, "rb")
        except OSError:
            self.send_error(404)
            return
        with handle:
            start, end = 0, size - 1
            status = 200
            range_header = self.headers.get("Range")
            if range_header:
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
                if not match or (not match.group(1) and not match.group(2)):
                    self.send_error(416)
                    return
                if match.group(1):
                    start = int(match.group(1))
                    if match.group(2):
                        end = min(int(match.group(2)), size - 1)
                else:
                    # A suffix range: the last n bytes.
                    start = max(0, size - int(match.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
            length = end - start + 1
            extension = os.path.splitext(file_path)[1]
            self.send_response(status)
            self.send_header("Content-Type", CONTENT_TYPES.get(extension, "application/octet-stream"))
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "max-age=60" if cacheable else "no-store")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if not send_body:
                return
            handle.seek(start)
            remaining = length
            try:
                chunk_size = min(256 * 1024, bytes_per_second // 4) if bytes_per_second else 256 * 1024
                while remaining > 0:
                    chunk = handle.read(min(chunk_size, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    if bytes_per_second:
                        time.sleep(len(chunk) / bytes_per_second)
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass


class LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--work", required=True, help="work directory for the clips and the HLS segments")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    arguments = parser.parse_args()

    os.makedirs(arguments.work, exist_ok=True)
    streams = Streams(arguments.ffmpeg, arguments.work, arguments.port)
    streams.prepare_clips()
    streams.prepare_tracks()
    streams.prepare_tracks_matroska()
    streams.check_files()
    streams.start_hls()

    Handler.streams = streams
    Handler.verbose = arguments.verbose
    server = LoopbackServer((HOST, arguments.port), Handler)

    def shut_down(signum, frame):
        streams.stop()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shut_down)
    signal.signal(signal.SIGINT, shut_down)
    log(f"serving {streams.base_url}/playlist.m3u (loopback only)")
    try:
        server.serve_forever()
    finally:
        streams.stop()
        server.server_close()
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
