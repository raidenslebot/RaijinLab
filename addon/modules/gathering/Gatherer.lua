-- Gathering module: herbalism, mining, fishing, woodcutting (+ Ascension customs via entry lists).

local Gatherer = {}

-- Representative gather node object type = GameObject (5). Entries can be extended in SV.
local DEFAULT_ENTRIES = {
    herbalism = {
        -- classic herbs (subset; full DB can live in SavedVariables)
        1617, 1618, 1619, 1620, 1621, 1622, 1623, 1624, 1628, 2041, 2042, 2043, 2044, 2045, 2046,
        2866, 142140, 142141, 142142, 142143, 142144, 142145, 176583, 176584, 176586, 176587, 176588, 176589,
    },
    mining = {
        1731, 1732, 1733, 1734, 1735, 2040, 2047, 3763, 3764, 2055, 103711, 103713, 165658,
        175404, 176645, 181555, 181556, 181557, 185557,
    },
    woodcutting = {
        -- Ascension / custom wood nodes can be added via SV; placeholder classic chests/trees entries
        2039, 2843, 2844, 2849, 3714, 3715, 20691,
    },
    fishing = {}, -- pools handled separately
}

-- Herbalism/mining/woodcutting only need a node in range, so they default ON.
-- FISHING is different: it needs a fishing pole equipped and a body of water, and
-- casting it without either makes the client demand a pole the moment the module
-- is switched on. It is therefore strictly OPT-IN.
Gatherer.OPT_IN = { fishing = true }

-- Three-valued: opt-in professions that were never set are NO (do not act),
-- not "true because defaults". That false-true is what made fishing cast the
-- moment gather was enabled with no user opinion recorded.
function Gatherer.profession_enabled_k(prof)
    local Kn = RaijinLab and RaijinLab.Know
    local g = RaijinLabDB and RaijinLabDB.gather
    local p = g and g.professions
    if Gatherer.OPT_IN[prof] then
        if not p or p[prof] == nil then
            if Kn then return Kn.no("opt_in_unset") end
            return false
        end
        if p[prof] == true then
            if Kn then return Kn.yes(true, "opt_in_on") end
            return true
        end
        if Kn then return Kn.no("opt_in_off") end
        return false
    end
    if not p then
        if Kn then return Kn.yes(true, "default_on") end
        return true
    end
    if p[prof] == false then
        if Kn then return Kn.no("explicit_off") end
        return false
    end
    if Kn then return Kn.yes(true, "default_or_on") end
    return true
end

function Gatherer.profession_enabled(prof)
    local k = Gatherer.profession_enabled_k(prof)
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

function Gatherer.entries_for(prof)
    local custom = RaijinLabDB and RaijinLabDB.gather and RaijinLabDB.gather.entries
    if custom and custom[prof] then return custom[prof] end
    return DEFAULT_ENTRIES[prof] or {}
end

function Gatherer.find_nearest_node()
    local World = RaijinLab.World
    local pp = World and World.player_pos()
    if not pp then return nil end

    local wanted = {}
    for _, prof in ipairs({ "herbalism", "mining", "woodcutting" }) do
        if Gatherer.profession_enabled(prof) then
            for _, id in ipairs(Gatherer.entries_for(prof)) do
                wanted[id] = prof
            end
        end
    end

    local best, bestD
    -- Prefer OM gameobjects
    if RaijinLab.RuntimeCall then
        local n = tonumber(RaijinLab:RuntimeCall("GetGameObjectCount") or 0) or 0
        for i = 1, math.min(n, 200) do
            local guid = RaijinLab:RuntimeCall("GetGameObjectWithIndex", i)
            if guid then
                local entry = tonumber(RaijinLab:RuntimeCall("ObjectId", guid) or 0) or 0
                local prof = wanted[entry]
                if prof then
                    local x, y, z = RaijinLab:ObjectPosition(guid)
                    if x then
                        local dx, dy, dz = x - pp.x, y - pp.y, z - pp.z
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if not bestD or d < bestD then
                            bestD = d
                            best = { guid = guid, entry = entry, prof = prof, x = x, y = y, z = z, dist = d }
                        end
                    end
                end
            end
        end
        -- Fallback: scan all objects
        if not best then
            local objs = World.collect_from_om()
            for _, o in ipairs(objs) do
                local prof = wanted[o.entry or 0]
                if prof and o.type == 5 then
                    if not bestD or o.dist < bestD then
                        bestD = o.dist
                        best = { guid = o.guid, entry = o.entry, prof = prof, x = o.x, y = o.y, z = o.z, dist = o.dist }
                    end
                end
            end
        end
    end
    return best
end

-- Is a fishing pole actually equipped? Casting without one is what produces the
-- "you need a fishing pole" spam - so this is a hard precondition, never a hint.
-- We only ever CHECK; equipping gear is the player's decision, not ours.
function Gatherer.has_fishing_pole_k()
    local Kn = RaijinLab and RaijinLab.Know
    if not GetInventoryItemLink then
        if Kn then return Kn.unknown("no_inv_api") end
        return nil
    end
    local ok, link = pcall(GetInventoryItemLink, "player", 16)
    if not ok then
        if Kn then return Kn.unknown("inv_error") end
        return nil
    end
    if not link then
        if Kn then return Kn.no("empty_mainhand") end
        return false
    end
    if GetItemInfo then
        local ok2, _, _, _, _, _, _, isub = pcall(GetItemInfo, link)
        if ok2 then
            local sub = tostring(isub or ""):lower()
            if sub:find("fishing", 1, true) then
                if Kn then return Kn.yes(true, "item_subclass") end
                return true
            end
            local nm = tostring(link):lower()
            if nm:find("fishing pole", 1, true) or nm:find("fishing rod", 1, true) then
                if Kn then return Kn.yes(true, "item_name") end
                return true
            end
            if Kn then return Kn.no("not_pole") end
            return false
        end
    end
    local hit = tostring(link):lower():find("fishing", 1, true) ~= nil
    if Kn then return hit and Kn.yes(true, "link_heuristic") or Kn.no("link_heuristic") end
    return hit
end

function Gatherer.has_fishing_pole()
    local k = Gatherer.has_fishing_pole_k()
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assume then
        return Kn.assume(k, false, "gather:no_pole_when_unknown")
    end
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

-- A fishing POOL we can actually see. Pools are game objects like any other node,
-- so they are only detectable when the user has supplied their entry ids
-- (RaijinLabDB.gather.entries.fishing) - there is no built-in list.
function Gatherer.fishing_pool_near_k()
    local Kn = RaijinLab and RaijinLab.Know
    local ids = Gatherer.entries_for("fishing")
    if not ids or #ids == 0 then
        if Kn then return Kn.unknown("no_pool_entries") end
        return nil
    end
    local wanted = {}
    for _, id in ipairs(ids) do wanted[id] = true end
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om then
        if Kn then return Kn.unknown("no_om") end
        return nil
    end
    for i = 1, #(om.gameobjects or {}) do
        local g = om.gameobjects[i]
        if g and wanted[g.Id or 0] then
            if Kn then return Kn.yes(true, "pool_seen") end
            return true
        end
    end
    if Kn then return Kn.no("no_pool_in_om") end
    return false
end

function Gatherer.fishing_pool_near()
    local k = Gatherer.fishing_pool_near_k()
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assume then
        return Kn.assume(k, false, "gather:no_pool_when_unknown")
    end
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

function Gatherer.tick_fishing()
    -- Every one of these is a REASON NOT TO CAST, and each was missing before:
    -- the old version fired "Fishing" whenever no herb/ore node happened to be in
    -- range, which is why enabling the module instantly demanded a pole.
    if not Gatherer.profession_enabled("fishing") then return false end
    if not Gatherer.has_fishing_pole() then return false, "no_pole" end
    if UnitChannelInfo and UnitChannelInfo("player") then return true end   -- already fishing
    if IsSwimming and IsSwimming() then return false, "swimming" end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return false, "combat" end
    -- Need somewhere to fish: either a pool we can see, or the user explicitly
    -- telling us to fish here.
    local cfgg = (RaijinLabDB and RaijinLabDB.gather) or {}
    if not (Gatherer.fishing_pool_near() or cfgg.prefer_fishing) then
        return false, "no_pool"
    end
    local spell = cfgg.fishing_spell or "Fishing"
    if RaijinLab.Actions then
        RaijinLab.Actions.CastSpellByName(spell)
        return true
    end
    return false
end

function Gatherer.tick()
    if not RaijinLabDB or not RaijinLabDB.modules or not RaijinLabDB.modules.gather then return end
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    -- NAV CONTENTION GUARD. Nav has a single active path. When the questing engine
    -- is running, the Director already gathers opportunistically through
    -- Suite.gather_step (which uses the full movement stack), so this standalone
    -- ticker must NOT also drive Nav - two owners issuing different destinations
    -- on alternating ticks makes the character vibrate in place instead of moving.
    if RaijinLabDB.modules.quest then return end

    -- Empty-scan backoff: do not thrash OM + fishing probes every 0.5s for minutes
    -- when there is simply nothing here.
    local F = RaijinLab and RaijinLab.Fail
    if F and F.may_retry then
        local ok = F.may_retry("gather:empty")
        if not ok then return end
    end

    local Nav = RaijinLab.Nav
    if Nav then Nav.tick(2.5) end

    if Gatherer.profession_enabled("fishing") and (RaijinLabDB.gather or {}).prefer_fishing then
        local okf, whyf = Gatherer.tick_fishing()
        if okf == false and whyf == "no_pole" and F and F.permanent then
            F.permanent("gather:no_pole", "no fishing pole",
                { "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE" })
        end
        return
    end

    local node = Gatherer.find_nearest_node()
    if not node then
        Gatherer._empty_n = (Gatherer._empty_n or 0) + 1
        if Gatherer._empty_n >= 8 and F and F.record then
            F.record("gather:empty", F.TRANSIENT or "transient", {
                why = "no_nodes",
                backoff = 20,
            })
            Gatherer._empty_n = 0
            local Ou = RaijinLab and RaijinLab.Outcomes
            if Ou and Ou.begin then
                local id = Ou.begin("gather", { why = "empty" })
                Ou.settle(id, -0.4, "empty_scan_streak")
            end
        end
        -- Nothing to gather here. That is NOT a reason to fish - the old code fell
        -- through to tick_fishing() on every empty scan, so switching the module on
        -- anywhere without a herb in range immediately tried to fish. Fishing now
        -- only happens when it is explicitly wanted AND there is water to fish in.
        if Gatherer.profession_enabled("fishing") then Gatherer.tick_fishing() end
        return
    end
    Gatherer._empty_n = 0
    if F and F.clear then F.clear("gather:empty") end

    if node.dist and node.dist > 5 then
        -- No click-to-move fallback. CTM is forbidden project-wide, and a
        -- fallback that only runs when Nav is missing is still a path that ships
        -- it. If steering is unavailable we would rather not move than move the
        -- one way we are not allowed to.
        if Nav then
            Nav.request_move({ x = node.x, y = node.y, z = node.z }, {})
        end
    else
        -- Interact
        if RaijinLab.Actions then
            RaijinLab.Actions.Interact(node.guid)
        elseif RaijinLab.ObjectInteract then
            RaijinLab:ObjectInteract(node.guid)
        end
    end
    Gatherer.last = node
end

function Gatherer.start()
    Gatherer.stop()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    RaijinLabDB.modules.gather = true
    if C_Timer and C_Timer.NewTicker then
        Gatherer._t = C_Timer.NewTicker(0.5, Gatherer.tick)
    else
        local f = CreateFrame("Frame")
        local a = 0
        f:SetScript("OnUpdate", function(_, e) a = a + e; if a >= 0.5 then a = 0; Gatherer.tick() end end)
        Gatherer._f = f
    end
    print("|cff7ec8e3RaijinLab|r gathering |cff55ff55ON|r")
end

function Gatherer.stop()
    if Gatherer._t then Gatherer._t:Cancel(); Gatherer._t = nil end
    if Gatherer._f then Gatherer._f:SetScript("OnUpdate", nil); Gatherer._f = nil end
    if RaijinLabDB and RaijinLabDB.modules then RaijinLabDB.modules.gather = false end
    print("|cff7ec8e3RaijinLab|r gathering |cffff5555OFF|r")
end

if RaijinLab then RaijinLab.Gatherer = Gatherer end
return Gatherer
