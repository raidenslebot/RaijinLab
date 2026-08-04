"""Run every measurement that was blocked on a live client, in one pass.

As of 2026-08-03 four basic-check gates and one offset are blocked on exactly
one thing: no Ascension process is running. They are MEASUREMENTS, not design
problems, and each is seconds of work with a live client - so this script
performs all of them and prints a verdict, rather than making the next session
re-derive what to look for.

    python tools/measure_blocked.py            # everything that needs no input
    python tools/measure_blocked.py --seated   # run AGAIN while sitting down

WHAT IT MEASURES

  1. Flags2 (gate #5, exotic unit types). Offsets.h carries Flags2 = 0xF0,
     DERIVED BY ARITHMETIC from the verified Flags = 0xEC and never read live.
     Nothing may gate on it until it is confirmed: an unverified offset is what
     left gate #20 silently dead for months (Bytes2 = 0xCC pointed into a zero
     region, so ShapeshiftForm answered "unshifted" for every caster in every
     form while passing its own gate).

  2. Bytes1 / standState (gate #21, sitting). The full descriptor 0x00..0x400
     was already diffed standing -> seated -> standing and BOTH diffs came back
     empty, so standState is almost certainly an INSTANCE field rather than a
     descriptor field - as Facing (0x7A8) and QuestGiverStatus (0x90) already
     are. This widens the search to the instance block, which that earlier pass
     never covered.

  3. The staged runtime offsets (Bytes0 0x5C, Bytes2 0x1E8, AuraState 0x0F4,
     DisplayId 0x10C, NativeDisplayId 0x110) re-confirmed against live client
     values, so a bad re-injection cannot pass silently.

HOW TO USE THE SITTING PASS
    1. python tools/measure_blocked.py            (standing - writes a snapshot)
    2. sit down in game (/sit)
    3. python tools/measure_blocked.py --seated   (prints the fields that moved)

Any dword whose BYTE 0 changes between the two passes is standState.
"""
import subprocess
import sys
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAP = ROOT / "tests" / ".standing_snapshot.json"


def rl(lua: str) -> str:
    """Run a Lua expression in the live client via the named pipe."""
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "rlctl.py"), lua],
                       cwd=str(ROOT), capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=180)
    return (r.stdout or "") + (r.stderr or "")


def alive() -> bool:
    out = rl("return 'ok'")
    if "cannot open" in out:
        print("NO LIVE CLIENT. Start Ascension, inject "
              "runtime\\dist\\RaijinLabLoader.exe, then re-run.")
        return False
    return True


# Descriptor + instance sweep. Instance fields live past the descriptor - Facing
# is at 0x7A8 - so the range deliberately covers both.
SWEEP = """
local R = RaijinLab
local g = UnitGUID('player')
local out = {}
for off = 0x00, 0x900, 4 do
  local v = R:RuntimeCall('ObjectField', g, off)
  if type(v) == 'number' then out[#out+1] = off .. '=' .. v end
end
return table.concat(out, ',')
"""


def parse(raw: str) -> dict:
    d = {}
    for line in raw.splitlines():
        if "=" not in line or "," not in line:
            continue
        for pair in line.strip().split(","):
            if "=" in pair:
                k, _, v = pair.partition("=")
                try:
                    d[int(k.strip())] = int(v.strip())
                except ValueError:
                    pass
        if d:
            break
    return d


def confirm_offsets() -> None:
    print("=== staged offsets vs live client ===")
    out = rl("""
local R = RaijinLab
local g = UnitGUID('player')
local function f(o) return R:RuntimeCall('ObjectField', g, o) or -1 end
local _, _, rid = UnitRace('player')
local _, _, cid = UnitClass('player')
local b0 = f(0x5C)
local function byte(v,n) return math.floor(v/(256^n))%256 end
return string.format(
  'bytes0=%d/%d client=%d/%d | hp=%d client=%d | lvl=%d client=%d | '
  .. 'bytes2=0x%08X | aurastate=0x%08X | display=%d native=%d',
  byte(b0,0), byte(b0,1), rid or -1, cid or -1,
  f(0x60), UnitHealth('player'), f(0xD8), UnitLevel('player'),
  f(0x1E8), f(0xF4), f(0x10C), f(0x110))
""")
    print("  " + out.strip().splitlines()[-1] if out.strip() else "  (no answer)")
    print("  PASS when bytes0 race/class match the client, hp/lvl match, and")
    print("  bytes2 is non-zero and PACKED (e.g. 0x00000801).")


def flags2() -> None:
    print("=== Flags2 (gate #5) - UNVERIFIED, derived by arithmetic ===")
    out = rl("""
local R = RaijinLab
local g = UnitGUID('player')
local o = {}
for _, off in ipairs({0xE8, 0xEC, 0xF0, 0xF4, 0xF8}) do
  o[#o+1] = string.format('%X=0x%08X', off, R:RuntimeCall('ObjectField', g, off) or 0)
end
return table.concat(o, ' ')
""")
    print("  " + (out.strip().splitlines()[-1] if out.strip() else "(no answer)"))
    print("  0xEC is UNIT_FIELD_FLAGS (verified in use). If 0xF0 holds a")
    print("  plausible flag word rather than 0, Flags2 = 0xF0 is supported and")
    print("  #5 can be wired. A zero here means it is NOT confirmed - leave it.")


def main() -> int:
    if not alive():
        return 1
    seated = "--seated" in sys.argv
    confirm_offsets()
    flags2()

    print("=== standState hunt (gate #21) ===")
    now = parse(rl(SWEEP))
    if not now:
        print("  sweep returned nothing - is the object manager warm?")
        return 1
    if not seated:
        SNAP.write_text(json.dumps({str(k): v for k, v in now.items()}),
                        encoding="utf-8")
        print("  standing snapshot written (%d fields)." % len(now))
        print("  NOW SIT DOWN IN GAME (/sit), then re-run with --seated.")
        return 0

    if not SNAP.exists():
        print("  no standing snapshot - run once WITHOUT --seated first.")
        return 1
    was = {int(k): v for k, v in json.loads(SNAP.read_text(encoding="utf-8")).items()}
    moved = [(o, was[o], now[o]) for o in sorted(now)
             if o in was and was[o] != now[o]]
    if not moved:
        print("  NOTHING MOVED across 0x00..0x900 either. That is a RESULT:")
        print("  standState is not reachable through ObjectField at all, and")
        print("  gate #21 should stay abstaining rather than be guessed at.")
        return 0
    print("  fields that changed between standing and seated:")
    for off, a, b in moved:
        tag = "  <-- BYTE 0 CHANGED, standState candidate" if (a & 0xFF) != (b & 0xFF) else ""
        print("    0x%03X  0x%08X -> 0x%08X%s" % (off, a, b, tag))
    print("  Take the BYTE-0 candidate: that is UNIT_FIELD_BYTES_1.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
