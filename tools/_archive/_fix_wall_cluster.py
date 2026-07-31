"""The wall-collision cluster. Five defects that together mean the character
sees a wall and runs into it anyway. Two of them I introduced last turn.
"""
from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

# ---- 1. MY BUG: the second probe resets the shared throttle every tick -----
OLD1 = """        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        if dh > 0.25 then
            -- Only worth a second cast when the two genuinely differ; probe_hz
            -- throttles the pair together so this does not double the raycasts
            -- in the common aimed-and-running case.
            a.probe_t = nil
            terrain_probe(a, px, py, pz, target_h)
        end"""
NEW1 = """        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        if dh > 0.25 then
            -- SEPARATE THROTTLES. `a.probe_t = nil` here reset the SHARED
            -- timestamp every tick, so the next tick's travel-direction probe
            -- always passed its throttle and the target-direction probe always
            -- consumed the slot - starving the very sensor this change existed
            -- to add. The probe ended up looking along the desired heading
            -- again, which is the exact bug it was meant to fix.
            local saved = a.probe_t
            a.probe_t = a.probe_t2
            terrain_probe(a, px, py, pz, target_h)
            a.probe_t2 = a.probe_t
            a.probe_t = saved
        end"""
assert OLD1 in s, "second-probe block not found"
s = s.replace(OLD1, NEW1, 1)

# ---- 2. a confirmed wall must STOP forward, not just bend -----------------
# ---- 3. and must steer away from the ray that actually hit ----------------
OLD2 = """    if chest_hit and hx then
        do
            -- real wall: never jump into it; steer around
            if (a.detour or 0) == 0 then
                a.detour = (a.recover_n % 2 == 0) and 0.7 or -0.7
            end"""
NEW2 = """    if chest_hit and hx then
        do
            -- real wall: never jump into it; steer around
            --
            -- TWO FIXES HERE.
            --
            -- (a) The side was chosen from recover_n parity, which is 0 during
            -- normal running - so it ALWAYS bent the same way (+0.7) regardless
            -- of where the wall actually was, and the 3-ray sweep's knowledge of
            -- WHICH shoulder hit was thrown away. Half the time that steers
            -- straight into the wall it just detected. Now: hit on the left
            -- shoulder means go right, and vice versa.
            --
            -- (b) A wall closer than about half the probe reach used to leave
            -- a.block false, so set_forward kept commanding FULL SPEED FORWARD
            -- into geometry the sensor had positively identified. Bending 0.7rad
            -- while running at a wall 1yd away just grinds along it. Close wall
            -- now blocks forward so the turn happens in place.
            local side = chest_off or 0
            local want
            if side > 0 then want = -0.9          -- hit on the left -> go right
            elseif side < 0 then want = 0.9       -- hit on the right -> go left
            else
                -- centre hit: no side information, so keep the alternating
                -- behaviour rather than guessing a direction
                want = (a.recover_n % 2 == 0) and 0.9 or -0.9
            end
            if (a.detour or 0) == 0 then a.detour = want end
            local dx0, dy0 = hx - px, (hy or py) - py
            local hitd = math.sqrt(dx0 * dx0 + dy0 * dy0)
            if hitd < (reach * 0.55) then
                a.block = true                   -- too close to run: turn in place
            end"""
assert OLD2 in s, "chest-hit block not found"
s = s.replace(OLD2, NEW2, 1)

# record which ray hit
OLD3 = """    local chest_hit, hx, hy
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
    end"""
NEW3 = """    local chest_hit, hx, hy, chest_off
    for _, o in ipairs({ 0, half, -half }) do
        local sx, sy = px + nx * o, py + ny * o
        local tx, ty = ex + nx * o, ey + ny * o
        local hit, ihx, ihy = RaijinLab:TraceLine(sx, sy, zc, tx, ty, zc, 0x100111)
        if hit and ihx then
            -- measure from the ray's own origin, not the body centre, or an
            -- offset ray reports a distance it did not travel
            local ddx, ddy = ihx - sx, ihy - sy
            if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                -- keep WHICH ray hit: it is the only clue about which way to
                -- go, and the old code measured it and then discarded it
                chest_hit, hx, hy, chest_off = hit, ihx, ihy, o
                break
            end
        end
    end"""
assert OLD3 in s, "chest sweep not found"
s = s.replace(OLD3, NEW3, 1)

# ---- 4. progress must not erase the SENSOR's detour ------------------------
OLD4 = """            reset_progress(a); a.detour = 0; a.recover_n = 0   -- progress: clear detour"""
NEW4 = """            -- PROGRESS CLEARS RECOVERY, NOT PERCEPTION.
            --
            -- a.detour is the ONLY channel by which the wall/cliff sensor
            -- influences the heading, and this zeroed it on every 0.8yd of
            -- movement. Running along a building means making progress every
            -- tick, so the sensor's steering output was erased as fast as it was
            -- produced - the bot "saw" the wall continuously and never acted on
            -- it. Recovery state (the escalating side-alternating angle) SHOULD
            -- clear on progress; a live sensor reading should not.
            reset_progress(a); a.recover_n = 0
            if not a.sensor_detour then a.detour = 0 end"""
assert OLD4 in s, "progress-clear not found"
s = s.replace(OLD4, NEW4, 1)

# mark the detour as sensor-owned when terrain_probe sets it, and clear it when clear
s = s.replace("            if (a.detour or 0) == 0 then a.detour = want end",
              "            if (a.detour or 0) == 0 then a.detour = want end\n"
              "            a.sensor_detour = true    -- owned by perception until the way is clear",
              1)
s = s.replace("    a.probe_t = t\n    a.block = false",
              "    a.probe_t = t\n    a.block = false\n"
              "    -- a fresh probe owns the verdict: last tick's wall is not evidence\n"
              "    a.sensor_detour = false", 1)
p.write_text(s, encoding="utf-8")
print("Navigator: throttle, detour side, block-on-close, detour lifetime")

# ---- 5. MY BUG: _report_probe calls status_sets() before it exists --------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
t = q.read_text(encoding="utf-8")
if "local status_sets" not in t.split("local function status_sets")[0]:
    t = t.replace("local QuestOM = {}",
                  "local QuestOM = {}\n\n"
                  "-- Forward declaration: _report_probe (defined above status_sets) calls this.\n"
                  "-- Without it the call resolved to a nil GLOBAL and threw, the error was\n"
                  "-- swallowed by the enclosing pcall, and BOTH the giver diagnostic and the\n"
                  "-- probe that feeds status_source_alive died silently.\n"
                  "local status_sets", 1)
    t = t.replace("local function status_sets()", "function status_sets()", 1)
    q.write_text(t, encoding="utf-8")
    print("QuestOM: status_sets forward-declared (diagnostic was throwing)")
else:
    print("QuestOM: already forward-declared")
