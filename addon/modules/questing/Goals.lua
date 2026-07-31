-- Goals - binds the concrete services to the Director's priority bands.
--
-- This is the seam between "what the bot can do" (the service modules) and "what
-- it should be doing right now" (the Director). Keeping the binding here means
-- the Director stays a pure arbiter with no knowledge of questing, and each
-- service stays unaware it is being arbitrated at all.
--
-- EVERY goal is registered via Director.register_unified so evaluate() and run()
-- share one act(dry) function. A need is not a plan: if dry-mode cannot prove
-- the preconditions that run-mode needs, the goal must not claim the band.

local Goals = {}

local function RL() return RaijinLab end
local function cfgq()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.quest = RaijinLabDB.quest or {}
    return RaijinLabDB.quest
end

local function hp_pct()
    if not (UnitHealth and UnitHealthMax) then return 100 end
    local mx = UnitHealthMax("player") or 0
    if mx <= 0 then return 100 end
    return (UnitHealth("player") or 0) / mx * 100
end

local function in_combat()
    return (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
end

local function poi_known(kind, alt)
    local R = RL()
    local P = R and R.POI
    if not (P and P.nearest and R.ObjectPosition) then return false end
    local px, py, pz = R:ObjectPosition("player")
    if not px then return false end
    if P.nearest(kind, px, py, pz) then return true end
    if alt and P.nearest(alt, px, py, pz) then return true end
    return false
end

local function reg(D, name, band, act, opts)
    if D.register_unified then
        return D.register_unified(name, band, act, opts)
    end
    -- Fallback for ancient Director without unified (should not ship).
    return D.register(name, band,
        function() return act(true) end,
        function() return act(false) end,
        opts)
end

-- Register every standard goal against the Director. Safe to call repeatedly.
function Goals.install(Suite)
    local D = RL() and RL().Director
    if not (D and Suite) then return false end
    local B = D.BANDS

    -- Clear prior install so re-install is idempotent.
    if D.clear then D.clear() end

    -- 1. RECOVER
    reg(D, "recover", B.recover, function(dry)
        local dead = (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) and true or false
        if not dead then
            if dry then return false, 0 end
            return nil
        end
        if dry then return true, 1.0, "dead" end
        local Death = RL().Death
        if Death then
            local st = Death.tick({ goto_fn = Suite._goto_public })
            if st then return st end
        end
        return "death:recovering"
    end)

    -- 2. SURVIVE
    reg(D, "survive", B.survive, function(dry)
        if not in_combat() then
            if dry then return false, 0 end
            return nil
        end
        local hp = hp_pct()
        local flee_at = cfgq().flee_hp or 20
        if hp > flee_at then
            if dry then return false, 0 end
            return nil
        end
        local urg = math.min(1, (flee_at - hp) / math.max(1, flee_at) + 0.5)
        local why = "hp " .. math.floor(hp) .. "%"
        if dry then return true, urg, why end
        return (Suite._flee_public and Suite._flee_public()) or "flee"
    end)

    -- 3. COMBAT - hold the slot while fighting / have attackable target.
    -- run() always returns a status when dry said active (never nil).
    reg(D, "combat", B.combat, function(dry)
        local fighting = in_combat()
        local has_target = UnitExists and UnitExists("target")
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target"))
            and UnitCanAttack and UnitCanAttack("player", "target")
        if not (fighting or has_target) then
            if dry then return false, 0 end
            return nil
        end
        local urg = 0.5 + (100 - hp_pct()) / 200
        local why = fighting and "in combat" or "target"
        if dry then return true, urg, why end
        local st = Suite._combat_public and Suite._combat_public()
        return st or "combat:hold"
    end)

    -- 4. REST - only when Rest.should_rest proves a real need AND we are safe.
    reg(D, "rest", B.rest, function(dry)
        if cfgq().use_rest == false then
            if dry then return false, 0 end
            return nil
        end
        local Rest = RL().Rest
        if not Rest then
            if dry then return false, 0 end
            return nil
        end
        local ok, why = Rest.should_rest()
        if not ok then
            if dry then return false, 0 end
            return nil
        end
        local hp = hp_pct()
        local urg = math.min(1, (100 - hp) / 100 + 0.2)
        if dry then return true, urg, why end
        local st = Rest.tick and Rest.tick({ stop_fn = Suite._stop_public })
        return st or "rest:tick"
    end)

    -- 5. ERRANDS - need AND reachable plan (merchant open or remembered POI).
    reg(D, "errand", B.errand, function(dry)
        local V = RL().Vendor
        if V and cfgq().use_vendor ~= false then
            local need, why, urgency = V.needs_vendor()
            local plan = false
            if need then
                if V.has_plan_k then
                    local k = V.has_plan_k(why)
                    plan = (type(k) == "table" and k.state == "yes")
                        or (k == true)
                else
                    plan = V.at_merchant and V.at_merchant()
                        or poi_known((why == "durability") and "repair" or "vendor", "vendor")
                end
            end
            if need and plan then
                if dry then
                    return true, math.max(0.3, urgency or 0.5), "vendor:" .. tostring(why)
                end
                return (Suite.vendor_trip and Suite.vendor_trip()) or "vendor:trip"
            end
        end
        local T = RL().Trainer
        if T then
            local need, why = T.needs_training()
            if need and poi_known("trainer") then
                if dry then return true, 0.35, "train:" .. tostring(why) end
                return (Suite.trainer_trip and Suite.trainer_trip()) or "train:trip"
            end
        end
        if dry then return false, 0 end
        return nil
    end)

    -- 6a. GATHER - opportunistic ONLY. Never steals a live turn-in / accept.
    -- Live: gather urg 0.33 flipped progress mid-walk to st=10 NPC (more_urgent),
    -- then master death left nav idle forever. Cap urgency below turnin/accept.
    reg(D, "gather", B.progress, function(dry)
        if cfgq().use_gather == false then
            if dry then return false, 0 end
            return nil
        end
        -- Quest work always outranks herbs. Live turn-in/?/? or a complete log
        -- entry means gather must not claim the progress band.
        local QL = RL().QuestLog
        if QL and QL.first_complete and QL.first_complete() then
            if dry then return false, 0, "defer_turnin" end
            return nil
        end
        local QOM = RL().QuestOM
        if QOM and QOM.nearest_giver then
            local g = QOM.nearest_giver("complete") or QOM.nearest_giver("available")
            if g and g.guid and (not g.dist or g.dist <= 80) then
                if dry then return false, 0, "defer_giver" end
                return nil
            end
        end
        local G = RL().Gatherer
        if not (G and G.find_nearest_node) then
            if dry then return false, 0 end
            return nil
        end
        if in_combat() then
            if dry then return false, 0 end
            return nil
        end
        local V = RL().Vendor
        if V and V.free_slots and V.free_slots() <= 0 then
            if dry then return false, 0, "bags full" end
            return nil
        end
        local ok, node = pcall(G.find_nearest_node)
        if not (ok and node and node.dist) then
            if dry then return false, 0 end
            return nil
        end
        local radius = cfgq().gather_radius or 40
        if node.dist > radius then
            if dry then return false, 0 end
            return nil
        end
        -- Cap well below turnin urgency so more_urgent can never steal questing.
        local urg = 0.05 + 0.15 * (1 - node.dist / radius)
        local why = node.prof or "node"
        if dry then return true, urg, why end
        return (Suite.gather_step and Suite.gather_step()) or "gather:step"
    end, { min_commit = 12.0 })

    -- 6b. PROGRESS - questing. Urgency rises when there is real work to do so
    -- same-band gather cannot interrupt a walk to a ! or ?.
    reg(D, "progress", B.progress, function(dry)
        local urg, why = 0.40, "questing"
        local QL = RL().QuestLog
        if QL and QL.first_complete and QL.first_complete() then
            urg, why = 0.90, "turnin_ready"
        else
            local QOM = RL().QuestOM
            if QOM and QOM.nearest_giver then
                local gt = QOM.nearest_giver("complete")
                local ga = QOM.nearest_giver("available")
                if gt and gt.guid and (not gt.dist or gt.dist <= 80) then
                    urg, why = 0.90, "turnin_live"
                elseif ga and ga.guid and (not ga.dist or ga.dist <= 80) then
                    urg, why = 0.80, "accept_live"
                end
            end
        end
        if dry then return true, urg, why end
        return (Suite.progress_step and Suite.progress_step()) or "quest:progress"
    end, { min_commit = 12.0 })

    return true
end

if RaijinLab then RaijinLab.Goals = Goals end
return Goals
