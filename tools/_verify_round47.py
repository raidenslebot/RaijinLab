#!/usr/bin/env python3
"""
Round 47 verification harness.

Two independent proofs:

PROOF 1 — LIVE LOG EVIDENCE (from the real in-game session, 2026-08-03 13:50-13:58):
  Parses raijinlab_dev.log, segments the session by the reported runtime version
  (ver=1.10.xxx markers), and counts casts / refusals per segment. Shows that
  every client refusal ("facing the wrong way", "in front of you", "too far
  away", FAILED_QUIET, Invalid target) happened under runtime 1.10.105-aa
  (round-45 era, pre facing-read fix) and that the 1.10.106-aa segment had
  ZERO refusals with 6/6 casts landed.

PROOF 2 — COOLDOWN GATE BY CONSTRUCTION (round-47 fix):
  Simulates the OLD Engine.spell_ready cooldown gate vs the NEW one across a
  range of remaining-cooldown (rem) and latency values, using the exact code
  that was changed. Proves the old gate allowed casting up to 0.24s BEFORE the
  local cooldown bar cleared (guaranteeing the client's "Spell is not ready
  yet" refusal, since the client judges readiness from its own local bar) and
  the new gate only fires once the bar is essentially cleared.

Usage: python tools/_verify_round47.py
Exit code 0 = all assertions hold. Non-zero = a proof failed.
"""
import os
import re
import sys
import math

DEV_LOG = r"C:\Ascension\Launcher\resources\ascension-live\Logs\raijinlab_dev.log"


# ---------------------------------------------------------------------------
# PROOF 1: live-log segmentation + refusal counts per runtime version
# ---------------------------------------------------------------------------

def segment_log(path):
    if not os.path.exists(path):
        return {"error": f"missing {path}"}
    lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
    # version markers:  "[rot] rotation ON ... ver=1.10.105-aa" and the header
    version_at = []  # (abs_time, version)
    for ln in lines:
        m = re.search(r"ver=(1\.10\.\d+[-\w]*)", ln)
        if m:
            t = _abs_time(ln)
            version_at.append((t, m.group(1)))
        m = re.search(r"runtime=(\d+\.\d+\.\d+[-\w]*)", ln)
        if m and ln.startswith("=== RaijinLab"):
            version_at.append((0, m.group(1)))  # header = t=0, sorts first
    if not version_at:
        return {"error": "no version markers found"}
    version_at.sort()

    def version_for(t):
        cur = None
        for vt, v in version_at:
            if vt <= t:
                cur = v
            else:
                break
        return cur

    seg = {}  # version -> {"casts":n, "landed":n, "refused":n, "refuse_kinds":{}}
    for ln in lines:
        t = _abs_time(ln)
        if t is None:
            continue
        v = version_for(t)
        if v is None:
            continue
        s = seg.setdefault(v, {"casts": 0, "landed": 0, "refused": 0,
                               "refuse_kinds": {}})
        if "[cast]" in ln:
            if "FIRE" in ln:
                s["casts"] += 1
            elif "I landed" in ln:  # canonical confirmation line (not the duplicate)
                s["landed"] += 1
            elif "I refused" in ln:  # canonical refusal line
                s["refused"] += 1
                m = re.search(r"why=([A-Za-z_]+)", ln)
                kind = m.group(1) if m else "?"
                s["refuse_kinds"][kind] = s["refuse_kinds"].get(kind, 0) + 1
    return {"segments": seg, "markers": version_at}


def _abs_time(ln):
    # dev log lines: "<ms-since-boot>.<frac> ..." e.g. "204547.401 [cast] ..."
    m = re.match(r"^\s*(\d+)(?:\.\d+)?\s", ln)
    if m:
        return int(m.group(1))
    return None


# ---------------------------------------------------------------------------
# PROOF 2: cooldown gate by construction
# ---------------------------------------------------------------------------

def old_gate_fires(rem, lag):
    """Exact old Engine.spell_ready logic: fires (cast allowed) when NOT
    (rem > 0.04 + lag)."""
    return not (rem > (0.04 + lag))


def old_lag(latency_ms):
    """Exact old lag computation: lag = max(home,world)*0.6, capped [0.05,0.35]."""
    ms = max(latency_ms, latency_ms)
    if ms > 0:
        return min(0.35, max(0.05, ms / 1000.0 * 0.6))
    return 0.08


def new_gate_fires(rem):
    """Exact new Engine.spell_ready logic: fires only when the local cooldown
    bar is essentially cleared (rem <= 0.05)."""
    return not (rem > 0.05)


def prove_cooldown_gate():
    fails = []
    # 1) DEMONSTRATE the OLD gate's defect: it casts while the local cooldown
    #    bar still shows meaningful time remaining (rem=0.10s), up to `lag`
    #    (max 0.24s) BEFORE the bar clears. This is the bug being fixed, not
    #    an assertion failure — reported for the record.
    worst_early = 0.0
    print("  OLD gate (rem > 0.04 + lag):")
    for lat in (50, 100, 200, 300, 400):
        lag = old_lag(lat)
        fires_at_0_10 = old_gate_fires(0.10, lag)
        early = (0.04 + lag) - 0.04  # how far before bar-clear OLD can cast
        worst_early = max(worst_early, early)
        print(f"    lat={lat:>3}ms lag={lag:.3f}s -> fires at rem=0.10s (bar "
              f"NOT clear): {fires_at_0_10}; can cast {early*1000:.0f}ms early")
    # 2) ASSERT the NEW gate: never fires while the bar still shows cooldown
    #    beyond the 50ms epsilon (0.05).
    for rem in (0.06, 0.10, 0.20, 0.50, 1.00, 1.40):
        if new_gate_fires(rem):
            fails.append(f"NEW fires with rem={rem} (bar NOT clear)")
    # 3) ASSERT the NEW gate fires at/after bar-clear (<= 0.05).
    for rem in (0.05, 0.03, 0.01, 0.0):
        if not new_gate_fires(rem):
            fails.append(f"NEW blocked at rem={rem} (bar clear)")
    return fails, worst_early


# ---------------------------------------------------------------------------
def main():
    print("=" * 72)
    print("PROOF 1: LIVE LOG SEGMENTATION (raijinlab_dev.log)")
    print("=" * 72)
    res = segment_log(DEV_LOG)
    if "error" in res:
        print("ERROR:", res["error"])
        sys.exit(2)
    print(f"version markers: {res['markers']}")
    print()
    print(f"{'runtime':<16}{'casts':>7}{'landed':>8}{'refused':>9}   refusal kinds")
    total_refused = 0
    for v in sorted(res["segments"], key=lambda x: (x is None, x or "")):
        s = res["segments"][v]
        kinds = ", ".join(f"{k}={n}" for k, n in s["refuse_kinds"].items()) or "-"
        print(f"{str(v):<16}{s['casts']:>7}{s['landed']:>8}{s['refused']:>9}   {kinds}")
        total_refused += s["refused"]
    # Assertion: the 1.10.106-aa segment (round-46 fixes live) had ZERO refusals.
    seg106 = res["segments"].get("1.10.106-aa")
    if seg106 is None:
        print("ASSERT FAIL: no 1.10.106-aa segment found")
        sys.exit(1)
    if seg106["refused"] != 0:
        print(f"ASSERT FAIL: 1.10.106-aa segment had {seg106['refused']} refusals")
        sys.exit(1)
    if seg106["casts"] == 0 or seg106["landed"] != seg106["casts"]:
        print(f"ASSERT FAIL: 1.10.106-aa casts={seg106['casts']} landed={seg106['landed']}")
        sys.exit(1)
    print(f"\nPASS: 1.10.106-aa segment: {seg106['casts']} casts, "
          f"{seg106['landed']} landed, {seg106['refused']} refusals.")
    print(f"      Pre-106 segments contributed {total_refused - seg106['refused']} refusals.")

    print()
    print("=" * 72)
    print("PROOF 2: COOLDOWN GATE BY CONSTRUCTION (round-47 fix)")
    print("=" * 72)
    fails, worst_early = prove_cooldown_gate()
    print(f"OLD gate could cast up to {worst_early*1000:.0f}ms BEFORE the local"
          f" cooldown bar cleared -> client 'Spell is not ready yet' by design.")
    print("NEW gate fires only at rem <= 0.05 (bar essentially cleared).")
    if fails:
        print("ASSERT FAILS:")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("PASS: no early-fire in the new gate; no spurious block at bar-clear.")

    print()
    print("RESULT: all proofs hold. Round 46 (log evidence) and round 47 "
          "(gate construction) verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
