"""Turn a live session log into a verdict.

WHY THIS EXISTS. Every navigation fix this session was verified against a
headless simulator that does not model buildings, then shipped blind and judged
by a human watching the character. That loop is slow and it is why answers kept
being "maybe". The dev log already contains the steering stream - position,
heading, target, detour, terrain verdicts - so the pathologies are all decidable
mechanically.

Each check below encodes a failure that actually happened, in the form that
would have caught it from the log alone:

  oscillation   the detour sign flipping back and forth (the shoulder-ray
                side choice with no commitment) - "running around randomly"
  wall_loop     repeated wall detections while the position barely changes -
                grinding along a building
  hop_at_wall   a hop issued while a wall is known to be in front - "jumping
                at the church"
  frozen        nav reports moving while the position does not change
  same_dest     the same destination chosen over and over - the belief field
                re-picking an unreachable cell
  budget_pin    the frame budget stuck at its floor - the starvation bug
  no_progress   long stretches with movement commanded and no displacement

Usage:  python tools/analyze_session.py [logfile]
Exit code is 1 when any check fails, so it can gate a change like a test.
"""
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

DEFAULT_LOG = Path(
    r"C:\Ascension\Launcher\resources\ascension-live\Logs\raijinlab_dev.log")

TS = r"^(\d+\.\d+)\s+"


def load(path):
    txt = Path(path).read_text(encoding="utf-8", errors="ignore")
    return txt.splitlines()


def parse(lines):
    """Pull the structured streams out of the log."""
    d = {
        "steps": [],      # (t, x, y, z, moving)
        "turns": [],      # (t, head, tgt, err, method, turn, fwd, dist)
        "detours": [],    # (t, value)
        "hops": [],       # t
        "walls": [],      # t
        "dests": [],      # (t, "x,y")
        "budget": [],     # (t, value)
        "navstate": [],   # (t, state)
    }
    for ln in lines:
        mt = re.match(TS, ln)
        if mt:
            d["last_t"] = max(d.get("last_t", 0.0), float(mt.group(1)))
        m = re.match(TS + r"\[nav\] step#\d+ pos=\(([-\d.]+),([-\d.]+),([-\d.]+)\).*?moving=(\w+)", ln)
        if m:
            d["steps"].append((float(m.group(1)), float(m.group(2)),
                               float(m.group(3)), float(m.group(4)),
                               m.group(5) == "true"))
            continue
        m = re.match(TS + r"\[nav\] turn#\d+ head=([-\d.a-z]+).*?tgt=([-\d.]+) err=([-+\d.]+) m=(\w+) turn=(\w+) fwd=(\w+) dist=([-\d.]+)", ln)
        if m:
            d["turns"].append((float(m.group(1)), m.group(2), float(m.group(3)),
                               float(m.group(4)), m.group(5), m.group(6),
                               m.group(7) == "true", float(m.group(8))))
            continue
        # `detour=1.90` on WALL lines, `detour 1.40` on CLIFF lines. This
        # only accepted the space form, so EVERY wall contact was invisible
        # and wall_loop / hop_at_wall / oscillation all "passed" on no data.
        m = re.match(TS + r".*terrain WALL\(chest\).*?detour[= ]([-\d.]+)", ln)
        if m:
            d["walls"].append(float(m.group(1)))
            d["detours"].append((float(m.group(1)), float(m.group(2))))
            continue
        m = re.match(TS + r".*terrain LIP\(foot\).*hop", ln)
        if m:
            d["hops"].append(float(m.group(1)))
            continue
        m = re.match(TS + r".*dest=(\d+),(\d+)", ln)
        if m:
            d["dests"].append((float(m.group(1)), m.group(2) + "," + m.group(3)))
            continue
        m = re.match(TS + r".*budget=([\d.]+)", ln)
        if m:
            d["budget"].append((float(m.group(1)), float(m.group(2))))
            m2 = re.search(r"probe_pk=([\d.]+)", ln)
            if m2:
                d.setdefault("probe_pk", []).append((float(m.group(1)), float(m2.group(1))))
            continue
        m = re.match(TS + r".*\[master\] ON reason=\S+ modules=(\S+)", ln)
        if m:
            d.setdefault("modules", []).append((float(m.group(1)), m.group(2)))
            continue
        m = re.match(TS + r".*\[selftest\] (PASS|FAIL|SKIP) (\S+)\s*(.*)$", ln)
        if m:
            d.setdefault("selftest", []).append((m.group(2), m.group(3), m.group(4).strip()))
            continue
        m = re.match(TS + r".*\[quest\] pick (\w+) giver=(\S+)", ln)
        if m:
            d.setdefault("pick", []).append((float(m.group(1)), m.group(2), m.group(3)))
            continue
        m = re.match(TS + r".*\[hb\] om bridge=(-?\d+) npcs=(-?\d+) players=(-?\d+) gos=(-?\d+) armed=(\w+) frame=(\w+)", ln)
        if m:
            d.setdefault("om", []).append((float(m.group(1)), int(m.group(2)),
                                           int(m.group(3)), m.group(6), m.group(7)))
            continue
        m = re.match(TS + r".*\[om\] run count=(-?\d+) players=\d+ npcs=(\d+) gos=\d+ unclassified=(\d+)", ln)
        if m:
            d.setdefault("om_run", []).append((float(m.group(1)), int(m.group(2)),
                                               int(m.group(3)), int(m.group(4))))
            continue
        m = re.match(TS + r".*\[hb\] quest state=(.*)$", ln)
        if m:
            d.setdefault("hb_quest", []).append((float(m.group(1)), m.group(2)))
            continue
        m = re.match(TS + r"\[nav\].*?nst=(\w+)", ln)
        if m:
            d["navstate"].append((float(m.group(1)), m.group(2)))
    return d


# ---- checks. each returns (name, ok, detail) ------------------------------

def chk_oscillation(d):
    """Detour flipping sign in quick succession = no commitment to a way around."""
    flips, worst = 0, 0.0
    prev = None
    for t, v in d["detours"]:
        if prev and v * prev[1] < 0 and (t - prev[0]) < 3.0:
            flips += 1
            worst = max(worst, 1.0 / max(t - prev[0], 0.01))
        prev = (t, v)
    ok = flips <= 1
    return ("oscillation", ok,
            f"{flips} detour sign-flip(s) within 3s"
            + (f", fastest {worst:.1f}/s" if flips else ""))


def chk_wall_loop(d):
    """Many wall hits while the character stays put = grinding a building."""
    if not d["walls"] or not d["steps"]:
        return ("wall_loop", True, "no wall contacts")
    bad = 0
    for wt in d["walls"]:
        near = [s for s in d["steps"] if abs(s[0] - wt) < 4.0]
        if len(near) >= 2:
            dx = max(s[1] for s in near) - min(s[1] for s in near)
            dy = max(s[2] for s in near) - min(s[2] for s in near)
            if (dx * dx + dy * dy) ** 0.5 < 3.0:
                bad += 1
    ok = bad < 3
    return ("wall_loop", ok,
            f"{bad} wall contact(s) with <3yd of movement in the surrounding 4s")


def chk_hop_at_wall(d):
    """A hop within a second of a known wall is jumping at a building."""
    bad = sum(1 for h in d["hops"]
              if any(abs(h - w) < 1.0 for w in d["walls"]))
    return ("hop_at_wall", bad == 0,
            f"{bad} hop(s) issued within 1s of a chest-height wall")


def chk_frozen(d):
    """nav says moving, position does not change."""
    runs, cur = [], 0
    prev = None
    for t, x, y, z, moving in d["steps"]:
        if prev and moving:
            if abs(x - prev[1]) < 0.05 and abs(y - prev[2]) < 0.05:
                cur += 1
            else:
                runs.append(cur); cur = 0
        prev = (t, x, y, z, moving)
    runs.append(cur)
    longest = max(runs) if runs else 0
    return ("frozen", longest < 20,
            f"longest run of 'moving' with no displacement: {longest} samples")


def chk_same_dest(d):
    if not d["dests"]:
        return ("same_dest", True, "no destinations logged")
    c = Counter(v for _, v in d["dests"])
    top, n = c.most_common(1)[0]
    frac = n / len(d["dests"])
    return ("same_dest", not (frac > 0.6 and n >= 6),
            f"most common destination {top} chosen {n}/{len(d['dests'])} ({frac:.0%})")


def chk_budget(d):
    if not d["budget"]:
        return ("budget_pin", True, "no budget samples")
    vals = [v for _, v in d["budget"]]
    pinned = sum(1 for v in vals if v <= 0.31) / len(vals)
    return ("budget_pin", pinned < 0.5,
            f"budget at the 0.30 floor in {pinned:.0%} of {len(vals)} samples"
            f" (max seen {max(vals):.2f})")


def chk_no_progress(d):
    """Forward commanded for a long stretch with no net displacement."""
    fwd = [t for t in d["turns"] if t[6]]
    if len(fwd) < 10 or not d["steps"]:
        return ("no_progress", True, f"only {len(fwd)} forward samples")
    t0, t1 = fwd[0][0], fwd[-1][0]
    seg = [s for s in d["steps"] if t0 <= s[0] <= t1]
    if len(seg) < 2:
        return ("no_progress", True, "insufficient position samples")
    dx = seg[-1][1] - seg[0][1]
    dy = seg[-1][2] - seg[0][2]
    net = (dx * dx + dy * dy) ** 0.5
    span = t1 - t0
    ok = not (span > 10.0 and net < 5.0)
    return ("no_progress", ok,
            f"net {net:.1f}yd over {span:.0f}s of commanded forward")


def chk_hop_while_moving(d):
    """A hop issued while position is advancing = the uphill-slope jump bug.
    Jumping is a remedy for being snagged; while moving there is nothing to fix."""
    if not d["hops"] or not d["steps"]:
        return ("hop_moving", True, "no hops")
    bad = 0
    for h in d["hops"]:
        near = [s for s in d["steps"] if 0 < h - s[0] < 1.5]
        if len(near) >= 2:
            dx = near[-1][1] - near[0][1]
            dy = near[-1][2] - near[0][2]
            if (dx * dx + dy * dy) ** 0.5 > 2.0:      # was moving fine
                bad += 1
    return ("hop_moving", bad == 0,
            f"{bad} hop(s) issued while advancing normally (uphill-jump bug)")


def chk_probe_spike(d):
    """Worst terrain-probe burst per second. The 1Hz frame EMA cannot see a
    multi-ms spike every 100ms; probe_pk was added so it cannot hide. Above
    ~3ms per burst at 30fps it is a felt stutter."""
    pk = d.get("probe_pk") or []
    if not pk:
        return ("probe_spike", True, "no probe_pk stream (pre-instrumentation log)")
    vals = sorted(v for _, v in pk)
    worst = vals[-1]
    p90 = vals[int(len(vals) * 0.9)] if len(vals) > 1 else worst
    return ("probe_spike", worst < 3.0,
            f"probe burst p90={p90:.2f}ms worst={worst:.2f}ms over {len(vals)} samples")


def chk_nav_died(d):
    """The suite believes it is moving, but nav has not steered for a minute.

    Real failure this session: Navigator.step threw, the ticker's error handler
    called stop() -> _stop_ticker(), and navigation ended permanently while the
    heartbeat went on reporting "accept:to ? st=8 d=20 (moving)" for another
    twenty minutes.

    Anchor on `turn#`, NOT `step#`: step logging is deliberately capped at the
    first 12 steps of a move (`a.step_n <= 12`), so missing step lines are
    NORMAL on any long move - judging liveness by them would fail every healthy
    journey. turn# re-logs at >=1Hz for the whole move.

    And require that something CLAIMED to be moving, so a legitimately idle nav
    (no goal, nothing to steer) is not accused of dying.
    """
    hb = [(t, txt) for t, txt in d.get("hb_quest", []) if "(moving)" in txt]
    if not hb:
        return ("nav_died", True, "nothing ever claimed to be moving")
    last_moving = hb[-1][0]
    if not d["turns"]:
        return ("nav_died", False,
                f"suite claimed 'moving' at {last_moving:.0f} but nav never steered at all")
    last_turn = d["turns"][-1][0]
    gap = last_moving - last_turn
    return ("nav_died", gap < 60.0,
            f"suite still reported '(moving)' {gap:.0f}s after the last steering command"
            + (" - the nav ticker died and nothing noticed" if gap >= 60 else ""))


def chk_engine_blind(d):
    """The runtime sees units but the engine's snapshot is empty.

    This is the defect that cost days: the bridge enumerated 95 units while
    object_list.npcs stayed 0, so questing had no givers and no objectives and
    fell through to a belief-field beeline into walls. Nothing logged it.
    """
    om = d.get("om") or []
    if not om:
        return ("engine_blind", True, "no om heartbeat in this log (older build)")
    bad = [r for r in om if r[1] > 0 and r[2] == 0]
    worst = max((r[1] for r in bad), default=0)
    return ("engine_blind", not bad,
            f"{len(bad)}/{len(om)} samples had bridge units but an EMPTY engine "
            f"snapshot (worst bridge={worst})")


def chk_unclassified(d):
    """Objects the manager could not put in any bucket.

    Non-zero means ObjectTypeFlags is not returning the mask the classifier
    expects - the live 1.8.33 bug, where it returned the ObjectType enum and
    every single object fell through."""
    runs = d.get("om_run") or []
    if not runs:
        return ("om_unclassified", True, "no [om] run lines (older build)")
    bad = [r for r in runs if r[3] > 0]
    worst = max((r[3] for r in bad), default=0)
    return ("om_unclassified", not bad,
            f"{len(bad)}/{len(runs)} manager passes left objects unclassified "
            f"(worst {worst}) - ObjectTypeFlags is not a bitmask")


def chk_giver_flicker(d):
    """A giver that appears and disappears between ticks is an unstable SENSOR.

    Live: `accept:to ? st=8 d=21` alternated with `objective:searching` about
    three times a second because giver_status treated an unanswered read (0) as
    "not a giver", and the client only answers ~6% of the time. The bot never
    closed the last 21 yards."""
    picks = d.get("pick") or []
    if len(picks) < 4:
        return ("giver_flicker", True, f"only {len(picks)} pick samples")
    flips = 0
    for a, b in zip(picks, picks[1:]):
        a_has = a[1] != "no_giver"
        b_has = b[1] != "no_giver"
        if a_has != b_has and (b[0] - a[0]) < 3.0:
            flips += 1
    return ("giver_flicker", flips <= 2,
            f"{flips} appear/disappear flips within 3s across {len(picks)} picks")


def chk_selftest(d):
    """The in-game runtime selftest, read from the LOG rather than a screenshot.

    It now runs automatically when the runtime arms and writes every row here, so
    the state of the bridge is answerable from the log file alone - no typed
    command, no screenshot, no transcription."""
    rows = d.get("selftest") or []
    if not rows:
        return ("selftest", True, "no selftest rows in this log (older build)")
    failed = [r for r in rows if r[0] == "FAIL"]
    if not failed:
        return ("selftest", True,
                f"{len(rows)} checks, none failing")
    detail = "; ".join(f"{r[1]}: {r[2]}" for r in failed[:3])
    return ("selftest", False, f"{len(failed)}/{len(rows)} FAILED -> {detail}")


CHECKS = [chk_selftest, chk_giver_flicker, chk_engine_blind, chk_unclassified, chk_nav_died, chk_oscillation, chk_wall_loop, chk_hop_at_wall, chk_hop_while_moving,
          chk_frozen, chk_same_dest, chk_budget, chk_probe_spike, chk_no_progress]


# DEAD: steps and turns both stop, yet the suite keeps claiming "(moving)".
SELFTEST_LOG = """100.000 [nav] step#1 pos=(0.00,0.00,0.00) gz=0.00 moving=true
100.100 [nav] terrain WALL(chest) d=0.4 detour=1.90 block=true
100.200 [nav] terrain CLIFF ahead heading=0.45 -> detour -0.90
100.300 [nav] step#2 pos=(0.00,0.00,0.00) gz=0.00 moving=true
100.400 [nav] turn#2 head=0.100 cam=0.100(ok=true) travel=0.100 tgt=0.200 err=+0.100 m=keyboard turn=left fwd=true dist=20.0
900.000 [hb] quest state=accept:to ? st=8 d=20 (moving)
"""

# HEALTHY LONG MOVE: step logging is capped at 12 per move, so steps are ancient
# while the move is perfectly alive - turn# keeps re-logging at 1Hz. Anchoring
# liveness on step# would condemn every long journey.
SELFTEST_HEALTHY = """100.000 [nav] step#1 pos=(0.00,0.00,0.00) gz=0.00 moving=true
100.300 [nav] step#12 pos=(5.00,0.00,0.00) gz=0.00 moving=true
890.000 [nav] turn#500 head=0.100 cam=0.100(ok=true) travel=0.100 tgt=0.200 err=+0.100 m=keyboard turn=left fwd=true dist=20.0
900.000 [hb] quest state=accept:to ? st=8 d=20 (moving)
"""

# IDLE: nothing claims to be moving, and there is a long quiet gap. Not a death.
SELFTEST_IDLE = """100.000 [nav] step#1 pos=(0.00,0.00,0.00) gz=0.00 moving=false
100.400 [nav] turn#2 head=0.100 cam=0.100(ok=true) travel=0.100 tgt=0.200 err=+0.100 m=keyboard turn=left fwd=false dist=20.0
900.000 [hb] perf frame=33.0ms fps=30 sched=0.00ms peak=1.0 budget=8.00 jobs=0 probe_pk=0.00
"""


def selftest():
    """Prove the parser and checks still match the log format they claim to read.

    This tool reported VERDICT: clean for a session in which the navigator died
    for twenty minutes and ground against a wall four times. Two silent rots: the
    WALL regex wanted `detour ` while the log writes `detour=`, so walls parsed as
    zero and three checks passed on empty data; and nothing noticed nav had
    stopped entirely.

    The fixtures below are deliberately built to DISCRIMINATE - a first version
    of this selftest passed even when nav_died was re-anchored to step# or had
    its "(moving)" guard removed, which made it decorative for the two properties
    that matter most.
    """
    bad = []
    d = parse(SELFTEST_LOG.splitlines())
    if len(d["walls"]) != 1:
        bad.append(f"WALL(chest) not parsed: got {len(d['walls'])} want 1")
    if len(d["detours"]) != 1:
        bad.append(f"detour value not parsed: got {len(d['detours'])}")
    if len(d["steps"]) != 2:
        bad.append(f"steps not parsed: got {len(d['steps'])} want 2")
    if not d.get("turns"):
        bad.append("turn# not parsed")
    if not d.get("hb_quest"):
        bad.append("heartbeat quest state not parsed")
    if chk_nav_died(d)[1]:
        bad.append("nav_died did not fire on a dead ticker")

    # must NOT fire when only the (capped) step log is stale
    h = parse(SELFTEST_HEALTHY.splitlines())
    if not chk_nav_died(h)[1]:
        bad.append("nav_died false-fired on a healthy long move "
                   "(anchored on step#, which is capped at 12)")

    # must NOT fire when nothing claimed to be moving
    i = parse(SELFTEST_IDLE.splitlines())
    if not chk_nav_died(i)[1]:
        bad.append("nav_died false-fired while idle (no '(moving)' claim)")

    for b in bad:
        print("  [FAIL]", b)
    print("selftest:", "clean" if not bad else f"{len(bad)} problem(s)")
    return 1 if bad else 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        return selftest()
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LOG
    if not Path(path).exists():
        print("no log at", path)
        return 2
    d = parse(load(path))
    print(f"=== session: {path}")
    print(f"    steps={len(d['steps'])} turns={len(d['turns'])} "
          f"walls={len(d['walls'])} hops={len(d['hops'])} "
          f"dests={len(d['dests'])} budget={len(d['budget'])}")
    mods = d.get("modules") or []
    ran = sorted({m for _, spec in mods for m in spec.split(",")})
    if mods:
        print(f"    modules enabled: {', '.join(ran)}")
    if not d["steps"] and not d["turns"]:
        # BE SPECIFIC ABOUT WHY THERE IS NOTHING TO JUDGE. "No steering stream"
        # sent me hunting for a broken navigator when the real answer was that
        # navigation was never switched on - a whole session spent learning
        # nothing. Name the missing module instead.
        if mods and "quest" not in ran and "nav" not in ran:
            print("    NOTE: navigation/questing were NEVER ENABLED this session "
                  f"(only: {', '.join(ran)}).")
            print("          Nothing about nav, pathfinding or questing can be "
                  "judged from this log.")
        else:
            print("    NOTE: no steering stream in this log - nothing to judge.")
        return 2
    print()
    bad = 0
    for fn in CHECKS:
        name, ok, detail = fn(d)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:<12} {detail}")
        if not ok:
            bad += 1
    print()
    print("VERDICT:", "clean" if bad == 0 else f"{bad} pathology(ies) present")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
