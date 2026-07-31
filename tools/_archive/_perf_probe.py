"""Rays and jumps only when they earn their cost.

Two live complaints, one root: the probe fires bursts of raycasts in a single
frame (chest sweep 3 + foot sweep 3, times two headings, plus the cliff fan -
up to ~26 CGWorldFrame intersects in one frame, every 100ms), and the foot ray
treats an uphill SLOPE as a hoppable lip, so the character jumps continuously
while climbing and gets thrown off course.

Frame telemetry cannot even see the burst: the 1Hz heartbeat reads an EMA, so a
5-10ms spike every 100ms reads as a clean 33.4ms median while feeling like
"extreme lag". Fix the cost, and instrument the spike so it can never hide again.
"""
from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

# ---- 1. chest sweep: centre + ONE alternating shoulder per tick ------------
OLD1 = """    local chest_hit, hx, hy, chest_off
    for _, o in ipairs({ 0, half, -half }) do"""
NEW1 = """    -- TWO RAYS, NOT THREE. Casting centre + both shoulders every probe made the
    -- probe tick a burst: with the foot sweep and the second heading it reached
    -- ~26 intersects in ONE frame, every 100ms - a spike the 1Hz EMA heartbeat
    -- cannot see but the player feels as constant stutter. Centre + ONE shoulder,
    -- alternating sides per tick, keeps full trunk coverage with detection
    -- latency of at most one probe period (0.7yd at run speed, inside the 2.2yd
    -- reach) at two-thirds the cost.
    a.sweep_side = -(a.sweep_side or 1)
    local chest_hit, hx, hy, chest_off
    for _, o in ipairs({ 0, half * a.sweep_side }) do"""
assert OLD1 in s, "chest sweep header not found"
s = s.replace(OLD1, NEW1, 1)

# ---- 2. foot sweep: only when progress has actually stalled ----------------
OLD2 = """    -- A WALL BASE IS NOT A HOPPABLE LIP. The foot ray catches the bottom of a
    -- building while the chest ray happens to miss (different shoulder, or a
    -- doorframe), and the lip rule then says "hop it" - so the bot stands at a
    -- church jumping. 11 such hops in one live session. If we are committed to
    -- rounding a wall, or a wall was seen recently, a foot hit is part of that
    -- wall and jumping only wastes the airtime we cannot steer through.
    if foot_hit and fx2 and (a.wall_side or 0) ~= 0 then
        foot_hit = nil
    end
    if foot_hit and fx2 then
        do"""
NEW2 = """    if foot_hit and fx2 then
        do"""
OLD3 = """    local foot_hit, fx2, fy2
    for _, o in ipairs({ 0, half, -half }) do"""
NEW3 = """    -- JUMPING IS A REMEDY FOR BEING SNAGGED, NOT A GREETING FOR TERRAIN.
    --
    -- Walking uphill, the ground 2.2yd ahead is HIGHER than your feet, so the
    -- horizontal foot ray hits the slope itself; the chest ray clears, the lip
    -- rule said "hoppable", and the character jumped continuously while climbing
    -- - thrown off course by its own airtime, for terrain it walks up anyway.
    -- The client climbs every walkable slope without help; a hop only ever earns
    -- its cost when the character is physically STUCK on something.
    --
    -- So the foot sweep runs only when forward progress has actually stalled
    -- (no 0.8yd progress step for jump_stall secs). While we are advancing there
    -- is nothing to fix - and no foot rays to pay for, which is most of the
    -- probe's former per-tick burst. A committed wall detour also skips it:
    -- a foot hit there is the wall's base, and airtime cannot be steered.
    local stalled = (now() - (a.progress_t or now())) > (c.jump_stall or 0.35)
    local foot_hit, fx2, fy2
    if not stalled or (a.wall_side or 0) ~= 0 then
        -- advancing, or rounding a wall: no hop, no rays
    else
    for _, o in ipairs({ 0, half * a.sweep_side }) do"""
assert OLD3 in s, "foot sweep header not found"
assert OLD2 in s, "foot wall-side gate not found"
s = s.replace(OLD3, NEW3, 1)
s = s.replace(OLD2, NEW2, 1)
# close the new else-branch: the sweep's terminating `end` needs one more
OLD4 = """                foot_hit, fx2, fy2 = hit, ihx, ihy
                break
            end
        end
    end
    if foot_hit and fx2 then"""
NEW4 = """                foot_hit, fx2, fy2 = hit, ihx, ihy
                break
            end
        end
    end
    end
    if foot_hit and fx2 then"""
assert OLD4 in s, "foot sweep tail not found"
s = s.replace(OLD4, NEW4, 1)

# ---- 3. second heading: alternate ticks instead of doubling the burst ------
OLD5 = """        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        if dh > 0.25 then"""
NEW5 = """        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        -- Alternate ticks rather than double-probing in one frame: the second
        -- full sweep in the same tick is what pushed the burst to ~26 rays. The
        -- target-heading probe only feeds pre-turn awareness, so +100ms latency
        -- on it costs nothing observable; halving the frame spike does.
        a.dual_flip = not a.dual_flip
        if dh > 0.25 and a.dual_flip then"""
assert OLD5 in s, "dual-heading block not found"
s = s.replace(OLD5, NEW5, 1)

# ---- 4. make the spike measurable: time the probe at its CALL SITE ---------
# (call-site timing, not an IIFE wrapper around the function body - text
# surgery on a function's return structure is exactly how main() got truncated)
OLD6 = """    local travel_h = cf or target_h"""
NEW6 = """    -- Account for our own burst. The 1Hz heartbeat reads an EMA, so a multi-ms
    -- probe spike every 100ms hid inside a clean 33ms median while the player
    -- reported extreme stutter. Track the worst probe cost each second and put
    -- it in the heartbeat: a cost that cannot be seen cannot be argued about.
    local __t0 = debugprofilestop and debugprofilestop()
    local travel_h = cf or target_h"""
assert OLD6 in s, "probe call site not found"
s = s.replace(OLD6, NEW6, 1)

OLD7 = """            a.probe_t = a.probe_t2
            terrain_probe(a, px, py, pz, target_h)
            a.probe_t2 = a.probe_t
            a.probe_t = saved
        end
    end"""
NEW7 = """            a.probe_t = a.probe_t2
            terrain_probe(a, px, py, pz, target_h)
            a.probe_t2 = a.probe_t
            a.probe_t = saved
        end
        if __t0 and debugprofilestop then
            local __ms = debugprofilestop() - __t0
            if __ms > (Navigator._probe_peak or 0) then Navigator._probe_peak = __ms end
        end
    end"""
assert OLD7 in s, "dual probe tail not found"
s = s.replace(OLD7, NEW7, 1)
p.write_text(s, encoding="utf-8")
print("Navigator: lazy sweeps, stall-gated hop, alternating dual probe, call-site spike accounting")

# tunable
t = p.read_text(encoding="utf-8")
A = "    wall_commit = 1.5,"
N = "    jump_stall = 0.35,        -- secs without forward progress before a foot-lip hop is even considered" + chr(10) + "    wall_commit = 1.5,"
assert A in t
t = t.replace(A, N, 1)
t = t.replace("local CFG_VERSION = 10", "local CFG_VERSION = 11", 1)
p.write_text(t, encoding="utf-8")
print("tunables added")
