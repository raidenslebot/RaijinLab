"""Rebuild the navigation mesh for whole continents, and FAIL when it fails.

WHY THIS EXISTS.

The last full rebuild was driven by an ad-hoc shell loop. build_navgrid.py had
been left unparseable (a newline written into the source as a real newline rather
than as an escape), so the Outland pass died instantly with a SyntaxError - and
the loop went on to print "ALL FOUR CONTINENTS COMPLETE" and exit 0. The only
reason it was caught at all is that the tile timestamps disagreed with the claim.

A build driver that reports success it did not verify is the same defect this
project keeps finding everywhere else: a confident value that actually means "no
answer". So this one checks three things and refuses to be cheerful about any of
them - the child's exit status, that the generator is importable BEFORE spending
hours on it, and that tiles newer than the run actually appeared on disk.

Usage:
    python tools/rebuild_world.py                 # all four continents
    python tools/rebuild_world.py Expansion01     # just one
"""

import ast
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "tools", "build_navgrid.py")
TILES = os.path.join("C:\\", "Ascension", "Launcher", "resources",
                     "ascension-live", "Logs", "navgrid")

CONTINENTS = ["Azeroth", "Kalimdor", "Northrend", "Expansion01"]


def preflight() -> None:
    """Parse the generator before committing hours to it.

    A SyntaxError costs nothing to detect now and costs an entire rebuild to
    detect later - which is exactly what happened.
    """
    with open(GEN, "r", encoding="utf-8") as fh:
        src = fh.read()
    try:
        ast.parse(src)
    except SyntaxError as exc:
        raise SystemExit("FAIL: %s does not parse (%s at line %s) - fix it "
                         "before rebuilding anything"
                         % (os.path.relpath(GEN, ROOT), exc.msg, exc.lineno))


def tiles_for(name: str):
    if not os.path.isdir(TILES):
        return []
    return [f for f in os.listdir(TILES)
            if f.startswith(name + "_") and f.endswith(".dat")]


def newest_mtime(name: str) -> float:
    best = 0.0
    for f in tiles_for(name):
        try:
            best = max(best, os.path.getmtime(os.path.join(TILES, f)))
        except OSError:
            pass
    return best


def rebuild(name: str) -> list:
    """Run one continent. Returns a list of problems (empty means it worked)."""
    started = time.time()
    before = len(tiles_for(name))
    print("=== %s starting %s ===" % (name, time.strftime("%H:%M:%S")))
    proc = subprocess.run([sys.executable, GEN, name, "--deploy"],
                          cwd=ROOT, capture_output=True, text=True)
    tail = (proc.stdout or "").strip().splitlines()[-3:]
    for line in tail:
        print("    " + line)
    bad = []
    if proc.returncode != 0:
        err = (proc.stderr or "").strip().splitlines()[-4:]
        bad.append("%s exited %d:\n        %s"
                   % (name, proc.returncode, "\n        ".join(err)))
    # EXIT 0 IS A CLAIM, NOT EVIDENCE. Tiles newer than the start of this run
    # are the evidence, and a generator that silently produced nothing fails here
    # even when it was perfectly happy about it.
    after = len(tiles_for(name))
    if newest_mtime(name) < started:
        bad.append("%s wrote no tile newer than the run started (%d on disk, "
                   "all stale) - it claimed to build and did not" % (name, after))
    else:
        print("    %s: %d tiles (%+d), %.1f min"
              % (name, after, after - before, (time.time() - started) / 60.0))
    return bad


def main(argv) -> int:
    wanted = argv[1:] or CONTINENTS
    for w in wanted:
        if w not in CONTINENTS:
            raise SystemExit("unknown continent %r (known: %s)"
                             % (w, ", ".join(CONTINENTS)))
    preflight()
    problems = []
    for name in wanted:
        problems += rebuild(name)
    print("")
    if problems:
        for p in problems:
            print("FAIL: %s" % p)
        print("\n%d of %d continent(s) FAILED" % (len(problems), len(wanted)))
        return 1
    print("all %d continent(s) rebuilt and verified on disk" % len(wanted))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
