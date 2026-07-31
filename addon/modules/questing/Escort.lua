-- Escort - following and protecting a quest NPC, the way a person does it.
--
-- Robotic following is instantly recognisable and it is also bad play: glued to
-- the NPC's back, re-pathing every frame, standing still while it gets chewed on.
-- A human escorting an NPC keeps a loose station slightly off to one side and
-- behind, lets small gaps open and close instead of correcting constantly, breaks
-- off to kill whatever attacks, and only sprints when it has genuinely fallen
-- behind.
--
-- That is what this models: a FOLLOW BAND rather than a follow point, a lateral
-- offset that drifts slowly, threat interception, and a stop-and-wait when the
-- NPC halts (escort NPCs frequently pause to talk).

local Escort = {}

local sqrt, random, cos, sin, pi = math.sqrt, math.random, math.cos, math.sin, math.pi
-- WoW's Lua 5.1 has math.atan2; 5.3+ folded it into two-argument math.atan and
-- dropped atan2 entirely. Bind once so this works in-game AND in the harness.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Station-keeping band. Inside NEAR we are close enough and should stop pushing;
-- past FAR we have fallen behind and should actually move.
Escort.NEAR      = 6.0
Escort.FAR       = 11.0
Escort.SPRINT    = 22.0     -- yd: badly behind, take the direct line
Escort.LOST      = 90.0     -- yd: we have lost it entirely
Escort.SIDE_MAX  = 4.0      -- yd of lateral offset (never dead-astern)
Escort.DRIFT     = 0.10     -- how fast the offset wanders (0..1 per update)

Escort._state = nil

local function now() return (GetTime and GetTime()) or 0 end
local function ppos()
    if RaijinLab and RaijinLab.ObjectPosition then return RaijinLab:ObjectPosition("player") end
end
local function opos(guid)
    if RaijinLab and RaijinLab.ObjectPosition and guid then return RaijinLab:ObjectPosition(guid) end
end

-- Find the NPC we are escorting: a friendly, living, quest-tied unit nearby.
-- Prefer one that is actually moving (escort NPCs walk their route), because a
-- stationary quest giver of the same name would otherwise win.
function Escort.find_npc(opts)
    opts = opts or {}
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om then return nil end
    local px, py, pz = ppos()
    if not px then return nil end
    local best, bestd = nil, math.huge
    for i = 1, #(om.npcs or {}) do
        local s = om.npcs[i]
        local u = s and s.Info and s.Info.Unit
        local q = s and s.Info and s.Info.Quest
        if s and s.Guid and not (u and u.Dead) then
            local tied = q and q.IsTiedToQuest
            local named = opts.name and s.Name == opts.name
            if tied or named then
                -- friendly only: an escort target is never attackable
                local friendly = true
                if UnitCanAttack and s.Guid then
                    local ok, can = pcall(UnitCanAttack, "player", s.Guid)
                    if ok and can then friendly = false end
                end
                if friendly then
                    local x, y = opos(s.Guid)
                    if x then
                        local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
                        if d < bestd and d <= (opts.max_dist or Escort.LOST) then
                            best, bestd = s, d
                        end
                    end
                end
            end
        end
    end
    if best then return { guid = best.Guid, name = best.Name, dist = bestd, struct = best } end
    return nil
end

-- Anything currently attacking the escortee (or us). Killing these IS the quest.
function Escort.threat_to(guid)
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om then return nil end
    local px, py = ppos()
    if not px then return nil end
    local best, bestd = nil, math.huge
    for i = 1, #(om.npcs or {}) do
        local s = om.npcs[i]
        local u = s and s.Info and s.Info.Unit
        if s and s.Guid and not (u and u.Dead) then
            local hostile = false
            if UnitCanAttack then
                local ok, can = pcall(UnitCanAttack, "player", s.Guid)
                hostile = ok and can and true or false
            end
            if hostile and u and u.InCombat then
                local x, y = opos(s.Guid)
                if x then
                    local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
                    if d < bestd then best, bestd = s, d end
                end
            end
        end
    end
    if best then return { guid = best.Guid, name = best.Name, dist = bestd } end
    return nil
end

-- The point we should actually stand at: behind and to one side of the NPC,
-- with the side offset drifting slowly so the station looks lived-in rather than
-- mathematically pinned.
function Escort.station(nx, ny, heading, t)
    local st = Escort._state or {}
    if not st.side then st.side = (random() * 2 - 1) * Escort.SIDE_MAX end
    -- slow random walk on the lateral offset, clamped
    st.side = st.side + (random() * 2 - 1) * Escort.SIDE_MAX * Escort.DRIFT
    if st.side > Escort.SIDE_MAX then st.side = Escort.SIDE_MAX end
    if st.side < -Escort.SIDE_MAX then st.side = -Escort.SIDE_MAX end
    Escort._state = st
    local back = (Escort.NEAR + Escort.FAR) * 0.5 * 0.6
    local h = heading or 0
    -- behind along the NPC's heading, plus a perpendicular offset
    local bx = nx - cos(h) * back
    local by = ny - sin(h) * back
    local px = bx + cos(h + pi / 2) * st.side
    local py = by + sin(h + pi / 2) * st.side
    return px, py
end

-- One escort step. Returns a status string.
-- `goto_fn(x, y, z, arrive)` is supplied by the caller (the Suite owns movement),
-- and `engage_fn(guid)` starts a fight. Keeping those injected means this module
-- stays testable and never fights the Suite for control of Nav.
function Escort.step(ctx)
    ctx = ctx or {}
    local goto_fn, engage_fn = ctx.goto_fn, ctx.engage_fn
    local npc = ctx.npc or Escort.find_npc({ name = ctx.name })
    if not npc then return "escort:npc lost", nil end

    local px, py, pz = ppos()
    local nx, ny, nz = opos(npc.guid)
    if not (px and nx) then return "escort:nopos", npc end
    local d = sqrt((nx - px) ^ 2 + (ny - py) ^ 2)

    -- 1) DEFEND. Whatever is attacking is the actual objective; a human turns and
    -- fights rather than continuing to trail the NPC.
    local threat = Escort.threat_to(npc.guid)
    if threat and threat.dist <= (ctx.engage_dist or 30) then
        if engage_fn then engage_fn(threat.guid) end
        return "escort:defending (" .. tostring(threat.name or "?") .. ")", npc
    end

    -- 2) Badly behind: take the direct line and close hard.
    if d > Escort.SPRINT then
        if goto_fn then goto_fn(nx, ny, nz, Escort.NEAR) end
        return "escort:catching up", npc
    end

    -- 3) Comfortably in the band: hold station and do NOT re-path. This is the
    -- difference between natural following and jittering - a person lets the gap
    -- breathe instead of correcting every frame.
    if d <= Escort.FAR then
        if d < Escort.NEAR * 0.6 and goto_fn then
            -- too close (the NPC stopped): stop pushing into its back
            return "escort:holding", npc
        end
        return "escort:in station", npc
    end

    -- 4) Drifting out of the band: walk to a station point behind/beside it.
    local heading = 0
    local st = Escort._state or {}
    if st.lx and (st.lx ~= nx or st.ly ~= ny) then
        heading = atan2(ny - st.ly, nx - st.lx)
    end
    st.lx, st.ly = nx, ny
    Escort._state = st
    local sx, sy = Escort.station(nx, ny, heading, now())
    if goto_fn then goto_fn(sx, sy, nz, Escort.NEAR * 0.8) end
    return "escort:following", npc
end

function Escort.reset() Escort._state = nil end

if RaijinLab then RaijinLab.Escort = Escort end
return Escort
