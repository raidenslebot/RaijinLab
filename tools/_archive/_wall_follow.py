"""Slide along a wall instead of leaning on it.

Live symptom and simulator agree: the character reaches a building/wall face and
stays there. `plans_around_walls_at_range` ends at x=296.5 against a wall
spanning x=300..320, y=-400..400, 72% stationary.

Why a fixed detour cannot work: 0.9 rad off the goal heading still has a large
forward component (cos 0.9 = 0.62), so against a long wall the character keeps
walking INTO it at 62% speed while bending 51 degrees. It never gets round,
because the way round is 400 yards sideways.

A wall is a surface. The way past a surface is to travel ALONG it, which means
turning until the sensor stops seeing it - not turning by a constant. So the
detour now escalates while contact persists, up to perpendicular (pi/2, pure
sideways) and slightly beyond, and relaxes back toward the goal as soon as the
way is clear. That is ordinary wall-following, and it is the difference between
"bounces off a corner" and "gets round a church".

The escalation is bounded, monotonic while in contact, and released by the same
wall_commit timer as the side choice - so it cannot oscillate.
"""
from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

OLD = """            if (a.wall_side or 0) == 0 then
                a.wall_side = want                 -- first contact: choose
            end
            a.wall_hold_t = now()                  -- keep the commitment alive
            a.detour = a.wall_side"""

NEW = """            if (a.wall_side or 0) == 0 then
                a.wall_side = want                 -- first contact: choose
                a.wall_bend = c.wall_bend0 or 0.9  -- and start at the gentle bend
            end
            a.wall_hold_t = now()                  -- keep the commitment alive

            -- ESCALATE WHILE THE WALL IS STILL THERE.
            --
            -- A constant 0.9 rad keeps 62% of forward speed pointed INTO the
            -- surface, so against a long wall the character leans on the face
            -- forever - exactly the live "runs into the building and stays
            -- there", and 72% stationary at x=296.5 in the simulator.
            --
            -- Each probe that still sees the wall bends further, toward
            -- perpendicular: at pi/2 the motion is purely along the surface,
            -- which is what actually gets round it. Capped just past
            -- perpendicular so we can clear a corner without ever reversing into
            -- the goal.
            local step = c.wall_bend_step or 0.25
            local capb = c.wall_bend_max or 1.9        -- ~109 deg
            a.wall_bend = math.min((a.wall_bend or (c.wall_bend0 or 0.9)) + step, capb)
            a.detour = a.wall_side >= 0 and a.wall_bend or -a.wall_bend"""
assert OLD in s, "wall commit block not found"
s = s.replace(OLD, NEW, 1)

# relax the bend when the way is clear, alongside the existing side release
OLD2 = """    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_commit or 1.5) then
        a.wall_side = 0
        a.wall_hold_t = nil
    end"""
NEW2 = """    -- RELAX BEFORE RELEASING. A clear probe means the bend is working, not that
    -- it is unnecessary: dropping straight back to the goal heading swings the
    -- body into the surface we were just clearing. Ease the bend down first, and
    -- only drop the side commitment once we are actually straightened out.
    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_relax or 0.4) then
        local b = (a.wall_bend or 0) - (c.wall_bend_step or 0.25)
        if b <= (c.wall_bend0 or 0.9) * 0.5 then b = 0 end
        a.wall_bend = b
        if b > 0 and (a.wall_side or 0) ~= 0 then
            a.detour = a.wall_side >= 0 and b or -b
            a.sensor_detour = true                 -- still perception's, not stale
        end
    end
    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_commit or 1.5)
        and (a.wall_bend or 0) <= 0 then
        a.wall_side = 0
        a.wall_bend = 0
        a.wall_hold_t = nil
    end"""
assert OLD2 in s, "wall release block not found"
s = s.replace(OLD2, NEW2, 1)

# tunables
A = "    wall_commit = 1.5,"
N = ("    wall_bend0 = 0.9,         -- rad: first bend on wall contact\n"
     "    wall_bend_step = 0.25,    -- rad added per probe while contact persists (wall-following)\n"
     "    wall_bend_max = 1.9,      -- rad: just past perpendicular, so a corner clears without reversing\n"
     "    wall_relax = 0.4,         -- secs of clear probes before easing the bend back toward the goal\n"
     "    wall_commit = 1.5,")
assert A in s
s = s.replace(A, N, 1)
s = s.replace("local CFG_VERSION = 11", "local CFG_VERSION = 12", 1)
p.write_text(s, encoding="utf-8")
print("Navigator: wall-following (escalating bend, eased release)")
