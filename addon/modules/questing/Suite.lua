-- Automated questing engine (state machine).
--
-- Composes the questing leaf modules and the shared services into one loop:
--   QuestLog   - WHAT to do   (parse the quest log: objectives, complete quests)
--   QuestOM    - WHERE it is  (find givers "!"/"?" and objectives via the OM's
--                              client-verified IsTiedToQuest flag)
--   QuestFrame - PAPERWORK    (accept / turn in / pick rewards, event-driven)
--   Nav        - MOVE         (this engine is the SOLE Nav driver while running -
--                              never run Grinder/Brain/Gatherer concurrently, they
--                              fight over the single Nav._active path)
--   Executor   - FIGHT        (the rotation does the actual casting on our target)
--
-- Core idea: the client already flags exactly the mobs/objects tied to an active
-- objective (Info.Quest.IsTiedToQuest, computed by the object manager). So a
-- SINGLE objective handler covers kill / collect / use-object / talk-to: go to
-- the nearest tied thing; if it is an attackable unit, kill it (rotation casts)
-- and loot; if a friendly unit, talk to it; if a game object, interact. The
-- objective TYPE only decides whether looting matters.
--
-- OUT-OF-RANGE TRAVEL: 3.3.5 exposes no coordinate database, so the engine used
-- to stop at "travel needed" whenever an objective left render range. It now
-- builds its own: QuestOM.observe() records every giver / turn-in / objective it
-- sees into the persistent POI store, and when nothing is visible the engine
-- travels back to the remembered position (long-range path via the hierarchical
-- planner) until the live scan can take over. A remembered spot that turns out to
-- be empty on arrival is forgotten, so the memory stays honest.

local Suite = {}
Suite.last = "idle"
Suite.state = "idle"
-- Per-quest script overrides: Suite.scripts[questId] = { accept=fn, objective=fn,
-- turnin=fn } for quests generic automation can't do (activities, vehicles,
-- use-item sequences). Hooked from the quest events below. Empty by default.
Suite.scripts = {}

local function now() return (GetTime and GetTime()) or 0 end

-- ---- configuration (RaijinLabDB.quest) -----------------------------------
local DEFAULTS = {
    enabled = false,
    auto_accept = true, auto_turnin = true,
    combat = true, use_rotation = true, loot = true,
    flee_hp = 20,                 -- % HP at which to disengage
    reward_policy = "quality", reward_index = nil,
    accept_elite = false, accept_group = false, accept_pvp = false,
    accept_daily = true, skip_trivial = false,
    arrive_dist = 3.5, interact_dist = 4.5, engage_dist = 25,
    giver_scan_dist = 80, objective_scan_dist = 120,
    stuck_secs = 4.0,
    memory_arrive = 12,           -- how close to a REMEMBERED spot before the live scan takes over
    observe_every = 1.0,          -- seconds between POI sighting recordings
    use_flightpaths = true,       -- take taxis for long hauls instead of running
    use_mount = true,             -- ride for medium/long legs, dismount to act
    use_rest = true,              -- eat/drink back to strength when hurt or oom
    use_vendor = true,            -- sell junk / repair / restock when needed
    use_director = true,          -- arbitrate goals by priority+urgency (vs fixed order)
    use_gather = true,            -- grab gather nodes we pass close to
    gather_radius = 40,           -- yd: only divert for a node already this close
}
local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    local q = RaijinLabDB.quest or {}
    RaijinLabDB.quest = q
    for k, v in pairs(DEFAULTS) do if q[k] == nil then q[k] = v end end
    return q
end

-- ---- shorthands (BEFORE brain log / context - Lua locals are not hoisted) -
local function Act() return RaijinLab and RaijinLab.Actions end
local function ppos()
    if RaijinLab and RaijinLab.ObjectPosition then return RaijinLab:ObjectPosition("player") end
end
local function opos(guid)
    if RaijinLab and RaijinLab.ObjectPosition and guid then return RaijinLab:ObjectPosition(guid) end
end
local function dist_to(x, y, z)
    local px, py, pz = ppos()
    if not (px and x) then return nil end
    -- NEVER DEGRADE TO 2D. Silently dropping the height when z is missing
    -- returns a CONFIDENT WRONG NUMBER: a corpse one floor below reads as
    -- "arrived", and every 3D decision above this quietly becomes a 2D one. That
    -- is the same trap as a fabricated dist=5 or a stub returning 0 - in range,
    -- confident, and meaningless.
    --
    -- We navigate in three dimensions, so a distance without a height is NOT A
    -- DISTANCE. Say we do not know, and let the caller supply a real z (every
    -- source can: the mesh stores a height per cell, and TraceGround answers
    -- live). A loud nil here is what forced Death.corpse_pos to ground itself
    -- properly instead of shipping a hole.
    if not (pz and z) then return nil end
    local dx, dy, dz = px - x, py - y, pz - z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function has_runtime()
    return RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()
end

-- ---- brain log -----------------------------------------------------------
-- Dual-write every meaningful decision: disk (DevLog) + Debug tab + Telemetry.
-- The bot standing still with an empty log is itself a bug - this is the fix.
local function qlog(event, kv)
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.info then Tel.info("quest", event, kv or {}) end
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then
        local parts = { tostring(event) }
        if type(kv) == "table" then
            for k, v in pairs(kv) do
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        DL.log("quest", table.concat(parts, " "))
    end
end

local function qlog_every(key, gap, event, kv)
    local t = now()
    Suite._qlog_last = Suite._qlog_last or {}
    if Suite._qlog_last[key] and (t - Suite._qlog_last[key]) < (gap or 2.0) then return end
    Suite._qlog_last[key] = t
    qlog(event, kv)
end

-- Snapshot "what is the brain thinking" for heartbeats / status.
function Suite.context()
    local c = cfg()
    local px, py, pz = ppos()
    local D = RaijinLab and RaijinLab.Director
    local goal = D and D._cur and D._cur.name or "none"
    local QL = RaijinLab and RaijinLab.QuestLog
    local qtitle, otext, okind = "-", "-", "-"
    if QL and QL.first_incomplete_objective then
        local ok, q, o = pcall(function()
            return QL.first_incomplete_objective({ skip = Suite._parked })
        end)
        if ok and q then qtitle = tostring(q.title or q.questId or "?") end
        if ok and o then
            otext = tostring(o.name or o.text or "?")
            okind = tostring(o.kind or "?")
        end
    end
    local g = Suite._goal
    local N = RaijinLab and RaijinLab.Navigator
    local nstate = N and N.state or (RaijinLab.Nav and RaijinLab.Nav.state) or "-"
    local tgt = Suite._act_tgt
    return {
        state = Suite.state or Suite.last or "?",
        goal = goal,
        quest = qtitle,
        obj = otext,
        okind = okind,
        runtime = has_runtime() and "yes" or "NO",
        px = px and string.format("%.1f", px) or "nil",
        py = py and string.format("%.1f", py) or "nil",
        pz = pz and string.format("%.1f", pz) or "nil",
        dest = g and string.format("%.0f,%.0f,%.0f", g.x or 0, g.y or 0, g.z or 0) or "none",
        nav = tostring(nstate),
        tgt = tgt and tostring(tgt.name or tgt.guid or "?") or "none",
        tdist = tgt and tgt.dist and string.format("%.1f", tgt.dist) or "-",
        tkind = tgt and tostring(tgt.kind or "-") or "-",
        interact_yd = c.interact_dist,
    }
end

local function set_state(s)
    local prev = Suite.state
    if s ~= prev then
        qlog("state", { from = prev, to = s })
    end
    Suite.state = s
    Suite.last = s
    -- Heartbeat even when state is sticky (standing on obj:interact / moving).
    -- pcall: never let logging crash the ticker (was: ppos nil -> whole suite dead).
    pcall(function() qlog_every("quest:hb", 2.0, "hb", Suite.context()) end)
    return s
end

-- ---- object manager: make sure it is enumerating -------------------------
-- NEVER force om.enable / InitObjectManager during suite-on warm window.
-- That path hard-crashed the client after login (OM walk + Lua enum same frame).
local function ensure_om()
    if not RaijinLab then return end
    local M = RaijinLab.Master
    if M and M.suite_om_safe and not M.suite_om_safe() then
        return -- Master owns the staggered arm
    end
    if RaijinLab.RuntimeCall then
        RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1")
    end
    if RaijinLab.GetObjManagerFrame and RaijinLab.InitObjectManager
        and not RaijinLab:GetObjManagerFrame() then
        RaijinLab:InitObjectManager()
    end
end

-- ---- movement with stuck detection ---------------------------------------
Suite._goal = nil
-- Move toward (x,y,z); returns "arrived" | "moving" | "stuck". Delegates the
-- actual locomotion to the steering Navigator (via Nav): face-and-run, jump,
-- object avoidance and stuck recovery all live there, so this just sets the
-- destination once and surfaces the state.
-- `opts.no_fly` - for movement that is LOCAL by nature. A search sweep leg can be
-- 900yd, which trips the long-haul flight-path branch below, and flying to a
-- waypoint you invented in order to look around is nonsense: it burns the trip,
-- lands somewhere else, and the sweep restarts. Travel to a real destination
-- still flies.
-- CAN WE ACTUALLY SEE THE WORLD?
--
-- The question the whole engine was missing. When the object snapshot is empty,
-- questing finds no givers and no objectives - and instead of STOPPING it fell
-- through to a belief-field search, which invents a destination from a
-- probability field and hands it to the navigator as if it were knowledge. The
-- analyzer caught the consequence exactly: "most common destination 1780,1620
-- chosen 9/9 (100%)". The user saw a bot walk in a circle and veer into a fence.
--
-- A search is only meaningful if the searcher can perceive what it is searching
-- for. With an empty snapshot every observation is a guaranteed miss, so the
-- belief field drains uniformly and the argmax is noise. Moving on noise is
-- worse than standing still: it burns the field, learns nothing, and looks
-- exactly like a broken bot.
--
-- Three-valued on purpose: nil/unknown does not block (we may simply be indoors
-- with nothing around); only a PROVEN blind state does - the runtime reporting
-- units while our snapshot holds none.
function Suite.perception_ok()
    local RL = RaijinLab
    local L = RL and RL.om and RL.om.object_list
    if not L then return false, "no object_list" end
    local seen = L.npcs and #L.npcs or 0
    if seen > 0 then return true end
    -- Empty snapshot is only damning if the runtime says there IS something.
    if RL.HasRuntime and RL:HasRuntime() and RL.RuntimeCall then
        local ok, n = pcall(RL.RuntimeCall, RL, "GetUnitCount")
        n = (ok and tonumber(n)) or 0
        if n > 0 then
            return false, string.format("blind: runtime sees %d units, engine snapshot 0", n)
        end
    end
    return true      -- genuinely nothing around: not a fault
end

local function goto_point(x, y, z, arrive, opts)
    opts = opts or {}
    arrive = arrive or cfg().arrive_dist
    local Nav = RaijinLab and RaijinLab.Nav
    if not Nav then return "moving" end
    local d = dist_to(x, y, z)
    if d and d <= arrive then
        Nav.cancel(); Suite._goal = nil
        return "arrived"
    end
    -- LONG HAUL: for a genuinely distant goal, walking the whole way is the wrong
    -- answer - a player would fly. Hand the decision to TravelNet, which weighs
    -- walk-to-flightmaster + overhead + flight against just walking.
    if not opts.no_fly and cfg().use_flightpaths ~= false
       and d and d > (Suite._fly_min or 600) then
        local st = Suite.try_flight(x, y, z, d)
        if st then return st end
    end
    -- MOUNT only for longer legs. At 60-100yd mount.maintain used to stop_fn
    -- (cancel Nav + clear _goal) every tick on level-3 chars still evaluating
    -- should_mount - that alone freezes displacement. Search never mounts.
    if cfg().use_mount ~= false and not opts.no_fly and not opts.no_mount
       and d and d >= 120 and RaijinLab.Mount then
        local mst = RaijinLab.Mount.maintain(d, {
            stop_fn = function()
                local a = Act()
                if a and a.StopMoving then pcall(a.StopMoving) end
                if Nav and Nav.cancel then Nav.cancel() end
                Suite._goal = nil
            end,
            near = math.max(arrive + 4, 12),
            min_dist = 120,
        })
        if mst then return mst end
    end
    -- DESTINATION HYSTERESIS. Only re-issue when the destination has genuinely
    -- moved, and not more often than REPLAN_GAP.
    local g = Suite._goal
    local eps = Suite.GOAL_EPS or 3.0
    local moved = (not g)
        or ((g.x - x) ^ 2 + (g.y - y) ^ 2 + ((g.z or 0) - (z or 0)) ^ 2) > eps * eps
    local Navigator = RaijinLab.Navigator
    local orphaned = g and Navigator and Navigator._active == nil
        and Navigator.state ~= "pathfinding"
    -- FROZEN DETECTOR: nav claims moving/pathfinding but player pos is unchanged.
    local px, py = ppos()
    if px and Suite._goto_last_px then
        local drift = (px - Suite._goto_last_px) ^ 2 + (py - (Suite._goto_last_py or py)) ^ 2
        if drift < 0.25 then
            if not Suite._goto_still_since then Suite._goto_still_since = now() end
        else
            Suite._goto_still_since = nil
        end
        if Suite._goto_still_since and (now() - Suite._goto_still_since) > 1.5 then
            qlog("goto_frozen", {
                d = d and math.floor(d) or -1,
                nav = Navigator and tostring(Navigator.state) or "?",
                px = string.format("%.1f", px), py = string.format("%.1f", py),
                dest = string.format("%.0f,%.0f", x, y),
            })
            -- HARD NUDGE: face goal + hold forward. Do not wait for turn cone.
            local a = Act()
            if a and px and x then
                local atan2 = math.atan2 or function(dy, dx)
                    return math.atan(dy / ((dx ~= 0 and dx) or 1e-9))
                end
                local ang = atan2(y - py, x - px)
                if a.Face then pcall(a.Face, ang) end
                if a.MoveForward then pcall(a.MoveForward, true) end
            end
            Suite._goal = nil
            Suite._goal_t = 0
            Suite._goto_still_since = nil
            orphaned = true
            opts = opts or {}
            -- Prefer pathfind on freeze, not forced straight-line into walls.
            opts.direct = false
        end
    end
    Suite._goto_last_px, Suite._goto_last_py = px, py

    if (moved and (now() - (Suite._goal_t or 0)) > (Suite.REPLAN_GAP or 1.0)) or orphaned then
        Suite._goal = { x = x, y = y, z = z }
        Suite._goal_t = now()
        Suite._goto_still_since = nil
        -- MESH / PATHFIND when the straight line is blocked or the leg is long.
        -- Live: go_live_giver used direct=true -> force_forward into building walls
        -- at d~22 while claiming "moving" with nav idle.
        local NG = RaijinLab.NavGrid
        local mesh_ready = NG and NG.at and (function()
            local ok, code = pcall(NG.at, x, y)
            return ok and code ~= nil
        end)()
        -- Default: ALWAYS pathfind for any real leg. Direct only for point-blank
        -- hops with clear LoS. The "mesh_ready OR d>40" gate still let short
        -- town walks (d=22 to a church NPC) go straight into the wall.
        local structure_on_path = false
        if NG and NG.at and NG.STRUCTURE and px then
            local steps = math.max(4, math.floor((d or 20) / 4))
            for i = 0, steps do
                local t = i / steps
                local sx = px + (x - px) * t
                local sy = py + (y - py) * t
                local okc, code = pcall(NG.at, sx, sy)
                if okc and code == NG.STRUCTURE then structure_on_path = true; break end
            end
        end
        -- `no_fly` MEANS "DO NOT TAKE A FLIGHT PATH". IT DOES NOT MEAN
        -- "DO NOT PLAN A ROUTE".
        --
        -- It was gating use_pf, so any caller that said "this leg is local, do
        -- not fly" also silently disabled the PATHFINDER. The search sweep -
        -- goto_point(tx, ty, tz, 18, { no_fly = true }) at the bottom of
        -- search_step, i.e. the bot's primary mode of exploration - therefore
        -- never planned a route in its life. Live log: not one [path] line and
        -- not one pathfind_to call in a whole session, only
        -- `move_to goal=(1780,1620) waypoints=0 arrive=18` for a goal 64 yards
        -- away. A straight-line beeline with no route is exactly the reported
        -- "ran straight at a wall".
        --
        -- Two different questions, two different flags: `no_fly` governs the
        -- flight-master branch above, `direct` governs planning.
        local use_pf = (not opts.direct)
            and d and d > 6 and d < 900
            and Navigator and Navigator.pathfind_to
        -- Only skip pathfind for tiny clear hops.
        if use_pf and d <= 12 and not structure_on_path and px and RaijinLab.TraceLine then
            local pz0 = select(3, ppos()) or z or 0
            local h = 1.6
            local okb, blocked = pcall(function()
                return RaijinLab:TraceLine(px, py, pz0 + h, x, y, (z or pz0) + h, 0x100111)
            end)
            if okb and not blocked then use_pf = false end
        end
        if use_pf then
            if RaijinLab.Scheduler and RaijinLab.Scheduler.start then
                pcall(RaijinLab.Scheduler.start)
            end
            Navigator.pathfind_to({ x = x, y = y, z = z }, {
                arrive_dist = arrive,
                force_forward = true,
                _no_los_shortcut = true,  -- never LoS->direct for suite travel
            })
        else
            if Navigator and Navigator.move_to then
                local ok = Navigator.move_to({ x = x, y = y, z = z }, {
                    arrive_dist = arrive,
                    force_forward = true,
                })
                if ok == false then
                    local F = RaijinLab.Fail
                    if F and F.clear then
                        pcall(F.clear, string.format("nav:stuck:%.0f:%.0f", x, y))
                    end
                    if Navigator.pathfind_to then
                        Navigator.pathfind_to({ x = x, y = y, z = z }, {
                            arrive_dist = arrive, force_forward = true,
                            _no_los_shortcut = true,
                        })
                    else
                        Navigator.move_to({ x = x, y = y, z = z }, {
                            arrive_dist = arrive, force_forward = true,
                        })
                    end
                end
            else
                Nav.request_move({ x = x, y = y, z = z }, { arrive_dist = arrive })
            end
        end
    end
    local st = Nav.tick(arrive)
    -- Idle with a still-valid goal: re-arm via PATHFIND, never bare move_to.
    -- Rate-limited: pathfind_to also no-ops when already pathfinding/moving the
    -- same goal, so we cannot cancel a live route with spam re-arms.
    if (st == "idle" or st == "stuck" or st == "failed")
        and Suite._goal and d and d > arrive then
        local tnow = now()
        if (tnow - (Suite._rearm_t or 0)) >= 1.2 then
            Suite._rearm_t = tnow
            local F = RaijinLab and RaijinLab.Fail
            if F and F.clear then
                pcall(F.clear, string.format("nav:stuck:%.0f:%.0f", x, y))
            end
            if Navigator and Navigator.pathfind_to then
                if RaijinLab.Scheduler and RaijinLab.Scheduler.start then
                    pcall(RaijinLab.Scheduler.start)
                end
                Navigator.pathfind_to({ x = x, y = y, z = z }, {
                    arrive_dist = arrive, force_forward = true, _no_los_shortcut = true,
                })
            elseif Navigator and Navigator.move_to then
                Navigator.move_to({ x = x, y = y, z = z }, {
                    arrive_dist = arrive, force_forward = true,
                })
            end
        end
        -- Report real navigator state - never lie "moving" when nav is idle.
        st = Nav.tick(arrive)
        if st == "pathfinding" or st == "moving" or st == "waypoint" then
            st = "moving"
        elseif st == "idle" or st == nil then
            st = "moving" -- intent held; re-arm will fire again after 1.2s
        end
    end
    do
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then
            Tel.on_change("goto", tostring(st), "nav", "goto",
                { d = d and math.floor(d) or nil, arrive = arrive })
            Tel.every("gotohb", 2.0, "nav", 4, "travel",
                { st = st, d = d and math.floor(d) or nil, gx = x, gy = y,
                  nst = Navigator and Navigator.state or "?",
                  px = px and math.floor(px) or nil, py = py and math.floor(py) or nil })
        end
    end
    if st == "arrived" then Suite._goal = nil; return "arrived" end
    if st == "stuck" or st == "failed" or st == "fell" then
        -- FAILURE IS EVIDENCE. Without this, the mass at an unreachable target
        -- survived and best() re-chose the identical cell forever - the bot ran
        -- at the same wall 18 times in one session. Draining it here is what
        -- makes the next choice a DIFFERENT place.
        --
        -- AT THE PICK RADIUS, not unreachable()'s 60yd default. best() scores a
        -- candidate by the mass within SIGHT of it, so a 60yd drain around a
        -- refused destination left the surrounding ring - including the 160yd
        -- POI-sighting spike seed() plants - fully intact, and the same cell
        -- stayed the argmax. Live: one destination chosen 24 of 39 times.
        --
        -- NOTE: "idle" is NOT a terminal failure here - it is re-armed above.
        local g = Suite._goal
        if g and g.x then
            for _, f in pairs(Suite._fields or {}) do
                if f and f.unreachable then
                    pcall(f.unreachable, f, g.x, g.y, Suite.SEARCH_SIGHT * 0.5)
                end
            end
        end
        Suite._goal = nil
        Suite._goal_t = 0
    end
    return st or "moving"
end

-- Interact with a nearby service NPC (merchant / trainer / flight master).
-- NOTE: Actions has no InteractUnit - the three call sites that used it were
-- silently no-ops, so the bot walked to the vendor and then stood there while the
-- errand goal held its slot forever. Resolve a real GUID and use A.Interact.
function Suite.interact_npc(rec)
    local a = Act()
    if not a then return false end
    local guid = nil
    local QOM = RaijinLab.QuestOM
    if rec and rec.e and rec.e ~= 0 and QOM and QOM.nearest_by_id then
        local hit = QOM.nearest_by_id(rec.e)
        if hit and hit.dist and hit.dist <= (cfg().interact_dist + 6) then guid = hit.guid end
    end
    -- Fall back to whatever is nearest and interactable in front of us.
    if not guid then
        local om = RaijinLab.om and RaijinLab.om.object_list
        local px, py, pz = ppos()
        if om and px then
            local best, bestd = nil, math.huge
            for i = 1, #(om.npcs or {}) do
                local st = om.npcs[i]
                if st and st.Guid and not (st.Info and st.Info.Unit and st.Info.Unit.Dead) then
                    if (not rec) or (not rec.n) or st.Name == rec.n then
                        local x, y, z = opos(st.Guid)
                        if x then
                            local d = math.sqrt((x-px)^2 + (y-py)^2 + ((z or 0)-(pz or 0))^2)
                            if d < bestd then best, bestd = st.Guid, d end
                        end
                    end
                end
            end
            if best and bestd <= (cfg().interact_dist + 6) then guid = best end
        end
    end
    if guid then
        if a.Target then pcall(a.Target, guid) end
        if a.Interact then pcall(a.Interact, guid); return true end
    end
    -- Last resort: interact with the current target.
    if a.Interact then pcall(a.Interact); return true end
    return false
end

-- Long-haul travel via the flight network. Returns a status string while it is
-- driving the trip, or nil to let normal walking handle it. Deliberately
-- conservative: if anything about the trip is unclear we walk, because a wrong
-- flight is far more expensive to undo than a long run.
function Suite.try_flight(gx, gy, gz, d)
    local TN = RaijinLab and RaijinLab.TravelNet
    if not TN then return nil end
    -- A ghost cannot fly, and a corpse run is often long enough to trip the
    -- long-haul threshold - which used to divert the ghost to a flight master and
    -- loop there instead of recovering the body.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return nil end
    -- Already flying: just wait it out, nav must not fight the taxi.
    if TN.on_taxi and TN.on_taxi() then
        local Nav = RaijinLab.Nav
        if Nav then Nav.cancel() end
        Suite._goal = nil
        return "travel:in flight"
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return nil end
    local px, py, pz = ppos()
    if not px then return nil end

    local ok, plan = pcall(TN.plan, px, py, pz, gx, gy, gz)
    if not (ok and plan and plan.mode == "fly" and plan.from_master) then return nil end

    -- Walk to the flight master first; the taxi window opening is handled by the
    -- normal interact path, and TAXIMAP_OPENED learns/refreshes the map.
    local fm = plan.from_master
    local fd = dist_to(fm.x, fm.y, fm.z)
    if fd and fd > (cfg().interact_dist or 4.5) then
        Suite._flight_target = plan.to_master and plan.to_master.n or nil
        local g = Suite._goal
        if not g or g.x ~= fm.x or g.y ~= fm.y then
            Suite._goal = { x = fm.x, y = fm.y, z = fm.z }
            local Navigator = RaijinLab.Navigator
            if Navigator and Navigator.pathfind_to then
                Navigator.pathfind_to({ x = fm.x, y = fm.y, z = fm.z },
                    { arrive_dist = cfg().interact_dist })
            else
                RaijinLab.Nav.request_move({ x = fm.x, y = fm.y, z = fm.z },
                    { arrive_dist = cfg().interact_dist })
            end
        end
        local st = RaijinLab.Nav.tick(cfg().interact_dist)
        return "travel:to flightmaster (" .. tostring(st or "moving") .. ")"
    end

    -- At the flight master. If the taxi window is up, take the flight; otherwise
    -- interact to open it.
    local want = Suite._flight_target or (plan.to_master and plan.to_master.n)
    if TaxiFrame and TaxiFrame:IsShown() and want then
        local flew = TN.take_flight(want)
        if flew then
            Suite._goal = nil
            return "travel:boarding flight to " .. tostring(want)
        end
        -- The node is not actually available from here - stop trying to fly.
        Suite._flight_target = nil
        return nil
    end
    -- Open the flight window (the giver/NPC interact path).
    local a = Act()
    Suite.interact_npc(plan.from_master)
    return "travel:opening flight map"
end

-- ---- combat --------------------------------------------------------------
local function in_combat()
    return (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
end
local function low_hp()
    if not (UnitHealth and UnitHealthMax) then return false end
    local mx = UnitHealthMax("player") or 0
    if mx <= 0 then return false end
    return (UnitHealth("player") / mx * 100) <= cfg().flee_hp
end
local function target_alive_enemy()
    return UnitExists and UnitExists("target")
        and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target"))
        and UnitCanAttack and UnitCanAttack("player", "target")
end
local function ensure_rotation()
    if not cfg().use_rotation then return end
    local Ex = RaijinLab and RaijinLab.RotationExecutor
    if Ex and not Ex._frame and Ex.start then Ex.start() end
end
-- Target + engage a hostile unit (rotation deals the damage).
local function engage(guid)
    local a = Act()
    if a then
        if a.Target then a.Target(guid) end
        if a.Attack then a.Attack() end
    end
    ensure_rotation()
end
-- Flee: cancel nav, run directly away from the current target for a moment.
local function flee()
    local Nav = RaijinLab and RaijinLab.Nav
    if Nav then Nav.cancel() end
    Suite._goal = nil
    local a = Act()
    if a and a.StopAttack then a.StopAttack() end
    local px, py, pz = ppos()
    local tx, ty, tz = opos(UnitGUID and UnitGUID("target"))
    if px and tx then
        local dx, dy = px - tx, py - ty
        local m = math.sqrt(dx * dx + dy * dy)
        if m > 0.1 then
            local fx, fy = px + (dx / m) * 25, py + (dy / m) * 25
            -- CLICK-TO-MOVE IS FORBIDDEN IN THIS PROJECT, INCLUDING ON THE PANIC
            -- PATH. a.MoveTo goes to the runtime's SafeCTM - the one thing this
            -- codebase is not allowed to do - and it sat here unnoticed because
            -- fleeing is rare. A hard constraint that holds only on the paths
            -- someone happened to review is not a constraint.
            --
            -- Steering handles this correctly anyway: the Navigator drives real
            -- movement keys, and running away is just a goal 25yd in the
            -- opposite direction. It also keeps obstacle avoidance, which CTM
            -- discards precisely when being cornered matters most.
            local Nv = RaijinLab.Navigator
            if Nv and Nv.move_to then
                Nv.move_to({ x = fx, y = fy, z = pz }, { arrive_dist = 4.0, no_avoid = false })
            elseif RaijinLab.Nav and RaijinLab.Nav.request_move then
                RaijinLab.Nav.request_move({ x = fx, y = fy, z = pz }, { arrive_dist = 4.0 })
            end
        end
    end
    return "flee(low hp)"
end

-- ---- loot ----------------------------------------------------------------
-- Interact the nearest lootable corpse within interact range (inline so we
-- never hand Nav to the free-running global Looter, which would StopMoving
-- mid-travel). Returns true if it kicked off a loot.
local function try_loot()
    if not cfg().loot then return false end
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om or not om.npcs then return false end
    local reach = cfg().interact_dist + 1.0
    local best, bestd = nil, math.huge
    for i = 1, #om.npcs do
        local s = om.npcs[i]
        if s and s.Info and s.Info.Unit and s.Info.Unit.Dead and s.Info.Unit.Lootable then
            local x, y, z = opos(s.Guid)
            local d = x and dist_to(x, y, z) or nil
            if d and d <= reach and d < bestd then best, bestd = s, d end
        end
    end
    if best then
        local a = Act()
        if a and a.Interact then a.Interact(best.Guid); return true end
    end
    return false
end

-- ---- death recovery ------------------------------------------------------
Suite._death_pos = nil
local function recover_death()
    -- Ghost? walk back to where we died and retrieve the corpse.
    if UnitIsGhost and UnitIsGhost("player") then
        local dp = Suite._death_pos
        if dp then
            local st = goto_point(dp.x, dp.y, dp.z, 18)
            if st == "arrived" then
                if RetrieveCorpse then RetrieveCorpse() end
                return "corpse:retrieve"
            end
            return "corpse:" .. st
        end
        return "corpse:unknown pos"
    end
    -- Just died (still a body): remember where, then release.
    local px, py, pz = ppos()
    if px then Suite._death_pos = { x = px, y = py, z = pz } end
    if RepopMe then RepopMe() end
    return "death:release"
end

-- ---- frame paperwork (event-driven; polled as a fallback) ----------------
local function drive_frames()
    local QF = RaijinLab and RaijinLab.QuestFrame
    if not QF then return nil end
    -- Older greeting frame.
    if QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown() then
        return QF.on_quest_greeting()
    end
    if GossipFrame and GossipFrame:IsShown() then
        return QF.on_gossip()
    end
    if QuestFrame and QuestFrame:IsShown() then
        if QuestFrameDetailPanel and QuestFrameDetailPanel:IsShown() then return QF.on_quest_detail() end
        if QuestFrameProgressPanel and QuestFrameProgressPanel:IsShown() then return QF.on_quest_progress() end
        if QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown() then return QF.on_quest_complete() end
    end
    return nil
end

-- ---- objective handling (unified) ----------------------------------------
-- Interact with unit OR world object. Logs success/failure so a silent stand-in-
-- front-of-chest is visible. Tries Actions + ObjectInteract + Face when possible.
local function interact(guid, why)
    why = why or "interact"
    if not guid then
        qlog("interact_fail", { why = why, err = "no_guid" })
        return false
    end
    -- Rate-limit: enough gap for the client to open a frame between tries.
    local tnow = now()
    if Suite._last_interact_t and (tnow - Suite._last_interact_t) < 1.0 then
        return Suite._last_interact_ok and true or false
    end
    Suite._last_interact_t = tnow
    -- Stand still before talking.
    local Nav = RaijinLab and RaijinLab.Nav
    if Nav and Nav.cancel then pcall(Nav.cancel) end
    local a = Act()
    if a and a.StopMoving then pcall(a.StopMoving) end
    if a and a.ensure then pcall(a.ensure) end
    local x, y, z = opos(guid)
    local d = (x and dist_to(x, y, z)) or -1
    local ok_target, ok_face, ok_interact = false, false, false
    local frame_open = (GossipFrame and GossipFrame:IsShown())
        or (QuestFrame and QuestFrame:IsShown())
    if frame_open then
        Suite._last_interact_ok = true
        return true
    end
    if a then
        if a.Target then ok_target = not not pcall(a.Target, guid) end
        if a.Face and x then
            local px, py = ppos()
            if px then
                local atan2 = math.atan2 or function(dy, dx)
                    return math.atan(dy / (dx ~= 0 and dx or 1e-9))
                end
                local ang = atan2(y - py, x - px)
                ok_face = not not pcall(a.Face, ang)
            end
        end
        -- Token path only: InteractUnit('target') after Target. Raw GUID is a no-op.
        if a.Interact then
            ok_interact = not not pcall(function() return a.Interact() end)
            if not ok_interact then
                ok_interact = not not pcall(function() return a.Interact(guid) end)
            end
        end
    end
    if not ok_interact and RaijinLab and RaijinLab.RuntimeCall then
        pcall(function() RaijinLab:RuntimeCall("TargetGuid", tostring(guid)) end)
        ok_interact = not not pcall(function()
            return RaijinLab:RuntimeCall("InteractTarget")
        end)
        if not ok_interact then
            ok_interact = not not pcall(function()
                return RaijinLab:RuntimeCall("Interact", tostring(guid))
            end)
        end
    end
    -- Did a frame actually open? FSExec "ok" is not proof of a dialog.
    frame_open = (GossipFrame and GossipFrame:IsShown())
        or (QuestFrame and QuestFrame:IsShown())
    -- DISPATCHED IS NOT DONE. VERIFY, THEN TRY THE OTHER DOOR.
    --
    -- The runtime returns true when the interact was DISPATCHED without throwing
    -- - it cannot see a dialog, so it cannot report one. Live: `ok=1 frame=0` at
    -- 4.2 yards, facing, targeted: everything reported success and no window
    -- opened, so the engine bounced back to "approach" and oscillated.
    --
    -- The frame is the only real evidence. Never call InteractUnit from addon
    -- Lua (taints secure path -> "RaijinLab tainted UNKNOWN()"). Runtime only.
    if not frame_open and UnitExists and UnitExists("target") then
        local A = RaijinLab and RaijinLab.Actions
        if A and A.Interact then
            pcall(A.Interact, "target")
            frame_open = (GossipFrame and GossipFrame:IsShown())
                or (QuestFrame and QuestFrame:IsShown())
            if frame_open then ok_interact = true end
        end
    end

    Suite._act_tgt = Suite._act_tgt or {}
    Suite._act_tgt.guid = guid
    Suite._act_tgt.dist = d
    -- Carry the promotion evidence with the attempt, so a silent interact can be
    -- judged against how good the reason for being here was.
    -- Published by the caller just before this runs (see accept/turnin below):
    -- `interact` only receives a guid, so reading a giver record here would be
    -- reading a nil upvalue - which is exactly what the first version did,
    -- leaving the flag-only rule-out permanently dead.
    Suite._act_tgt.evidence = Suite._pending_evidence or Suite._act_tgt.evidence
    Suite._act_tgt.last_interact = tnow
    Suite._act_tgt.ok = ok_interact
    Suite._last_interact_ok = ok_interact
    Suite._interact_fail_n = frame_open and 0 or ((Suite._interact_fail_n or 0) + 1)

    -- A FLAG-ONLY CANDIDATE IS DISPROVEN BY ONE SILENT INTERACT.
    --
    -- Objects with no database entry and no client status are promoted purely
    -- because a dynamic-flag bit is set and the SPARKLE/ACTIVATE mapping is not
    -- yet proven, so "any bit that is not NO_INTERACT" counts as interesting.
    -- Live that produced 16 such promotions, including gameobject 90641
    -- (dynflags 0x08, no name in the database, offers_new_quest false) which the
    -- engine walked to and interacted with repeatedly while a real quest giver
    -- stood 2.7 yards away.
    --
    -- A guess is allowed to be wrong once. The interact IS the experiment: no
    -- frame, no loot, nothing targeted means the flag did not mean what we
    -- hoped, and there is no reason to spend another approach on it. Givers with
    -- real evidence (a client status, or a database quest) keep the patient
    -- retry path, because for them a silent interact is usually range or timing.
    if not frame_open then
        local QOM = RaijinLab.QuestOM
        local ev = Suite._act_tgt and Suite._act_tgt.evidence
        if QOM and QOM.rule_out and ev == "flag" then
            QOM.rule_out(guid, "flag_only_interact_did_nothing")
            Suite._interact_fail_n = 0
            Suite._goal = nil
        end
    end
    qlog("interact", {
        why = why, guid = tostring(guid), dist = string.format("%.1f", d or -1),
        target = ok_target and 1 or 0, face = ok_face and 1 or 0,
        ok = ok_interact and 1 or 0, frame = frame_open and 1 or 0,
        fails = Suite._interact_fail_n or 0,
        pos = x and string.format("%.0f,%.0f,%.0f", x, y, z or 0) or "nil",
    })
    return ok_interact or frame_open
end

-- Act on a single OM objective struct: kill it if hostile, talk if friendly,
-- interact if it's an object. Returns a status string.
local function act_on_objective(t)
    local x, y, z = opos(t.guid)
    local d0 = x and dist_to(x, y, z) or nil
    Suite._act_tgt = {
        guid = t.guid, name = t.name, kind = t.kind, dist = d0,
        id = t.id,
    }
    if not x then
        qlog("obj_nopos", { name = t.name, guid = tostring(t.guid), kind = t.kind })
        return "obj:nopos"
    end
    if t.kind == "object" then
        local reach = (cfg().interact_dist or 4.5) + 1.5  -- objects need a bit more slack
        local st = goto_point(x, y, z, reach)
        qlog_every("obj:go:" .. tostring(t.guid), 2.0, "obj_go", {
            name = t.name, kind = "object", st = st,
            dist = string.format("%.1f", d0 or -1),
            dest = string.format("%.0f,%.0f,%.0f", x, y, z or 0),
        })
        if st == "arrived" then
            local ok = interact(t.guid, "object:" .. tostring(t.name or "?"))
            if RaijinLab.Watchdog then RaijinLab.Watchdog.note("interact") end
            return ok and "obj:interact-object" or "obj:interact-failed"
        end
        return "obj:" .. st
    end
    -- unit: decide hostile vs friendly by targeting and asking the client.
    local d = dist_to(x, y, z)
    if d and d <= cfg().engage_dist then
        local a = Act()
        if a and a.Target then a.Target(t.guid) end
        if UnitCanAttack and UnitCanAttack("player", "target")
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
            engage(t.guid)
            qlog_every("obj:eng:" .. tostring(t.guid), 2.0, "obj_engage", {
                name = t.name, dist = string.format("%.1f", d),
            })
            return "obj:engage"
        end
        -- friendly quest unit -> talk / interact within range
        if d <= cfg().interact_dist then
            local ok = interact(t.guid, "talk:" .. tostring(t.name or "?"))
            return ok and "obj:talk" or "obj:talk-failed"
        end
        local st = goto_point(x, y, z, cfg().interact_dist)
        return "obj:" .. st
    end
    local st = goto_point(x, y, z, math.min(cfg().engage_dist * 0.6, cfg().interact_dist + 2))
    qlog_every("obj:approach:" .. tostring(t.guid), 2.0, "obj_approach", {
        name = t.name, kind = t.kind, st = st,
        dist = string.format("%.1f", d or -1),
    })
    return "obj:" .. st
end

local function do_objective(q, o)
    -- 0) ESCORT. Following and defending an NPC is a completely different shape of
    -- objective - there is no destination, the NPC is the destination - so it is
    -- handled before the normal go-to-a-thing logic.
    local QI = RaijinLab.QuestInteract
    local ES = RaijinLab.Escort
    if QI and ES and QI.is_escort(q, o) then
        local npc = ES.find_npc({ max_dist = 90 })
        if npc then
            local st = ES.step({
                npc = npc,
                goto_fn = function(x, y, z, arrive) goto_point(x, y, z, arrive) end,
                engage_fn = engage,
                engage_dist = cfg().engage_dist,
            })
            return st or "escort:?"
        end
        -- no escort NPC in sight yet: fall through and go find/talk to the giver
    end

    -- 1) finish the current fight before wandering off.
    if target_alive_enemy() then engage(UnitGUID and UnitGUID("target")); return "obj:fighting" end
    -- 2) loot a fresh corpse (collect-from-kill / general loot).
    if try_loot() then return "obj:loot" end
    -- 2b) USE A QUEST ITEM. "Use the torch on the pyre" / "apply the bandage":
    -- these never complete by walking or killing, so try the item verb before the
    -- generic go-to-a-thing path. Only when the client actually gave us the item.
    if QI and QI.classify(o) == "use_item" then
        local st = Suite.try_quest_item(q, o)
        if st then return st end
    end
    -- 3) nearest client-tied objective MATCHING THIS OBJECTIVE'S TARGET.
    -- An unfiltered second lookup used to sit here as a fallback, so failing to
    -- find "Duskbat" handed back whatever tied thing happened to be physically
    -- closest and the bot walked off to work an unrelated quest's target while
    -- reporting progress on this one. Not finding the named thing means it is not
    -- in range - which is the patrol / memory / search case below, not a licence
    -- to chase something else.
    -- The unfiltered fallback is BACK, and it is safe now for a specific reason.
    --
    -- It was removed because it retargeted whatever was physically nearest - a
    -- chair, a mailbox, a guard. But that was never this call's fault: the object
    -- manager was flagging EVERY object as a quest objective, because the bridge
    -- returns a hardcoded 0 for ObjectIsQuestObjective and 0 is truthy in Lua.
    -- With that fixed at the source, nearest_objective returns only objects the
    -- client genuinely ties to one of our quests, so "any of my objectives" is a
    -- sensible answer rather than "any scenery".
    --
    -- And it is needed: for collect quests o.name is the ITEM name and for event
    -- objectives it is the whole phrase ("Bone Chip: 0/8"), neither of which ever
    -- equals an object's Name - so the filtered lookup alone silently never
    -- matches and those quest types stall forever.
    local t = RaijinLab.QuestOM.nearest_objective({ name = o and o.name, max_dist = cfg().objective_scan_dist })
        or RaijinLab.QuestOM.nearest_objective({ max_dist = cfg().objective_scan_dist })
    qlog_every("obj:pick", 3.0, "objective", {
        quest = tostring(q and (q.title or q.questId) or "?"),
        obj = tostring(o and (o.name or o.text) or "?"),
        okind = tostring(o and o.kind or "?"),
        found = t and tostring(t.name or t.guid) or "none",
        fkind = t and tostring(t.kind or "?") or "-",
        fdist = t and t.dist and string.format("%.1f", t.dist) or "-",
    })
    if not t then
        -- 4) Nothing in render range. If this is a KILL/collect objective we have
        -- worked before, the right behaviour is not to stand still and not to
        -- wander: walk the mob's actual spawn circuit, arriving as each camp
        -- repopulates. Only if we know no spawns at all do we fall back to the
        -- single remembered sighting.
        local pat = Suite.patrol_for(o)
        if pat then
            qlog_every("obj:patrol", 3.0, "objective_patrol", {
                quest = tostring(q and (q.title or q.questId) or "?"),
                obj = tostring(o and o.name or "?"), st = tostring(pat),
            })
            return pat
        end
        local mem = Suite.travel_to_memory("objective", o and o.name, q)
        qlog_every("obj:mem", 3.0, "objective_memory", {
            quest = tostring(q and (q.title or q.questId) or "?"),
            obj = tostring(o and o.name or "?"), st = tostring(mem),
        })
        return mem
    end
    return act_on_objective(t)
end

-- Go and do the shopping when the bags are full / gear is broken / food is out.
-- Returns a status string while the trip is in progress, or nil when there is
-- nothing to do (or nowhere known to do it, in which case we keep questing and
-- pick a merchant up along the way).
function Suite.vendor_trip()
    local V, P = RaijinLab.Vendor, RaijinLab.POI
    if not (V and P) then return nil end
    -- Already at the counter: the MERCHANT_SHOW handler does the business, so all
    -- that is left is to notice it is done and release the trip.
    if V.at_merchant() then
        Suite._vendor_goal = nil
        return "vendor:doing business"
    end
    local need, why = V.needs_vendor()
    if not need then Suite._vendor_goal = nil; return nil end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return nil end

    local px, py, pz = ppos()
    if not px then return nil end
    -- A repair need wants a repair-capable NPC specifically; anything else will
    -- do for selling and restocking.
    local kind = (why == "durability") and "repair" or "vendor"
    local rec, d = P.nearest(kind, px, py, pz)
    if not rec and kind == "repair" then rec, d = P.nearest("vendor", px, py, pz) end
    if not rec then
        -- Nothing remembered yet. Say so once rather than silently ignoring a
        -- real problem - the user may want to walk past a town.
        return nil
    end
    Suite._vendor_goal = rec
    local st = goto_point(rec.x, rec.y, rec.z, cfg().interact_dist)
    if st == "arrived" then
        Suite.interact_npc(rec)
        return "vendor:opening (" .. tostring(why) .. ")"
    end
    return "vendor:travelling to " .. tostring(rec.n or "merchant")
        .. " (" .. tostring(why) .. ", " .. st .. ")"
end

-- Opportunistic gathering. A human picks the herb they walk past; they do not
-- cross the zone for it. So this only engages a node that is already CLOSE, uses
-- the normal movement stack (pathfinder, mount, obstacle avoidance) rather than
-- driving Nav directly like the standalone Gatherer ticker did, and remembers the
-- node so we can come back once it respawns.
function Suite.gather_step()
    local G = RaijinLab.Gatherer
    if not G or not G.find_nearest_node then return nil end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return nil end
    local node = Suite._gather_node
    -- Re-scan unless we are already committed to a node that still exists.
    if not node or not node.guid then
        local ok, n = pcall(G.find_nearest_node)
        node = ok and n or nil
        Suite._gather_node = node
    end
    if not node then return nil end
    local d = dist_to(node.x, node.y, node.z)
    if not d or d > (cfg().gather_radius or 40) then
        Suite._gather_node = nil
        return nil
    end
    -- Remember it: gather nodes respawn, so a known node is worth revisiting.
    local P = RaijinLab.POI
    if P then
        local kind = (node.prof == "mining") and "ore" or "herb"
        pcall(P.record, kind, { x = node.x, y = node.y, z = node.z,
                                name = node.prof, entry = node.entry })
    end
    local st = goto_point(node.x, node.y, node.z, cfg().interact_dist)
    if st == "arrived" then
        local a = Act()
        if a and a.Interact then pcall(a.Interact, node.guid)
        elseif RaijinLab.ObjectInteract then pcall(RaijinLab.ObjectInteract, RaijinLab, node.guid) end
        Suite._gather_node = nil
        if RaijinLab.Watchdog then RaijinLab.Watchdog.note("gather") end
        return "gather:harvesting " .. tostring(node.prof or "node")
    end
    return "gather:moving to " .. tostring(node.prof or "node") .. " (" .. st .. ")"
end

-- Use a quest item, on the right target when the objective names one.
-- Returns a status string, or nil when this is not actually an item objective
-- (so the caller falls through to the normal handling rather than stalling).
function Suite.try_quest_item(q, o)
    local QI = RaijinLab and RaijinLab.QuestInteract
    if not QI then return nil end
    -- Prefer an item the client ties to THIS quest; otherwise one named by the
    -- objective text. If we hold no such item there is nothing to use yet -
    -- usually it still has to be looted, so fall through.
    local item = QI.item_for_quest(q and q.questId) or QI.item_by_name(o and o.name)
    if not item then return nil end

    -- Is there a specific thing to use it ON? The client flags quest-tied objects
    -- and units, so the nearest tied thing is the intended target.
    local t = RaijinLab.QuestOM.nearest_objective({ name = o and o.name, max_dist = cfg().objective_scan_dist })
        or RaijinLab.QuestOM.nearest_objective({ max_dist = cfg().objective_scan_dist })
    if t then
        local x, y, z = opos(t.guid)
        if x then
            local d = dist_to(x, y, z)
            if d and d > cfg().interact_dist then
                local st = goto_point(x, y, z, cfg().interact_dist)
                return "obj:carrying " .. tostring(item.name or "item") .. " (" .. st .. ")"
            end
            local ok = QI.use_item(item, t.guid)
            return ok and ("obj:used " .. tostring(item.name or "item") .. " on " .. tostring(t.name or "?"))
                or "obj:item use failed"
        end
    end
    -- No target: some quest items are simply used in the right place.
    local ok = QI.use_item(item, nil)
    return ok and ("obj:used " .. tostring(item.name or "item")) or nil
end

-- Spawn-point patrol for an objective whose target is not currently visible.
-- Returns a status string, or nil when we have no spawn memory to work with.
function Suite.patrol_for(o)
    local P = RaijinLab and RaijinLab.Patrol
    if not (P and o and o.name) then return nil end
    -- Only kill/collect objectives have a spawn circuit worth walking; a "talk to
    -- X" objective has exactly one location and is handled by memory travel.
    if o.kind ~= "kill" and o.kind ~= "collect" then return nil end
    local px, py, pz = ppos()
    if not px then return nil end
    local rec, d, why = P.next_point(o.name, px, py, pz)
    if not rec then
        if why == "all_recent" then
            -- Everything nearby was just cleared: hold position briefly rather
            -- than sprinting a pointless lap while the camps repopulate.
            return "obj:waiting for respawn (" .. tostring(o.name) .. ")"
        end
        return nil
    end
    local st = goto_point(rec.x, rec.y, rec.z, cfg().memory_arrive or 12)
    if st == "arrived" then
        P.mark_visited(rec)
        return "obj:patrol reached spawn (" .. tostring(o.name) .. ")"
    end
    return "obj:patrolling " .. tostring(o.name) .. " (" .. st .. ")"
end

-- ---- SEARCH: what a human does when they do not know where the thing is ----
--
-- An expanding outward sweep from where the search began, not a random walk and
-- not a straight line. Rings grow so the near ground is covered first; each ring
-- is rotated off the last so we are not retracing the same spokes; and within a
-- ring the candidate headings are SCORED by the traversability field, so the bot
-- prefers roads and open ground over hazard and drops - the same heatmap the
-- navigation uses, rather than a second opinion about the world.
--
-- Bounded on purpose: past SEARCH_MAX the thing is not in this area and the
-- caller's park-and-try-another logic should get its turn.
Suite.SEARCH_START = 40        -- yd: first ring (was 70 - flung level-1 chars 400yd)
Suite.SEARCH_STEP  = 45        -- yd: ring growth
Suite.SEARCH_MAX   = 700       -- yd: give up and let the quest be parked
Suite.INTERACT_FAILS  = 6      -- silent interacts before stepping back to retry
Suite.INTERACT_CYCLES = 2      -- reposition cycles before the giver is abandoned

-- WHEN HAS A GIVER PROVED IT WILL NEVER ANSWER?
--
-- Pure so it can be tested: the live path runs inside the approach loop, where
-- reproducing it needs navigation, an object manager and a real frame.
-- Repositioning used to reset the fail counter with no cycle count at all, so
-- against a target that can never respond the engine looped forever - walk in,
-- interact silently, step back, walk in - and never tried anything else.
function Suite.giver_exhausted(fail_n, cycle_n)
    return (fail_n or 0) >= Suite.INTERACT_FAILS
       and (cycle_n or 0) >= Suite.INTERACT_CYCLES
end
Suite.SEARCH_SPOKES = 8

function Suite.search_reset(key)
    Suite._search = Suite._search or {}
    if key then
        Suite._search[key] = nil
    else
        Suite._search = {}
        Suite._fields = nil        -- a full reset forgets the belief fields too
        Suite._seen = nil
        Suite._seen_n = nil
    end
end

-- Score a candidate point: prefer travelled ground and roads, avoid danger.
-- Falls back to neutral when the traversability field has nothing to say yet,
-- so an unmapped zone still gets searched instead of refusing every direction.
local function search_score(x, y, z)
    local T = RaijinLab and RaijinLab.Traversability
    if not (T and T.factor) then return 1 end
    local ok, f = pcall(T.factor, x, y, z)
    if not ok or type(f) ~= "number" or f ~= f then return 1 end
    return 1 / math.max(0.05, f)          -- lower travel cost = better candidate
end

-- Coverage memory. Coarse cells, so "have I looked here?" is a cheap lookup and
-- the sweep can be judged by ground COVERED rather than distance walked.
Suite.SEARCH_CELL = 60          -- yd

local function cell_key(x, y)
    return math.floor(x / Suite.SEARCH_CELL) .. ":" .. math.floor(y / Suite.SEARCH_CELL)
end

-- Sight radius used for belief updates. Deliberately conservative relative to the
-- client's render range: over-claiming what was seen permanently discards ground
-- that was only glimpsed, and a search that wrongly rules places out never
-- recovers.
-- SIGHT IS WHAT WE CAN DETECT, NOT HOW FAR WE CAN WALK.
--
-- These are two different distances and conflating them breaks the search in
-- opposite ways:
--   * SEARCH_MAX_LEG bounds TRAVEL. At 120 it was far too small - smaller than
--     the belief field itself - so every leg past 120yd was refused as absurd.
--   * SEARCH_SIGHT bounds DETECTION, and drains belief accordingly. Raising it
--     to 400 was wrong: the object manager only surfaces objectives within
--     objective_scan_dist (120yd), so a 400yd drain marks ground as "checked"
--     that was never actually looked at. Live effect: the bot drained the cell
--     containing its target without ever coming close enough to see it, then
--     orbited the rim of its own field at ~500yd forever.
--
-- So sight tracks the real detection radius, with a small margin for movement
-- between probes. Travel range is SEARCH_MAX_LEG and is deliberately large.
Suite.SEARCH_SIGHT = 140.0
-- yd: no single search leg may be longer than this. A sweep is LOCAL; a proposal
-- to cross the map is a bug in whatever produced the cell.
--
-- MUST EXCEED THE FIELD'S OWN SUPPORT BOUND, which is SearchField.MAX_RADIUS *
-- 1.5 (= 1350). Set below it, this backstop rejects perfectly legitimate legs and
-- the search refuses to move at all - two bounds that disagree are worse than
-- one, because the tighter one silently wins and looks like a different bug.
-- Cap single search legs. 1600yd "sweep" was not pathing - it was teleporting
-- the goal around the continent while the body jumped in place.
-- THE REFUSAL BOUND MUST NOT BE SMALLER THAN THE FIELD IT SEARCHES.
--
-- This was 120 while SearchField.MAX_RADIUS is 900: every leg past 120yd was
-- rejected as "absurd", so the sweep could never reach 80% of its own belief
-- field and reported "refused leg" forever. Live and in the simulator that is a
-- character standing still next to an objective 257yd away.
--
-- The bound exists to catch a genuinely broken proposal (a stale cell, another
-- map's coordinates, arithmetic that escaped) - not to cap normal travel. So it
-- sits just outside the field's own support: anything further cannot be a
-- legitimate belief cell, anything inside it is ordinary walking.
Suite.SEARCH_MAX_LEG = 1000.0

-- One belief field per objective, seeded lazily.
function Suite.search_field(key, px, py, pz, label, kind)
    Suite._fields = Suite._fields or {}
    local f = Suite._fields[key]
    local SF = RaijinLab and RaijinLab.SearchField
    if not f and SF then
        f = SF.new({ x = px, y = py })
        f:seed(px, py, { z = pz, name = label,
                         kind = (kind == "objective") and "spawn" or nil })
        Suite._fields[key] = f
    end
    return f
end

-- CAN A CHARACTER STAND THERE? The belief field is pure probability and knows
-- nothing about geometry, which is how 18 consecutive search legs pointed at
-- the inside of the same building. We have real client terrain (NavGrid tiles
-- extracted from the MPQs) - use it. Three-valued: only a definite "no" vetoes,
-- because an unloaded tile is ignorance, not a wall.
function Suite.search_oracle(x, y)
    local NG = RaijinLab.NavGrid
    if not (NG and NG.walkable) then return nil end
    -- A DESTINATION INSIDE A BUILDING IS ALWAYS WRONG, even though the same cell
    -- may well be walkable. walkable() answers UNKNOWN for STRUCTURE because the
    -- footprint is an axis-aligned box that also covers the courtyard - correct
    -- for "can I stand on this square", useless for "should I walk 80 yards to
    -- stand there". For choosing where to AIM, a footprint is strong evidence:
    -- there is no reason to pick the middle of a church as a search waypoint.
    if NG.at then
        local okc, code = pcall(NG.at, x, y)
        if okc and code == NG.STRUCTURE then return false end
    end
    local ok, verdict = pcall(NG.walkable, x, y)
    if not ok then return nil end
    -- NavGrid.walkable is Know-style three-valued: collapse only a proven no.
    local K = RaijinLab.Know
    if K and K.is_no and K.is_no(verdict) then return false end
    if verdict == false then return false end
    return nil
end

function Suite.search_for(kind, label, q)
    local px, py, pz = ppos()
    if not px then return kind .. ":searching (no position)" end

    -- KNOWLEDGE FIRST. NOTHING BELOW THIS IS REACHED IF WE KNOW.
    --
    -- Consulted before the belief field is even constructed, because every gate
    -- down there (module present? mass left?) can return first - and each one
    -- returns EXACTLY when knowing matters most: an empty field means we have no
    -- idea, which is precisely when the database should answer. Two ordering
    -- bugs in a row here, both caught by the same test.
    do
        local k2 = tostring(kind) .. ":" .. tostring(label)
        Suite._search = Suite._search or {}
        -- Same shape the normal path creates: `legs` is incremented later and a
        -- table without it threw "arithmetic on a nil value (field 'legs')".
        local dst = Suite._search[k2]
        if not dst then
            dst = { ax = px, ay = py, az = pz, legs = 0 }
            Suite._search[k2] = dst
        end
        dst.seen = dst.seen or {}
        local dbx, dby = Suite.known_target(label, px, py, dst.seen)
        if dbx then
            dst.tx, dst.ty = dbx, dby
            -- pz, never nil: dist_to does 3D maths and a nil z throws.
            local gst = goto_point(dbx, dby, pz, Suite.SEARCH_ARRIVE or 18,
                { no_fly = true })
            -- TRUST THE DISTANCE, NOT THE WORD.
            --
            -- goto_point reports "arrived" when the NAVIGATOR finishes its
            -- route, and a partial route ends at an intermediate waypoint. One
            -- spurious arrival marked the only known spawn as spent, after which
            -- known_target had nothing left and the bot parked - it travelled
            -- 79 of 398 yards and stopped dead. Only a real arrival counts.
            local dnow = math.sqrt((dbx - px) ^ 2 + (dby - py) ^ 2)
            if gst == "arrived" and dnow <= (Suite.SEARCH_ARRIVE or 18) * 1.5 then
                -- ARRIVING AT A SPAWN IS NOT FINDING THE TARGET.
                --
                -- A mob is not always standing on the first spawn point, so
                -- returning "arrived" here parked the bot on an empty patch of
                -- ground forever - a deterministic dead end, exactly as useless
                -- as a guessed one. Mark this point spent and let the next tick
                -- pick the next-nearest spawn; perception gets its chance first,
                -- because the caller re-scans before calling us again.
                dst.seen[#dst.seen + 1] = { x = dbx, y = dby }
                dst.tx, dst.ty = nil, nil
                return kind .. ":spawn empty, next known point (" .. tostring(label) .. ")"
            end
            return kind .. ":to known location (" .. tostring(label) .. ")"
        end
    end

    local key = tostring(kind) .. ":" .. tostring(label)
    Suite._search = Suite._search or {}
    local st = Suite._search[key]
    if not st then
        st = { ax = px, ay = py, az = pz, legs = 0 }
        Suite._search[key] = st
    end

    local field = Suite.search_field(key, px, py, pz, label, kind)
    if not field then
        -- No belief field available (module missing): say so rather than
        -- pretending to search, so the caller can park the quest.
        return kind .. ":none in range, none remembered (" .. tostring(label) .. ")"
    end

    -- WE ARE STANDING HERE AND CAN SEE. Remove belief from everything in sight,
    -- not from the cell under our feet - the previous sweep cleared footsteps
    -- while the character could see 200 yards, so it kept re-searching ground it
    -- had already looked at and could never converge.
    field:observe(px, py, Suite.SEARCH_SIGHT)


    -- Belief exhausted: the thing is not in this region. Hand back the stuck
    -- status the park logic watches for. This TERMINATES, which coverage-based
    -- search cannot - "somewhere I have not been" is an infinite set, whereas
    -- probability mass is finite and every observation consumes some.
    if field:mass() <= 0.5 then
        Suite._fields[key] = nil
        Suite._search[key] = nil
        return kind .. ":none in range, none remembered (" .. tostring(label) .. ")"
    end

    -- Choose the next leg when we have none, or have reached the last one.
    if not st.tx or ((px - st.tx) ^ 2 + (py - st.ty) ^ 2) < (18 * 18) then
        -- sight MUST be passed: best() otherwise defaults to a 200yd gain disc
        -- while every drain in this engine (arrival observe, refusal drains) is
        -- SEARCH_SIGHT or less. A destination judged by 200yd of mass but only
        -- ever drained over 150 keeps most of its score through any number of
        -- visits and refusals and stays the argmax - the pick radius and the
        -- drain radius must be the SAME number or the search ping-pongs to one
        -- spot (live: the same dest chosen 24 of 39 times).
        -- KNOWLEDGE BEFORE SEARCH.
        --
        -- A probability field is what you use when you do not know where the
        -- thing is. For anything in the shipped database we DO know: RaijinQuest
        -- carries the server's own spawn tables, and QuestDB turns them into
        -- world coordinates. Sweeping a belief field for a mob whose spawn point
        -- is on disk is how the bot ended up jogging into fences hunting a
        -- "Scavenger Paw" - which is loot, so no unit ever carried that name and
        -- perception could not have found it at any sensor quality.
        --
        -- Guarded three ways so this can only ever help: the zone must be
        -- CALIBRATED (QuestDB returns nil until the affine fit is solved AND
        -- still predicting), the point must be a sane distance, and any failure
        -- falls straight through to the field exactly as before.
        local bx, by
        if Suite.ALLOW_BELIEF_SEARCH then
            bx, by = field:best(px, py, {
                oracle = Suite.search_oracle,
                sight = Suite.SEARCH_SIGHT,
            })
        end
        if not bx then
            -- NOTHING IS GUESSED. EVER.
            --
            -- This used to fall back to a probability field: with no idea where
            -- the objective was it INVENTED a destination from a belief mass and
            -- committed the character to walking there. That is the "runs off in
            -- a random direction" behaviour, and it is not a tuning problem - a
            -- guessed destination is wrong by construction, and every layer below
            -- faithfully executes it.
            --
            -- We ship the server's own spawn tables (RaijinQuest), so "where is
            -- X" has a real answer whenever X is a real thing. When the database
            -- has nothing AND perception has nothing, the honest state is "I do
            -- not know where this is" - so say so and park the quest, which lets
            -- the engine pick a different one it CAN act on. Standing still with
            -- a reason beats moving without one.
            Suite._fields[key] = nil
            Suite._search[key] = nil
            qlog("no_known_location", { name = tostring(label), kind = tostring(kind) })
            return kind .. ":location unknown, parking (" .. tostring(label) .. ")"
        end
        if not bx then
            Suite._fields[key] = nil
            Suite._search[key] = nil
            return kind .. ":none in range, none remembered (" .. tostring(label) .. ")"
        end
        -- SECOND LINE OF DEFENCE. The field bounds its own answers, but this is
        -- the layer that actually commits the character to walking somewhere, so
        -- it refuses an impossible leg rather than trusting its supplier. Fifty
        -- seconds were spent walking at a target 10698 yards away because nothing
        -- here ever asked whether the distance was sane.
        --
        -- A REFUSED LEG MUST DRAIN ITS PROPOSER. This used to wipe the whole
        -- field and reset the search - which looked decisive but restored the
        -- problem: the caller keeps searching, search_field() reseeds next
        -- tick, and seed() re-plants the position-independent POI sighting
        -- spike - the exact mass that proposed the leg. The identical refusal
        -- then repeated forever (earlier sessions: 100% same-destination
        -- picks). Suppressing only the cell we refuse keeps the rest of the
        -- belief and makes the next best() a different answer.
        local leg = math.sqrt((bx - px) ^ 2 + (by - py) ^ 2)
        if leg > Suite.SEARCH_MAX_LEG then
-- DRAIN NARROWER THAN THE PICK DISC, DELIBERATELY.
-- Aligning best()'s sight with the drain radius was the right fix for the
-- re-pick loop. Widening every REFUSAL drain to the same 150yd was not: the
-- field's own POI spike spans ~160yd, so two refusals erased it entirely, mass()
-- fell under its floor, best() returned nil and no destination was ever produced
-- again - the simulator went to 0yd travelled, 100% stationary, in 5 scenarios.
-- A refusal is evidence about a PLACE, not about the whole neighbourhood.
            field:unreachable(bx, by, Suite.SEARCH_SIGHT * 0.5)
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel then Tel.warn("quest", "absurd_leg",
                { label = tostring(label), leg = math.floor(leg) }) end
            return kind .. ":searching (refused leg, mass="
                .. string.format("%.0f", field:mass()) .. ")"
        end
        st.tx, st.ty = bx, by
        st.tz = pz
        local WM = RaijinLab and RaijinLab.WorldMesh
        if WM and WM.ground_z and WM.cell_id then
            local okc, id = pcall(WM.cell_id, bx, by, pz)
            if okc and id then
                local okz, gz = pcall(WM.ground_z, id)
                if okz and type(gz) == "number" then st.tz = gz end
            end
        end
        st.legs = st.legs + 1
        -- MASS EXHAUSTION IS NOT A GUARANTEED TERMINATOR, so the sweep is also
        -- bounded by LEGS.
        --
        -- diffuse() deliberately leaks belief back to neighbours every pass,
        -- because targets move and respawn - without it a zone swept once is
        -- written off forever. But that means drain and spread are in a race, and
        -- once sight is the true detection radius (140yd) rather than an
        -- overstated one, spread can keep pace: the field never empties and the
        -- sweep never hands back control, so the quest is never parked and never
        -- retried by another route.
        --
        -- A leg budget terminates regardless of how that race is tuned. It is the
        -- honest statement too: "I have looked in N places and not found it" is
        -- exactly when a caller should try something else.
        if st.legs >= (Suite.SEARCH_MAX_LEGS or 60) then
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel and Tel.warn then
                Tel.warn("quest", "search_exhausted",
                    { label = tostring(label), legs = st.legs })
            end
            return kind .. ":none in range, none remembered (" .. tostring(label)
                .. ", searched " .. tostring(st.legs) .. " legs)"
        end
        -- Targets move and respawn, so certainty must decay. Without this a zone
        -- swept once is written off forever and a wandering mob is unfindable.
        field:diffuse()
    end

    -- REFUSE TO SEARCH BLIND. Do not hand the navigator a guessed destination
    -- when we cannot perceive the thing we are looking for.
    local psee, pwhy = Suite.perception_ok()
    if not psee then
        local DL = RaijinLab and RaijinLab.DevLog
        if DL and DL.log_every then
            DL.log_every("blind", 5.0, "quest",
                "REFUSING to search - %s (a guessed destination is not knowledge)",
                tostring(pwhy))
        end
        local Nv = RaijinLab and RaijinLab.Navigator
        if Nv and Nv.stop then pcall(Nv.stop) end
        return kind .. ":blocked " .. tostring(pwhy)
    end
    local gst = goto_point(st.tx, st.ty, st.tz, 18, { no_fly = true })
    if gst == "arrived" then
        -- A search waypoint is a step in a sweep, never a destination. Letting
        -- goto_point's "arrived" reach the caller ended the search outright.
        st.tx = nil
        return kind .. ":searching " .. tostring(label)
            .. " (mass=" .. string.format("%.0f", field:mass())
            .. ", legs=" .. tostring(st.legs) .. ")"
    end
    if gst == "failed" or gst == "no_path" or gst == "stuck"
        or gst == "fell" or gst == "idle" then
        -- Unreachable: treat it as observed so the same bearing cannot be chosen
        -- again, which is how the old sweep could livelock on a blocked heading.
        --
        -- ALL of goto_point's terminal failures, not just failed/no_path.
        -- goto_point abandons the goal on stuck/fell/idle too (it clears its
        -- own _goal and drains the fields) - but the search kept st.tx, so the
        -- very same destination was re-issued on the next tick, forever. A leg
        -- the mover has given up on is a REFUSED leg here, whatever the word.
        --
        -- And drain at the FULL pick radius: the old half-sight (75yd) drain
        -- was smaller than the disc best() scores a candidate by, so the mass
        -- ring around a refused destination kept it the argmax and it was
        -- re-picked immediately (live: same dest 24 of 39 picks).
        field:unreachable(st.tx, st.ty, Suite.SEARCH_SIGHT * 0.5)
        st.tx = nil
        return kind .. ":searching (rerouting, mass="
            .. string.format("%.0f", field:mass()) .. ")"
    end
    return kind .. ":searching " .. tostring(label)
        .. " (mass=" .. string.format("%.0f", field:mass())
        .. ", legs=" .. tostring(st.legs) .. ", " .. tostring(gst) .. ")"
end

-- ---- greeting a guessed quest giver --------------------------------------
--
-- The status sensor is a `return 0` stub, so the only way to learn whether an npc
-- has a quest is to talk to it and let the client answer. That answer does NOT
-- arrive on the tick the interact is sent: the packet goes to the server and the
-- quest / gossip frame turns up several frames later.
--
-- The old code greeted and called rule_out on the SAME tick, blacklisting every
-- candidate for 900 seconds before any frame could possibly open. The fallback
-- that exists to bootstrap giver memory could therefore never succeed even once -
-- it poisoned every npc it ever walked up to.
Suite.GREET_VERDICT_SECS = 6.0

local function frame_shown(f)
    if not (f and f.IsShown) then return false end
    local ok, v = pcall(f.IsShown, f)
    if not ok then return false end
    -- IsShown answers 1/nil on 3.3.5, and a 0 out of a stubbed frame must not
    -- read as "the dialog opened".
    return (v and v ~= 0) and true or false
end

-- Did a QUEST dialog open? Three-valued on purpose.
--
-- Counting any shown GossipFrame as proof caused a livelock: an innkeeper or a
-- guard opens a gossip window with no quest options, QF.on_gossip returns nil, so
-- Suite.tick never takes its `if fr then` branch, the pending greet is cleared as
-- "answered", and the same npc is greeted again next tick. Forty interacts on one
-- guard, forever - the reviewer reproduced exactly that.
--
-- A quest-less gossip is not "wait longer", it is a definite NO: we asked, and
-- this npc has nothing. Rule it out at once rather than timing out.
--   "yes"     - a real quest dialog
--   "no"      - a gossip window that demonstrably carries no quests
--   nil       - nothing open yet; keep waiting
local function greet_frame_verdict()
    if frame_shown(QuestFrameDetailPanel) or frame_shown(QuestFrameProgressPanel)
        or frame_shown(QuestFrameRewardPanel) or frame_shown(QuestFrameGreetingPanel)
        or frame_shown(QuestFrame) then
        return "yes"
    end
    if frame_shown(GossipFrame) then
        local na = (GetNumGossipActiveQuests and GetNumGossipActiveQuests()) or 0
        local nv = (GetNumGossipAvailableQuests and GetNumGossipAvailableQuests()) or 0
        if (tonumber(na) or 0) + (tonumber(nv) or 0) > 0 then return "yes" end
        return "no"          -- it answered, and the answer is "nothing here"
    end
    return nil
end

local function greet_frame_open()
    return greet_frame_verdict() == "yes"
end

-- The name we are still awaiting a verdict on, or nil once the greet is settled.
local function greet_pending()
    local g = Suite._greet_pending
    if not g then return nil end
    local v = greet_frame_verdict()
    if v == "yes" then
        Suite._greet_pending = nil
        return nil                          -- answered: the dialog drives from here
    end
    if v == "no" then
        -- Definite negative. Do not wait out the timer: this npc answered and has
        -- nothing, so retrying it is pure waste and closing the window frees the
        -- engine to move on.
        Suite._greet_pending = nil
        if RaijinLab.QuestOM and RaijinLab.QuestOM.rule_out then
            RaijinLab.QuestOM.rule_out(g.guid, "gossip_no_quests")
        end
        if CloseGossip then pcall(CloseGossip) end
        return nil
    end
    if (now() - (g.t or 0)) < (Suite.GREET_VERDICT_SECS or 6.0) then
        return g.name                       -- still waiting for an answer
    end
    -- Timed out with nothing shown at all: treat as no, but say why separately so
    -- the two causes stay distinguishable in the log.
    Suite._greet_pending = nil
    if RaijinLab.QuestOM and RaijinLab.QuestOM.rule_out then
        RaijinLab.QuestOM.rule_out(g.guid, "no_frame_timeout")
    end
    return nil
end

-- ---- judging a remembered spot on arrival ---------------------------------
Suite.MEMORY_COOLDOWN = 180        -- secs a fruitless remembered spot is parked
Suite.MEMORY_NPC_RADIUS = 20       -- yd: close enough to count as "standing here"
Suite._mem_cold = {}

local function mem_key(mem)
    local P = RaijinLab and RaijinLab.POI
    if P and P.key_of and mem and mem.rec then
        local k = P.key_of(mem.rec)
        if k then return k end
    end
    if mem and mem.x then return string.format("%.0f:%.0f", mem.x, mem.y) end
    return nil
end

local function mem_suppressed(mem)
    local k = mem_key(mem)
    if not k then return false end
    local t = Suite._mem_cold[k]
    if not t then return false end
    if (now() - t) > (Suite.MEMORY_COOLDOWN or 180) then
        Suite._mem_cold[k] = nil
        return false
    end
    return true
end

local function mem_suppress(mem)
    local k = mem_key(mem)
    if k then Suite._mem_cold[k] = now() end
end

-- The live npc standing at a remembered spot, if there is one. A giver POI holds
-- the PLAYER's position at the moment a frame opened, not the npc's, so the
-- nearest living npc to that spot is the best identification available; a name
-- match wins over mere proximity when we have a name.
local function npc_at(mem)
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not (om and om.npcs and mem and mem.x) then return nil end
    local named, namedd, any, anyd = nil, math.huge, nil, math.huge
    for i = 1, #om.npcs do
        local s = om.npcs[i]
        local dead = s and s.Info and s.Info.Unit and s.Info.Unit.Dead
        if s and s.Guid and not (dead and dead ~= 0) then
            local ox, oy, oz = opos(s.Guid)
            if ox then
                local dx, dy = ox - mem.x, oy - mem.y
                local dz = (oz or 0) - (mem.z or 0)
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= (Suite.MEMORY_NPC_RADIUS or 20) then
                    if d < anyd then any, anyd = s, d end
                    if mem.name and s.Name == mem.name and d < namedd then
                        named, namedd = s, d
                    end
                end
            end
        end
    end
    return named or any
end

-- Dialog-status role sets, mirrored from QuestOM (whose status_sets is local to
-- that file). Mirroring is deliberate, not drift: the old "ask QuestOM instead"
-- meant asking nearest_giver, and nearest_giver answers about whichever giver
-- happens to be CLOSEST anywhere in range - which is exactly how a different
-- nearby giver convicted THIS record. Per-npc set membership needs the sets
-- themselves; read the same RaijinLabDB override QuestOM reads so a user
-- override applies to both.
--   available 2/4/7/8 (!), complete 3/6/9/10 (?), 5 incomplete, 1 unavailable
local MEM_STATUS_AVAILABLE = { [2] = true, [4] = true, [7] = true, [8] = true }
local MEM_STATUS_COMPLETE  = { [3] = true, [6] = true, [9] = true, [10] = true }
local function giver_status_sets()
    local c = (RaijinLabDB and RaijinLabDB.quest and RaijinLabDB.quest.giver_status) or {}
    return c.available or MEM_STATUS_AVAILABLE, c.complete or MEM_STATUS_COMPLETE
end

-- Is the npc we remember here standing in front of us and PROVABLY not the giver
-- we came for? True only on positive PER-NPC evidence; every other answer is
-- false with a reason, because the caller deletes world memory on a true.
--
-- Two convictions this used to hand out were no evidence at all, and both
-- erased good turn-in memory (reviewer-confirmed):
--   * "the npc here answered SOME status outside the wanted set". The dialog
--     status is one aggregated byte per npc; an npc showing 7/8 (has a quest
--     to GIVE) can perfectly well also be a turn-in - one byte cannot say
--     both roles at once, so the byte naming the other role excludes nothing.
--   * "nearest_giver(want) names a different guid". That is a fact about
--     whichever giver is CLOSER, anywhere in range - not about this npc.
local function mem_disconfirmed(mem, kind, want, q)
    if kind ~= "giver" and kind ~= "turnin" then
        -- Objectives despawn and respawn by design, so an empty spawn point is a
        -- timer rather than a mistake and looking can never disprove it.
        return false, "objective"
    end
    local QOM = RaijinLab and RaijinLab.QuestOM
    if not (QOM and QOM.giver_status) then return false, "no_om" end
    local s = npc_at(mem)
    if not s then return false, "nobody_here" end
    -- IDENTITY FIRST. Guids are per-spawn and POIs persist across sessions, so
    -- name (or entry id) is the only identity a record can carry - and npc_at
    -- falls back to "whoever is nearest to the spot", so a bystander on the
    -- doorstep must not testify for the npc we remember. 0-truthy: an entry id
    -- out of a stubbed source is 0, which is "no identity", not entry zero.
    local name_known = (mem.name ~= nil and mem.name ~= "")
    local entry_known = (mem.entry and mem.entry ~= 0) and true or false
    if not (name_known or entry_known) then return false, "record_anonymous" end
    local matched = (name_known and s.Name == mem.name)
        or (entry_known and s.Id and s.Id ~= 0 and s.Id == mem.entry)
    if not matched then return false, "different_npc_here" end
    -- Query THIS npc, Guid first then Object, same as nearest_giver does.
    local st = QOM.giver_status(s.Guid)
    if not st and s.Object then st = QOM.giver_status(s.Object) end
    -- giver_status answers nil for "cannot tell" and never 0-as-an-answer, which
    -- is exactly the point: a stub that says 0 about the whole world convicts
    -- nobody. Deleting on its silence is what erased good turn-in POIs.
    if not st then return false, "sensor_silent" end
    local avail, complete = giver_status_sets()
    local wanted = (want == "complete") and complete or avail
    local other  = (want == "complete") and avail or complete
    if wanted[st] then return false, "confirmed_" .. tostring(st) end
    if other[st] then return false, "dual_role_possible_" .. tostring(st) end
    -- 5 = incomplete: he ends a quest we are still WORKING on. That confirms
    -- the turn-in relationship rather than denying it - forgetting on 5 would
    -- erase the memory at the exact moment it is proving itself.
    if st == 5 then return false, "in_progress" end
    if st == 1 then
        -- unavailable: a real per-npc answer outside every role set - nothing
        -- for us at all right now. But a record that names a DIFFERENT quest
        -- never claimed anything about the quest in hand, so this trip cannot
        -- disprove it (we may simply not hold that quest yet / any more).
        local qid = tonumber(q and (q.questId or q.questID or q.id) or nil)
        local recq = tonumber(mem.rec and mem.rec.q) or 0
        if recq ~= 0 and (not qid or recq ~= qid) then
            return false, "records_other_quest"
        end
        return true, "status_unavailable"
    end
    -- Anything else is outside the verified enum (the dialog-status table is
    -- still pending live verification): unknown is not "no".
    return false, "status_unverified_" .. tostring(st)
end

-- Head for a remembered location when nothing is visible. Returns a status string.
-- A remembered spot that is DISPROVED on arrival is forgotten; one that merely
-- shows us nothing is parked for a while and retried later.
function Suite.travel_to_memory(kind, name, q)
    local QOM = RaijinLab and RaijinLab.QuestOM
    local label = tostring(name or (q and q.title) or "?")
    if not QOM then return "obj:none in range (" .. label .. ")" end
    -- Settle the previous tick's greet before doing anything else: nominating a
    -- new candidate while a dialog is still in flight throws the answer away.
    local waiting = greet_pending()
    if waiting and (kind == "giver" or kind == "turnin") then
        return kind .. ":greeting " .. tostring(waiting)
    end
    local want = (kind == "giver") and "available" or "complete"
    local mem
    if kind == "objective" then
        mem = QOM.remembered_objective(name)
    else
        -- IDENTITY FIRST. This was a bare remembered_giver("complete"): the quest
        -- was passed in and dropped on the floor, so the engine walked to the
        -- nearest remembered turn-in of ANY quest and then judged THIS quest by
        -- what it found standing there. Prefer a record that identifies itself;
        -- fall back to nearest only when none does, because turn-in POIs are
        -- keyed on the npc name and we only learn that once a frame has opened.
        -- IDENTITY, NOT TITLE. This passed `name`, which at the turn-in call site
        -- is the QUEST TITLE, while turn-in POIs are keyed on the NPC name
        -- (QuestFrame records UnitName("npc")). A title never equals an npc name,
        -- so the filtered lookup always missed and the unfiltered one always won -
        -- leaving the "nearest turn-in of any quest" bug exactly as it was.
        --
        -- The quest id is the join that actually exists: POI.record/POI.nearest
        -- both support it. Prefer that, then an npc-name match, then anything.
        local qid = q and (q.questId or q.questID or q.id)
        if qid then mem = QOM.remembered_giver(want, { quest = qid }) end
        if not mem and name then mem = QOM.remembered_giver(want, { name = name }) end
        if not mem then mem = QOM.remembered_giver(want) end
    end
    -- A spot we already walked to and found nothing at is not a destination until
    -- its cooldown expires, or the engine paces back to it every single tick.
    if mem and mem_suppressed(mem) then mem = nil end
    if not mem then
        -- DEAD END, AND IT USED TO END HERE. Returning a status string and taking
        -- no action is what left a level-1 character standing in Deathknell for
        -- 166 minutes: the objective was never in range, nothing was remembered,
        -- so no destination was ever produced and the whole navigation stack was
        -- never invoked (nav and path logged ZERO lines all session).
        --
        -- Not knowing where something is, is not a reason to stand still. It is
        -- the reason to go and look.
        --
        -- LIVE STATUS first (runtime 1.8.10+ reads CGObject+0x90). Then greet
        -- candidates (QUESTGIVER bit). Search field only if nothing nearby.
        if (kind == "giver" or kind == "turnin") and RaijinLab.QuestOM.probe_sensor then
            pcall(RaijinLab.QuestOM.probe_sensor)
        end
        if (kind == "giver" or kind == "turnin") then
            local live = RaijinLab.QuestOM.nearest_giver(want)
            if live and live.dist and live.dist <= (cfg().giver_scan_dist or 80) then
                local cx, cy, cz = opos(live.guid)
                if cx then
                    local st2 = goto_point(cx, cy, cz, cfg().interact_dist or 4.5,
                        { no_mount = true })
                    if st2 == "arrived" then
                        interact(live.guid, kind .. ":" .. tostring(live.name or "?"))
                        return kind .. ":interact " .. tostring(live.name or "?")
                    end
                    return kind .. ":to " .. tostring(live.name or "?") .. " (" .. st2 .. ")"
                end
            end
            local c = RaijinLab.QuestOM.nearest_giver
                and RaijinLab.QuestOM.nearest_giver(want, { allow_candidates = true })
            if c and c.dist and c.dist <= 50 then
                local Tel = RaijinLab and RaijinLab.Telemetry
                if Tel and Tel.every then
                    Tel.every("quest:candidate", 10, "quest", 3, "greet_candidate",
                        { name = tostring(c.name), dist = math.floor(c.dist or 0) })
                end
                local cx, cy, cz = opos(c.guid)
                if cx then
                    local st2 = goto_point(cx, cy, cz, cfg().interact_dist or 4.5,
                        { no_mount = true })
                    if st2 == "arrived" then
                        interact(c.guid, kind .. "_cand:" .. tostring(c.name or "?"))
                        Suite._greet_pending = { guid = c.guid, name = c.name, t = now() }
                        return kind .. ":greeting " .. tostring(c.name)
                    end
                    return kind .. ":approaching " .. tostring(c.name) .. " (" .. st2 .. ")"
                end
            end
        end
        -- Giver/turnin: NEVER belief-search as the first response to "no memory".
        -- That is the random-direction bug. Prefer live status (already tried
        -- above) then candidates; search_for only for kill/collect objectives.
        if kind == "giver" or kind == "turnin" then
            local cand = RaijinLab.QuestOM.nearest_giver
                and RaijinLab.QuestOM.nearest_giver(
                    (kind == "turnin") and "complete" or "available",
                    { allow_candidates = true })
            if cand and cand.guid and (not cand.dist or cand.dist <= 50) then
                local cx, cy, cz = cand.x, cand.y, cand.z
                if not cx then cx, cy, cz = opos(cand.guid) end
                if cx then
                    local st2 = goto_point(cx, cy, cz, cfg().interact_dist or 4.5,
                        { no_mount = true })
                    if st2 == "arrived" then
                        interact(cand.guid, kind .. "_cand:" .. tostring(cand.name or "?"))
                        Suite._greet_pending = { guid = cand.guid, name = cand.name, t = now() }
                        return kind .. ":greeting " .. tostring(cand.name or "?")
                    end
                    return kind .. ":approaching " .. tostring(cand.name or "?")
                        .. " (" .. st2 .. ")"
                end
            end
            return kind .. ":waiting for live status / candidate (no random search)"
        end
        return Suite.search_for(kind, label, q)
    end
    local st = goto_point(mem.x, mem.y, mem.z, cfg().memory_arrive or 12)
    if st == "arrived" then
        -- STANDING HERE AND SEEING NOTHING USED TO BE ENOUGH TO DELETE THIS.
        -- It is not evidence. The only sensor that can say "this npc has no quest
        -- for you" is ObjectQuestGiverStatus, and while that is a `return 0` stub
        -- it says nothing about anybody - so arriving at a perfectly good turn-in
        -- erased the one memory that could have finished the quest, permanently
        -- and on every visit. Silence is not disconfirmation.
        local gone, why = mem_disconfirmed(mem, kind, want, q)
        local P = RaijinLab.POI
        if gone and P and mem.rec then
            P.forget(mem.rec)
            return kind .. ":memory disproved, forgotten (" .. label
                .. ", " .. tostring(why) .. ")"
        end
        -- Keep the record and stop pacing back to it: park it for a cooldown.
        -- For giver/turnin do NOT random-search; wait for live status to refill.
        mem_suppress(mem)
        if kind == "giver" or kind == "turnin" then
            return kind .. ":memory empty here, waiting for live status"
        end
        return Suite.search_for(kind, label, q)
    end
    return kind .. ":travelling to remembered " .. label .. " (" .. st .. ")"
end

-- ---- givers: accept + turn in --------------------------------------------
local function do_accept(g)
    if not g or not g.guid then return "accept:noguid" end
    local x, y, z = g.x, g.y, g.z
    if not x then x, y, z = opos(g.guid) end
    if not x then
        -- Position unreadable: still Target+Interact (status may already be 8).
        Suite._pending_evidence = g.evidence
        interact(g.guid, "accept:" .. tostring(g.name or "?"))
        return "accept:interact_nopos " .. tostring(g.name or g.guid)
            .. " st=" .. tostring(g.status or "?")
    end
    -- No direct=true: path around buildings to the ! giver.
    local st = goto_point(x, y, z, cfg().interact_dist, { no_mount = true })
    if st == "arrived" then
        Suite._pending_evidence = g.evidence
        interact(g.guid, "accept:" .. tostring(g.name or "?"))
        return "accept:interact " .. tostring(g.name or "")
            .. " st=" .. tostring(g.status or "?")
    end
    return "accept:to " .. tostring(g.name or "?")
        .. " st=" .. tostring(g.status or "?")
        .. " d=" .. string.format("%.0f", g.dist or -1)
        .. " (" .. st .. ")"
end
local function do_turnin(q)
    local scan = cfg().giver_scan_dist or 80
    -- 1) Live complete status (DialogStatus 9/10) - preferred. NEVER fall past a
    -- lit yellow ? into belief-field search: that is the "random wrong direction"
    -- the player sees. nearest_giver now scans GetNpcWithIndex too.
    local g = RaijinLab.QuestOM.nearest_giver("complete")
    if g and g.guid and (not g.dist or g.dist <= scan) then
        local x, y, z = g.x, g.y, g.z
        if not x then x, y, z = opos(g.guid) end
        if x then
            local st = goto_point(x, y, z, cfg().interact_dist, { no_mount = true })
            if st == "arrived" then
        Suite._pending_evidence = g.evidence
                interact(g.guid, "turnin:" .. tostring(g.name or "?"))
                return "turnin:interact " .. tostring(g.name or g.guid)
            end
            return "turnin:to " .. tostring(g.name or "?")
                .. " st=" .. tostring(g.status or "?")
                .. " d=" .. string.format("%.0f", g.dist or -1)
                .. " (" .. st .. ")"
        end
        -- Have a live complete GUID but no position: still try interact if we
        -- are already next to something (target/mouseover).
        if g.dist and g.dist <= (cfg().interact_dist or 4.5) + 2 then
            interact(g.guid, "turnin:" .. tostring(g.name or "?"))
            return "turnin:interact_nopos " .. tostring(g.name or g.guid)
        end
    end
    -- 2) Probe to force status queries, then re-scan.
    if RaijinLab.QuestOM.probe_sensor then pcall(RaijinLab.QuestOM.probe_sensor) end
    g = RaijinLab.QuestOM.nearest_giver("complete")
    if g and g.guid and (not g.dist or g.dist <= scan) then
        local x, y, z = g.x, g.y, g.z
        if not x then x, y, z = opos(g.guid) end
        if x then
            local st = goto_point(x, y, z, cfg().interact_dist, { no_mount = true })
            if st == "arrived" then
        Suite._pending_evidence = g.evidence
                interact(g.guid, "turnin:" .. tostring(g.name or "?"))
                return "turnin:interact " .. tostring(g.name or g.guid)
            end
            return "turnin:to " .. tostring(g.name or "?") .. " (" .. st .. ")"
        end
    end
    -- 3) Candidates (QUESTGIVER bit / friendly) - greet to open dialog. Still a
    -- real NPC, never a random belief cell.
    local cand = RaijinLab.QuestOM.nearest_giver
        and RaijinLab.QuestOM.nearest_giver("complete", { allow_candidates = true })
    if cand and cand.guid and (not cand.dist or cand.dist <= 50) then
        local x, y, z = cand.x, cand.y, cand.z
        if not x then x, y, z = opos(cand.guid) end
        if x then
            local st = goto_point(x, y, z, cfg().interact_dist, { no_mount = true })
            if st == "arrived" then
                interact(cand.guid, "turnin_cand:" .. tostring(cand.name or "?"))
                Suite._greet_pending = { guid = cand.guid, name = cand.name, t = now() }
                return "turnin:greeting " .. tostring(cand.name or "?")
            end
            return "turnin:approaching " .. tostring(cand.name or "?") .. " (" .. st .. ")"
        end
    end
    -- 4) Memory POI.
    local mem = nil
    if RaijinLab.QuestOM.remembered_giver then
        local qid = q and (q.questId or q.questID or q.id)
        if qid then mem = RaijinLab.QuestOM.remembered_giver("complete", { quest = qid }) end
        if not mem then mem = RaijinLab.QuestOM.remembered_giver("complete") end
    end
    if mem and mem.x then
        local st = goto_point(mem.x, mem.y, mem.z, cfg().memory_arrive or 12)
        if st == "arrived" then
            return "turnin:at memory, looking for NPC"
        end
        return "turnin:to memory (" .. st .. ")"
    end
    -- 5) Last resort: nearest friendly/QUESTGIVER-flagged NPC even without a
    -- status match. Idle "waiting" looked like /raijin quest on did nothing.
    local any = RaijinLab.QuestOM.candidate_giver and RaijinLab.QuestOM.candidate_giver()
    if any and any.guid then
        local x, y, z = any.x, any.y, any.z
        if not x then x, y, z = opos(any.guid) end
        if x then
            local st = goto_point(x, y, z, cfg().interact_dist, { no_mount = true })
            if st == "arrived" then
                interact(any.guid, "turnin_any:" .. tostring(any.name or "?"))
                Suite._greet_pending = { guid = any.guid, name = any.name, t = now() }
                return "turnin:greeting nearest " .. tostring(any.name or "?")
            end
            return "turnin:to nearest " .. tostring(any.name or "?") .. " (" .. st .. ")"
        end
    end
    return "turnin:no giver in range (status empty, no candidates)"
end

-- ---- main tick -----------------------------------------------------------

-- ---- public hooks for the Director ---------------------------------------
-- The goal bindings live in Goals.lua and must not reach into this file's
-- locals, so the handful of primitives they need are exposed here.
function Suite._goto_public(x, y, z, arrive) return goto_point(x, y, z, arrive) end
function Suite._flee_public() return flee() end
function Suite._stop_public()
    local a = Act()
    if a and a.StopMoving then pcall(a.StopMoving) end
    local Nav = RaijinLab.Nav
    if Nav and Nav.cancel then Nav.cancel() end
    Suite._goal = nil
end
-- Combat: keep fighting whatever we are engaged with. The rotation does the
-- casting; this only makes sure we stay on target instead of wandering away.
function Suite._combat_public()
    if target_alive_enemy() then
        engage(UnitGUID and UnitGUID("target"))
        return "combat:fighting"
    end
    if try_loot() then return "combat:loot" end
    -- Our target died but we are STILL in combat: something else is hitting us.
    -- Returning nil here let the Director fall through to `progress`, which would
    -- take Nav and walk away from a mob mid-fight. Re-acquire instead, and hold
    -- the slot while combat lasts so nothing below this band can steer.
    if in_combat() then
        local a = Act()
        if a and a.TargetNearestEnemy then pcall(a.TargetNearestEnemy) end
        if target_alive_enemy() then
            engage(UnitGUID and UnitGUID("target"))
            return "combat:re-acquired"
        end
        return "combat:holding"
    end
    return nil
end

-- Visit a class trainer when we have levelled since the last visit.
function Suite.trainer_trip()
    local T, P = RaijinLab.Trainer, RaijinLab.POI
    if not (T and P) then return nil end
    if T.at_trainer() then return "trainer:learning" end
    local need = T.needs_training()
    if not need then return nil end
    if in_combat() then return nil end
    local px, py, pz = ppos()
    if not px then return nil end
    local rec, d = P.nearest("trainer", px, py, pz)
    if not rec then return nil end
    local st = goto_point(rec.x, rec.y, rec.z, cfg().interact_dist)
    if st == "arrived" then
        Suite.interact_npc(rec)
        return "trainer:opening"
    end
    return "trainer:travelling (" .. st .. ")"
end

-- Walk to a live DialogStatus giver (position may be missing - interact still).
-- NEVER force direct=true: that walked straight through buildings (live: "ran
-- into a wall" at d=22 toward a st=10 NPC). goto_point pathfinds when LoS is
-- blocked or mesh is available; short clear approaches stay direct by policy.
local function go_live_giver(g, verb)
    if not (g and g.guid) then return nil end
    local x, y, z = g.x, g.y, g.z
    if not x then x, y, z = opos(g.guid) end
    local tag = tostring(g.name or g.guid)
    local stn = tostring(g.status or "?")
    -- If a quest/gossip frame is already open, let drive_frames handle it.
    if (GossipFrame and GossipFrame:IsShown())
        or (QuestFrame and QuestFrame:IsShown()) then
        return verb .. ":frame_open " .. tag .. " st=" .. stn
    end
    if not x then
        interact(g.guid, verb .. ":" .. tag)
        return verb .. ":interact_nopos " .. tag .. " st=" .. stn
    end
    -- ONCE IN RANGE, STAND STILL AND TALK.
    --
    -- goto_point was re-issued every tick while interacting, and the npc's
    -- position is re-read each time, so the destination jittered by a yard or
    -- two constantly: (1861,1605) -> (1863,1607) -> (1862,1601). Every jitter
    -- re-planned and re-committed the character, which is the "stuttery, very
    -- robotic, moving in place" behaviour - and a failed interact bounced
    -- straight back into approach, making it worse.
    --
    -- Interact range is a place to STAND, not a target to chase. Once inside it,
    -- stop steering entirely: interact, and only resume moving if we genuinely
    -- drift out (with hysteresis, so millimetre noise cannot restart the walk).
    local arrive = math.min(cfg().interact_dist or 4.5, 3.5)
    local dnow0 = dist_to(x, y, z)
    local hold = (cfg().interact_dist or 4.5) + 1.0
    if dnow0 and dnow0 <= hold then
        Suite._goal = nil
        local Nav0 = RaijinLab and RaijinLab.Nav
        if Nav0 and Nav0.cancel then pcall(Nav0.cancel) end
        local a0 = Act()
        if a0 and a0.StopMoving then pcall(a0.StopMoving) end
        interact(g.guid, verb .. ":" .. tag)
        return verb .. ":interact " .. tag .. " st=" .. stn
    end
    local st = goto_point(x, y, z, arrive, { no_mount = true })
    if st == "arrived" then
        Suite._goal = nil
        local Nav = RaijinLab and RaijinLab.Nav
        if Nav and Nav.cancel then pcall(Nav.cancel) end
        interact(g.guid, verb .. ":" .. tag)
        local dnow = dist_to(x, y, z) or -1
        -- AN UNREACHABLE GIVER MUST EVENTUALLY BE ABANDONED.
        --
        -- Repositioning resets the fail counter, so with a target that can never
        -- answer this loop ran FOREVER: walk in, interact silently, step back 4
        -- yards, walk in again. Live, the bot did exactly that against a quest
        -- flagged object it could reach but not use - it never tried anything
        -- else, because nothing ever concluded the attempt had failed.
        --
        -- Two repositions is enough evidence. Rule the guid out (the same 900s
        -- blacklist gossip and frame-timeout already use) so the next-best
        -- candidate gets a turn, and reset the cycle counter with it.
        local tries = Suite._interact_cycle_n or 0
        if Suite.giver_exhausted(Suite._interact_fail_n, tries) then
            Suite._interact_fail_n, Suite._interact_cycle_n = 0, 0
            local QOM = RaijinLab.QuestOM
            if QOM and QOM.rule_out then QOM.rule_out(g.guid, "interact_no_response") end
            Suite._goal = nil
            return verb .. ":gave_up " .. tag .. " st=" .. stn
        end
        -- After many silent interacts, step back and re-approach (LOS / angle).
        if (Suite._interact_fail_n or 0) >= Suite.INTERACT_FAILS then
            Suite._interact_fail_n = 0
            Suite._interact_cycle_n = tries + 1
            local px, py, pz = ppos()
            if px and x then
                local dx, dy = px - x, py - y
                local m = math.sqrt(dx * dx + dy * dy)
                if m > 0.1 then
                    local bx = px + (dx / m) * 4
                    local by = py + (dy / m) * 4
                    local Nv = RaijinLab.Navigator
                    if Nv and Nv.move_to then
                        Nv.move_to({ x = bx, y = by, z = pz or z },
                            { arrive_dist = 1.5, force_forward = true, no_avoid = true })
                    end
                    return verb .. ":reposition " .. tag .. " st=" .. stn
                end
            end
        end
        return verb .. ":interact " .. tag .. " st=" .. stn
            .. " d=" .. string.format("%.1f", dnow)
    end
    return verb .. ":to " .. tag .. " st=" .. stn
        .. " d=" .. string.format("%.0f", g.dist or dist_to(x, y, z) or -1)
        .. " (" .. st .. ")"
end

-- The actual job: turn in, pick up, work an objective. Extracted from tick() so
-- the Director can run it as one goal among several.
-- WHY DID IT CHOOSE THAT? The state log records WHAT the engine decided
-- ("accept:to ?" / "objective:searching") but never WHY, so when it alternated
-- between the two three times a second - never closing the last 21 yards to an
-- npc it could see - the log showed the symptom and none of the inputs. One
-- throttled line with the actual decision variables makes that self-evident:
-- a giver that is present on one tick and absent on the next is an unstable
-- SENSOR, not an unstable policy.
-- Where the database says this quest's giver / ender stands, or nil.
-- Same guards as known_target: uncalibrated zone or absurd distance -> nil, so
-- every caller falls back to what it did before.
function Suite.known_quest_npc(q, which)
    local qid = q and (q.questId or q.id)
    if not qid then return nil end
    local QDB = RaijinLab and RaijinLab.QuestDB
    if not (QDB and QDB.quest_npc) then return nil end
    local px, py, pz = ppos()
    if not px then return nil end
    local ok, p = pcall(QDB.quest_npc, qid, which, px, py)
    if not (ok and p and p.x and p.y) then return nil end
    -- No cap here either: a turn-in npc on another continent is a travel
    -- problem, not an unknown one. goto_point decides walk vs flight.
    p.z = p.z or pz
    qlog("db_questnpc", {
        qid = tostring(qid), which = which,
        d = math.floor(p.dist or -1),
        x = string.format("%.0f", p.x), y = string.format("%.0f", p.y),
    })
    return p
end

-- Where the database says the objective is, in world coordinates - or nil.
--
-- KNOWLEDGE BEFORE SEARCH. A probability field is what you use when you do not
-- know where something is. For anything in the shipped tables we DO know:
-- RaijinQuest carries the server's own spawn data and QuestDB turns it into
-- world coordinates. Sweeping a belief field for a mob whose spawn point is on
-- disk is how the bot ended up jogging into fences hunting a "Scavenger Paw" -
-- which is LOOT, so no unit ever carried that name and perception could not have
-- found it at any sensor quality.
--
-- Guarded so it can only ever help: the zone must be CALIBRATED (QuestDB returns
-- nil until its affine fit is solved and still predicting), the point must be a
-- sane leg away, and every failure returns nil so the caller falls through to
-- the field exactly as before.
-- ZERO PROBABILITY. This engine does not guess where things are.
--
-- The belief field remains in the tree because its bookkeeping (visited ground,
-- refusals) is still useful evidence, but it is NO LONGER A SOURCE OF
-- DESTINATIONS. Turning this on restores the old behaviour of inventing a place
-- to walk when nothing is known, which is precisely what made the bot look
-- aimless. Leave it off.
Suite.ALLOW_BELIEF_SEARCH = false

function Suite.known_target(label, px, py, seen)
    if not (label and px and py) then return nil end
    local QDB = RaijinLab and RaijinLab.QuestDB
    if not (QDB and QDB.locate) then return nil end
    local okq, known = pcall(QDB.locate, label, px, py, seen)
    if not (okq and known and known.x and known.y) then return nil end
    local d = math.sqrt((known.x - px) ^ 2 + (known.y - py) ^ 2)
    -- NO DISTANCE CAP. "Anywhere from anywhere."
    --
    -- This refused any known target beyond SEARCH_MAX_LEG (1000yd) and returned
    -- nil - which the caller reads as "location unknown" and parks. So a place we
    -- KNEW was thrown away for being far, and the bot did nothing. The cap was
    -- inherited from the belief field, where a long leg meant a wild guess; a
    -- database coordinate is not a guess, and distance is not a reason to
    -- disbelieve it.
    --
    -- Long range is a TRAVEL problem and goto_point already solves it: past
    -- Suite._fly_min it weighs walk-to-flightmaster + flight against walking, and
    -- the hierarchical planner crosses zones. Handing a far target to that system
    -- is the whole point of having it.
    qlog("db_target", {
        name = tostring(label), d = math.floor(d),
        x = string.format("%.0f", known.x), y = string.format("%.0f", known.y),
    })
    return known.x, known.y
end

local function log_pick(branch, g, extra)
    local DL = RaijinLab and RaijinLab.DevLog
    if not (DL and DL.log_every) then return end
    DL.log_every("qpick", 1.0, "quest",
        "pick %s giver=%s d=%s st=%s%s",
        tostring(branch),
        g and tostring(g.guid) or "none",
        g and g.dist and string.format("%.0f", g.dist) or "-",
        g and tostring(g.st or g.status or "-") or "-",
        (extra and (" " .. extra) or "")
            -- the decisive input when the answer is "no_giver": WHICH statuses
            -- the sensor actually returned. 1=unavailable 5=in-progress are
            -- correct refusals; 8/10 here would mean a policy bug instead.
            .. (RaijinLab.QuestOM and RaijinLab.QuestOM.status_hist_str
                and (" seen=" .. RaijinLab.QuestOM.status_hist_str()) or "")
            -- and HOW the scan went: how many objects were examined, and how
            -- many passed each witness. "no giver" with no numbers is what made
            -- every diagnosis a guess.
            .. (function()
                local sc = RaijinLab.QuestOM and RaijinLab.QuestOM._scan
                if not sc then return "" end
                return string.format(" scan=%d/status%d/db%d/spark%d/nopos%d",
                    sc.seen or 0, sc.status or 0, sc.db or 0, sc.spark or 0, sc.nopos or 0)
            end)())
end

function Suite.progress_step()
    local c = cfg()
    local QOM = RaijinLab.QuestOM
    local scan = c.giver_scan_dist or 80

    -- 0) LIVE CLIENT MARKS FIRST.
    -- /raijin quest givers already proves st=8/10 on nearby NPCs. Do not wait
    -- for QuestLog completeness or Director fall-through: walk to !/? now.
    -- Live bug: progress_step returned nil -> Director all_idle -> state=idle
    -- while yellow marks stood in town.
    if QOM and QOM.nearest_giver then
        if c.auto_turnin ~= false then
            local g = QOM.nearest_giver("complete")
            if g and g.guid and (not g.dist or g.dist <= scan) then
                log_pick("turnin", g)
                return go_live_giver(g, "turnin")
            end
        end
        if c.auto_accept ~= false and not (RaijinLab.QuestLog and RaijinLab.QuestLog.is_full
            and RaijinLab.QuestLog.is_full()) then
            local g = QOM.nearest_giver("available")
            if g and g.guid and (not g.dist or g.dist <= scan) then
                log_pick("accept", g)
                return do_accept(g) or go_live_giver(g, "accept")
            end
            -- The NEGATIVE case is the one that mattered: logging only successes
            -- hides an intermittent sensor completely.
            log_pick("no_giver", g, "scan=" .. tostring(scan))
        end
    end

    local turnin_st = nil
    if c.auto_turnin then
        local tq = RaijinLab.QuestLog and RaijinLab.QuestLog.first_complete
            and RaijinLab.QuestLog.first_complete()
        if tq then
            local h = Suite.scripts[tq.questId]
            if h and h.turnin then return "script:" .. (h.turnin(tq) or "turnin") end
            turnin_st = do_turnin(tq)
            if turnin_st and not tostring(turnin_st):find("no giver", 1, true)
                and not tostring(turnin_st):find("waiting", 1, true)
                and not tostring(turnin_st):find("status empty", 1, true) then
                return turnin_st
            end
            -- NO TURN-IN NPC IN SIGHT IS NOT A DEAD END - WE KNOW WHERE HE IS.
            --
            -- do_turnin can only use an npc already inside scan range, so a
            -- finished quest whose ender stands two hundred yards away simply
            -- fell through to objective search: the bot wandered off with a
            -- completed quest in its log and never handed it in. RaijinQuest
            -- carries the quest's ender and its spawn, so walk there.
            --
            -- Only when the DB can place him (calibrated zone), and the ordinary
            -- goto machinery handles the travel, mounting and re-planning.
            local dbq = Suite.known_quest_npc(tq, "end")
            if dbq then
                return goto_point(dbq.x, dbq.y, dbq.z, cfg().interact_dist or 4.5)
                    == "arrived" and "turnin:at giver" or
                    string.format("turnin:travel %s (%.0fyd)",
                        tostring(tq.title or tq.questId), dbq.dist or -1)
            end
        end
    end

    local QL = RaijinLab.QuestLog
    local q, o
    if QL and QL.best_objective then q, o = QL.best_objective({ skip = Suite._parked }) end
    if not q and QL and QL.first_incomplete_objective then
        q, o = QL.first_incomplete_objective({ skip = Suite._parked })
    end
    if q and o then
        local h = Suite.scripts[q.questId]
        if h and h.objective then return "script:" .. (h.objective(q, o) or "objective") end
        local st = do_objective(q, o)
        Suite.note_objective_result(q, st)
        return st
    end
    if Suite._parked and next(Suite._parked) then
        Suite._parked, Suite._attempts = nil, nil
        return "unparked"
    end

    -- NEVER return nil: Director treats nil as fallthrough -> all_idle -> "idle".
    if turnin_st then return turnin_st end
    local n8 = QOM and QOM.nearest_giver and QOM.nearest_giver("available")
    local n10 = QOM and QOM.nearest_giver and QOM.nearest_giver("complete")
    return string.format(
        "progress:idle log_empty live_!=%s live_?=%s",
        n8 and (tostring(n8.name or "?") .. "/st" .. tostring(n8.status)) or "none",
        n10 and (tostring(n10.name or "?") .. "/st" .. tostring(n10.status)) or "none")
end

function Suite.tick()
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    if not (RaijinLabDB and RaijinLabDB.modules and RaijinLabDB.modules.quest) then return end
    local c = cfg()

    -- Without the inject runtime there is no position, no OM, no interact.
    -- Fail loud and idle rather than thrashing "searching (no position)" forever
    -- and looking like the quest engine is broken.
    if not has_runtime() then
        return set_state("need_runtime: inject tools\\inject.bat in-world, then /reload")
    end
    local px = ppos()
    if not px then
        return set_state("need_position: ObjectPosition(player) nil - wait for OM arm or re-inject")
    end

    ensure_om()

    -- Remember what we can currently see (quest givers / turn-ins / objectives)
    -- so anything out of render range later is still navigable. Throttled: the OM
    -- refreshes ~30Hz but sightings only need recording about once a second.
    local tnow = now()
    if (tnow - (Suite._observe_t or 0)) >= (c.observe_every or 1.0) then
        Suite._observe_t = tnow
        if RaijinLab.QuestOM and RaijinLab.QuestOM.observe then
            pcall(RaijinLab.QuestOM.observe, { max_dist = c.objective_scan_dist })
        end
        -- Learn where creatures actually spawn while we are here, so a later
        -- "kill 12 of these" has a real circuit to walk instead of a guess.
        if RaijinLab.Patrol and RaijinLab.Patrol.observe then
            pcall(RaijinLab.Patrol.observe)
        end
    end

    -- 0) Supervise. Fourteen modules drive this character; the failure that
    -- matters is not a crash but looking busy while achieving nothing. The
    -- watchdog escalates nudge -> reset -> halt when no real progress arrives.
    if RaijinLab.Watchdog then pcall(RaijinLab.Watchdog.tick) end

    -- 1) A quest/gossip window is open -> do the paperwork. This stays ahead of
    -- everything: an open frame is a modal the server is waiting on, not a goal.
    local fr = drive_frames()
    if fr then
        -- An open frame settles any greet we are waiting on: this npc talks to
        -- us. It has to be cleared HERE because the tick returns at this branch
        -- for the whole life of the dialog, so the pending check further down
        -- never runs while the frame is up - and would then time out and
        -- blacklist for 900s the one npc that actually answered.
        Suite._greet_pending = nil
        return set_state("frame:" .. fr)
    end

    -- 2) ARBITRATE. The Director weighs every goal by priority band and urgency,
    -- with hysteresis so competing goals cannot ping-pong, and remembers what it
    -- interrupted. Falls back to the original fixed cascade if it is unavailable.
    local D = RaijinLab.Director
    if D and c.use_director ~= false then
        -- Re-install goals if the Director was cleared (empty _goals -> permanent idle).
        local ngoals = 0
        if D._goals then for _ in pairs(D._goals) do ngoals = ngoals + 1 end end
        if (not Suite._goals_installed or ngoals == 0) and RaijinLab.Goals then
            Suite._goals_installed = pcall(RaijinLab.Goals.install, Suite)
        end
        local st = D.tick()
        if st then
            Suite._death_pos = nil
            return set_state(st)
        end
        -- Director returned nil (master gate / all fallthrough). Still try a
        -- direct progress step so live !/? are not stranded behind "idle".
        local direct = Suite.progress_step and Suite.progress_step()
        if direct then
            Suite._death_pos = nil
            return set_state(direct)
        end
        return set_state("idle")
    end

    -- 2) Dead -> recover before anything else.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        -- Prefer the persistent recovery module: it survives a reload while dead,
        -- respects the retrieval delay, and falls back to the spirit healer rather
        -- than leaving a ghost stranded forever.
        if RaijinLab.Death then
            local dst = RaijinLab.Death.tick({
                goto_fn = function(x, y, z, arrive) goto_point(x, y, z, arrive) end,
            })
            if dst then return set_state(dst) end
        end
        return set_state(recover_death())
    end
    Suite._death_pos = nil

    -- 3) Safety: low HP in combat -> disengage.
    if in_combat() and low_hp() then return set_state(flee()) end

    -- 3b) Recover. Out of combat and hurt/oom -> eat and drink before taking on
    -- anything else; fighting at 20% health is how an unattended bot dies.
    if cfg().use_rest ~= false and RaijinLab.Rest then
        local rst = RaijinLab.Rest.tick({
            stop_fn = function()
                local a = Act()
                if a and a.StopMoving then pcall(a.StopMoving) end
                local Nav = RaijinLab.Nav
                if Nav and Nav.cancel then Nav.cancel() end
                Suite._goal = nil
            end,
        })
        if rst then return set_state(rst) end
    end

    -- 3c) Errands. Full bags stop us looting, broken gear stops us fighting and
    -- an empty food bag stops us recovering - all of which quietly end a run. Go
    -- and fix it while we still can, but only if we actually know where a vendor
    -- is (otherwise carry on questing and learn one on the way).
    if cfg().use_vendor ~= false and RaijinLab.Vendor then
        local vst = Suite.vendor_trip()
        if vst then return set_state(vst) end
    end

    -- 4) Hand in a completed quest (highest value action).
    if c.auto_turnin then
        local tq = RaijinLab.QuestLog.first_complete()
        if tq then
            local h = Suite.scripts[tq.questId]
            if h and h.turnin then return set_state("script:" .. (h.turnin(tq) or "turnin")) end
            return set_state(do_turnin(tq))
        end
    end

    -- 5) Pick up a new quest from a nearby "!" giver (respect the 25-quest cap).
    if c.auto_accept and not RaijinLab.QuestLog.is_full() then
        local g = RaijinLab.QuestOM.nearest_giver("available")
        if g and g.dist <= c.giver_scan_dist then return set_state(do_accept(g)) end
    end

    -- 6) Work the BEST objective, not merely the first in the log: QuestPolicy
    -- ranks by completion, real remembered distance and difficulty, and quests we
    -- have repeatedly failed to progress are parked so we never grind a wall.
    local QL = RaijinLab.QuestLog
    local q, o
    if QL.best_objective then
        q, o = QL.best_objective({ skip = Suite._parked })
    end
    if not q then q, o = QL.first_incomplete_objective({ skip = Suite._parked }) end
    if q and o then
        local h = Suite.scripts[q.questId]
        if h and h.objective then return set_state("script:" .. (h.objective(q, o) or "objective")) end
        local st = do_objective(q, o)
        Suite.note_objective_result(q, st)
        return set_state(st)
    end

    -- Nothing left we can work: unpark everything and try again next tick rather
    -- than idling forever (a parked quest may have become possible again).
    if Suite._parked and next(Suite._parked) then
        Suite._parked, Suite._attempts = nil, nil
        return set_state("unparked")
    end
    return set_state("idle")
end

-- Track whether an objective is actually progressing. A quest that keeps coming
-- back "nothing in range and nothing remembered" is one we cannot currently do -
-- park it and move to another instead of looping on it forever.
function Suite.note_objective_result(q, st)
    if not (q and q.questId and st) then return end
    local QP = RaijinLab and RaijinLab.QuestPolicy
    local stuck = tostring(st):find("none in range", 1, true)
        or tostring(st):find("memory stale", 1, true)
        or tostring(st):find("no_known_spawns", 1, true)
    Suite._attempts = Suite._attempts or {}
    if not stuck then
        Suite._attempts[q.questId] = nil
        return
    end
    local n = (Suite._attempts[q.questId] or 0) + 1
    Suite._attempts[q.questId] = n
    local park = false
    if QP and QP.should_park then
        park = QP.should_park(q, { attempts = n }) and true or false
    else
        park = n >= 3
    end
    if park then
        Suite._parked = Suite._parked or {}
        Suite._parked[q.questId] = true
        local DL = RaijinLab.DevLog
        if DL then DL.log("quest", "parked %s after %d failed attempts",
            tostring(q.title or q.questId), n) end
    end
end

-- ---- events: react the frame the server opens the window -----------------
local function on_event(_, event, ...)
    if not (RaijinLabDB and RaijinLabDB.modules and RaijinLabDB.modules.quest) then return end
    local QF = RaijinLab and RaijinLab.QuestFrame
    if not QF then return end
    if event == "GOSSIP_SHOW" then QF.on_gossip()
    elseif event == "QUEST_GREETING" then QF.on_quest_greeting()
    elseif event == "QUEST_DETAIL" then QF.on_quest_detail()
    elseif event == "QUEST_PROGRESS" then QF.on_quest_progress()
    elseif event == "QUEST_COMPLETE" then QF.on_quest_complete()
    elseif event == "QUEST_ACCEPTED" then
        local qid = select(2, ...)               -- (questLogIndex, questID)
        local h = qid and Suite.scripts[qid]
        if h and h.accept then pcall(h.accept, qid) end
    end
end

-- ---- lifecycle -----------------------------------------------------------
function Suite.start()
    -- Do not call Suite.stop() first when already running - that printed OFF
    -- then ON and briefly zeroed modules.quest, which looked like a no-op.
    if Suite._t or Suite._f then
        if Suite._t then Suite._t:Cancel(); Suite._t = nil end
        if Suite._f then Suite._f:SetScript("OnUpdate", nil); Suite._f = nil end
        if Suite._events then
            Suite._events:SetScript("OnEvent", nil)
            Suite._events:UnregisterAllEvents()
            Suite._events = nil
        end
    end
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    RaijinLabDB.modules.quest = true
    -- Master OFF suppresses every tick. quest on must raise the gate.
    RaijinLabDB.master = true
    cfg().enabled = true
    ensure_om()
    if RaijinLab.RuntimeCall then
        pcall(function() RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1") end)
    end
    -- Always have a disk log for the session (Debug tab alone is not enough).
    if RaijinLab.DevLog and RaijinLab.DevLog.start then pcall(RaijinLab.DevLog.start) end
    if RaijinLab.Scheduler and RaijinLab.Scheduler.start then pcall(RaijinLab.Scheduler.start) end
    if RaijinLab.Telemetry and RaijinLab.Telemetry.cfg then
        local tc = RaijinLab.Telemetry.cfg()
        tc.enabled = true
        if (tc.level or 0) < 4 then tc.level = 4 end
    end
    -- Reset status counters so a prior DEAD verdict cannot stick across restarts.
    if RaijinLab.QuestOM then
        RaijinLab.QuestOM._status_asked = 0
        RaijinLab.QuestOM._status_nonzero = 0
        RaijinLab.QuestOM._probe_rounds = 0
        RaijinLab.QuestOM._witnessed_dead = false
    end
    -- Event frame for reactive frame paperwork + script hooks.
    local ef = CreateFrame("Frame")
    ef:RegisterEvent("GOSSIP_SHOW")
    ef:RegisterEvent("QUEST_GREETING")
    ef:RegisterEvent("QUEST_DETAIL")
    ef:RegisterEvent("QUEST_PROGRESS")
    ef:RegisterEvent("QUEST_COMPLETE")
    ef:RegisterEvent("QUEST_ACCEPTED")
    ef:SetScript("OnEvent", on_event)
    Suite._events = ef
    -- Drive tick. 0.3 s is responsive without hammering the OM queries.
    if C_Timer and C_Timer.NewTicker then
        Suite._t = C_Timer.NewTicker(0.3, Suite.tick)
    else
        local f = CreateFrame("Frame")
        local a = 0
        f:SetScript("OnUpdate", function(_, e) a = a + e; if a >= 0.3 then a = 0; Suite.tick() end end)
        Suite._f = f
    end
    Suite._qlog_last = {}
    Suite.state = "starting"
    Suite.last = "starting"
    qlog("start", {
        runtime = tostring(RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion() or "?"),
        master = tostring(RaijinLabDB.master ~= false),
    })
    local master_on = not (RaijinLab.Master and RaijinLab.Master.suppressed and RaijinLab.Master.suppressed())
    print("|cff7ec8e3RaijinLab|r questing |cff55ff55ON|r  master="
        .. (master_on and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    print("|cff7ec8e3RaijinLab|r /raijin quest status  |  log: Logs/raijinlab_dev.log")
end

function Suite.stop()
    qlog("stop", { last = tostring(Suite.last), state = tostring(Suite.state) })
    if Suite._t then Suite._t:Cancel(); Suite._t = nil end
    if Suite._f then Suite._f:SetScript("OnUpdate", nil); Suite._f = nil end
    if Suite._events then Suite._events:SetScript("OnEvent", nil); Suite._events:UnregisterAllEvents(); Suite._events = nil end
    if RaijinLab and RaijinLab.Nav then RaijinLab.Nav.cancel() end
    Suite._goal = nil
    Suite._act_tgt = nil
    if RaijinLabDB and RaijinLabDB.modules then RaijinLabDB.modules.quest = false end
    if RaijinLabDB and RaijinLabDB.quest then RaijinLabDB.quest.enabled = false end
    if RaijinLab.DevLog and RaijinLab.DevLog.flush then pcall(RaijinLab.DevLog.flush) end
    print("|cff7ec8e3RaijinLab|r questing |cffff5555OFF|r")
end

function Suite.status()
    local c = Suite.context and Suite.context() or {}
    return string.format(
        "quest=%s state=%s goal=%s quest=%s obj=%s(%s) tgt=%s dist=%s kind=%s nav=%s pos=%s,%s,%s dest=%s",
        tostring(RaijinLabDB and RaijinLabDB.modules and RaijinLabDB.modules.quest),
        tostring(c.state or Suite.last),
        tostring(c.goal), tostring(c.quest), tostring(c.obj), tostring(c.okind),
        tostring(c.tgt), tostring(c.tdist), tostring(c.tkind),
        tostring(c.nav), tostring(c.px), tostring(c.py), tostring(c.pz),
        tostring(c.dest))
end

if RaijinLab then RaijinLab.QuestSuite = Suite end
return Suite
