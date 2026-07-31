-- Grinding: radius auto-fight + user-defined route waypoints.

local Grinder = {}

local function dist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Grinder.center()
    local g = RaijinLabDB and RaijinLabDB.grind
    if g and g.center then return g.center end
    local World = RaijinLab.World
    local pp = World and World.player_pos()
    if pp then
        RaijinLabDB = RaijinLabDB or {}
        RaijinLabDB.grind = RaijinLabDB.grind or {}
        if not RaijinLabDB.grind.center then
            RaijinLabDB.grind.center = { x = pp.x, y = pp.y, z = pp.z }
        end
        return RaijinLabDB.grind.center
    end
    return nil
end

function Grinder.add_waypoint()
    local World = RaijinLab.World
    local pp = World and World.player_pos()
    if not pp then return end
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.grind = RaijinLabDB.grind or { route = {} }
    RaijinLabDB.grind.route = RaijinLabDB.grind.route or {}
    local r = RaijinLabDB.grind.route
    r[#r + 1] = { x = pp.x, y = pp.y, z = pp.z }
    print(string.format("|cff7ec8e3RaijinLab|r grind waypoint #%d at (%.1f, %.1f, %.1f)", #r, pp.x, pp.y, pp.z))
end

function Grinder.clear_route()
    if RaijinLabDB and RaijinLabDB.grind then
        RaijinLabDB.grind.route = {}
        print("|cff7ec8e3RaijinLab|r grind route cleared")
    end
end

function Grinder.pick_target(radius)
    local World = RaijinLab.World
    local pp = World and World.player_pos()
    local c = Grinder.center()
    if not pp or not c then return nil end
    radius = radius or (RaijinLabDB.grind and RaijinLabDB.grind.radius) or 40
    local units = World.collect_units_from_tokens()
    local best, bestD
    for _, u in ipairs(units) do
        if u.is_enemy and not u.is_dead and not u.is_player then
            local dc = dist(c.x, c.y, c.z, u.x, u.y, u.z)
            if dc <= radius then
                local d = dist(pp.x, pp.y, pp.z, u.x, u.y, u.z)
                if not bestD or d < bestD then best, bestD = u, d end
            end
        end
    end
    return best
end

function Grinder.tick()
    if not RaijinLabDB or not RaijinLabDB.modules or not RaijinLabDB.modules.grind then return end
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    local Nav = RaijinLab.Nav
    if Nav then Nav.tick(2.0) end

    local radius = (RaijinLabDB.grind and RaijinLabDB.grind.radius) or 40
    local t = Grinder.pick_target(radius)
    if t then
        if RaijinLab.Actions then
            if t.guid then RaijinLab.Actions.Target(t.guid)
            elseif t.token then RaijinLab.Actions.Target(t.token) end
        end
        -- Close gap
        local World = RaijinLab.World
        local pp = World and World.player_pos()
        if pp and t.x and dist(pp.x, pp.y, pp.z, t.x, t.y, t.z) > 5 and Nav then
            Nav.request_move({ x = t.x, y = t.y, z = t.z }, {})
        end
        -- Rotation handles damage if enabled; otherwise start attack via runtime
        if RaijinLab.Actions and UnitExists and UnitExists("target") then
            RaijinLab.Actions.Attack()
        end
        return
    end

    -- No target: patrol route or return to center
    local route = RaijinLabDB.grind.route or {}
    if #route > 0 then
        Grinder._ri = Grinder._ri or 1
        if Grinder._ri > #route then Grinder._ri = 1 end
        local wp = route[Grinder._ri]
        local World = RaijinLab.World
        local pp = World and World.player_pos()
        if pp and dist(pp.x, pp.y, pp.z, wp.x, wp.y, wp.z) < 4 then
            Grinder._ri = Grinder._ri + 1
        elseif Nav then
            Nav.request_move(wp, {})
        end
    else
        local c = Grinder.center()
        local World = RaijinLab.World
        local pp = World and World.player_pos()
        if c and pp and dist(pp.x, pp.y, pp.z, c.x, c.y, c.z) > radius * 0.85 and Nav then
            Nav.request_move(c, {})
        end
    end
end

function Grinder.start()
    Grinder.stop()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    RaijinLabDB.modules.grind = true
    Grinder.center() -- pin center on start if missing
    if C_Timer and C_Timer.NewTicker then
        Grinder._t = C_Timer.NewTicker(0.4, Grinder.tick)
    else
        local f = CreateFrame("Frame")
        local a = 0
        f:SetScript("OnUpdate", function(_, e) a = a + e; if a >= 0.4 then a = 0; Grinder.tick() end end)
        Grinder._f = f
    end
    print("|cff7ec8e3RaijinLab|r grinding |cff55ff55ON|r radius=" .. tostring((RaijinLabDB.grind or {}).radius or 40))
end

function Grinder.stop()
    if Grinder._t then Grinder._t:Cancel(); Grinder._t = nil end
    if Grinder._f then Grinder._f:SetScript("OnUpdate", nil); Grinder._f = nil end
    if RaijinLabDB and RaijinLabDB.modules then RaijinLabDB.modules.grind = false end
    print("|cff7ec8e3RaijinLab|r grinding |cffff5555OFF|r")
end

if RaijinLab then RaijinLab.Grinder = Grinder end
return Grinder
