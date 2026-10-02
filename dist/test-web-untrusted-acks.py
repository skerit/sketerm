#!/usr/bin/env python3
"""Validate native policy/media ACK failures against real CEF and loopback fixtures."""

import argparse
import array
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import socket
import struct
import sys
import tempfile
import time
import unittest


spec = importlib.util.spec_from_file_location("web_untrusted_rig", Path(__file__).with_name("test-web-untrusted.py"))
rig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rig)


class LoopbackFixture(rig.HTTPFixture):
    def server_bind(self):
        self.server_address = ("127.0.0.1", 0)
        http.server.ThreadingHTTPServer.server_bind(self)


def wire_string(value):
    encoded = value.encode()
    return struct.pack("<H", len(encoded)) + encoded


class NativeClient:
    """Use the helper's existing local protocol without a remote debugging port."""

    def __init__(self, mcp):
        self.events = []
        self.buffer = bytearray()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        processes = mcp.refresh_processes()
        candidates = [info for info in processes if "--socket" in info["argv"]
                      and not any(arg.startswith("--type=") for arg in info["argv"])]
        sockets = {info["argv"][info["argv"].index("--socket") + 1] for info in candidates}
        rig.require(len(sockets) == 1, "Expected one owned helper socket: %r" % sockets)
        self.sock.connect(sockets.pop())
        self.send(0x01, struct.pack("<I", 1) + wire_string("acks-native"))
        ack = self.wait(0x02)
        offset = 4
        for _ in range(2):
            length = struct.unpack_from("<H", ack, offset)[0]
            offset += 2 + length
        count = struct.unpack_from("<H", ack, offset)[0]
        offset += 2
        self.caps = set()
        for _ in range(count):
            length = struct.unpack_from("<H", ack, offset)[0]
            offset += 2
            self.caps.add(ack[offset:offset + length].decode())
            offset += length
        rig.require({"net-policy-ack", "web-emulation", "semantic"} <= self.caps,
                    "Native ACK capabilities missing: %r" % self.caps)

    def send(self, tag, payload):
        self.sock.sendall(struct.pack("<IB", 1 + len(payload), tag) + payload)

    def pump(self, timeout=0):
        if select.select([self.sock], [], [], timeout)[0]:
            data, ancillary, flags, _ = self.sock.recvmsg(65536, socket.CMSG_SPACE(64 * 4))
            for level, kind, payload in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    descriptors = array.array("i")
                    descriptors.frombytes(payload[:len(payload) - len(payload) % descriptors.itemsize])
                    for fd in descriptors:
                        os.close(fd)
            rig.require(not flags & socket.MSG_CTRUNC, "Native frame descriptors were truncated")
            rig.require(data, "Real helper closed the native connection")
            self.buffer.extend(data)
        while len(self.buffer) >= 4:
            length = struct.unpack_from("<I", self.buffer)[0]
            rig.require(1 <= length <= 16 * 1024 * 1024, "Invalid native frame length")
            if len(self.buffer) < length + 4:
                break
            tag, payload = self.buffer[4], bytes(self.buffer[5:4 + length])
            del self.buffer[:4 + length]
            self.events.append((tag, payload))

    def wait(self, tag, predicate=lambda _: True, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            for index, (kind, payload) in enumerate(self.events):
                if kind == tag and predicate(payload):
                    self.events.pop(index)
                    return payload
            remaining = deadline - time.monotonic()
            rig.require(remaining > 0, "Native helper did not answer tag 0x%x" % tag)
            self.pump(min(remaining, 0.1))

    def observe(self):
        rig.require("observe" in self.caps, "Native observer is not advertised")
        self.send(0xF0, b"\x01")
        self.wait(0xF1, lambda payload: payload[8] == 1)
        self.events.clear()

    def evaluate(self, code):
        encoded = code.encode()
        self.send(0xA0, struct.pack("<IBII", 7, 0, 5000, len(encoded)) + encoded + struct.pack("<I", 60000))
        result = self.wait(0xA1, lambda payload: struct.unpack_from("<I", payload)[0] == 7)
        rig.require(result[4] == 1, "Native eval failed: %r" % result)
        length = struct.unpack_from("<I", result, 5)[0]
        value = json.loads(result[9:9 + length])
        return value.get("value", value) if isinstance(value, dict) else value

    def media(self, color, motion):
        self.send(0x1A, struct.pack("<IBBH", 7, color, motion, 0))

    def open_media(self, url, host, untrusted):
        self.send(0x90, struct.pack("<IB", 7, 1) + wire_string("") + wire_string(""))
        policy = struct.pack("<IIIHHIQIIH", 7, 1, 3 if untrusted else 1, 0, 3, 0, 0, 0, 0, 1)
        self.send(0x86, policy + wire_string(host) + struct.pack("<H", 0))
        ack = self.wait(0x88, lambda payload: struct.unpack_from("<II", payload) == (7, 1))
        rig.require(ack[8] == 1, "Native media control policy refused")
        self.media(2, 1)
        self.send(0x16, struct.pack("<IHHHI", 7, 640, 480, 1000, 7) + wire_string(url))
        self.wait(0x40, lambda payload: struct.unpack_from("<I", payload)[0] == 7 and payload[4] == 2
                  and not payload[7:].startswith(b"about:"))

    def navigate(self, url):
        self.send(0x18, struct.pack("<I", 7) + wire_string(url))

    def close(self):
        self.sock.close()


class AckTests(rig.WebUntrustedTests):
    @classmethod
    def setUpClass(cls):
        cls.p1 = LoopbackFixture()
        cls.addClassCleanup(cls.p1.close)
        cls.p2 = LoopbackFixture()
        cls.addClassCleanup(cls.p2.close)

    def tearDown(self):
        super().tearDown()
        if any(test is self or getattr(test, "test_case", None) is self
               for test, _ in self._outcome.result.failures + self._outcome.result.errors):
            for mcp in getattr(self, "fault_clients", []):
                mcp.diagnostics()
                print("--- Native ACK seam stderr ---\n" + self.native_log(mcp), file=sys.stderr)

    def fault_mcp(self, env):
        mcp = self.new_mcp(env)
        if not hasattr(self, "fault_clients"):
            self.fault_clients = []
        self.fault_clients.append(mcp)
        return mcp

    def native_log(self, mcp):
        path = mcp.root / "s/acks-native.log"
        return path.read_text(errors="replace") if path.exists() else ""

    def page(self, label):
        path = "/page/" + self.token + "-" + label
        self.p1.asset(path, b"""<!doctype html><html><head><meta charset="utf-8">
<title>Untrusted integration fixture</title><link rel="icon" href="data:image/x-icon,">
<script>window.firstDocument={dark:matchMedia('(prefers-color-scheme: dark)').matches,
reduce:matchMedia('(prefers-reduced-motion: reduce)').matches};</script>
</head><body><h1>ACK fixture ready</h1></body></html>""", "text/html; charset=utf-8")
        return path

    def policy(self, untrusted):
        return dict(untrusted=untrusted, allow_hosts=["127.0.0.1:%d" % self.p1.server_port],
                    allow_private_addresses=True, block_ads=False, max_requests=100)

    def open_client(self, mcp, path, untrusted, media=False):
        result = mcp.tool("web_open", url=self.p1.url(path), snapshot="none", ephemeral=True,
                          route="direct", policy=self.policy(untrusted), timeout_ms=20000,
                          **(dict(color_scheme="dark", reduced_motion="reduce") if media else {}))
        self.assertFalse(result.get("loading"), result)
        self.assertFalse(result.get("load_error"), result)
        self.assertTrue(result["policy_active"], result)
        self.assertEqual(mcp.evaluate(result["view"], "return document.title;"), "Untrusted integration fixture")
        self.assertGreater(len(self.p1.matching(path, "GET")), 0)
        return result["view"]

    def live_counterpart(self, mcp, pane, label):
        before = mcp.tool("web_policy", pane=pane)
        updated = mcp.tool("web_policy_set", pane=pane, policy=dict(max_requests=90))
        self.assertEqual(updated["tightened"], ["max_requests"], updated)
        self.assertEqual(updated["policy"]["max_requests"], 90)
        after = mcp.tool("web_policy", pane=pane)
        self.assertGreater(after["policy_serial"], before["policy_serial"])
        self.assertEqual(after["requests"], before["requests"])
        self.assertEqual(after["bytes"], before["bytes"])
        target = self.path(label)
        value = mcp.evaluate(pane, "return await (async()=>{const r=await fetch(%s);return await r.text();})()" %
                             json.dumps(self.p1.url(target)))
        self.assertEqual(value, "fixture-ok")
        self.assertGreater(len(self.p1.matching(target, "GET")), 0)

    def assert_survivor(self, mcp, pane, helper, label):
        self.assertIsNotNone(rig.same_process(helper), "Failure retired the unaffected helper")
        self.assertIsNone(mcp.unusable, "Failure poisoned the whole MCP connection")
        self.assertEqual([view["view"] for view in mcp.tool("web_tabs")["views"]], [pane])
        target = self.path(label)
        outcome = mcp.evaluate(pane, "return await (async()=>{const r=await fetch(%s);return await r.text();})()" %
                               json.dumps(self.p1.url(target)))
        self.assertEqual(outcome, "fixture-ok")
        self.assertGreater(len(self.p1.matching(target, "GET")), 0)

    def helper_identity(self, mcp, untrusted):
        if untrusted:
            return mcp.untrusted_helper()[1]
        return rig.eventually(lambda: next((info for info in mcp.refresh_processes()
                                           if "--socket" in info["argv"]
                                           and not any(arg.startswith("--type=") for arg in info["argv"])), None),
                              5, "owned native helper")

    def policy_failure(self, mode, replacement):
        for untrusted in (False, True):
            with self.subTest(fault=mode, replacement=replacement, untrusted=untrusted):
                control = self.open_client(self.mcp, self.page("control-%s-%s-%s" % (mode, replacement, untrusted)), untrusted)
                self.live_counterpart(self.mcp, control, "control-update-%s-%s-%s" % (mode, replacement, untrusted))
                self.mcp.tool("web_close", pane=control)
                ordinal = 4 if replacement else 2
                mcp = self.fault_mcp(dict(SKETERM_WEB_FAULT_POLICY_INSTALL=str(ordinal), SKETERM_WEB_FAULT_POLICY_ACK=mode))
                survivor = self.open_client(mcp, self.page("survivor-%s-%s-%s" % (mode, replacement, untrusted)), untrusted)
                helper = self.helper_identity(mcp, untrusted)
                native = NativeClient(mcp)
                self.addCleanup(native.close)
                if not untrusted:
                    native.observe()
                denied = self.page("denied-%s-%s-%s" % (mode, replacement, untrusted))
                if replacement:
                    affected = self.open_client(mcp, self.page("affected-%s-%s" % (mode, untrusted)), untrusted)
                    self.live_counterpart(mcp, affected, "affected-update-%s-%s" % (mode, untrusted))
                    native.pump(0.1)
                    if not untrusted:
                        self.assertEqual(sum(tag == 0xF1 and payload[8] == 1 for tag, payload in native.events), 1,
                                         "Real browser creation positive control was not announced")
                    native.events.clear()
                    arguments = dict(pane=affected, policy=dict(max_requests=80))
                    tool = "web_policy_set"
                else:
                    arguments = dict(url=self.p1.url(denied), snapshot="none", ephemeral=True, route="direct",
                                     policy=self.policy(untrusted), timeout_ms=20000)
                    tool = "web_open"
                started = time.monotonic()
                result = mcp.raw_tool(tool, **arguments)
                elapsed = time.monotonic() - started
                self.assertIs(result.get("isError"), True, result)
                error = result["structuredContent"]["error"]
                self.assertEqual(error["code"], "refused" if mode == "oom" else "timeout", result)
                self.assertIn("closed fail-closed", error["message"])
                self.assertEqual(set(result["structuredContent"]), {"error"},
                                 "Failed ACK reported a replacement grant or success facts")
                if mode != "oom":
                    self.assertGreaterEqual(elapsed, 4.5, "A stale/missing ACK was accepted without awaiting the deadline")
                    self.assertLess(elapsed, 12, "Policy ACK deadline did not bound the view failure")
                log = self.native_log(mcp)
                self.assertRegex(log, r"fault policy %s view=\d+ serial=\d+ browser=%s" %
                                 (mode, "true" if replacement else "false"))
                if replacement:
                    stopped = mcp.raw_tool("web_navigate", pane=affected, url=self.p1.url(denied))
                    self.assertIs(stopped.get("isError"), True, stopped)
                    self.assertEqual(stopped["structuredContent"]["error"]["code"], "not_found")
                self.assert_no_hits(self.p1, denied)
                native.pump(0.1)
                if not untrusted:
                    announcements = [(tag, payload) for tag, payload in native.events if tag == 0xF1]
                    self.assertEqual(sum(payload[8] == 1 for _, payload in announcements), 0,
                                     "Initial policy failure created a real browser")
                    self.assertEqual(sum(payload[8] == 0 for _, payload in announcements), int(replacement),
                                     "Replacement failure did not destroy only the affected browser")
                self.assert_survivor(mcp, survivor, helper, "survivor-after-%s-%s-%s" % (mode, replacement, untrusted))
                native.close()
                mcp.tool("web_close", pane=survivor)

    def test_policy_initial_oom(self):
        self.policy_failure("oom", False)

    def test_policy_replacement_oom(self):
        self.policy_failure("oom", True)

    def test_policy_drop_ack(self):
        for replacement in (False, True):
            self.policy_failure("drop", replacement)

    def test_policy_stale_ack(self):
        for replacement in (False, True):
            self.policy_failure("stale", replacement)

    def media_failure(self, mode):
        for untrusted in (False, True):
            for replacement in (False, True):
                with self.subTest(fault=mode, replacement=replacement, untrusted=untrusted):
                    mcp = self.fault_mcp(dict(SKETERM_WEB_FAULT_MEDIA_APPLY="3", SKETERM_WEB_FAULT_MEDIA_ACK=mode))
                    survivor = self.open_client(mcp, self.page("media-survivor-%s-%s-%s" % (mode, replacement, untrusted)),
                                                untrusted)
                    helper = self.helper_identity(mcp, untrusted)
                    native = NativeClient(mcp)
                    self.addCleanup(native.close)
                    control_path = self.page("media-control-%s-%s-%s" % (mode, replacement, untrusted))
                    native.open_media(self.p1.url(control_path), "127.0.0.1:%d" % self.p1.server_port, untrusted)
                    self.assertEqual(native.evaluate("firstDocument"), dict(dark=True, reduce=True))
                    self.assertGreater(len(self.p1.matching(control_path, "GET")), 0)
                    native.media(1, 2)
                    rig.eventually(lambda: native.evaluate("({dark:matchMedia('(prefers-color-scheme: dark)').matches,"
                                                          "reduce:matchMedia('(prefers-reduced-motion: reduce)').matches})") ==
                                   dict(dark=False, reduce=False), 5, "native live media update")
                    self.assertEqual(native.evaluate("firstDocument"), dict(dark=True, reduce=True))
                    control_nav = self.page("media-navigation-control-%s-%s-%s" % (mode, replacement, untrusted))
                    native.navigate(self.p1.url(control_nav))
                    native.wait(0x40, lambda payload: payload[4] == 2 and payload[7:] == self.p1.url(control_nav).encode())
                    self.assertEqual(native.evaluate("firstDocument"), dict(dark=False, reduce=False))
                    self.assertGreater(len(self.p1.matching(control_nav, "GET")), 0)
                    if replacement:
                        started = time.monotonic()
                        native.media(2, 1)
                        failure = native.wait(0x92, lambda payload: struct.unpack_from("<I", payload)[0] == 7)
                        length = struct.unpack_from("<H", failure, 8)[0]
                        message = failure[10:10 + length].decode()
                    else:
                        control_path = self.page("media-initial-denied-%s-%s" % (mode, untrusted))
                        started = time.monotonic()
                        result = mcp.raw_tool("web_open", url=self.p1.url(control_path), snapshot="none", ephemeral=True,
                                              route="direct", policy=self.policy(untrusted), timeout_ms=20000,
                                              color_scheme="dark", reduced_motion="reduce")
                        self.assertIs(result.get("isError"), True, result)
                        message = result["structuredContent"]["error"]["message"]
                    elapsed = time.monotonic() - started
                    self.assertIn("engine rejected media emulation" if mode == "reject" else
                                  "media emulation execution acknowledgment timed out", message)
                    log = self.native_log(mcp)
                    self.assertRegex(log, r"fault media %s browser=\d+ message=[1-9]\d*" % mode)
                    if mode == "drop":
                        self.assertRegex(log, r"fault media drop browser=\d+ message=[1-9]\d* success=1")
                        self.assertGreaterEqual(elapsed, 4.5)
                        self.assertLess(elapsed, 12)
                    if replacement:
                        denied = self.page("media-retired-%s-%s" % (mode, untrusted))
                        native.navigate(self.p1.url(denied))
                        native.send(0x87, struct.pack("<II", 7, 99))
                        retired = native.wait(0x88, lambda payload: struct.unpack_from("<II", payload) == (7, 99))
                        self.assertEqual(retired[8], 0, "Retired media view retained an active native policy")
                        self.assert_no_hits(self.p1, denied)
                    else:
                        self.assert_no_hits(self.p1, control_path)
                        self.assertEqual(native.evaluate("firstDocument"), dict(dark=False, reduce=False),
                                         "Initial failure retired an unaffected native view/connection")
                    self.assert_survivor(mcp, survivor, helper, "media-survivor-after-%s-%s-%s" % (mode, replacement, untrusted))
                    # A later media-enabled tab still works on the same helper/connection.
                    recovered = self.open_client(mcp, self.page("media-recovered-%s-%s-%s" % (mode, replacement, untrusted)),
                                                 untrusted, media=True)
                    self.assertEqual(mcp.evaluate(recovered, "return firstDocument;"), dict(dark=True, reduce=True))
                    mcp.tool("web_close", pane=recovered)
                    native.close()
                    mcp.tool("web_close", pane=survivor)

    def test_media_native_reject(self):
        self.media_failure("reject")

    def test_media_native_drop(self):
        self.media_failure("drop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=rig.REPO / "zig-out/bin")
    parser.add_argument("--helper", type=Path, help="Fresh helper (default SKETERM_WEB_BIN or built sibling)")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--observe", type=float, default=3)
    parser.add_argument("--test", action="append", help="Select only methods defined by this ACK runner")
    options = parser.parse_args()
    if sys.platform != "linux" or not hasattr(os, "pidfd_open") or not hasattr(rig.signal, "pidfd_send_signal"):
        parser.error("Linux /proc and reuse-safe pidfd process cleanup are required")
    if not 15 <= options.timeout <= 140 or not 1 <= options.observe <= 10:
        parser.error("--timeout must be 15..140 and --observe 1..10 seconds")
    binary = options.bin_dir.resolve() / "sketerm-mcp"
    helper = (options.helper or Path(os.environ.get("SKETERM_WEB_BIN", str(options.bin_dir / "sketerm-webengine")))).resolve()
    for path in (binary, helper):
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error("Built executable missing: %s (this runner never builds)" % path)
    methods = sorted(name for name in AckTests.__dict__ if name.startswith("test_"))
    for name in options.test or []:
        if name not in methods:
            parser.error("Not an ACK test method: " + name)
    with tempfile.TemporaryDirectory(prefix="wa-", dir="/tmp") as temporary:
        root = Path(temporary)
        pinned_mcp, pinned_helper = root / "sketerm-mcp", root / "sketerm-webengine"
        for source, target in ((binary, pinned_mcp), (helper, pinned_helper)):
            shutil.copy2(source, target)
            print("Pinned %s: bytes=%d sha256=%s" % (source, target.stat().st_size,
                                                    hashlib.sha256(target.read_bytes()).hexdigest()), flush=True)
        wrapper = root / "ack-helper"
        wrapper.write_text('#!/bin/sh\nexec %s "$@" 2>>"$XDG_STATE_HOME/acks-native.log"\n' %
                           shlex.quote(str(pinned_helper)), encoding="ascii")
        wrapper.chmod(0o700)
        rig.OPTIONS = argparse.Namespace(command=[str(pinned_mcp), "--no-record"], helper=wrapper,
                                         timeout=options.timeout, observe=options.observe)
        print("SKETERM_WEB_BIN=" + str(wrapper), flush=True)
        print("Only ACK methods run; loopback only, isolated XDG, exact-PID cleanup, no build/install/debugging port.", flush=True)
        suite = unittest.TestSuite(AckTests(name) for name in options.test or methods)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
