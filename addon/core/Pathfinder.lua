-- Async raycast A* pathfinder.
--
-- There's no navmesh on this server, so we build the graph ON THE FLY from the
-- world's own collision: each node is a ground point (snapped down via TraceGround),
-- and an edge exists only when a body-height TraceLine between two points is clear
-- and the slope is walkable. A* over that graph finds a true route around real
-- terrain and buildings; the result is then string-pulled (line-of-sight funnel)
-- into a minimal set of smooth waypoints.
--
-- It is deliberately HEAVY (many raycasts) - and that's fine: the whole search
-- runs as a coroutine on the frame-budgeted Scheduler, yielding whenever the
-- frame budget is spent, so an exhaustive high-resolution search costs zero
-- frame hitches and simply finishes a few frames later.
--
-- The pure core (Heap / search / simplify) takes an `oracle` interface so it can
-- be unit-tested against a synthetic world with no client:
--   oracle.ground(x, y, z_hint)                 -> ground Z or nil (cliff/gap),
--                                                  plus a second return `guessed`
--                                                  = true when no source could
--                                                  measure it and the z_hint was
--                                                  handed straight back. A guessed
--                                                  height is NOT ground and must
--                                                  never be expanded as one.
--   oracle.edge_clear(ax,ay,az, bx,by,bz)       -> bool (walkable, wall-free)
--   oracle.yield_check()                        -> cooperative yield hook (opt)

local Pathfinder = {}

local sqrt, floor, cos, sin = math.sqrt, math.floor, math.cos, math.sin
local PI2 = math.pi * 2

local function d3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return sqrt(dx * dx + dy * dy + dz * dz)
end
local function d2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

-- ---- binary min-heap (lazy-deletion A* open set) -------------------------
local Heap = {}
Heap.__index = Heap
function Heap.new() return setmetatable({ n = 0, k = {}, p = {} }, Heap) end
function Heap:empty() return self.n == 0 end
function Heap:push(key, prio)
    local n = self.n + 1
    self.n = n
    self.k[n] = key; self.p[n] = prio
    while n > 1 do
        local parent = floor(n / 2)
        if self.p[parent] <= self.p[n] then break end
        self.k[parent], self.k[n] = self.k[n], self.k[parent]
        self.p[parent], self.p[n] = self.p[n], self.p[parent]
        n = parent
    end
end
function Heap:pop()
    if self.n == 0 then return nil end
    local top = self.k[1]
    local n = self.n
    self.k[1], self.p[1] = self.k[n], self.p[n]
    self.k[n], self.p[n] = nil, nil
    self.n = n - 1
    n = 1
    local size = self.n
    while true do
        local l, r = n * 2, n * 2 + 1
        local smallest = n
        if l <= size and self.p[l] < self.p[smallest] then smallest = l end
        if r <= size and self.p[r] < self.p[smallest] then smallest = r end
        if smallest == n then break end
        self.k[n], self.k[smallest] = self.k[smallest], self.k[n]
        self.p[n], self.p[smallest] = self.p[smallest], self.p[n]
        n = smallest
    end
    return top
end
Pathfinder.Heap = Heap

-- ---- body-volume (capsule) clearance --------------------------------------
-- A single infinitely-thin ray misses exactly the things that snag a real
-- character: the knee-high rock, the doorframe that fits a ray but not a body,
-- the tree pair with a 0.3yd gap. So an edge is validated as a CAPSULE:
--   * chest-height center ray        - any hit = a real wall, edge fails
--   * two chest-height LATERAL rays  - offset +-half_width perpendicular, so the
--                                      body actually FITS through the corridor
--   * the foot-height ray is deliberately NOT a blocker: a hit at foot level
--     with a clear chest is a small hoppable lip (pebble/root/step); the
--     ground-continuity sampling separately rejects steps that are too tall,
--     and the steering layer hops the small ones.
-- `tracer(x1,y1,z1,x2,y2,z2) -> blocked` abstracts TraceLine so this is pure.
function Pathfinder.capsule_clear(ax, ay, az, bx, by, bz, tracer, opts)
    opts = opts or {}
    local chest = opts.chest or 1.4
    local halfw = opts.half_width or 0.45
    -- Centre first: most blocked edges fail here (1 ray). Laterals only if
    -- centre is open -- more edges tested per budget, same safety for trunks.
    if tracer(ax, ay, (az or 0) + chest, bx, by, (bz or 0) + chest) then return false end
    local dx, dy = bx - ax, by - ay
    local len = sqrt(dx * dx + dy * dy)
    -- Sub-yard hops on the search graph: centre ray is enough; body width is
    -- sampled on longer edges. Saves ~2 rays per micro-step * thousands of nodes.
    if len <= 1.25 then return true end
    if len > 0.01 then
        local px, py = -dy / len * halfw, dx / len * halfw
        if tracer(ax + px, ay + py, (az or 0) + chest, bx + px, by + py, (bz or 0) + chest) then
            return false
        end
        if tracer(ax - px, ay - py, (az or 0) + chest, bx - px, by - py, (bz or 0) + chest) then
            return false
        end
    end
    return true
end

local function reconstruct(came, coord, k)
    local path = {}
    while k do
        local c = coord[k]
        table.insert(path, 1, { x = c.x, y = c.y, z = c.z })
        k = came[k]
    end
    return path
end

-- ---- pure A* over the on-the-fly ground graph ----------------------------
-- Returns (path, status) where status is "found" | "partial" | "no_path".
function Pathfinder.search(start, goal, oracle, opts)
    opts = opts or {}
    local step = opts.step or 2.5
    local arrive = opts.arrive or 3.0
    local max_nodes = opts.max_nodes or 8000
    local dirs = opts.dirs or 16

    -- Endpoints are the one place a guessed height is tolerable: we are
    -- physically standing at the start, and the goal's z is the caller's own
    -- claim about where it wants to go. Consulted explicitly so it is a decision
    -- rather than the silent fallback it used to be - expanded nodes below get
    -- no such licence, because that is where an invented height becomes a route.
    local sz, sguessed = oracle.ground(start.x, start.y, start.z)
    local gz, gguessed = oracle.ground(goal.x, goal.y, goal.z)
    if sz == nil or sguessed then sz = start.z or 0 end
    if gz == nil or gguessed then gz = goal.z or 0 end
    local startN = { x = start.x, y = start.y, z = sz }
    local goalN = { x = goal.x, y = goal.y, z = gz }

    local function key(x, y) return floor(x / step + 0.5) .. ":" .. floor(y / step + 0.5) end

    local open = Heap.new()
    local g, came, closed, coord = {}, {}, {}, {}
    local sk = key(startN.x, startN.y)
    g[sk] = 0; coord[sk] = startN
    open:push(sk, d3(startN, goalN))
    local best_k, best_d = sk, d2(startN, goalN)
    local expanded = 0

    while not open:empty() do
        local ck = open:pop()
        if not closed[ck] then
            closed[ck] = true
            local cn = coord[ck]

            local dg = d2(cn, goalN)
            if dg < best_d then best_d, best_k = dg, ck end
            if d3(cn, goalN) <= arrive then
                return reconstruct(came, coord, ck), "found"
            end

            expanded = expanded + 1
            if expanded > max_nodes then break end
            -- HARD wall-clock cap: a route search can NEVER hang the bot. Checked
            -- every 48 nodes (cheap) - if we blow the real-time deadline, bail with
            -- the best-so-far and let the caller steer direct. Kills the old
            -- fps-death-spiral where a low frame budget let a search run 20s+.
            if opts.deadline and (expanded % 48 == 0) and GetTime and GetTime() > opts.deadline then
                break
            end

            for dnum = 0, dirs - 1 do
                local ang = (dnum / dirs) * PI2
                local nx = cn.x + cos(ang) * step
                local ny = cn.y + sin(ang) * step
                local nz, nguessed = oracle.ground(nx, ny, cn.z)
                -- A guessed height is not a node. Expanding one grew the search
                -- across an imaginary flat plane at the parent's own height, so a
                -- route over unmapped space came back "found" and fully costed.
                -- Refusing it makes the search stop at the edge of what can be
                -- evidenced and return a "partial" the caller can re-plan from.
                -- (nz may legitimately be 0 - test the guess flag, not the number.)
                if nz and not nguessed then
                    local nk = key(nx, ny)
                    if not closed[nk] then
                        local nn = { x = nx, y = ny, z = nz }
                        if oracle.edge_clear(cn.x, cn.y, cn.z, nx, ny, nz) then
                            -- QUALITY cost: distance * terrain_factor (+jump). The
                            -- factor rewards proven/known-walkable ground and
                            -- penalizes uncertainty/cliffs/water/snags, so the route
                            -- is the cleanest one, not the shortest. Admissible
                            -- because factor >= 1 and the heuristic is 1.0*d3.
                            local base = d3(cn, nn)
                            local ec = oracle.step_cost
                                and oracle.step_cost(cn.x, cn.y, cn.z, nx, ny, nz, base)
                                or (base + (oracle.cost_extra and oracle.cost_extra(nx, ny, nz) or 0))
                            local tentative = g[ck] + ec
                            if (g[nk] == nil) or (tentative < g[nk]) then
                                g[nk] = tentative
                                came[nk] = ck
                                coord[nk] = nn
                                open:push(nk, tentative + d3(nn, goalN))
                            end
                        end
                    end
                end
            end

            if oracle.yield_check then oracle.yield_check() end
        end
    end

    if best_k and best_k ~= sk then
        return reconstruct(came, coord, best_k), "partial"
    end
    return nil, "no_path"
end

-- ---- multi-resolution refinement ------------------------------------------
-- A coarse step is fast and covers range, but it MISSES narrow features: the
-- 0.5yd doorway, the one diagonal seam that lets you run up a hill, the gap
-- between two boulders. So when a resolution fails to reach the goal, the
-- search AUTOMATICALLY re-runs at a finer step (sub-yard at the bottom) - the
-- ground cache makes the re-search cheap, and the scheduler absorbs the extra
-- rays. Returns (path, status, step_used); keeps the best partial across
-- resolutions (closest final node to the goal) when nothing fully connects.
function Pathfinder.search_adaptive(start, goal, oracle, opts)
    opts = opts or {}
    local steps = opts.steps or { opts.step or 3.0, 1.5, 0.75 }
    local best, bestStatus, bestDist, bestStep
    for i = 1, #steps do
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.step = steps[i]
        local path, status = Pathfinder.search(start, goal, oracle, o)
        if status == "found" then return path, "found", steps[i] end
        if path and #path > 0 then
            local dd = d3(path[#path], goal)
            if not bestDist or dd < bestDist then
                best, bestStatus, bestDist, bestStep = path, status, dd, steps[i]
            end
        end
        -- Respect the wall-clock deadline between resolutions too, so we don't start
        -- an expensive finer pass we can't afford.
        if opts.deadline and GetTime and GetTime() > opts.deadline then break end
        if oracle.yield_check then oracle.yield_check() end
    end
    return best, bestStatus or "no_path", bestStep
end

-- How long a horizontal span (yards) a single line-of-sight shortcut may cover.
-- A clear TraceLine only means "clear" INSIDE streamed collision: past render
-- range the client has nothing loaded to hit, so the trace reports clear for a
-- mountain, a keep, or a canyon. The funnel believed it and deleted precisely the
-- waypoints that were routing AROUND that unloaded geometry, replacing a good
-- detour with a straight line into the thing it was avoiding. Beyond this range a
-- span is not "open", it is UNKNOWN - and unknown does not earn a shortcut.
Pathfinder.LOS_TRUST_YD = 70

-- ---- line-of-sight funnel: drop waypoints reachable in a straight line ----
function Pathfinder.simplify(path, oracle, opts)
    if not path or #path <= 2 then return path end
    local trust = (opts and opts.los_trust) or Pathfinder.LOS_TRUST_YD
    local yield_check = oracle and oracle.yield_check
    local out = { path[1] }
    local i = 1
    local tests = 0
    while i < #path do
        local j = #path
        while j > i + 1 do
            local a, b = path[i], path[j]
            -- Range first: it is free, and it keeps us from spending a fistful of
            -- raycasts on a span whose answer we would have to distrust anyway.
            if d2(a, b) <= trust and oracle.edge_clear(a.x, a.y, a.z, b.x, b.y, b.z) then
                break
            end
            -- Each edge_clear is a capsule of raycasts plus a ground walk, so the
            -- funnel is as expensive as the search it follows and has to hand the
            -- frame back on the same terms.
            tests = tests + 1
            if yield_check and (tests % 8 == 0) then yield_check() end
            j = j - 1
        end
        out[#out + 1] = path[j]
        i = j
    end
    return out
end

-- ---- live oracle backed by the runtime collision raycasts ----------------
local function live_oracle()
    local RL = RaijinLab
    -- All ground queries flow through the shared cache (TraceGround is the
    -- hottest raycast; caching makes exhaustive search cheap). Cells the world
    -- memory has blacklisted (repeat physical snags) read as HOLES: geometry
    -- said walkable, experience said otherwise - experience wins.
    -- PRECEDENCE, and it is deliberate:
    --   experience  >  live sensing  >  the client's own map  >  nothing
    -- Experience first because a cell we have physically snagged on is untrue
    -- whatever the geometry claims. Live sensing next because it is current.
    -- The offline map LAST but never absent - it is the only source that still
    -- answers past render range, which is exactly where planning used to stop
    -- and the bot started walking blind at a goal it could not see.
    local function grd(x, y, zh)
        local WM = RL and RL.WorldMesh
        if WM and WM.is_blacklisted and WM.is_blacklisted(x, y, zh) then return nil end
        local GC = RL and RL.GroundCache
        local disc = (GC and GC.DISCOVERY_DOWN) or 14.0
        local live
        -- Discovery span: z-hints from neighbors can be wrong by a storey.
        -- The hit is then classified by route_z so a lake bed 10yd under the
        -- band becomes a swim node at the band, not a walk node on the mud.
        if GC and GC.ground then
            live = GC.ground(x, y, zh, nil, 3.0, disc)
        elseif RL and RL.TraceGround then
            live = RL:TraceGround(x, y, zh or 0, 3.0, disc)
        end
        local water = false
        if GC and GC.is_water then
            local w = GC.is_water(x, y)
            if w == true then water = true end
        else
            local NG = RL and RL.NavGrid
            if NG and NG.at and NG.WATER and NG.at(x, y) == NG.WATER then water = true end
        end
        if GC and GC.route_z then
            local rz, kind = GC.route_z(zh, live, water)
            if rz ~= nil then return rz end
            -- cliff/void from live sensing: still allow the offline map for
            -- unload (render-range) cases below; only refuse when we had a hit.
            if live ~= nil then return nil end
        elseif live then
            return live
        end
        -- Nothing loaded to hit. That is not "no ground" - it is "not loaded",
        -- and treating the two as the same is what confined every route to
        -- render range. The extracted terrain knows.
        local NG = RL and RL.NavGrid
        if NG and NG.height then
            local h = NG.height(x, y)
            if h then
                if GC and GC.route_z then
                    local rz = GC.route_z(zh, h, water)
                    if rz ~= nil then return rz end
                    -- map says dry cliff under deep drop: refuse
                    if not water then return nil end
                end
                return h
            end
        end
        -- Water with no solid and no map height: keep the travel band. This one
        -- is evidenced - something answered "water here" - so it is real ground
        -- for routing purposes (the swim surface), not a guess.
        if water then return zh end
        -- NOTHING answered: no live collision, no extracted map height, no water.
        -- Returning the hint bare turned "I cannot tell whether there is ground
        -- here" into "there is flat walkable ground exactly at your feet", and the
        -- planner routed confidently through unmapped space on the strength of it.
        -- It was worst in the continuity gate below, which feeds the PREVIOUS
        -- sample in as the hint: every sample across an unmapped chasm came back
        -- equal to the last one, so the gate that exists to catch chasms compared
        -- a number to itself and passed every one of them.
        -- The hint still goes back (callers need some z to work with) but flagged,
        -- and every caller here consults the flag before treating it as ground.
        return zh, true
    end

    -- What the offline map says about standing at a point. Returns
    -- 1 = walkable, -1 = definitely not, 0 = it cannot say.
    -- WALKABILITY IS A QUESTION ABOUT A FLOOR, NOT A COLUMN.
    --
    -- Without the height this asked about the LOWEST surface in the cell - a
    -- multi-storey building's ground plan - while the character stood upstairs.
    -- Every answer was then about a floor it was not on, which is precisely how
    -- it kept planning through walls indoors.
    local function mapsays(x, y, z)
        local NG, Know = RL and RL.NavGrid, RL and RL.Know
        if not (NG and NG.walkable and Know) then return 0 end
        local k
        if z and NG.walkable_z then
            k = NG.walkable_z(x, y, z)
        else
            k = NG.walkable(x, y)
        end
        if Know.is_yes(k) then return 1 end
        if Know.is_no(k) then return -1 end
        return 0                     -- unknown, and unknown decides nothing
    end
    local tracer = function(x1, y1, z1, x2, y2, z2)
        if RL and RL.TraceLine then
            return RL:TraceLine(x1, y1, z1, x2, y2, z2, 0x100111) and true or false
        end
        return false
    end
    -- THREE-VALUED TRACE, because "I could not tell" is not "clear".
    --
    -- `tracer` above collapses everything to a boolean, and TraceLine reports
    -- state="unknown" when the raycast threw or nothing was loaded to hit -
    -- which becomes `false`, i.e. "not blocked". That is fine for a soft hint
    -- and fatal as a licence to walk through a wall the map already knows about.
    local tracer_state = function(x1, y1, z1, x2, y2, z2)
        if not (RL and RL.TraceLine) then return "unknown" end
        local blocked, _, _, _, state = RL:TraceLine(x1, y1, z1, x2, y2, z2, 0x100111)
        if state then return state end
        return blocked and "blocked" or "clear"
    end
    return {
        ground = grd,
        -- multiplicative quality cost: base distance * WorldMesh terrain factor, plus
        -- a jump penalty for a big up-step (prefer not jumping fences/ramps).
        step_cost = function(ax, ay, az, bx, by, bz, base)
            local WM = RL and RL.WorldMesh
            local f = (WM and WM.cost_factor and WM.cost_factor(bx, by, bz)) or 1.0
            local j = (az and bz and (bz - az) > 1.5) and 3.0 or 0
            -- Ground the client itself calls walkable is cheap; a building
            -- footprint is merely UNCERTAIN, so it is discouraged rather than
            -- forbidden - its bounding box covers its own floor, and refusing to
            -- route through one would make every town unreachable.
            local m = mapsays(bx, by, bz)
            if m == 1 then f = f * 0.85 end
            local NG = RL and RL.NavGrid
            if NG and NG.at then
                local code = (NG.at_z and NG.at_z(bx, by, bz)) or NG.at(bx, by)
                -- STRUCTURE now covers both a building footprint and doodad
                -- clutter (trees, rocks). Both mean "real geometry is here but
                -- finer than this grid" - weaving costs time, so price it and let
                -- live raycasts resolve the actual trunk or wall.
                -- 1.8x made a building a speed bump: cutting straight through
                -- stayed the shortest route, so the planner routed into the
                -- church and left the wall to a 2.2yd raycast - a reflex standing
                -- in for a plan. We have the footprint; use it to go AROUND.
                --
                -- Deliberately a heavy cost rather than a hard block. The box
                -- covers doorways and courtyards too, so forbidding it outright
                -- would wall off buildings we are supposed to enter (inns, quest
                -- interiors). A large multiplier means "only through here if
                -- there is genuinely no way round", which is exactly the truth.
                f = f * Pathfinder.grid_mult(code, NG)
                -- Swimming is roughly half speed, cannot fight, and drowns. So it
                -- is heavily discouraged but never refused: the route around a
                -- lake is usually shorter in time, and when it is not, crossing
                -- has to remain available or a river becomes a wall.
                if code == NG.WATER then f = f * 4.0 end
            end
            return base * f + j
        end,
        cost_extra = function(x, y, z)   -- legacy (kept for callers that still use it)
            local WM = RL and RL.WorldMesh
            return (WM and WM.penalty and WM.penalty(x, y, z)) or 0
        end,
        edge_clear = function(ax, ay, az, bx, by, bz)
            -- A DEFINITE no from the map ends it: the client's own terrain says
            -- this is a cliff face or solid ground. Only a definite no - unknown
            -- must fall through to live sensing below, or an unexported zone
            -- would read as one solid wall.
            if mapsays(bx, by, bz) == -1 then return false end
            -- STRUCTURE + solid ray = hard block (do not cut through the wall).
            -- STRUCTURE + clear ray = doorway/courtyard - allow; step_cost still
            -- multiplies heavily so A* prefers going around. Hard-blocking every
            -- STRUCTURE cell made indoor NPCs unreachable.
            -- Sample ALONG the segment, not only the endpoint: a path that
            -- skirts a footprint only at the far node still cuts the wall mid-edge.
            local NG = RL and RL.NavGrid
            if NG and NG.at and NG.STRUCTURE then
                local samples = 4
                for si = 1, samples do
                    local t = si / samples
                    local sx = ax + (bx - ax) * t
                    local sy = ay + (by - ay) * t
                    -- Interpolate the HEIGHT along the segment too: sampling a
                    -- mid-edge cell against the endpoint's floor asks about the
                    -- wrong storey exactly where a wall would be.
                    local sz = (az and bz) and (az + (bz - az) * t) or bz
                    local code = (NG.at_z and NG.at_z(sx, sy, sz)) or NG.at(sx, sy)
                    if code == NG.STRUCTURE then
                        -- THE MAP IS THE AUTHORITY FOR STATIC GEOMETRY.
                        --
                        -- This used to block only when a live ray ALSO confirmed
                        -- the wall, so a STRUCTURE cell was passable whenever the
                        -- raycast could not answer - collision not streamed in, a
                        -- thin ray slipping between fence posts, or a throw that
                        -- reports state="unknown" and collapses to "not blocked".
                        -- The premapped world - every building and doodad
                        -- extracted from the client's own MPQs, 3637 tiles - was
                        -- subordinate to the least reliable sensor we have.
                        -- Live: plan_hier routed 10 nodes straight through a
                        -- fence, which the bot then met with a 1.2yd whisker.
                        --
                        -- Invert the burden of proof. A cell the map calls
                        -- STRUCTURE is solid unless the ray gives POSITIVE
                        -- evidence of a gap. That keeps the doorway/courtyard
                        -- case the old comment cared about (indoors, with
                        -- collision loaded, a real gap answers "clear") while
                        -- refusing to invent one out of an unanswered probe.
                        local z0 = (az or 0) + 1.2
                        local z1 = (az or 0) + ((bz or 0) - (az or 0)) * t + 1.2
                        if tracer_state(ax, ay, z0, sx, sy, z1) ~= "clear" then
                            return false
                        end
                    end
                end
            end
            local horiz = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
            -- capsule wall gate: chest ray + lateral body-width rays (a thin ray
            -- fits where a body doesn't; a foot-level pebble is NOT a wall).
            if not Pathfinder.capsule_clear(ax, ay, az, bx, by, bz, tracer) then
                return false
            end
            -- ground-continuity gate: walk the edge in ~1.5yd steps and require a
            -- floor at every sample with a walkable step between samples. This is
            -- what stops a route from striding over a chasm or off a cliff that
            -- sits BETWEEN two nodes (endpoint-only checks miss it). Heavy on
            -- raycasts by design - the scheduler amortizes it.
            if (RL and (RL.GroundCache or RL.TraceGround)) and horiz > 0.01 then
                local steps = floor(horiz / 1.5)
                if steps < 1 then steps = 1 end
                local prevz = az or 0
                for k = 1, steps do
                    local t = k / steps
                    local sx = ax + (bx - ax) * t
                    local sy = ay + (by - ay) * t
                    local gz, guessed = grd(sx, sy, prevz)
                    -- Unknown fails the gate exactly like a hole does. A guess
                    -- here is the hint we just passed in (prevz), so the step
                    -- test below would compare prevz to itself and wave through
                    -- every chasm nothing could measure - the gate would be
                    -- proving only that our own arithmetic is consistent.
                    if not gz or guessed then return false end      -- gap / cliff / unproven
                    if (prevz - gz) > 3.5 or (gz - prevz) > 2.5 then return false end  -- step too big
                    prevz = gz
                end
            end
            return true
        end,
        yield_check = function()
            local S = RL and RL.Scheduler
            if not (S and S.over_budget and S.over_budget()) then return end
            -- Scheduler.yield IS coroutine.yield, which throws "attempt to yield
            -- from outside a coroutine" on the main thread. This hook now also
            -- runs from simplify / plan_mesh / plan_hier, which a caller may
            -- invoke synchronously, so the thread check is what keeps a budget
            -- overrun from becoming a Lua error mid-route.
            if coroutine and coroutine.running and coroutine.running() then S.yield() end
        end,
    }
end
Pathfinder._live_oracle = live_oracle

-- RAYCAST-FREE mesh A*: plan directly over the WorldMesh graph (cells + links the
-- Surveyor/traversal recorded). No raycasts - pure memory lookups - so a route over
-- KNOWN ground is found in microseconds and is as complete as the map. Returns
-- (path, "found") or (nil, "no_path"/"no_mesh") when the map can't reach start->goal.
-- ---- TIER 0: hierarchical long-range plan --------------------------------
-- A single UNCORRIDORED A* over the mesh state-graph, guided by a wall-aware
-- heuristic from the HLP pyramid. The pyramid never constrains where the search
-- may go (that would make it incomplete and bias it toward the short risky line);
-- it only tells the search which direction is actually promising, which is what
-- makes a cross-zone goal tractable at all.
--
-- Returns (path, status): "found" | "partial" (best prefix toward the goal, the
-- caller walks it and re-plans from further along) | "no_path" (PROVEN
-- unreachable by the coarse flood) | "no_mesh".
-- Pure grid-code price multiplier, extracted so it can be TESTED. The inline
-- version shipped as a comment with a number attached: the mutation harness
-- proved that reverting the building cost to 1.8x changed no test outcome, so
-- the whole go-around-buildings behaviour was one silent edit from vanishing.
--
-- STRUCTURE must dominate (>=10x): at 1.8x, cutting straight through a church
-- stays the shortest route and the wall is left to a 2.2yd raycast reflex.
-- It must NOT be infinite: the footprint box covers doorways and courtyards,
-- so a hard block would make every inn unreachable.
function Pathfinder.grid_mult(code, NG)
    if not (code and NG) then return 1.0 end
    if code == NG.STRUCTURE then return NG.STRUCTURE_COST or 12.0 end
    return 1.0
end

function Pathfinder.plan_hier(start, goal, opts)
    opts = opts or {}
    local WM = RaijinLab and RaijinLab.WorldMesh
    local H = RaijinLab and RaijinLab.HLP
    if not (WM and WM.state_neighbours and WM.nearest_known) then return nil, "no_mesh" end

    local er = opts.entry_r or 24
    local sid, sx, sy, sz = WM.nearest_known(start.x, start.y, start.z, er)
    if not sid then return nil, "no_mesh" end
    -- The goal may sit in unmapped space; widen the snap so a far target still
    -- anchors to the closest ground we actually know about.
    local gid, gx, gy, gz = WM.nearest_known(goal.x, goal.y, goal.z, opts.goal_entry_r or 64)
    if not gid then return nil, "no_mesh" end
    if sid == gid then
        return { { x = sx, y = sy, z = sz }, { x = goal.x, y = goal.y, z = goal.z } }, "found"
    end

    -- "NOT CONNECTED IN THE MESH" IS NOT "NOT REACHABLE IN THE WORLD".
    --
    -- H.reachable floods coarse blocks built ONLY from cells WorldMesh has
    -- already recorded as open, and coarse_neighbours skips any block absent from
    -- that table - so ground we have simply never walked is byte-identical to a
    -- wall. The comment this replaces called the negative "provable", and it is,
    -- but only within the mesh: promoting a mesh-local verdict to a global one is
    -- the whole bug.
    --
    -- It bites exactly when the mesh has two mapped islands with unexplored (and
    -- perfectly walkable) ground between them - after a graveyard resurrect, a
    -- flight path, or a hearth. Both endpoints snap to known cells, so HLP's own
    -- "endpoint outside the mesh" escape cannot fire, the flood exhausts one
    -- island and answers false. Pathfinder returned no_path, Navigator called
    -- stop() and cleared the goal, which also disables replanning: the bot stands
    -- still forever for somewhere it could have walked to.
    --
    -- The short-circuit also discarded the only tier that could have disagreed.
    -- TIER 2's oracle falls back to NavGrid heights extracted from the client's
    -- own terrain, specifically so routes extend past render range and past
    -- anything we happen to have mapped. Skipping it on mesh evidence throws away
    -- the better witness.
    --
    -- So: a coarse miss now DEMOTES the plan to the slower tiers instead of
    -- terminating it. Refusing to search is only justified when something that
    -- can actually see the world says no.
    if H and H.reachable then
        local ok = H.reachable(sid, gid, opts)
        if ok == false then
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel and Tel.every then
                Tel.every("path:coarse_miss", 10, "path", 3, "coarse_disconnected",
                    { note = "unmapped is not unreachable - falling through to full search" })
            end
            return nil, "coarse_miss"
        end
    end

    -- Wall-aware potential. Level scales with distance so the flood stays small.
    local field = nil
    if H and H.potential then
        local planar = d2(start, goal)
        local lvl = (planar > 16000 and 4) or (planar > 2000 and 3) or 2
        field = H.potential(gid, { level = opts.level or lvl, max_blocks = opts.max_blocks })
    end

    -- Snapshot living geometry once for this query: creatures and players are
    -- real obstacles, but they are transient, so they are costed here rather than
    -- ever being written into the persistent map.
    local OB = RaijinLab and RaijinLab.Obstacles
    if OB and OB.refresh then pcall(OB.refresh) end
    local ob_ignore = opts.ignore_guids
    -- The traversability field: roads pull the route in, danger pushes it out.
    -- This is what makes the plan read like a human's choice rather than a
    -- straight line - it is the difference between "shortest" and "best".
    local TV = RaijinLab and RaijinLab.Traversability
    local danger_tol = opts.danger_tolerance

    local goalN = { x = gx, y = gy, z = gz }
    local eps = opts.eps or 1.6          -- weighted A*: far fewer expansions, bounded error
    local maxn = opts.max_nodes or 6000
    local yield_check = opts.yield_check

    local function hval(cid, node)
        if H and H.h_for then return H.h_for(field, cid, goalN.x, goalN.y) end
        return d3(node, goalN)
    end

    local open = Heap.new()
    local startN = { x = sx, y = sy, z = sz }
    local g, came, coord = { [sid] = 0 }, {}, { [sid] = startN }
    local closed = {}
    open:push(sid, eps * hval(sid, startN))

    -- Track the most promising node seen, so a search that runs out of budget still
    -- returns real forward progress instead of nothing.
    local best_id, best_score = sid, hval(sid, startN)
    local expanded = 0
    while not open:empty() do
        local cid = open:pop()
        if not closed[cid] then
            closed[cid] = true
            local cn = coord[cid]
            if cid == gid then
                local p = reconstruct(came, coord, cid)
                p[#p + 1] = { x = goal.x, y = goal.y, z = goal.z }
                return p, "found"
            end
            expanded = expanded + 1
            if expanded > maxn then break end
            if yield_check and (expanded % 48 == 0) then yield_check() end

            for _, nb in ipairs(WM.state_neighbours(cid)) do
                if not closed[nb.id] then
                    local f = (WM.cost_factor and WM.cost_factor(nb.x, nb.y, nb.z)) or 1
                    if TV then
                        f = f * TV.factor(nb.x, nb.y, nb.z, { danger_tolerance = danger_tol })
                    end
                    -- Prefer ground the body has actually proven over merely-seen
                    -- ground when costs are otherwise close ("most guaranteed" wins).
                    if nb.edge == WM.EDGE_PROVEN then f = f * 0.95 end
                    local step = d3(cn, nb) * f
                    -- Parkour is a real capability, not a free one: a jump costs
                    -- time and can miss, so it is only taken when it genuinely beats
                    -- walking around. Drops cost less than upward ledges.
                    if nb.edge == WM.EDGE_JUMP then
                        step = step + ((nb.climb and nb.climb > 0) and 6.0 or 2.5)
                    end
                    -- Living obstacles: impassable where a body cannot fit, merely
                    -- expensive nearby so the route keeps a natural margin.
                    if OB then
                        if OB.blocks(nb.x, nb.y, nb.z, { ignore = ob_ignore }) then
                            step = nil
                        else
                            local pen = OB.penalty(nb.x, nb.y, nb.z, { ignore = ob_ignore })
                            if pen > 0 then step = step * (1 + pen) end
                        end
                    end
                    if step then
                    local tentative = g[cid] + step
                    if g[nb.id] == nil or tentative < g[nb.id] then
                        g[nb.id] = tentative
                        came[nb.id] = cid
                        coord[nb.id] = nb
                        local h = hval(nb.id, nb)
                        open:push(nb.id, tentative + eps * h)
                        if h < best_score then best_score, best_id = h, nb.id end
                    end
                    end
                end
            end
        end
    end

    if best_id ~= sid then
        local p = reconstruct(came, coord, best_id)
        if #p >= 2 then return p, "partial" end
    end
    return nil, "no_path_local"
end

function Pathfinder.plan_mesh(start, goal, opts)
    local WM = RaijinLab and RaijinLab.WorldMesh
    if not (WM and WM.nearest_known and WM.neighbours) then return nil, "no_mesh" end
    local er = (opts and opts.entry_r) or 24
    -- Raycast-free does not mean free: an 8000-node expansion over the mesh is
    -- still thousands of table walks, and without a yield hook it all landed in
    -- one frame. find() threads the oracle's hook in through opts.
    local yield_check = opts and opts.yield_check
    local sid, sx, sy, sz = WM.nearest_known(start.x, start.y, start.z, er)
    local gid, gx, gy, gz = WM.nearest_known(goal.x, goal.y, goal.z, er)
    if not (sid and gid) then return nil, "no_mesh" end
    if sid == gid then return { { x = sx, y = sy, z = sz }, { x = goal.x, y = goal.y, z = goal.z } }, "found" end
    local goalN = { x = gx, y = gy, z = gz }
    local open = Heap.new()
    local g, came, coord = { [sid] = 0 }, {}, { [sid] = { x = sx, y = sy, z = sz } }
    local closed = {}
    open:push(sid, d3(coord[sid], goalN))
    local expanded, maxn = 0, (opts and opts.max_nodes) or 8000
    while not open:empty() do
        local cid = open:pop()
        if not closed[cid] then
            closed[cid] = true
            local cn = coord[cid]
            if cid == gid then
                local p = reconstruct(came, coord, cid)
                p[#p + 1] = { x = goal.x, y = goal.y, z = goal.z }   -- final hop to the exact goal
                return p, "found"
            end
            expanded = expanded + 1
            if expanded > maxn then break end
            if yield_check and (expanded % 48 == 0) then yield_check() end
            for _, nb in ipairs(WM.neighbours(cid)) do
                if not closed[nb.id] then
                    local tentative = g[cid] + d3(cn, nb) * (WM.cost_factor(nb.x, nb.y, nb.z) or 1)
                    if g[nb.id] == nil or tentative < g[nb.id] then
                        g[nb.id] = tentative; came[nb.id] = cid; coord[nb.id] = nb
                        open:push(nb.id, tentative + d3(nb, goalN))
                    end
                end
            end
        end
    end
    return nil, "no_path"
end

-- Public: find a route from start to goal. Runs async on the Scheduler; calls
-- callback(path, status). Falls back to a synchronous search if no scheduler.
function Pathfinder.find(start, goal, callback, opts)
    opts = opts or {}   -- tier 2 writes opts.deadline; never let a nil-opts call crash
    local S = RaijinLab and RaijinLab.Scheduler
    local oracle = live_oracle()
    local body = function()
        local t0 = (debugprofilestop and debugprofilestop()) or 0
        -- Hand the cooperative yield hook to the tiers that take it through opts.
        -- plan_hier has always had `local yield_check = opts.yield_check`, but no
        -- caller anywhere ever set it, so the guard could not become true and
        -- TIER 0/1 ran their whole A* inside one frame however small the frame
        -- budget was - the tiers that are supposed to be the cheap ones were the
        -- only ones that could not be interrupted. Set once here, before either
        -- plan_hier call and plan_mesh, so all of them are budgeted alike.
        opts.yield_check = opts.yield_check or oracle.yield_check
        local DL = RaijinLab and RaijinLab.DevLog
        local planar = d2(start, goal)
        local H = RaijinLab and RaijinLab.HLP
        local near = (H and H.ENTRY_NEAR) or 300.0

        -- TIER 0: hierarchical plan for anything beyond local range. A flat mesh A*
        -- simply cannot reach across a zone within its node budget; this is guided
        -- by the coarse potential so it can. Also proves unreachable goals instantly.
        if planar > near then
            local hp, hstatus = Pathfinder.plan_hier(start, goal, opts)
            if hp and #hp >= 2 and (hstatus == "found" or hstatus == "partial") then
                local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel then Tel.info("path", "hier", { status = hstatus, dist = math.floor(planar),
                nodes = #hp, sx = start.x, sy = start.y, gx = goal.x, gy = goal.y }) end
                return { path = Pathfinder.simplify(hp, oracle, opts), status = hstatus }
            end
            -- DELIBERATELY NO EARLY RETURN ON A COARSE MISS.
            --
            -- This used to bail out here with no_path whenever the coarse flood
            -- failed to connect, on the belief that it had PROVED there was no
            -- route. It had proved no route THROUGH ALREADY-MAPPED GROUND, which
            -- is a different claim: unexplored terrain is absent from the block
            -- table and therefore indistinguishable from a wall. After a
            -- resurrect, hearth or flight path the mesh holds disconnected
            -- islands and this fired constantly, returning no_path for places the
            -- character could simply have walked to - and Navigator responds by
            -- stopping and clearing the goal, which disables replanning too.
            --
            -- plan_hier now reports "coarse_miss" for that case and we fall
            -- through to TIER 1/TIER 2 below. TIER 2 is the one that matters: its
            -- oracle reads NavGrid heights extracted from the client's own
            -- terrain, so it can answer for ground we have never visited. Only a
            -- searcher that can see the world earns the right to say "no route".
        end

        -- TIER 1: raycast-free mesh plan over KNOWN ground (instant). If the map
        -- already connects us to the goal, use it - no raycasts, no frame cost.
        local mp, mstatus = Pathfinder.plan_mesh(start, goal, opts)
        if mp and #mp >= 2 and mstatus == "found" then
            if DL then DL.log("path", "mesh (%.1f,%.1f)->(%.1f,%.1f) nodes=%d (raycast-free)",
                start.x, start.y, goal.x, goal.y, #mp) end
            return { path = Pathfinder.simplify(mp, oracle, opts), status = "found" }
        end

        -- TIER 1b: the body-link mesh missed it, but the Surveyor may have SEEN a
        -- route. plan_hier walks the state graph (observed ground included), so it
        -- routes over look-ahead perception the link graph cannot use.
        if planar <= near then
            local hp2, hs2 = Pathfinder.plan_hier(start, goal, opts)
            if hp2 and #hp2 >= 2 and hs2 == "found" then
                if DL then DL.log("path", "hier-near (%.0f,%.0f)->(%.0f,%.0f) nodes=%d",
                    start.x, start.y, goal.x, goal.y, #hp2) end
                return { path = Pathfinder.simplify(hp2, oracle, opts), status = "found" }
            end
        end
        -- TIER 2: residual raycast search where the map is thin/unknown.
        -- Hard real-time deadline so a route search can never hang the client (the
        -- old collision-graph A* could run 20s+ and death-spiral fps). Default 0.5s;
        -- past it we take best-so-far and steer direct.
        opts.deadline = opts.deadline or ((GetTime and GetTime() or 0) + (opts.max_ms or 0.5))
        -- multi-resolution: coarse for range, automatic sub-yard refinement when
        -- blocked, so narrow doorways / seams are found rather than missed
        local path, status, step = Pathfinder.search_adaptive(start, goal, oracle, opts)
        local raw = path and #path or 0
        if path then path = Pathfinder.simplify(path, oracle, opts) end
        local DL = RaijinLab and RaijinLab.DevLog
        if DL then
            local ms = (debugprofilestop and (debugprofilestop() - t0)) or 0
            DL.log("path", "search (%.1f,%.1f)->(%.1f,%.1f) status=%s step=%s nodes=%d simplified=%d %.1fms",
                start.x, start.y, goal.x, goal.y, tostring(status), tostring(step), raw, path and #path or 0, ms)
        end
        return { path = path, status = status }
    end
    if S and S.run then
        -- Jobs never complete if the OnUpdate frame is not armed. That left
        -- Navigator stuck in "pathfinding" with zero movement for entire
        -- sessions (live: d=80, pos frozen, nav=pathfinding forever).
        if S.start then pcall(S.start) end
        return S.run(body, S.PRIO.NORMAL, function(r)
            if callback then callback(r and r.path, r and r.status) end
        end)
    end
    local r = body()
    if callback then callback(r.path, r.status) end
    return nil
end

if RaijinLab then RaijinLab.Pathfinder = Pathfinder end
return Pathfinder
