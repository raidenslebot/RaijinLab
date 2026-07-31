"""Run the bot in a simulated world. No game client, no human.

    python tests/simulate.py                 # all scenarios
    python tests/simulate.py reaches_ gather # only matching names
    python tests/simulate.py -v              # per-scenario trace

Exit 0 = every scenario achieved its goal. Non-zero = the count that did not.

Reading a failure: the scenario prints WHY it exists (the real incident) next to
what the bot actually did, because "assertion failed" is a symptom and the
incident is the diagnosis.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sim.runner import SimRun          # noqa: E402
from sim.scenarios import ALL          # noqa: E402


def run_one(cls, verbose: bool = False) -> tuple[bool, str, list[str]]:
    sc = cls()
    world = sc.build()
    run = SimRun(world)
    if run.load_errors:
        return False, "load errors", [f"{m}: {e}" for m, e in run.load_errors[:5]]
    sc.setup(run)
    res = run.run(sc.seconds, on_tick=getattr(run, "_watch", None))
    failures = sc.check(run, res)

    # Any contract the bot violated during the run is a failure in its own right,
    # even if the scenario's own goal was met - that is the whole point of having
    # the bot check itself.
    diag = run.diagnose()
    for v in diag.get("violated", []):
        failures.append(f"contract '{v['name']}' violated: {v['explain']}")
    if res.errors:
        failures.append(f"{len(res.errors)} lua error(s), first: {res.errors[0]}")

    line = res.summary()
    if verbose:
        unhandled = run.bridge.unhandled
        if unhandled:
            top = sorted(unhandled.items(), key=lambda kv: -kv[1])[:6]
            line += "\n      unhandled runtime calls: " + ", ".join(
                f"{k}x{v}" for k, v in top)
    return (not failures), line, failures


def main(argv) -> int:
    args = [a for a in argv[1:] if not a.startswith("-")]
    verbose = "-v" in argv
    picked = [c for c in ALL if not args or any(a in c.name for a in args)]

    print(f"simulating {len(picked)} scenario(s)\n")
    bad = 0
    for cls in picked:
        ok, line, failures = run_one(cls, verbose)
        mark = "PASS" if ok else "FAIL"
        print(f"[{mark}] {cls.name}")
        print(f"      {line}")
        if not ok:
            bad += 1
            print(f"      reproduces: {cls.why}")
            for f in failures:
                print(f"      -> {f}")
        print()

    print(f"{len(picked) - bad}/{len(picked)} scenarios passed")
    return bad


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
