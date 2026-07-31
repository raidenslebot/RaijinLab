#!/usr/bin/env python
"""Read and analyse the RaijinLab live telemetry log.

The addon writes structured lines to <WoW>/Logs/raijinlab_dev.log about twice a
second:

    329334.399 [director] I switch goal=rest band=4 why=preempted urgency=0.62

This turns that into something answerable: what has it been doing, what changed,
what went wrong, and what does the log NOT contain (silence is a symptom too).

Usage:
    python tools/readlog.py                 # summary of the whole session
    python tools/readlog.py --tail 60       # last 60 lines, decoded
    python tools/readlog.py --cat director  # one category
    python tools/readlog.py --errors        # errors + warnings only
    python tools/readlog.py --timeline      # goal/state transitions over time
    python tools/readlog.py --follow        # live tail
"""
import argparse
import collections
import os
import re
import sys
import time

LOG = r"C:\Ascension\Launcher\resources\ascension-live\Logs\raijinlab_dev.log"
LINE = re.compile(r"^(?P<t>[\d.]+)\s+\[(?P<cat>[^\]]+)\]\s+(?P<rest>.*)$")
EVENT = re.compile(r"^(?P<lvl>[EWIDT])\s+(?P<event>\S+)(?:\s+(?P<kv>.*))?$")


def parse(line):
    m = LINE.match(line.rstrip("\n"))
    if not m:
        return None
    rec = {"t": float(m.group("t")), "cat": m.group("cat"), "raw": m.group("rest")}
    e = EVENT.match(rec["raw"])
    if e:
        rec["lvl"] = e.group("lvl")
        rec["event"] = e.group("event")
        kv = {}
        for pair in (e.group("kv") or "").split():
            if "=" in pair:
                k, v = pair.split("=", 1)
                kv[k] = v
        rec["kv"] = kv
    else:
        rec["lvl"] = "I"
        rec["event"] = None
        rec["kv"] = {}
    return rec


def load(path, limit=None):
    if not os.path.exists(path):
        print(f"log not found: {path}", file=sys.stderr)
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    if limit:
        lines = lines[-limit:]
    return [r for r in (parse(l) for l in lines) if r]


def fmt_span(recs):
    if not recs:
        return "empty"
    dur = recs[-1]["t"] - recs[0]["t"]
    return f"{len(recs)} lines over {dur/60:.1f} min"


def summary(recs):
    print(f"=== session: {fmt_span(recs)} ===\n")

    cats = collections.Counter(r["cat"] for r in recs)
    print("lines by category:")
    for c, n in cats.most_common():
        print(f"  {c:<12} {n:>7}")

    lvls = collections.Counter(r["lvl"] for r in recs)
    print("\nby level:  " + "  ".join(f"{k}={v}" for k, v in sorted(lvls.items())))

    errs = [r for r in recs if r["lvl"] in ("E", "W")]
    if errs:
        print(f"\n!! {len(errs)} errors/warnings:")
        top = collections.Counter((r["cat"], r["event"]) for r in errs)
        for (c, e), n in top.most_common(12):
            print(f"  {n:>5}x [{c}] {e}")
            sample = next(r for r in errs if r["cat"] == c and r["event"] == e)
            if sample["kv"]:
                print(f"         {sample['kv']}")
    else:
        print("\nno errors or warnings")

    # what the bot actually spent its time doing
    goals = [r for r in recs if r["cat"] == "snap" and r["event"] == "goal"]
    if goals:
        gc = collections.Counter(g["kv"].get("goal", "?") for g in goals)
        total = sum(gc.values())
        print("\ntime by goal (from 1Hz snapshots):")
        for g, n in gc.most_common():
            print(f"  {g:<12} {n:>6}s  {100.0*n/total:5.1f}%")

    # movement: is it actually going anywhere?
    pos = [r for r in recs if r["cat"] == "snap" and r["event"] == "player"
           and "x" in r["kv"]]
    if len(pos) >= 2:
        def f(r, k):
            try:
                return float(r["kv"][k])
            except (KeyError, ValueError):
                return None
        moved = 0.0
        stalled = 0
        for a, b in zip(pos, pos[1:]):
            ax, ay = f(a, "x"), f(a, "y")
            bx, by = f(b, "x"), f(b, "y")
            if None in (ax, ay, bx, by):
                continue
            d = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5
            moved += d
            if d < 0.5:
                stalled += 1
        print(f"\nmovement: {moved:.0f} yd travelled, "
              f"{stalled}/{len(pos)-1} samples stationary "
              f"({100.0*stalled/max(1,len(pos)-1):.0f}%)")
        bad = [p for p in pos if p["kv"].get("facing") == "BAD"]
        if bad:
            print(f"  !! facing read as GARBAGE in {len(bad)}/{len(pos)} samples")

    casts = [r for r in recs if r["cat"] == "cast"]
    if casts:
        cc = collections.Counter(r["event"] for r in casts)
        print("\ncasts: " + "  ".join(f"{k}={v}" for k, v in cc.most_common()))
        refused = [r for r in casts if r["event"] == "refused"]
        if refused:
            why = collections.Counter(r["kv"].get("why", "?") for r in refused)
            print("  refusal reasons:")
            for w, n in why.most_common(8):
                print(f"    {n:>5}x {w}")

    # silence is a symptom: which subsystems never said anything?
    expected = {"director", "quest", "nav", "path", "cast", "rest", "vendor",
                "mount", "death", "watchdog", "snap"}
    missing = sorted(expected - set(cats))
    if missing:
        print("\nsilent subsystems (no lines at all): " + ", ".join(missing))


def timeline(recs):
    print("=== transitions ===")
    for r in recs:
        if r["cat"] == "director" and r["event"] == "switch":
            kv = r["kv"]
            print(f"{r['t']:>12.1f} GOAL -> {kv.get('goal'):<10} "
                  f"({kv.get('why')}) {kv.get('reason','')}")
        elif r["cat"] == "quest" and r["event"] == "state":
            print(f"{r['t']:>12.1f} state  {r['kv'].get('from')} -> {r['kv'].get('to')}")
        elif r["cat"] == "nav" and r["event"] == "goto":
            print(f"{r['t']:>12.1f} nav    {r['kv'].get('from')} -> {r['kv'].get('to')}")
        elif r["lvl"] in ("E", "W"):
            print(f"{r['t']:>12.1f} !! [{r['cat']}] {r['event']} {r['kv']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=LOG)
    ap.add_argument("--tail", type=int)
    ap.add_argument("--cat")
    ap.add_argument("--event")
    ap.add_argument("--errors", action="store_true")
    ap.add_argument("--timeline", action="store_true")
    ap.add_argument("--follow", action="store_true")
    a = ap.parse_args()

    if a.follow:
        print(f"following {a.log} (ctrl-c to stop)")
        with open(a.log, "r", encoding="utf-8", errors="replace") as f:
            f.seek(0, os.SEEK_END)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.3)
                    continue
                r = parse(line)
                if not r:
                    continue
                if a.cat and r["cat"] != a.cat:
                    continue
                if a.errors and r["lvl"] not in ("E", "W"):
                    continue
                print(line.rstrip())
        return

    recs = load(a.log, a.tail)
    if a.cat:
        recs = [r for r in recs if r["cat"] == a.cat]
    if a.event:
        recs = [r for r in recs if r["event"] == a.event]
    if a.errors:
        recs = [r for r in recs if r["lvl"] in ("E", "W")]

    if a.timeline:
        timeline(recs)
    elif a.tail or a.cat or a.event or a.errors:
        for r in recs:
            print(f"{r['t']:>12.1f} [{r['cat']}] {r['raw']}")
    else:
        summary(recs)


if __name__ == "__main__":
    main()
