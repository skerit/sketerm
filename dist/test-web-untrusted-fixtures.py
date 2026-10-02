#!/usr/bin/env python3
"""Verify real DNS, WebRTC and WebTransport traffic in isolated browser controls."""

import argparse
import asyncio
import ctypes
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from web_untrusted_fixtures import DNSFixture, WebTransportFixture, _dns_wire


def query_dns(port, name, kind=1, tcp=False):
    query = struct.pack("!6H", 1234, 0x100, 1, 0, 0, 0) + _dns_wire(name) + struct.pack("!HH", kind, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as client:
        client.settimeout(3)
        client.connect(("127.0.0.1", port))
        if tcp:
            client.sendall(struct.pack("!H", len(query)) + query)
            def receive(length):
                result = b""
                while len(result) < length:
                    chunk = client.recv(length - len(result))
                    if not chunk:
                        raise AssertionError("Truncated TCP DNS reply")
                    result += chunk
                return result
            return receive(struct.unpack("!H", receive(2))[0])
        client.send(query)
        return client.recv(65535)


class FixtureTests(unittest.TestCase):
    def test_dns_udp_tcp_wildcard_and_no_public_fallback(self):
        with tempfile.TemporaryDirectory(prefix="wdt-", dir="/tmp") as root:
            log = Path(root) / "dns.jsonl"
            with DNSFixture(log=log) as fixture:
                self.assertEqual(fixture.count(), 0)
                for tcp in (False, True):
                    name = uuid.uuid4().hex + ".fixtures.test"
                    response = query_dns(fixture.port, name, tcp=tcp)
                    ident, flags, questions, answers, _, _ = struct.unpack("!6H", response[:12])
                    self.assertEqual((ident, questions, answers), (1234, 1, 1))
                    self.assertEqual(flags & 0x840f, 0x8400)
                    self.assertEqual(response[-4:], socket.inet_aton("127.0.0.1"))
                    self.assertEqual(fixture.count(name), 1)
                    self.assertEqual(struct.unpack("!6H", query_dns(fixture.port, name, kind=28, tcp=tcp)[:12])[3], 0)
                    denied = query_dns(fixture.port, "unowned.test", tcp=tcp)
                    self.assertEqual(struct.unpack("!6H", denied[:12])[1] & 15, 5)
                self.assertEqual(fixture.count(), 6)
                records = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(records, fixture.events())
                self.assertEqual({event["transport"] for event in records}, {"udp", "tcp"})
            fixture.close()
            with DNSFixture(port=fixture.port):
                pass

    def test_dns_malformed_packets_are_not_logged_as_queries(self):
        with DNSFixture() as fixture:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.sendto(b"not DNS", ("127.0.0.1", fixture.port))
                cycle = struct.pack("!6H", 1, 0x100, 1, 0, 0, 0) + b"\xc0\x0c\x00\x01\x00\x01"
                client.sendto(cycle, ("127.0.0.1", fixture.port))
            query_dns(fixture.port, "valid.fixtures.test")
            self.assertEqual(fixture.count(), 1)

    def test_dns_suffix_must_be_owned_test_zone(self):
        for suffix in ("example.com", "localhost", "bad..test", "bad/name.test"):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                DNSFixture(suffix=suffix)

    def test_webtransport_certificate_real_handshake_connect_and_echo(self):
        try:
            from aioquic.asyncio import QuicConnectionProtocol, connect
            from aioquic.h3.connection import H3_ALPN, H3Connection
            from aioquic.h3.events import DatagramReceived, HeadersReceived
            from aioquic.quic.configuration import QuicConfiguration
            from aioquic.quic.events import ProtocolNegotiated
            from cryptography import x509
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec
        except ImportError as error:
            self.fail("System Python aioquic and cryptography are required: %s" % error)

        class Client(QuicConnectionProtocol):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.ready = asyncio.get_running_loop().create_future()
                self.echo = asyncio.get_running_loop().create_future()
                self.http = None

            def quic_event_received(self, event):
                if isinstance(event, ProtocolNegotiated):
                    self.http = H3Connection(self._quic, enable_webtransport=True)
                if self.http:
                    for item in self.http.handle_event(event):
                        if isinstance(item, HeadersReceived) and not self.ready.done():
                            self.ready.set_result(dict(item.headers))
                        if isinstance(item, DatagramReceived) and not self.echo.done():
                            self.echo.set_result(item.data)

        with WebTransportFixture() as fixture:
            certificate = x509.load_der_x509_certificate(fixture.certificate_der)
            self.assertIsInstance(certificate.public_key().curve, ec.SECP256R1)
            self.assertEqual(fixture.certificate_hash, hashlib.sha256(fixture.certificate_der).digest())
            self.assertLessEqual(certificate.not_valid_after_utc - certificate.not_valid_before_utc,
                                 datetime.timedelta(days=14))
            self.assertEqual(fixture.count(), 0)
            self.assertEqual(fixture.accepted_count(), 0)
            temporary = Path(fixture._temporary.name)

            async def exercise():
                configuration = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN,
                                                   max_datagram_frame_size=65536, idle_timeout=3)
                configuration.load_verify_locations(cadata=certificate.public_bytes(serialization.Encoding.PEM))
                async with asyncio.timeout(10):
                    async with connect("127.0.0.1", fixture.port, configuration=configuration,
                                       create_protocol=Client) as client:
                        await client.ping()
                        stream = client._quic.get_next_available_stream_id()
                        client.http.send_headers(stream, [
                            (b":method", b"CONNECT"), (b":scheme", b"https"),
                            (b":authority", ("127.0.0.1:%d" % fixture.port).encode()),
                            (b":path", b"/transport-positive"), (b":protocol", b"webtransport"),
                            (b"origin", b"http://127.0.0.1"),
                        ])
                        client.transmit()
                        self.assertEqual((await client.ready)[b":status"], b"200")
                        client.http.send_datagram(stream, b"wire-echo-positive")
                        client.transmit()
                        self.assertEqual(await client.echo, b"wire-echo-positive")
            asyncio.run(exercise())
            self.assertGreater(fixture.count(), 0)
            self.assertEqual(fixture.handshake_count(), 1)
            self.assertEqual(fixture.accepted_count(), 1)
            self.assertEqual(fixture.accepts()[0]["path"], "/transport-positive")
        self.assertFalse(temporary.exists())
        fixture.close()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", fixture.port))

    def test_fixture_start_failure_is_not_zero_traffic_success(self):
        with DNSFixture() as owner:
            fixture = DNSFixture(port=owner.port)
            with self.assertRaisesRegex(RuntimeError, "Address already in use"):
                fixture.start()
            self.assertFalse(fixture._thread.is_alive())
            with self.assertRaises(RuntimeError):
                fixture.count()


class NamespaceTests(unittest.TestCase):
    def test_veth_pair_is_private_connected_and_has_no_default_route(self):
        links = json.loads(subprocess.check_output(["ip", "-j", "-d", "link", "show"]))
        self.assertEqual({link["ifname"] for link in links}, {"lo", "wu0", "wu1"})
        veths = {link["ifname"]: link for link in links if link["ifname"] != "lo"}
        for name, peer in (("wu0", "wu1"), ("wu1", "wu0")):
            self.assertEqual(veths[name]["linkinfo"]["info_kind"], "veth")
            self.assertIn("UP", veths[name]["flags"])
            self.assertIn("LOWER_UP", veths[name]["flags"])
            self.assertEqual(veths[name]["link"], peer)
        addresses = json.loads(subprocess.check_output(["ip", "-j", "-4", "address", "show"]))
        actual = {(link["ifname"], address["local"], address["prefixlen"])
                  for link in addresses for address in link["addr_info"] if link["ifname"] != "lo"}
        self.assertEqual(actual, {("wu0", "10.203.0.1", 30), ("wu1", "10.203.0.2", 30)})
        for family in ("-4", "-6"):
            routes = json.loads(subprocess.check_output(["ip", "-j", family, "route", "show"]))
            self.assertFalse(any(route["dst"] == "default" for route in routes), routes)

    def test_namespace_init_reaps_adopted_children(self):
        read_fd, write_fd = os.pipe()
        parent = os.fork()
        if parent == 0:
            os.close(read_fd)
            if os.fork() == 0:
                os.write(write_fd, str(os.getpid()).encode())
                os.close(write_fd)
                time.sleep(0.1)
            os._exit(0)
        os.close(write_fd)
        try:
            orphan = int(os.read(read_fd, 100))
        finally:
            os.close(read_fd)
            os.waitpid(parent, 0)
        deadline = time.monotonic() + 3
        while Path("/proc/%d" % orphan).exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(Path("/proc/%d" % orphan).exists(), "Namespace PID 1 left an adopted zombie")

    def test_libc_resolves_only_through_real_isolated_dns(self):
        suffix = os.environ["SKETERM_TEST_DNS_HINT_HOST"]
        log = Path(os.environ["SKETERM_TEST_DNS_LOG"])
        self.assertTrue(suffix.endswith(".test"))
        self.assertEqual(Path("/etc/resolv.conf").read_text().splitlines()[0], "nameserver 127.0.0.1")
        self.assertIn("hosts: dns", Path("/etc/nsswitch.conf").read_text().splitlines())
        interfaces = {line.split(":", 1)[0].strip() for line in Path("/proc/net/dev").read_text().splitlines()[2:]}
        self.assertEqual(interfaces, {"lo", "wu0", "wu1"})
        # The rig runs as the real user in a nested user namespace (Chromium
        # will not sandbox as root), never in the init namespace.
        self.assertNotEqual(os.getuid(), 0)
        self.assertNotIn("4294967295", Path("/proc/self/uid_map").read_text())
        name = "libc-" + uuid.uuid4().hex + "." + suffix
        offset = log.stat().st_size
        addresses = {item[4][0] for item in socket.getaddrinfo(name, 80, socket.AF_INET, socket.SOCK_STREAM)}
        self.assertEqual(addresses, {"127.0.0.1"})
        for tcp in (False, True):
            self.assertEqual(query_dns(53, name, tcp=tcp)[-4:], socket.inet_aton("127.0.0.1"))
        with self.assertRaises(socket.gaierror):
            socket.getaddrinfo("outside-" + uuid.uuid4().hex + ".test", 80)
        with log.open() as stream:
            stream.seek(offset)
            records = [json.loads(line) for line in stream]
        self.assertEqual({event["transport"] for event in records if event["name"] == name}, {"udp", "tcp"})


class WrapperTests(unittest.TestCase):
    def test_resolver_mounts_are_private_and_command_status_is_preserved(self):
        paths = (Path("/etc/resolv.conf"), Path("/etc/nsswitch.conf"))
        before = [path.read_bytes() for path in paths]
        namespaces = [os.readlink("/proc/self/ns/" + kind) for kind in ("user", "mnt", "net", "pid")]
        probe = """
import json, os
from pathlib import Path
print('PROBE:' + json.dumps(dict(
    namespaces=[os.readlink('/proc/self/ns/' + kind) for kind in ('user','mnt','net','pid')],
    resolver=Path('/etc/resolv.conf').read_text(),
    nss=Path('/etc/nsswitch.conf').read_text(),
    log=os.environ['SKETERM_TEST_DNS_LOG'])), flush=True)
raise SystemExit(17)
"""
        result = subprocess.run(["bash", str(Path(__file__).with_name("test-web-untrusted-netns.sh")),
                                 "--", sys.executable, "-B", "-c", probe],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        facts = json.loads(next(line[6:] for line in result.stdout.splitlines() if line.startswith("PROBE:")))
        self.assertTrue(all(before != after for before, after in zip(namespaces, facts["namespaces"])))
        self.assertTrue(facts["resolver"].startswith("nameserver 127.0.0.1\n"))
        self.assertIn("\nhosts: dns\n", facts["nss"])
        self.assertFalse(Path(facts["log"]).parent.exists(), "Namespace scratch directory survived command exit")
        self.assertEqual([path.read_bytes() for path in paths], before, "Host resolver files changed")

    def test_direct_namespace_entry_is_refused_before_mounts(self):
        result = subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("web_untrusted_fixtures.py")),
                                 "_netns", "/tmp", "[]"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing resolver mounts", result.stderr)

    def test_wrapper_sigterm_and_sigkill_retire_exact_owned_descendants(self):
        libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        self.addCleanup(lambda: libc.prctl(36, previous.value, 0, 0, 0))
        def identity(pid):
            try:
                text = Path("/proc/%d/stat" % pid).read_text()
                return text[text.rfind(")") + 2:].split()[19]
            except FileNotFoundError:
                return None
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                probe = ("import os,time;print('SIGNAL_PROBE:'+os.environ['SKETERM_TEST_DNS_LOG'],flush=True);"
                         "time.sleep(60)")
                owned, root = {}, None
                with subprocess.Popen(["bash", str(Path(__file__).with_name("test-web-untrusted-netns.sh")),
                                       "--", sys.executable, "-B", "-c", probe],
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0) as child:
                    try:
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if not select.select([child.stdout], [], [], 0.1)[0]:
                                continue
                            line = child.stdout.readline().decode()
                            if line.startswith("SIGNAL_PROBE:"):
                                root = Path(line.strip().split(":", 1)[1]).parent
                                break
                            if not line:
                                break
                        self.assertIsNotNone(root, "Namespace signal control did not start")
                        pending = [child.pid]
                        while pending:
                            pid = pending.pop()
                            owned[pid] = identity(pid)
                            pending.extend(int(text) for text in
                                           Path("/proc/%d/task/%d/children" % (pid, pid)).read_text().split())
                        self.assertGreaterEqual(len(owned), 4, owned)
                        child.send_signal(sig)
                        child.wait(timeout=10)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            for pid in owned:
                                try:
                                    os.waitpid(pid, os.WNOHANG)
                                except ChildProcessError:
                                    pass
                            if all(identity(pid) != start for pid, start in owned.items()):
                                break
                            time.sleep(0.02)
                        self.assertTrue(all(identity(pid) != start for pid, start in owned.items()),
                                        "Wrapper signal left an owned namespace process alive: %r" % owned)
                    finally:
                        if child.poll() is None:
                            child.kill()
                            child.wait(timeout=10)
                        for pid, start in owned.items():
                            if identity(pid) == start:
                                os.kill(pid, signal.SIGKILL)
                                try:
                                    os.waitpid(pid, 0)
                                except ChildProcessError:
                                    pass
                        # SIGKILL prevents any process from running its TemporaryDirectory cleanup.
                        if root and root.parent == Path("/tmp") and root.name.startswith("wn-") and root.exists():
                            shutil.rmtree(root)


def browser_controls(options):
    spec = importlib.util.spec_from_file_location("web_untrusted_rig", Path(__file__).with_name("test-web-untrusted.py"))
    rig = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rig)
    binary = options.bin_dir.resolve() / "sketerm-mcp"
    helper = options.bin_dir.resolve() / "sketerm-webengine"
    for path in (binary, helper):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError("Built executable missing: %s (this test never builds)" % path)
    rig.OPTIONS = argparse.Namespace(command=[str(binary), "--no-record"], helper=helper,
                                     timeout=60, observe=3)

    class BrowserControls(rig.WebUntrustedTests):
        def test_real_webrtc_stun_and_turn_packets(self):
            for transport in ("stun", "turn-tcp", "turn-tls"):
                for mode in (False, True):
                    with self.subTest(transport=transport, untrusted=mode), rig.PacketContext(udp=transport == "stun") as fixture:
                        self.assertEqual(fixture.sock.getsockname()[0], "127.0.0.1")
                        pane = self.open(untrusted=mode)
                        url = ("stun:127.0.0.1:%d" if transport == "stun" else
                               "turn:127.0.0.1:%d?transport=tcp" if transport == "turn-tcp" else
                               "turns:127.0.0.1:%d?transport=tcp") % fixture.port
                        outcome = self.mcp.evaluate(pane, """
const start=performance.now();let pc=null;const result={};
try {
  pc=new RTCPeerConnection({iceServers:[{urls:%s,username:'rig',credential:'rig'}]});
  pc.createDataChannel('control');
  await pc.setLocalDescription(await pc.createOffer());
  result.description=true;
} catch(e) {result.error=e.name;}
await new Promise(r=>setTimeout(r,3000));
result.duration=performance.now()-start;
if(pc) {result.gathering=pc.iceGatheringState;pc.close();}
return result;
""" % json.dumps(url))
                        count = fixture.count()
                        with fixture.lock:
                            bindings = sum(len(packet) >= 20 and packet[:2] == b"\x00\x01" and
                                           packet[4:8] == b"\x21\x12\xa4\x42" for packet in fixture.packets)
                        print("Browser WebRTC: transport=%s untrusted=%s %s=%d STUN-bindings=%d outcome=%s" % (
                            transport, mode, "UDP" if transport == "stun" else "TCP-accepts", count,
                            bindings, outcome), flush=True)
                        self.assertGreaterEqual(outcome["duration"], 2950)
                        if mode:
                            self.assertEqual(count, 0, "Untrusted WebRTC emitted traffic")
                        else:
                            self.assertTrue(outcome.get("description"), outcome)
                            self.assertGreater(count, 0, "Ordinary %s emitted no traffic; denial is unproven" % transport)
                            if transport == "stun":
                                self.assertEqual(bindings, count, "Fixture received traffic other than STUN binding requests")
                        self.mcp.tool("web_close", pane=pane)

        def test_successful_webtransport_and_zero_untrusted_udp(self):
            for mode in (False, True):
                with self.subTest(untrusted=mode), WebTransportFixture() as fixture:
                    pane = self.open(untrusted=mode)
                    outcome = self.mcp.evaluate(pane, """
const result={present:typeof WebTransport==='function',secure:isSecureContext};
let transport, timer;
try {
  transport=new WebTransport(%s, {serverCertificateHashes:[
    {algorithm:'sha-256',value:new Uint8Array(%s)}]});
  transport.closed.catch(()=>{});
  result.ready=await Promise.race([transport.ready.then(()=>true,e=>{
    result.error=e.name;result.message=e.message;return false;
  }),new Promise(r=>timer=setTimeout(()=>r('timeout'),8000))]);
} catch(e) {result.error=e.name;result.message=e.message;result.ready=false;}
finally {clearTimeout(timer);if(transport)transport.close();}
await new Promise(r=>setTimeout(r,3000));return result;
""" % (json.dumps(fixture.url()), json.dumps(list(fixture.certificate_hash))))
                    print("Browser WebTransport: untrusted=%s outcome=%s UDP=%d handshakes=%d CONNECTs=%d" % (
                        mode, outcome, fixture.count(), fixture.handshake_count(), fixture.accepted_count()), flush=True)
                    self.assertTrue(outcome["present"])
                    self.assertTrue(outcome["secure"])
                    if mode:
                        self.assertIsNot(outcome["ready"], True)
                        self.assertEqual(fixture.count(), 0)
                        self.assertEqual(fixture.accepted_count(), 0)
                    else:
                        self.assertIs(outcome["ready"], True)
                        self.assertGreater(fixture.count(), 0)
                        self.assertGreater(fixture.handshake_count(), 0)
                        self.assertEqual(fixture.accepted_count(), 1)
                    self.mcp.tool("web_close", pane=pane)

        def test_real_dns_hints(self):
            suffix = os.environ["SKETERM_TEST_DNS_HINT_HOST"]
            log = Path(os.environ["SKETERM_TEST_DNS_LOG"])
            for hint in ("dns-prefetch", "preconnect"):
                for mode in (False, True):
                    with self.subTest(hint=hint, untrusted=mode):
                        host = "%s-%s-%s.%s" % (self.token, hint, str(mode).lower(), suffix)
                        offset = log.stat().st_size
                        url = self.p1.url("/page/" + host, **{hint: "http://" + host + ":%d" % self.p2.server_port})
                        # The ephemeral control emitted no hints; a named ordinary context does.
                        # Its on-disk profile remains below the rig's isolated XDG root.
                        facts = self.mcp.tool("web_open", url=url, snapshot="none", route="direct",
                                              **({"ephemeral": True} if mode else {"profile": "dns-control"}),
                                              policy=dict(allow_hosts=["127.0.0.1:%d" % self.p1.server_port]
                                                          if mode else ["127.0.0.1"], block_ads=False,
                                                          allow_private_addresses=True, untrusted=mode))
                        pane = facts["view"]
                        self.assertEqual(self.mcp.evaluate(pane, "return document.title;"), "Untrusted integration fixture")
                        def queries():
                            with log.open("rb") as stream:
                                stream.seek(offset)
                                return host.encode() in stream.read().lower()
                        if mode:
                            deadline = time.monotonic() + 3
                            while time.monotonic() < deadline:
                                self.assertFalse(queries(), "Untrusted %s emitted DNS" % hint)
                                time.sleep(0.05)
                        else:
                            rig.eventually(queries, 8, "ordinary %s wire DNS query" % hint)
                        print("Browser DNS hint: %s untrusted=%s query=%s" % (hint, mode, queries()), flush=True)
                        self.mcp.tool("web_close", pane=pane)

    suite = unittest.TestSuite()
    if options.browser_test in (None, "webrtc"):
        suite.addTest(BrowserControls("test_real_webrtc_stun_and_turn_packets"))
    if options.browser_test in (None, "webtransport"):
        suite.addTest(BrowserControls("test_successful_webtransport_and_zero_untrusted_udp"))
    if options.netns and options.browser_test in (None, "dns"):
        suite.addTest(BrowserControls("test_real_dns_hints"))
    return suite


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--netns", action="store_true", help="Also test the wrapper's isolated libc resolver")
    parser.add_argument("--browser", action="store_true", help="Also test already-built MCP/browser positive and negative controls")
    parser.add_argument("--browser-test", choices=("dns", "webtransport", "webrtc"), help="Select one browser control for diagnosis")
    parser.add_argument("--bin-dir", type=Path, default=Path(__file__).resolve().parent.parent / "zig-out/bin")
    options = parser.parse_args()
    if options.browser_test and not options.browser:
        parser.error("--browser-test requires --browser")
    if options.browser_test in ("dns", "webrtc") and not options.netns:
        parser.error("--browser-test %s requires the namespace wrapper and --netns" % options.browser_test)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(FixtureTests)
    if options.netns:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(NamespaceTests))
    else:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(WrapperTests))
    if options.browser:
        suite.addTests(browser_controls(options))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
