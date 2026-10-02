#!/usr/bin/env python3
"""Local wire-level browser network controls for the untrusted acceptance rig."""

import argparse
import asyncio
import ctypes
import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class _LoopFixture:
    def __init__(self):
        self.port = None
        self._lock = threading.Lock()
        self._errors = []
        self._ready = threading.Event()
        self._thread = None
        self._closed = False
        self._loop = None

    def _check(self):
        with self._lock:
            errors = tuple(self._errors)
        if errors:
            raise RuntimeError("%s failed: %s" % (type(self).__name__, errors))

    def start(self):
        if self._closed:
            raise RuntimeError("Cannot restart a closed fixture")
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, daemon=True,
                                            name=type(self).__name__)
            self._thread.start()
        if not self._ready.wait(10):
            self.close()
            raise RuntimeError("%s did not bind within 10 seconds" % type(self).__name__)
        try:
            self._check()
        except BaseException:
            self.close()
            raise
        return self

    def _run(self):
        async def serve():
            self._loop = asyncio.get_running_loop()
            self._stop = asyncio.Event()
            self._loop.set_exception_handler(lambda _, context: self._fail(
                context.get("exception", context["message"])))
            try:
                await self._open()
                self._ready.set()
                await self._stop.wait()
            finally:
                await self._shutdown()

        try:
            asyncio.run(serve())
        except BaseException as error:
            self._fail(error)
        finally:
            self._ready.set()

    def _fail(self, error):
        with self._lock:
            self._errors.append(repr(error))

    def close(self):
        if self._closed:
            self._check()
            return
        self._closed = True
        if self._thread:
            if self._loop and not self._loop.is_closed():
                self._loop.call_soon_threadsafe(self._stop.set)
            self._thread.join(timeout=10)
            if self._thread.is_alive():
                raise RuntimeError("%s thread did not stop" % type(self).__name__)
        self._check()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.close()


class WebTransportFixture(_LoopFixture):
    """Count received UDP independently from TLS handshakes and accepted HTTP/3 CONNECTs."""

    def __init__(self, port=0):
        super().__init__()
        self._requested_port = port
        self._packets = 0
        self._handshakes = 0
        self._accepts = []
        self._temporary = None
        self._server = None
        self.certificate_hash = None
        self.certificate_der = None

    async def _open(self):
        try:
            from aioquic.asyncio import QuicConnectionProtocol
            from aioquic.asyncio.server import QuicServer
            from aioquic.h3.connection import H3_ALPN, H3Connection
            from aioquic.h3.events import DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
            from aioquic.quic.configuration import QuicConfiguration
            from aioquic.quic.events import HandshakeCompleted, ProtocolNegotiated
            from cryptography import x509
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.x509.oid import NameOID
        except ImportError as error:
            raise RuntimeError("WebTransport requires system Python aioquic and cryptography: %s" % error) from error

        self._temporary = tempfile.TemporaryDirectory(prefix="wq-", dir="/tmp")
        root = Path(self._temporary.name)
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.datetime.now(datetime.timezone.utc)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                       .public_key(key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now - datetime.timedelta(minutes=5))
                       .not_valid_after(now + datetime.timedelta(days=7))
                       .add_extension(x509.SubjectAlternativeName([
                           x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
                       .sign(key, hashes.SHA256()))
        self.certificate_der = certificate.public_bytes(serialization.Encoding.DER)
        self.certificate_hash = hashlib.sha256(self.certificate_der).digest()
        cert_path, key_path = root / "cert.pem", root / "key.pem"
        cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                               serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        key_path.chmod(0o600)
        configuration = QuicConfiguration(is_client=False, alpn_protocols=H3_ALPN,
                                           max_datagram_frame_size=65536, idle_timeout=5)
        configuration.load_cert_chain(str(cert_path), str(key_path))
        fixture = self

        class Protocol(QuicConnectionProtocol):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.http = None
                self.sessions = set()

            def quic_event_received(self, event):
                if isinstance(event, ProtocolNegotiated):
                    self.http = H3Connection(self._quic, enable_webtransport=True)
                if isinstance(event, HandshakeCompleted):
                    with fixture._lock:
                        fixture._handshakes += 1
                if self.http is None:
                    return
                for item in self.http.handle_event(event):
                    if isinstance(item, HeadersReceived):
                        headers = dict(item.headers)
                        accepted = (headers.get(b":method") == b"CONNECT" and
                                    headers.get(b":protocol") == b"webtransport" and
                                    headers.get(b":path", b"").startswith(b"/"))
                        self.http.send_headers(item.stream_id, [
                            (b":status", b"200" if accepted else b"404"),
                            (b"sec-webtransport-http3-draft", b"draft02"),
                        ], end_stream=not accepted)
                        if accepted:
                            self.sessions.add(item.stream_id)
                            with fixture._lock:
                                fixture._accepts.append(dict(
                                    path=headers[b":path"].decode("ascii"), stream_id=item.stream_id))
                    elif isinstance(item, DatagramReceived) and item.stream_id in self.sessions:
                        self.http.send_datagram(item.stream_id, item.data)
                    elif isinstance(item, WebTransportStreamDataReceived) and item.session_id in self.sessions:
                        # Client-initiated bidirectional streams can echo on the same stream.
                        if item.stream_id % 4 == 0:
                            self._quic.send_stream_data(item.stream_id, item.data, item.stream_ended)

        class Server(QuicServer):
            def datagram_received(self, data, addr):
                with fixture._lock:
                    fixture._packets += 1
                super().datagram_received(data, addr)

        transport, self._server = await self._loop.create_datagram_endpoint(
            lambda: Server(configuration=configuration, create_protocol=Protocol),
            local_addr=("127.0.0.1", self._requested_port))
        self.port = transport.get_extra_info("sockname")[1]

    async def _shutdown(self):
        if self._server:
            self._server.close()
            await asyncio.sleep(0)
        if self._temporary:
            self._temporary.cleanup()

    def url(self, path="/transport"):
        if self.port is None:
            raise RuntimeError("Start the WebTransport fixture before using its URL")
        if not path.startswith("/"):
            raise ValueError("WebTransport path must begin with /")
        return "https://127.0.0.1:%d%s" % (self.port, path)

    def count(self):
        self._check()
        with self._lock:
            return self._packets

    def handshake_count(self):
        self._check()
        with self._lock:
            return self._handshakes

    def accepted_count(self):
        self._check()
        with self._lock:
            return len(self._accepts)

    def accepts(self):
        self._check()
        with self._lock:
            return [dict(event) for event in self._accepts]


def _dns_name(data, offset):
    labels, seen, end = [], set(), None
    while True:
        if offset in seen or offset >= len(data):
            raise ValueError("Invalid DNS name pointer")
        seen.add(offset)
        length = data[offset]
        if length & 0xc0 == 0xc0:
            if offset + 1 >= len(data):
                raise ValueError("Truncated DNS pointer")
            end = end or offset + 2
            offset = ((length & 0x3f) << 8) | data[offset + 1]
            continue
        offset += 1
        if not length:
            name = b".".join(labels).decode("ascii").lower()
            if len(name) > 253:
                raise ValueError("DNS name too long")
            return name, end or offset
        if length > 63 or offset + length > len(data):
            raise ValueError("Invalid DNS label")
        labels.append(data[offset:offset + length])
        offset += length


def _dns_wire(name):
    return b"".join(bytes([len(label)]) + label.encode("ascii") for label in name.split(".") if label) + b"\0"


class DNSFixture(_LoopFixture):
    """Serve only an owned .test wildcard zone, logging actual UDP/TCP questions and answers."""

    def __init__(self, suffix="fixtures.test", port=0, log=None):
        super().__init__()
        self.suffix = suffix.lower().rstrip(".")
        labels = self.suffix.split(".")
        if not self.suffix.endswith(".test") or any(
                not label or len(label) > 63 or not all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in label)
                for label in labels) or len(self.suffix) > 253:
            raise ValueError("DNS fixture suffix must be a plain name under .test")
        self._requested_port = port
        self.log = Path(log) if log else None
        self._events = []
        self._udp = self._tcp = self._log = None
        self._writers = set()

    async def _open(self):
        if self.log:
            self._log = self.log.open("a", encoding="ascii", buffering=1)
        fixture = self

        class UDP(asyncio.DatagramProtocol):
            def connection_made(self, transport):
                self.transport = transport

            def datagram_received(self, data, addr):
                response = fixture._response(data, "udp")
                if response is not None:
                    self.transport.sendto(response, addr)

        self._udp, _ = await self._loop.create_datagram_endpoint(
            UDP, local_addr=("127.0.0.1", self._requested_port))
        self.port = self._udp.get_extra_info("sockname")[1]
        self._tcp = await asyncio.start_server(self._connection, "127.0.0.1", self.port)

    async def _connection(self, reader, writer):
        self._writers.add(writer)
        try:
            while True:
                header = await asyncio.wait_for(reader.readexactly(2), 3)
                length = struct.unpack("!H", header)[0]
                data = await asyncio.wait_for(reader.readexactly(length), 3)
                response = self._response(data, "tcp")
                if response is None:
                    break
                writer.write(struct.pack("!H", len(response)) + response)
                await writer.drain()
        except (asyncio.IncompleteReadError, TimeoutError, ConnectionError):
            pass
        finally:
            writer.close()
            await writer.wait_closed()
            self._writers.discard(writer)

    def _response(self, data, transport):
        try:
            ident, flags, questions, _, _, _ = struct.unpack("!6H", data[:12])
            if flags & 0xf800 or questions != 1:
                return None
            name, end = _dns_name(data, 12)
            kind, dns_class = struct.unpack("!HH", data[end:end + 4])
            question = _dns_wire(name) + struct.pack("!HH", kind, dns_class)
        except (ValueError, UnicodeError, struct.error):
            return None
        owned = name == self.suffix or name.endswith("." + self.suffix)
        answers = ["127.0.0.1"] if owned and dns_class == 1 and kind in (1, 255) else []
        rcode = 0 if owned and dns_class == 1 else 5
        answer = b""
        if answers:
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(answers[0])
        response = struct.pack("!6H", ident, 0x8000 | (0x400 if owned else 0) | (flags & 0x100) | rcode,
                               1, len(answers), 0, 0) + question + answer
        event = dict(name=name, type=kind, transport=transport, answers=answers,
                     rcode=rcode, time=time.monotonic())
        with self._lock:
            self._events.append(event)
        if self._log:
            self._log.write(json.dumps(event, separators=(",", ":")) + "\n")
        return response

    def count(self, name=None):
        self._check()
        with self._lock:
            return sum(name is None or event["name"] == name.lower().rstrip(".") for event in self._events)

    def events(self):
        self._check()
        with self._lock:
            return [dict(event, answers=list(event["answers"])) for event in self._events]

    async def _shutdown(self):
        if self._udp:
            self._udp.close()
        if self._tcp:
            self._tcp.close()
            await self._tcp.wait_closed()
        for writer in tuple(self._writers):
            writer.close()
        if self._log:
            self._log.close()


def _namespace_ids():
    return [os.readlink("/proc/self/ns/" + kind) for kind in ("user", "mnt", "net", "pid")]


def _die_with_parent(parent):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot arm namespace parent-death signal")
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


def _reap_adopted(stop, command_pid):
    # This process is namespace PID 1; Popen alone does not reap orphaned CEF zygotes.
    children = Path("/proc/self/task/%d/children" % os.getpid())
    while not stop.is_set():
        for text in children.read_text().split():
            pid = int(text)
            if pid != command_pid:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
        stop.wait(0.02)


def _inside_namespace(root, outer_ids, outer_user, args):
    if (os.getpid() != 1 or len(outer_ids) != 4 or len(outer_user) != 2 or
            any(before == after for before, after in zip(outer_ids, _namespace_ids()))):
        raise RuntimeError("Refusing resolver mounts without new user/mount/network/PID namespaces")
    subprocess.run(["mount", "--make-rprivate", "/"], check=True)
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    # WebRTC ignores loopback interfaces; both veth ends stay in this new namespace.
    subprocess.run(["ip", "link", "add", "wu0", "type", "veth", "peer", "name", "wu1"], check=True)
    for interface, address in (("wu0", "10.203.0.1/30"), ("wu1", "10.203.0.2/30")):
        subprocess.run(["ip", "address", "add", address, "dev", interface], check=True)
        subprocess.run(["ip", "link", "set", "dev", interface, "up"], check=True)
    root = Path(root)
    resolver = root / "resolv.conf"
    resolver.write_text("nameserver 127.0.0.1\noptions timeout:1 attempts:1 ndots:1\n", encoding="ascii")
    nss = root / "nsswitch.conf"
    lines = Path("/etc/nsswitch.conf").read_text().splitlines()
    lines = [line for line in lines if not line.lstrip().startswith("hosts:")]
    nss.write_text("\n".join(lines) + "\nhosts: dns\n", encoding="ascii")
    for source, target in ((resolver, "/etc/resolv.conf"), (nss, "/etc/nsswitch.conf")):
        subprocess.run(["mount", "--bind", str(source), target], check=True)
        subprocess.run(["mount", "-o", "remount,bind,ro", target], check=True)
    suffix = "w%s.test" % uuid.uuid4().hex
    log = root / "dns.jsonl"
    with DNSFixture(suffix=suffix, port=53, log=log) as dns:
        probe = "resolver-probe." + suffix
        addresses = {item[4][0] for item in socket.getaddrinfo(probe, 80, socket.AF_INET, socket.SOCK_STREAM)}
        if addresses != {"127.0.0.1"} or dns.count(probe) == 0:
            raise RuntimeError("Private resolver did not receive the libc positive-control query")
        env = dict(os.environ, SKETERM_TEST_DNS_HINT_HOST=suffix,
                   SKETERM_TEST_DNS_LOG=str(log), SKETERM_TEST_PRIVATE_HOST="private." + suffix,
                   PYTHONDONTWRITEBYTECODE="1")
        if args and args[0] == "--":
            command = args[1:]
            if not command:
                raise ValueError("Expected an executable after --")
        elif args == ["--self-test"]:
            command = [sys.executable, "-B", str(Path(__file__).with_name("test-web-untrusted-fixtures.py")), "--netns"]
        else:
            for arg in args:
                if arg.split("=", 1)[0] in ("--dns-hint-host", "--dns-log", "--private-host"):
                    raise ValueError("The namespace wrapper owns --dns-hint-host, --dns-log and --private-host")
            command = [sys.executable, "-B", str(Path(__file__).with_name("test-web-untrusted.py")),
                       "--dns-hint-host", suffix, "--dns-log", str(log),
                       "--private-host", "private." + suffix, *args]
        # Root is only needed for the mounts, veth pair and port 53 above.
        # The rig runs as the real user again in a nested user namespace:
        # Chromium refuses to start its sandbox as root.
        uid, gid = outer_user
        command = ["unshare", "--map-user=%d" % uid, "--map-group=%d" % gid, "--", *command]
        print("Isolated local DNS: %s -> 127.0.0.1 (UDP/TCP 53); log %s" % (suffix, log), flush=True)
        stop = threading.Event()
        try:
            with subprocess.Popen(command, env=env) as child:
                reaper = threading.Thread(target=_reap_adopted, args=(stop, child.pid), daemon=True)
                reaper.start()
                try:
                    return child.wait()
                finally:
                    stop.set()
                    reaper.join(timeout=3)
        finally:
            dns._check()
            events = dns.events()
            owned = [event for event in events if event["rcode"] == 0]
            print("DNS wire log: " + json.dumps(dict(queries=owned, refused=len(events) - len(owned)),
                                                separators=(",", ":")), flush=True)


def netns(args):
    if args == ["--help"]:
        print("Usage: bash dist/test-web-untrusted-netns.sh [rig options]\n"
              "       bash dist/test-web-untrusted-netns.sh --self-test\n"
              "       bash dist/test-web-untrusted-netns.sh -- executable [arguments]\n"
              "Requires Linux rootless namespaces, util-linux mount/unshare, iproute2 and system Python.\n"
              "Supplies local --dns-hint-host/--dns-log/--private-host; no root, builds or public network.\n"
              "Custom commands receive SKETERM_TEST_DNS_HINT_HOST/DNS_LOG/PRIVATE_HOST environment variables.")
        return 0
    outer_ids = _namespace_ids()
    with tempfile.TemporaryDirectory(prefix="wn-", dir="/tmp") as root:
        command = ["unshare", "--user", "--map-root-user", "--mount", "--net", "--pid", "--fork",
                   "--mount-proc", "--propagation", "private", "--kill-child=SIGKILL",
                   sys.executable, "-B", str(Path(__file__).resolve()), "_netns", root,
                   json.dumps(outer_ids), json.dumps([os.getuid(), os.getgid()]), *args]
        parent = os.getpid()
        with subprocess.Popen(command, preexec_fn=lambda: _die_with_parent(parent)) as child:
            old_handlers = {}
            def stop(signum, _):
                child.terminate()
                raise SystemExit(128 + signum)
            try:
                for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    old_handlers[signum] = signal.signal(signum, stop)
                code = child.wait()
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                for signum, handler in old_handlers.items():
                    signal.signal(signum, handler)
        if code:
            print("FAIL: isolated DNS/browser command exited %d; namespace, mount or resolver failures are not skips." % code,
                  file=sys.stderr)
        return code if code >= 0 else 128 - code


def main():
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument("mode", choices=("netns", "_netns"))
    options = parser.parse_args(sys.argv[1:2])
    args = sys.argv[2:]
    try:
        if options.mode == "netns":
            return netns(args)
        return _inside_namespace(args[0], json.loads(args[1]), json.loads(args[2]), args[3:])
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("FAIL: local browser fixture infrastructure: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
