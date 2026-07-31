from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

# ---- 1. COMMIT to a side once chosen --------------------------------------
OLD = """            local side = chest_off or 0
            local want
            if side > 0 then want = -0.9          -- hit on the left -> go right
            elseif side < 0 then want = 0.9       -- hit on the right -> go left
            else
                -- centre hit: no side information, so keep the alternating
                -- behaviour rather than guessing a direction
                want = (a.recover_n % 2 == 0) and 0.9 or -0.9
            end
            if (a.detour or 0) == 0 then a.detour = want end"""

NEW = """            -- COMMIT TO A SIDE. Choosing purely from which shoulder hit made
            -- the bot oscillate: the left ray hits so we turn right, which swings
            -- the RIGHT shoulder into the wall, so we turn left, forever. The
            -- live log shows it as consecutive `detour 0.90` / `detour -0.90`.
            --
            -- A wall is a surface, not a point. The way past it is to pick one
            -- direction and HOLD it until the way is actually clear - the same
            -- hysteresis the strafe controller already uses. Re-deciding every
            -- probe is what produces the random-looking dance.
            local side = chest_off or 0
            local want
            if side > 0 then want = -0.9          -- hit on the left -> go right
            elseif side < 0 then want = 0.9       -- hit on the right -> go left
            else
                -- centre hit carries no side information. Keep whatever we were
                -- already committed to; only invent a direction if we have none.
                want = (a.wall_side ~= 0 and a.wall_side)
                    or ((a.recover_n % 2 == 0) and 0.9 or -0.9)
            end
            if (a.wall_side or 0) == 0 then
                a.wall_side = want                 -- first contact: choose
            end
            a.wall_hold_t = now()                  -- keep the commitment alive
            a.detour = a.wall_side"""
assert OLD in s, "detour side block not found"
s = s.replace(OLD, NEW, 1)

# release the commitment only when the way has been clear for a moment
OLD2 = """    a.block = false
    -- a fresh probe owns the verdict: last tick's wall is not evidence
    a.sensor_detour = false"""
NEW2 = """    a.block = false
    -- a fresh probe owns the verdict: last tick's wall is not evidence
    a.sensor_detour = false
    -- ...but the SIDE we committed to is not a per-probe verdict. Release it
    -- only after the way has stayed clear for a moment, otherwise the first
    -- clear probe mid-detour drops the commitment and the oscillation returns.
    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_commit or 1.5) then
        a.wall_side = 0
        a.wall_hold_t = nil
    end"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)

# ---- 2. never hop when a wall is in front ---------------------------------
OLD3 = """    if foot_hit and fx2 then
        do"""
NEW3 = """    -- A WALL BASE IS NOT A HOPPABLE LIP. The foot ray catches the bottom of a
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
assert OLD3 in s, "foot-hit block not found"
s = s.replace(OLD3, NEW3, 1)

# tunable
OLD4 = "    body_radius = 0.45,"
NEW4 = ("    wall_commit = 1.5,        -- secs to hold a chosen way-around before re-deciding (anti-oscillation)\n"
        "    body_radius = 0.45,")
assert OLD4 in s
s = s.replace(OLD4, NEW4, 1)
s = s.replace("local CFG_VERSION = 9", "local CFG_VERSION = 10", 1)
p.write_text(s, encoding="utf-8")
print("Navigator: detour commitment + no hopping at walls")
