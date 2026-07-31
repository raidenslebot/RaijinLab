"""Drive the live navigator for a STRICTLY BOUNDED window and trace every frame.

WHY THIS EXISTS.

Watching the bot navigate has been the slowest loop in this project. Two things
made it slow, and this fixes both:

  * IT RAN UNTIL SOMEONE STOPPED IT. A bad route means the character grinds into
    a building for as long as nobody intervenes, which is unpleasant to watch and
    tells you nothing after the first second. The window here is a hard cap: the
    stop runs in a `finally`, so it happens on success, on failure, on a timeout,
    and on Ctrl-C.
  * SAMPLING OVER THE PIPE WAS TOO COARSE. One round trip per sample gives maybe
    2Hz, and a steering fault lives between those samples. The recorder is
    installed IN THE CLIENT as an OnUpdate and writes into a ring buffer, so the
    trace is per FRAME (~30-60Hz). The pipe is only used to start it, stop it,
    and collect the result.

What a row contains is deliberately everything that has ever been needed to
explain a navigation failure - position, the steering loop, the planner, and what
the mesh says about the ground under and ahead of the character - because going
back for "one more field" costs another live run.

Usage
    python tools/navtest.py                 # 8s, current goal (quest suite)
    python tools/navtest.py --secs 5
    python tools/navtest.py --to 1838 1563  # navigate to a world point
    python tools/navtest.py --corpse        # run to the corpse
    python tools/navtest.py --raw           # dump every row, not the summary
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RLCTL = os.path.join(HERE, "rlctl.py")

# Installed in the client. Samples once per frame into a ring buffer.
#
# Kept deliberately cheap: no string building, no allocation beyond one row per
# frame, and every call wrapped so a nil API can never break the client we are
# trying to observe. A tracer that crashes the subject is worse than no tracer.
RECORDER = r"""
local R = RaijinLab
R.__navtrace = { rows = {}, n = 0, t0 = GetTime and GetTime() or 0 }
local T = R.__navtrace
if R.__navtrace_frame then R.__navtrace_frame:SetScript("OnUpdate", nil) end
R.__navtrace_frame = R.__navtrace_frame or CreateFrame("Frame")

local function num(v) if type(v) == "number" then return v end return nil end

R.__navtrace_frame:SetScript("OnUpdate", function()
    local N = R.Navigator
    if not N then return end
    local ok = pcall(function()
        local px, py, pz = R:ObjectPosition("player")
        if not px then return end
        local now = (GetTime and GetTime()) or 0
        local a = N._active
        local g = N._pf_final_goal or N._pf_goal
        local NG = R.NavGrid
        local code, gh, gres
        if NG and NG.at then code, gh, gres = NG.at(px, py) end
        -- BOTH the base answer and the FLOOR-AWARE one, with their heights.
        -- Logging only at()'s height made it impossible to tell whether the
        -- multi-floor lookup picked the storey the character is standing on or
        -- silently fell back to the terrain below - and a trace that cannot
        -- distinguish those is a trace that cannot explain an indoor collision.
        local codez, hz
        if NG and NG.at_z then codez, hz = NG.at_z(px, py, pz) end
        local nsurf
        if NG and NG.surfaces then
            local sf = NG.surfaces(px, py)
            nsurf = sf and #sf or 0
        end
        -- what the mesh says 3yd ahead of where we FACE: the cell we are about
        -- to walk into is the one that explains a collision.
        local f = R:ObjectFacing("player")
        local ax, ay, acode, ah
        if f then
            ax, ay = px + math.cos(f) * 3, py + math.sin(f) * 3
            if NG and NG.at_z then acode, ah = NG.at_z(ax, ay, pz) end
        end
        T.n = T.n + 1
        T.rows[T.n] = {
            t     = now - T.t0,
            x     = px, y = py, z = pz,
            face  = num(f),
            st    = tostring(N.state),
            mov   = N._moving and 1 or 0,
            act   = (a ~= nil) and 1 or 0,
            meth  = tostring(N._method),
            err   = num(N._err),
            tcmd  = num(N._last_turn_cmd),
            eff   = num(N._eff),
            blk   = (a and a.block) and 1 or 0,
            wside = num(a and a.wall_side),
            det   = num(a and a.detour),
            wfol  = N._wall_follow and 1 or 0,
            held  = num(N._held_for_aim_n),
            lerr  = tostring(N._last_err),
            gx    = num(g and g.x), gy = num(g and g.y), gz = num(g and g.z),
            pf    = tostring(N._pf_dbg),
            rep   = num(N._replan_n),
            code  = num(code), gh = num(gh), res = num(gres),
            codez = num(codez), hz = num(hz), nsurf = num(nsurf),
            acode = num(acode), ah = num(ah),
        }
        if T.n > 2000 then T.rows[T.n - 2000] = nil end   -- bound the buffer
    end)
end)
return "recording"
"""

STOP = r"""
local R = RaijinLab
if R.__navtrace_frame then R.__navtrace_frame:SetScript("OnUpdate", nil) end
pcall(function() if R.QuestSuite and R.QuestSuite.stop then R.QuestSuite.stop() end end)
pcall(function() if R.Master and R.Master.off then R.Master.off("navtest") end end)
pcall(function() if R.Navigator and R.Navigator.stop then R.Navigator.stop() end end)
local a = R.Actions
if a then
    pcall(a.MoveForward, false)
    pcall(a.StrafeLeft, false); pcall(a.StrafeRight, false)
    pcall(a.TurnLeft, false);  pcall(a.TurnRight, false)
end
return "stopped"
"""

# Fetched in SLICES. The first version asked for the whole trace in one reply
# and got 60,012 bytes of truncated JSON - the transport has a ceiling, and a
# tracer that loses its own data at the moment of use is worthless. Rows are
# pulled in batches small enough to survive it.
DUMP = r"""
local T = RaijinLab.__navtrace
if not T then return "0" end
return tostring(T.n)
"""

DUMP_RANGE = r"""
local T = RaijinLab.__navtrace
if not T then return "[]" end
local a, b = %d, %d
local out, n = {}, 0
local function add(s) n = n + 1; out[n] = s end
add("[")
local first = true
for i = a, b do
    local r = T.rows[i]
    if r then
        if not first then add(",") end
        first = false
        local parts = {}
        for k, v in pairs(r) do
            local val
            if type(v) == "number" then val = string.format("%%.3f", v)
            else val = '"' .. tostring(v):gsub('[\\"]', "'"):gsub("%%c", " ") .. '"' end
            parts[#parts + 1] = '"' .. k .. '":' .. val
        end
        add("{" .. table.concat(parts, ",") .. "}")
    end
end
add("]")
return table.concat(out)
"""


def rl(code, timeout=40):
    r = subprocess.run([sys.executable, RLCTL, code],
                       capture_output=True, text=True, timeout=timeout)
    return (r.stdout or "").strip(), (r.stderr or "").strip(), r.returncode


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=8.0,
                    help="hard cap on how long the bot may move (default 8)")
    ap.add_argument("--to", nargs=2, type=float, metavar=("X", "Y"))
    ap.add_argument("--corpse", action="store_true")
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("--every", type=int, default=6,
                    help="print every Nth frame in the trace (default 6)")
    args = ap.parse_args(argv[1:])

    # The cap is not advisory. Anything below this line runs inside the try, and
    # the stop is in the finally - so a crash, a timeout or a Ctrl-C still leaves
    # the character standing still rather than grinding into a wall.
    if args.secs <= 0 or args.secs > 30:
        print("refusing a window of %.1fs - this exists to be SHORT" % args.secs)
        return 2

    out, err, rc = rl(RECORDER)
    if "recording" not in out:
        print("could not install the recorder: %s%s" % (out, err))
        return 1

    started = None
    try:
        if args.to:
            start = ('local R = RaijinLab local px, py, pz = R:ObjectPosition("player") '
                     'R.Navigator.move_to({ x = %f, y = %f, z = pz }, { arrive_dist = 3 }) '
                     'return "goto"' % (args.to[0], args.to[1]))
        elif args.corpse:
            start = ('local R = RaijinLab local cx, cy, cz = R.Death.corpse_pos() '
                     'if not cx then return "no corpse position" end '
                     'R.Navigator.move_to({ x = cx, y = cy, z = cz }, { arrive_dist = 4 }) '
                     'return "corpse run"')
        else:
            start = ('local R = RaijinLab '
                     'if R.Master and R.Master.on then R.Master.on("navtest", {"quest"}) end '
                     'R.QuestSuite.start() return "suite"')
        started, serr, _ = rl(start)
        print("start: %s" % (started or serr))
        if "no corpse" in (started or ""):
            return 1
        time.sleep(args.secs)
    finally:
        s, _, _ = rl(STOP)
        print("stop:  %s  (window %.1fs)" % (s, args.secs))

    cnt, _, _ = rl(DUMP, timeout=30)
    try:
        total = int(float(cnt.strip()))
    except Exception:
        print("could not read the frame count: %r" % cnt[:120])
        return 1
    rows, BATCH = [], 40
    for a in range(1, total + 1, BATCH):
        chunk, cerr, _ = rl(DUMP_RANGE % (a, min(a + BATCH - 1, total)), timeout=40)
        try:
            rows.extend(json.loads(chunk))
        except Exception:
            print("  (dropped frames %d-%d: unparseable)" % (a, a + BATCH - 1))
    if not rows:
        print("no frames parsed out of %d recorded" % total)
        return 1
    if not rows:
        print("no frames recorded - was the client in world?")
        return 1

    rows.sort(key=lambda r: r.get("t", 0))
    print("\n%d frames over %.2fs (%.0f fps)"
          % (len(rows), rows[-1]["t"] - rows[0]["t"],
             len(rows) / max(0.001, rows[-1]["t"] - rows[0]["t"])))

    def d(a, b):
        return ((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2) ** 0.5

    travelled = sum(d(rows[i], rows[i - 1]) for i in range(1, len(rows)))
    net = d(rows[-1], rows[0])
    print("travelled %.1fyd, net %.1fyd" % (travelled, net))
    if rows[0].get("gx") is not None:
        g = {"x": rows[0]["gx"], "y": rows[0]["gy"]}
        print("goal distance %.1f -> %.1f yd" % (d(rows[0], g), d(rows[-1], g)))

    hdr = ("    t     x       y      z    face   err  turn  st        mv blk wf "
           "code ahead  base    floor  dz   nsf goal-d")
    print("\n" + hdr)
    print("-" * len(hdr))
    step = 1 if args.raw else max(1, args.every)
    for i in range(0, len(rows), step):
        r = rows[i]
        gd = ""
        if r.get("gx") is not None:
            gd = "%7.1f" % (((r["x"] - r["gx"]) ** 2 + (r["y"] - r["gy"]) ** 2) ** 0.5)
        hz = r.get("hz")
        dz = ("%5.1f" % (r["z"] - hz)) if hz is not None else "    -"
        print("%5.2f %7.1f %7.1f %6.1f %6.2f %5.2f %5.2f  %-9s %d  %d  %d %4s %5s %7s %6s %s %3s %s"
              % (r.get("t", 0), r["x"], r["y"], r["z"], r.get("face") or 0,
                 r.get("err") or 0, r.get("tcmd") or 0, str(r.get("st"))[:9],
                 r.get("mov", 0), r.get("blk", 0), r.get("wfol", 0),
                 str(r.get("codez") if r.get("codez") is not None else r.get("code")),
                 str(r.get("acode")), ("%.1f" % r["gh"]) if r.get("gh") is not None else "-",
                 ("%.1f" % hz) if hz is not None else "-", dz,
                 str(r.get("nsurf")), gd))

    # A verdict, not just a table: the same four questions get asked every time.
    print("\nverdict")
    moving = sum(1 for r in rows if r.get("mov"))
    print("  moving           %d/%d frames (%.0f%%)"
          % (moving, len(rows), 100.0 * moving / len(rows)))
    errs = [r["err"] for r in rows if r.get("err") is not None]
    if errs:
        print("  heading error    first %.2f  last %.2f  max %.2f rad"
              % (errs[0], errs[-1], max(errs)))
    stuck = sum(1 for i in range(1, len(rows)) if d(rows[i], rows[i - 1]) < 0.01)
    print("  stationary       %d/%d frames" % (stuck, len(rows) - 1))
    blocked = sum(1 for r in rows if r.get("blk"))
    print("  blocked          %d frames, wall-following %d"
          % (blocked, sum(1 for r in rows if r.get("wfol"))))
    lerrs = set(str(r.get("lerr")) for r in rows) - {"nil", "None"}
    if lerrs:
        print("  errors reported  %s" % ", ".join(sorted(lerrs)))
    off = [abs(r["z"] - r["hz"]) for r in rows if r.get("hz") is not None]
    if off:
        off.sort()
        print("  |z - mesh floor|  median %.2f  p90 %.2f  max %.2f yd"
              % (off[len(off)//2], off[int(len(off)*0.9)], off[-1]))
        bad = sum(1 for v in off if v > 2.0)
        print("  frames where the mesh floor is >2yd from the feet: %d/%d"
              % (bad, len(off)))
    multi = sum(1 for r in rows if (r.get("nsurf") or 0) > 1)
    print("  frames over a multi-storey cell: %d/%d" % (multi, len(rows)))
    ahead_solid = sum(1 for r in rows if r.get("acode") in (3, 5, 6))
    print("  mesh says the cell 3yd AHEAD is solid on %d/%d frames"
          % (ahead_solid, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
