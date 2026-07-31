-- 1 Hz state snapshot to the dev log: navigation, pathfinding, quest, perf, and
-- camera+projection. This is the primary window into what the bot is doing -
-- read <WoW>/Logs/raijinlab_dev.log to review a whole session. The camera lines
-- carry everything needed to calibrate the world->screen projection from the log
-- alone (no chat commands / screenshots): raw camera fields plus where a known
-- point in front of the player and the current target actually project.

local function n1(v) return v and string.format("%.1f", v) or "nil" end

-- Yield the rest of this frame if the scheduler says our slice is spent.
-- Safe to call outside a coroutine: coroutine.yield only runs when we are in
-- one, and Scheduler.run always puts us in one.
local function yield_if_spent()
    local S = RaijinLab.Scheduler
    if not (S and S.over_budget and S.over_budget()) then return end
    if coroutine and coroutine.running and coroutine.running() then
        pcall(coroutine.yield)
    end
end

local function heartbeat()
    local DL = RaijinLab.DevLog
    if not DL then return end

    -- Idle (master OFF): skip TraceGround + most HB volume. 1 Hz raycasts while
    -- AFK was a visible stutter cadence with nothing "running".
    local idle = RaijinLab.Master and RaijinLab.Master.suppressed
        and RaijinLab.Master.suppressed()
    if idle then
        local t = (GetTime and GetTime()) or 0
        if (t - (RaijinLab._hb_idle_t or 0)) < 5.0 then return end
        RaijinLab._hb_idle_t = t
    end

    -- NOTE: never `X and Y()` before a multi-assign - `and` truncates Y() to one
    -- value (that made y/z log as nil). Read into all three explicitly.
    local px, py, pz
    if RaijinLab.ObjectPosition then px, py, pz = RaijinLab:ObjectPosition("player") end
    local pfac = RaijinLab.ObjectFacing and RaijinLab:ObjectFacing("player")
    -- grounded? (floor within a few yd under the feet) + movement-mode flags that
    -- would clip the character through the world if left on (noclip / fly).
    -- Prefer navigator's last grounded Z (free) over a fresh TraceGround every Hz.
    local grd
    local Nv0 = RaijinLab.Navigator
    if Nv0 and Nv0._active and Nv0._active.last_ground then
        grd = Nv0._active.last_ground.z
    elseif px and RaijinLab.GroundCache and RaijinLab.GroundCache.ground then
        grd = RaijinLab.GroundCache.ground(px, py, pz)
    elseif (not idle) and px and RaijinLab.TraceGround then
        grd = RaijinLab:TraceGround(px, py, pz, 2.5, 6.0)
    end
    DL.log("hb", "player pos=(%s,%s,%s) facing=%s grounded=%s(gz=%s) noclip=%s fly=%s inworld=%s combat=%s hp=%s%%",
        n1(px), n1(py), n1(pz), n1(pfac),
        tostring(grd ~= nil), n1(grd),
        tostring(RaijinLabDB and RaijinLabDB.noclip_toggle or false),
        tostring((RaijinLab.IsFlyingModeEnabled and RaijinLab:IsFlyingModeEnabled()) or (RaijinLabDB and RaijinLabDB.fly_toggle) or false),
        tostring(IsPlayerInWorld and IsPlayerInWorld()),
        tostring(UnitAffectingCombat and UnitAffectingCombat("player") or false),
        (UnitHealth and UnitHealthMax and UnitHealthMax("player") or 0) > 0
            and string.format("%.0f", UnitHealth("player") / UnitHealthMax("player") * 100) or "?")

    -- Section boundary: give the frame back if we have used our slice. Running
    -- as a Scheduler coroutine makes this a real yield; called directly it is a
    -- no-op, so the function stays correct either way.
    yield_if_spent()

    local Nv = RaijinLab.Navigator
    if Nv then
        local a = Nv._active
        local g = a and a.goal
        DL.log("hb", "nav state=%s active=%s node=%s/%s goal=%s pfgoal=%s replan=%s draw=%s",
            tostring(Nv.state), tostring(a ~= nil),
            a and tostring(a.idx or "-") or "-", a and a.path and tostring(#a.path) or "-",
            g and string.format("(%s,%s)", n1(g.x), n1(g.y)) or "-",
            Nv._pf_final_goal and string.format("(%s,%s)", n1(Nv._pf_final_goal.x), n1(Nv._pf_final_goal.y)) or "-",
            tostring(Nv._replan_n or 0), tostring(Nv._drawing))
    end

    yield_if_spent()

    local S = RaijinLab.Scheduler
    if S and S.stats then
        local s = S.stats()
        -- probe_pk is the WORST terrain-probe burst since the last heartbeat.
        -- The frame EMA cannot see a multi-ms spike every 100ms; this can, and
        -- it is the number that convicts or clears the probe when stutter is
        -- reported. Reset after reading so each heartbeat covers its own second.
        local Nv = RaijinLab.Navigator
        local ppk = (Nv and Nv._probe_peak) or 0
        if Nv then Nv._probe_peak = 0 end
        DL.log("hb", "perf frame=%.1fms fps=%.0f sched=%.2fms peak=%.2f budget=%.2f jobs=%d probe_pk=%.2f",
            s.frame_ms or 0, s.fps or 0, s.last_ms or 0, s.peak_ms or 0, s.budget or 0, s.alive or 0, ppk)
    end
    local gc = RaijinLab.GroundCache and RaijinLab.GroundCache.stats()
    if gc then DL.log("hb", "gcache cells=%d hit=%.0f%% (%d/%d)", gc.count or 0, (gc.rate or 0) * 100, gc.hits or 0, gc.misses or 0) end
    local wm = RaijinLab.WorldMesh and RaijinLab.WorldMesh.stats()
    if wm then DL.log("hb", "wmesh map=%s snags=%d seams=%d", tostring(wm.map), wm.stuck or 0, wm.ramps or 0) end
    -- Throughput meters: prove "more answers / cheaper units" from the log.
    do
        local h = RaijinLab._tl_hits or 0
        local m = RaijinLab._tl_miss or 0
        local gc = RaijinLab.GroundCache and RaijinLab.GroundCache.stats and RaijinLab.GroundCache.stats()
        DL.log_every("thru", 5.0, "hb",
            "thru tl_hit=%d tl_miss=%d tl_rate=%.0f%% gcache_rate=%.0f%% gcache_n=%s",
            h, m, (h + m) > 0 and (100 * h / (h + m)) or 0,
            gc and ((gc.rate or 0) * 100) or 0,
            tostring(gc and gc.count or "-"))
    end

    -- WHAT THE ENGINE CAN ACTUALLY SEE. Every navigation and questing failure
    -- this project has had traced back to this being empty while the runtime
    -- happily reported dozens of units - and nothing ever logged it, so it was
    -- found by inference over days instead of by reading one line. bridge= is
    -- what the DLL enumerates; npcs/players/gos are what the engine actually
    -- holds; armed/frame say whether the producer is even running.
    do
        local L = RaijinLab.om and RaijinLab.om.object_list
        local bridge_n = -1
        if RaijinLab.HasRuntime and RaijinLab:HasRuntime() then
            local okb, v = pcall(RaijinLab.RuntimeCall, RaijinLab, "GetUnitCount")
            bridge_n = (okb and tonumber(v)) or -1
        end
        local QOM = RaijinLab.QuestOM
        DL.log("hb", "om bridge=%d npcs=%d players=%d gos=%d armed=%s frame=%s "
            .. "gstat_asked=%s gstat_nz=%s",
            bridge_n,
            (L and L.npcs and #L.npcs) or -1,
            (L and L.players and #L.players) or -1,
            (L and L.gameobjects and #L.gameobjects) or -1,
            tostring(RaijinLab._runtime_armed and true or false),
            tostring((RaijinLab.GetObjManagerFrame and RaijinLab:GetObjManagerFrame()) and true or false),
            tostring(QOM and QOM._status_asked or "-"),
            tostring(QOM and QOM._status_nonzero or "-"))
    end

    -- Feed the zone->world calibration and report it. Without a solved
    -- transform every pfQuest coordinate is unusable, so this number decides
    -- whether the bot can navigate to known spawns or is back to guessing.
    do
        local QDB = RaijinLab.QuestDB
        if QDB and QDB.observe and GetPlayerMapPosition and RaijinLab.ObjectPosition then
            local okp, xp, yp = pcall(GetPlayerMapPosition, "player")
            local wx, wy = RaijinLab:ObjectPosition("player")
            -- the DATABASE's zone id, not the client's WorldMapArea id:
            -- spawns are keyed 85 (Tirisfal) while GetCurrentMapAreaID
            -- returns 1240, so calibrating on the latter solved a zone
            -- nothing ever looked up.
            local QD = RaijinLab.QuestDB
            local map = (QD and QD.current_zone and QD.current_zone())
                or (GetCurrentMapAreaID and GetCurrentMapAreaID()) or nil
            if okp and xp and wx and map then
                pcall(QDB.observe, map, xp, yp, wx, wy)
                -- ...and the SAME reading in the client map's own space. The
                -- corpse and the player report percentages of whatever map the
                -- client is showing, which is not the database's zone, and
                -- converting one with the other's transform is what sent the
                -- corpse run past the body.
                local cmid = GetCurrentMapAreaID and GetCurrentMapAreaID()
                if cmid and QDB.observe_client then
                    pcall(QDB.observe_client, cmid, xp, yp, wx, wy)
                end
                local c = QDB._cal[map]
                DL.log_every("qdbcal", 5.0, "hb",
                    "qdb map=%s solved=%s err=%s samples=%d pf=%s",
                    tostring(map), tostring(c and c.t_solved ~= nil),
                    c and c.err and string.format("%.1f", c.err) or "-",
                    c and #c.samples or 0, tostring(QDB.available()))
            end
        end
    end

    if RaijinLabDB and RaijinLabDB.modules and RaijinLabDB.modules.quest and RaijinLab.QuestSuite then
        DL.log("hb", "quest state=%s", tostring(RaijinLab.QuestSuite.last))
    end

    -- Camera calibration: only when explicitly needed (debug level / flag).
    -- Was every heartbeat with WorldToScreen - pure overhead for normal runs.
    local want_cam = RaijinLabDB and RaijinLabDB.telemetry
        and (RaijinLabDB.telemetry.cam_hb == true
            or (RaijinLabDB.telemetry.categories and RaijinLabDB.telemetry.categories.cam
                and RaijinLabDB.telemetry.categories.cam >= 3))
    if want_cam then
        local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
        if c then
            DL.log("cam", "pos=(%.1f,%.1f,%.1f) fov=%.4f fwd=(%.3f,%.3f,%.3f) right=(%.3f,%.3f,%.3f) up=(%.3f,%.3f,%.3f)",
                c.px, c.py, c.pz, c.fov, c.fx, c.fy, c.fz, c.rx, c.ry, c.rz, c.ux, c.uy, c.uz)
            if px and RaijinLab.WorldToScreen then
                local ax = px + math.cos(pfac or 0) * 10
                local ay = py + math.sin(pfac or 0) * 10
                local on, nx, ny = RaijinLab.WorldToScreen(ax, ay, pz)
                DL.log("cam", "project player+10yd=(%.1f,%.1f,%.1f) -> on=%s ndc=(%.3f,%.3f)", ax, ay, pz or 0,
                    tostring(on), nx or -1, ny or -1)
            end
        end
    end
end

function RaijinLab:StartInstrumentation()
    if RaijinLab._instr_t then return end
    if C_Timer and C_Timer.NewTicker then
        -- OFF THE MAIN THREAD'S CRITICAL PATH.
        --
        -- heartbeat() does a synchronous TraceGround raycast plus a full world /
        -- services / rotation snapshot, all inline, once a second. At 30fps a
        -- frame is 33ms, so any of that landing in one frame is a visible hitch -
        -- reported as "a kind of stutter every second or so", which is exactly
        -- the cadence of this ticker.
        --
        -- NOT reduced or throttled: the same work still happens, at the same 1Hz,
        -- with the same detail. It is submitted to the frame-budgeted Scheduler
        -- as a LOW-priority job instead, so it yields when the frame's budget is
        -- spent and resumes on the next one. Costly instrumentation becomes
        -- something the frame can absorb rather than something it must swallow
        -- whole.
        -- 1 Hz again: TraceGround only when nav has no last floor; camera off by
        -- default. More samples than 2Hz, less ray cost than the old path.
        -- 2s cadence when only rotation is armed (less hitch while fighting).
        -- Full 1s when quest/nav modules need denser samples.
        local function instr_gap()
            local d = RaijinLabDB and RaijinLabDB.modules
            if d and (d.quest or d.grind or d.gather) then return 1.0 end
            return 2.0
        end
        local acc = 0
        RaijinLab._instr_t = C_Timer.NewTicker(0.5, function()
            acc = acc + 0.5
            if acc < instr_gap() then return end
            acc = 0
            if RaijinLab and RaijinLab._ui_open_hint then return end -- free UI frames
            local S = RaijinLab.Scheduler
            if S and S.run then
                S.run(function()
                    pcall(heartbeat)
                end, S.PRIO and S.PRIO.LOW or 3)
            else
                pcall(heartbeat)
            end
        end)
    end
end
