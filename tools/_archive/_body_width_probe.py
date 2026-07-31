from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

OLD = """    local chest_hit, hx, hy = RaijinLab:TraceLine(px, py, zc, ex, ey, zc, 0x100111)
    if chest_hit and hx then
        local dx, dy = hx - px, hy - py
        if math.sqrt(dx * dx + dy * dy) < reach then"""

NEW = """    -- A CHARACTER IS NOT A LINE. This cast one ray straight ahead, so anything
    -- narrower than the body and offset from dead centre - a tree trunk, a post,
    -- a lamp - was missed at chest height while the collision capsule still hit
    -- it. The foot ray then caught the roots, the lip rule said "hoppable", and
    -- the bot stood there trying to JUMP OVER A TREE. Reported verbatim.
    --
    -- Sweep the body's width instead: centre plus both shoulders, offset
    -- perpendicular to the heading. Three rays is the cheapest shape that cannot
    -- thread a trunk between them, and the probe is already throttled to
    -- probe_hz so the extra casts cost nothing measurable.
    local half = c.body_radius or 0.45
    local nx, ny = -math.sin(heading), math.cos(heading)   -- perpendicular
    local chest_hit, hx, hy
    for _, o in ipairs({ 0, half, -half }) do
        local sx, sy = px + nx * o, py + ny * o
        local tx, ty = ex + nx * o, ey + ny * o
        local hit, ihx, ihy = RaijinLab:TraceLine(sx, sy, zc, tx, ty, zc, 0x100111)
        if hit and ihx then
            -- measure from the ray's own origin, not the body centre, or an
            -- offset ray reports a distance it did not travel
            local ddx, ddy = ihx - sx, ihy - sy
            if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                chest_hit, hx, hy = hit, ihx, ihy
                break
            end
        end
    end
    if chest_hit and hx then
        do"""
assert OLD in s, "chest probe not found"
s = s.replace(OLD, NEW, 1)

# same for the foot ray: a lip we can hop must also be judged across the body
OLD2 = """    local foot_hit, fx2, fy2 = RaijinLab:TraceLine(px, py, zf, ex, ey, zf, 0x100111)
    if foot_hit and fx2 then
        local dx, dy = fx2 - px, fy2 - py
        if math.sqrt(dx * dx + dy * dy) < reach then"""
NEW2 = """    local foot_hit, fx2, fy2
    for _, o in ipairs({ 0, half, -half }) do
        local sx, sy = px + nx * o, py + ny * o
        local tx, ty = ex + nx * o, ey + ny * o
        local hit, ihx, ihy = RaijinLab:TraceLine(sx, sy, zf, tx, ty, zf, 0x100111)
        if hit and ihx then
            local ddx, ddy = ihx - sx, ihy - sy
            if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                foot_hit, fx2, fy2 = hit, ihx, ihy
                break
            end
        end
    end
    if foot_hit and fx2 then
        do"""
assert OLD2 in s, "foot probe not found"
s = s.replace(OLD2, NEW2, 1)

# declare the tunable
OLD3 = "    wall_probe = 2.2,         -- yd ahead to raycast for walls"
NEW3 = """    wall_probe = 2.2,         -- yd ahead to raycast for walls
    body_radius = 0.45,       -- yd: half the character's width; probes sweep this, because a single centre ray threads trunks and posts"""
assert OLD3 in s
s = s.replace(OLD3, NEW3, 1)
s = s.replace("local CFG_VERSION = 8", "local CFG_VERSION = 9", 1)
p.write_text(s, encoding="utf-8")
print("Navigator: obstacle probes sweep the body's width (3 rays)")
