#!/usr/bin/env python3
"""Summarizes a Spall trace (fire:prof, `pads --trace FILE`) per thread and zone.

    python3 scripts/prof.py trace.spall                # every thread, top 25 zones by self time
    python3 scripts/prof.py trace.spall --top 50 --thread audio
    python3 scripts/prof.py trace.spall --per frame    # each zone's time per "frame" zone
    python3 scripts/prof.py a.spall b.spall --compare  # before and after, zone by zone
    python3 scripts/prof.py trace.spall --budget graph=5333   # a zone's calls against a budget (µs)

For each zone: calls, total and self time (self: less the zones inside it),
the median and 99th percentile of one call, and its share of the thread's
recorded time. `--per ZONE` adds each zone's time per call of ZONE (per
frame, per audio callback). The Spall viewer (gravitymoth.com/spall) shows
the same file as a timeline.
"""

import argparse
import struct
import sys
from collections import defaultdict

MAGIC = 0x0BADF00D
BEGIN, END, INSTANT, PAD_SKIP, NAME_PROCESS, NAME_THREAD = 3, 4, 5, 7, 8, 9


class Zone:
    __slots__ = ("calls", "total", "self_", "durations")

    def __init__(self):
        self.calls, self.total, self.self_, self.durations = 0, 0.0, 0.0, []


def parse(path):
    """Per thread: its name and {zone: Zone}, its recorded span, and the
    durations of every call (ns)."""
    data = open(path, "rb").read()
    magic, version, scale, _ = struct.unpack_from("<QQdQ", data, 0)
    if magic != MAGIC:
        sys.exit(f"{path}: not a Spall trace")
    at = 32
    threads = {}  # tid -> dict(name, zones, stack, first, last)

    def thread(tid):
        t = threads.get(tid)
        if t is None:
            t = threads[tid] = {"name": f"thread {tid}", "zones": defaultdict(Zone), "stack": [], "first": None, "last": 0, "top": 0.0}
        return t

    while at + 20 <= len(data):
        size, tid, pid, first_ts = struct.unpack_from("<IIIQ", data, at)
        at += 20
        end = at + size
        t = thread(tid)
        p = at
        while p < end:
            kind = data[p]
            if kind == BEGIN:
                ts, nl, al = struct.unpack_from("<QBB", data, p + 1)
                name = data[p + 11 : p + 11 + nl].decode("utf-8", "replace")
                p += 11 + nl + al
                t["stack"].append([name, ts * scale, 0.0])
                if t["first"] is None:
                    t["first"] = ts * scale
            elif kind == END:
                (ts,) = struct.unpack_from("<Q", data, p + 1)
                p += 9
                if not t["stack"]:
                    continue
                name, start, inner = t["stack"].pop()
                dur = ts * scale - start
                z = t["zones"][name]
                z.calls += 1
                z.total += dur
                z.self_ += dur - inner
                z.durations.append(dur)
                if t["stack"]:
                    t["stack"][-1][2] += dur
                else:
                    t["top"] += dur
                t["last"] = max(t["last"], ts * scale)
            elif kind in (NAME_THREAD, NAME_PROCESS):
                nl = data[p + 1]
                name = data[p + 2 : p + 2 + nl].decode("utf-8", "replace")
                if kind == NAME_THREAD:
                    t["name"] = name
                p += 2 + nl
            elif kind == PAD_SKIP:
                (n,) = struct.unpack_from("<I", data, p + 1)
                p += n
            elif kind == INSTANT:
                ts, nl, al = struct.unpack_from("<QBB", data, p + 1)
                p += 11 + nl + al
            else:
                break  # (an unknown event: the rest of this buffer is skipped)
        at = end
    return threads


def ms(ns):
    return ns / 1e6


def us(ns):
    return ns / 1e3


def pct(durs, q):
    s = sorted(durs)
    return s[min(len(s) - 1, int(len(s) * q))] if s else 0.0


def merged(threads):
    """Threads with the same name merged (graph workers)."""
    out = {}
    for t in threads.values():
        m = out.setdefault(t["name"], {"name": t["name"], "zones": defaultdict(Zone), "top": 0.0, "count": 0})
        m["count"] += 1
        m["top"] += t["top"]
        for name, z in t["zones"].items():
            d = m["zones"][name]
            d.calls += z.calls
            d.total += z.total
            d.self_ += z.self_
            d.durations.extend(z.durations)
    return out


def budget_lines(threads, spec):
    """`ZONE=US`: that zone's calls (on every thread) against a budget of US µs
    a call (an audio block's length, a frame's)."""
    zone, _, limit = spec.partition("=")
    limit = float(limit) * 1e3
    durs = [d for t in threads.values() for d in t["zones"].get(zone, Zone()).durations]
    if not durs:
        return f"budget: no {zone} zone"
    over = sum(1 for d in durs if d > limit)
    return (f"budget: {zone} median {100 * pct(durs, 0.5) / limit:.1f}%, p99 {100 * pct(durs, 0.99) / limit:.1f}%, "
            f"worst {100 * max(durs) / limit:.1f}% of {limit / 1e3:.0f} µs ({over} of {len(durs)} calls over)")


def report(path, args):
    threads = merged(parse(path))
    print(f"{path}")
    for spec in args.budget or []:
        print(budget_lines(threads, spec))
    for name, t in sorted(threads.items(), key=lambda kv: -kv[1]["top"]):
        if args.thread and args.thread not in name:
            continue
        zones = t["zones"]
        if not zones:
            continue
        per = zones.get(args.per) if args.per else None
        count = f" ×{t['count']}" if t["count"] > 1 else ""
        print(f"\n== {name}{count}: {ms(t['top']):.1f} ms in zones")
        head = f"{'zone':32} {'calls':>8} {'total ms':>10} {'self ms':>10} {'self %':>7} {'med µs':>9} {'p99 µs':>9}"
        if per:
            head += f" {'µs/' + args.per:>12}"
        print(head)
        for zname, z in sorted(zones.items(), key=lambda kv: -kv[1].self_)[: args.top]:
            line = f"{zname[:32]:32} {z.calls:8d} {ms(z.total):10.2f} {ms(z.self_):10.2f} {100 * z.self_ / max(t['top'], 1):6.1f}% {us(pct(z.durations, 0.5)):9.2f} {us(pct(z.durations, 0.99)):9.2f}"
            if per:
                line += f" {us(z.total / max(per.calls, 1)):12.2f}"
            print(line)


def compare(a, b, args):
    ta, tb = merged(parse(a)), merged(parse(b))
    per = args.per
    for name in sorted(set(ta) | set(tb)):
        if args.thread and args.thread not in name:
            continue
        za = ta.get(name, {"zones": {}})["zones"]
        zb = tb.get(name, {"zones": {}})["zones"]
        pa, pb = za.get(per) if per else None, zb.get(per) if per else None
        print(f"\n== {name} ({'per ' + per if per and pa and pb else 'totals, ms'})")
        print(f"{'zone':32} {'before':>12} {'after':>12} {'change':>8}")

        def value(z, p):
            if z is None:
                return 0.0
            return us(z.total / max(p.calls, 1)) if p else ms(z.total)

        rows = []
        for zname in set(za) | set(zb):
            x, y = value(za.get(zname), pa), value(zb.get(zname), pb)
            rows.append((zname, x, y))
        for zname, x, y in sorted(rows, key=lambda r: -max(r[1], r[2]))[: args.top]:
            ch = f"{100 * (y - x) / x:+7.1f}%" if x > 0 else "    new"
            print(f"{zname[:32]:32} {x:12.2f} {y:12.2f} {ch}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--top", type=int, default=25, help="zones a thread shows (default 25)")
    ap.add_argument("--thread", help="only threads whose name contains this")
    ap.add_argument("--per", help="also show each zone's time per call of this zone (frame, audio callback)")
    ap.add_argument("--compare", action="store_true", help="two traces: before and after")
    ap.add_argument("--budget", action="append", help="ZONE=US: that zone's calls against US µs (an audio block: graph=5333 at 256 frames, 48 kHz)")
    args = ap.parse_args()
    if args.compare:
        if len(args.traces) != 2:
            sys.exit("--compare takes two traces")
        compare(args.traces[0], args.traces[1], args)
    else:
        for i, p in enumerate(args.traces):
            if i:
                print()
            report(p, args)


if __name__ == "__main__":
    main()
