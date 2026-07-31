-- Shared navigation service (pure path math + glue to runtime MoveTo).
-- Modules request goals via Nav; they do not reimplement CTM.

local Nav = {}

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- --- Pure geometric helpers (unit-tested) -----------------------------------

-- Cost of a straight segment with optional obstacle inflation.
-- obstacles = { {x,y,z,radius}, ... }  - cylinders on XY for walk planning
function Nav.segment_cost(ax, ay, az, bx, by, bz, obstacles, opts)
    opts = opts or {}
    local base = dist3(ax, ay, az or 0, bx, by, bz or 0)
    if base <= 0 then return 0 end
    local penalty = 0
    local climb_w = opts.climb_weight or 1.5
    local dy = math.abs((bz or 0) - (az or 0))
    penalty = penalty + dy * climb_w
    for _, o in ipairs(obstacles or {}) do
        local r = o.radius or o.r or 1.5
        -- distance from obstacle center to segment on XY
        local ox, oy = o.x, o.y
        local abx, aby = bx - ax, by - ay
        local ab2 = abx * abx + aby * aby
        local t = 0
        if ab2 > 1e-9 then
            t = ((ox - ax) * abx + (oy - ay) * aby) / ab2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local cx, cy = ax + abx * t, ay + aby * t
        local d = dist2(ox, oy, cx, cy)
        if d < r then
            -- hard block
            return math.huge
        elseif d < r * 2 then
            penalty = penalty + (r * 2 - d) * (opts.near_obstacle_weight or 3)
        end
    end
    if opts.mounted then
        base = base * (opts.mount_speed_factor or 0.7) -- lower cost = prefer mount legs
    end
    return base + penalty
end

-- Greedy waypoint path through a graph.
-- nodes = { {id,x,y,z}, ... }  edges optional: if nil, fully connected with segment_cost
function Nav.shortest_path(start, goal, nodes, obstacles, opts)
    opts = opts or {}
    if not start or not goal then return nil, "missing_endpoints" end
    -- trivial direct path if clear
    local direct = Nav.segment_cost(start.x, start.y, start.z or 0, goal.x, goal.y, goal.z or 0, obstacles, opts)
    if direct < math.huge and (not nodes or #nodes == 0) then
        return {
            { x = start.x, y = start.y, z = start.z or 0 },
            { x = goal.x, y = goal.y, z = goal.z or 0 },
        }, direct
    end

    -- Build node list including start/goal
    local pts = {}
    pts[1] = { id = "__start", x = start.x, y = start.y, z = start.z or 0 }
    for i, n in ipairs(nodes or {}) do
        pts[#pts + 1] = { id = n.id or i, x = n.x, y = n.y, z = n.z or 0 }
    end
    pts[#pts + 1] = { id = "__goal", x = goal.x, y = goal.y, z = goal.z or 0 }
    local N = #pts

    -- Dijkstra
    local dist = {}
    local prev = {}
    local used = {}
    for i = 1, N do dist[i] = math.huge; prev[i] = nil; used[i] = false end
    dist[1] = 0
    for _ = 1, N do
        local u, best = nil, math.huge
        for i = 1, N do
            if not used[i] and dist[i] < best then best = dist[i]; u = i end
        end
        if not u or best == math.huge then break end
        used[u] = true
        if u == N then break end
        for v = 1, N do
            if not used[v] then
                local c = Nav.segment_cost(pts[u].x, pts[u].y, pts[u].z, pts[v].x, pts[v].y, pts[v].z, obstacles, opts)
                if c < math.huge and dist[u] + c < dist[v] then
                    dist[v] = dist[u] + c
                    prev[v] = u
                end
            end
        end
    end
    if dist[N] == math.huge then
        return nil, "no_path"
    end
    local path = {}
    local cur = N
    while cur do
        table.insert(path, 1, { x = pts[cur].x, y = pts[cur].y, z = pts[cur].z, id = pts[cur].id })
        cur = prev[cur]
    end
    return path, dist[N]
end

-- Terrain analysis stub: classify slope between two points
function Nav.classify_slope(az, bz, horizontal_dist)
    if horizontal_dist <= 0 then return "flat", 0 end
    local slope = math.abs((bz or 0) - (az or 0)) / horizontal_dist
    if slope < 0.15 then return "flat", slope end
    if slope < 0.45 then return "incline", slope end
    if slope < 0.9 then return "steep", slope end
    return "impassable", slope
end

-- Obstacle detection helper: points that block a radius around entities
function Nav.obstacles_from_entities(entities, default_radius)
    local out = {}
    default_radius = default_radius or 1.5
    for _, e in ipairs(entities or {}) do
        if e.x and e.y then
            out[#out + 1] = {
                x = e.x, y = e.y, z = e.z or 0,
                radius = e.radius or e.bounding_radius or default_radius,
                kind = e.kind or "entity",
            }
        end
    end
    return out
end

-- --- Live glue (addon) ------------------------------------------------------
--
-- Live movement is ALWAYS keyboard steering (core/Navigator.lua):
-- face-heading + MoveForward + hop. Click-to-move / CTM / runtime MoveTo are
-- FORBIDDEN - no fallback path. Pure path math above is for planning only.

Nav._active = nil -- unused (legacy); Navigator owns live state

function Nav.request_move(goal, opts)
    opts = opts or {}
    local N = RaijinLab and RaijinLab.Navigator
    if not N or not N.move_to then return false, "no_navigator" end
    local ok = N.move_to(goal, {
        waypoints = opts.waypoints or opts.nodes,
        arrive_dist = opts.arrive_dist,
        no_avoid = opts.no_avoid,
        force_forward = opts.force_forward ~= false,
    })
    return ok, N
end

function Nav.tick(arrive_dist)
    local N = RaijinLab and RaijinLab.Navigator
    if not N then return "idle" end
    local st = N.state
    if st == "arrived" then return "arrived" end
    if st == "idle" or st == nil then return "idle" end
    if st == "moving" or st == "waypoint" or st == "pathfinding" then return "moving" end
    return st == "stuck" and "stuck" or "failed"
end

function Nav.cancel()
    if RaijinLab and RaijinLab.Navigator and RaijinLab.Navigator.stop then
        RaijinLab.Navigator.stop()
    end
    Nav._active = nil
end

function Nav.status()
    if RaijinLab and RaijinLab.Navigator then
        return RaijinLab.Navigator._active
    end
    return nil
end

if RaijinLab then
    RaijinLab.Nav = Nav
end

return Nav
