-- TravelNet - long-haul travel: flight paths, boats, zeppelins, portals.
--
-- Walking is only the last mile. Crossing a continent, or reaching another one at
-- all, means using the world's own transit: taxi nodes, ships, zeppelins and
-- portals. This module decides WHICH of those to use and drives the taxi UI.
--
-- Everything here is LEARNED, never hardcoded. Ascension is a custom server, so a
-- static route table copied from retail would be wrong in exactly the places that
-- matter. Instead: flight masters are remembered as POIs when seen, the taxi map
-- is read from the client (which authoritatively knows which nodes this character
-- has unlocked), and transit points (docks / zeppelin towers / portals) are
-- recorded with the destination we actually ended up at after using them.
--
-- The planner's job is a single decision: for this destination, is it cheaper to
-- walk, or to walk to a flight master, fly, and walk the remainder?

local TravelNet = {}

local sqrt, floor = math.sqrt, math.floor

TravelNet.WALK_SPEED   = 7.0     -- yd/s on foot
TravelNet.FLY_SPEED    = 25.0    -- yd/s effective taxi speed (incl. detours)
TravelNet.TAXI_OVERHEAD = 25.0   -- s: dismount, talk, menu, take-off
TravelNet.MIN_FLY_DIST = 600     -- yd: below this, walking always wins

local function now() return (GetTime and GetTime()) or 0 end
local function P() return RaijinLab and RaijinLab.POI end

-- ---- taxi map ------------------------------------------------------------
-- The client knows every flight node this character has unlocked, and whether
-- each is reachable from the flight master we are standing at. That is real,
-- per-character truth - far better than any table we could ship.
function TravelNet.taxi_nodes()
    local out = {}
    if not (NumTaxiNodes and TaxiNodeName) then return out end
    local n = NumTaxiNodes() or 0
    for i = 1, n do
        local name = TaxiNodeName(i)
        local status = TaxiNodeGetType and TaxiNodeGetType(i) or nil
        if name then
            out[#out + 1] = { index = i, name = name, status = status }
        end
    end
    return out
end

-- Remember the taxi map while the flight window is open, so we can reason about
-- flight availability later when we are nowhere near a flight master.
function TravelNet.learn_taxi_map()
    local nodes = TravelNet.taxi_nodes()
    if #nodes == 0 then return 0 end
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.travel = RaijinLabDB.travel or {}
    local map = RaijinLabDB.travel.taxi or {}
    RaijinLabDB.travel.taxi = map
    local key = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world"
    local cont = map[key] or {}
    map[key] = cont
    local learned = 0
    for _, nd in ipairs(nodes) do
        -- "REACHABLE" nodes are ones this character may actually fly to.
        if nd.name and nd.name ~= "" then
            local rec = cont[nd.name] or {}
            rec.name = nd.name
            rec.t = now()
            if nd.status then rec.status = nd.status end
            cont[nd.name] = rec
            learned = learned + 1
        end
    end
    return learned
end

function TravelNet.known_taxi(mapkey)
    local t = RaijinLabDB and RaijinLabDB.travel and RaijinLabDB.travel.taxi
    if not t then return {} end
    return t[mapkey or ((RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world")] or {}
end

-- ---- cost model ----------------------------------------------------------
-- Rough seconds-to-arrive for each option. Deliberately simple and explicit: the
-- only thing that matters is picking the option a competent player would pick,
-- and the dominant terms are distance-on-foot versus flight overhead.
function TravelNet.walk_seconds(d) return (d or 0) / TravelNet.WALK_SPEED end

function TravelNet.fly_seconds(d_to_master, d_flight, d_from_node)
    return TravelNet.walk_seconds(d_to_master)
        + TravelNet.TAXI_OVERHEAD
        + (d_flight or 0) / TravelNet.FLY_SPEED
        + TravelNet.walk_seconds(d_from_node)
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

-- Decide how to get to (gx,gy,gz) from (px,py,pz).
-- Returns a plan: { mode = "walk"|"fly", ... } with the reasoning attached so the
-- decision is inspectable rather than magic.
function TravelNet.plan(px, py, pz, gx, gy, gz, opts)
    opts = opts or {}
    local direct = dist2(px, py, gx, gy)
    local plan = { mode = "walk", direct = direct,
                   walk_s = TravelNet.walk_seconds(direct) }

    -- Short hops are never worth an airport run.
    if direct < (opts.min_fly or TravelNet.MIN_FLY_DIST) then
        plan.why = "short"
        return plan
    end
    local poi = P()
    if not poi then plan.why = "no_poi"; return plan end

    -- Nearest flight master to US, and the one nearest the DESTINATION.
    local fm_here, d_here = poi.nearest("flightmaster", px, py, pz, { max_dist = opts.master_max or 4000 })
    if not fm_here then plan.why = "no_known_flightmaster"; return plan end
    local fm_dest, _ = poi.nearest("flightmaster", gx, gy, gz)
    if not fm_dest then plan.why = "no_node_near_goal"; return plan end

    -- Flying to the same node we are standing at achieves nothing.
    if fm_dest == fm_here then plan.why = "same_node"; return plan end

    local d_flight = dist2(fm_here.x, fm_here.y, fm_dest.x, fm_dest.y)
    local d_from = dist2(fm_dest.x, fm_dest.y, gx, gy)
    local fly_s = TravelNet.fly_seconds(d_here, d_flight, d_from)
    plan.fly_s = fly_s
    plan.from_master = fm_here
    plan.to_master = fm_dest

    if fly_s < plan.walk_s then
        plan.mode = "fly"
        plan.why = "faster"
    else
        plan.why = "walking_faster"
    end
    return plan
end

-- ---- driving the taxi UI -------------------------------------------------
-- Take the flight whose node name best matches `name`. Returns true if a flight
-- was actually initiated.
function TravelNet.take_flight(name)
    if not (NumTaxiNodes and TaxiNodeName and TakeTaxiNode) then return false, "no_taxi_api" end
    if not name or name == "" then return false, "no_name" end
    local want = tostring(name):lower()
    local n = NumTaxiNodes() or 0
    local exact, partial
    for i = 1, n do
        local nm = TaxiNodeName(i)
        if nm then
            local l = nm:lower()
            if l == want then exact = i break end
            if not partial and l:find(want, 1, true) then partial = i end
        end
    end
    local idx = exact or partial
    if not idx then return false, "node_not_available" end
    TakeTaxiNode(idx)
    TravelNet._flying = { name = name, t = now() }
    return true
end

-- Are we currently on a taxi? (UnitOnTaxi is the authoritative check.)
function TravelNet.on_taxi()
    if UnitOnTaxi then return UnitOnTaxi("player") and true or false end
    return TravelNet._flying ~= nil
end

-- ---- transit points (boats / zeppelins / portals) ------------------------
-- These cannot be enumerated by any API: the only way to know a dock leads
-- somewhere is to have used it. So we record where we boarded and where we
-- arrived, building a real transit graph from experience.
function TravelNet.note_transit_board(kind, x, y, z, name)
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.travel = RaijinLabDB.travel or {}
    TravelNet._pending = {
        kind = kind, x = x, y = y, z = z, name = name,
        map = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world",
        t = now(),
    }
    local poi = P()
    if poi then poi.record("flightmaster", { x = x, y = y, z = z, name = name }) end
end

-- Call after a zone/continent change: if we recently boarded something, this is
-- where it led, so the pair becomes a usable transit edge.
function TravelNet.note_transit_arrive(x, y, z)
    local pend = TravelNet._pending
    if not pend then return nil end
    TravelNet._pending = nil
    local map = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world"
    if map == pend.map then return nil end        -- did not actually change map
    RaijinLabDB.travel.transit = RaijinLabDB.travel.transit or {}
    local list = RaijinLabDB.travel.transit
    list[#list + 1] = {
        kind = pend.kind, name = pend.name,
        from_map = pend.map, from = { x = pend.x, y = pend.y, z = pend.z },
        to_map = map, to = { x = x, y = y, z = z }, t = now(),
    }
    return list[#list]
end

-- Known transit edges leaving a map (how to reach another continent at all).
function TravelNet.transits_from(mapkey)
    local list = (RaijinLabDB and RaijinLabDB.travel and RaijinLabDB.travel.transit) or {}
    local out = {}
    for i = 1, #list do
        if list[i].from_map == mapkey then out[#out + 1] = list[i] end
    end
    return out
end

-- Cross-map route: which transit do we take to get from here to `target_map`?
-- Returns the transit edge to head for, or nil when we have never found one.
function TravelNet.route_to_map(target_map, px, py, pz)
    local here = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world"
    if here == target_map then return nil, "same_map" end
    local direct = {}
    for _, tr in ipairs(TravelNet.transits_from(here)) do
        if tr.to_map == target_map then direct[#direct + 1] = tr end
    end
    -- Prefer a direct link, nearest boarding point first.
    local best, bestd = nil, math.huge
    for _, tr in ipairs(direct) do
        local d = dist2(px or 0, py or 0, tr.from.x, tr.from.y)
        if d < bestd then best, bestd = tr, d end
    end
    if best then return best, "direct" end
    -- Otherwise any transit off this map is progress toward somewhere else.
    local any = TravelNet.transits_from(here)
    for _, tr in ipairs(any) do
        local d = dist2(px or 0, py or 0, tr.from.x, tr.from.y)
        if d < bestd then best, bestd = tr, d end
    end
    if best then return best, "indirect" end
    return nil, "no_known_transit"
end

function TravelNet.stats()
    local here = (RaijinLab and RaijinLab.WorldMesh and RaijinLab.WorldMesh.map_key()) or "world"
    local taxi = 0
    for _ in pairs(TravelNet.known_taxi(here)) do taxi = taxi + 1 end
    local tr = (RaijinLabDB and RaijinLabDB.travel and RaijinLabDB.travel.transit) or {}
    return { map = here, taxi_nodes = taxi, transits = #tr, on_taxi = TravelNet.on_taxi() }
end

if RaijinLab then RaijinLab.TravelNet = TravelNet end
return TravelNet
