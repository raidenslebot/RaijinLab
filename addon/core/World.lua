-- World query helpers for conditions / combat / gather.
--
-- RANGE AUTHORITY (hard rule):
--   yards = ObjectPosition(GUID) 2D center, then edge = center - pCombat - tCombat.
--   Nameplates / unit tokens are DISCOVERY only (UnitCanAttack, health, names).
--   CheckInteractDistance is NEVER treated as a yard measurement.

local World = {}

-- Recent SPELL_MISSED / absorbed evidence keyed by target GUID then school/spell
World._miss_by_guid = {}
World._cleu_armed = false

local function dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = (ax or 0) - (bx or 0), (ay or 0) - (by or 0), (az or 0) - (bz or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function dist2(ax, ay, bx, by)
    local dx, dy = (ax or 0) - (bx or 0), (ay or 0) - (by or 0)
    return math.sqrt(dx * dx + dy * dy)
end

function World.player_pos()
    if not RaijinLab or not RaijinLab.ObjectPosition then return nil end
    local x, y, z = RaijinLab:ObjectPosition("player")
    if not x then return nil end
    return { x = x, y = y, z = z }
end

function World.unit_guid(unit)
    if UnitGUID then return UnitGUID(unit) end
    return nil
end

-- Enumerate unit tokens stock API can see. Tokens are for Unit* state only;
-- distance always goes through GUID ObjectPosition (see unit_distances).
function World.iter_unit_tokens()
    -- Stable tokens only. nameplateN is forbidden for discovery on Ascension
    -- (exists only under cursor). Runtime NearbyHostiles is the pack authority.
    local tokens = { "target", "focus", "pet", "mouseover" }
    for i = 1, 4 do tokens[#tokens + 1] = "party" .. i end
    for i = 1, 5 do tokens[#tokens + 1] = "boss" .. i end
    return tokens
end

-- Sanitize combat reach / bounding (Trinity default 1.5 when field is 0).
local function sanitize_reach(v, default, cap)
    v = tonumber(v)
    if not v or v ~= v or v < 0 then return default end
    if cap and v > cap then return default end
    return v
end

local function combat_reach_of(ref)
    if not ref or not (RaijinLab and RaijinLab.ObjectCombatReach) then
        return 1.5
    end
    local ok, v = pcall(RaijinLab.ObjectCombatReach, RaijinLab, ref)
    if not ok then return 1.5 end
    return sanitize_reach(v, 1.5, 100)
end

local function bounding_of(ref)
    if not ref or not (RaijinLab and RaijinLab.ObjectBoundingRadius) then
        return 0
    end
    local ok, v = pcall(RaijinLab.ObjectBoundingRadius, RaijinLab, ref)
    if not ok then return 0 end
    return sanitize_reach(v, 0, 80) or 0
end

-- World position for a unit. GUID first (OM ObjectPtr path). Token is only a
-- fallback when GUID is missing or the GUID read failed.
local function unit_world_pos(guid, token)
    if not (RaijinLab and RaijinLab.ObjectPosition) then return nil end
    if guid then
        local ok, x, y, z = pcall(RaijinLab.ObjectPosition, RaijinLab, guid)
        if ok and x then return x, y, z end
    end
    if token then
        local ok, x, y, z = pcall(RaijinLab.ObjectPosition, RaijinLab, token)
        if ok and x then return x, y, z end
    end
    return nil
end

-- True distances relative to the player (2D).
-- center = pivot-to-pivot
-- edge   = center - pCombat - tCombat  (melee / unit-targeted)
-- aoe    = center (or center - giantBound) for self-AoE
-- precise = true ONLY when both ObjectPositions succeeded.
--
-- NEVER invents yards from CheckInteractDistance buckets.
local AOE_BOSS_BOUND = 2.0
local function unit_distances(guid, token)
    local px, py, pz
    if RaijinLab and RaijinLab.ObjectPosition then
        px, py, pz = RaijinLab:ObjectPosition("player")
    end
    local tx, ty, tz = unit_world_pos(guid, token)
    if not px or not tx then
        -- No real position => no yards. Callers must fail closed.
        return nil, nil, nil, nil, nil, nil, nil, nil, false, nil, nil, nil
    end
    local center = dist2(px, py, tx, ty)
    -- Collapsed-to-player (same coords): refuse as precise rather than lie.
    if center < 0.05 and guid and UnitGUID and UnitGUID("player")
        and tostring(guid) ~= tostring(UnitGUID("player")) then
        return nil, nil, nil, nil, nil, nil, nil, nil, false, nil, nil, nil
    end
    local pr = combat_reach_of("player")
    -- Prefer GUID reach; token only if GUID unknown.
    local tr = combat_reach_of(guid or token)
    local tb = bounding_of(guid or token)
    local edge = center - pr - tr
    if edge < 0 then edge = 0 end
    local extend = (tb > AOE_BOSS_BOUND) and tb or 0
    local aoe = center - extend
    if aoe < 0 then aoe = 0 end
    return center, edge, aoe, tx, ty, tz, pr, tr, true, nil, nil, tb
end

-- GUID -> unit token map for Unit* queries (attackable, dead, health).
-- Nameplates are discovery only; they do not supply yards.
-- On Ascension, nameplateN often does NOT exist unless the unit is under the
-- cursor — so this map may only contain target/focus/mouseover. Combat scans
-- MUST fall back to OM GUID + ObjectUnitFlags (see om_unit_is_hostile).
function World.guid_token_map()
    local map = {}
    if not UnitExists then return map end
    for _, token in ipairs(World.iter_unit_tokens()) do
        if UnitExists(token) then
            local guid = UnitGUID and UnitGUID(token)
            if guid and not map[guid] then
                map[guid] = token
            end
        end
    end
    return map
end

-- ============================================================================
-- RUNTIME-FIRST hostiles (no nameplates, no UnitCanAttack spam).
--
-- Authority: RaijinLabRuntime NearbyHostiles — one C++ Refresh + snapshot walk,
-- returns packed hostiles with positions/flags/hp already computed.
-- Lua NEVER loops GetUnitWithIndex + ObjectHealth/Flags (that crashed + lagged).
-- ============================================================================
local UF_NON_ATTACKABLE = 0x00000002
local UF_NOT_ATTACKABLE_1 = 0x00000080
local UF_IMMUNE_TO_PC = 0x00000100
local UF_NOT_SELECTABLE = 0x02000000

-- Diagnostic / rare single-guid path only. Hot path uses NearbyHostiles cache.
function World.om_unit_is_hostile(guid)
    if not guid or not RaijinLab or not RaijinLab.RuntimeCall then return false end
    local cache = World._hostiles_cache
    if cache and cache.by_guid and cache.by_guid[tostring(guid)] then
        return true
    end
    local flags = tonumber(RaijinLab:RuntimeCall("ObjectUnitFlags", guid)) or 0
    if flags ~= 0 and bit and bit.band then
        if bit.band(flags, UF_NON_ATTACKABLE) ~= 0 then return false end
        if bit.band(flags, UF_NOT_ATTACKABLE_1) ~= 0 then return false end
        if bit.band(flags, UF_IMMUNE_TO_PC) ~= 0 then return false end
        if bit.band(flags, UF_NOT_SELECTABLE) ~= 0 then return false end
    end
    local hp = tonumber(RaijinLab:RuntimeCall("ObjectHealth", guid))
    local mhp = tonumber(RaijinLab:RuntimeCall("ObjectMaxHealth", guid))
    if mhp ~= nil and mhp > 0 and hp ~= nil and hp <= 0 then return false end
    return true
end

-- Parse: n|0xGUID:entry:x:y:z:center:edge:flags:hp:mhp[:face]|...
local function parse_nearby_hostiles(packed)
    local out = {}
    if type(packed) ~= "string" or packed == "" or packed == "0" then return out end
    local first = true
    for part in string.gmatch(packed, "[^|]+") do
        if first then
            first = false
        else
            local guid, entry, x, y, z, center, edge, flags, hp, mhp, face =
                string.match(part,
                    "^(0[xX]%x+):(-?%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):(%d+):(-?%d+):(-?%d+):?(%d*)$")
            if not guid then
                guid, entry, x, y, z, center, edge, flags, hp, mhp, face =
                    string.match(part,
                        "^(%x+):(-?%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):(%d+):(-?%d+):(-?%d+):?(%d*)$")
                if guid then guid = "0x" .. guid end
            end
            if guid then
                center = tonumber(center) or 999
                edge = tonumber(edge) or center
                local aoe = center
                local face_n = tonumber(face)
                local facing = true
                if face_n ~= nil then facing = face_n ~= 0 end
                out[#out + 1] = {
                    guid = guid,
                    entry = tonumber(entry) or 0,
                    x = tonumber(x) or 0,
                    y = tonumber(y) or 0,
                    z = tonumber(z) or 0,
                    dist = aoe,
                    dist_aoe = aoe,
                    dist_center = center,
                    dist_edge = edge,
                    t_reach = 1.5,
                    p_reach = 1.5,
                    precise = true,
                    source = "rt_hostiles",
                    unit_flags = tonumber(flags) or 0,
                    health = tonumber(hp) or 0,
                    max_health = tonumber(mhp) or 0,
                    facing = facing,
                    token = nil,
                }
            end
        end
    end
    return out
end

-- WotLK 3.3.5 / Trinity Spell::CheckCast unit-target face rule:
--   caster->HasInArc(M_PI, target)  where M_PI is FULL cone width (180°).
-- Our API takes the HALF-angle: π/2 (90°) so |heading_error| <= 90°
--   => front HEMISPHERE (180° total), matching the client "not in front of you".
-- This is NOT "only a 90° slice" — that would be wrong and too tight.
--
-- Applies ONLY to unit-targeted player casts that the client face-checks.
-- Ground self-AoE / self / no-unit-target spells never call this path.
World.CAST_FACE_HALF_ARC = math.pi / 2   -- half-angle radians
World.CAST_FACE_FULL_ARC = math.pi       -- full cone (documentation / Trinity M_PI)

local function _live_player_facing()
    -- Prefer runtime live facing (player+0x7AC). ObjectFacing@0x7A4 is stale
    -- on this client and FaceDirection writes only the stale field.
    local A = RaijinLab and RaijinLab.Actions
    if A and A.PlayerFacing then
        local ok, f = pcall(A.PlayerFacing)
        if ok and type(f) == "number" and f == f and f > -0.01 and f < 6.30 then
            return f
        end
    end
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        local ok, f = pcall(RaijinLab.RuntimeCall, RaijinLab, "PlayerFacing")
        if ok and type(f) == "number" and f == f and f > -0.01 and f < 6.30 then
            return f
        end
    end
    if GetPlayerFacing then
        local f = GetPlayerFacing()
        if type(f) == "number" then return f end
    end
    if RaijinLab and RaijinLab.ObjectFacing then
        return RaijinLab:ObjectFacing("player")
    end
    return nil
end

-- Heading error (signed rad) from player facing to GUID. nil if unmeasurable.
-- Positive ≈ target is to the left (CCW from facing) — matches TurnByDelta +.
function World.heading_error_to_guid(guid)
    if not guid or not (RaijinLab and RaijinLab.ObjectPosition) then return nil end
    local px, py = RaijinLab:ObjectPosition("player")
    local tx, ty = RaijinLab:ObjectPosition(guid)
    if not px or not tx then return nil end
    local face = _live_player_facing()
    if not face then return nil end
    local ang = math.atan2(ty - py, tx - px)
    local diff = ang - face
    while diff > math.pi do diff = diff - 2 * math.pi end
    while diff < -math.pi do diff = diff + 2 * math.pi end
    return diff
end

-- Absolute yaw (rad) toward GUID, or nil.
function World.heading_to_guid(guid)
    if not guid or not (RaijinLab and RaijinLab.ObjectPosition) then return nil end
    local px, py = RaijinLab:ObjectPosition("player")
    local tx, ty = RaijinLab:ObjectPosition(guid)
    if not px or not tx then return nil end
    return math.atan2(ty - py, tx - px)
end

-- Face toward GUID without changing unit selection.
-- Uses TurnByDelta (real client turn) — raw FaceDirection memory write is
-- ignored for movement/cast on this Ascension build.
function World.face_guid(guid)
    local err = World.heading_error_to_guid(guid)
    if err == nil then return false end
    if math.abs(err) <= 0.12 then return true end -- already close enough
    -- Cap one-shot step to avoid wild spin; recheck next tick if still off.
    local step = err
    if step > 1.4 then step = 1.4 end
    if step < -1.4 then step = -1.4 end
    local A = RaijinLab and RaijinLab.Actions
    if A and A.TurnByDelta then
        local ok = pcall(A.TurnByDelta, step)
        return ok and true or false
    end
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        local ok = pcall(RaijinLab.RuntimeCall, RaijinLab, "TurnByDelta", step)
        return ok and true or false
    end
    -- Last resort: memory write (may not affect cast face on this client).
    local yaw = World.heading_to_guid(guid)
    if yaw and A and A.Face then
        pcall(A.Face, yaw)
        return true
    end
    return false
end

-- Facing check. Returns true / false / nil (nil = undetermined — cannot measure).
-- Multi-dot MUST cast when nil (client is last authority). Only skip when false.
function World.is_facing_guid(guid, half_arc)
    if not guid then return false end
    half_arc = tonumber(half_arc) or World.CAST_FACE_HALF_ARC
    local err = World.heading_error_to_guid(guid)
    if err ~= nil then
        return math.abs(err) <= half_arc
    end
    local c = World._hostiles_cache
    if c and c.by_guid then
        local row = c.by_guid[tostring(guid)]
        if row and row.facing ~= nil and (not c.t or ((GetTime and GetTime()) or 0) - c.t < 0.08) then
            return row.facing and true or false
        end
    end
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        local ok, v = pcall(RaijinLab.RuntimeCall, RaijinLab, "ObjectIsFacing", "player", guid, half_arc)
        if ok and v ~= nil then
            return v == true or v == 1 or v == "true"
        end
    end
    -- Undetermined: not false. Callers that need bool for "can wire" treat nil as allow.
    return nil
end

-- Bool helper: only true when measured facing. false for not-facing OR undetermined.
function World.is_facing_guid_strict(guid, half_arc)
    return World.is_facing_guid(guid, half_arc) == true
end

-- Bool helper for "should we skip cast": only when MEASURED not facing.
function World.is_not_facing_guid(guid, half_arc)
    return World.is_facing_guid(guid, half_arc) == false
end

-- GUID line-of-sight. true = clear, false = blocked, nil = undetermined.
-- Used by BasicRules / live_castable so multi-dot never wires a blocked cast.
function World.is_los_guid(guid)
    if not guid then return nil end
    guid = tostring(guid)
    local tnow = (GetTime and GetTime()) or 0
    local lc = World._los_guid_cache
    if lc and lc.key == guid and (tnow - (lc.t or 0)) < 0.10 then
        return lc.v
    end
    if not (RaijinLab and RaijinLab.ObjectPosition and RaijinLab.TraceLine) then
        return nil
    end
    local px, py, pz = RaijinLab:ObjectPosition("player")
    local tx, ty, tz = RaijinLab:ObjectPosition(guid)
    if not px or not tx then return nil end
    local ok, blocked = pcall(RaijinLab.TraceLine, RaijinLab,
        px, py, (pz or 0) + 2, tx, ty, (tz or 0) + 2, 0x100111)
    if not ok then return nil end
    local clear = (blocked ~= true)
    World._los_guid_cache = { key = guid, t = tnow, v = clear }
    return clear
end

-- True when unit (token or GUID) is actively attacking the local player
-- (targets player, or is casting a harmful spell at player). Used for natural
-- target acquisition only — never for multi-dot GUID casts.
function World.unit_is_attacking_player(token_or_guid)
    if not token_or_guid then return false end
    local token = nil
    local guid = nil
    if type(token_or_guid) == "string" and UnitExists and UnitExists(token_or_guid) then
        token = token_or_guid
        guid = UnitGUID and UnitGUID(token)
    else
        guid = tostring(token_or_guid)
    end
    -- Prefer UnitTarget runtime / stock: unit's target is player.
    if token and UnitIsUnit then
        if UnitIsUnit(token .. "target", "player") then return true end
        -- Some clients expose target via UnitName on "targettarget" only for "target".
        if token == "target" and UnitIsUnit("targettarget", "player") then return true end
    end
    if RaijinLab and RaijinLab.UnitTarget and guid then
        local ok, tg = pcall(RaijinLab.UnitTarget, RaijinLab, guid)
        if ok and tg then
            local pg = UnitGUID and UnitGUID("player")
            if pg and tostring(tg) == tostring(pg) then return true end
        end
    end
    -- Hostiles pack: unit_flags / in combat targeting us is reflected by being
    -- in the pack AND UnitAffectingCombat on a live token.
    if token and UnitAffectingCombat and UnitCanAttack then
        if UnitCanAttack("player", token) and UnitAffectingCombat(token)
            and UnitIsUnit and UnitIsUnit(token .. "target", "player") then
            return true
        end
    end
    return false
end

-- enemies_in_range / WW pack: hitbox-aware AoE gap <= range.
-- precise=false units still count if we have a yard number (runtime pack).
local function dist_within(u, range)
    range = tonumber(range) or 8
    if not u then return false end
    local d = tonumber(u.dist_aoe or u.dist_center or u.dist)
    if d == nil then return false end
    return d <= range
end

-- SINGLE authority for combat hostiles. Runtime NearbyHostiles only.
-- NEVER cache empty packs (that zeroed enemies_in_range for 100ms+ forever
-- when OM was still warming — condition looked permanently broken).
function World.collect_nearby_enemies(max_range)
    max_range = tonumber(max_range) or 40
    local now = (GetTime and GetTime()) or 0
    local c = World._hostiles_cache
    if c and c.list and #c.list > 0 and c.range and c.range >= max_range
        and (now - (c.t or 0)) < 0.08 then
        if c.range == max_range then return c.list end
        local slim = {}
        for i = 1, #c.list do
            local e = c.list[i]
            if (tonumber(e.dist_center) or 999) <= max_range + 1 then
                slim[#slim + 1] = e
            end
        end
        return slim
    end

    local out = {}
    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime()) then
        return out
    end

    local scan = max_range
    if scan < 40 then scan = 40 end
    local okp, packed = pcall(RaijinLab.RuntimeCall, RaijinLab, "NearbyHostiles", scan, 48)
    if okp and type(packed) == "string" then
        out = parse_nearby_hostiles(packed)
    end

    -- Merge living client target if present (optional; not required).
    if UnitExists and UnitExists("target")
        and UnitCanAttack and UnitCanAttack("player", "target")
        and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
        local tg = UnitGUID and UnitGUID("target")
        if tg then
            local found = false
            for i = 1, #out do
                if tostring(out[i].guid) == tostring(tg) then
                    out[i].token = "target"
                    found = true
                    break
                end
            end
            if not found then
                local center, edge, aoe = unit_distances(tg, "target")
                if center and center <= scan + 5 then
                    out[#out + 1] = {
                        guid = tg, token = "target",
                        dist = aoe or center, dist_aoe = aoe or center,
                        dist_center = center, dist_edge = edge or center,
                        precise = true, source = "target_merge",
                    }
                end
            end
        end
    end

    -- Only cache NON-empty results. Empty must re-query next tick.
    if #out > 0 then
        local by = {}
        for i = 1, #out do by[tostring(out[i].guid)] = out[i] end
        World._hostiles_cache = { t = now, range = scan, list = out, by_guid = by }
    else
        World._hostiles_cache = nil
    end

    if max_range >= scan then return out end
    local slim = {}
    for i = 1, #out do
        if (tonumber(out[i].dist_center) or 999) <= max_range + 1 then
            slim[#slim + 1] = out[i]
        end
    end
    return slim
end

-- Token convenience for UI / rare paths. NOT used for pack discovery.
function World.collect_units_from_tokens()
    local out = {}
    local seen = {}
    if not UnitExists then return out end
    -- Only stable tokens — never nameplateN (forbidden / mouseover-only here).
    local tokens = { "target", "focus", "pet", "mouseover" }
    for _, token in ipairs(tokens) do
        if UnitExists(token) then
            local guid = UnitGUID and UnitGUID(token)
            if guid and not seen[guid] then
                seen[guid] = true
                local center, edge, aoe, x, y, z, pr, tr, precise, lo, hi, tb =
                    unit_distances(guid, token)
                local hp = UnitHealth and UnitHealth(token) or 0
                local mhp = UnitHealthMax and UnitHealthMax(token) or 1
                out[#out + 1] = {
                    guid = guid, token = token,
                    name = UnitName and UnitName(token) or "?",
                    x = x or 0, y = y or 0, z = z or 0,
                    dist = aoe or center or 999,
                    dist_center = center or 999,
                    dist_edge = edge or center or 999,
                    dist_aoe = aoe or center or 999,
                    precise = precise and true or false,
                    p_reach = pr, t_reach = tr, t_bound = tb,
                    health = hp, max_health = mhp,
                    health_pct = mhp > 0 and (100 * hp / mhp) or 0,
                    is_player = UnitIsPlayer and UnitIsPlayer(token) or false,
                    is_enemy = UnitCanAttack and UnitCanAttack("player", token) or false,
                    is_friend = UnitIsFriend and UnitIsFriend("player", token) or false,
                    is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(token) or false,
                    source = "token",
                }
            end
        end
    end
    return out
end

function World.collect_from_om()
    local out = {}
    if not RaijinLab or not RaijinLab.RuntimeCall then return out end
    local n = tonumber(RaijinLab:RuntimeCall("GetObjectCount") or 0) or 0
    local px, py, pz = 0, 0, 0
    if RaijinLab.ObjectPosition then
        px, py, pz = RaijinLab:ObjectPosition("player")
    end
    local pr = combat_reach_of("player")
    for i = 1, math.min(n, 256) do
        local guid = RaijinLab:RuntimeCall("GetObjectWithIndex", i)
        if guid then
            local typ = tonumber(RaijinLab:RuntimeCall("ObjectTypeFlags", guid) or 0) or 0
            local x, y, z = RaijinLab:ObjectPosition(guid)
            local entry = tonumber(RaijinLab:RuntimeCall("ObjectId", guid) or 0) or 0
            local center = (x and px) and dist2(px, py, x, y) or dist3(px, py, pz, x, y, z)
            local tr = combat_reach_of(guid)
            local edge = center - pr - tr
            if edge < 0 then edge = 0 end
            out[#out + 1] = {
                guid = guid,
                entry = entry,
                type = typ,
                x = x or 0, y = y or 0, z = z or 0,
                dist = center,
                dist_center = center,
                dist_edge = edge,
                p_reach = pr,
                t_reach = tr,
                precise = (x ~= nil),
                source = "om",
            }
        end
    end
    return out
end

-- ---- Corpses (for conditions that gate corpse-consuming abilities) ---------
-- IMPORTANT: "consumed" is NOT about loot. Looting a corpse does not consume it.
-- A corpse is consumed when used by a corpse-ability (Cannibalize, Raise Dead,
-- Animate Dead, etc.). Tracking is CLEU-based (GUID marked when such a spell
-- successfully fires on/near that body).
--
-- state meanings for the condition:
--   available = dead body present AND not yet marked consumed
--   consumed  = dead body still present AND marked consumed by a corpse ability
--   any       = any dead body / corpse object in range (loot irrelevant)
local CORPSE_TYPEFLAG = 1024 -- RaijinLab.enums.ObjectTypeFlags.Corpse
local UNIT_TYPEFLAG = 32
local UNIT_DYNFLAG_DEAD = 0x0040
World._corpse_consumed = World._corpse_consumed or {} -- [guid] = GetTime()
-- Recent deaths: CLEU-tracked bodies that nameplates drop mid-combat.
-- [guid] = { x, y, z, t }
World._death_corpses = World._death_corpses or {}
-- Last known positions of living units we saw (so death events still get coords).
World._last_unit_pos = World._last_unit_pos or {}

-- Known corpse-consuming abilities (classic/WotLK + common private-server names).
-- IDs are best-effort; name matching is the primary signal.
local CORPSE_CONSUME_IDS = {
    [20577] = true, -- Cannibalize
    [46584] = true, -- Raise Dead (DK)
    [46585] = true, -- Raise Dead variants
    [561289] = true, -- Soul Capture (Ascension Reaper)
}

local function _is_corpse_consume_spell(spellId, spellName)
    spellId = tonumber(spellId) or 0
    if spellId > 0 and CORPSE_CONSUME_IDS[spellId] then return true end
    local n = string.lower(tostring(spellName or ""))
    if n == "" then return false end
    -- Explicit allow-list of name fragments (avoid false positives)
    if n:find("cannibal", 1, true) then return true end
    if n:find("raise dead", 1, true) then return true end
    if n:find("animate dead", 1, true) then return true end
    if n:find("corpse explosion", 1, true) then return true end
    if n:find("raise ally", 1, true) then return true end
    if n:find("army of the dead", 1, true) then return true end
    if n:find("raise abomination", 1, true) then return true end
    if n:find("soul capture", 1, true) then return true end
    if n:find("capture soul", 1, true) then return true end
    if n:find("soulsteal", 1, true) then return true end
    return false
end

function World.mark_corpse_consumed(guid)
    if not guid then return end
    World._corpse_consumed[guid] = (GetTime and GetTime()) or 0
end

function World.is_corpse_consumed(guid)
    if not guid then return false end
    return World._corpse_consumed[guid] ~= nil
end

-- Mark the nearest unconsumed corpse within `range` (Cannibalize is self-cast).
function World.mark_nearest_corpse_consumed(range)
    range = tonumber(range) or 8
    local list = World.collect_corpses(range)
    local best, best_d = nil, 1e9
    for i = 1, #list do
        local c = list[i]
        if c.available and c.dist < best_d then
            best, best_d = c, c.dist
        end
    end
    if best and best.guid then
        World.mark_corpse_consumed(best.guid)
        return best.guid
    end
    return nil
end

local function _player_xyz()
    if RaijinLab and RaijinLab.ObjectPosition then
        local x, y, z = RaijinLab:ObjectPosition("player")
        if x then return x, y, z end
    end
    return 0, 0, 0
end

local function _unit_is_dead_body(token)
    if not token or not UnitExists or not UnitExists(token) then return false end
    if UnitIsGhost and UnitIsGhost(token) then return false end
    if UnitIsDead and UnitIsDead(token) then return true end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(token) then return true end
    local hp = UnitHealth and UnitHealth(token)
    if hp and hp <= 0 then return true end
    return false
end

local function _has_flag(typ, flag)
    typ = tonumber(typ) or 0
    flag = tonumber(flag) or 0
    if flag == 0 then return false end
    if bit and bit.band then return bit.band(typ, flag) > 0 end
    return typ == flag or (flag > 0 and math.floor(typ / flag) % 2 == 1)
end

local function _remember_living_pos(guid, x, y, z)
    if not guid or not x then return end
    World._last_unit_pos[guid] = { x = x, y = y, z = z or 0, t = (GetTime and GetTime()) or 0 }
end

function World.note_unit_died(guid)
    if not guid then return end
    local now = (GetTime and GetTime()) or 0
    local x, y, z
    if RaijinLab and RaijinLab.ObjectPosition then
        x, y, z = RaijinLab:ObjectPosition(guid)
    end
    if not x then
        local last = World._last_unit_pos[guid]
        if last and last.x then x, y, z = last.x, last.y, last.z end
    end
    if not x then
        -- Remember GUID only. Do NOT invent a player-position corpse: the client
        -- will refuse Soul Capture with "no corpses available" if we cast on a
        -- ghost entry the OM/client cannot see. Collect only when OM verifies.
        World._death_corpses[guid] = { x = nil, y = nil, z = nil, t = now, pending = true }
        return
    end
    World._death_corpses[guid] = { x = x, y = y, z = z or 0, t = now, pending = false }
end

-- Client refused a corpse ability: drop this GUID so we never re-spam it.
function World.invalidate_corpse(guid)
    if not guid then return end
    World._death_corpses[guid] = nil
    World._corpse_invalid = World._corpse_invalid or {}
    World._corpse_invalid[guid] = (GetTime and GetTime()) or 0
end

function World.invalidate_nearest_corpse(range)
    range = tonumber(range) or 40
    local c = World.nearest_available_corpse(range)
    if c and c.guid then
        World.invalidate_corpse(c.guid)
        return c.guid
    end
    return nil
end

function World.is_corpse_invalid(guid)
    if not guid then return false end
    local t = World._corpse_invalid and World._corpse_invalid[guid]
    if not t then return false end
    local now = (GetTime and GetTime()) or 0
    if now - t > 45 then
        World._corpse_invalid[guid] = nil
        return false
    end
    return true
end

-- Nearest available (not ability-consumed) corpse within range, or nil.
-- Only returns bodies the client can actually use (verified OM/token position).
function World.nearest_available_corpse(range)
    range = tonumber(range) or 40
    local list = World.collect_corpses(range)
    local best, best_d = nil, 1e9
    -- Prefer token/om_corpse/om_unit over pure CLEU (client-visible first).
    local rank = { token = 0, om_corpse = 1, om_unit = 2, cleu = 3 }
    local best_rank = 99
    for i = 1, #list do
        local c = list[i]
        if c.available and c.verified and c.dist <= range and not c.approx then
            local r = rank[c.source] or 5
            if c.dist < best_d - 0.01 or (math.abs(c.dist - best_d) < 0.01 and r < best_rank) then
                best, best_d, best_rank = c, c.dist, r
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- User interaction busy state. Rotation must NEVER interrupt loot / gossip /
-- quest / trade / AH / crafting / etc. unless a slot opts in via player_state.
-- Returns state key ("looting", "gossip", ...) or "free".
-- ---------------------------------------------------------------------------
local INTERACT_FRAMES = {
    LootFrame = "looting",
    GossipFrame = "gossip",
    QuestFrame = "quest",
    MerchantFrame = "merchant",
    TradeFrame = "trade",
    AuctionFrame = "auction",
    ClassTrainerFrame = "trainer",
    TaxiFrame = "taxi",
    BankFrame = "bank",
    GuildBankFrame = "bank",
    MailFrame = "mail",
    TradeSkillFrame = "crafting",
    CraftFrame = "crafting",
    PetitionFrame = "petition",
    TabardFrame = "tabard",
    PetStableFrame = "stable",
    ItemTextFrame = "item_text",
}

function World.user_interaction_state()
    -- Cheap TTL cache: frame-walk is hot on every rotation tick.
    local t = (GetTime and GetTime()) or 0
    if World._uistate_t and (t - World._uistate_t) < 0.08 and World._uistate then
        return World._uistate
    end
    local st = "free"
    -- Death / ghost: never cast through unless player_state allows "dead".
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        st = "dead"
    elseif UnitOnTaxi and UnitOnTaxi("player") then
        st = "taxi"
    elseif SpellIsTargeting and SpellIsTargeting() then
        st = "spell_targeting"
    elseif CursorHasItem and CursorHasItem() then
        st = "cursor"
    else
        if GetCursorInfo then
            local ok, ctype = pcall(GetCursorInfo)
            if ok and ctype and ctype ~= "" then st = "cursor" end
        end
        if st == "free" and GetNumLootItems then
            local n = GetNumLootItems()
            if type(n) == "number" and n > 0 then st = "looting" end
        end
        if st == "free" then
            for frameName, state in pairs(INTERACT_FRAMES) do
                local f = _G[frameName]
                if f and f.IsShown and f:IsShown() then
                    st = state
                    break
                end
            end
        end
        if st == "free" then
            for i = 1, 4 do
                local f = _G["StaticPopup" .. i]
                if f and f.IsShown and f:IsShown() then
                    st = "popup"
                    break
                end
            end
        end
    end
    World._uistate = st
    World._uistate_t = t
    return st
end

function World.user_interaction_busy()
    local st = World.user_interaction_state()
    if st and st ~= "free" then return true, st end
    return false, "free"
end

-- Scan nearby corpses. Returns list of { guid, dist, available, consumed, source, x,y,z }.
-- available/consumed are about CORPSE-ABILITY use, not loot.
-- Sources: token (dead unit still selectable), om_unit (dead NPC still in OM),
-- om_corpse (Corpse object type), cleu (recent death memory mid-combat).
function World.collect_corpses(max_range)
    max_range = tonumber(max_range) or 40
    local out = {}
    local seen = {}
    local px, py, pz = _player_xyz()
    local now = (GetTime and GetTime()) or 0

    for g, t in pairs(World._corpse_consumed) do
        if type(t) == "number" and now - t > 300 then World._corpse_consumed[g] = nil end
    end
    for g, info in pairs(World._death_corpses) do
        if type(info) == "table" and info.t and now - info.t > 120 then
            World._death_corpses[g] = nil
        end
    end
    for g, info in pairs(World._last_unit_pos) do
        if type(info) == "table" and info.t and now - info.t > 60 then
            World._last_unit_pos[g] = nil
        end
    end
    if World._corpse_invalid then
        for g, t in pairs(World._corpse_invalid) do
            if type(t) == "number" and now - t > 45 then World._corpse_invalid[g] = nil end
        end
    end

    local function push(guid, token, d, source, x, y, z, verified)
        if not guid or seen[guid] then return end
        if World.is_corpse_invalid and World.is_corpse_invalid(guid) then return end
        if d == nil then d = 999 end
        if d > max_range then return end
        -- Never expose unverified bodies to conditions/casts - client will
        -- refuse with "no corpses available" and we look broken.
        if verified == false then return end
        seen[guid] = true
        local consumed = World.is_corpse_consumed(guid)
        out[#out + 1] = {
            guid = guid, token = token, dist = d,
            available = not consumed, consumed = consumed,
            source = source, x = x, y = y, z = z,
            verified = verified ~= false, approx = false,
        }
    end

    -- 1) Unit tokens that are dead (nameplates / target / mouseover / party).
    --    Also remember living unit positions for CLEU death fallback.
    if UnitExists then
        for _, token in ipairs(World.iter_unit_tokens()) do
            if UnitExists(token) then
                local guid = UnitGUID and UnitGUID(token)
                local x, y, z
                if guid and RaijinLab and RaijinLab.ObjectPosition then
                    x, y, z = RaijinLab:ObjectPosition(guid)
                    if not x then x, y, z = RaijinLab:ObjectPosition(token) end
                end
                if guid and x and not _unit_is_dead_body(token) then
                    _remember_living_pos(guid, x, y, z)
                end
                if _unit_is_dead_body(token) and guid then
                    -- Corpse yards: ObjectPosition(GUID) only. No CheckInteract.
                    if x then
                        local d = dist3(px, py, pz, x, y, z)
                        push(guid, token, d, "token", x, y, z, true)
                    end
                end
            end
        end
    end

    -- 2) Object manager: Corpse objects + dead Units (health 0 / DEAD dynflag).
    --    Mid-combat, dead NPCs stay in the OM as Unit type long after nameplates drop.
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.ObjectPosition then
        local corpseFlag = (RaijinLab.enums and RaijinLab.enums.ObjectTypeFlags
            and RaijinLab.enums.ObjectTypeFlags.Corpse) or CORPSE_TYPEFLAG
        local unitFlag = (RaijinLab.enums and RaijinLab.enums.ObjectTypeFlags
            and RaijinLab.enums.ObjectTypeFlags.Unit) or UNIT_TYPEFLAG
        local deadFlag = (RaijinLab.enums and RaijinLab.enums.UnitDynamicFlags
            and RaijinLab.enums.UnitDynamicFlags.UNIT_DYNFLAG_DEAD) or UNIT_DYNFLAG_DEAD

        -- Prefer typed unit enum when available (faster + complete).
        local unit_n = tonumber(RaijinLab:RuntimeCall("GetUnitCount") or 0) or 0
        if unit_n > 0 then
            for i = 1, math.min(unit_n, 256) do
                local guid = RaijinLab:RuntimeCall("GetUnitWithIndex", i)
                if guid and not seen[guid] then
                    local x, y, z = RaijinLab:ObjectPosition(guid)
                    if x then
                        local dead = false
                        if RaijinLab.ObjectDynamicFlags then
                            local ok, flags = pcall(RaijinLab.ObjectDynamicFlags, RaijinLab, guid)
                            flags = tonumber(flags) or 0
                            if ok and _has_flag(flags, deadFlag) then dead = true end
                        end
                        -- CLEU said this GUID died: treat as corpse even if dynflags lag.
                        if not dead and World._death_corpses[guid] then dead = true end
                        if not dead then
                            _remember_living_pos(guid, x, y, z)
                        else
                            -- Refresh death memory with a real OM position.
                            local info = World._death_corpses[guid]
                            if info then info.x, info.y, info.z, info.approx, info.pending = x, y, z or 0, nil, false end
                            push(guid, nil, dist3(px, py, pz, x, y, z), "om_unit", x, y, z, true)
                        end
                    end
                end
            end
        end

        local n = tonumber(RaijinLab:RuntimeCall("GetObjectCount") or 0) or 0
        for i = 1, math.min(n, 256) do
            local guid = RaijinLab:RuntimeCall("GetObjectWithIndex", i)
            if guid and not seen[guid] then
                local typ = tonumber(RaijinLab:RuntimeCall("ObjectTypeFlags", guid) or 0) or 0
                if _has_flag(typ, corpseFlag) then
                    local x, y, z = RaijinLab:ObjectPosition(guid)
                    if x then
                        push(guid, nil, dist3(px, py, pz, x, y, z), "om_corpse", x, y, z, true)
                    end
                elseif _has_flag(typ, unitFlag) then
                    local x, y, z = RaijinLab:ObjectPosition(guid)
                    if x then
                        local dead = false
                        if RaijinLab.ObjectDynamicFlags then
                            local ok, flags = pcall(RaijinLab.ObjectDynamicFlags, RaijinLab, guid)
                            flags = tonumber(flags) or 0
                            if ok and _has_flag(flags, deadFlag) then dead = true end
                        end
                        if not dead and World._death_corpses[guid] then dead = true end
                        if not dead then
                            _remember_living_pos(guid, x, y, z)
                        else
                            local info = World._death_corpses[guid]
                            if info then info.x, info.y, info.z, info.approx, info.pending = x, y, z or 0, nil, false end
                            push(guid, nil, dist3(px, py, pz, x, y, z), "om_unit", x, y, z, true)
                        end
                    end
                end
            end
        end
    end

    -- 3) CLEU death memory: ONLY if the object still resolves in the OM.
    -- Unverified pending deaths stay in memory for later match, never cast.
    for guid, info in pairs(World._death_corpses) do
        if not seen[guid] and type(info) == "table" then
            local x, y, z
            if RaijinLab and RaijinLab.ObjectPosition then
                x, y, z = RaijinLab:ObjectPosition(guid)
            end
            if x then
                info.x, info.y, info.z, info.approx, info.pending = x, y, z or 0, nil, false
                push(guid, nil, dist3(px, py, pz, x, y, z), "cleu", x, y, z, true)
            end
            -- else: keep pending memory, do not push
        end
    end
    return out
end

-- Count corpses within range matching state: "available" | "consumed" | "any"
function World.count_corpses(range, state)
    range = tonumber(range) or 30
    state = string.lower(tostring(state or "available"))
    local list = World.collect_corpses(range)
    local n = 0
    for i = 1, #list do
        local c = list[i]
        if c.dist <= range then
            if state == "any" or state == "both" then
                n = n + 1
            elseif state == "available" or state == "not_consumed" or state == "fresh" then
                if c.available then n = n + 1 end
            elseif state == "consumed" then
                if c.consumed then n = n + 1 end
            end
        end
    end
    return n, list
end

-- Combat log: auras-by-GUID (no nameplates), miss/immune, corpse-consume.
-- [destGuid][spellKey] = { exp=GetTime()+dur, stacks=n, name=... }
World._aura_by_guid = World._aura_by_guid or {}

local function _aura_key(spellId, spellName)
    spellId = tonumber(spellId) or 0
    if spellId > 0 then return "id:" .. tostring(spellId) end
    local n = string.lower(tostring(spellName or ""))
    if n ~= "" then return "nm:" .. n end
    return nil
end

function World.note_aura_on_guid(guid, spellId, spellName, stacks, duration)
    if not guid then return end
    local sid = tonumber(spellId) or 0
    local dur = tonumber(duration) or 21
    if dur < 1 then dur = 15 end
    if dur > 120 then dur = 60 end
    stacks = tonumber(stacks) or 1
    World._aura_search_cache = nil -- next search must see the applied aura
    -- RUNTIME is the authority. Lua cache is diagnostic only.
    if sid > 0 and RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        pcall(RaijinLab.RuntimeCall, RaijinLab, "NoteUnitAura", guid, sid, stacks, dur)
    end
    local key = _aura_key(spellId, spellName)
    if not key then return end
    local now = (GetTime and GetTime()) or 0
    World._aura_by_guid[guid] = World._aura_by_guid[guid] or {}
    World._aura_by_guid[guid][key] = {
        exp = now + dur,
        stacks = stacks,
        name = tostring(spellName or ""),
        sid = sid,
        t = now,
    }
    if sid > 0 and spellName and tostring(spellName) ~= "" then
        local nk = "nm:" .. string.lower(tostring(spellName))
        World._aura_by_guid[guid][nk] = World._aura_by_guid[guid][key]
    end
end

function World.clear_aura_on_guid(guid, spellId, spellName)
    if not guid then return end
    local sid = tonumber(spellId) or 0
    if sid > 0 and RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        pcall(RaijinLab.RuntimeCall, RaijinLab, "ClearUnitAura", guid, sid)
    end
    local bag = World._aura_by_guid[guid]
    if not bag then return end
    local key = _aura_key(spellId, spellName)
    if key then bag[key] = nil end
    if spellName and tostring(spellName) ~= "" then
        bag["nm:" .. string.lower(tostring(spellName))] = nil
    end
    if sid > 0 then bag["id:" .. tostring(sid)] = nil end
end

-- has, stacks, remaining — client UnitAura (when visible) + RUNTIME notes + cache.
function World.guid_aura_state(guid, spell_id, aura_name)
    if not guid then return false, 0, 0 end
    local sid = tonumber(spell_id) or 0
    local nm = tostring(aura_name or "")
    -- Client-visible: if this GUID is "target"/"focus"/nameplate, UnitDebuff
    -- is authoritative. Fixes single-target PS double-cast when CLEU notes lag
    -- but the debuff is already on the bar.
    if UnitDebuff and UnitGUID then
        local tokens = { "target", "focus", "mouseover" }
        for i = 1, 40 do tokens[#tokens + 1] = "nameplate" .. i end
        for ti = 1, #tokens do
            local tok = tokens[ti]
            if UnitExists and UnitExists(tok) and tostring(UnitGUID(tok) or "") == tostring(guid) then
                for i = 1, 40 do
                    local name, _, _, count, _, _, expirationTime, _, _, _, spellId = UnitDebuff(tok, i)
                    if not name then break end
                    local match = false
                    if sid > 0 and tonumber(spellId) == sid then match = true end
                    if not match and nm ~= "" and string.lower(name) == string.lower(nm) then
                        match = true
                    end
                    if match then
                        local rem = 0
                        if expirationTime and GetTime then
                            rem = math.max(0, (tonumber(expirationTime) or 0) - GetTime())
                        end
                        return true, math.max(1, tonumber(count) or 1), rem
                    end
                end
                break -- only check the matching token
            end
        end
    end
    if sid > 0 and RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime() then
        local ok, stacks = pcall(RaijinLab.RuntimeCall, RaijinLab, "HasUnitAura", guid, sid)
        stacks = (ok and tonumber(stacks)) or 0
        if stacks and stacks > 0 then
            return true, stacks, 0
        end
        -- Runtime missing: fall through to Lua cache (optimistic notes).
    end
    local bag = World._aura_by_guid[guid]
    if not bag then return false, 0, 0 end
    local now = (GetTime and GetTime()) or 0
    local keys = {}
    if sid > 0 then keys[#keys + 1] = "id:" .. tostring(sid) end
    if nm ~= "" then keys[#keys + 1] = "nm:" .. string.lower(nm) end
    for i = 1, #keys do
        local e = bag[keys[i]]
        if e then
            local rem = (tonumber(e.exp) or 0) - now
            if rem > 0.05 then
                return true, tonumber(e.stacks) or 1, rem
            end
            bag[keys[i]] = nil
        end
    end
    return false, 0, 0
end

function World.arm_combat_log()
    if World._cleu_armed then return end
    if not CreateFrame then return end
    World._cleu_armed = true
    local f = CreateFrame("Frame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function()
        local ok, err = pcall(World.on_combat_log)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
    World._cleu_frame = f
end

function World.on_combat_log()
    -- 3.3.5 combat log uses global arg1..argN
    -- arg2=event, arg3=sourceGUID, arg4=sourceName, arg6=destGUID, arg9=spellId, arg10=spellName
    local subevent = arg2
    if type(subevent) ~= "string" then return end
    local sourceGUID = arg3
    local destGUID = arg6
    local playerGuid = UnitGUID and UnitGUID("player")

    -- ---- Death memory (mid-combat corpses for Soul Capture etc.) ----
    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        if destGUID and destGUID ~= playerGuid then
            World.note_unit_died(destGUID)
            World._aura_by_guid[destGUID] = nil
        end
        return
    end
    -- Overkill damage also means a corpse just appeared.
    if subevent == "SWING_DAMAGE" or subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "RANGE_DAMAGE" then
        local overkill = tonumber(arg13) or tonumber(arg12) or 0
        if overkill and overkill > 0 and destGUID and destGUID ~= playerGuid then
            World.note_unit_died(destGUID)
            World._aura_by_guid[destGUID] = nil
        end
    end

    -- ---- Aura tracking by GUID (multi-dot without nameplates / TargetUnit) ----
    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH"
        or subevent == "SPELL_AURA_APPLIED_DOSE" then
        local spellId, spellName = arg9, arg10
        local stacks = tonumber(arg13) or tonumber(arg12) or 1
        if destGUID then
            World.note_aura_on_guid(destGUID, spellId, spellName, stacks, nil)
        end
        -- fall through for corpse-consume on AURA_APPLIED
    elseif subevent == "SPELL_AURA_REMOVED" or subevent == "SPELL_AURA_REMOVED_DOSE" then
        local spellId, spellName = arg9, arg10
        if destGUID then
            if subevent == "SPELL_AURA_REMOVED" then
                World.clear_aura_on_guid(destGUID, spellId, spellName)
            end
        end
        return
    end

    -- ---- Corpse consumption (NOT loot) ----
    if subevent == "SPELL_CAST_SUCCESS" or subevent == "SPELL_AURA_APPLIED"
        or subevent == "SPELL_PERIODIC_ENERGIZE" or subevent == "SPELL_ENERGIZE" then
        local spellId, spellName = arg9, arg10
        local nm = string.lower(tostring(spellName or ""))
        local is_consume = _is_corpse_consume_spell(spellId, spellName)
            or nm:find("soul capture", 1, true)
            or nm:find("capture soul", 1, true)
            or nm:find("soulsteal", 1, true)
        if is_consume then
            local from_player = (playerGuid and sourceGUID == playerGuid)
                or (arg4 and UnitName and arg4 == UnitName("player"))
            if from_player then
                if destGUID and destGUID ~= playerGuid and destGUID ~= sourceGUID then
                    World.mark_corpse_consumed(destGUID)
                    World._death_corpses[destGUID] = nil
                else
                    local g = World.mark_nearest_corpse_consumed(40)
                    if g then World._death_corpses[g] = nil end
                end
            end
        end
        -- Do NOT note SPELL_CAST_SUCCESS with the cast spell id as an "aura".
        -- Plague Strike id 45513 ≠ Blood Plague 55078 — that polluted search
        -- (wrong key) and never stopped multi-dot from re-casting.
        -- Optimistic apply is done in Executor with the aura_search spell_id,
        -- and confirmed by SPELL_AURA_APPLIED above.
        if subevent ~= "SPELL_MISSED" then return end
    end

    local spellId, spellName, spellSchool, missType
    if subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" or subevent == "SPELL_PERIODIC_MISSED" then
        spellId = arg9
        spellName = arg10
        spellSchool = arg11
        missType = arg12
    elseif subevent == "SWING_MISSED" then
        missType = arg9
        spellId = 0
        spellName = "Melee"
        spellSchool = 1
    else
        return
    end

    local mt = tostring(missType or ""):upper()
    if mt ~= "IMMUNE" and mt ~= "EVADE" and mt ~= "DEFLECT" and mt ~= "REFLECT"
        and mt ~= "ABSORB" and mt ~= "BLOCK" then
        return
    end

    local now = GetTime and GetTime() or 0
    local function note(guid, key)
        if not guid or key == nil then return end
        World._miss_by_guid[guid] = World._miss_by_guid[guid] or {}
        World._miss_by_guid[guid][key] = { type = mt, t = now, spell = spellName }
        local bag = World._miss_by_guid[guid]
        for k, v in pairs(bag) do
            if v.t and now - v.t > 6 then bag[k] = nil end
        end
    end

    note(destGUID, spellId)
    note(destGUID, tostring(spellId or ""))
    local school = World.school_from_mask(spellSchool)
    if school then note(destGUID, school) end
    if mt == "IMMUNE" or mt == "EVADE" then note(destGUID, "all") end
    if school and school ~= "physical" and (mt == "IMMUNE" or mt == "REFLECT") then
        note(destGUID, "magic")
    end
end

function World.school_from_mask(mask)
    mask = tonumber(mask) or 0
    -- SpellSchool masks (bit): 1 physical, 2 holy, 4 fire, 8 nature, 16 frost, 32 shadow, 64 arcane
    if mask == 1 then return "physical" end
    if mask == 2 then return "holy" end
    if mask == 4 then return "fire" end
    if mask == 8 then return "nature" end
    if mask == 16 then return "frost" end
    if mask == 32 then return "shadow" end
    if mask == 64 then return "arcane" end
    if mask > 1 then return "magic" end
    return nil
end

function World.recent_miss_for(unit)
    local guid = UnitGUID and UnitGUID(unit)
    if not guid then return {} end
    return World._miss_by_guid[guid] or {}
end

-- Parse absorb amount from UnitBuff tooltip / return values when available
local function scan_absorb_amounts(unit)
    local amounts = {}
    if not UnitBuff then return amounts end
    local tip = World._absorb_tip
    if not tip and CreateFrame then
        tip = CreateFrame("GameTooltip", "RaijinLabAbsorbTip", nil, "GameTooltipTemplate")
        tip:SetOwner(UIParent or WorldFrame, "ANCHOR_NONE")
        World._absorb_tip = tip
    end
    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime, unitCaster, isStealable,
              shouldConsolidate, spellId = UnitBuff(unit, i)
        if not name then break end
        local amt = 0
        -- Some private servers return absorb as an extra return; scan known positions
        -- Also parse tooltip lines for numbers near "absorb"
        if tip and tip.SetUnitBuff then
            tip:ClearLines()
            pcall(tip.SetUnitBuff, tip, unit, i)
            local regions = { tip:GetRegions() }
            for _, r in ipairs(regions) do
                if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                    local t = r:GetText()
                    if t and (t:lower():find("absorb") or t:lower():find("damage")) then
                        local n = t:match("(%d+[%d,%.]*)")
                        if n then
                            n = n:gsub(",", "")
                            amt = tonumber(n) or amt
                        end
                    end
                end
            end
        end
        if amt > 0 then
            amounts[name] = amt
            if spellId then
                amounts[spellId] = amt
                amounts[tostring(spellId)] = amt
            end
        end
    end
    return amounts
end

-- Rich aura scan: presence tables + stacks + remaining duration.
-- present[name|id]=true, stacks[name|id]=count, remaining[name|id]=seconds
local function scan_auras_rich(unit, isDebuff)
    local present, stacks, remaining = {}, {}, {}
    if not unit then return present, stacks, remaining end
    local getter = isDebuff and UnitDebuff or UnitBuff
    if not getter then return present, stacks, remaining end
    local now = GetTime and GetTime() or 0
    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime, unitCaster, isStealable,
              shouldConsolidate, spellId = getter(unit, i)
        if not name then break end
        count = tonumber(count) or 1
        if count < 1 then count = 1 end
        local rem = 0
        -- 3.3.5: expirationTime is absolute GetTime() when aura ends; duration is full length
        if type(expirationTime) == "number" and expirationTime > 0 then
            rem = expirationTime - now
            if rem < 0 then rem = 0 end
        elseif type(duration) == "number" and duration > 0 then
            -- some clients return timeLeft as 7th; treat duration as remaining if no expiration
            rem = duration
        end
        local function mark(key)
            if not key then return end
            present[key] = true
            local prev = stacks[key] or 0
            if count > prev then stacks[key] = count end
            local prevR = remaining[key] or 0
            if rem > prevR then remaining[key] = rem end
        end
        mark(name)
        if type(spellId) == "number" and spellId > 0 then
            mark(spellId)
            mark(tostring(spellId))
        end
    end
    return present, stacks, remaining
end

-- Map spell_id -> present/stacks/remaining using GetSpellInfo name when id missing on aura
local function mark_ids_from_names(present, stacks, remaining, spell_ids)
    if not GetSpellInfo or type(spell_ids) ~= "table" then return end
    for _, id in ipairs(spell_ids) do
        local n = GetSpellInfo(id)
        if n and present[n] then
            present[id] = true
            present[tostring(id)] = true
            if stacks[n] then
                stacks[id] = stacks[n]
                stacks[tostring(id)] = stacks[n]
            end
            if remaining[n] then
                remaining[id] = remaining[n]
                remaining[tostring(id)] = remaining[n]
            end
        end
    end
end

-- Warrior/Druid/etc. stances and forms are SHAPESHIFTS. On 3.3.5 / Ascension
-- they often never appear in UnitBuff, so an aura condition like
-- "Battle Stance (2457) missing" stays true forever -> rotation spams stance.
-- Inject the active form into the player buff tables (name + common spell ids).
local SHAPESHIFT_SPELL_IDS = {
    -- Warrior
    2457,  -- Battle Stance
    71,    -- Defensive Stance
    2458,  -- Berserker Stance
    -- Druid
    768,   -- Cat Form
    5487,  -- Bear Form
    9634,  -- Dire Bear Form
    783,   -- Travel Form
    1066,  -- Aquatic Form
    24858, -- Moonkin Form
    33891, -- Tree of Life
    -- Priest / Rogue / etc. (harmless if absent)
    15473, -- Shadowform
    1784,  -- Stealth
}

local function inject_active_shapeshift_forms(present, stacks, remaining, spell_ids)
    if not present then return end
    local function mark(key)
        if not key then return end
        present[key] = true
        if stacks and (not stacks[key] or stacks[key] < 1) then stacks[key] = 1 end
        -- Forms are permanent until switched; use a large remaining so
        -- remaining_op filters don't treat them as expired.
        if remaining and (not remaining[key] or remaining[key] < 3600) then
            remaining[key] = 3600
        end
    end

    if GetShapeshiftFormInfo then
        local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 10
        for i = 1, n do
            -- 3.3.5: texture, name, isActive, isCastable
            local _tex, name, active = GetShapeshiftFormInfo(i)
            if active and type(name) == "string" and name ~= "" then
                mark(name)
            end
        end
    end

    -- Map known stance/form spell ids whose GetSpellInfo name is now present.
    if GetSpellInfo then
        for _, id in ipairs(SHAPESHIFT_SPELL_IDS) do
            local n = GetSpellInfo(id)
            if n and present[n] then
                mark(id)
                mark(tostring(id))
            end
        end
        -- Also map any rotation spell ids that match an active form name.
        if type(spell_ids) == "table" then
            for _, id in ipairs(spell_ids) do
                local n = GetSpellInfo(id)
                if n and present[n] then
                    mark(id)
                    mark(tostring(id))
                end
            end
        end
    end
end

local function spell_cooldown_remaining(spellId)
    if not GetSpellCooldown or not spellId or spellId == 0 then return 0 end
    local start, duration, enable
    -- 3.3.5: GetSpellCooldown(name) or GetSpellCooldown(id) depending on client
    if GetSpellInfo then
        local name = GetSpellInfo(spellId)
        if name then
            start, duration, enable = GetSpellCooldown(name)
        end
    end
    if (not start or start == 0) then
        start, duration, enable = GetSpellCooldown(spellId)
    end
    if not start or not duration or duration <= 0 then return 0 end
    local rem = (start + duration) - (GetTime and GetTime() or 0)
    if rem < 0 then rem = 0 end
    return rem
end

local function gcd_remaining()
    if not GetSpellCooldown then return 0 end
    -- Prefer a known instant / racial / auto-attack style probe
    local probes = { 6603, 78, 133 } -- Auto Attack, Heroic Strike, Fireball (fallbacks)
    for _, id in ipairs(probes) do
        local rem = spell_cooldown_remaining(id)
        -- GCD windows are typically <= 1.5s; longer values are real spell CDs
        if rem > 0 and rem <= 1.6 then return rem end
    end
    -- Book slot 1 as last resort (often sits on GCD)
    if GetSpellName then
        local n = GetSpellName(1, BOOKTYPE_SPELL or "spell")
        if n then
            local start, duration = GetSpellCooldown(n)
            if start and duration and duration > 0 and duration <= 1.6 then
                local rem = start + duration - (GetTime and GetTime() or 0)
                if rem > 0 then return rem end
            end
        end
    end
    return 0
end
-- Public accessor so external callers (Executor's soft-GCD gate) can query
-- without touching the internal build_context path.
World.gcd_remaining = gcd_remaining

-- Power pools.
--
-- POWER_TYPES: stock 3.3.5 pools reachable through UnitPower(unit, idx).
--   0 mana, 1 rage, 2 focus, 3 energy, 4 happiness, 5 runes, 6 runic.
-- POWER_CUSTOM: Ascension-flavored pools NOT exposed via UnitPower. Each
--   entry declares an aura scan: the pool's current value is the stack
--   count of the named aura on the player; the pool's max is the entry's
--   `cap` (best-known upper bound so pct math has a denominator).
--
-- Rationale for aura-only felfury: Ascension's own AscensionRotation
-- addon (see Interface/AddOns/AscensionRotation/Libs/Util.lua) uses only
-- the stock 0-6 indices via UnitPowerType. There is no numeric-index API
-- for Fel Fury on this build, so guessing an index (any index) risks
-- reading an unrelated pool. Aura stacks are the ground truth.
local POWER_TYPES = {
    mana = 0, rage = 1, focus = 2, energy = 3,
    happiness = 4, runes = 5, runic = 6,
}

-- POWER_CUSTOM entries can specify EITHER:
--   aura_names = { "Aura A", "Aura B" }  -- current value = highest stack count
--   read = function() return current, max end   -- direct read
-- `cap` is the max when aura_names is used (or the API doesn't expose a max).
local POWER_CUSTOM = {
    -- FelFury (Ascension Demon Hunter, 0-6). We don't know for certain how this
    -- build exposes it, so we try, in order: (1) explicit UnitPower indices
    -- (10 = WotLK ALTERNATE_POWER_INDEX, the usual home for custom pools; plus a
    -- scan of 7-15 for any pool whose max looks like a small discrete resource),
    -- (2) the "Fel Fury" aura stack count. `/raijin power` dumps the live truth
    -- so this can be pinned exactly. cap 6 is the known FelFury maximum.
    felfury = {
        unit_power_indices = { 10 },
        unit_power_scan = { lo = 7, hi = 15, max_lo = 1, max_hi = 6 },
        aura_names = { "Fel Fury", "FelFury", "Fel fury" },
        cap = 6,
    },
    -- Combo points aren't a UnitPower pool on 3.3.5 - GetComboPoints is its
    -- own API. Wrapping it into POWER_CUSTOM lets the unified `power`
    -- condition treat combo points the same as mana/rage/felfury: pick
    -- power_type=combo_points with mode=units and threshold N.
    combo_points = {
        cap = 5,
        read = function()
            if not GetComboPoints then return 0, 5 end
            return (GetComboPoints("player", "target") or 0), 5
        end,
    },
}

-- Resolve current + max raw amounts for a power. `ptype` is either the
-- string name ("mana", "felfury", ...), a numeric UnitPower index, or nil
-- for the primary pool. Returns (current, max).
--
-- Contract:
--   * A pool that isn't present on this character returns (0, 0). Callers
--     interpret that as "N/A"; pct helpers translate it to 100 (see below)
--     so a threshold like power_pct_below(40) doesn't spuriously fire on
--     classes that don't have the pool at all.
--   * A custom (aura-based) pool always returns max = cap, even when the
--     aura is missing, so pct math is stable (0/6 = 0%, 6/6 = 100%).
local function power_raw_for(ptype)
    if not UnitPower or not UnitPowerMax then return 0, 0 end

    local key = type(ptype) == "string" and string.lower(ptype) or ptype

    -- Custom pool (aura-driven or direct-read). Add friends to POWER_CUSTOM.
    if type(key) == "string" then
        local custom = POWER_CUSTOM[key]
        if custom then
            if type(custom.read) == "function" then
                local ok, cur, max = pcall(custom.read)
                if not ok then return 0, custom.cap or 0 end
                return tonumber(cur) or 0, tonumber(max) or custom.cap or 0
            end
            -- (1) Explicit UnitPower index (e.g. 10 = WotLK ALTERNATE_POWER_INDEX).
            -- A real custom pool reports a non-zero max here. Clamp to the known
            -- cap so an unrelated large pool that happens to live at this index
            -- (e.g. a vehicle/encounter resource with max 100) can't hijack the
            -- reading; take the first plausible hit.
            if custom.unit_power_indices then
                local cap = custom.cap or 12
                for _, idx in ipairs(custom.unit_power_indices) do
                    local max = UnitPowerMax("player", idx) or 0
                    if max > 0 and max <= cap then
                        return UnitPower("player", idx) or 0, max
                    end
                end
            end
            -- (2) Aura-stack (value = highest matching buff's stack count). Only
            -- accepted when actually present (>0); a 0/absent aura is
            -- indistinguishable from "no such aura", so fall through to the scan.
            if custom.aura_names and UnitBuff then
                local stacks = 0
                for i = 1, 40 do
                    local nm, _, _, count = UnitBuff("player", i)
                    if not nm then break end
                    for _, wanted in ipairs(custom.aura_names) do
                        if string.lower(nm) == string.lower(wanted) then
                            -- A PRESENT application counts as at least 1: 3.3.5
                            -- reports count=0 for single non-stacking auras, and
                            -- dropping it here would make a present pool read as
                            -- absent (mirrors scan_auras_rich's 0->1 clamp).
                            local c = tonumber(count) or 0
                            if c < 1 then c = 1 end
                            if c > stacks then stacks = c end
                        end
                    end
                end
                if stacks > 0 then return stacks, custom.cap or 0 end
            end
            -- (3) Auto-discover: scan a band of indices for a pool whose max looks
            -- like a small discrete resource (FelFury caps at 6). Accept ONLY when
            -- exactly one index qualifies, so an unrelated pool can't be grabbed
            -- by accident. `/raijin power` reveals the true index to pin here.
            if custom.unit_power_scan then
                local s = custom.unit_power_scan
                local found_idx, found_max, n = nil, 0, 0
                for idx = s.lo, s.hi do
                    local max = UnitPowerMax("player", idx) or 0
                    if max >= (s.max_lo or 1) and max <= (s.max_hi or 12) then
                        n = n + 1
                        found_idx, found_max = idx, max
                    end
                end
                if n == 1 then
                    return UnitPower("player", found_idx) or 0, found_max
                end
            end
            -- Genuinely undetected: report max 0 (NOT cap) so the pool reads as
            -- ABSENT. Returning cap here made felfury look present-at-0 on every
            -- character (even a warrior), defeating the Conditions absent-pool
            -- guard and firing felfury conditions where no such pool exists. A
            -- real DH exposes the pool via one of the branches above (max=cap),
            -- so this only zeroes out characters that truly lack it.
            return 0, 0
        end
    end

    -- Numeric-index pool via UnitPower.
    local idx = POWER_TYPES[key]
    if idx == nil and type(key) == "number" then idx = key end
    if idx == nil then
        -- Primary pool for this unit (mana / rage / ...).
        return UnitPower("player") or 0, UnitPowerMax("player") or 0
    end
    return UnitPower("player", idx) or 0, UnitPowerMax("player", idx) or 0
end

-- Percent form of the same lookup. When a pool has no max (either the
-- character doesn't have it, or UnitPowerMax hasn't populated yet), return
-- 100 so "power below X%" evaluates false - safer default than 0, which
-- would make min-power conditions fire on classes that lack the pool.
local function power_pct_for(ptype)
    local cur, max = power_raw_for(ptype)
    if max and max > 0 then return 100 * cur / max end
    return 100
end

-- Build target protection snapshot for Protection.is_protected
function World.build_target_protection()
    local snap = {
        exists = UnitExists and UnitExists("target") or false,
        is_dead = false,
        can_attack = false,
        is_friend = false,
        buffs = {},
        debuffs = {},
        absorb_amounts = {},
        creature_type = "",
        recent_miss = {},
    }
    if not snap.exists then return snap end
    snap.is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") or false
    snap.can_attack = UnitCanAttack and UnitCanAttack("player", "target") or false
    snap.is_friend = UnitIsFriend and UnitIsFriend("player", "target") or false
    snap.creature_type = UnitCreatureType and UnitCreatureType("target") or ""
    local presentB, _, _ = scan_auras_rich("target", false)
    local presentD, _, _ = scan_auras_rich("target", true)
    snap.buffs = presentB
    snap.debuffs = presentD
    snap.absorb_amounts = scan_absorb_amounts("target")
    snap.recent_miss = World.recent_miss_for("target")
    return snap
end

-- Per-spell protected map for rotation spell ids (and slot evaluation)
function World.compute_protection_map(spell_ids, spell_names)
    local Protection = RaijinLab and RaijinLab.Protection
    local map = {} -- [id] = { protected=bool, reason=string }
    if not Protection then return map end
    World.arm_combat_log()
    local target = World.build_target_protection()
    local now = GetTime and GetTime() or 0
    spell_ids = spell_ids or {}
    spell_names = spell_names or {}
    for _, id in ipairs(spell_ids) do
        local name = spell_names[id] or (GetSpellInfo and GetSpellInfo(id)) or ""
        local prot, reason, details = Protection.is_protected(target, {
            spell_id = id,
            spell_name = name,
            school = "auto",
            now = now,
            treat_absorb_as_protected = true,
            respect_recent_miss = true,
        })
        map[id] = { protected = prot, reason = reason, details = details, school = details and details.school }
        map[tostring(id)] = map[id]
    end
    return map, target
end

-- opts.spell_ids = list of spell ids to resolve cooldowns / aura id mapping for
-- opts.skip_enemies = true -> skip OM/token enemy scan (rotation hot path when
--   no enemies_in_range / pvp conditions need it). Huge win at 50-60 Hz.
-- opts.light = true -> skip protection map recompute when cache cold longer OK
-- opts.skip_spell_snapshot = true -> Executor fill_live overwrites these; skip
--   the heavy per-spell IsUsable/IsSpellInRange/GetSpellInfo loop here.
-- opts.skip_los = true -> skip TraceLine (re-use cached LoS for a few frames)
-- opts.skip_facing = true -> skip facing/behind probes
function World.build_context(opts)
    opts = opts or {}
    local spell_ids = opts.spell_ids or {}

    -- Same-frame / short TTL cache: share snapshot across consumers and
    -- absorb micro-ticks when the world fingerprint is unchanged.
    local tnow = (GetTime and GetTime()) or 0
    local sk = opts.skip_enemies and 1 or 0
    local ss = opts.skip_spell_snapshot and 1 or 0
    local sl = opts.skip_los and 1 or 0
    local nk = #spell_ids
    local sid0 = spell_ids[1] or 0
    local sidN = spell_ids[nk] or 0
    local tguid = (UnitGUID and UnitExists and UnitExists("target") and UnitGUID("target")) or "-"
    local combat = (UnitAffectingCombat and UnitAffectingCombat("player")) and 1 or 0
    local cache_key = string.format("%d:%d:%d:%s:%s:%s:%d:%d",
        nk, sk, ss, tostring(sid0), tostring(sidN), tostring(tguid), combat, sl)
    local cc = World._ctx_frame_cache
    -- In combat with a target: reuse for 1 frame only. OOC / no target: up to 50ms.
    local ttl = (combat == 1 and tguid ~= "-") and 0.0 or 0.05
    if cc and cc.key == cache_key and cc.ctx and (tnow - (cc.t or 0)) <= ttl then
        return cc.ctx
    end
    -- Same GetTime stamp = same frame even when ttl is 0.
    if cc and cc.key == cache_key and cc.ctx and cc.t == tnow then
        return cc.ctx
    end

    -- Ensure CLEU is armed whenever we build combat context
    World.arm_combat_log()

    local ctx = {
        in_combat = UnitAffectingCombat and UnitAffectingCombat("player") or false,
        health_pct = 100,
        power_pct = 100,
        power_by_type = {},
        combo_points = 0,
        is_moving = (GetUnitSpeed and GetUnitSpeed("player") or 0) > 0,
        is_mounted = IsMounted and IsMounted() or false,
        is_casting = (UnitCastingInfo and UnitCastingInfo("player") ~= nil) or false,
        is_channeling = (UnitChannelInfo and UnitChannelInfo("player") ~= nil) or false,
        -- User interaction: loot/gossip/quest/trade/AH/craft/... Never interrupt
        -- unless a slot opts in via the player_state condition.
        user_state = (World.user_interaction_state and World.user_interaction_state()) or "free",
        pvp_flagged = UnitIsPVP and UnitIsPVP("player") or false,
        has_pet = UnitExists and UnitExists("pet") or false,
        form = GetShapeshiftForm and GetShapeshiftForm() or 0,
        gcd_remaining = 0,
        cooldowns = {},
        known_spells = {},
        player_buffs = {},
        player_buff_stacks = {},
        player_buff_remaining = {},
        player_debuffs = {},
        player_debuff_stacks = {},
        player_debuff_remaining = {},
        target_buffs = {},
        target_buff_stacks = {},
        target_buff_remaining = {},
        target_debuffs = {},
        target_debuff_stacks = {},
        target_debuff_remaining = {},
        target_exists = UnitExists and UnitExists("target") or false,
        target_is_enemy = false,
        target_is_friend = false,
        target_is_dead = false,
        -- "hostile" | "neutral" | "friendly" | nil  (from UnitReaction bands)
        target_hostility = nil,
        -- Raw UnitReaction 1..8 when known (1 hated .. 8 exalted)
        target_reaction = nil,
        target_health_pct = 100,
        target_distance = 999,
        target_distance_precise = false,
        facing_target = false,
        behind_target = false,
        enemies_in_range = 0,
        enemies_in_8 = 0,
        enemies_in_10 = 0,
        enemies_in_40 = 0,
        enemies_by_range = {}, -- [range] = count for arbitrary queries
        enemy_players_in_range = 0,
        nearest_enemy_player_dist = 999,
        nearest_enemy_dist = 999,
        target_ttd = nil,
        spell_usable = {}, -- [id] = bool
        spell_in_range = {},
        spell_targeted = {}, -- [id] = bool: spell is target-directed (has range)
        spell_instant = {},  -- [id] = bool: cast time == 0 (weaves during a cast)
        target_in_los = nil, -- true/false/nil (nil = undeterminable)
        -- Corpses (filled below; used by the `corpse` condition)
        corpses_available = 0,
        corpses_consumed = 0,
        corpses_total = 0,
        corpse_nearest = 999,
        corpse_list = {},
    }

    if UnitHealth and UnitHealthMax then
        local h, m = UnitHealth("player"), UnitHealthMax("player")
        if m and m > 0 then ctx.health_pct = 100 * h / m end
    end
    ctx.power_pct = power_pct_for(nil)
    -- Raw current/max for the primary pool so unit-mode conditions
    -- (power_at_least mode=units) can compare discrete pools like FelFury's
    -- 0-6 stacks rather than a rounded percent.
    do
        local cur, max = power_raw_for(nil)
        ctx.power_amount = cur
        ctx.power_amount_max = max
    end
    ctx.power_amount_by_type = {}
    ctx.power_amount_max_by_type = {}
    -- Stock UnitPower pools: index-keyed AND name-keyed so consumers can
    -- reach the value by either.
    for name, idx in pairs(POWER_TYPES) do
        ctx.power_by_type[name] = power_pct_for(name)
        ctx.power_by_type[idx] = ctx.power_by_type[name]
        local cur, max = power_raw_for(name)
        ctx.power_amount_by_type[name] = cur
        ctx.power_amount_max_by_type[name] = max
    end
    -- Custom aura-driven pools (felfury, ...): name-keyed only (no numeric
    -- index exists for them on this build).
    for name, _ in pairs(POWER_CUSTOM) do
        ctx.power_by_type[name] = power_pct_for(name)
        local cur, max = power_raw_for(name)
        ctx.power_amount_by_type[name] = cur
        ctx.power_amount_max_by_type[name] = max
    end
    if GetComboPoints then
        ctx.combo_points = GetComboPoints("player", "target") or 0
    end

    -- Player auras (~10 Hz). Shape-shift inject stays free.
    local pac = World._paura_cache
    if pac and (tnow - (pac.t or 0)) < 0.10 then
        ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining =
            pac.b, pac.bs, pac.br
        ctx.player_debuffs, ctx.player_debuff_stacks, ctx.player_debuff_remaining =
            pac.d, pac.ds, pac.dr
    else
        ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining =
            scan_auras_rich("player", false)
        inject_active_shapeshift_forms(ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining, spell_ids)
        mark_ids_from_names(ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining, spell_ids)
        ctx.player_debuffs, ctx.player_debuff_stacks, ctx.player_debuff_remaining =
            scan_auras_rich("player", true)
        mark_ids_from_names(ctx.player_debuffs, ctx.player_debuff_stacks, ctx.player_debuff_remaining, spell_ids)
        World._paura_cache = {
            t = tnow,
            b = ctx.player_buffs, bs = ctx.player_buff_stacks, br = ctx.player_buff_remaining,
            d = ctx.player_debuffs, ds = ctx.player_debuff_stacks, dr = ctx.player_debuff_remaining,
        }
    end
    -- Always re-inject forms (cheap) after cache hit so stance changes land.
    inject_active_shapeshift_forms(ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining, spell_ids)

    if ctx.target_exists then
        ctx.target_is_enemy = UnitCanAttack and UnitCanAttack("player", "target") or false
        ctx.target_is_friend = UnitIsFriend and UnitIsFriend("player", "target") or false
        ctx.target_is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") or false
        -- Target's target is us (aggro / focused on player).
        do
            local on_you = false
            if UnitIsUnit then
                local ok, r = pcall(UnitIsUnit, "targettarget", "player")
                on_you = ok and r and true or false
            end
            ctx.target_targeting_you = on_you
        end
        -- Hostility bands from UnitReaction (authoritative nameplate/UI colors):
        --   1-3 hostile (hated/hostile/unfriendly), 4 neutral, 5-8 friendly.
        -- Fallback when reaction is nil: friend -> friendly, can_attack -> hostile,
        -- else neutral. Yellow neutrals are attackable, so reaction is preferred.
        do
            local band, rnum = nil, nil
            if UnitReaction then
                local ok, r = pcall(UnitReaction, "player", "target")
                if ok then rnum = tonumber(r) end
            end
            if rnum then
                if rnum <= 3 then band = "hostile"
                elseif rnum == 4 then band = "neutral"
                else band = "friendly" end
            else
                if ctx.target_is_friend then
                    band = "friendly"
                elseif ctx.target_is_enemy then
                    band = "hostile"
                else
                    band = "neutral"
                end
            end
            ctx.target_reaction = rnum
            ctx.target_hostility = band
        end
        local th, tm = 0, 1
        if UnitHealth and UnitHealthMax then
            th, tm = UnitHealth("target"), UnitHealthMax("target")
            if tm and tm > 0 then ctx.target_health_pct = 100 * th / tm end
        end
        -- RANGE AUTHORITY: ObjectPosition(GUID) + ObjectCombatReach only.
        -- Target token is discovery; GUID is the coordinate key. Never use
        -- CheckInteractDistance buckets as combat yards.
        local tguid = UnitGUID and UnitGUID("target") or nil
        local px, py, pz, tx, ty, tz
        if RaijinLab and RaijinLab.ObjectPosition then
            px, py, pz = RaijinLab:ObjectPosition("player")
            -- GUID first (OM ObjectPtr). Token only if GUID missing/failed.
            if tguid then
                tx, ty, tz = RaijinLab:ObjectPosition(tguid)
            end
            if not tx then
                tx, ty, tz = RaijinLab:ObjectPosition("target")
            end
        end
        local have_precise = false
        if px and tx then
            local dx, dy = px - tx, py - ty
            local center = math.sqrt(dx * dx + dy * dy)
            -- Collapsed-to-player is not a real range reading.
            local collapsed = (center < 0.05 and tguid and UnitGUID
                and tostring(tguid) ~= tostring(UnitGUID("player")))
            if not collapsed then
                local pReach = combat_reach_of("player")
                local tReach = combat_reach_of(tguid or "target")
                local tBound = bounding_of(tguid or "target")
                local edge = center - pReach - tReach
                if edge < 0 then edge = 0 end
                local extend = (tBound > AOE_BOSS_BOUND) and tBound or 0
                local aoe = center - extend
                if aoe < 0 then aoe = 0 end
                ctx.player_combat_reach = pReach
                ctx.target_combat_reach = tReach
                ctx.target_bounding_radius = tBound
                ctx.target_aoe_gap = aoe
                ctx.target_aoe_extend = extend
                ctx.target_distance_center = center
                ctx.target_distance = edge
                ctx.target_distance_precise = true
                have_precise = true
            end
        end
        -- Prefer API CombatDistance only when manual path failed and it returns
        -- a real center (still ObjectPosition under the hood, GUID-resolved).
        if not have_precise and RaijinLab and RaijinLab.CombatDistance then
            local edge, ctr, pReach, tReach =
                RaijinLab:CombatDistance("player", tguid or "target")
            if ctr and ctr >= 0 and ctr < 900 then
                ctx.player_combat_reach = pReach
                ctx.target_combat_reach = tReach
                ctx.target_distance_center = ctr
                ctx.target_distance = edge or ctr
                ctx.target_distance_precise = true
                have_precise = true
                if RaijinLab.AoEDistance then
                    local aoe, _, extend =
                        RaijinLab:AoEDistance("player", tguid or "target")
                    ctx.target_aoe_gap = aoe
                    ctx.target_aoe_extend = extend
                    if RaijinLab.ObjectBoundingRadius then
                        ctx.target_bounding_radius =
                            tonumber(RaijinLab:ObjectBoundingRadius(tguid or "target"))
                    end
                else
                    ctx.target_aoe_gap = ctr
                    ctx.target_aoe_extend = 0
                end
            end
        end
        -- No CheckInteract midpoint. Without ObjectPosition we do not invent yards.
        if not have_precise then
            ctx.target_distance = 999
            ctx.target_distance_center = 999
            ctx.target_distance_precise = false
            ctx.target_distance_lo = nil
            ctx.target_distance_hi = nil
        end
        -- LoS: one TraceLine is a top hitch source. Cache ~100ms per target.
        if not opts.skip_los and px and tx and RaijinLab and RaijinLab.TraceLine then
            local los_key = tostring(tguid or "t")
            local lc = World._los_cache
            if lc and lc.key == los_key and (tnow - (lc.t or 0)) < 0.10 then
                ctx.target_in_los = lc.v
            else
                local ok, blocked = pcall(RaijinLab.TraceLine, RaijinLab,
                    px, py, (pz or 0) + 2, tx, ty, (tz or 0) + 2, 0x100111)
                if ok then
                    ctx.target_in_los = (blocked ~= true)
                    World._los_cache = { key = los_key, t = tnow, v = ctx.target_in_los }
                end
            end
        elseif opts.skip_los and World._los_cache and World._los_cache.key == tostring(tguid or "t") then
            ctx.target_in_los = World._los_cache.v
        end
        if not opts.skip_facing then
            if RaijinLab and RaijinLab.ObjectIsFacing then
                ctx.facing_target = not not RaijinLab:ObjectIsFacing("player", "target")
            end
            if RaijinLab and RaijinLab.ObjectIsBehind then
                ctx.behind_target = not not RaijinLab:ObjectIsBehind("player", "target")
            end
        end

        -- Target auras: throttle to ~20 Hz per target GUID (rotation reuses).
        local ta_key = tostring(tguid or "-")
        local tac = World._taura_cache
        if tac and tac.key == ta_key and (tnow - (tac.t or 0)) < 0.05 then
            ctx.target_buffs, ctx.target_buff_stacks, ctx.target_buff_remaining =
                tac.b, tac.bs, tac.br
            ctx.target_debuffs, ctx.target_debuff_stacks, ctx.target_debuff_remaining =
                tac.d, tac.ds, tac.dr
        else
            ctx.target_buffs, ctx.target_buff_stacks, ctx.target_buff_remaining =
                scan_auras_rich("target", false)
            mark_ids_from_names(ctx.target_buffs, ctx.target_buff_stacks, ctx.target_buff_remaining, spell_ids)
            ctx.target_debuffs, ctx.target_debuff_stacks, ctx.target_debuff_remaining =
                scan_auras_rich("target", true)
            mark_ids_from_names(ctx.target_debuffs, ctx.target_debuff_stacks, ctx.target_debuff_remaining, spell_ids)
            World._taura_cache = {
                key = ta_key, t = tnow,
                b = ctx.target_buffs, bs = ctx.target_buff_stacks, br = ctx.target_buff_remaining,
                d = ctx.target_debuffs, ds = ctx.target_debuff_stacks, dr = ctx.target_debuff_remaining,
            }
        end

        if th and GetTime then
            local now = GetTime()
            if World._ttd_th and World._ttd_t and now > World._ttd_t then
                local lost = World._ttd_th - th
                local dt = now - World._ttd_t
                if lost > 0 and dt > 0 then
                    local dps = lost / dt
                    if dps > 0 then ctx.target_ttd = th / dps end
                end
            end
            World._ttd_th = th
            World._ttd_t = now
        end
    else
        ctx.target_targeting_you = false
    end

    -- GCD first so spell_usable can consult it
    ctx.gcd_remaining = gcd_remaining()

    -- Cooldowns + known + usable. Executor.fill live state every tick when
    -- skip_spell_snapshot is set (rotation hot path) — avoid double work.
    if opts.skip_spell_snapshot then
        -- Minimal stubs so conditions never see nil tables.
        for _, id in ipairs(spell_ids) do
            id = tonumber(id) or 0
            if id > 0 then
                ctx.cooldowns[id] = ctx.cooldowns[id] or 0
                ctx.cooldowns[tostring(id)] = ctx.cooldowns[id]
                ctx.spell_usable[id] = true
                ctx.spell_usable[tostring(id)] = true
                ctx.spell_in_range[id] = true
                ctx.spell_in_range[tostring(id)] = true
                ctx.known_spells[id] = true
                ctx.known_spells[tostring(id)] = true
                ctx.spell_instant[id] = ctx.spell_instant[id]
                ctx.spell_targeted[id] = false
            end
        end
    else
    -- Full snapshot path (non-rotation consumers / diagnostics).
    local RR = RaijinLab and RaijinLab.RankResolver
    for _, id in ipairs(spell_ids) do
        local rid = id
        if RR and RR.highest then rid = RR.highest(id) or id end
        ctx.cooldowns[id] = spell_cooldown_remaining(rid)
        ctx.cooldowns[tostring(id)] = ctx.cooldowns[id]

        -- Instant? cast time 0 -> can weave while casting/channeling. 3.3.5
        -- GetSpellInfo returns castTime (ms) as the 7th value.
        local instant = true
        if GetSpellInfo then
            local _, _, _, _, _, _, castTime = GetSpellInfo(rid)
            castTime = tonumber(castTime)
            if castTime and castTime > 0 then instant = false end
        end
        ctx.spell_instant[id] = instant
        ctx.spell_instant[tostring(id)] = instant

        local known = false
        if IsSpellKnown then
            known = not not IsSpellKnown(rid)
        elseif GetSpellInfo and GetSpellInfo(rid) then
            known = true
        end
        ctx.known_spells[id] = known
        ctx.known_spells[tostring(id)] = known

        -- Pure IsUsableSpell only (resource / stance / form). Do NOT fold known or
        -- cooldown into this flag - Conditions.spell_usable require_known / require_off_cd
        -- gates read known_spells and cooldowns independently.
        local usable = true
        if IsUsableSpell then
            local name = GetSpellInfo and GetSpellInfo(rid)
            local can = false
            if name then
                local u, nomana = IsUsableSpell(name)
                can = not not u
                if nomana then can = false end
            else
                local u, nomana = IsUsableSpell(rid)
                can = not not u
                if nomana then can = false end
            end
            usable = can
        end
        ctx.spell_usable[id] = usable
        ctx.spell_usable[tostring(id)] = usable

        -- Range snapshot (Executor fill_live overwrites each tick).
        -- Self-AoE (maxR 0 / Whirlwind): never trust IsSpellInRange (returns 0
        -- falsely with a target and used to mark WW as targeted+OOR forever).
        local inr, targeted = true, false
        local minR, maxR = 0, 0
        local sname = nil
        if GetSpellInfo then
            local n, _, _, _, _, _, _, mn, mx = GetSpellInfo(rid)
            sname = n
            minR, maxR = tonumber(mn) or 0, tonumber(mx) or 0
        end
        local self_aoe = (maxR <= 0)
        if sname then
            local nl = string.lower(sname)
            if nl:find("whirlwind", 1, true) or nl:find("thunder clap", 1, true)
                or nl:find("arcane explosion", 1, true) then
                self_aoe = true
            end
        end
        if ctx.target_exists then
            if self_aoe then
                targeted = false
                inr = true -- refined after enemy scan / Executor live check
            else
                local client_r = nil
                if IsSpellInRange then
                    if sname then client_r = IsSpellInRange(sname, "target")
                    else client_r = IsSpellInRange(rid, "target") end
                    if client_r ~= nil then targeted = true end
                    if client_r == 0 then inr = false end
                end
                if client_r ~= 0 and client_r ~= 1 then
                    if maxR > 0 then
                        targeted = true
                        -- Only ObjectPosition+reach yards. No interact bucket soft-IN.
                        if ctx.target_distance_precise then
                            local d = tonumber(ctx.target_distance)
                            if d and d < 900 then
                                if d > maxR then inr = false end
                                if minR > 0 and d < minR then inr = false end
                            else
                                inr = false
                            end
                        else
                            inr = false
                        end
                    end
                end
            end
        elseif maxR > 0 and not self_aoe then
            targeted = true
            inr = false
        end
        ctx.spell_in_range[id] = inr
        ctx.spell_in_range[tostring(id)] = inr
        ctx.spell_targeted[id] = targeted
        ctx.spell_targeted[tostring(id)] = targeted
    end
    end -- not opts.skip_spell_snapshot

    -- Nearby enemies. CENTER yards for enemies_in_range / WW pack.
    local enemy_list = {}
    local e8, e10, e40, ep = 0, 0, 0, 0
    local nearest_ep, nearest_e, nearest_center, nearest_aoe = 999, 999, 999, 999
    local nearest_precise = false
    if not opts.skip_enemies then
        local enemies = World.collect_nearby_enemies(40)
        for i = 1, #enemies do
            local e = enemies[i]
            enemy_list[#enemy_list + 1] = e
            local aoe = tonumber(e.dist_aoe or e.dist) or 999
            local c = tonumber(e.dist_center) or aoe
            if e.precise and aoe < nearest_aoe then
                nearest_aoe = aoe
                nearest_center = c
                nearest_e = aoe
                nearest_precise = true
            end
            if dist_within(e, 8) then e8 = e8 + 1 end
            if dist_within(e, 10) then e10 = e10 + 1 end
            if dist_within(e, 40) then e40 = e40 + 1 end
        end
        for _, u in ipairs(World.collect_units_from_tokens()) do
            if u.is_enemy and not u.is_dead and u.is_player then
                ep = ep + 1
                local d = tonumber(u.dist_edge or u.dist) or 999
                if d < nearest_ep then nearest_ep = d end
            end
        end
    end
    ctx.enemy_list = enemy_list
    ctx.enemy_distances = {}
    for i = 1, #enemy_list do
        ctx.enemy_distances[i] = enemy_list[i].dist_aoe or enemy_list[i].dist
    end
    ctx.enemies_in_range = e8
    ctx.enemies_in_8 = e8
    ctx.enemies_in_10 = e10
    ctx.enemies_in_40 = e40
    ctx.enemy_players_in_range = ep
    ctx.nearest_enemy_player_dist = nearest_ep
    ctx.nearest_enemy_dist = nearest_e
    ctx.nearest_enemy_center = nearest_center
    ctx.nearest_enemy_aoe = nearest_aoe
    ctx.nearest_enemy_precise = nearest_precise
    function ctx.count_enemies_within(range)
        range = tonumber(range) or 8
        local n = 0
        for i = 1, #enemy_list do
            if dist_within(enemy_list[i], range) then n = n + 1 end
        end
        return n
    end
    -- Refine self/AOE on CURRENT TARGET only (fail-closed pure/center gap).
    -- Nearest-pack is for enemies_in_range counts, NOT for "can I WW my target".
    do
        for _, id in ipairs(spell_ids) do
            id = tonumber(id) or 0
            if id > 0 then
                local maxR = 0
                local nm = nil
                if GetSpellInfo then
                    local n, _, _, _, _, _, _, _, mx = GetSpellInfo(id)
                    nm, maxR = n, tonumber(mx) or 0
                end
                local is_aoe = (ctx.spell_targeted[id] == false)
                    or (maxR <= 0)
                    or (id >= 1680 and id <= 1686)
                    or (nm and string.lower(nm):find("whirlwind", 1, true))
                    or (nm and string.lower(nm):find("thunder clap", 1, true))
                if is_aoe then
                    local band = 8.0
                    local inr = false
                    local gap = tonumber(ctx.target_aoe_gap)
                    if not gap and ctx.target_distance_precise then
                        local tc = tonumber(ctx.target_distance_center)
                        if tc then
                            local ext = tonumber(ctx.target_aoe_extend) or 0
                            gap = tc - ext
                            if gap < 0 then gap = 0 end
                        end
                    end
                    if gap and gap <= band then inr = true end
                    ctx.spell_in_range[id] = inr
                    ctx.spell_in_range[tostring(id)] = inr
                    ctx.spell_targeted[id] = false
                    ctx.spell_targeted[tostring(id)] = false
                end
            end
        end
    end

    -- Protection analysis (immunity / absorb / reflect) for rotation spells.
    -- This is the heaviest part of the tick: build_target_protection scans the
    -- target's auras AND parses tooltips for absorb amounts. It does NOT need
    -- 50 Hz freshness, so cache it per target for ~150 ms. Recompute immediately
    -- when the target changes (never evaluate a new target against a stale shield
    -- map) or the rotation's spell set changes. This also removes the second
    -- redundant target-aura scan on the ~87% of ticks that hit the cache.
    local pmap, ptarget
    local now_t = (GetTime and GetTime()) or 0
    local tguid = (ctx.target_exists and UnitGUID) and UnitGUID("target") or nil
    local pc = World._prot_cache
    -- Protection is heavy (tooltip parse). 250ms is enough for shield drops;
    -- recompute immediately on target change via guid key.
    if pc and pc.guid == tguid and pc.nspells == #spell_ids and (now_t - pc.t) < 0.25 then
        pmap, ptarget = pc.pmap, pc.ptarget
    else
        pmap, ptarget = World.compute_protection_map(spell_ids)
        World._prot_cache = { guid = tguid, t = now_t, pmap = pmap, ptarget = ptarget, nspells = #spell_ids }
    end
    ctx.protection = pmap
    ctx.protection_target = ptarget
    -- Convenience: target_protected[id] = bool for CAST GATES only.
    -- is_protected() returns protected=true for relationship states
    -- (no_target/dead/friendly/cannot_attack). Those are NOT cast immunities.
    -- Conditions use ctx.is_spell_protected() (full semantics). Cast gates use
    -- Protection.blocks_cast(reason) only.
    ctx.target_protected = {}
    ctx.target_protected_reason = {}
    local Prot = RaijinLab and RaijinLab.Protection
    for id, info in pairs(pmap) do
        if type(info) == "table" then
            local r = info.reason
            local prot = false
            if info.protected and Prot and Prot.blocks_cast then
                prot = Prot.blocks_cast(r) and true or false
            elseif info.protected and r and r ~= "no_target" and r ~= "target_dead"
                and r ~= "friendly" and r ~= "cannot_attack" then
                -- Fallback if Protection module missing: only non-relationship.
                prot = true
            end
            ctx.target_protected[id] = prot
            ctx.target_protected_reason[id] = r
        end
    end
    -- Closure so pure conditions can re-query with custom school / absorb options
    function ctx.is_spell_protected(spell_id, spell_name, school, extra)
        local Protection = RaijinLab and RaijinLab.Protection
        if not Protection then
            local p = pmap[spell_id] or pmap[tostring(spell_id)]
            return p and p.protected or false, p and p.reason or "no_module"
        end
        local target = ptarget or World.build_target_protection()
        extra = extra or {}
        local prot, reason = Protection.is_protected(target, {
            spell_id = spell_id,
            spell_name = spell_name,
            school = school or "auto",
            now = GetTime and GetTime() or 0,
            treat_absorb_as_protected = extra.treat_absorb_as_protected,
            absorb_threshold = extra.absorb_threshold,
            treat_heavy_dr_as_protected = extra.treat_heavy_dr_as_protected,
            respect_recent_miss = extra.respect_recent_miss,
            allow_friend = extra.allow_friend,
        })
        return prot, reason
    end

    -- Corpses for corpse-ability gates (Cannibalize / Raise Dead / ...).
    -- "consumed" = used by such an ability (CLEU-tracked), NEVER loot state.
    -- Scan out to 40 yd once per context; the condition filters range/state.
    do
        local list = World.collect_corpses(40)
        local avail, cons, nearest = 0, 0, 999
        for i = 1, #list do
            local c = list[i]
            if c.available then avail = avail + 1 else cons = cons + 1 end
            if c.dist < nearest then nearest = c.dist end
        end
        ctx.corpse_list = list
        ctx.corpses_available = avail
        ctx.corpses_consumed = cons
        ctx.corpses_total = #list
        ctx.corpse_nearest = nearest
        function ctx.count_corpses_within(range, state)
            range = tonumber(range) or 30
            state = string.lower(tostring(state or "available"))
            local n = 0
            for i = 1, #list do
                local c = list[i]
                if c.dist <= range then
                    if state == "any" or state == "both" then n = n + 1
                    elseif (state == "available" or state == "not_consumed" or state == "fresh") and c.available then n = n + 1
                    elseif (state == "consumed" or state == "empty") and c.consumed then n = n + 1
                    end
                end
            end
            return n
        end
    end

    -- Keep the most recent context around for diagnostics (`/raijin power`).
    World._last_ctx = ctx
    World._ctx_frame_cache = { key = cache_key, ctx = ctx, t = tnow }
    return ctx
end

-- Detect whether a rotation needs the expensive nearby-enemy scan.
function World.rotation_needs_enemies(rotation)
    if not rotation then return false end
    for _, slot in ipairs(rotation.slots or {}) do
        for _, c in ipairs(slot.conditions or {}) do
            local id = tostring(c.id or "")
            if id:find("enemies", 1, true)
                or id:find("pvp", 1, true)
                or id:find("aoe", 1, true)
                or id == "enemy_players_in_range"
                or id == "nearest_enemy"
                or id == "aura_search" then
                return true
            end
        end
    end
    return false
end

function World.rotation_needs_aura_search(rotation)
    if not rotation then return false end
    for _, slot in ipairs(rotation.slots or {}) do
        for _, c in ipairs(slot.conditions or {}) do
            if c and c.id == "aura_search" then return true end
        end
    end
    return false
end

-- ---- Unit aura probe (token) ----------------------------------------------
-- Returns has, stacks, remaining_seconds for buff or debuff on a unit token.
-- Matches by application spell id AND/OR aura name (case-insensitive). On
-- Ascension, disease application ids can differ from stock WotLK; name match
-- is the reliable second key.
function World.unit_aura_probe(token, kind, spell_id, aura_name)
    if not token or (UnitExists and not UnitExists(token)) then
        return false, 0, 0
    end
    kind = string.lower(tostring(kind or "debuff"))
    local getter = (kind == "buff") and UnitBuff or UnitDebuff
    if not getter then return false, 0, 0 end
    spell_id = tonumber(spell_id) or 0
    aura_name = tostring(aura_name or "")
    local want_lower = (aura_name ~= "") and string.lower(aura_name) or nil
    -- Also resolve name from id when only an id was supplied.
    if spell_id > 0 and not want_lower and GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, spell_id)
        if ok and type(n) == "string" and n ~= "" then
            want_lower = string.lower(n)
        end
    end
    local now_t = (GetTime and GetTime()) or 0
    for i = 1, 40 do
        -- Flexible unpack: private servers vary return count; never assume 11.
        local ok, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 = pcall(getter, token, i)
        if not ok then break end
        local name = a1
        if not name then break end
        local count = tonumber(a4) or 1
        local duration = a6
        local expirationTime = a7
        local sid = tonumber(a11) or tonumber(a10)
        if count < 1 then count = 1 end
        local match = false
        if spell_id > 0 and sid and sid == spell_id then
            match = true
        end
        if not match and want_lower and string.lower(tostring(name)) == want_lower then
            match = true
        end
        -- Partial name fallback (e.g. "Frost Fever" vs "Frost Fever (Rank 2)").
        if not match and want_lower then
            local nl = string.lower(tostring(name))
            if nl:find(want_lower, 1, true) or want_lower:find(nl, 1, true) then
                match = true
            end
        end
        if match then
            local rem = 0
            if type(expirationTime) == "number" and expirationTime > now_t then
                rem = expirationTime - now_t
            elseif type(duration) == "number" and duration > 0 then
                rem = duration
            end
            return true, count, rem
        end
    end
    return false, 0, 0
end

-- Distance 2D player -> token (GUID ObjectPosition preferred). Nil if unknown.
function World.token_distance(token)
    if not token then return nil end
    local center, edge = unit_distances(UnitGUID and UnitGUID(token), token)
    return center, edge
end

-- Optional unit tokens (target/focus/party only). Nameplates are NEVER required
-- and are not used for multi-dot discovery (forbidden / unreliable on Ascension).
local function aura_search_tokens()
    return { "target", "focus", "pet", "targettarget", "focustarget", "pettarget", "mouseover" }
end

-- Find nearby units matching aura present/missing.
-- RUNTIME-FIRST: discovery, hostility, face, and aura notes all live in the
-- inject DLL. Lua never uses mouseover/UnitExists/UnitCanAttack for multi-dot
-- (that made Icy Touch instant only while hovering and 10–20s otherwise).
-- Returns list of {guid, dist, face_err, facing} sorted best-first.
function World.find_aura_search_targets(opts)
    opts = opts or {}
    World.arm_combat_log()
    local state = string.lower(tostring(opts.state or "missing"))
    local spell_id = tonumber(opts.spell_id) or 0
    local aura_name = tostring(opts.name or "")
    if spell_id <= 0 and (aura_name == "" or not aura_name) then
        return {}
    end
    if spell_id <= 0 and aura_name ~= "" and GetSpellInfo then
        -- Name-only: resolve to id when possible; runtime filters by id.
        -- Without id, fall back to empty (cannot key aura table by name alone).
        return {}
    end
    local range = tonumber(opts.range) or 40
    local max_n = tonumber(opts.max_n) or 8
    if max_n < 1 then max_n = 1 end
    if max_n > 16 then max_n = 16 end
    local want_missing = (state == "missing" or state == "absent" or state == "lacks")
    local state_n = want_missing and 0 or 1

    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime()) then
        return {}
    end

    -- Lua-side cache (~80ms) — Engine evaluates aura_search every tick per slot.
    local tnow = (GetTime and GetTime()) or 0
    local ck = tostring(spell_id) .. ":" .. tostring(state_n) .. ":" .. tostring(range)
    local ac = World._aura_search_cache
    if ac and ac.key == ck and (tnow - (ac.t or 0)) < 0.08 and ac.list then
        return ac.list
    end

    local ok, packed = pcall(RaijinLab.RuntimeCall, RaijinLab, "AuraSearch",
        range, spell_id, state_n, max_n)
    if not ok or type(packed) ~= "string" or packed == "" or packed == "0" then
        World._aura_search_cache = { key = ck, t = tnow, list = {} }
        return {}
    end

    local Ex = RaijinLab and RaijinLab.RotationExecutor
    local out = {}
    local first = true
    for part in string.gmatch(packed, "[^|]+") do
        if first then
            first = false
        else
            -- 0xGUID:entry:center:edge:face:hp:mhp
            local guid, entry, center, edge, face, hp, mhp = string.match(part,
                "^(0[xX]%x+):(-?%d+):([%-%d%.]+):([%-%d%.]+):(%d+):(-?%d+):(-?%d+)$")
            if not guid then
                guid, entry, center, edge, face, hp, mhp = string.match(part,
                    "^(%x+):(-?%d+):([%-%d%.]+):([%-%d%.]+):(%d+):(-?%d+):(-?%d+)$")
                if guid then guid = "0x" .. guid end
            end
            if guid then
                if not (Ex and Ex.guid_blacklisted and Ex.guid_blacklisted(guid)) then
                    local d = tonumber(center) or 999
                    local facing = (tonumber(face) or 1) ~= 0
                    out[#out + 1] = {
                        guid = guid,
                        token = nil, -- never client tokens for multi-dot
                        dist = d,
                        face_err = facing and 0 or 1.6,
                        facing = facing,
                        entry = tonumber(entry),
                        hp = tonumber(hp),
                        mhp = tonumber(mhp),
                        edge = tonumber(edge),
                    }
                end
            end
        end
    end
    World._aura_search_cache = { key = ck, t = tnow, list = out }
    return out
end

-- Back-compat single-hit wrapper.
function World.find_aura_search_target(opts)
    local list = World.find_aura_search_targets(opts)
    if not list or #list == 0 then return nil end
    local best = list[1]
    return best.token, best.guid, best.dist
end

-- Actively target a unit for the rotation.
-- NEVER call FrameScript TargetUnit from addon Lua (taints secure path and
-- pops "RaijinLab tainted UNKNOWN()"). Always go through Actions -> runtime
-- TargetGuid (C-origin FrameScript_Execute / SoftHardwareUnlock).
function World.retarget_unit(token)
    if not token then return false end
    if UnitExists and not UnitExists(token) then return false end
    if UnitIsUnit and UnitIsUnit("target", token) then return true end

    local tg = nil
    if UnitGUID then
        local okg, g = pcall(UnitGUID, token)
        if okg then tg = g end
    end
    -- Prefer GUID; fall back to token/name for TargetByName path.
    local A = RaijinLab and RaijinLab.Actions
    if A and A.Target and A.available and A.available() then
        -- Prefer unit TOKEN (nameplateN) - hex GUID TargetUnit is flaky here.
        local ok = not not A.Target(token)
        if not ok and tg then
            ok = not not A.Target(tg)
        end
        if ok then
            if tg and UnitGUID and UnitExists and UnitExists("target") then
                local cg = UnitGUID("target")
                if cg and tostring(cg) == tostring(tg) then return true end
            end
            if UnitIsUnit and UnitIsUnit("target", token) then return true end
            return true
        end
    end
    -- No runtime / failed: do NOT call FrameScript TargetUnit (taint).
    -- CastSpell(guid) still works for multi-dot without a client target swap.
    return false
end

-- Ruthless: if we lack a living attackable target, snap to nearest hostile.
-- Uses OM GUIDs when nameplates/mouseover are absent (Ascension default).
function World.acquire_hostile_target(max_range)
    max_range = tonumber(max_range) or 40
    if UnitExists and UnitExists("target") then
        local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")
        local atk = UnitCanAttack and UnitCanAttack("player", "target")
        if not dead and atk then return false, "have_target" end
    end
    local best_tok, best_guid, best_d = nil, nil, 1e9
    local seen = {}
    for _, token in ipairs(World.iter_unit_tokens()) do
        if UnitExists and UnitExists(token) then
            local guid = UnitGUID and UnitGUID(token)
            if guid and not seen[guid] then
                seen[guid] = true
                if not (UnitIsDeadOrGhost and UnitIsDeadOrGhost(token))
                    and UnitCanAttack and UnitCanAttack("player", token)
                    and not (UnitIsUnit and UnitIsUnit(token, "player")) then
                    local d = World.token_distance(token)
                    if d == nil then d = max_range * 0.5 end
                    if d <= max_range and d < best_d then
                        best_tok, best_guid, best_d = token, guid, d
                    end
                end
            end
        end
    end
    -- OM path: no nameplate/mouseover required.
    if not best_tok and not best_guid then
        local enemies = World.collect_nearby_enemies(max_range)
        for i = 1, #enemies do
            local e = enemies[i]
            local d = tonumber(e.dist_center or e.dist) or 999
            if d <= max_range and d < best_d and e.guid then
                best_d = d
                best_guid = e.guid
                best_tok = e.token
            end
        end
    end
    if best_tok and World.retarget_unit(best_tok) then
        return true, best_tok
    end
    if best_guid then
        local A = RaijinLab and RaijinLab.Actions
        if A and A.Target and A.available and A.available() then
            if A.Target(best_guid) then return true, best_guid end
        end
    end
    if not best_tok and not best_guid then return false, "none" end
    return false, "retarget_fail"
end

-- Refresh ctx target fields after a retarget (so later conditions/range see truth).
function World.sync_ctx_target(ctx)
    if not ctx then return end
    ctx.target_exists = UnitExists and UnitExists("target") or false
    if not ctx.target_exists then
        ctx.target_is_enemy = false
        ctx.target_is_friend = false
        ctx.target_is_dead = false
        ctx.target_hostility = nil
        return
    end
    ctx.target_is_enemy = UnitCanAttack and UnitCanAttack("player", "target") or false
    ctx.target_is_friend = UnitIsFriend and UnitIsFriend("player", "target") or false
    ctx.target_is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") or false
    if UnitHealth and UnitHealthMax then
        local th, tm = UnitHealth("target"), UnitHealthMax("target")
        if tm and tm > 0 then ctx.target_health_pct = 100 * th / tm end
    end
    -- Hostility band
    local band, rnum = nil, nil
    if UnitReaction then
        local ok, r = pcall(UnitReaction, "player", "target")
        if ok then rnum = tonumber(r) end
    end
    if rnum then
        if rnum <= 3 then band = "hostile"
        elseif rnum == 4 then band = "neutral"
        else band = "friendly" end
    elseif ctx.target_is_friend then
        band = "friendly"
    elseif ctx.target_is_enemy then
        band = "hostile"
    else
        band = "neutral"
    end
    ctx.target_reaction = rnum
    ctx.target_hostility = band
    -- Live yards on new target
    local tguid = UnitGUID and UnitGUID("target")
    local center, edge, aoe, _, _, _, pr, tr, precise, _, _, tb =
        unit_distances(tguid, "target")
    if precise then
        ctx.target_distance_center = center
        ctx.target_distance = edge or center
        ctx.target_distance_precise = true
        ctx.player_combat_reach = pr
        ctx.target_combat_reach = tr
        ctx.target_aoe_gap = aoe
        ctx.target_bounding_radius = tb
    end
    -- Refresh target auras for subsequent aura conditions on same slot.
    if scan_auras_rich then
        ctx.target_buffs, ctx.target_buff_stacks, ctx.target_buff_remaining =
            scan_auras_rich("target", false)
        ctx.target_debuffs, ctx.target_debuff_stacks, ctx.target_debuff_remaining =
            scan_auras_rich("target", true)
    end
end

if RaijinLab then
    RaijinLab.World = World
end

return World
