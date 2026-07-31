-- SearchField - where is the thing, probably?
--
-- The sweep this replaces was COVERAGE-based: walk to cells you have not stood
-- in. Three things are wrong with that, and together they are why it walked 2872
-- yards on a 398 yard problem and never converged:
--
--   1. IT CLEARED FOOTSTEPS, NOT SIGHT. The character sees ~200yd. Marking the
--      60yd cell you are standing in throws away almost everything you just
--      looked at, so the sweep kept re-searching ground it had already seen.
--   2. IT HAD NO PRIOR. Every direction was equally good, so it expanded
--      uniformly - which is only correct when you genuinely know nothing, and the
--      bot does not: it has spawn memory, quest hints, roads, and the fact that
--      mobs cluster.
--   3. COVERAGE CANNOT CONVERGE. "Somewhere I have not been" is an infinite set.
--      Probability mass is finite, so consuming it terminates.
--
-- So instead: a belief field over the target's location. Observation REMOVES mass
-- from everything you could see. Movement goes where the expected information per
-- unit of travel cost is highest - which automatically prefers roads (cheap),
-- avoids hazards (expensive), revisits nothing, and concentrates on remembered
-- spawns. The "heatmap" the navigation was asked for, used as a decision surface
-- rather than a picture.
--
-- Sparse on purpose: only cells with mass exist, so an empty region costs nothing
-- and the field cannot grow without bound.

local SF = {}

SF.CELL       = 40.0     -- yd per belief cell
SF.MAX_RADIUS = 900.0    -- yd: prior support around the anchor
SF.DETECT     = 0.85     -- P(spot it | it is inside the observed disc)
SF.EDGE       = 0.45     -- P(spot it | near the edge of the disc) - sight is not a step function
SF.FLOOR      = 1e-4     -- mass below this is discarded, keeping the field sparse
SF.SPREAD     = 0.02     -- per-observation leak to neighbours: things MOVE and RESPAWN
SF.CLUSTER    = 160.0    -- yd: seeing one is evidence there are more nearby

local floor, sqrt, exp = math.floor, math.sqrt, math.exp

local function key_of(cx, cy) return cx .. ":" .. cy end
local function cell_of(x, y) return floor(x / SF.CELL), floor(y / SF.CELL) end
local function centre_of(cx, cy)
    return (cx + 0.5) * SF.CELL, (cy + 0.5) * SF.CELL
end

-- ---- construction ---------------------------------------------------------

-- How many cells make a block. The block index is a SUMMARY, never a substitute:
-- it narrows where to look closely, and the answer is still computed at full cell
-- resolution inside that region.
SF.BLOCK = 4

function SF.new(opts)
    opts = opts or {}
    local f = {
        cells = {},          -- cell key -> mass
        blocks = {},         -- block key -> { m = summed mass, bx, by, n }
        border = {},         -- block key -> true, for cheap iteration
        nblocks = 0,
        n = 0,
        total = 0,
        anchor_x = opts.x or 0,
        anchor_y = opts.y or 0,
        observed = 0,
    }
    return setmetatable(f, { __index = SF })
end

-- THE ONE PLACE MASS CHANGES. Cell and block totals move together, so the block
-- index is exact by construction and never needs rebuilding. This is what lets
-- the field scale: aggregates are maintained in O(1) per update rather than
-- recomputed in O(n) per query.
function SF:_bump(cx, cy, delta)
    if delta == 0 then return end
    local k = key_of(cx, cy)
    local prev = self.cells[k] or 0
    local nm = prev + delta
    if nm < SF.FLOOR then
        if prev > 0 then self.n = self.n - 1 end
        self.cells[k] = nil
        delta = -prev
        nm = 0
    else
        if prev == 0 then self.n = self.n + 1 end
        self.cells[k] = nm
    end
    self.total = self.total + delta

    local bx, by = floor(cx / SF.BLOCK), floor(cy / SF.BLOCK)
    local bk = bx .. ":" .. by
    local b = self.blocks[bk]
    if not b then
        b = { m = 0, bx = bx, by = by, n = 0 }
        self.blocks[bk] = b
        self.nblocks = self.nblocks + 1
        self.border[#self.border + 1] = b
    end
    b.m = b.m + delta
    if b.m < 0 then b.m = 0 end
end

-- Seed the prior. Reachable, easy ground is more likely than hazard; anywhere we
-- REMEMBER seeing this thing is far more likely than anywhere we do not.
-- Falls back to a plain disc when neither traversability nor memory can answer -
-- ignorance is a uniform prior, not a refusal to search.
function SF:seed(x, y, opts)
    opts = opts or {}
    self.anchor_x, self.anchor_y = x, y
    local R = opts.radius or SF.MAX_RADIUS
    local T = RaijinLab and RaijinLab.Traversability
    local cx0, cy0 = cell_of(x - R, y - R)
    local cx1, cy1 = cell_of(x + R, y + R)
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local mx, my = centre_of(cx, cy)
            local d = sqrt((mx - x) ^ 2 + (my - y) ^ 2)
            if d <= R then
                -- Mild inverse-distance prior: a thing you were sent to find is
                -- more often near than far, but never impossible far away.
                local m = 1.0 / (1.0 + d / 300.0)
                if T and T.factor then
                    local ok, fac = pcall(T.factor, mx, my, opts.z or 0)
                    -- Easy ground is likelier to hold a reachable target, and it
                    -- is cheaper to check - both point the same way.
                    if ok and type(fac) == "number" and fac == fac and fac > 0 then
                        m = m / fac
                    end
                end
                self:add(mx, my, m)
            end
        end
    end
    -- Remembered sightings dominate everything above: this is the difference
    -- between searching and guessing.
    local P = RaijinLab and RaijinLab.POI
    if P and P.nearest and opts.name then
        local rec = P.nearest(opts.kind or "spawn", x, y, opts.z or 0, { name = opts.name })
        if rec then self:hit(rec.x, rec.y, 25.0) end
    end
    return self
end

-- ---- mass -----------------------------------------------------------------

function SF:add(x, y, m)
    if not (m and m > 0) then return end
    local cx, cy = cell_of(x, y)
    self:_bump(cx, cy, m)
end

function SF:mass() return self.total end
function SF:count() return self.n end

-- ---- the update that matters ----------------------------------------------

-- WE LOOKED HERE AND SAW NOTHING. Remove mass from everything inside the sight
-- radius, not merely the cell under our feet - this is the whole correction. A
-- soft edge keeps the update honest: detection is not a step function, and
-- zeroing a hard disc would permanently discard places we only half-saw.
function SF:observe(x, y, radius)
    radius = radius or 200.0
    -- Iterate the AFFECTED BLOCKS, and inside them only cells that actually hold
    -- mass. Scanning the bounding box cell-by-cell costs the same whether the
    -- region is full or empty; this costs what is actually there, so a sparse
    -- field over a whole continent is as cheap as a dense one over a clearing.
    local removed = 0
    local bx0 = floor(floor((x - radius) / SF.CELL) / SF.BLOCK)
    local bx1 = floor(floor((x + radius) / SF.CELL) / SF.BLOCK)
    local by0 = floor(floor((y - radius) / SF.CELL) / SF.BLOCK)
    local by1 = floor(floor((y + radius) / SF.CELL) / SF.BLOCK)
    for bx = bx0, bx1 do
        for by = by0, by1 do
            local b = self.blocks[bx .. ":" .. by]
            if b and b.m > 0 then
                for cx = bx * SF.BLOCK, (bx + 1) * SF.BLOCK - 1 do
                    for cy = by * SF.BLOCK, (by + 1) * SF.BLOCK - 1 do
                        local m = self.cells[key_of(cx, cy)]
                        if m then
                            local mx, my = centre_of(cx, cy)
                            local d = sqrt((mx - x) ^ 2 + (my - y) ^ 2)
                            if d <= radius then
                                -- full confidence in the middle, tapering to
                                -- EDGE at the rim: detection is not a step
                                -- function, and zeroing a hard disc would
                                -- permanently discard half-seen ground.
                                local t = d / radius
                                local p = SF.DETECT + (SF.EDGE - SF.DETECT) * t * t
                                local cut = m * p
                                self:_bump(cx, cy, -cut)
                                removed = removed + cut
                            end
                        end
                    end
                end
            end
        end
    end
    if self.total < 0 then self.total = 0 end
    self.observed = self.observed + 1
    return removed
end

-- WE SAW ONE. Concentrate belief nearby: mobs of a kind cluster, and a sighting
-- is the strongest evidence available about where the rest are.
function SF:hit(x, y, weight)
    weight = weight or 10.0
    local R = SF.CLUSTER
    local cx0, cy0 = cell_of(x - R, y - R)
    local cx1, cy1 = cell_of(x + R, y + R)
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local mx, my = centre_of(cx, cy)
            local d = sqrt((mx - x) ^ 2 + (my - y) ^ 2)
            if d <= R then
                self:add(mx, my, weight * exp(-(d * d) / (2 * (R / 2) ^ 2)))
            end
        end
    end
end

-- ---- where to go next -----------------------------------------------------

-- Maximise EXPECTED INFORMATION PER UNIT OF TRAVEL. Not "nearest unvisited" and
-- not "highest probability": either alone misbehaves - the first wanders, the
-- second sprints across the zone for a marginal gain. The ratio is what makes it
-- behave like someone who actually wants to find the thing.
-- FULL CELL RESOLUTION AT BOUNDED COST. Two passes, neither of which degrades
-- the answer:
--   1. Rank BLOCKS by summed mass over travel cost. The sums are maintained
--      incrementally, so this pass reads them - it does not compute them.
--   2. Refine inside the best few blocks at FULL cell resolution, scoring each
--      cell by the mass its sight-disc would actually reveal.
-- The naive version scored every cell and summed its neighbourhood for each -
-- O(n^2), ~4 million operations on a 900yd field, evaluated inside a movement
-- loop. This is O(blocks + K * cells-per-block) and gives a STRICTLY better
-- answer, because the refinement pass uses a real sight-disc rather than a fixed
-- radius guess. Widen REFINE to spend more and see further; nothing here caps
-- how large the field may grow.
SF.REFINE = 6            -- blocks examined at full resolution

function SF:best(px, py, opts)
    opts = opts or {}
    local sight = opts.sight or 200.0
    local T = RaijinLab and RaijinLab.Traversability
    local mind = sight * 0.4

    local function cost_at(mx, my, d)
        local c = d
        if T and T.factor then
            local ok, fac = pcall(T.factor, mx, my, opts.z or 0)
            if ok and type(fac) == "number" and fac == fac and fac > 0 then
                c = d * fac              -- roads are cheap, hazard is dear
            end
        end
        return c
    end

    -- A LEG MUST STAY INSIDE THE FIELD'S OWN SUPPORT.
    --
    -- Observed live: the search proposed a target 10698 yards away and walked at
    -- it for fifty seconds. The field is seeded over MAX_RADIUS around an anchor,
    -- so nothing that far can be a legitimate belief cell - it is a stale key, a
    -- coordinate from another map, or arithmetic that escaped. Whatever produced
    -- it, proposing a ten-kilometre walk is wrong, and this is the cheapest place
    -- to be certain of it: where the answer leaves the field.
    --
    -- Measured from the ANCHOR, not the player: the player walks away from the
    -- anchor during a sweep, so a player-relative bound would drift along with
    -- the very error it exists to catch.
    local ax = self.anchor_x or px
    local ay = self.anchor_y or py
    local limit = (opts.max_leg or SF.MAX_RADIUS) * 1.5

    -- pass 1: rank blocks (read-only over maintained sums)
    local ranked, nr = {}, 0
    for i = 1, #self.border do
        local b = self.border[i]
        if b.m > SF.FLOOR then
            local bmx = (b.bx + 0.5) * SF.BLOCK * SF.CELL
            local bmy = (b.by + 0.5) * SF.BLOCK * SF.CELL
            if sqrt((bmx - ax) ^ 2 + (bmy - ay) ^ 2) > limit then
                -- outside the support: drop the mass so it cannot be reconsidered
                -- on the next call, rather than skipping it forever
                b.m = 0
            end
        end
        if b.m > SF.FLOOR then
            local mx = (b.bx + 0.5) * SF.BLOCK * SF.CELL
            local my = (b.by + 0.5) * SF.BLOCK * SF.CELL
            local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
            nr = nr + 1
            ranked[nr] = { b = b, s = b.m / (cost_at(mx, my, d) + 1.0) }
        end
    end
    if nr == 0 then return nil end
    table.sort(ranked, function(a, c) return a.s > c.s end)

    -- pass 2: refine inside the strongest blocks, at full cell resolution
    --
    -- `refine_n`, NOT `limit`: this shadowed the support bound above, so the
    -- in-refinement support check compared a DISTANCE IN YARDS against
    -- min(nr, REFINE) - a small integer like 3. Every cell farther than ~3yd
    -- from the anchor was marked d=-1, refinement never produced a candidate,
    -- and every leg the engine has ever taken came from the block-centre
    -- fallback below - which is quantized to 160yd blocks and skips the oracle.
    -- The live log shows it: every destination ever chosen (1840,1520 /
    -- 1840,1680 / 1840,1360) is exactly (n+0.5)*160. A one-letter naming
    -- collision quantized the entire search behaviour.
    local best_score, bx, by
    local refine_n = math.min(nr, SF.REFINE)
    for i = 1, refine_n do
        local b = ranked[i].b
        for cx = b.bx * SF.BLOCK, (b.bx + 1) * SF.BLOCK - 1 do
            for cy = b.by * SF.BLOCK, (b.by + 1) * SF.BLOCK - 1 do
                if self.cells[key_of(cx, cy)] then
                    local mx, my = centre_of(cx, cy)
                    if opts.oracle and opts.oracle(mx, my) == false then
                        -- geometry says no: not a place a character can stand.
                        -- Drop the mass THROUGH _bump - cells are plain numbers
                        -- and _bump also maintains the block index; removing the
                        -- key directly would leave block totals pointing at mass
                        -- that no longer exists, and ranking would keep visiting
                        -- the ghost.
                        local m2 = self.cells[key_of(cx, cy)]
                        if m2 and m2 > 0 then self:_bump(cx, cy, -m2) end
                    end
                    local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
                    if opts.oracle and not self.cells[key_of(cx, cy)] then d = -1 end
                    if sqrt((mx - ax) ^ 2 + (my - ay) ^ 2) > limit then
                        d = -1                  -- outside support: not a candidate
                    end
                    -- Standing still reveals nothing: a candidate must be far
                    -- enough that going there uncovers unseen ground.
                    if d > mind then
                        -- Gain is what the WHOLE TRIP reveals - everything within
                        -- sight of that spot, not the single cell.
                        local gain = self:neighbourhood(mx, my, sight)
                        local score = gain / (cost_at(mx, my, d) + 1.0)
                        if not best_score or score > best_score then
                            best_score, bx, by = score, mx, my
                        end
                    end
                end
            end
        end
    end
    -- Everything strong is too close to be worth walking to: fall back to the
    -- best block centre rather than refusing to move.
    if not bx then
        for i = 1, nr do
            local b = ranked[i].b
            local mx = (b.bx + 0.5) * SF.BLOCK * SF.CELL
            local my = (b.by + 0.5) * SF.BLOCK * SF.CELL
            -- The fallback must obey the same geometry veto as refinement: a
            -- block centre inside a building is exactly the destination that
            -- marched the bot into the same wall 18 times.
            if sqrt((mx - px) ^ 2 + (my - py) ^ 2) > mind
               and not (opts.oracle and opts.oracle(mx, my) == false) then
                return mx, my, ranked[i].s
            end
        end
        return nil
    end
    return bx, by, best_score
end

-- Total mass within `r` - used so a destination is judged by what the whole trip
-- would reveal, not by one cell in isolation.
-- A LEG WE COULD NOT REACH MUST STOP BEING THE BEST LEG.
--
-- observe() drains mass where we ARRIVE and look around. But a destination
-- behind a wall is never arrived at, so its mass survived every failure and
-- best() re-chose the identical cell forever - live log: 18/18 destination
-- picks were the same spot, each one a march into the same building. Navigation
-- failure is evidence too: not "the target is not there", but "I cannot search
-- there from here", which for a SEARCH is operationally the same thing. Drain
-- it like a look, and the next best() moves on.
function SF:unreachable(x, y, radius)
    return self:observe(x, y, radius or (SF.CELL * 1.5))
end

-- GEOMETRY VETO for best(). The field itself stays pure belief - geometry is
-- the caller's knowledge - so best() accepts an oracle instead of importing
-- NavGrid here. Returning false vetoes a candidate cell; the mass is dropped so
-- ranking does not immediately resurface it. nil/absent oracle = no veto, so
-- existing callers and tests are untouched.
function SF:neighbourhood(x, y, r)
    -- Exact, but it visits only blocks that hold mass, so an empty region costs
    -- nothing regardless of how large r is.
    local sum = 0
    local bx0 = floor(floor((x - r) / SF.CELL) / SF.BLOCK)
    local bx1 = floor(floor((x + r) / SF.CELL) / SF.BLOCK)
    local by0 = floor(floor((y - r) / SF.CELL) / SF.BLOCK)
    local by1 = floor(floor((y + r) / SF.CELL) / SF.BLOCK)
    for bx = bx0, bx1 do
        for by = by0, by1 do
            local b = self.blocks[bx .. ":" .. by]
            if b and b.m > SF.FLOOR then
                for cx = bx * SF.BLOCK, (bx + 1) * SF.BLOCK - 1 do
                    for cy = by * SF.BLOCK, (by + 1) * SF.BLOCK - 1 do
                        local m = self.cells[key_of(cx, cy)]
                        if m then
                            local mx, my = centre_of(cx, cy)
                            if sqrt((mx - x) ^ 2 + (my - y) ^ 2) <= r then
                                sum = sum + m
                            end
                        end
                    end
                end
            end
        end
    end
    return sum
end

-- Things move and respawn, so certainty must decay: without this, a zone swept
-- once is written off forever and a wandering target can never be found.
function SF:diffuse(rate)
    rate = rate or SF.SPREAD
    if rate <= 0 or self.n == 0 then return end
    local moves = {}
    for k, m in pairs(self.cells) do
        local cx, cy = k:match("(-?%d+):(-?%d+)")
        cx, cy = tonumber(cx), tonumber(cy)
        if cx then
            moves[#moves + 1] = { cx = cx, cy = cy, share = m * rate }
        end
    end
    for i = 1, #moves do
        local mv = moves[i]
        self:_bump(mv.cx, mv.cy, -mv.share)
        local q = mv.share * 0.25
        self:_bump(mv.cx + 1, mv.cy, q)
        self:_bump(mv.cx - 1, mv.cy, q)
        self:_bump(mv.cx, mv.cy + 1, q)
        self:_bump(mv.cx, mv.cy - 1, q)
    end
end

function SF:stats()
    return { cells = self.n, blocks = self.nblocks, mass = self.total,
             observations = self.observed }
end

if RaijinLab then RaijinLab.SearchField = SF end
return SF
