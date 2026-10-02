#!/usr/bin/env python3
"""Exercise the real MCP restricted loader with local, positively verified controls."""

import argparse
import base64
import hashlib
import html
import http.server
import http.client
import ipaddress
import io
import json
import os
from pathlib import Path
import queue
import re
import shutil
import shlex
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
import zlib
from urllib.parse import parse_qs, urlencode, urlsplit


REPO = Path(__file__).resolve().parent.parent
OPTIONS = None


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def eventually(probe, timeout, description):
    deadline = time.monotonic() + timeout
    while True:
        value = probe()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out: " + description)
        time.sleep(0.05)


def png_first_pixel(image):
    require(image[:8] == b"\x89PNG\r\n\x1a\n", "Screenshot is not PNG")
    width, height, depth, color, compression, filtering, interlace = struct.unpack("!IIBBBBB", image[16:29])
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    require(depth == 8 and channels and compression == filtering == interlace == 0,
            "Screenshot PNG has an unsupported pixel format")
    compressed, offset = [], 8
    while offset < len(image):
        length = struct.unpack("!I", image[offset:offset + 4])[0]
        if image[offset + 4:offset + 8] == b"IDAT":
            compressed.append(image[offset + 8:offset + 8 + length])
        offset += length + 12
    # Every PNG filter predicts zero at the first pixel in the first row.
    row = zlib.decompressobj().decompress(b"".join(compressed), 1 + channels)
    require(len(row) == 1 + channels and row[0] <= 4, "Screenshot PNG has no valid first pixel")
    rgb = tuple(row[1:4]) if color in (2, 6) else (row[1],) * 3
    alpha = row[channels] if color in (4, 6) else 255
    return width, height, (*rgb, alpha)


class HTTPFixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("0.0.0.0", 0), HTTPHandler)
        self.events = []
        self.assets = {}
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path, host="127.0.0.1", **query):
        suffix = "?" + urlencode(query, doseq=True) if query else ""
        return "http://%s:%d%s%s" % (host, self.server_port, path, suffix)

    def matching(self, path, method=None):
        with self.lock:
            return [event for event in self.events
                    if event["path"] == path and (method is None or event["method"] == method)]

    def asset(self, path, payload, content_type, status=200, headers=()):
        with self.lock:
            self.assets[path] = (payload, content_type, status, headers)

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=3)


class HTTPHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.respond()

    def do_HEAD(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def do_PUT(self):
        self.respond()

    def do_OPTIONS(self):
        self.respond()

    def respond(self):
        self.connection.settimeout(5)
        parsed = urlsplit(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with self.server.lock:
            self.server.events.append(dict(path=parsed.path, method=self.command,
                                           headers=dict(self.headers.items()), body=body))
        if self.headers.get("Upgrade", "").lower() == "websocket":
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.wfile.write(b"\x88\x02\x03\xe8")
            self.wfile.flush()
            self.close_connection = True
            return
        query = parse_qs(parsed.query)
        content_type = "text/plain; charset=utf-8"
        payload = b"fixture-ok"
        if parsed.path.endswith(".js"):
            content_type = "application/javascript"
            payload = (b"self.addEventListener('install', () => self.skipWaiting());"
                       b"self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));")
            if "marker" in query:
                payload = ("globalThis[%s]=true;" % json.dumps(query["marker"][0])).encode()
            if query.get("worker") == ["1"]:
                payload = b"postMessage('worker-ok');"
        elif parsed.path.endswith(".css"):
            content_type = "text/css"
            payload = b"body{--cdn-control:applied}"
        elif parsed.path.endswith(".wav"):
            content_type = "audio/wav"
            samples = b"\0\0" * 8000
            payload = (b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVEfmt " +
                       struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16) +
                       b"data" + struct.pack("<I", len(samples)) + samples)
        elif parsed.path.endswith(".png"):
            content_type = "image/png"
            payload = base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")
        elif "/page/" in parsed.path:
            content_type = "text/html; charset=utf-8"
            links = "".join('<link rel="%s" href="%s"%s>' % (
                rel, html.escape(query[rel][0], quote=True),
                ' crossorigin="anonymous"' if rel == "preconnect" else "")
                for rel in ("icon", "prefetch", "preconnect", "dns-prefetch") if rel in query)
            payload = ("""<!doctype html><html><head><meta charset="utf-8">
<title>Untrusted integration fixture</title>""" + links + """
<style>body{background:white;color:black}button{padding:16px;margin:16px}
@media(prefers-color-scheme:dark){body{background:rgb(17,17,17);color:white}}
@media(prefers-reduced-motion:reduce){body{--motion:reduce}}
</style><script>
window.firstDocument = {
  dark:matchMedia('(prefers-color-scheme: dark)').matches,
  light:matchMedia('(prefers-color-scheme: light)').matches,
  reduce:matchMedia('(prefers-reduced-motion: reduce)').matches,
  noPreference:matchMedia('(prefers-reduced-motion: no-preference)').matches,
  dpr:devicePixelRatio, width:innerWidth, height:innerHeight
};
window.trustedEvents = [];
function popup(event) {
  trustedEvents.push(event.isTrusted);
  window.popupResult = !!window.open('/popup-target', '_blank');
}
function download(event) {
  trustedEvents.push(event.isTrusted);
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob(['untrusted-download-control']));
  a.download = 'fixture-download.txt'; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}
</script></head><body><h1>Fixture ready</h1>
<button onclick="popup(event)">Open popup</button>
<button onclick="download(event)">Download blob</button>
</body></html>""").encode()
        with self.server.lock:
            asset = self.server.assets.get(parsed.path)
        status, extra_headers = 200, ()
        if asset:
            payload, content_type, status, extra_headers = asset
        content_type = query.get("mime", [content_type])[0]
        status = int(query.get("status", [status])[0])
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for origin in query.get("acao", ["*"]):
            if origin != "none":
                self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Range, Content-Type, X-Rig-Header, Upgrade-Insecure-Requests")
        self.send_header("Access-Control-Expose-Headers", "X-Fixture-Secret")
        self.send_header("X-Fixture-Secret", "header-secret")
        if "location" in query:
            self.send_header("Location", query["location"][0])
        for name, value in extra_headers:
            self.send_header(name, value)
        self.send_header("Service-Worker-Allowed", "/")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.close_connection = True


class PacketFixture:
    """Count actual UDP packets or TCP accepts without relying on browser-side claims."""

    def __init__(self, udp=False):
        self.udp = udp
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        if not udp:
            self.sock.listen(16)
        self.sock.settimeout(0.1)
        self.lock = threading.Lock()
        self.packets = []
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            try:
                if self.udp:
                    data, peer = self.sock.recvfrom(65535)
                    with self.lock:
                        self.packets.append(data)
                    # Answer a real RFC 5389 binding request, not just any UDP traffic.
                    if len(data) >= 20 and data[:2] == b"\x00\x01" and data[4:8] == b"\x21\x12\xa4\x42":
                        address = struct.unpack("!I", socket.inet_aton(peer[0]))[0] ^ 0x2112A442
                        attr = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, peer[1] ^ 0x2112, address)
                        self.sock.sendto(struct.pack("!HH", 0x0101, len(attr)) + data[4:20] + attr, peer)
                else:
                    conn, _ = self.sock.accept()
                    with self.lock:
                        self.packets.append(b"accept")
                    conn.close()
            except socket.timeout:
                continue
            except OSError:
                if not self.stopping.is_set():
                    raise

    def count(self):
        with self.lock:
            return len(self.packets)

    def close(self):
        self.stopping.set()
        self.thread.join(timeout=2)
        self.sock.close()


def process_info(pid):
    """Read a PID identity including start time so cleanup cannot signal a reused PID."""
    try:
        directory = Path("/proc") / str(pid)
        stat = (directory / "stat").read_text()
        fields = stat[stat.rfind(")") + 2:].split()
        argv = [os.fsdecode(arg) for arg in (directory / "cmdline").read_bytes().split(b"\0") if arg]
        return dict(pid=pid, state=fields[0], ppid=int(fields[1]), start=fields[19], argv=argv,
                    comm=stat[stat.find("(") + 1:stat.rfind(")")])
    except (OSError, ValueError, IndexError):
        return None


def private_root(argv):
    if "--untrusted" not in argv:
        return None
    root = None
    for index, arg in enumerate(argv):
        if arg == "--untrusted-root" and index + 1 < len(argv):
            root = argv[index + 1]
        elif arg.startswith("--untrusted-root="):
            root = arg.split("=", 1)[1]
    # Roots live under the launcher's runtime dir: <runtime>/sketerm/u/<16 hex>.
    return Path(root) if root and re.fullmatch(r"(/[^/\0]+)+/sketerm/u/[0-9a-f]{16}", root) \
        and ".." not in Path(root).parts else None


def same_process(info):
    current = process_info(info["pid"])
    return current if current and current["start"] == info["start"] else None


class MCP:
    def __init__(self, root, command, helper, timeout, env_overrides=None, helper_args=()):
        self.root = root
        self.timeout = timeout
        self.request_id = 0
        self.unusable = None
        self.expected_exit = 0
        self.responses = queue.Queue()
        self.known = {}
        self.roots = {}
        self.process_history = {}
        self.saved_logs = {}
        self.helper_diagnostics = {}
        self.history = []
        self.proc_lock = threading.Lock()
        self.stopping = threading.Event()
        self.stderr_path = root / "mcp-stderr.log"
        self.stderr = self.stderr_path.open("wb")
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("SKETERM_", "XDG_")) and key not in (
                   "DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "XAUTHORITY", "PULSE_SERVER",
                   "DBUS_SESSION_BUS_ADDRESS", "http_proxy", "https_proxy", "all_proxy",
                   "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "no_proxy")}
        for key, leaf in (("HOME", "h"), ("XDG_CONFIG_HOME", "c"), ("XDG_STATE_HOME", "s"),
                          ("XDG_RUNTIME_DIR", "r"), ("XDG_CACHE_HOME", "k"),
                          ("XDG_DATA_HOME", "d"), ("TMPDIR", "t")):
            path = root / leaf
            path.mkdir(mode=0o700)
            env[key] = str(path)
        self.downloads = root / "downloads"
        self.downloads.mkdir(mode=0o700)
        (root / "c/user-dirs.dirs").write_text('XDG_DOWNLOAD_DIR="%s"\n' % self.downloads)
        if helper_args:
            wrapper = root / "helper-wrapper"
            wrapper.write_text("#!/bin/sh\nexec %s %s \"$@\"\n" % (
                shlex.quote(str(helper)), " ".join(shlex.quote(arg) for arg in helper_args)))
            wrapper.chmod(0o700)
            helper = wrapper
        env.update(SKETERM_WEB_BIN=str(helper), SKETERM_WEB_SESSION="0",
                   SKETERM_WEB_BROKER_ENGINE="0", SKETERM_WEB_OZONE="headless",
                   SKETERM_WEB_GPU="0", LIBGL_ALWAYS_SOFTWARE="1", SKETERM_MCP_WEB_GUI="0",
                   NO_PROXY="*", no_proxy="*", XDG_CONFIG_DIRS=str(root / "c"),
                    XDG_DATA_DIRS=str(root / "d"))
        env.update(env_overrides or {})
        self.life_read, self.life_write = os.pipe()
        env["SKETERM_MUX_LIFETIME_FD"] = str(self.life_read)
        try:
            self.process = subprocess.Popen(command, cwd=REPO, env=env, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=self.stderr,
                                            pass_fds=(self.life_read,), start_new_session=True)
        except BaseException:
            os.close(self.life_read)
            os.close(self.life_write)
            self.stderr.close()
            raise
        parent = process_info(self.process.pid)
        self.parent_start = parent["start"] if parent else None
        require(parent is not None, "Cannot retain the MCP parent's PID start time")
        self.process_history[(parent["pid"], parent["start"])] = parent
        self.reader = threading.Thread(target=self.read_stdout, daemon=True)
        self.reader.start()
        self.tracker = threading.Thread(target=self.track, daemon=True)
        self.tracker.start()

    def read_stdout(self):
        try:
            for line in self.process.stdout:
                try:
                    self.responses.put(json.loads(line))
                except (ValueError, UnicodeError) as error:
                    self.responses.put(AssertionError("Non-NDJSON MCP stdout: %r (%s)" % (line[:500], error)))
        finally:
            self.responses.put(EOFError("MCP stdout closed"))

    def refresh_processes(self, include_zombies=False):
        table = {}
        for entry in Path("/proc").iterdir():
            if entry.name.isdecimal():
                info = process_info(int(entry.name))
                if info:
                    table[info["pid"]] = info
        with self.proc_lock:
            parent = table.get(self.process.pid)
            owned = {self.process.pid} if parent and parent["start"] == self.parent_start else set()
            owned.update(pid for pid, start in self.known.items()
                         if pid in table and table[pid]["start"] == start)
            while True:
                more = {pid for pid, info in table.items() if info["ppid"] in owned}
                if more <= owned:
                    break
                owned.update(more)
            for pid in owned - {self.process.pid}:
                if pid in table:
                    self.known[pid] = table[pid]["start"]
                    self.process_history[(pid, table[pid]["start"])] = table[pid]
                    private = private_root(table[pid]["argv"])
                    if private:
                        self.roots.setdefault(private, None)
                        try:
                            identity = private.lstat()
                            if stat.S_ISDIR(identity.st_mode) and identity.st_uid == os.getuid():
                                if self.roots[private] is None:
                                    self.roots[private] = (identity.st_dev, identity.st_ino)
                        except OSError:
                            pass
            return [table[pid] for pid in owned if pid in table and pid != self.process.pid
                    and (include_zombies or table[pid]["state"] != "Z")]

    def track(self):
        while not self.stopping.is_set():
            self.refresh_processes()
            self.stopping.wait(0.1)

    def rpc(self, method, params):
        require(self.unusable is None, "MCP connection unusable; refusing further RPC: %s" % self.unusable)
        self.request_id += 1
        request = dict(jsonrpc="2.0", id=self.request_id, method=method, params=params)
        self.history.append(request)
        self.history = self.history[-5:]
        try:
            self.process.stdin.write(json.dumps(request, separators=(",", ":")).encode() + b"\n")
            self.process.stdin.flush()
        except OSError as error:
            self.unusable = str(error)
            raise AssertionError("MCP request delivery failed: " + str(error)) from error
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise queue.Empty
                reply = self.responses.get(timeout=remaining)
            except queue.Empty:
                self.unusable = "request %d (%s) timed out; late replies cannot be correlated safely" % (self.request_id, method)
                raise AssertionError(self.unusable) from None
            if isinstance(reply, BaseException):
                self.unusable = str(reply)
                raise reply
            require(reply.get("jsonrpc") == "2.0", "Invalid JSON-RPC reply: %r" % reply)
            if "id" not in reply:
                require("method" in reply, "Malformed MCP notification: %r" % reply)
                continue
            if reply["id"] != self.request_id:
                self.unusable = "Unexpected MCP reply ID: %r" % reply
                raise AssertionError(self.unusable)
            require("error" not in reply, "MCP protocol error: %r" % reply)
            return reply["result"]

    def initialize(self):
        self.rpc("initialize", dict(protocolVersion="2024-11-05", capabilities={},
                                    clientInfo=dict(name="web-untrusted-integration", version="1")))
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        tools = {tool["name"]: tool for tool in self.rpc("tools/list", {})["tools"]}
        for name in ("capabilities", "web_open", "web_policy", "web_eval", "web_act", "web_tabs",
                     "web_close", "web_screenshot", "web_resize", "web_network", "web_policy_set",
                     "web_navigate", "web_snapshot"):
            require(name in tools, "Built MCP does not expose " + name)
        require("untrusted" in tools["web_open"]["inputSchema"]["properties"]["policy"]["properties"],
                "Built MCP does not advertise policy.untrusted")
        caps = self.tool("capabilities")
        require(not caps["gui_socket"] and not caps["web_gui"], "Test must not attach to a real GUI")
        require("web_untrusted" in caps and "web_emulation" in caps,
                "Built MCP lacks the new verified capability facts")

    def raw_tool(self, tool_name, **arguments):
        result = self.rpc("tools/call", dict(name=tool_name, arguments=arguments))
        details = result.get("structuredContent", {}).get("error", {}).get("details", {})
        if (result.get("isError") and isinstance(details, dict) and details.get("id")
                and tool_name != "web_diagnostic" and self.unusable is None):
            try:
                self.helper_diagnostics[details["id"]] = self.rpc("tools/call", dict(
                    name="web_diagnostic", arguments=dict(id=details["id"])))
            except Exception as error:
                self.helper_diagnostics[details["id"]] = dict(unavailable=str(error))
        return result

    def tool(self, tool_name, **arguments):
        result = self.raw_tool(tool_name, **arguments)
        if result.get("isError"):
            details = result.get("structuredContent", {}).get("error", {}).get("details", {})
            if isinstance(details, dict) and details.get("id") and tool_name != "web_diagnostic":
                print("--- Helper diagnostic ---\n" + json.dumps(self.helper_diagnostics.get(details["id"]), indent=2),
                      file=sys.stderr)
        require(not result.get("isError"), "%s failed: %s" % (tool_name, json.dumps(result)))
        require(isinstance(result.get("structuredContent"), dict), "Missing MCP structuredContent")
        return result["structuredContent"]

    def evaluate(self, pane, body):
        facts = self.tool("web_eval", pane=pane, body=body, strict=True,
                          max_chars=60000, timeout_ms=min(120000, int((self.timeout - 5) * 1000)))
        require("value" in facts and not facts.get("truncated"), "Missing complete eval value: %r" % facts)
        value = facts["value"]
        if isinstance(value, dict) and "value" in value:
            value = value["value"]
        require(not (isinstance(value, dict) and value.get("__kind") == "error"),
                "Fixture JavaScript threw: %r" % value)
        return value

    def untrusted_helper(self):
        def locate():
            processes = self.refresh_processes()
            supervisors = [info for info in processes if info["ppid"] == self.process.pid
                           and info["comm"] == "sk-web-cleanup"]
            matches = [(supervisor, info) for supervisor in supervisors for info in processes
                       if info["ppid"] == supervisor["pid"] and "--untrusted" in info["argv"]
                       and not any(arg.startswith("--type=") for arg in info["argv"])]
            require(len(matches) <= 1, "Ambiguous owned untrusted helpers: %r" % matches)
            return matches[0] if matches else None
        supervisor, info = eventually(locate, 5, "owned cleanup supervisor and actual browser PIDs")
        # The cleanup owner's argv is untouched; CEF may rewrite the browser's argv block.
        private = private_root(supervisor["argv"])
        require(private is not None, "Cleanup owner has no explicit private root: %r" % supervisor["argv"])
        identity = private.lstat()
        require(stat.S_ISDIR(identity.st_mode) and identity.st_mode & 0o7777 == 0o700
                and identity.st_uid == os.getuid(),
                "Untrusted root must exist and be mode 0700: %s" % private)
        with self.proc_lock:
            self.roots[private] = (identity.st_dev, identity.st_ino)
        self.capture_logs()
        return supervisor, info, private

    def capture_logs(self):
        # LevelDB's numeric .log files are binary journals, not diagnostic output.
        with self.proc_lock:
            roots = tuple(self.roots)
        for base in (self.root, *roots):
            if not base.exists():
                continue
            for name in ("cef.log", "chrome_debug.log", "mux.log", "stderr.log"):
                for path in base.rglob(name):
                    try:
                        with path.open("rb") as stream:
                            stream.seek(max(0, path.stat().st_size - 20000))
                            self.saved_logs[str(path)] = stream.read().decode("utf-8", errors="replace")
                    except OSError:
                        pass

    def diagnostics(self):
        self.refresh_processes()
        self.capture_logs()
        print("\n--- MCP requests ---\n" + json.dumps(self.history, indent=2), file=sys.stderr)
        print("--- Owned PID identities ---\n" + json.dumps(list(self.process_history.values()), indent=2), file=sys.stderr)
        print("--- Private roots ---\n" + repr(self.roots), file=sys.stderr)
        print("--- MCP stderr ---\n" + self.stderr_path.read_text(errors="replace")[-20000:], file=sys.stderr)
        for path, text in sorted(self.saved_logs.items()):
            print("--- %s ---\n%s" % (path, text), file=sys.stderr)
        print("--- Captured helper stderr diagnostics ---\n" + json.dumps(self.helper_diagnostics, indent=2), file=sys.stderr)

    def signal_owned(self, info, sig):
        self.refresh_processes()
        owned = (info["pid"] == self.process.pid and info["start"] == self.parent_start or
                 self.known.get(info["pid"]) == info["start"])
        require(owned and same_process(info), "Refusing signal to an unowned or reused PID: %r" % info)
        fd = os.pidfd_open(info["pid"])
        try:
            require(same_process(info), "PID identity changed before signaling: %r" % info)
            signal.pidfd_send_signal(fd, sig)
        finally:
            os.close(fd)

    def owned_subtree(self, owner):
        processes = self.refresh_processes()
        ids = {owner["pid"]} if same_process(owner) else set()
        while True:
            more = {info["pid"] for info in processes if info["ppid"] in ids}
            if more <= ids:
                break
            ids.update(more)
        return [info for info in processes if info["pid"] in ids]

    def assert_retired(self, processes, description):
        # Zombies still own a PID; require removal/reuse, not merely a non-running state.
        eventually(lambda: all(same_process(info) is None for info in processes), 10, description)

    def close(self):
        self.refresh_processes()
        self.capture_logs()
        errors = []
        try:
            if self.process.stdin and not self.process.stdin.closed:
                try:
                    self.process.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                code = self.process.wait(timeout=20)
                if code != self.expected_exit:
                    errors.append("MCP exited with %d" % code)
            except subprocess.TimeoutExpired:
                errors.append("MCP did not exit after stdin EOF")
                self.signal_owned(dict(pid=self.process.pid, start=self.parent_start), signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.signal_owned(dict(pid=self.process.pid, start=self.parent_start), signal.SIGKILL)
                    self.process.wait(timeout=5)
        finally:
            os.close(self.life_write)
            os.close(self.life_read)
        deadline = time.monotonic() + 8
        alive = self.refresh_processes(include_zombies=True)
        while alive and time.monotonic() < deadline:
            time.sleep(0.1)
            alive = self.refresh_processes(include_zombies=True)
        self.capture_logs()
        self.stopping.set()
        self.tracker.join(timeout=3)
        if alive:
            errors.append("Owned subprocesses survived graceful shutdown: %r" % alive)
            # Exact, start-time-checked descendants only; never kill by executable name.
            for info in alive:
                current = same_process(info)
                if current and current["comm"] != "sk-web-cleanup":
                    try:
                        self.signal_owned(info, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            deadline = time.monotonic() + 5
            while self.refresh_processes(include_zombies=True) and time.monotonic() < deadline:
                time.sleep(0.1)
            remaining = self.refresh_processes(include_zombies=True)
            if remaining:
                errors.append("Owned subprocesses survived exact-PID SIGKILL: %r" % remaining)
        retained = [info for info in self.process_history.values() if info["pid"] != self.process.pid
                    and same_process(info)]
        if retained:
            errors.append("Owned PID identities not fully retired (including zombies): %r" % retained)
        for path, identity in self.roots.items():
            if path.exists():
                errors.append("MCP left private helper root behind: %s" % path)
                current = path.lstat()
                if (not retained and identity == (current.st_dev, current.st_ino)
                        and stat.S_ISDIR(current.st_mode) and current.st_uid == os.getuid()):
                    shutil.rmtree(path)
        self.reader.join(timeout=3)
        self.process.stdout.close()
        self.stderr.close()
        if errors:
            self.diagnostics()
            raise AssertionError("; ".join(errors))


class WebUntrustedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p1 = HTTPFixture()
        cls.addClassCleanup(cls.p1.close)
        cls.p2 = HTTPFixture()
        cls.addClassCleanup(cls.p2.close)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wu-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.mcp = MCP(self.root, OPTIONS.command, OPTIONS.helper, OPTIONS.timeout)
        self.addCleanup(self.mcp.close)
        self.token = uuid.uuid4().hex
        try:
            self.mcp.initialize()
        except BaseException:
            self.mcp.diagnostics()
            raise

    def tearDown(self):
        result = self._outcome.result
        if any(test is self or getattr(test, "test_case", None) is self
               for test, _ in result.failures + result.errors):
            self.mcp.diagnostics()

    def path(self, label):
        return "/%s/%s" % (self.token, label)

    def open(self, untrusted=False, url=None, hosts=None, private=True, schemes=None, policy_patch=None, profile=None, **extra):
        url = url or self.p1.url("/page/" + self.token)
        hosts = hosts if hosts is not None else ["127.0.0.1:%d" % self.p1.server_port]
        policy = dict(allow_hosts=hosts, allow_private_addresses=private, block_ads=False)
        if untrusted:
            policy["untrusted"] = True
        if schemes:
            policy["allow_schemes"] = schemes
        policy.update(policy_patch or {})
        require(not untrusted or profile is None, "Untrusted fixtures cannot use persistent profiles")
        identity = dict(ephemeral=True) if profile is None else dict(profile=profile)
        facts = self.mcp.tool("web_open", url=url, snapshot="none", **identity,
                              route="direct", policy=policy, timeout_ms=20000, **extra)
        require(facts["backend"] == "headless" and facts["profile_kind"] == ("ephemeral" if profile is None else "named"), facts)
        require(facts.get("untrusted") is untrusted, "Open did not echo its actual mode: %r" % facts)
        require(not facts.get("load_error") and not facts.get("loading"), "Fixture did not load: %r" % facts)
        pane = facts["view"]
        self.assertEqual(self.mcp.evaluate(pane, "return document.title;"), "Untrusted integration fixture")
        if untrusted:
            caps = self.mcp.tool("capabilities")
            self.assertIs(caps["web_untrusted"], True)
            self.assertIs(caps["web_untrusted_mode"], True)
            enforced = self.mcp.tool("web_policy", pane=pane)["enforced"]
            self.assertEqual(enforced["internet_sockets"], "denied")
            self.assertEqual(enforced["http_broker"], "actual-address-validated")
            for key in ("service_workers", "websockets", "webrtc", "extensions", "ranges"):
                self.assertIs(enforced[key], False)
            self.assertEqual(enforced["methods"], "GET/HEAD and same-origin POST only")
            self.assertEqual(enforced["max_response_bytes"], 16 * 1024 * 1024)
            self.assertEqual(enforced["response_timeout_ms"], 15000)
            self.assertEqual(enforced["renderer_sandbox"], "chromium namespace (user/pid/net) + seccomp-bpf")
            self.mcp.untrusted_helper()
        return pane

    def fetch(self, pane, url, options=None):
        return self.mcp.evaluate(pane, """
const abort = new AbortController(); const timer = setTimeout(() => abort.abort(), 5000);
try { const r = await fetch(%s, {...%s, signal:abort.signal});
      return {ok:r.ok, status:r.status, type:r.type, header:r.headers.get('X-Fixture-Secret'),
              body:await r.text()}; }
catch(e) { return {ok:false, error:e.name}; } finally {clearTimeout(timer);}
""" % (json.dumps(url), json.dumps(options or {})))

    def resource(self, pane, kind, url, marker=None):
        worker_url = None
        if kind == "worker":
            bootstrap = self.path("worker-bootstrap-" + uuid.uuid4().hex + ".js")
            self.p1.asset(bootstrap, ("importScripts(%s);" % json.dumps(url)).encode(), "application/javascript")
            worker_url = self.p1.url(bootstrap)
        return self.mcp.evaluate(pane, """
const kind=%s, url=%s, marker=%s, workerURL=%s;
if(kind==='font') {
  const face=new FontFace(marker, `url(${JSON.stringify(url)})`);
  document.fonts.add(face);
  try {await Promise.race([face.load(),new Promise((_,reject)=>setTimeout(()=>reject(Error('timeout')),7000))]);
    const span=document.createElement('span'); span.textContent='MMMM';
    span.style.fontFamily=JSON.stringify(marker); document.body.append(span);
    return {loaded:face.status==='loaded', applied:document.fonts.check(`16px "${marker}"`, 'MMMM')};
  } catch(e) {return {loaded:false, applied:false, error:e.name};}
}
if(kind==='worker') {
  return await new Promise(resolve=>{
    let worker; const timer=setTimeout(()=>{if(worker)worker.terminate();resolve({loaded:false,timeout:true});},7000);
    try {worker=new Worker(workerURL);
      worker.onmessage=e=>{clearTimeout(timer);worker.terminate();resolve({loaded:e.data==='worker-ok'});};
      worker.onerror=()=>{clearTimeout(timer);worker.terminate();resolve({loaded:false});};
    } catch(e) {clearTimeout(timer);resolve({loaded:false,error:e.name});}
  });
}
let element;
if(kind==='style') {element=document.createElement('link');element.rel='stylesheet';element.href=url;}
else if(kind==='image') {element=new Image();element.src=url;}
else if(kind==='media') {element=document.createElement('audio');element.preload='auto';element.src=url;}
else {element=document.createElement('script');element.src=url;if(kind==='module')element.type='module';}
if(marker)delete globalThis[marker];
const loaded=await new Promise(resolve=>{
  const timer=setTimeout(()=>resolve(false),7000);
  element[kind==='media'?'onloadeddata':'onload']=()=>{clearTimeout(timer);resolve(true);};
  element.onerror=()=>{clearTimeout(timer);resolve(false);};
  document.head.append(element);if(kind==='media')element.load();
});
let result={loaded};
if(kind==='script'||kind==='module')result.executed=globalThis[marker]===true;
if(kind==='style')result.applied=getComputedStyle(document.body).getPropertyValue('--cdn-control').trim()==='applied';
if(kind==='image' && loaded) {
  const canvas=document.createElement('canvas');canvas.width=canvas.height=1;
  canvas.getContext('2d').drawImage(element,0,0);
  try {result.pixel=Array.from(canvas.getContext('2d').getImageData(0,0,1,1).data);result.readable=true;}
  catch(e) {result.readable=false;result.error=e.name;}
}
if(kind==='media'){result.duration=Number.isFinite(element.duration)?element.duration:null;result.ready=element.readyState;}
element.remove();return result;
""" % (json.dumps(kind), json.dumps(url), json.dumps(marker), json.dumps(worker_url)))

    def assert_resource_control(self, outcome, kind):
        self.assertIs(outcome["loaded"], True, "Ordinary/allowed resource control failed: %r" % outcome)
        if kind in ("script", "module"):
            self.assertIs(outcome["executed"], True, outcome)
        elif kind in ("style", "font"):
            self.assertIs(outcome["applied"], True, outcome)
        elif kind == "media":
            self.assertEqual(outcome["duration"], 1, outcome)
            self.assertGreaterEqual(outcome["ready"], 2, outcome)

    def assert_no_hits(self, server, path, seconds=None):
        deadline = time.monotonic() + (OPTIONS.observe if seconds is None else seconds)
        while time.monotonic() < deadline:
            self.assertEqual(server.matching(path), [], "Forbidden request reached fixture")
            time.sleep(0.05)

    def test_01_http_ports_and_stable_handles(self):
        ordinary = self.open(hosts=["127.0.0.1"])
        target = self.path("port-control")
        self.assertTrue(self.fetch(ordinary, self.p2.url(target))["ok"])
        self.assertGreater(len(self.p2.matching(target)), 0)
        for mode in (False, True):
            with self.subTest(untrusted=mode):
                pane = self.open(untrusted=mode)
                allowed, denied = self.path("allowed-" + str(mode)), self.path("denied-" + str(mode))
                self.assertTrue(self.fetch(pane, self.p1.url(allowed))["ok"])
                self.assertGreater(len(self.p1.matching(allowed)), 0)
                cdn = self.path("cdn-port-control-" + str(mode) + ".js")
                cdn_pane = self.open(untrusted=mode, policy_patch={
                    "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]})
                marker = "port_control_" + str(mode)
                self.assert_resource_control(self.resource(cdn_pane, "script", self.p2.url(cdn, marker=marker), marker), "script")
                self.assertGreater(len(self.p2.matching(cdn, "GET")), 0)
                denied += ".js"
                outcome = self.resource(pane, "script", self.p2.url(denied, marker=marker), marker)
                self.assertIs(outcome["loaded"], False, outcome)
                self.assertIs(outcome["executed"], False, outcome)
                self.assert_no_hits(self.p2, denied)
                policy = self.mcp.tool("web_policy", pane=pane)
                self.assertGreater(policy["denied"].get("sub_host", 0), 0, policy)
                self.assertEqual(self.mcp.evaluate(ordinary, "return document.title;"),
                                 "Untrusted integration fixture")
                self.mcp.tool("web_close", pane=pane)
                self.mcp.tool("web_close", pane=cdn_pane)
        # An empty list must default to the main URL's effective port, not deny its random fixture port.
        pane = self.open(untrusted=True, hosts=[])
        policy = self.mcp.tool("web_policy", pane=pane)
        self.assertEqual(policy["policy"]["allow_hosts"], ["127.0.0.1:%d" % self.p1.server_port])

    def test_02_stun_packets(self):
        for transport in ("stun", "turn-tcp", "turn-tls"):
            for mode in (False, True):
                with self.subTest(transport=transport, untrusted=mode), PacketContext(udp=transport == "stun") as fixture:
                    pane = self.open(untrusted=mode)
                    urls = ("stun:127.0.0.1:%d" if transport == "stun" else
                            "turn:127.0.0.1:%d?transport=tcp" if transport == "turn-tcp" else
                            "turns:127.0.0.1:%d?transport=tcp") % fixture.port
                    outcome = self.mcp.evaluate(pane, """
const start=performance.now(); let pc=null, result={};
try {
  pc=new RTCPeerConnection({iceServers:[{urls:%s,username:'rig',credential:'rig'}]});
  pc.createDataChannel('control');
  await pc.setLocalDescription(await pc.createOffer());
  result.description=true;
} catch(e) {result.error=e.name;}
await new Promise(r=>setTimeout(r,%d));
result.duration=performance.now()-start;
if(pc) {result.gathering=pc.iceGatheringState; pc.close();}
return result;
""" % (json.dumps(urls), int(max(3, OPTIONS.observe) * 1000)))
                    self.assertGreaterEqual(outcome["duration"], max(3, OPTIONS.observe) * 1000 - 50)
                    if mode:
                        self.assertEqual(fixture.count(), 0, "Untrusted WebRTC emitted traffic")
                    else:
                        self.assertTrue(outcome.get("description"), outcome)
                        self.assertGreater(fixture.count(), 0, transport + " control emitted no traffic; denial is unproven")
                        if transport == "stun":
                            self.assertTrue(any(len(packet) >= 20 and packet[:2] == b"\x00\x01"
                                                and packet[4:8] == b"\x21\x12\xa4\x42"
                                                for packet in fixture.packets), "No real STUN binding packet")
                    self.mcp.tool("web_close", pane=pane)

    def test_03_resolved_private_address(self):
        host = (OPTIONS.private_host or socket.gethostname()).lower()
        require(re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host) is not None,
                "--private-host must be a plain DNS hostname")
        require(host != "localhost" and not host.endswith((".localhost", ".local", ".internal")),
                "Resolved-private test needs a hostname the textual gate does not already deny")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            self.fail("Resolved-private hostname must not be an IP literal")
        try:
            addresses = {item[4][0] for item in socket.getaddrinfo(host, self.p1.server_port,
                                                                 socket.AF_INET, socket.SOCK_STREAM)}
        except socket.gaierror as error:
            self.fail("Local hostname does not resolve; supply --private-host from local NSS/hosts: %s" % error)
        require(addresses and all(ipaddress.ip_address(address).is_private for address in addresses),
                "Local hostname must resolve only to private IPv4 addresses: %r" % addresses)
        hosts = ["%s:%d" % (host, self.p1.server_port)]
        control_path = "/page/" + self.token + "-dns-control"
        control = self.open(untrusted=True, url=self.p1.url(control_path, host=host), hosts=hosts)
        self.assertGreater(len(self.p1.matching(control_path)), 0)
        self.mcp.tool("web_close", pane=control)
        denied_path = "/page/" + self.token + "-dns-denied"
        result = self.mcp.raw_tool("web_open", url=self.p1.url(denied_path, host=host), snapshot="none",
                                   ephemeral=True, route="direct", timeout_ms=20000,
                                   policy=dict(untrusted=True, allow_hosts=hosts, block_ads=False,
                                               allow_private_addresses=False))
        # Navigation can answer a load-error fact or a tool refusal; neither alone proves the reason.
        self.assert_no_hits(self.p1, denied_path)
        facts = result.get("structuredContent", {})
        pane = facts.get("view")
        if pane is None:
            views = self.mcp.tool("web_tabs")["views"]
            candidates = [view for view in views if view["url"] == self.p1.url(denied_path, host=host)]
            require(len(candidates) == 1, "Refused navigation left no inspectable policy: %r" % result)
            pane = candidates[0]["view"]
        policy = self.mcp.tool("web_policy", pane=pane)
        self.assertGreater(policy["denied"].get("resolved_private_address", 0), 0, policy)
        self.assertEqual(policy["denied"].get("private_address", 0), 0, policy)
        self.mcp.untrusted_helper()

    def test_04_classic_and_module_service_workers(self):
        for mode in (False, True):
            pane = self.open(untrusted=mode)
            for kind in ("classic", "module"):
                with self.subTest(untrusted=mode, kind=kind):
                    path = self.path("sw-" + kind + "-" + str(mode) + ".js")
                    result = self.mcp.evaluate(pane, """
try {
  const registration=await navigator.serviceWorker.register(%s, {type:%s, scope:%s});
  const worker=registration.installing || registration.waiting || registration.active;
  if(worker && worker.state !== 'activated') await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error('activation timeout')),5000);
    worker.addEventListener('statechange',()=>{
      if(worker.state==='activated'){clearTimeout(timer);resolve();}
      if(worker.state==='redundant'){clearTimeout(timer);reject(new Error('redundant'));}
    });
  });
  await registration.unregister(); return {registered:true};
} catch(e) {return {registered:false, error:e.name, message:e.message};}
""" % (json.dumps(path), json.dumps(kind), json.dumps(self.path("scope-" + kind + "/"))))
                    if mode:
                        self.assertFalse(result["registered"], result)
                        self.assert_no_hits(self.p1, path)
                    else:
                        self.assertTrue(result["registered"], "Service-worker control failed: %r" % result)
                        self.assertGreater(len(self.p1.matching(path)), 0)
            self.mcp.tool("web_close", pane=pane)

    def test_05_favicon_and_prefetch(self):
        for rel in ("icon", "prefetch"):
            for mode in (False, True):
                with self.subTest(rel=rel, untrusted=mode):
                    path = self.path(rel + "-" + str(mode) + (".png" if rel == "icon" else ""))
                    page = self.p1.url("/page/" + self.token + rel + str(mode),
                                       **{rel: self.p2.url(path)})
                    pane = self.open(untrusted=mode, url=page,
                                     policy_patch={"allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]},
                                     profile=None if mode else "hint-control")
                    if mode:
                        self.assert_no_hits(self.p2, path)
                    else:
                        eventually(lambda: self.p2.matching(path), OPTIONS.observe + 5,
                                   rel + " control must reach the second HTTP server")
                    self.mcp.tool("web_close", pane=pane)

    def test_06_preconnect_tcp_accepts(self):
        for mode in (False, True):
            with self.subTest(untrusted=mode), PacketContext() as tcp:
                target = "http://127.0.0.1:%d" % tcp.port
                pane = self.open(untrusted=mode, hosts=None if mode else ["127.0.0.1"],
                                 url=self.p1.url("/page/" + self.token + str(mode), preconnect=target),
                                 profile=None if mode else "preconnect-control")
                if mode:
                    deadline = time.monotonic() + OPTIONS.observe
                    while time.monotonic() < deadline:
                        self.assertEqual(tcp.count(), 0, "Untrusted preconnect opened a TCP connection")
                        time.sleep(0.05)
                else:
                    eventually(tcp.count, OPTIONS.observe + 5,
                               "preconnect control (browser prediction may be disabled; no silent pass)")
                self.mcp.tool("web_close", pane=pane)

    def test_07_beacon_post_and_websocket(self):
        for mode in (False, True):
            with self.subTest(untrusted=mode):
                schemes = None if mode else ["http", "https", "ws", "wss"]
                pane = self.open(untrusted=mode, schemes=schemes)
                beacon = self.path("beacon-" + str(mode))
                accepted = self.mcp.evaluate(pane, "return navigator.sendBeacon(%s, 'beacon-body');" % json.dumps(beacon))
                self.assertTrue(accepted)
                events = eventually(lambda: self.p1.matching(beacon, "POST"), 5, "same-origin beacon POST")
                self.assertEqual(events[0]["body"], b"beacon-body")
                headers = {key.lower(): value for key, value in events[0]["headers"].items()}
                self.assertEqual(headers.get("origin"), self.p1.url("").rstrip("/"), events)
                network = self.mcp.tool("web_network", pane=pane, max=128)
                self.assertTrue(any(request["url"].endswith(beacon) and request["method"] == "POST"
                                    and not request["blocked"] for request in network["requests"]), network)
                path = self.path("ws-" + str(mode))
                url = self.p1.url(path).replace("http:", "ws:", 1)
                outcome = self.mcp.evaluate(pane, """
return await new Promise(resolve=>{
  let ws; const timer=setTimeout(()=>{if(ws)ws.close();resolve({opened:false,timeout:true});},5000);
  try {ws=new WebSocket(%s);
    ws.onopen=()=>{clearTimeout(timer);ws.close();resolve({opened:true});};
    ws.onerror=()=>{clearTimeout(timer);resolve({opened:false});};
  } catch(e) {clearTimeout(timer);resolve({opened:false,error:e.name});}
});
""" % json.dumps(url))
                if mode:
                    self.assertFalse(outcome["opened"], outcome)
                    self.assert_no_hits(self.p1, path)
                else:
                    self.assertTrue(outcome["opened"], "WebSocket handshake control failed: %r" % outcome)
                    self.assertGreater(len(self.p1.matching(path)), 0)
                self.mcp.tool("web_close", pane=pane)

    def test_08_permissions_and_device_api_presence(self):
        mcp = self.new_mcp(helper_args=("--enable-blink-features=WebBluetooth,WebBluetoothGetDevices",))
        values = {}
        for mode in (False, True):
            facts = mcp.tool("web_open", url=self.p1.url("/page/" + self.token), snapshot="none", ephemeral=True,
                             policy=dict(untrusted=mode, allow_private_addresses=True, block_ads=False,
                                         allow_hosts=["127.0.0.1:%d" % self.p1.server_port]))
            pane = facts["view"]
            values[mode] = mcp.evaluate(pane, """
const result={secure:isSecureContext, devices:{}, permissions:{}};
for(const name of ['usb','bluetooth','hid','serial']) result.devices[name]=name in navigator;
for(const name of ['notifications','geolocation','clipboard-read','clipboard-write']) {
  try {result.permissions[name]=(await navigator.permissions.query({name})).state;}
  catch(e) {result.permissions[name]='error:'+e.name;}
}
return result;
""")
            self.assertTrue(values[mode]["secure"], "API control must use a secure loopback context")
            mcp.tool("web_close", pane=pane)
        for name in ("usb", "bluetooth", "hid", "serial"):
            with self.subTest(device=name):
                self.assertIs(values[False]["devices"][name], True,
                              "Installed CEF lacks %s; disabled-API control cannot prove restriction" % name)
                self.assertIs(values[True]["devices"][name], False)
        for name in ("notifications", "geolocation", "clipboard-read", "clipboard-write"):
            with self.subTest(permission=name):
                control = values[False]["permissions"][name]
                # Chromium can grant clipboard-write to the focused secure document by default.
                self.assertIn(control, ("prompt", "granted") if name == "clipboard-write" else ("prompt",),
                              "Ordinary permission control was already denied: %r" % values[False])
                if name == "clipboard-write":
                    self.assertIn(values[True]["permissions"][name], ("prompt", "granted"),
                                  "CEF's sanitized clipboard writes are not claimed as denied")
                else:
                    self.assertEqual(values[True]["permissions"][name], "denied")

    def test_09_trusted_popups_and_blob_downloads(self):
        for mode in (False, True):
            with self.subTest(untrusted=mode):
                pane = self.open(untrusted=mode)
                self.assertEqual(len(self.mcp.tool("web_tabs")["views"]), 1)
                self.mcp.tool("web_act", pane=pane, name="Open popup", role="button", action="click")
                self.assertEqual(self.mcp.evaluate(pane, "return trustedEvents;"), [True])
                if mode:
                    deadline = time.monotonic() + OPTIONS.observe
                    while time.monotonic() < deadline:
                        self.assertEqual(len(self.mcp.tool("web_tabs")["views"]), 1)
                        time.sleep(0.1)
                    self.assertIs(self.mcp.evaluate(pane, "return popupResult;"), False)
                else:
                    views = eventually(lambda: (lambda views: views if len(views) > 1 else None)(
                        self.mcp.tool("web_tabs")["views"]), 5, "ordinary trusted popup tab")
                    self.assertIs(self.mcp.evaluate(pane, "return popupResult;"), True)
                    for view in views:
                        if view["view"] != pane:
                            self.mcp.tool("web_close", pane=view["view"])
                before = {path for path in self.mcp.downloads.rglob("*") if path.is_file()}
                self.mcp.tool("web_act", pane=pane, name="Download blob", role="button", action="click")
                self.assertEqual(self.mcp.evaluate(pane, "return trustedEvents;"), [True, True])
                if mode:
                    deadline = time.monotonic() + OPTIONS.observe
                    while time.monotonic() < deadline:
                        self.mcp.tool("web_tabs")  # Pump offered downloads too.
                        self.assertEqual({path for path in self.mcp.downloads.rglob("*") if path.is_file()}, before)
                        time.sleep(0.1)
                else:
                    def downloaded():
                        self.mcp.tool("web_tabs")
                        path = self.mcp.downloads / "fixture-download.txt"
                        return path if path.is_file() and path.read_bytes() == b"untrusted-download-control" else None
                    path = eventually(downloaded, 10, "ordinary page blob download in isolated XDG downloads")
                    path.unlink()
                self.mcp.tool("web_close", pane=pane)

    def test_10_first_document_emulation_and_scale(self):
        for mode in (False, True):
            for color, motion in (("light", "no-preference"), ("dark", "reduce")):
                for dpr in (0.5, 1, 1.5, 4):
                    with self.subTest(untrusted=mode, color=color, motion=motion, dpr=dpr):
                        pane = self.open(untrusted=mode, color_scheme=color, reduced_motion=motion,
                                         device_scale_factor=dpr, width=640, height=480)
                        self.assertIs(self.mcp.tool("capabilities")["web_emulation"], True)
                        first = self.mcp.evaluate(pane, "return firstDocument;")
                        self.assertEqual(first, dict(dark=color == "dark", light=color == "light",
                                                     reduce=motion == "reduce", noPreference=motion == "no-preference",
                                                     dpr=dpr, width=640, height=480))
                        css = self.mcp.evaluate(pane, """const s=getComputedStyle(document.body);
return {background:s.backgroundColor,motion:s.getPropertyValue('--motion').trim()};""")
                        self.assertEqual(css, dict(background="rgb(17, 17, 17)" if color == "dark" else "rgb(255, 255, 255)",
                                                   motion="reduce" if motion == "reduce" else ""))
                        background = (17, 17, 17, 255) if color == "dark" else (255, 255, 255, 255)
                        self.assert_screenshot(pane, int(640 * dpr), int(480 * dpr), background)
                        self.mcp.tool("web_resize", pane=pane, width=800, height=600)
                        eventually(lambda: self.mcp.evaluate(pane, "return innerWidth===800 && innerHeight===600;"),
                                   5, "resized logical viewport")
                        self.assertEqual(self.mcp.evaluate(pane, "return devicePixelRatio;"), dpr)
                        self.assert_screenshot(pane, int(800 * dpr), int(600 * dpr), background)
                        self.mcp.tool("web_close", pane=pane)

    def assert_screenshot(self, pane, width, height, background=None):
        def painted():
            result = self.mcp.raw_tool("web_screenshot", pane=pane)
            require(not result.get("isError"), "Screenshot failed: %r" % result)
            images = [block for block in result["content"] if block["type"] == "image"]
            self.assertEqual(len(images), 1)
            image = base64.b64decode(images[0]["data"], validate=True)
            actual_width, actual_height, pixel = png_first_pixel(image)
            return result if (actual_width, actual_height) == (width, height) and (background is None or pixel == background) else None
        result = eventually(painted, 5, "physical screenshot %dx%d with background %r" % (width, height, background))
        self.assertEqual((result["structuredContent"]["width"], result["structuredContent"]["height"]),
                         (width, height))

    def test_11_private_root_close_crash_and_no_core(self):
        ordinary = self.open()
        roots = set()
        for cause in ("close", "close", "kill", "kill", "abort", "abort"):
            with self.subTest(cause=cause, iteration=len(roots)):
                pane = self.open(untrusted=True)
                supervisor, helper, private = self.mcp.untrusted_helper()
                self.assertNotIn(private, roots, "Private root was reused")
                roots.add(private)
                self.assert_confinement(helper)
                owned = self.mcp.owned_subtree(supervisor)
                self.assertTrue(any(info["pid"] == helper["pid"] for info in owned), owned)
                self.assertEqual(self.mcp.evaluate(ordinary, "return document.title;"),
                                 "Untrusted integration fixture")
                artifacts_before = self.core_artifacts(private)
                self.mcp.capture_logs()
                if cause == "close":
                    self.mcp.tool("web_close", pane=pane)
                else:
                    self.mcp.signal_owned(helper, signal.SIGKILL if cause == "kill" else signal.SIGABRT)
                    self.mcp.assert_retired([helper], "deliberately signaled actual browser reaped")
                    # A read observes helper loss; do not restart with another web_open first.
                    self.mcp.raw_tool("web_policy", pane=pane)
                    self.mcp.raw_tool("web_tabs")
                eventually(lambda: not private.exists(), 8, "private helper root removed after " + cause)
                self.mcp.assert_retired(owned, "supervisor, browser and all owned descendants reaped after " + cause)
                self.assertEqual(self.core_artifacts(private), artifacts_before,
                                 "Untrusted browser produced a core/minidump")
                self.assertEqual(self.mcp.evaluate(ordinary, "return document.title;"),
                                 "Untrusted integration fixture")
        # Registered cleanup verifies graceful MCP shutdown with a live restricted view.
        self.open(untrusted=True)

    def renderers_of(self, helper):
        # Forked renderers keep the zygote's argv; a renderer is recognised by
        # Blink's "Compositor" thread, which no zygote or utility process runs.
        def threads(info):
            try:
                return {(task / "comm").read_text().strip()
                        for task in (Path("/proc") / str(info["pid"]) / "task").iterdir()}
            except OSError:
                return set()
        def live():
            found = [info for info in self.mcp.owned_subtree(helper)
                     if info["state"] != "Z" and "Compositor" in threads(info)]
            return found or None
        return eventually(live, 5, "live renderer of helper %d" % helper["pid"])

    def sandbox_evidence(self, info):
        # status stays readable for nondumpable processes; ns/* links do not.
        text = (Path("/proc") / str(info["pid"]) / "status").read_text()
        status = dict(line.split(":", 1) for line in text.splitlines() if ":" in line)
        return len(status["NSpid"].split()), int(status["Seccomp_filters"].strip())

    def test_24_renderers_run_in_chromium_namespace_sandbox(self):
        ordinary_pane = self.open()
        self.open(untrusted=True)
        _, helper, _ = self.mcp.untrusted_helper()
        ordinary = [info for info in self.mcp.refresh_processes()
                    if info["ppid"] == self.mcp.process.pid and "--untrusted" not in info["argv"]
                    and info["comm"] != "sk-web-cleanup"
                    and not any(arg.startswith("--type=") for arg in info["argv"])
                    and Path(info["argv"][0]).name == "sketerm-webengine"]
        require(len(ordinary) == 1, "Expected exactly one ordinary helper: %r" % ordinary)
        self.assertEqual(self.mcp.evaluate(ordinary_pane, "return document.title;"), "Untrusted integration fixture")
        # Control: the ordinary helper runs Chromium unsandboxed, so its
        # renderers share the browser's PID namespace and seccomp stack.
        base = self.sandbox_evidence(ordinary[0])
        for renderer in self.renderers_of(ordinary[0]):
            self.assertEqual(self.sandbox_evidence(renderer), base, renderer)
        depth, filters = self.sandbox_evidence(helper)
        for renderer in self.renderers_of(helper):
            r_depth, r_filters = self.sandbox_evidence(renderer)
            # The namespace sandbox clones user, PID and network namespaces together.
            self.assertGreater(r_depth, depth, "untrusted renderer is not in a sandbox PID namespace")
            # Chromium's seccomp-bpf policy stacks on the helper's socket filter.
            self.assertGreater(r_filters, filters, "untrusted renderer has no Chromium seccomp policy")

    def assert_confinement(self, helper):
        def with_renderer():
            items = self.mcp.owned_subtree(helper)
            zygotes = {info["pid"] for info in items if "--type=zygote" in info["argv"]}
            # Forked CEF renderers can retain the zygote's argv on Linux.
            return items if any(info["state"] != "Z" and
                                ("--type=renderer" in info["argv"] or info["ppid"] in zygotes)
                                for info in items) else None
        processes = eventually(with_renderer,
            5, "live restricted CEF renderer")
        checked = 0
        for info in processes:
            current = same_process(info)
            if current is None or current["state"] == "Z":
                continue
            directory = Path("/proc") / str(info["pid"])
            try:
                limits = (directory / "limits").read_text()
                status_text = (directory / "status").read_text()
            except FileNotFoundError:
                require(same_process(info) is None, "A live process lost its /proc records")
                continue
            match = re.search(r"^Max core file size\s+(\S+)\s+(\S+)\s+bytes[ \t]*$", limits, re.MULTILINE)
            if match is None:
                current = same_process(info)
                if current is None or current["state"] == "Z":
                    continue
            self.assertIsNotNone(match, "Cannot inspect core limits for PID %d" % info["pid"])
            self.assertEqual(match.groups(), ("0", "0"), info)
            status = dict(line.split(":", 1) for line in status_text.splitlines()
                          if ":" in line)
            self.assertEqual(status["NoNewPrivs"].strip(), "1", info)
            if info["pid"] == helper["pid"] or any(arg.startswith("--type=") for arg in info["argv"]):
                self.assertEqual(status["Seccomp"].strip(), "2", info)
            # New kernels may expose Dumpable; its absence is not a fabricated assertion.
            # Zygotes stay dumpable: the namespace sandbox cannot map a
            # non-dumpable child's user namespace. Browser and renderers are not.
            if "Dumpable" in status and "--type=zygote" not in info["argv"]:
                self.assertEqual(status["Dumpable"].strip(), "0", info)
            checked += 1
        self.assertGreater(checked, 1, "No live confined CEF descendants were inspected")
        if "Dumpable" not in status:
            print("\n/proc does not expose Dumpable; checked zero soft/hard core limits and local crash artifacts. "
                  "Native test covers PR_GET_DUMPABLE directly.", file=sys.stderr)

    def core_artifacts(self, private):
        return {path for base in (self.root, private) if base.exists() for path in base.rglob("*")
                if path.is_file() and (path.name == "core" or path.name.startswith("core.")
                                       or path.suffix == ".dmp")}

    def test_12_dns_hints(self):
        require(OPTIONS.dns_hint_host, "DNS control requires dist/test-web-untrusted-netns.sh or an instrumented resolver")
        for hint in ("dns-prefetch", "preconnect"):
            for mode in (False, True):
                with self.subTest(hint=hint, untrusted=mode):
                    host = "%s-%s-%s.%s" % (self.token, hint, str(mode).lower(), OPTIONS.dns_hint_host)
                    log = OPTIONS.dns_log
                    offset = log.stat().st_size
                    target = "http://%s:%d" % (host, self.p2.server_port)
                    pane = self.open(untrusted=mode, profile=None if mode else "dns-control",
                                     url=self.p1.url("/page/" + host, **{hint: target}))
                    def queries():
                        with log.open("rb") as stream:
                            stream.seek(offset)
                            return host.encode() in stream.read().lower()
                    if mode:
                        deadline = time.monotonic() + max(3, OPTIONS.observe)
                        while time.monotonic() < deadline:
                            self.assertFalse(queries(), "Untrusted %s reached the instrumented resolver" % hint)
                            time.sleep(0.05)
                    else:
                        eventually(queries, OPTIONS.observe + 5, "ordinary %s wire DNS query" % hint)
                    self.mcp.tool("web_close", pane=pane)

    def test_13_webtransport_connection(self):
        from web_untrusted_fixtures import WebTransportFixture
        for mode in (False, True):
            with self.subTest(untrusted=mode), WebTransportFixture() as fixture:
                pane = self.open(untrusted=mode)
                outcome = self.mcp.evaluate(pane, """
const result={present:typeof WebTransport==='function',secure:isSecureContext}; let transport,timer;
try {
  transport=new WebTransport(%s,{serverCertificateHashes:[
    {algorithm:'sha-256',value:new Uint8Array(%s)}]});
  transport.closed.catch(()=>{});
  result.ready=await Promise.race([transport.ready.then(()=>true,e=>{
    result.error=e.name;return false;
  }),new Promise(r=>timer=setTimeout(()=>r('timeout'),8000))]);
} catch(e) {result.error=e.name;result.ready=false;}
finally {clearTimeout(timer);if(transport)transport.close();}
await new Promise(r=>setTimeout(r,%d));return result;
""" % (json.dumps(fixture.url()), json.dumps(list(fixture.certificate_hash)), int(max(3, OPTIONS.observe) * 1000)))
                self.assertIs(outcome["present"], True)
                self.assertIs(outcome["secure"], True)
                if mode:
                    self.assertIsNot(outcome["ready"], True)
                    self.assertEqual(fixture.count(), 0, "Untrusted WebTransport emitted UDP")
                    self.assertEqual(fixture.accepted_count(), 0)
                else:
                    self.assertIs(outcome["ready"], True, "Working QUIC control did not connect: %r" % outcome)
                    self.assertGreater(fixture.count(), 0)
                    self.assertGreater(fixture.handshake_count(), 0)
                    self.assertEqual(fixture.accepted_count(), 1)
                self.mcp.tool("web_close", pane=pane)

    def test_14_restricted_http_methods_and_ranges(self):
        control = self.open(hosts=["127.0.0.1"])
        allowed = self.open(untrusted=True, hosts=["127.0.0.1:%d" % self.p1.server_port,
                                                   "127.0.0.1:%d" % self.p2.server_port])
        for method in ("GET", "HEAD", "POST"):
            with self.subTest(method=method):
                path = self.path("method-" + method)
                options = {"method": method}
                if method == "POST":
                    options["body"] = "post-body"
                options["headers"] = {"X-Rig-Header": "same-origin-control", "Accept": "application/json; profile=\"rig\""}
                self.assertTrue(self.fetch(allowed, self.p1.url(path), options)["ok"])
                events = self.p1.matching(path, method)
                self.assertGreater(len(events), 0)
                self.assertEqual({key.lower(): value for key, value in events[0]["headers"].items()}["x-rig-header"],
                                 "same-origin-control")
        for name, options in (("put", {"method": "PUT", "body": "forbidden"}),
                              ("range", {"headers": {"Range": "bytes=0-1"}})):
            with self.subTest(operation=name):
                positive, negative = self.path(name + "-control"), self.path(name + "-denied")
                self.assertTrue(self.fetch(control, self.p1.url(positive), options)["ok"])
                self.assertGreater(len(self.p1.matching(positive)), 0)
                self.assertFalse(self.fetch(allowed, self.p1.url(negative), options)["ok"])
                self.assert_no_hits(self.p1, negative)
        positive, negative = self.path("cross-post-control"), self.path("cross-post-denied")
        options = dict(method="POST", body="cross-origin-body")
        self.assertTrue(self.fetch(control, self.p2.url(positive), options)["ok"])
        self.assertGreater(len(self.p2.matching(positive, "POST")), 0)
        self.assertFalse(self.fetch(allowed, self.p2.url(negative), options)["ok"])
        self.assert_no_hits(self.p2, negative)
        policy = self.mcp.tool("web_policy", pane=allowed)
        self.assertEqual(policy["denied"].get("sub_host", 0), 0, policy)
        self.assertGreater(policy["denied"].get("untrusted_http", 0), 0, policy)

    def font_fixture(self):
        font = OPTIONS.font
        if font is None:
            probe = subprocess.run(["fc-match", "-f", "%{file}", "monospace"], check=True,
                                   stdout=subprocess.PIPE, timeout=5)
            font = Path(os.fsdecode(probe.stdout))
        font_bytes = font.read_bytes()
        require(font_bytes[:4] in (b"\x00\x01\x00\x00", b"OTTO"),
                "--font/fc-match must identify a valid standalone TTF/OTF: %s" % font)
        print("\nCDN font control: %s (%d bytes)" % (font, len(font_bytes)), file=sys.stderr)
        return font_bytes, "font/otf" if font_bytes[:4] == b"OTTO" else "font/ttf"

    def test_15_allowed_cdn_script_style_module_font(self):
        font_bytes, font_mime = self.font_fixture()
        for mode in (False, True):
            pane = self.open(untrusted=mode, policy_patch={
                "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]})
            cookie = "cdn_control=" + self.token
            self.assertIs(self.mcp.evaluate(pane, "document.cookie=%s;return document.cookie.includes(%s);" %
                                           (json.dumps(cookie + ";path=/"), json.dumps(cookie))), True)
            for kind in ("script", "style", "module", "font"):
                with self.subTest(untrusted=mode, kind=kind):
                    marker = "cdn_" + kind + "_" + str(mode)
                    path = self.path(marker + {"script": ".js", "module": ".js", "style": ".css", "font": ".ttf"}[kind])
                    if kind == "font":
                        self.p2.asset(path, font_bytes, font_mime)
                    elif kind == "module":
                        dependency = self.path(marker + "-dependency.js")
                        self.p2.asset(dependency, b"export const control=true;", "application/javascript")
                        self.p2.asset(path, ("import {control} from %s;globalThis[%s]=control;" %
                                            (json.dumps(self.p2.url(dependency)), json.dumps(marker))).encode(),
                                      "application/javascript")
                    outcome = self.resource(pane, kind, self.p2.url(path, marker=marker), marker)
                    self.assert_resource_control(outcome, kind)
                    self.assertGreater(len(self.p2.matching(path, "GET")), 0)
                    if kind == "module":
                        self.assertGreater(len(self.p2.matching(dependency, "GET")), 0)
                    if not mode and kind in ("script", "style"):
                        self.assertTrue(any(cookie in {key.lower(): value for key, value in event["headers"].items()}.get("cookie", "")
                                            for event in self.p2.matching(path)), "Ordinary credential control sent no cookie")
                    if mode:
                        for event in self.p2.matching(path):
                            headers = {key.lower(): value for key, value in event["headers"].items()}
                            self.assertNotIn("cookie", headers)
                            self.assertNotIn("authorization", headers)
                            self.assertNotIn("referer", headers)
            self.mcp.tool("web_close", pane=pane)

    def test_16_cdn_response_cors_mime_and_status_gates(self):
        font_bytes, font_mime = self.font_fixture()
        panes = {mode: self.open(untrusted=mode, policy_patch={
            "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]}) for mode in (False, True)}
        variants = dict(no_acao=dict(acao="none"), exact_origin=dict(acao=self.p1.url("")),
                        duplicate=dict(acao=["*", "*"]), combined=dict(acao="*, *"),
                        wrong_mime=dict(mime="text/plain"), error_status=dict(status=404))
        for kind, suffix in (("script", ".js"), ("style", ".css"), ("module", ".js"), ("font", ".ttf")):
            # Invalid module/font CORS is also rejected by ordinary Chromium; validate a genuine
            # wildcard/MIME control first, then require source traffic for every invalid response.
            for mode in (False, True):
                path, marker = self.path("cors-baseline-%s-%s%s" % (kind, mode, suffix)), "baseline_" + kind + str(mode)
                if kind == "font":
                    self.p2.asset(path, font_bytes, font_mime)
                self.assert_resource_control(self.resource(panes[mode], kind, self.p2.url(path, marker=marker), marker), kind)
                self.assertGreater(len(self.p2.matching(path, "GET")), 0)
            for name, query in variants.items():
                for mode in (False, True):
                    with self.subTest(kind=kind, response=name, untrusted=mode):
                        path = self.path("cors-%s-%s-%s%s" % (kind, name, mode, suffix))
                        marker = "cors_" + kind + "_" + name + "_" + str(mode)
                        if kind == "font":
                            self.p2.asset(path, font_bytes, font_mime)
                        outcome = self.resource(panes[mode], kind, self.p2.url(path, marker=marker, **query), marker)
                        self.assertGreater(len(self.p2.matching(path, "GET")), 0,
                                           "Response-gate test must reach the source, not fail at the host/type gate")
                        if mode:
                            self.assertIs(outcome["loaded"], False, outcome)
                            if kind in ("script", "module"):
                                self.assertIs(outcome["executed"], False, outcome)
                            else:
                                self.assertIs(outcome["applied"], False, outcome)
                        elif kind == "script" and name != "error_status":
                            self.assert_resource_control(outcome, kind)

    def test_17_cross_origin_fetch_xhr_no_cors_body_and_headers(self):
        for mode in (False, True):
            pane = self.open(untrusted=mode, policy_patch={
                "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]})
            for operation in ("fetch", "xhr", "no-cors", "page-upgrade-insecure-requests"):
                with self.subTest(untrusted=mode, operation=operation):
                    path = self.path(operation + "-" + str(mode))
                    url = self.p2.url(path)
                    if operation == "xhr":
                        outcome = self.mcp.evaluate(pane, """
return await new Promise(resolve=>{const r=new XMLHttpRequest();r.open('GET',%s);r.timeout=5000;
r.onload=()=>resolve({ok:true,body:r.responseText,header:r.getResponseHeader('X-Fixture-Secret')});
r.onerror=r.ontimeout=()=>resolve({ok:false});r.send();});
""" % json.dumps(url))
                    else:
                        options = ({"mode": "no-cors"} if operation == "no-cors" else
                                   {"headers": {"Upgrade-Insecure-Requests": "1"}}
                                   if operation == "page-upgrade-insecure-requests" else {})
                        outcome = self.fetch(pane, url, options)
                    if mode:
                        self.assertFalse(outcome["ok"], outcome)
                        self.assertNotIn("fixture-ok", outcome.get("body", ""), outcome)
                        self.assertNotEqual(outcome.get("header"), "header-secret", outcome)
                        self.assert_no_hits(self.p2, path)
                    else:
                        self.assertGreater(len(self.p2.matching(path, "GET")), 0,
                                           "Ordinary control never issued its GET: %r" % outcome)
                        if operation == "no-cors":
                            self.assertEqual(outcome, dict(ok=False, status=0, type="opaque", header=None, body=""))
                        else:
                            self.assertTrue(outcome["ok"], outcome)
                            self.assertEqual(outcome["body"], "fixture-ok")
                            self.assertEqual(outcome["header"], "header-secret")
            self.mcp.tool("web_close", pane=pane)

    def test_18_cross_origin_canvas_media_and_worker(self):
        for mode in (False, True):
            pane = self.open(untrusted=mode, policy_patch={
                "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]})
            for kind, suffix in (("image", ".png"), ("media", ".wav"), ("worker", ".js")):
                with self.subTest(untrusted=mode, kind=kind):
                    path = self.path("opaque-" + kind + "-" + str(mode) + suffix)
                    outcome = self.resource(pane, kind, self.p2.url(path, worker=1))
                    if mode:
                        self.assertIs(outcome["loaded"], False, outcome)
                        self.assertNotIn("pixel", outcome, "Cross-origin image became canvas-readable")
                        self.assert_no_hits(self.p2, path)
                    else:
                        self.assert_resource_control(outcome, kind)
                        self.assertGreater(len(self.p2.matching(path, "GET")), 0)
                        if kind == "image":
                            self.assertIs(outcome["readable"], False, outcome)
                            self.assertEqual(outcome["error"], "SecurityError", outcome)
            # Same-origin canvas is a readable positive control; media controls above are
            # ordinary because Chromium may request Range, deliberately unsupported here.
            path = self.path("same-origin-image-" + str(mode) + ".png")
            outcome = self.resource(pane, "image", self.p1.url(path))
            self.assert_resource_control(outcome, "image")
            self.assertGreater(len(self.p1.matching(path, "GET")), 0)
            self.assertIs(outcome["readable"], True, outcome)
            self.assertEqual(len(outcome["pixel"]), 4, outcome)
            self.mcp.tool("web_close", pane=pane)

    def test_19_non_navigation_redirects_never_followed(self):
        for mode in (False, True):
            pane = self.open(untrusted=mode, policy_patch={
                "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port]})
            for cross in (False, True):
                for acao in ("none", "*"):
                    with self.subTest(untrusted=mode, cross_origin=cross, acao=acao):
                        server = self.p2 if cross else self.p1
                        label = "redirect-%s-%s-%s" % (mode, cross, acao == "*")
                        source, target = self.path(label + ".js"), self.path(label + "-target.js")
                        marker = "redirect_control_" + uuid.uuid4().hex
                        outcome = self.resource(pane, "script", server.url(source, status=302, acao=acao,
                            location=server.url(target, marker=marker)), marker)
                        self.assertGreater(len(server.matching(source, "GET")), 0)
                        if mode:
                            self.assertIs(outcome["loaded"], False, outcome)
                            self.assertIs(outcome["executed"], False, outcome)
                            self.assert_no_hits(server, target)
                        else:
                            self.assert_resource_control(outcome, "script")
                            self.assertGreater(len(server.matching(target, "GET")), 0)
            # The non-navigation restriction must not break ordinary document redirects/Accept.
            source, target = self.path("nav-redirect-" + str(mode)), "/page/" + self.token + "-nav-" + str(mode)
            self.mcp.tool("web_navigate", pane=pane, url=self.p1.url(source, status=302, acao="none",
                                                                    location=self.p1.url(target)))
            self.assertEqual(self.mcp.evaluate(pane, "return document.title;"), "Untrusted integration fixture")
            for path in (source, target):
                events = self.p1.matching(path, "GET")
                self.assertGreater(len(events), 0)
                headers = {key.lower(): value for key, value in events[0]["headers"].items()}
                self.assertIn("text/html", headers.get("accept", ""), events)
                self.assertEqual(headers.get("upgrade-insecure-requests"), "1", events)
            self.mcp.tool("web_close", pane=pane)

    def test_20_mcp_parent_sigkill_retires_owned_descendants(self):
        # A fresh independent MCP is killed twice; the main test client remains usable.
        ordinary = self.open()
        for iteration in range(2):
            with self.subTest(iteration=iteration):
                mcp = self.new_mcp()
                path = "/page/" + self.token + "-parent-kill-" + str(iteration)
                facts = mcp.tool("web_open", url=self.p1.url(path), snapshot="none", ephemeral=True,
                                 policy=dict(untrusted=True, allow_private_addresses=True, block_ads=False,
                                             allow_hosts=["127.0.0.1:%d" % self.p1.server_port]))
                self.assertEqual(mcp.evaluate(facts["view"], "return document.title;"), "Untrusted integration fixture")
                supervisor, browser, private = mcp.untrusted_helper()
                owned = mcp.refresh_processes()
                self.assertTrue(any(info["pid"] == supervisor["pid"] for info in owned), owned)
                self.assertTrue(any(info["pid"] == browser["pid"] for info in owned), owned)
                mcp.capture_logs()
                parent = dict(pid=mcp.process.pid, start=mcp.parent_start)
                mcp.expected_exit = -signal.SIGKILL
                mcp.signal_owned(parent, signal.SIGKILL)
                self.assertEqual(mcp.process.wait(timeout=5), -signal.SIGKILL)
                mcp.unusable = "MCP parent deliberately killed"
                eventually(lambda: not private.exists(), 10, "private root removed after MCP parent SIGKILL")
                mcp.assert_retired(owned, "all recorded descendants retired after MCP parent SIGKILL")
                self.assertEqual(self.mcp.evaluate(ordinary, "return document.title;"), "Untrusted integration fixture")

    def new_mcp(self, env=None, helper_args=()):
        temporary = tempfile.TemporaryDirectory(prefix="wu-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        mcp = MCP(Path(temporary.name), OPTIONS.command, OPTIONS.helper, OPTIONS.timeout,
                  env_overrides=env, helper_args=helper_args)
        self.addCleanup(mcp.close)
        mcp.initialize()
        return mcp

    def test_21_missing_negotiation_capabilities_fail_closed(self):
        self.open(untrusted=True, color_scheme="dark", reduced_motion="reduce")
        for flag, needle in (("SKETERM_WEB_DISABLE_NET_POLICY", "policy"),
                             ("SKETERM_WEB_DISABLE_NET_POLICY_ACK", "policy"),
                             ("SKETERM_WEB_DISABLE_UNTRUSTED", "untrusted"),
                             ("SKETERM_WEB_DISABLE_EMULATION", "emulation")):
            with self.subTest(flag=flag):
                mcp = self.new_mcp({flag: "1"})
                path = "/page/" + self.token + "-" + flag.lower()
                result = mcp.raw_tool("web_open", url=self.p1.url(path), snapshot="none", ephemeral=True,
                                     color_scheme="dark", reduced_motion="reduce",
                                     policy=dict(untrusted=True, allow_private_addresses=True, block_ads=False,
                                                 allow_hosts=["127.0.0.1:%d" % self.p1.server_port]))
                self.assertIs(result.get("isError"), True, result)
                self.assertIn(needle, result["structuredContent"]["error"]["message"].lower())
                self.assert_no_hits(self.p1, path)
                views = mcp.raw_tool("web_tabs")
                if not views.get("isError"):
                    self.assertEqual(views["structuredContent"]["views"], [], views)

    def test_22_budgets_latch_and_reads_survive(self):
        for mode in (False, True):
            for field, reason in (("max_requests", "request_cap"), ("max_bytes", "byte_cap"),
                                  ("max_navigations", "nav_cap"), ("deadline_ms", "deadline")):
                with self.subTest(untrusted=mode, budget=field):
                    pane = self.open(untrusted=mode, policy_patch={"block_types": ["image"]})
                    before = self.mcp.tool("web_policy", pane=pane)
                    path = self.path("budget-control-" + field + "-" + str(mode))
                    denied = self.path("budget-denied-" + field + "-" + str(mode))
                    if field == "deadline_ms":
                        self.assertTrue(self.fetch(pane, self.p1.url(path))["ok"])
                        self.assertGreater(len(self.p1.matching(path, "GET")), 0)
                        self.mcp.tool("web_policy_set", pane=pane, policy={field: 1000})
                        eventually(lambda: self.mcp.tool("web_policy", pane=pane)["exhausted"], 5,
                                   "deadline latches without another request")
                    else:
                        counter = {"max_requests": "requests", "max_bytes": "bytes", "max_navigations": "navigations"}[field]
                        self.mcp.tool("web_policy_set", pane=pane, policy={field: before[counter] + 1})
                        if field == "max_navigations":
                            path = "/page/" + self.token + "-budget-nav-" + str(mode)
                            self.mcp.tool("web_navigate", pane=pane, url=self.p1.url(path))
                            self.assertEqual(self.mcp.evaluate(pane, "return document.title;"), "Untrusted integration fixture")
                        else:
                            outcome = self.fetch(pane, self.p1.url(path))
                            self.assertTrue(outcome["ok"], outcome)
                            self.assertEqual(outcome["body"], "fixture-ok", "The response crossing the byte cap must complete")
                        self.assertGreater(len(self.p1.matching(path, "GET")), 0)
                        self.mcp.raw_tool("web_navigate" if field == "max_navigations" else "web_eval", pane=pane,
                                          **({"url": self.p1.url(denied)} if field == "max_navigations" else
                                             {"body": "try {await fetch(%s);}catch(e){}return true;" % json.dumps(self.p1.url(denied)),
                                              "timeout_ms": 5000}))
                    after = self.mcp.tool("web_policy", pane=pane)
                    self.assertIs(after["exhausted"], True, after)
                    self.assertEqual(after["exhausted_reason"], reason, after)
                    self.assert_no_hits(self.p1, denied)
                    for tool, arguments in (("web_eval", {"body": "return 1;"}),
                                            ("web_navigate", {"url": self.p1.url(denied)}),
                                            ("web_act", {"name": "Open popup", "role": "button", "action": "click"})):
                        refused = self.mcp.raw_tool(tool, pane=pane, **arguments)
                        self.assertIs(refused.get("isError"), True, refused)
                        self.assertIn(reason, refused["structuredContent"]["error"]["message"])
                    read = self.mcp.tool("web_snapshot", pane=pane)
                    self.assertIs(read["policy_exhausted"], True, read)
                    self.assertEqual(read["policy_exhausted_reason"], reason)
                    serial = after["policy_serial"]
                    loosen = self.mcp.raw_tool("web_policy_set", pane=pane, policy={field: 0})
                    self.assertIs(loosen.get("isError"), True, loosen)
                    retained = self.mcp.tool("web_policy", pane=pane)
                    self.assertEqual(retained["policy_serial"], serial)
                    self.assertEqual(retained["exhausted_reason"], reason)
                    self.assert_no_hits(self.p1, denied)
                    self.mcp.tool("web_close", pane=pane)

    def test_23_policy_only_tightens_including_http_443(self):
        for mode in (False, True):
            with self.subTest(untrusted=mode):
                pane = self.open(untrusted=mode, policy_patch={
                    "allow_subresource_hosts": ["127.0.0.1:%d" % self.p2.server_port, "cdn.example"],
                    "max_requests": 100, "max_bytes": 10000000, "max_navigations": 100, "deadline_ms": 120000})
                before = self.mcp.tool("web_policy", pane=pane)
                looser = dict(allow_hosts=before["policy"]["allow_hosts"] + ["127.0.0.1", "extra.example"], max_requests=101, max_bytes=10000001,
                              max_navigations=101, deadline_ms=120001)
                result = self.mcp.raw_tool("web_policy_set", pane=pane, policy=looser)
                self.assertIs(result.get("isError"), True, result)
                unchanged = self.mcp.tool("web_policy", pane=pane)
                self.assertEqual(unchanged["policy"], before["policy"])
                self.assertEqual(unchanged["policy_serial"], before["policy_serial"])
                result = self.mcp.tool("web_policy_set", pane=pane, policy=dict(max_requests=90, max_bytes=10000001))
                self.assertEqual(result["tightened"], ["max_requests"])
                self.assertEqual(result["ignored"], ["max_bytes"])
                expected = dict(before["policy"], max_requests=90)
                self.assertEqual(result["policy"], expected, "Omitted fields changed during a partial tighten")
                marker = "tighten_control_" + str(mode)
                control = self.path(marker + ".js")
                self.assert_resource_control(self.resource(pane, "script", self.p2.url(control, marker=marker), marker), "script")
                self.assertGreater(len(self.p2.matching(control, "GET")), 0)
                # A bare restricted host means HTTP:80 / HTTPS:443, NOT HTTP:443.
                explicit = self.mcp.raw_tool("web_policy_set", pane=pane, policy={
                    "allow_subresource_hosts": expected["allow_subresource_hosts"] + ["cdn.example:443"]
                    if mode else ["cdn.example:443"]})
                if mode:
                    self.assertIs(explicit.get("isError"), True, explicit)
                    self.assertEqual(self.mcp.tool("web_policy", pane=pane)["policy"], expected)
                    result = self.mcp.tool("web_policy_set", pane=pane, policy={
                        "allow_schemes": ["https"], "allow_subresource_hosts": ["cdn.example:443"]})
                    self.assertEqual(result["ignored"], [], "Combined HTTPS-only port tighten was incorrectly ignored")
                    self.assertEqual(result["policy"]["allow_schemes"], ["https"])
                else:
                    self.assertFalse(explicit.get("isError"), explicit)
                # The former CDN port is now denied even though the page remains readable.
                denied = self.path("tighten-denied-" + str(mode) + ".js")
                outcome = self.resource(pane, "script", self.p2.url(denied, marker=marker), marker)
                self.assertIs(outcome["loaded"], False, outcome)
                self.assertIs(outcome["executed"], False, outcome)
                self.assert_no_hits(self.p2, denied)
                result = self.mcp.tool("web_policy_set", pane=pane, policy={"allow_hosts": []})
                self.assertEqual(result["policy"]["allow_hosts"], [])
                result = self.mcp.tool("web_policy_set", pane=pane, policy={
                    "allow_private_addresses": False, "block_types": ["image", "media"]})
                policy = result["policy"]
                unchanged = self.mcp.tool("web_policy_set", pane=pane, policy={"block_types": []})
                self.assertEqual(unchanged["policy"], policy)
                self.assertEqual(unchanged["tightened"], [])
                for change in ({"allow_private_addresses": True},
                               {"allow_subresource_hosts": policy["allow_subresource_hosts"] + ["cdn.example"]}):
                    refused = self.mcp.raw_tool("web_policy_set", pane=pane, policy=change)
                    self.assertIs(refused.get("isError"), True, refused)
                    self.assertEqual(self.mcp.tool("web_policy", pane=pane)["policy"], policy)
                mode_flip = self.mcp.raw_tool("web_policy_set", pane=pane, policy={"untrusted": not mode})
                self.assertIs(mode_flip.get("isError"), True, mode_flip)
                self.assertEqual(self.mcp.tool("web_policy", pane=pane)["policy"]["untrusted"], mode)
                self.mcp.tool("web_close", pane=pane)


class PacketContext(PacketFixture):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class RigUnitTests(unittest.TestCase):
    def test_diagnostics_capture_restricted_logs_not_leveldb(self):
        with tempfile.TemporaryDirectory(prefix="wu-", dir="/tmp") as temporary:
            base = Path(temporary)
            root, private = base / "mcp", base / "restricted"
            root.mkdir()
            private.mkdir()
            (private / "cef.log").write_text("actual restricted CEF diagnostic")
            (private / "chrome_debug.log").write_text("actual restricted Chrome diagnostic")
            (private / "000001.log").write_bytes(b"binary-LevelDB-sentinel\0\xff")
            mcp = MCP.__new__(MCP)
            mcp.root, mcp.roots, mcp.saved_logs = root, {private: None}, {}
            mcp.proc_lock = threading.Lock()
            mcp.capture_logs()
            self.assertEqual(mcp.saved_logs, {
                str(private / "cef.log"): "actual restricted CEF diagnostic",
                str(private / "chrome_debug.log"): "actual restricted Chrome diagnostic"})

    def test_pidfd_signals_only_owned_start_time(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        try:
            info = process_info(child.pid)
            self.assertIsNotNone(info)
            mcp = MCP.__new__(MCP)
            mcp.process, mcp.parent_start = child, info["start"]
            mcp.known, mcp.roots, mcp.process_history = {}, {}, {}
            mcp.proc_lock = threading.Lock()
            with self.assertRaisesRegex(AssertionError, "unowned or reused PID"):
                mcp.signal_owned(dict(info, start="not-the-current-start-time"), signal.SIGKILL)
            with self.assertRaisesRegex(AssertionError, "unowned or reused PID"):
                mcp.signal_owned(process_info(os.getpid()), signal.SIGKILL)
            self.assertIsNone(child.poll(), "Rejected signals killed our control child")
            mcp.signal_owned(info, signal.SIGTERM)
            self.assertEqual(child.wait(timeout=3), -signal.SIGTERM)
        finally:
            if child.poll() is None:
                child.kill()  # Popen retains its unreaped child PID until wait.
            child.wait(timeout=3)

    def test_screenshot_pixel_reader(self):
        def chunk(kind, data):
            return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
        for filter_type in range(5):
            image = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(bytes((filter_type, 17, 17, 17, 255)))) + chunk(b"IEND", b""))
            self.assertEqual(png_first_pixel(image), (1, 1, (17, 17, 17, 255)))

    def test_rpc_timeout_quarantines_late_reply(self):
        mcp = MCP.__new__(MCP)
        mcp.timeout, mcp.request_id, mcp.unusable = 0.01, 0, None
        mcp.history, mcp.responses = [], queue.Queue()
        mcp.process = argparse.Namespace(stdin=io.BytesIO())
        with self.assertRaisesRegex(AssertionError, "late replies"):
            mcp.rpc("timed-out", {})
        written = mcp.process.stdin.getvalue()
        mcp.responses.put(dict(jsonrpc="2.0", id=1, result={}))
        with self.assertRaisesRegex(AssertionError, "connection unusable"):
            mcp.rpc("must-not-send", {})
        self.assertEqual(mcp.process.stdin.getvalue(), written)
        self.assertEqual(mcp.request_id, 1)
        self.assertEqual(mcp.responses.qsize(), 1)

    def test_rpc_wrong_id_quarantines_connection(self):
        mcp = MCP.__new__(MCP)
        mcp.timeout, mcp.request_id, mcp.unusable = 1, 0, None
        mcp.history, mcp.responses = [], queue.Queue()
        mcp.process = argparse.Namespace(stdin=io.BytesIO())
        mcp.responses.put(dict(jsonrpc="2.0", id=9, result={}))
        with self.assertRaisesRegex(AssertionError, "Unexpected MCP reply ID"):
            mcp.rpc("wrong-id", {})
        with self.assertRaisesRegex(AssertionError, "connection unusable"):
            mcp.rpc("must-not-send", {})

    def test_root_requires_explicit_16_hex_argument(self):
        root = "/tmp/wu-test/r/sketerm/u/" + "a" * 16
        self.assertEqual(private_root(["helper", "--untrusted", "--untrusted-root", root]), Path(root))
        for argv in (["--untrusted", "--cache-dir", root + "/cache"],
                     ["--untrusted", "--untrusted-root", root + "/../foreign"],
                     ["--untrusted", "--untrusted-root", root[:-1]],
                     ["--untrusted-root", root]):
            self.assertIsNone(private_root(argv))
        self.assertIsNotNone(same_process(process_info(os.getpid())))
        self.assertIsNone(same_process(dict(pid=os.getpid(), start="not-the-current-start-time")))

    def test_http_fixture_cors_status_mime_and_media(self):
        fixture = HTTPFixture()
        self.addCleanup(fixture.close)
        fixture.asset("/module.js", b"export const control=true;", "application/javascript")
        for path, query, expected_status, mime, origins in (
                ("/module.js", {}, 200, "application/javascript", ["*"]),
                ("/module.js", dict(acao="none", mime="text/plain"), 200, "text/plain", []),
                ("/module.js", dict(acao=["*", "*"]), 200, "application/javascript", ["*", "*"]),
                ("/redirect.js", dict(status=302, location=fixture.url("/module.js")), 302, "application/javascript", ["*"]),
                ("/control.wav", {}, 200, "audio/wav", ["*"])):
            with self.subTest(path=path, query=query):
                url = urlsplit(fixture.url(path, **query))
                client = http.client.HTTPConnection(url.hostname, url.port, timeout=3)
                try:
                    client.request("GET", url.path + ("?" + url.query if url.query else ""))
                    response = client.getresponse()
                    payload = response.read()
                    self.assertEqual(response.status, expected_status)
                    self.assertEqual(response.getheader("Content-Type"), mime)
                    self.assertEqual([value for name, value in response.getheaders()
                                      if name.lower() == "access-control-allow-origin"], origins)
                    if path == "/module.js":
                        self.assertEqual(payload, b"export const control=true;")
                    elif path.endswith(".wav"):
                        self.assertEqual(payload[:4], b"RIFF")
                        self.assertEqual(len(payload), 16044)
                finally:
                    client.close()
                self.assertGreater(len(fixture.matching(path, "GET")), 0)

    def test_packet_fixture_answers_real_stun_and_counts_tcp(self):
        with PacketContext(udp=True) as fixture:
            client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                client.settimeout(3)
                transaction = b"test-rig-123"
                request = b"\x00\x01\x00\x00\x21\x12\xa4\x42" + transaction
                client.sendto(request, ("127.0.0.1", fixture.port))
                response, _ = client.recvfrom(256)
                self.assertEqual(response[:2], b"\x01\x01")
                self.assertEqual(response[4:20], request[4:20])
                self.assertEqual(fixture.count(), 1)
            finally:
                client.close()
        with PacketContext() as fixture:
            with socket.create_connection(("127.0.0.1", fixture.port), timeout=3):
                eventually(fixture.count, 3, "TCP packet fixture accept")
            self.assertEqual(fixture.count(), 1)


def main():
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="""No builds are performed. Missing capabilities and failed controls FAIL, not skip.
The DNS test needs a wildcard DNS zone routed to a query-logging resolver;
--dns-log must be an existing append-only local log containing queried hostnames.
No public DNS hostname is selected automatically. --private-host must resolve
locally to this machine's private IPv4 address and must not use a .local,
.localhost or .internal suffix. The default is socket.gethostname().
Run through dist/test-web-untrusted-netns.sh for an isolated local resolver.
WebTransport controls require system Python aioquic and cryptography.
Not proved here: native IPv6/mapped-address
filtering, arbitrary native-code resistance, real hardware permissions, GPU
rendering or system core-dump collector output. Policy and media
acknowledgement failures are proved by dist/test-web-untrusted-acks.py.
Use dist/test-web-untrusted.c for native socket/address/loader assertions.""")
    parser.add_argument("--bin-dir", type=Path, default=REPO / "zig-out/bin")
    parser.add_argument("--helper", type=Path, help="Helper pin (default SKETERM_WEB_BIN, then built sibling)")
    parser.add_argument("--private-host", help="Locally resolving non-reserved hostname for resolved-private test")
    parser.add_argument("--font", type=Path, help="Local TTF/OTF for the genuine CDN font control (default fc-match monospace)")
    parser.add_argument("--timeout", type=float, default=60, help="Per MCP response deadline in seconds (default 60)")
    parser.add_argument("--observe", type=float, default=3, help="Negative observation window in seconds (default 3)")
    parser.add_argument("--dns-hint-host", help="Optional instrumented wildcard DNS suffix")
    parser.add_argument("--dns-log", type=Path, help="Append-only query log for the optional DNS control")
    parser.add_argument("--test", action="append", help="Run named unittest method(s); default runs all")
    parser.add_argument("--rig-only", action="store_true", help="Run fixture, PID identity and RPC quarantine tests without a browser")
    OPTIONS = parser.parse_args()
    if sys.platform != "linux" or not Path("/proc/self/stat").exists():
        parser.error("These integration tests require Linux /proc and the Linux restricted loader")
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        parser.error("Python must expose Linux pidfd_open/pidfd_send_signal for reuse-safe process signals")
    if not 15 <= OPTIONS.timeout <= 140 or not 1 <= OPTIONS.observe <= 10:
        parser.error("--timeout must be 15..140 and --observe 1..10 seconds")
    if bool(OPTIONS.dns_hint_host) != bool(OPTIONS.dns_log):
        parser.error("--dns-hint-host and --dns-log must be supplied together")
    if OPTIONS.dns_log and not OPTIONS.dns_log.is_file():
        parser.error("--dns-log must already exist; the rig does not configure a resolver")
    if OPTIONS.dns_hint_host:
        OPTIONS.dns_hint_host = OPTIONS.dns_hint_host.lower()
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", OPTIONS.dns_hint_host):
            parser.error("--dns-hint-host must be a plain wildcard DNS suffix")
    if OPTIONS.rig_only:
        if OPTIONS.test:
            parser.error("--rig-only cannot be combined with --test")
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestLoader().loadTestsFromTestCase(RigUnitTests))
        print("RIG-ONLY RUN: no browser security or lifecycle behavior was exercised.")
        return 0 if result.wasSuccessful() else 1
    bin_dir = OPTIONS.bin_dir.resolve()
    standalone = bin_dir / "sketerm-mcp"
    binary = standalone if standalone.exists() else bin_dir / "sketerm"
    OPTIONS.helper = (OPTIONS.helper or Path(os.environ.get("SKETERM_WEB_BIN", str(bin_dir / "sketerm-webengine")))).resolve()
    for path in (binary, OPTIONS.helper):
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error("Built executable missing or not executable: %s" % path)
    command_args = ([] if binary == standalone else ["mcp"]) + ["--no-record"]
    # CEF re-execs its own path; rebuilding zig-out during a run must not delete it.
    with tempfile.TemporaryDirectory(prefix="wp-", dir="/tmp") as temporary:
        pinned_binary = Path(temporary) / binary.name
        pinned_helper = Path(temporary) / "sketerm-webengine"
        for source, target in ((binary, pinned_binary), (OPTIONS.helper, pinned_helper)):
            shutil.copy2(source, target)
            print("Pinned executable: %s sha256=%s" % (source, hashlib.sha256(target.read_bytes()).hexdigest()), flush=True)
        OPTIONS.command = [str(pinned_binary)] + command_args
        OPTIONS.helper = pinned_helper
        print("MCP: " + " ".join(OPTIONS.command), flush=True)
        print("SKETERM_WEB_BIN=" + str(OPTIONS.helper), flush=True)
        print("No build, GUI attachment, public-DNS fallback, or process-name cleanup.", flush=True)
        loader = unittest.TestLoader()
        if OPTIONS.test:
            for name in OPTIONS.test:
                if name not in loader.getTestCaseNames(WebUntrustedTests):
                    parser.error("Unknown test method: " + name)
            suite = unittest.TestSuite(WebUntrustedTests(name) for name in OPTIONS.test)
        else:
            suite = unittest.TestSuite((loader.loadTestsFromTestCase(RigUnitTests), loader.loadTestsFromTestCase(WebUntrustedTests)))
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        print("Coverage limits: no hardware access, native IPv6/mapped-address proof, "
              "GPU path, system core collector inspection, or native-code exploit defense. "
              "Native ACK-failure injection runs separately in dist/test-web-untrusted-acks.py.")
        if not OPTIONS.dns_hint_host:
            print("NOT TESTED IN THIS SELECTION: DNS hint packets (use the namespace wrapper for the full matrix).")
        if OPTIONS.test:
            print("PARTIAL RUN: only explicitly selected test methods were exercised.")
        return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
