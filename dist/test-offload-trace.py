#!/usr/bin/env python3
"""Check offload surface generations rather than GTK's enabled property."""

import argparse
import collections
import pathlib
import re
import unittest


def inspect_trace(text, limit):
    generations = collections.Counter()
    surfaces = {}
    children = set()
    destroyed = set()
    callbacks = {}
    requests = collections.Counter()
    pending = collections.Counter()
    peaks = collections.Counter()
    for line in text.splitlines():
        match = re.search(r"new id wl_surface[#@](\d+)", line)
        if match:
            sid = int(match[1])
            generations[sid] += 1
            surfaces[sid] = (sid, generations[sid])
        match = re.search(r"\.get_subsurface\(new id wl_subsurface[#@]\d+, wl_surface[#@](\d+),", line)
        if match:
            children.add(surfaces[int(match[1])])
        match = re.search(r"wl_surface[#@](\d+)\.frame\(new id wl_callback[#@](\d+)\)", line)
        if match:
            sid, cid = map(int, match.groups())
            surface = surfaces[sid]
            if cid in callbacks:
                raise ValueError("callback id reused before retirement")
            callbacks[cid] = surface
            requests[surface] += 1
            pending[surface] += 1
            peaks[surface] = max(peaks[surface], pending[surface])
        match = re.search(r"wl_display[#@]\d+\.delete_id\((\d+)\)", line)
        if match:
            surface = callbacks.pop(int(match[1]), None)
            if surface is not None:
                pending[surface] -= 1
        match = re.search(r"wl_surface[#@](\d+)\.destroy\(", line)
        if match:
            destroyed.add(surfaces[int(match[1])])
    exercised = children.intersection(requests)
    if not exercised:
        raise ValueError("no offload surface requested a frame callback")
    for surface in exercised:
        if requests[surface] > limit:
            raise ValueError(f"surface {surface} issued {requests[surface]} callbacks; limit {limit}")
        if surface not in destroyed:
            raise ValueError(f"offload surface {surface} was not destroyed")
    return len(exercised), max(requests[s] for s in exercised), max(peaks[s] for s in exercised)


class TraceTests(unittest.TestCase):
    create = "new id wl_surface#4\n.get_subsurface(new id wl_subsurface#5, wl_surface#4, wl_surface#1)\n"
    request = "wl_surface#4.frame(new id wl_callback#6)\n"
    retire = "wl_display#1.delete_id(6)\nwl_callback#6.done(100)\n"
    destroy = "wl_surface#4.destroy()\n"

    def test_delete_before_done_is_retired_once(self):
        trace = self.create + (self.request + self.retire) * 3 + self.destroy
        self.assertEqual(inspect_trace(trace, 3), (1, 3, 1))

    def test_surface_id_reuse_starts_new_generation(self):
        trace = self.create + self.request + self.retire + self.destroy
        self.assertEqual(inspect_trace(trace * 2, 1), (2, 1, 1))

    def test_retained_generation_fails_even_if_callbacks_finish(self):
        trace = self.create + (self.request + self.retire) * 4 + self.destroy
        with self.assertRaisesRegex(ValueError, "issued 4 callbacks"):
            inspect_trace(trace, 3)

    def test_undestroyed_generation_fails(self):
        with self.assertRaisesRegex(ValueError, "was not destroyed"):
            inspect_trace(self.create + self.request, 3)

    def test_empty_trace_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, "no offload surface"):
            inspect_trace("", 3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="?", type=pathlib.Path)
    parser.add_argument("--limit", type=int, default=160)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        unittest.main(argv=[__file__])
    if args.trace is None:
        parser.error("a trace path is required")
    try:
        count, requests, pending = inspect_trace(args.trace.read_text(), args.limit)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(f"PASS: {count} offload generations retired; maximum {requests} requests and {pending} pending callbacks per generation")
