-- Combat spatial brain: engage / disengage / reposition / PvE<->PvP posture.

local Brain = {}

local function dist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Brain.analyze()
    local World = RaijinLab.World
    local ctx = World and World.build_context() or {}
    local cfg = (RaijinLabDB and RaijinLabDB.combat) or {}
    local posture = "pve"
    if cfg.pvp_mode == "pvp" or (cfg.pvp_mode ~= "pve" and (ctx.pvp_flagged or (ctx.enemy_players_in_range or 0) > 0)) then
        posture = "pvp"
    end

    local state = {
        posture = posture,
        in_combat = ctx.in_combat,
        health_pct = ctx.health_pct or 100,
        enemies_melee = ctx.enemies_in_8 or 0,
        enemies_near = ctx.enemies_in_40 or 0,
        enemy_players = ctx.enemy_players_in_range or 0,
        has_target = ctx.target_exists and ctx.target_is_enemy and not ctx.target_is_dead,
        target_distance = ctx.target_distance or 999,
        recommendation = "idle",
    }

    local disengage_hp = cfg.disengage_hp or 25
    if state.health_pct <= disengage_hp and state.in_combat then
        state.recommendation = "disengage"
    elseif posture == "pvp" and state.enemy_players > 0 and state.health_pct < 40 then
        state.recommendation = "disengage"
    elseif state.enemies_melee >= 4 and state.health_pct < 60 then
        state.recommendation = "reposition"
    elseif not state.has_target and state.enemies_near > 0 and (cfg.engage ~= false) then
        state.recommendation = "engage"
    elseif state.has_target and state.target_distance > 30 then
        state.recommendation = "close_gap"
    elseif state.has_target then
        state.recommendation = "press"
    end
    return state
end

function Brain.act(state)
    state = state or Brain.analyze()
    local Nav = RaijinLab.Nav
    local World = RaijinLab.World
    local pp = World and World.player_pos()

    if state.recommendation == "disengage" and pp and Nav then
        -- Step backward along facing inverse (simple kite vector)
        local facing = 0
        if GetPlayerFacing then facing = GetPlayerFacing() end
        local back = facing + math.pi
        local gx = pp.x + math.cos(back) * 12
        local gy = pp.y + math.sin(back) * 12
        Nav.request_move({ x = gx, y = gy, z = pp.z }, { mounted = false })
        if RaijinLab.Actions then RaijinLab.Actions.ClearTarget() end
        return state
    end

    if state.recommendation == "reposition" and pp and Nav then
        local facing = GetPlayerFacing and GetPlayerFacing() or 0
        local side = facing + (math.pi / 2)
        Nav.request_move({ x = pp.x + math.cos(side) * 8, y = pp.y + math.sin(side) * 8, z = pp.z }, {})
        return state
    end

    if state.recommendation == "engage" then
        -- Natural target acquisition ONLY for hostiles that are attacking us.
        -- NEVER touch selection while rotation multi-dot is active (GUID cast
        -- with acquire off must leave the client's target alone completely).
        if RaijinLabDB and RaijinLabDB.rotation_enabled then
            local Ex = RaijinLab.RotationExecutor
            local multi = Ex and Ex._last_cast and Ex._last_cast.guid
                and (GetTime and (GetTime() - (Ex._last_cast.t or 0)) < 2.5)
            if multi then return state end
            -- Any aura_search-driven cast path: do not auto-TargetNearest.
            if Ex and Ex._last_action and Ex._last_action.aura_search_hit then
                return state
            end
        end
        -- If we already have a living attackable target, leave it alone.
        if UnitExists and UnitExists("target")
            and UnitCanAttack and UnitCanAttack("player", "target")
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
            return state
        end
        local enemies = World and World.collect_nearby_enemies and World.collect_nearby_enemies(40) or {}
        local best, bestD
        for i = 1, #enemies do
            local u = enemies[i]
            if not u or not u.guid then
                -- skip
            else
                local attacking = false
                if World.unit_is_attacking_player then
                    attacking = World.unit_is_attacking_player(u.token or u.guid)
                end
                -- Strict: only units actually targeting the player (not "nearby
                -- in combat"). Heals/buffs on us never count as attacking.
                if attacking then
                    local d = tonumber(u.dist_center or u.dist) or 999
                    if not bestD or d < bestD then best, bestD = u, d end
                end
            end
        end
        if best and best.guid and RaijinLab.Actions and RaijinLab.Actions.Target then
            RaijinLab.Actions.Target(best.guid)
        end
        return state
    end

    if state.recommendation == "close_gap" and pp and Nav then
        local tx, ty, tz = RaijinLab:ObjectPosition("target")
        if tx then
            Nav.request_move({ x = tx, y = ty, z = tz }, {})
        end
        return state
    end

    -- press: let rotation executor handle abilities
    return state
end

function Brain.tick()
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    if not RaijinLabDB or not RaijinLabDB.modules or not RaijinLabDB.modules.combat then
        return
    end
    local st = Brain.analyze()
    Brain.act(st)
    if RaijinLab.Nav then RaijinLab.Nav.tick(2.0) end
    Brain.last = st
end

function Brain.start()
    Brain.stop()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    RaijinLabDB.modules.combat = true
    if C_Timer and C_Timer.NewTicker then
        Brain._t = C_Timer.NewTicker(0.25, Brain.tick)
    else
        local f = CreateFrame("Frame")
        local a = 0
        f:SetScript("OnUpdate", function(_, e)
            a = a + e
            if a >= 0.25 then a = 0; Brain.tick() end
        end)
        Brain._f = f
    end
    print("|cff7ec8e3RaijinLab|r combat brain |cff55ff55ON|r")
end

function Brain.stop()
    if Brain._t then Brain._t:Cancel(); Brain._t = nil end
    if Brain._f then Brain._f:SetScript("OnUpdate", nil); Brain._f = nil end
    if RaijinLabDB and RaijinLabDB.modules then RaijinLabDB.modules.combat = false end
    print("|cff7ec8e3RaijinLab|r combat brain |cffff5555OFF|r")
end

if RaijinLab then RaijinLab.CombatBrain = Brain end
return Brain
