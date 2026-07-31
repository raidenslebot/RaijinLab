-- Vision - professional, budgeted world overlays for what the bot believes.
--
-- 3.3.5 can only project short 2D line segments (no filled polys, no true 3D
-- debug mesh). Within that constraint: thin path ribbon, single goal marker,
-- optional sparse diagnostics. Grid carpet default OFF.
--
--   /raijin show              status
--   /raijin show path|target|grid|search|controller|all|off

local V = {}

V.LAYERS = { "grid", "path", "search", "target", "controller" }

V.GRID_RADIUS   = 36
V.GRID_STRIDE   = 3
V.MAX_SEGMENTS  = 120
V.SEARCH_TOP    = 8

V.COLOR = {
    [1] = { 0.15, 0.75, 0.28 },
    [2] = { 0.90, 0.65, 0.10 },
    [3] = { 0.95, 0.15, 0.15 },
    [4] = { 0.18, 0.45, 0.90 },
    [5] = { 0.90, 0.45, 0.08 },
}

-- EVERY LAYER ON BY DEFAULT. This is an explicit product requirement, not a
-- taste call: rendering is the only way to see what the bot believes, and it was
-- asked for as "default all on". Shipping layers dark was doubly wrong while the
-- renderer itself was broken - the line drawer used Legion-era CreateLine APIs
-- that do not exist on 3.3.5, so nothing had EVER drawn. Turning layers off for
-- performance while nothing rendered saved nothing and hid everything.
--
-- Cost is bounded elsewhere and honestly: MAX_SEGMENTS caps segments per frame,
-- and the Debug tab toggles let a layer be turned off deliberately. An explicit
-- off still survives reload (cfg only fills nils).
V.DEFAULT_ON = {
    path = true, target = true, intent = true,
    grid = true, search = true, controller = true,
}

local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    local c = RaijinLabDB.vision
    if not c then c = {}; RaijinLabDB.vision = c end
    if c._vdefaults ~= 5 then
        for l, on in pairs(V.DEFAULT_ON) do c[l] = on end
        c._vdefaults = 5
    end
    for i = 1, #V.LAYERS do
        local l = V.LAYERS[i]
        if c[l] == nil then c[l] = V.DEFAULT_ON[l] and true or false end
    end
    return c
end

function V.enabled(layer) return cfg()[layer] and true or false end
function V.set(layer, on) cfg()[layer] = on and true or false; V.refresh() end
function V.any()
    for _, l in ipairs(V.LAYERS) do if V.enabled(l) then return true end end
    return false
end

local function d() return RaijinLab and RaijinLab.drawing end
local function ppos()
    local R = RaijinLab
    if not (R and R.ObjectPosition) then return nil end
    return R:ObjectPosition("player")
end

V._segments = 0

local function line(dr, x1, y1, z1, x2, y2, z2)
    if V._segments >= V.MAX_SEGMENTS then return false end
    V._segments = V._segments + 1
    if dr.Line then dr:Line(x1, y1, z1, x2, y2, z2) end
    return true
end

-- Micro-dot (two 0.35 yd ticks).
local function dot(dr, x, y, z, s)
    s = s or 0.35
    if not line(dr, x - s, y, z, x + s, y, z) then return false end
    return line(dr, x, y - s, z, x, y + s, z)
end

-- Diamond goal marker (reads as a waypoint, not a tile).
local function diamond(dr, x, y, z, r)
    r = r or 1.1
    local z0 = (z or 0) + 0.25
    if not line(dr, x, y - r, z0, x + r, y, z0) then return false end
    if not line(dr, x + r, y, z0, x, y + r, z0) then return false end
    if not line(dr, x, y + r, z0, x - r, y, z0) then return false end
    return line(dr, x - r, y, z0, x, y - r, z0)
end

-- Ring via polyline (Circle if available).
local function ring(dr, x, y, z, radius, segs)
    segs = segs or 16
    if dr.Circle then
        dr:Circle(x, y, z, radius)
        return true
    end
    local z0 = (z or 0) + 0.2
    local prevx, prevy = x + radius, y
    for i = 1, segs do
        local a = (i / segs) * math.pi * 2
        local nx, ny = x + math.cos(a) * radius, y + math.sin(a) * radius
        if not line(dr, prevx, prevy, z0, nx, ny, z0) then return false end
        prevx, prevy = nx, ny
    end
    return true
end

-- ---- layers ---------------------------------------------------------------

function V.draw_grid(dr, px, py, pz)
    local NG = RaijinLab and RaijinLab.NavGrid
    if not (NG and NG.at) then return end
    local map = NG.map_name and NG.map_name()
    if not map then return end
    local res = 4.0
    local t = NG.load and NG.load(map, NG.tile_of and NG.tile_of(px, py))
    if t and t.res then res = t.res end
    local step = res * math.max(1, V.GRID_STRIDE)
    local r = V.GRID_RADIUS
    -- Only hazards (not walk carpet): steep/wall/water/structure
    for gx = -r, r, step do
        for gy = -r, r, step do
            if gx * gx + gy * gy <= r * r then
                local x, y = px + gx, py + gy
                local code, h = NG.at(x, y, map)
                if code and code >= 2 and code <= 5 then
                    local c = V.COLOR[code]
                    if c and dr.SetColorRaw then
                        dr:SetColorRaw(c[1], c[2], c[3], 0.65)
                    end
                    if not dot(dr, x, y, (h or pz) + 0.1, 0.4) then return end
                end
            end
        end
    end
end

function V.draw_path(dr)
    local N = RaijinLab and RaijinLab.Navigator
    local a = N and N._active
    if not a then return end
    local px, py, pz = ppos()
    if not px then return end
    local nodes = {}
    if a.path then for i = a.idx or 1, #a.path do nodes[#nodes + 1] = a.path[i] end end
    if a.goal then nodes[#nodes + 1] = a.goal end
    if #nodes == 0 then return end

    -- Soft cyan->green ribbon
    if dr.SetColorRaw then dr:SetColorRaw(0.15, 0.95, 0.55, 0.95) end
    if dr.SetWidth then dr:SetWidth(2) end
    local prevx, prevy, prevz = px, py, pz + 0.3
    for _, n in ipairs(nodes) do
        local nz = (n.z or pz) + 0.3
        if not line(dr, prevx, prevy, prevz, n.x, n.y, nz) then break end
        prevx, prevy, prevz = n.x, n.y, nz
    end
    -- Subtle waypoint dots (not crosses)
    if dr.SetColorRaw then dr:SetColorRaw(0.25, 0.85, 1.0, 0.85) end
    for i = 1, #nodes - 1 do
        local n = nodes[i]
        if not dot(dr, n.x, n.y, (n.z or pz) + 0.35, 0.5) then break end
    end
end

-- WHERE IT IS TRYING TO GO, even with no route to draw.
--
-- draw_path returns immediately unless Navigator._active exists, so during
-- planning, parking, or any gap between goals the screen showed NOTHING - and
-- those are exactly the moments the answer is wanted ("i have no idea where it
-- is going... all i see is it picking random directions"). Intent survives the
-- absence of a route: the goal we asked for, the search leg we committed to,
-- and the database point we are walking at.
--
-- Drawn as a vertical beacon plus a straight line from the feet, so a glance
-- says both WHERE and HOW FAR. Deliberately a different colour from the path
-- ribbon: this is desire, not a planned route.
function V.draw_intent(dr, px, py, pz)
    local N = RaijinLab and RaijinLab.Navigator
    local S = RaijinLab and RaijinLab.QuestSuite
    if not (N or S) then return end

    local goal = (N and (N._want_goal or N._pf_goal)) or nil
    local gx, gy, gz
    if goal and goal.x then gx, gy, gz = goal.x, goal.y, goal.z end
    if not gx and S and S._search then
        for _, st in pairs(S._search) do
            if st and st.tx then gx, gy, gz = st.tx, st.ty, st.tz; break end
        end
    end
    if not gx then return end
    gz = gz or pz

    -- amber line: intent, not a route
    if dr.SetColorRaw then dr:SetColorRaw(1.0, 0.75, 0.15, 0.85) end
    if dr.SetWidth then dr:SetWidth(2) end
    line(dr, px, py, pz + 0.4, gx, gy, gz + 0.4)

    -- beacon so it reads at distance and from any angle
    if dr.SetColorRaw then dr:SetColorRaw(1.0, 0.9, 0.3, 0.95) end
    line(dr, gx, gy, gz, gx, gy, gz + 6.0)
    if dr.SetColorRaw then dr:SetColorRaw(1.0, 0.55, 0.1, 0.9) end
    dot(dr, gx, gy, gz + 0.2, 1.2)
end

function V.draw_search(dr, px, py, pz)
    local S = RaijinLab and RaijinLab.QuestSuite
    local fields = S and S._fields
    if not fields then return end
    local best
    for _, f in pairs(fields) do best = best or f end
    if not (best and best.cells) then return end
    local top = {}
    for k, m in pairs(best.cells) do top[#top + 1] = { k = k, m = m } end
    table.sort(top, function(a, b) return a.m > b.m end)
    local maxm = top[1] and top[1].m or 1
    local SF = RaijinLab.SearchField
    local cell = (SF and SF.CELL) or 40
    for i = 1, math.min(#top, V.SEARCH_TOP) do
        local e = top[i]
        local cx, cy = e.k:match("(-?%d+):(-?%d+)")
        if cx then
            local x = (tonumber(cx) + 0.5) * cell
            local y = (tonumber(cy) + 0.5) * cell
            local t = e.m / maxm
            if dr.SetColorRaw then
                dr:SetColorRaw(1.0, 0.85 - 0.5 * t, 0.1, 0.35 + 0.45 * t)
            end
            if not diamond(dr, x, y, pz + 0.2, 1.2 + t) then break end
        end
    end
end

function V.draw_target(dr, px, py, pz)
    local N = RaijinLab and RaijinLab.Navigator
    local g = N and N._active and N._active.goal
    if not g then return end
    local gz = (g.z or pz) + 0.4
    if dr.SetColorRaw then dr:SetColorRaw(1.0, 0.82, 0.12, 0.95) end
    diamond(dr, g.x, g.y, gz, 1.4)
    ring(dr, g.x, g.y, gz, 1.8, 14)
    -- Thin lead line player -> goal
    if dr.SetColorRaw then dr:SetColorRaw(1.0, 0.9, 0.2, 0.45) end
    line(dr, px, py, pz + 0.4, g.x, g.y, gz)
end

function V.draw_controller(dr, px, py, pz)
    local N = RaijinLab and RaijinLab.Navigator
    if not N then return end
    local head = N._facing_real or N._cam_now
    local tgt = N._target_h
    local z0 = pz + 0.5
    local len = 6.0
    if head and dr.SetColorRaw then
        dr:SetColorRaw(0.2, 1.0, 0.4, 0.9)
        line(dr, px, py, z0,
            px + math.cos(head) * len, py + math.sin(head) * len, z0)
    end
    if tgt and dr.SetColorRaw then
        dr:SetColorRaw(0.3, 0.7, 1.0, 0.85)
        line(dr, px, py, z0,
            px + math.cos(tgt) * (len * 0.85), py + math.sin(tgt) * (len * 0.85), z0)
    end
end

function V.render()
    local dr = d()
    if not dr then return end
    V._segments = 0
    local px, py, pz = ppos()
    if not px then return end
    -- Cheapest-first so path/target always get budget before grid.
    if V.enabled("path") then pcall(V.draw_path, dr) end
    -- intent BEFORE the heavier layers: when everything else is empty this
    -- is the one that answers "where is it going".
    if V.enabled("intent") then pcall(V.draw_intent, dr, px, py, pz) end
    if V.enabled("target") then pcall(V.draw_target, dr, px, py, pz) end
    if V.enabled("controller") then pcall(V.draw_controller, dr, px, py, pz) end
    if V.enabled("search") then pcall(V.draw_search, dr, px, py, pz) end
    if V.enabled("grid") then pcall(V.draw_grid, dr, px, py, pz) end
end

function V.refresh()
    local R = RaijinLab
    if not (R and R.AddDrawingCallback) then return end
    if V.any() then
        if R.InitDrawing then pcall(R.InitDrawing, R) end
        R:AddDrawingCallback("vision", V.render)
    else
        R:AddDrawingCallback("vision", function() end)
    end
end

if RaijinLab then RaijinLab.Vision = V end
return V
