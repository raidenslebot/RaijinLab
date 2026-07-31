-- HLP - Hierarchical Heuristic Planner (long-range navigation).
--
-- The problem it solves: the mesh planner is a FLAT A* over 4yd cells. At a few
-- thousand nodes that reaches a few hundred yards, so a goal across the zone
-- returns no_path and the character crawls there by chaining blind local searches.
--
-- The design deliberately INVERTS the obvious approach. A coarse "corridor" that
-- the fine search must stay inside would be both incomplete (a real route outside
-- the corridor is excluded) and biased toward the SHORT risky line rather than the
-- clean one. So the pyramid here is NEVER a corridor and never a router. It is:
--
--   1. a wall-aware HEURISTIC generator for a single UNCORRIDORED fine A*, and
--   2. a REACHABILITY oracle.
--
-- Because the pyramid only ever feeds a heuristic, stale or optimistic block data
-- can only make the search explore a little more - it can NEVER exclude a valid
-- route. Completeness stays a property of the fine A* itself.
--
-- The reachability half is provable in the useful direction: any fine path moves
-- between grid-adjacent open cells, and every open cell's block has open_count > 0,
-- so a fine path IMPLIES a coarse path. Contrapositive: no coarse path => no fine
-- path. A negative is therefore sound (instant, correct "no_path" for islands and
-- across-water goals); a positive is only a hint, and the fine search decides.
--
-- The pyramid is DERIVED and NON-PERSISTED: it is rebuilt from the cell store on
-- demand and cached against a generation counter, so it can never drift out of
-- sync with the mesh (the failure mode an incremental rollup would risk).

local HLP = {}

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

-- Levels are 2D (z-collapsed): stacked geometry is a fine-search concern, and
-- collapsing cuts the block count enormously.
--
-- THE SIZES ARE IN YARDS BECAUSE THAT IS WHAT THEY MEAN.
--
-- These used to be spans in CELLS with the yardage in a comment - which was only
-- true at MRES 4. That silently tied the whole hierarchy to the cell size: at
-- MRES 2 every level covered half the distance and held four times the blocks,
-- so the fixed block budget explored a QUARTER of the world. The potential field
-- then stopped short of the player, h_for() found no entry for their block, and
-- fell back to straight-line euclidean - a heuristic that points directly at the
-- wall it is supposed to route around. The bot walked into the wall face because
-- refining the grid had quietly shrunk the planner's horizon.
--
-- Levels describe world scale, so they are declared in world units and the span
-- is derived. Level 4 covers a continent at any resolution.
HLP.LEVEL_YD = { 32, 256, 2048, 16384 }
HLP.LEVELS = {
    { level = 1, span = 8 },
    { level = 2, span = 64 },
    { level = 3, span = 512 },
    { level = 4, span = 4096 },
}

-- Recompute spans from the live cell size. Mutates HLP.LEVELS in place so every
-- existing reference to it stays correct, and reports whether anything moved -
-- a changed span invalidates the pyramid, which is keyed by block id.
function HLP.sync_levels()
    local w = RaijinLab and RaijinLab.WorldMesh
    local mres = (w and w.MRES) or 4.0
    if mres <= 0 then return false end
    local moved = false
    for i, L in ipairs(HLP.LEVELS) do
        local yd = HLP.LEVEL_YD[i]
        if yd then
            local span = floor(yd / mres + 0.5)
            if span < 1 then span = 1 end
            if L.span ~= span then L.span = span; moved = true end
        end
    end
    if moved then HLP._synced_mres = mres end
    return moved
end
HLP.ENTRY_NEAR = 300.0      -- below this, the flat mesh planner is simply better

local function WM() return RaijinLab and RaijinLab.WorldMesh end

-- ---- block addressing ----------------------------------------------------
-- Cell coords are the BIASED integers WorldMesh packs (0..16383 per axis), so
-- block coords are a plain integer division - no negative-number edge cases.
function HLP.block_of(span, cx, cy)
    return floor(cx / span) * 16384 + floor(cy / span)
end
function HLP.block_xy(span, bid)
    return floor(bid / 16384), bid % 16384
end
-- World-space centre of a block, via the cell packing (no duplicated constants).
function HLP.block_center(span, bid)
    local w = WM(); if not w then return 0, 0 end
    local bx, by = HLP.block_xy(span, bid)
    local half = floor(span / 2)
    local id = w.coords_id(bx * span + half, by * span + half, 512)
    local x, y = w.cell_center(id)
    return x, y
end

-- ---- pyramid build -------------------------------------------------------
-- Per block we keep only what a heuristic and a reachability flood need:
--   open   = number of open (walkable) child cells   -> traversable at all?
--   best_q = MIN over children of a LOWER-BOUND cost factor. Dropping the
--            non-negative unknown/hazard/stuck terms guarantees best_q <= the true
--            cost_factor of every child, which is what keeps the derived heuristic
--            from over-estimating.
--   visits = summed traffic (highway signal), hazard = OR of hazard bits.
local W_BASE, F_FLOOR, V_TRUST = 1.35, 1.00, 4

local function f_lb(visits)
    -- cost_factor's travel reward only; every other term it can add is >= 0.
    local f = W_BASE - (W_BASE - F_FLOOR) * math.min(1, (visits or 0) / V_TRUST)
    if f < F_FLOOR then f = F_FLOOR end
    return f
end

function HLP.rebuild(opts)
    opts = opts or {}
    local w = WM(); if not w then return nil end
    local m = w._debug_bucket and w._debug_bucket() or nil
    local cells = opts.cells
    if not cells then
        -- Reach the live cell table through a public query surface.
        cells = w._cells_for_planner and w._cells_for_planner() or nil
    end
    if not cells then return nil end

    local pyr = {}
    for _, L in ipairs(HLP.LEVELS) do pyr[L.level] = {} end

    local fget = w._fget
    local n = 0
    for id, cw in pairs(cells) do
        local st = fget(cw, "state")
        local open = (st == w.OPEN_TRAVERSED or st == w.OPEN_RAYCAST)
            and fget(cw, "stuck") < w._blacklist_n
        if open then
            n = n + 1
            local cx, cy = w.cell_coords(id)
            local visits = fget(cw, "visits")
            local hz = fget(cw, "hazard")
            local q = f_lb(visits)
            for _, L in ipairs(HLP.LEVELS) do
                local t = pyr[L.level]
                local bid = HLP.block_of(L.span, cx, cy)
                local b = t[bid]
                if not b then
                    t[bid] = { open = 1, best_q = q, visits = visits, hazard = hz }
                else
                    b.open = b.open + 1
                    if q < b.best_q then b.best_q = q end
                    b.visits = b.visits + visits
                    if hz > b.hazard then b.hazard = hz end
                end
            end
        end
    end
    HLP._pyr = pyr
    HLP._map = w.map_key()
    HLP._gen = w._gen or 0
    HLP._open_cells = n
    return pyr
end

-- Rebuild only when the mesh actually changed (or the map did).
function HLP.ensure()
    local w = WM(); if not w then return nil end
    -- Block ids are cell coords divided by span, so a span change invalidates
    -- every id in the pyramid. Resync first and drop it if the cell size moved.
    if HLP.sync_levels() then HLP._pyr = nil end
    if HLP._pyr and HLP._map == w.map_key() and HLP._gen == (w._gen or 0) then
        return HLP._pyr
    end
    return HLP.rebuild()
end

function HLP.blocks(level)
    local p = HLP.ensure()
    return p and p[level] or nil
end

-- ---- coarse adjacency ----------------------------------------------------
local NB8 = { {1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1} }

local function coarse_neighbours(t, span, bid)
    local bx, by = HLP.block_xy(span, bid)
    local out = {}
    for i = 1, 8 do
        local nx, ny = bx + NB8[i][1], by + NB8[i][2]
        if nx >= 0 and ny >= 0 then
            local nid = nx * 16384 + ny
            if t[nid] then out[#out + 1] = nid end
        end
    end
    return out
end
HLP._coarse_neighbours = coarse_neighbours

-- ---- reachability (sound negative) ---------------------------------------
-- Returns false ONLY when the goal is provably unreachable: no chain of open
-- blocks connects them, and every fine path would have to produce such a chain.
-- `true` means "not disproven" - the fine search still decides.
function HLP.reachable(startId, goalId, opts)
    opts = opts or {}
    local w = WM(); if not w then return true end
    local level = opts.level or 1
    local p = HLP.ensure(); if not p then return true end
    local t = p[level]; if not t then return true end
    local span = HLP.LEVELS[level].span

    local scx, scy = w.cell_coords(startId)
    local gcx, gcy = w.cell_coords(goalId)
    local sb = HLP.block_of(span, scx, scy)
    local gb = HLP.block_of(span, gcx, gcy)
    if not (t[sb] and t[gb]) then return true end   -- can't disprove
    if sb == gb then return true end

    local seen, queue, head = { [sb] = true }, { sb }, 1
    local cap = opts.max_blocks or 20000
    local expanded = 0
    while head <= #queue do
        local cur = queue[head]; head = head + 1
        expanded = expanded + 1
        if expanded > cap then return true end       -- budget out: don't claim a negative
        if cur == gb then return true end
        for _, nid in ipairs(coarse_neighbours(t, span, cur)) do
            if not seen[nid] then seen[nid] = true; queue[#queue + 1] = nid end
        end
    end
    return false, "coarse_disconnected"
end

-- ---- heuristic potential -------------------------------------------------
-- Backward Dijkstra from the goal's block over the coarse graph. pot[bid] is a
-- lower-bound-ish cost from that block to the goal that KNOWS ABOUT WALLS and
-- unmapped space - which is exactly what plain Euclid cannot express (Euclid says
-- "10 yards" when the real route is 200 yards around a building).
function HLP.potential(goalId, opts)
    opts = opts or {}
    local w = WM(); if not w then return nil end
    local level = opts.level or 2
    local p = HLP.ensure(); if not p then return nil end
    local t = p[level]; if not t then return nil end
    local span = HLP.LEVELS[level].span

    local gcx, gcy = w.cell_coords(goalId)
    local gb = HLP.block_of(span, gcx, gcy)
    if not t[gb] then return nil end

    -- centres cached: the flood asks for them repeatedly
    local cxy = {}
    local function centre(bid)
        local c = cxy[bid]
        if not c then local x, y = HLP.block_center(span, bid); c = { x, y }; cxy[bid] = c end
        return c[1], c[2]
    end

    local pot = { [gb] = 0 }
    -- Small binary heap (self-contained so this module has no load-order coupling)
    local hk, hp, hn = {}, {}, 0
    local function push(k, pr)
        hn = hn + 1; hk[hn], hp[hn] = k, pr
        local i = hn
        while i > 1 do
            local par = floor(i / 2)
            if hp[par] <= hp[i] then break end
            hk[par], hk[i] = hk[i], hk[par]; hp[par], hp[i] = hp[i], hp[par]; i = par
        end
    end
    local function pop()
        if hn == 0 then return nil end
        local top = hk[1]
        hk[1], hp[1] = hk[hn], hp[hn]; hk[hn], hp[hn] = nil, nil; hn = hn - 1
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= hn and hp[l] < hp[s] then s = l end
            if r <= hn and hp[r] < hp[s] then s = r end
            if s == i then break end
            hk[i], hk[s] = hk[s], hk[i]; hp[i], hp[s] = hp[s], hp[i]; i = s
        end
        return top
    end

    push(gb, 0)
    local closed = {}
    local cap = opts.max_blocks or 20000
    local expanded = 0
    while true do
        local cur = pop()
        if not cur then break end
        if not closed[cur] then
            closed[cur] = true
            expanded = expanded + 1
            if expanded > cap then break end
            local cx, cy = centre(cur)
            local gcur = pot[cur]
            for _, nid in ipairs(coarse_neighbours(t, span, cur)) do
                if not closed[nid] then
                    local nx, ny = centre(nid)
                    local d = sqrt((nx - cx) ^ 2 + (ny - cy) ^ 2)
                    local cand = gcur + d * (t[nid].best_q or F_FLOOR)
                    if pot[nid] == nil or cand < pot[nid] then
                        pot[nid] = cand
                        push(nid, cand)
                    end
                end
            end
        end
    end
    return { pot = pot, level = level, span = span, goal_block = gb, expanded = expanded }
end

-- Heuristic for a cell given a potential field.
-- The block potential is measured centre-to-centre, so it can overshoot a specific
-- cell's true remaining cost by at most about one block diagonal at each end. We
-- subtract that slack before using it, and never return less than the straight-line
-- floor - so the value stays a usable lower bound while still being wall-aware.
function HLP.h_for(field, cellId, goalX, goalY)
    local w = WM(); if not w then return 0 end
    local cx0, cy0 = w.cell_center(cellId)
    local eucl = sqrt((goalX - cx0) ^ 2 + (goalY - cy0) ^ 2) * F_FLOOR
    if not field then return eucl end
    local cx, cy = w.cell_coords(cellId)
    local bid = HLP.block_of(field.span, cx, cy)
    local pv = field.pot[bid]
    if not pv then return eucl end
    local blockyd = field.span * (w.MRES or 4.0)
    local slack = blockyd * 1.4142 * 2
    local h = pv - slack
    if h < eucl then return eucl end
    return h
end

function HLP.stats()
    local p = HLP.ensure()
    if not p then return { built = false } end
    local out = { built = true, map = HLP._map, gen = HLP._gen, open_cells = HLP._open_cells or 0 }
    for _, L in ipairs(HLP.LEVELS) do
        local n = 0
        for _ in pairs(p[L.level] or {}) do n = n + 1 end
        out["l" .. L.level] = n
    end
    return out
end

if RaijinLab then RaijinLab.HLP = HLP end
return HLP
