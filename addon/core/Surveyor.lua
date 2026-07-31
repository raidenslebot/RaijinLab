-- Ambient environment perception - the eyes.
--
-- Continuously raycasts a fan around the character (floor + wall probes) and writes
-- what it finds into the WorldMesh: walkable floor, cliffs/gaps, and WALLS. So the
-- pathfinder knows the terrain out to ~150yd and routes AROUND obstacles before the
-- character ever reaches them - it should never walk into a wall, and "recovery"
-- should almost never be needed. Runs a few raycasts per frame on its own ticker,
-- amortized so it costs a sliver of the frame budget; cells already mapped this
-- session are skipped (zero re-survey waste).

local Surveyor = {}

-- ring distances (yd) and the angular half-width scanned at each. Near rings sweep
-- the full circle (know your immediate surroundings); far rings focus forward.
Surveyor._rings = {
    { d = 5,   half = math.pi,        step = 0.52 },   -- 12 dirs, full circle
    { d = 10,  half = math.pi,        step = 0.52 },
    { d = 18,  half = 2.4,            step = 0.44 },
    { d = 30,  half = 2.0,            step = 0.40 },
    { d = 48,  half = 1.6,            step = 0.36 },
    { d = 72,  half = 1.2,            step = 0.34 },
    { d = 105, half = 0.9,            step = 0.32 },
    { d = 150, half = 0.7,            step = 0.30 },
}
-- More probes when budget allows: quality up, cost still scheduler-capped.
Surveyor._per_frame = 12
Surveyor._eye = 1.4              -- chest height for the wall (LoS) ray
Surveyor._wall_range = 45        -- only trust a LoS block as a WALL within this range
Surveyor._running = false

local floor = math.floor
local TWO_PI = math.pi * 2
-- Lua 5.1 (in-game) has math.atan2; 5.3+ dropped it for two-arg math.atan.
local atan2 = math.atan2 or math.atan
local function now() return (GetTime and GetTime()) or 0 end
-- shortest signed angular difference a-b, wrapped to (-pi, pi]
local function angdiff(a, b)
    local d = (a - b) % TWO_PI
    if d > math.pi then d = d - TWO_PI end
    return d
end
Surveyor._angdiff = angdiff   -- exposed for tests

-- Build the flat list of (angle,dist) probes for the current facing, once, and cycle
-- through it a few per frame. Re-centered on the facing each time we wrap around.
local function build_fan(facing)
    local fan = {}
    for _, r in ipairs(Surveyor._rings) do
        local a = -r.half
        while a <= r.half + 1e-6 do
            fan[#fan + 1] = { ang = facing + a, d = r.d }
            a = a + r.step
        end
    end
    return fan
end

local function heading()
    local Nv = RaijinLab and RaijinLab.Navigator
    if Nv and Nv._cam_now then return Nv._cam_now end
    local c = RaijinLab and RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    if c and c.fx and (c.fx * c.fx + c.fy * c.fy) > 1e-6 then return atan2(c.fy, c.fx) end
    return 0
end

-- Probe one (angle,dist) from the player: does floor exist there, is there a wall in
-- the way, is it a drop? Writes the result into the mesh.
local function probe(px, py, pz, ang, dist)
    local RL = RaijinLab
    local WM = RL and RL.WorldMesh
    if not WM then return end
    local sx = px + math.cos(ang) * dist
    local sy = py + math.sin(ang) * dist
    -- Fast pre-skip: standing on flat ground the sample cell sits at ~pz, so if it's
    -- already mapped this session we can skip ALL rays. (Definitive skip is below,
    -- keyed off the real ground z - this one just saves the ground ray in the common
    -- flat case without risking a miss on sloped terrain.)
    if WM.conf_fresh and WM.conf_fresh(sx, sy, pz) then return end
    -- floor under the sample? search a wide vertical band for stacked geometry.
    local gz = RL.TraceGround and RL:TraceGround(sx, sy, pz + 3, 10, 45) or nil
    if not gz then
        WM.mark_cliff(sx, sy, pz)                       -- gap / ledge / no floor
        return
    end
    -- Definitive skip: now that we know the exact ground cell, bail if IT is already
    -- mapped this session. This keys off the SAME cell mark_seen writes below, so it
    -- never re-surveys a mapped cell and never skips an unmapped one.
    if WM.conf_fresh and WM.conf_fresh(sx, sy, gz) then return end
    -- WALL between us and the sample (chest-height ray)? If so, don't claim the far
    -- side is walkable.
    if RL.TraceLine then
        local blocked, hx, hy, hz = RL:TraceLine(px, py, pz + Surveyor._eye,
            sx, sy, gz + Surveyor._eye, 0x100111)
        if blocked then
            -- Only record a WALL when the hit is (a) near enough to trust and (b)
            -- clearly BEFORE the sample. A hit right at the sample is just that spot's
            -- own upslope terrain (its floor was already found above), not a wall in
            -- the corridor - marking it blocked would wrongly wall off a walkable hill.
            if hx then
                local dhit = math.sqrt((hx - px) ^ 2 + (hy - py) ^ 2)
                if dhit <= Surveyor._wall_range and dhit < dist - 4 then
                    WM.mark_seen(hx, hy, hz, false)
                end
            end
            return
        end
    end
    WM.mark_seen(sx, sy, gz, true)                      -- clear + floor => walkable
    -- Measure how steep this ground actually is while its neighbourhood is fresh.
    -- Doing it here means the planner already knows which face of a hill is
    -- runnable before the character ever commits to a route up it.
    if WM.compute_slope then
        pcall(WM.compute_slope, WM.cell_id(sx, sy, gz))
    end
end
Surveyor._probe = probe   -- exposed for tests

function Surveyor.start()
    if Surveyor._running or not CreateFrame then return end
    Surveyor._running = true
    local f = CreateFrame("Frame")
    Surveyor._frame = f
    local acc = 0
    f:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc < 0.2 then return end                   -- ~5 Hz (was 20 Hz - FPS killer with TraceLine fan)
        acc = 0
        pcall(Surveyor.tick)
    end)
end

function Surveyor.stop()
    if Surveyor._frame then Surveyor._frame:SetScript("OnUpdate", nil); Surveyor._frame = nil end
    Surveyor._running = false
end

-- One survey tick: a handful of probes, cycling the fan. Only while in world with a
-- valid position, and honoring the frame budget (defers when the scheduler is tight).
-- True only when ambient raycasts are worth the FPS cost.
function Surveyor.needed()
    local RL = RaijinLab
    if not RL then return false end
    local Nv = RL.Navigator
    if Nv and (Nv._active or Nv.state == "moving" or Nv._moving) then return true end
    local M = RL.Master
    if M and M.suppressed and M.suppressed() then return false end
    local d = RaijinLabDB and RaijinLabDB.modules
    -- Travel modules need terrain; rotation-only does not.
    if d and (d.quest or d.grind or d.gather) then return true end
    return false
end

function Surveyor.tick()
    local RL = RaijinLab
    if not (RL and RL.ObjectPosition and RL.WorldMesh and RL.TraceGround) then return end
    -- IDLE GATE: TraceLine fan is a top FPS cost. Master OFF, rotation-only, or
    -- pure standing idle => zero rays.
    if not Surveyor.needed() then return end
    local S = RL.Scheduler
    if S and S.over_budget and S.over_budget() then return end   -- give the frame back
    local px, py, pz = RL:ObjectPosition("player")
    if not (px and py and pz) then return end

    -- WATER. The client tells us plainly when we are swimming, and that is the
    -- only fully reliable water signal on 3.3.5 (a raycast cannot distinguish a
    -- lake surface from ground). So we mark water from EXPERIENCE: wherever we
    -- actually swim becomes a water hazard, which the cost model already
    -- penalises heavily - swimming is slow and you cannot fight from it.
    if IsSwimming and IsSwimming() and RL.WorldMesh then
        pcall(RL.WorldMesh.mark_water, px, py, pz)
    end

    -- Sample the living world into the traversability field: hostiles become
    -- danger, other players trace out the road network, our own travel counts
    -- weakly. Once a second is plenty - these are regional facts.
    local TV = RL.Traversability
    if TV then
        local tnow = (GetTime and GetTime()) or 0
        if (tnow - (Surveyor._tv_t or 0)) >= 1.0 then
            Surveyor._tv_t = tnow
            pcall(TV.observe_world)
            if RL.Navigator and RL.Navigator._moving then
                pcall(TV.note_self_travel, px, py)
            end
        end
    end

    -- (re)build the fan when we've consumed it or moved/turned enough to re-center
    local h = heading()
    if not Surveyor._fan or Surveyor._cursor > #Surveyor._fan
        or math.abs(angdiff(Surveyor._fh or 0, h)) > 0.4
        or (Surveyor._fx and ((px - Surveyor._fx) ^ 2 + (py - Surveyor._fy) ^ 2) > 100) then
        Surveyor._fan = build_fan(h)
        Surveyor._cursor = 1
        Surveyor._fh, Surveyor._fx, Surveyor._fy = h, px, py
    end
    local fan = Surveyor._fan
    local n = 0
    while n < Surveyor._per_frame and Surveyor._cursor <= #fan do
        local p = fan[Surveyor._cursor]
        Surveyor._cursor = Surveyor._cursor + 1
        pcall(probe, px, py, pz, p.ang, p.d)
        n = n + 1
    end
    Surveyor._surveyed = (Surveyor._surveyed or 0) + n
end

function Surveyor.stats()
    return { running = Surveyor._running, surveyed = Surveyor._surveyed or 0,
             fan = Surveyor._fan and #Surveyor._fan or 0, cursor = Surveyor._cursor or 0 }
end

if RaijinLab then RaijinLab.Surveyor = Surveyor end
return Surveyor
