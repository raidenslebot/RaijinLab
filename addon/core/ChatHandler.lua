-- On this client SendSystemMessage does NOT display for the local player - it is not a
-- reliable stock 3.3.5 global and is chat-restricted for low-level characters (< 10), so
-- its output is silently dropped. Route all command output through this shim.
--
-- CRITICAL: these are replies to a command the user EXPLICITLY typed, so they must
-- ALWAYS show in chat - never gated by the "verbose chat" toggle. The DebugLog
-- print hook captures every RaijinLab-prefixed print() to its buffer and only
-- mirrors to chat when chat_verbose is on, so routing command replies through a
-- plain print() silently ate them unless verbose was enabled. Instead we print
-- via DebugLog's ORIGINAL (un-hooked) print so the reply always reaches chat, and
-- separately push it to the debug buffer so the Debug tab still records it.
local function SendSystemMessage(msg)
    local DL = RaijinLab and RaijinLab.DebugLog
    if DL and DL._orig_print then
        DL._orig_print(msg)                 -- always visible in chat (bypasses verbose gate)
        if DL.Push then DL.Push(msg) end     -- still captured to the Debug tab
    else
        print(msg)                           -- DebugLog not loaded yet: best effort
    end
end

function RaijinLab:RunCommand(msg)
    local _, _, cmd, args = string.find(msg or "", "%s?(%w+)%s?(.*)")
    if not cmd or cmd == "" then cmd = "status" end
    -- MASTER SWITCH. Deliberately the first commands checked, and given the
    -- shortest possible names: /raijin off has to work when something is going
    -- wrong, which is the worst possible time to be typing a long word.
    if cmd == "off" or cmd == "stop" or cmd == "halt" then
        local M = RaijinLab.Master
        if not M then SendSystemMessage("|cff7ec8e3RaijinLab|r: master switch unavailable"); return true end
        local was = M.stop_all("chat")
        local n = 0
        for _ in pairs(was) do n = n + 1 end
        SendSystemMessage("|cff7ec8e3RaijinLab|r suite |cffff5555OFF|r - " .. n ..
            " module(s) stopped, movement released")
        if RaijinLab.Menu and RaijinLab.Menu.RefreshHome then pcall(RaijinLab.Menu.RefreshHome, RaijinLab.Menu) end
        return true
    elseif cmd == "on" or cmd == "go" or cmd == "start" then
        local M = RaijinLab.Master
        if not M then SendSystemMessage("|cff7ec8e3RaijinLab|r: master switch unavailable"); return true end
        local started = M.start_all("chat")
        SendSystemMessage("|cff7ec8e3RaijinLab|r suite |cff10ff10ON|r - " ..
            (#started > 0 and table.concat(started, ", ") or "idle (no modules enabled)"))
        if RaijinLab.Menu and RaijinLab.Menu.RefreshHome then pcall(RaijinLab.Menu.RefreshHome, RaijinLab.Menu) end
        return true
    elseif cmd == "suite" then
        local M = RaijinLab.Master
        if not M then SendSystemMessage("|cff7ec8e3RaijinLab|r: master switch unavailable"); return true end
        if args == "on" then return RaijinLab:RunCommand("on") end
        if args == "off" then return RaijinLab:RunCommand("off") end
        local on, n = M.summary()
        SendSystemMessage("|cff7ec8e3RaijinLab|r suite: " ..
            (on and ("|cff10ff10ON|r - " .. n .. " active: " .. table.concat(M.active(), ", "))
                 or ("|cffff5555OFF|r - " .. n .. " module(s) saved for resume")))
        return true
    end

    if cmd == "mj" then
        RaijinLab.multijump_toggle = not RaijinLab.multijump_toggle
        SendSystemMessage("Multi-Jump: " .. tostring(RaijinLab.multijump_toggle));
        RaijinLab:SetSystemVar("RaijinLab.multijump_toggle", tostring(RaijinLab.multijump_toggle))
    elseif cmd == "proc" then
        -- 2026-08-03 (ProcForce toggle): drive Stormbringer-class proc spells.
        -- MUST be instantly stoppable in-game - this is the escape hatch the
        -- user demanded after a runaway forced closing the game.
        --   /raijin proc on [icdMs]      enable (default 300ms, spell 273057)
        --   /raijin proc off             disable NOW
        --   /raijin proc                 show state
        local rt = RaijinLab.RuntimeCall and RaijinLab:HasRuntime() and RaijinLab
        if not rt then
            SendSystemMessage("|cff7ec8e3RaijinLab|r proc: runtime not loaded")
            return true
        end
        local isOn = (args == "on" or args == "1" or args == "enable")
        local isOff = (args == "off" or args == "0" or args == "disable" or args == "stop")
        if isOn then
            local icd = tonumber(args:match("(%d+)")) or 300
            local ok = RaijinLab:RuntimeCall("ProcForceAdd", 273057, icd)
            SendSystemMessage("|cff7ec8e3RaijinLab|r proc |cff10ff10ON|r " ..
                "(273057 every " .. icd .. "ms)" .. (ok == 1 and "" or " (failed)"))
        elseif isOff then
            RaijinLab:RuntimeCall("ProcForceClear")
            SendSystemMessage("|cff7ec8e3RaijinLab|r proc |cffff5555OFF|r")
        else
            local st = tostring(RaijinLab:RuntimeCall("ProcForceState") or "")
            SendSystemMessage("|cff7ec8e3RaijinLab|r proc state: " .. st ..
                "  (use: /raijin proc on  |  /raijin proc off)")
        end
        return true
    elseif cmd == "aa" then
        RaijinLab.anti_afk = not RaijinLab.anti_afk
        SendSystemMessage("Anti-Afk: " .. tostring(RaijinLab.anti_afk));
        RaijinLab:SetSystemVar("RaijinLab.anti_afk", tostring(RaijinLab.anti_afk))
    elseif cmd == "fly" then
        RaijinLab.fly_toggle = not RaijinLab.fly_toggle
        RaijinLab:SetSystemVar("RaijinLab.fly_toggle", tostring(RaijinLab.fly_toggle))
        SendSystemMessage("Fly: " .. tostring(RaijinLab.fly_toggle))
        if not RaijinLab.fly_toggle and not RaijinLab:IsFlyingModeEnabled() then
            return
        end
        RaijinLab:EnableFlyingMode(RaijinLab.fly_toggle)
    elseif cmd == "nc" then
        RaijinLab.noclip_toggle = not RaijinLab.noclip_toggle
        if RaijinLab.noclip_toggle then
            if RaijinLab:IsFlyingModeEnabled() then
                RaijinLab:SetNoClipModes(15)
            else
                RaijinLab:SetNoClipModes(7)
            end
        else
            RaijinLab:SetNoClipModes(0)
        end
    elseif cmd == "travel" and args and args ~= "" then
        if type(RaijinLab.Travel) == "function" then
            RaijinLab:Travel(args)
        else
            SendSystemMessage("|cff7ec8e3RaijinLab|r travel: module unavailable")
        end
    elseif cmd == "trace" then
        if args == "start" then
            if RaijinLab.trace_timer then
                RaijinLab.trace_timer:Cancel()
                RaijinLab.trace_timer = nil
            end
            if type(RaijinLab.TraceLogObjects) ~= "function" then
                SendSystemMessage("|cff7ec8e3RaijinLab|r trace: TraceLogObjects not implemented")
            elseif not (C_Timer and C_Timer.NewTicker) then
                SendSystemMessage("|cff7ec8e3RaijinLab|r trace: C_Timer.NewTicker unavailable")
            else
                RaijinLab.trace_timer = C_Timer.NewTicker(0.5, function() RaijinLab:TraceLogObjects() end)
                SendSystemMessage("|cff7ec8e3RaijinLab|r trace: started")
            end
        else
            if RaijinLab.trace_timer then
                RaijinLab.trace_timer:Cancel()
                RaijinLab.trace_timer = nil
                SendSystemMessage("|cff7ec8e3RaijinLab|r trace: stopped")
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r trace: not running")
            end
        end
    elseif cmd == "tracker" then
        RaijinLab.tracker_toggle = not RaijinLab.tracker_toggle
        SendSystemMessage("Object Tracker: " .. tostring(RaijinLab.tracker_toggle));
        RaijinLab:SetSystemVar("RaijinLab.tracker_toggle", tostring(RaijinLab.tracker_toggle))
        if RaijinLab.tracker_toggle then
            RaijinLab:AddDrawingCallback("objectTracker", RaijinLab.DrawTrackedObjects)
            RaijinLab:InitTrackerModule()
        else
            RaijinLab:RemoveDrawingCallback("objectTracker")
        end
    elseif cmd == "track" and args then
        local _, _, action, id = string.find(args, "%s?(%w+)%s?(%d+)")
        if id then
            id = tonumber(id)
        else
            _, _, action, id = string.find(args, "%s?(%w+)%s?([%w%s]+)")
            print("action is: " .. tostring(action) .. " id is: " .. tostring(id))
        end
        if action == "add" and id then
            RaijinLab:AddObjectToTrackerByIdOrName(id)
            SendSystemMessage("Added ID: " .. tostring(id))
        elseif action == "del" and id then
            RaijinLab:RemoveObjectFromTrackerByIdOrName(id)
        elseif args == "all" then
            RaijinLab:TrackAllObjects()
        elseif args == "quest" then
            RaijinLabDB.track_quest_objects = not RaijinLabDB.track_quest_objects
            SendSystemMessage("Track Quest Objects: " .. tostring(RaijinLabDB.track_quest_objects))
            if RaijinLabDB.track_quest_objects then
                RaijinLab:EnableQuestTracker()
            end
        elseif action == "quest" and id == "reset" then
            RaijinLabDB.objects_to_track.quest = {}
        end
    elseif cmd == "farm" and args then
        if args == "stop" then
            RaijinLab:DestroyAllFarmers()
        else
            RaijinLab:CreateFarmer(args)
        end
    elseif cmd == "menu" or cmd == "ui" then
        if RaijinLab.Menu then RaijinLab.Menu:Toggle()
        elseif RaijinLab.ShowStatusFrame then RaijinLab:ShowStatusFrame() end
    elseif cmd == "rotation" then
        local Ex = RaijinLab.RotationExecutor
        local a = (args or ""):match("^%s*(%S*)") or ""
        if a == "start" and Ex then
            Ex.start()
            SendSystemMessage("|cff7ec8e3RaijinLab|r " .. (Ex.status and Ex.status() or "started"))
        elseif a == "stop" and Ex then
            Ex.stop()
        elseif a == "status" and Ex then
            SendSystemMessage("|cff7ec8e3RaijinLab|r " .. (Ex.status and Ex.status() or "no status"))
            local hasRt = RaijinLab:HasRuntime()
            SendSystemMessage("|cff7ec8e3RaijinLab|r HasRuntime=" .. tostring(hasRt) ..
                " ver=" .. tostring(hasRt and RaijinLab:RuntimeVersion() or "nil"))
            if not hasRt and RaijinLab.RuntimeDetectDiag then
                SendSystemMessage("|cff7ec8e3RaijinLab|r detect: " .. tostring(RaijinLab:RuntimeDetectDiag()))
            end
        elseif (a == "stats" or a == "metrics") and Ex then
            local lines = Ex.metrics_report and Ex.metrics_report() or { "no metrics" }
            SendSystemMessage("|cff7ec8e3RaijinLab|r rotation metrics:")
            for i = 1, #lines do
                SendSystemMessage("  " .. tostring(lines[i]))
            end
        elseif a == "debug" and Ex then
            Ex._debug = not Ex._debug
            RaijinLab._debug_print = Ex._debug
            SendSystemMessage("|cff7ec8e3RaijinLab|r rotation debug: " .. tostring(Ex._debug))
        elseif a == "list" and Ex then
            -- Which rotations exist for THIS character, and how many spells each
            -- actually has. The empty-rotation warning points here.
            local sum, order, active = Ex.config_summary()
            SendSystemMessage("|cff7ec8e3RaijinLab|r rotations for this character:")
            for _, n in ipairs(order) do
                local info = sum[n] or { filled = 0, total = 0 }
                SendSystemMessage(string.format("   %s%s|r  %d spell(s)%s%s",
                    n == active and "|cff10ff10" or "|cffaaaaaa", n, info.filled,
                    info.filled == 0 and "  |cffff5555<- EMPTY|r" or "",
                    n == active and "   |cff10ff10<- active|r" or ""))
            end
            SendSystemMessage("   use: /raijin rotation use <name>")
        elseif a == "use" and Ex then
            local name = (args or ""):match("^%s*use%s+(.+)$")
            name = name and name:gsub("%s+$", "") or nil
            if not name or name == "" then
                SendSystemMessage("|cff7ec8e3RaijinLab|r usage: /raijin rotation use <name>")
            else
                local ok, err = Ex.set_active_config(name)
                if ok then
                    SendSystemMessage("|cff7ec8e3RaijinLab|r active rotation -> |cff10ff10" .. name .. "|r")
                    if RaijinLab.FlushRotations then pcall(RaijinLab.FlushRotations, RaijinLab) end
                else
                    SendSystemMessage("|cff7ec8e3RaijinLab|r cannot use '" .. name .. "': " ..
                        tostring(err) .. "  (/raijin rotation list)")
                end
            end
        elseif a == "cast" then
            -- Force one cast attempt via Actions (diagnostic)
            local Act = RaijinLab.Actions
            local sid = tonumber((args or ""):match("cast%s+(%d+)")) or 0
            if sid == 0 and Ex then
                -- One-shot diagnostic tick. Humanization was removed; nothing
                -- to reset. Reset only the internal throttle so the tick isn't
                -- eaten by the 0.35s min-gap guard.
                Ex._last_attempt_t = 0
                Ex.tick()
                SendSystemMessage("|cff7ec8e3RaijinLab|r one-shot tick: " .. (Ex.status and Ex.status() or "?"))
            elseif Act and sid > 0 then
                local ok = Act.CastSpell(sid, "target")
                SendSystemMessage("|cff7ec8e3RaijinLab|r CastSpell(" .. sid .. ") => " .. tostring(ok))
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r usage: /raijin rotation cast [spellId]")
            end
        else
            if RaijinLab.Menu then
                RaijinLab.Menu:Show()
                if RaijinLab.Menu.SelectTab then RaijinLab.Menu:SelectTab("rotation") end
            end
            if Ex and Ex.status then
                SendSystemMessage("|cff7ec8e3RaijinLab|r " .. Ex.status() .. "  (/raijin rotation list|use <name>|start|stop|status|stats|debug|cast)")
            end
        end
    elseif cmd == "rotstats" or cmd == "metrics" then
        local Ex = RaijinLab.RotationExecutor
        if not Ex or not Ex.metrics_report then
            SendSystemMessage("|cff7ec8e3RaijinLab|r rotstats: no executor/metrics")
        else
            local lines = Ex.metrics_report()
            SendSystemMessage("|cff7ec8e3RaijinLab|r rotation metrics:")
            for i = 1, #lines do
                SendSystemMessage("  " .. tostring(lines[i]))
            end
        end
    elseif cmd == "controller" or cmd == "ctl" then
        -- THE STEERING LOOP, as numbers. What physically drives the character:
        -- measure the real heading, turn toward the aim, run forward only once
        -- inside the move cone, strafe for lateral drift, jump at walls - with a
        -- grounded gate that refuses to drive when there is no floor underfoot.
        local N = RaijinLab.Navigator
        if not N then SendSystemMessage("|cff7ec8e3RaijinLab|r: navigator unavailable"); return true end
        local a = N._active
        local A = RaijinLab.Actions
        SendSystemMessage("|cff7ec8e3RaijinLab|r steering controller:")
        SendSystemMessage(string.format("  state=%s  active=%s  method=%s",
            tostring(N.state), a and "yes" or "no", tostring(N._method or "-")))
        local head, aim = N._facing_real, N._target_h
        SendSystemMessage(string.format(
            "  heading %s  aim %s  err %s rad   (forward opens inside %.2f)",
            head and string.format("%.3f", head) or "?",
            aim and string.format("%.3f", aim) or "-",
            N._err and string.format("%+.3f", N._err) or "-",
            (N.cfg and N.cfg().move_cone) or 1.6))
        SendSystemMessage(string.format(
            "  inputs: forward=%s strafe=%s turn=%s  last turn cmd=%s",
            tostring(N._moving), tostring(N._strafe), tostring(N._turn),
            N._last_turn_cmd and string.format("%+.3f", N._last_turn_cmd) or "-"))
        -- Which heading source is being trusted right now. This is the value the
        -- whole loop closes on, and it read 155 degrees stale for a whole session
        -- while every other number looked healthy.
        local src = "dead-reckon"
        if N._pf_now and N.trusted and N.trusted("_pf_ok") ~= false then src = "live facing (0x7AC)"
        elseif N._travel_now then src = "travel bearing"
        elseif N._cam_now then src = "camera" end
        -- The position is upstream of everything; report it first when broken.
        if (RaijinLab._badpos or 0) > 0 then
            SendSystemMessage(string.format(
                "  |cffff5555POSITION READ REJECTED %dx|r - the runtime disagreed with " ..
                "the camera. Nothing can navigate until this is fixed (re-inject).",
                RaijinLab._badpos))
        end
        SendSystemMessage("  heading source: |cffffcc00" .. src .. "|r" ..
            (N._pf_now and string.format("  live=%.3f", N._pf_now) or ""))
        if a then
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if px and a.goal then
                SendSystemMessage(string.format("  goal (%.0f, %.0f)  %.0f yd out  waypoints %d/%d",
                    a.goal.x, a.goal.y,
                    math.sqrt((a.goal.x-px)^2 + (a.goal.y-py)^2),
                    a.idx or 0, a.path and #a.path or 0))
            end
        end
        SendSystemMessage("  |cffffcc00/raijin show controller|r draws this in the world")
        return true
    elseif cmd == "npcflags" then
        -- UNIT_NPC_FLAGS empirical sweep (capability bit 0x2). Dialog status
        -- itself is NOT here - that is CGObject+0x90 via ObjectQuestGiverStatus
        -- (SMSG_QUESTGIVER_STATUS). Use this to measure NpcFlags offset only.
        --
        -- Usage: target a KNOWN quest giver (one with a "!" or "?" over it) and
        -- run /raijin npcflags. Then target something that is definitely NOT a
        -- quest giver (a critter, a guard with no marker) and run it again. Any
        -- offset that appears in the first list and not the second is a
        -- candidate for UNIT_NPC_FLAGS; a single survivor is the answer.
        --
        -- Safe: ObjectField is bounded and the runtime's Mem::Read is
        -- range-checked and SEH-wrapped, so a wrong offset reads 0, not a crash.
        local g = UnitGUID and UnitGUID("target")
        if not g then
            SendSystemMessage("|cff7ec8e3RaijinLab|r npcflags: select a target first")
            return true
        end
        if not RaijinLab.ObjectField then
            SendSystemMessage("|cff7ec8e3RaijinLab|r npcflags: runtime has no ObjectField")
            return true
        end
        local hits, n = {}, 0
        for off = 0, 0x400, 4 do
            local ok, v = pcall(RaijinLab.ObjectField, RaijinLab, g, off)
            v = ok and tonumber(v) or nil
            -- Ignore all-ones / absurd values: those are unmapped reads, not fields.
            if v and v ~= 0 and v < 0x7FFFFFFF and bit and bit.band(v, 0x2) ~= 0 then
                n = n + 1
                hits[#hits + 1] = string.format("0x%X(=%d)", off, v)
            end
        end
        local nm = (UnitName and UnitName("target")) or "target"
        RaijinLabDB.quest = RaijinLabDB.quest or {}
        local prev = RaijinLabDB.quest._npcflag_probe
        RaijinLabDB.quest._npcflag_probe = hits
        SendSystemMessage(string.format(
            "|cff7ec8e3RaijinLab|r npcflags [%s]: %d offset(s) with bit 0x2 set", nm, n))
        SendSystemMessage("  " .. (table.concat(hits, " ", 1, math.min(#hits, 20))))
        if prev then
            -- Difference against the previous target: that is the actual signal.
            local seen = {}
            for _, o in ipairs(hits) do seen[o] = true end
            local only_prev = {}
            for _, o in ipairs(prev) do if not seen[o] then only_prev[#only_prev + 1] = o end end
            SendSystemMessage("  in the PREVIOUS target but not this one: " ..
                ((#only_prev > 0) and table.concat(only_prev, " ") or "(none)"))
            SendSystemMessage("  -> an offset listed there, on a questgiver-then-" ..
                "nonquestgiver pair, is your UNIT_NPC_FLAGS candidate")
        else
            SendSystemMessage("  now target a NON quest giver and run it again to difference")
        end
        return true
    elseif cmd == "show" or cmd == "vision" or cmd == "draw" then
        local V = RaijinLab.Vision
        if not V then SendSystemMessage("|cff7ec8e3RaijinLab|r: vision unavailable"); return true end
        local a = tostring(args or ""):lower():gsub("%s+", "")
        if a == "off" or a == "none" then
            for _, l in ipairs(V.LAYERS) do V.set(l, false) end
            SendSystemMessage("|cff7ec8e3RaijinLab|r vision |cffff5555OFF|r")
            return true
        end
        if a == "all" then
            for _, l in ipairs(V.LAYERS) do V.set(l, true) end
        elseif a ~= "" then
            local known = false
            for _, l in ipairs(V.LAYERS) do
                if l == a then known = true; V.set(l, not V.enabled(l)) end
            end
            if not known then
                SendSystemMessage("|cff7ec8e3RaijinLab|r show: unknown layer '" .. a ..
                    "' - try " .. table.concat(V.LAYERS, " / ") .. " / all / off")
                return true
            end
        end
        local on, segs = V.status()
        SendSystemMessage("|cff7ec8e3RaijinLab|r vision: " ..
            (#on > 0 and ("|cff10ff10" .. table.concat(on, ", ") .. "|r") or "|cffff5555off|r"))
        SendSystemMessage("  layers: " .. table.concat(V.LAYERS, " / ") ..
            "   (|cffffcc00/raijin show <layer>|r toggles, all, off)")
        if #on > 0 then
            SendSystemMessage(string.format("  drawing %d segment(s)/frame, cap %d",
                segs or 0, V.MAX_SEGMENTS))
            if not (RaijinLab.drawing and RaijinLab.AddDrawingCallback) then
                SendSystemMessage("  |cffff5555the draw layer is not available - " ..
                    "needs the runtime injected|r")
            end
        end
        return true
    elseif cmd == "navgrid" then
        local NG = RaijinLab.NavGrid
        if not NG then SendSystemMessage("|cff7ec8e3RaijinLab|r: navgrid unavailable"); return true end
        local st = NG.stats()
        SendSystemMessage("|cff7ec8e3RaijinLab|r navgrid: map=" .. tostring(NG.map_name()) ..
            " cached=" .. tostring(st.cached) .. " absent=" .. tostring(st.absent))
        SendSystemMessage("  dir: " .. tostring(st.dir))
        if args == "verify" then
            local r, why = NG.verify(80, 140)
            if not r then
                SendSystemMessage("  |cffff5555cannot verify: " .. tostring(why) .. "|r")
                return true
            end
            SendSystemMessage(string.format(
                "  compared %d/%d points (no tile: %d)", r.compared, r.sampled, r.no_tile))
            if r.compared == 0 then
                SendSystemMessage("  |cffff5555no overlap - tiles for this area are not generated|r")
            else
                local col = (r.pct >= 90) and "|cff10ff10" or "|cffff5555"
                SendSystemMessage(string.format(
                    "  %s%.0f%% within 3yd|r  median %.2f  mean %.2f  worst %.2f",
                    col, r.pct, r.median_err, r.mean_err, r.worst_err))
                SendSystemMessage(string.format(
                    "  signed bias %+.2f yd  (%s)", r.bias,
                    (math.abs(r.bias) > r.mean_err * 0.5)
                        and "ONE-SIDED - a systematic offset, not noise"
                        or "roughly symmetric - resolution noise, not a bias"))
                -- VERDICT FROM THE BIAS, NOT THE PERCENTAGE. An 8yd grid over
                -- 4.17yd samples cannot reach 100% on steep ground no matter how
                -- correct it is, so judging on the hit rate alone reports
                -- "systematically wrong" at exactly the point the data is fine -
                -- and sends the next person hunting a convention bug that does
                -- not exist. A one-sided error is a real defect; a symmetric one
                -- is the resolution, and the fix for that is resolution.
                local one_sided = math.abs(r.bias) > math.max(0.5, r.mean_err * 0.5)
                if one_sided then
                    SendSystemMessage("  |cffff5555ONE-SIDED ERROR - a real defect: a "
                        .. "constant offset means a bad convention or estimator|r")
                elseif r.median_err <= 2.0 then
                    SendSystemMessage("  |cff10ff10the extracted world agrees with the "
                        .. "client|r - residual is symmetric sampling error")
                    -- Report where the error actually lives instead of asserting
                    -- a cause. If the outliers are on plain walkable ground the
                    -- tidy explanation is simply wrong.
                    local NGm = RaijinLab.NavGrid
                    local label = { [NGm.UNKNOWN] = "unknown", [NGm.WALK] = "open ground",
                                    [NGm.STEEP] = "steep", [NGm.BLOCKED] = "wall",
                                    [NGm.WATER] = "water", [NGm.STRUCTURE] = "clutter" }
                    if (r.overhead or 0) > 0 then
                        SendSystemMessage(string.format(
                            "    %d point(s) had no ground at grid height but a "
                            .. "surface elsewhere in the column (roof/overhang)",
                            r.overhead))
                    end
                    if r.worst_x and r.worst_err > 3.0 then
                        SendSystemMessage(string.format(
                            "    worst at (%.0f, %.0f): grid says %.1f, client says %.1f",
                            r.worst_x, r.worst_y, r.worst_grid or 0, r.worst_live or 0))
                    end
                    for code, b in pairs(r.by_code or {}) do
                        if b.n > 0 then
                            SendSystemMessage(string.format(
                                "    %-11s n=%-4d mean %5.2f   %d over 3yd",
                                label[code] or ("code" .. code), b.n, b.sum / b.n, b.big))
                        end
                    end
                else
                    SendSystemMessage("  |cffff5555scatter without bias - wrong tile, or "
                        .. "the grid is too coarse for this terrain|r")
                end
            end
        else
            SendSystemMessage("  |cffffcc00/raijin navgrid verify|r - check the extracted "
                .. "terrain against the client's own raycasts")
        end
        return true
    elseif cmd == "esp" then
        -- SHOW THE ID ON THE OBJECT. Ascension's custom objects have no database
        -- entry, so a chat listing can only print a GUID - and matching a GUID to
        -- the bag in front of you is the step that kept costing a round trip.
        local E = RaijinLab.ObjectESP
        if not E then
            -- The 3.3.5 client builds its addon file list at STARTUP. /reload
            -- re-runs the Lua but does NOT re-parse a .toc, so a newly added
            -- file stays unloaded until the client is restarted - and the only
            -- symptom is a module that is simply not there.
            SendSystemMessage("|cffff5555RaijinLab esp:|r ObjectESP did not load.")
            SendSystemMessage("  ObjectESP.lua is NEW in the TOC, and this client "
                .. "reads the file list at startup - |cffffd100/reload is not "
                .. "enough, fully restart the client|r.")
            return true
        end
        local a = args and string.lower(args) or ""
        if a == "debug" then
            -- DUMP EVERY STAGE, NOT A CONCLUSION.
            --
            -- "nothing renders" has exactly one symptom and six possible causes,
            -- and the draw loop runs its callbacks inside pcall - so a hard error
            -- anywhere in here is SILENT except for one throttled telemetry line.
            -- Three wrong guesses (font file, addon_name, a WorldToScreen stub)
            -- came before this existed. Each line below is a stage; the first
            -- bad one is the answer.
            local out = {}
            local function row(k, v) out[#out + 1] = "  " .. k .. " = " .. tostring(v) end
            row("HasRuntime", RaijinLab.HasRuntime and RaijinLab:HasRuntime())
            row("drawing object", RaijinLab.GetDrawingObject
                and (RaijinLab:GetDrawingObject() ~= nil))
            local D = RaijinLab.drawing
            row("drawing.Text", D and D.Text ~= nil)
            row("esp.enabled", E.enabled)
            local dob = RaijinLab.GetDrawingObject and RaijinLab:GetDrawingObject()
            local ncb = 0
            if dob and dob.callbacks then
                for _ in pairs(dob.callbacks) do ncb = ncb + 1 end
            end
            row("draw callbacks", ncb)
            row("w2s table", RaijinLab.w2s ~= nil)
            -- the projection, stage by stage: camera first, then a real point
            local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
            row("GetCameraData", c ~= nil)
            if c then
                row("  cam pos", string.format("%.1f,%.1f,%.1f", c.px, c.py, c.pz))
                row("  cam fov", c.fov)
            else
                local raw = RaijinLab.RuntimeCall
                    and RaijinLab:RuntimeCall("GetCameraData")
                row("  raw GetCameraData", type(raw) .. " " .. tostring(raw))
            end
            local px, py, pz = RaijinLab:ObjectPosition("player")
            row("player pos", px and string.format("%.1f,%.1f,%.1f", px, py, pz))
            if px and RaijinLab.WorldToScreen then
                local on, nx, ny = RaijinLab.WorldToScreen(px, py, pz + 2)
                row("WorldToScreen(self)", tostring(on) .. " nx=" .. tostring(nx)
                    .. " ny=" .. tostring(ny))
            end
            local L = RaijinLab.om and RaijinLab.om.object_list
            row("gameobjects", L and L.gameobjects and #L.gameobjects or "nil")
            if px and E.pick and L then
                row("picked in range", #E.pick(L.gameobjects, px, py, pz, E.range, E.max_labels))
            end
            -- and finally: run one pass and report what it THREW, if anything
            local ok, err = pcall(E.draw)
            row("draw() pcall", ok and "ok" or ("ERROR: " .. tostring(err)))
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp debug:")
            for i = 1, #out do SendSystemMessage(out[i]) end
            return true
        end
        if a == "all" then
            E.mode = "all"
            if not E.enabled then E.start() end
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp: ON (objects + npcs + players)")
            return true
        elseif a == "objects" or a == "go" then
            E.mode = "objects"
            if not E.enabled then E.start() end
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp: ON (gameobjects)")
            return true
        elseif a == "off" then
            E.stop()
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp: OFF")
            return true
        elseif tonumber(a) then
            E.range = tonumber(a)
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp: range " .. tostring(E.range) .. " yd")
            return true
        end
        local on, why = E.toggle()
        if on == false and why then
            SendSystemMessage("|cffff5555RaijinLab esp:|r " .. tostring(why))
        else
            SendSystemMessage("|cff7ec8e3RaijinLab|r esp: "
                .. (E.enabled and "ON" or "OFF")
                .. " mode=" .. tostring(E.mode) .. " range=" .. tostring(E.range)
                .. "  |  /raijin esp all | objects | off | <range>")
        end
        return true
    elseif cmd == "goflags" then
        -- RESOLVE THE SPARKLE BIT, BY PROOF, NOT BY PREFERENCE.
        --
        -- Two real TrinityCore tables disagree by one bit shift (see GOFlags).
        -- Most bits settle it outright because they exist in only one table.
        -- 0x08 does not - it is SPARKLE under CLASSIC and ANIMATE under MODERN -
        -- and live data showed exactly that ambiguity: one object at 0x0008 and
        -- every other gameobject at 0x0000.
        --
        -- So there are two paths, and neither is a guess:
        --   /raijin goflags            list the evidence and say what it proves
        --   /raijin goflags <entry>    "I can SEE this one sparkling" -> lock it
        --
        -- The second uses the only sensor that can break the tie. A person can
        -- see a sparkle; the client will not tell us which bit caused it.
        local G = RaijinLab.GOFlags
        if not G then
            SendSystemMessage("|cff7ec8e3RaijinLab|r: GOFlags module unavailable")
            return true
        end
        -- REFUSE TO REPORT FROM A STALE RUNTIME.
        --
        -- Gameobject dynamic flags only became readable in 1.9.0-go-fields: before
        -- that the DLL read UNIT_DYNAMIC_FLAGS (0x13C) on gameobjects, which is
        -- past the end of their descriptor and returns zeros. An older resident
        -- build therefore produces a screen full of lo=0x0000 that looks like
        -- evidence and is not. Say so instead of letting it be read as data.
        local ST = RaijinLab.SelfTest
        local resident = RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion()
        if ST and ST.EXPECT_VERSION and resident ~= ST.EXPECT_VERSION then
            -- Distinguish NO RUNTIME from an OLD one. They produce identical
            -- output - a screen of lo=0x0000 - for completely different reasons,
            -- and reading that as "this server does not set the field" is a wrong
            -- conclusion that costs a day. With no bridge ObjectDynamicFlags
            -- returns nil and the object manager stores `or 0`, so EVERY object
            -- reads zero by construction; nothing about the server is visible.
            if not resident then
                SendSystemMessage("|cffff5555RaijinLab goflags: NO RUNTIME "
                    .. "INJECTED|r - the DLL is not loaded in this client.")
                SendSystemMessage("  Every object will read lo=0x0000 because "
                    .. "there is no bridge to ask - this says NOTHING about the "
                    .. "server. Inject RaijinLabLoader.exe, then run this again.")
            else
                SendSystemMessage("|cffff5555RaijinLab goflags: STALE RUNTIME|r - "
                    .. "resident " .. tostring(resident) .. ", need "
                    .. tostring(ST.EXPECT_VERSION))
                SendSystemMessage("  gameobject dynamic flags read the WRONG "
                    .. "field before " .. tostring(ST.EXPECT_VERSION)
                    .. " and come back 0. Re-inject the DLL, then run this again.")
            end
            return true
        end

        local L = RaijinLab.om and RaijinLab.om.object_list
        local gos = (L and L.gameobjects) or {}
        local want = tonumber(args)
        -- `/raijin goflags target` - name the object by TARGETING it. Ascension's
        -- custom objects are absent from the database, so the listing can only
        -- show a GUID, and copying that by hand is the kind of step that does not
        -- survive contact with a real session.
        local want_guid = nil
        if args and string.lower(args) == "target" then
            if RaijinLab.ObjectExists and RaijinLab:ObjectExists("target") then
                want_guid = RaijinLab.ObjectGUID and RaijinLab:ObjectGUID("target")
            end
            if not want_guid then
                SendSystemMessage("|cff7ec8e3RaijinLab|r goflags: no target - "
                    .. "target the sparkling object first, or pass its entry id")
                return true
            end
        end

        local px, py, pz
        if RaijinLab.ObjectPosition then
            px, py, pz = RaijinLab:ObjectPosition("player")
        end

        -- GAMEOBJECT_BYTES_1 = [state][TYPE][artKit][animProgress]. The TYPE byte
        -- exists on every gameobject regardless of dynamic flags, so it answers
        -- even if this server never sets GAMEOBJECT_DYNAMIC. Printed RAW: this
        -- addon's GameObjectTypes enum is 1-based where 3.3.5a numbers DOOR=0,
        -- and naming it from an unverified table would hide the discrepancy
        -- instead of exposing it. CHEST/GOOBER/QUESTGIVER are the lootable and
        -- quest-starting classes - whichever integers they turn out to be.
        local function type_name(t)
            local T = RaijinLab.enums and RaijinLab.enums.GameObjectTypes
            if not T then return "type=" .. tostring(t) end
            local inv = RaijinLab.enums.GameObjectTypesInverted
            local n = inv and inv[t]
            if not n then return "type=" .. tostring(t) end
            return (string.gsub(n, "GAMEOBJECT_TYPE_", ""))
        end

        local function go_extra(guid)
            if not (guid and RaijinLab.RuntimeCall) then return "" end
            local b1 = tonumber(RaijinLab:RuntimeCall("GameObjectBytes1", guid))
            local gf = tonumber(RaijinLab:RuntimeCall("ObjectFlags", guid))
            if not b1 then return "" end
            local state = math.floor(b1) % 256
            local gotype = math.floor(b1 / 256) % 256
            return string.format("%s state=%d goflags=0x%X",
                type_name(gotype), state, gf or 0)
        end

        local flagged, zero, target_lo = 0, 0, nil
        for i = 1, #gos do
            local g = gos[i]
            local dyn = g.DynamicFlags and g.DynamicFlags.value
            if type(dyn) == "number" then
                local lo = dyn % 65536
                G.observe(lo)
                if want and tonumber(g.Id) == want then target_lo = lo end
                if want_guid and tostring(g.Guid) == tostring(want_guid) then
                    target_lo = lo
                end
                if lo == 0 then
                    zero = zero + 1
                    -- A world of zeros is the case where dynamic flags told us
                    -- NOTHING. Printing type/state for the nearest few turns that
                    -- dead end into an answer in the same run instead of another
                    -- round trip.
                    if zero <= 6 then
                        SendSystemMessage(string.format(
                            "  |cff888888e=%-7s %-22s      lo=0x0000 %s|r",
                            tostring(g.Id or "?"),
                            string.sub(tostring(g.Name or "?"), 1, 22),
                            go_extra(g.Guid)))
                    end
                else
                    flagged = flagged + 1
                    -- Only NON-ZERO objects are printed. The first version listed
                    -- everything and the interesting line scrolled out of chat.
                    local bits, v = "", 1
                    for _ = 1, 16 do
                        if math.floor(lo / v) % 2 == 1 then
                            bits = bits .. (bits == "" and "" or "+")
                                .. string.format("0x%02X", v)
                        end
                        v = v * 2
                    end
                    local d = "?"
                    if px and g.Guid and RaijinLab.ObjectPosition then
                        local ox, oy, oz = RaijinLab:ObjectPosition(g.Guid)
                        if ox then
                            d = string.format("%.0f", math.sqrt((ox - px) ^ 2
                                + (oy - py) ^ 2 + ((oz or 0) - (pz or 0)) ^ 2))
                        end
                    end
                    SendSystemMessage(string.format(
                        "  |cffffd100e=%s|r %-22s %4syd lo=0x%04X %s %s",
                        tostring(g.Id or "?"),
                        string.sub(tostring(g.Name or "?"), 1, 22), d, lo, bits,
                        go_extra(g.Guid)))
                end
            end
        end

        if want or want_guid then
            if target_lo == nil then
                SendSystemMessage("|cff7ec8e3RaijinLab|r goflags: no gameobject "
                    .. "with entry " .. tostring(want) .. " in range")
                return true
            end
            local ok, why = G.prove_sparkling(target_lo)
            SendSystemMessage("|cff7ec8e3RaijinLab|r goflags: "
                .. (ok and "|cff00ff00PROVEN|r " or "|cffff5555refused|r ")
                .. tostring(why))
            if ok then
                G.save()
                SendSystemMessage("  saved - the quest-item witness is now live")
            end
            return true
        end

        SendSystemMessage(string.format(
            "|cff7ec8e3RaijinLab|r goflags: %d flagged, %d with no flags | %s",
            flagged, zero, G.status()))
        if not G.mapping() then
            SendSystemMessage("  |cffffd100Stand where you can SEE the sparkle,|r "
                .. "then run |cffffd100/raijin goflags <entry>|r naming that "
                .. "object. Its lit bit IS sparkle - that settles it for good.")
        end
        return true
    elseif cmd == "objects" or cmd == "obj" then
        -- DUMP THE DECISION INPUTS, NOT A CONCLUSION.
        --
        -- Every diagnosis this session cost a round trip because the log printed
        -- the OUTCOME ("no_known_location") and none of the values the outcome
        -- was computed from. This prints, for everything nearby: entry id, name,
        -- distance, dynamic flags (sparkle/activate), whether the database says
        -- it starts a quest, and what the client's dialog status says. One run
        -- answers "why was this not picked" without another hypothesis.
        local L = RaijinLab.om and RaijinLab.om.object_list
        if not L then SendSystemMessage("|cff7ec8e3RaijinLab|r: no object list"); return true end
        -- `cond and f()` TRUNCATES A MULTI-RETURN TO ONE VALUE. Written as
        -- `local px, py, pz = RaijinLab.ObjectPosition and RaijinLab:ObjectPosition("player")`
        -- this set px and left py/pz NIL, and the distance arithmetic below threw
        -- - taking the client down with it. Guard with a statement, not an
        -- expression, whenever the call returns more than one value.
        local px, py, pz
        if RaijinLab.ObjectPosition then
            px, py, pz = RaijinLab:ObjectPosition("player")
        end
        local QDB = RaijinLab.QuestDB
        local function dump(list, kind, label)
            local n = 0
            for i = 1, #(list or {}) do
                local o = list[i]
                local x, y, z = o.x, o.y, o.z
                if not x and o.Guid and RaijinLab.ObjectPosition then
                    local okp, xx, yy, zz = pcall(RaijinLab.ObjectPosition, RaijinLab, o.Guid)
                    if okp then x, y, z = xx, yy, zz end
                end
                local d = (x and y and px and py)
                    and math.sqrt((px - x) ^ 2 + (py - y) ^ 2) or nil
                if (not d) or d <= 60 then
                    n = n + 1
                    if n <= 12 then
                        local dyn = o.DynamicFlags and o.DynamicFlags.value
                        local starts = "-"
                        if QDB and QDB.quests_started_by and o.Id then
                            starts = QDB.quests_started_by(o.Id, kind) and "YES" or "no"
                        end
                        local st = "-"
                        if RaijinLab.QuestOM and RaijinLab.QuestOM.giver_status and o.Guid then
                            st = tostring(RaijinLab.QuestOM.giver_status(o.Guid) or "-")
                        end
                        SendSystemMessage(string.format(
                            "  %s id=%s d=%s dyn=%s starts=%s st=%s pos=%s %s",
                            label, tostring(o.Id), d and string.format("%.0f", d) or "nil",
                            tostring(dyn), starts, st, x and "y" or "NIL",
                            tostring(o.Name)))
                    end
                end
            end
            SendSystemMessage(string.format("|cff7ec8e3%s|r: %d within 60yd (of %d)",
                label, n, #(list or {})))
        end
        SendSystemMessage("|cff7ec8e3RaijinLab|r nearby objects:")
        dump(L.gameobjects, "O", "GO ")
        dump(L.npcs, "U", "NPC")
        return true
    elseif cmd == "chain" or cmd == "why" then
        -- ONE COMMAND THAT NAMES THE FIRST BROKEN LINK.
        --
        -- Every fault in this project looks the same from outside: the character
        -- stands still or jogs somewhere pointless. The chain is strictly
        -- ordered, so the FIRST failure is the only one worth acting on and
        -- everything after it is noise.
        local C = RaijinLab.Chain
        if not C then
            SendSystemMessage("Chain module not loaded")
            return true
        end
        local rows, first_bad = C.evaluate()
        SendSystemMessage("|cff7ec8e3RaijinLab|r questing chain:")
        for i, r in ipairs(rows) do
            local mark
            if r.ok == true then mark = "|cff44ff44PASS|r"
            elseif r.ok == false then mark = "|cffff4444FAIL|r"
            else mark = "|cffaaaaaa ?  |r" end
            SendSystemMessage(string.format("  %s %-16s %s", mark, r.name,
                tostring(r.detail or "")))
            if first_bad == i then
                SendSystemMessage("       |cffffcc00why it matters:|r " .. tostring(r.why))
                SendSystemMessage("       |cffffcc00^ fix this one first; "
                    .. "everything below depends on it|r")
            end
        end
        if not first_bad then
            SendSystemMessage("  |cff44ff44every link healthy|r")
        end
        return true
    elseif cmd == "spelldump" or cmd == "sd" then
        -- LIVE SPELL DATA (2026-08-02): dump the client's decoded Spell.dbc
        -- record + range entry for one or more spell IDs. Ground truth for the
        -- runtime's per-ability reader (facing/melee classification, range).
        -- Usage: /raijin spelldump 45477 45513 6603
        local function rt(name, ...)
            if not RaijinLab.HasRuntime or not RaijinLab:HasRuntime() then return nil end
            local ok, a = pcall(RaijinLab.RuntimeCall, RaijinLab, name, ...)
            if not ok then return "ERR:" .. tostring(a) end
            return tostring(a or "")
        end
        local ids = {}
        for tok in tostring(args or ""):gmatch("%d+") do ids[#ids + 1] = tonumber(tok) end
        if #ids == 0 then ids = { 45477, 45513, 26573, 6603 } end  -- Icy/Plague/Consecration/Attack
        for _, sid in ipairs(ids) do
            local melee = rt("SpellMeleeInfo", sid)
            local live = rt("SpellInfoLive", sid)
            SendSystemMessage("|cff7ec8e3RaijinLab|r spelldump " .. sid)
            SendSystemMessage("  melee: " .. (melee or "nil"))
            local hexOnly = (live or ""):match("|hex=(%x+)")
            local short = (live or ""):gsub("|hex=%x+", "")
            SendSystemMessage("  info: " .. short)
            if hexOnly and #hexOnly > 80 then
                SendSystemMessage("  hex[:80]: " .. hexOnly:sub(1, 80))
            end
        end
        SendSystemMessage("|cff7ec8e3RaijinLab|r (full hex in dev log)")
        return true
    elseif cmd == "search" or cmd == "as" then
        -- LIVE AURA-SEARCH DIAGNOSTIC (2026-08-02). Aura search silently
        -- returning nothing (rotation stuck in "wait no_target") is usually one
        -- of: (1) World.spell_max_range(id) == nil -> the aura_search condition
        -- HARD-FAILS RANGE_UNKNOWN and never calls the runtime; (2) the
        -- runtime AuraSearch returns an empty pack (OM snapshot empty / aura
        -- notes not seeded); (3) the second-pass aura filter drops every hit.
        -- This command runs the EXACT production path and reports each stage.
        -- Usage: /raijin search <spellId> [missing|present] [range]
        local W = RaijinLab and RaijinLab.World
        if not W then
            SendSystemMessage("|cff7ec8e3RaijinLab|r search: World unavailable")
            return true
        end
        local sid = tonumber((args or ""):match("(%d+)")) or 45477
        local state = tostring((args or ""):match("(%a+)")):lower()
        if state ~= "missing" and state ~= "present" then state = "missing" end
        local range = tonumber((args or ""):match("%s(%d+)%s*(%d*)")) or 0
        -- Stage 1: spell max range (the gate that hard-fails aura search).
        local maxR = W.spell_max_range and W.spell_max_range(sid)
        SendSystemMessage("|cff7ec8e3RaijinLab|r search " .. sid ..
            " state=" .. state .. " spell_max_range=" .. tostring(maxR or "NIL"))
        if not maxR then
            SendSystemMessage("  |cffff5555aura_search blocked: spell_max_range==nil " ..
                "(RANGE_UNKNOWN) - the runtime SpellMeleeInfo max= decode failed")
            return true
        end
        local sr = tonumber(range) or maxR
        if sr > maxR then sr = maxR end
        -- Stage 2: raw runtime AuraSearch pack.
        local ok, packed = nil, nil
        if RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime() then
            local state_n = (state == "missing") and 0 or 1
            ok, packed = pcall(RaijinLab.RuntimeCall, RaijinLab,
                "AuraSearch", sr, sid, state_n, 8)
        end
        SendSystemMessage("  range=" .. sr .. " raw AuraSearch ok=" .. tostring(ok) ..
            " len=" .. tostring(packed and #packed or 0))
        -- Stage 3: the production Lua wrapper (exactly what Conditions uses).
        local nm = ""
        if W.spell_name then
            nm = tostring(W.spell_name(sid) or "")
        elseif GetSpellInfo then
            local okn = pcall(GetSpellInfo, sid)
            if okn then nm = "" end -- GetSpellInfo returns multiple; use id
        end
        local list = W.find_aura_search_targets and W.find_aura_search_targets({
            kind = "debuff", state = state, spell_id = sid,
            name = nm,
            range = sr, max_n = 8,
        })
        if not list or #list == 0 then
            SendSystemMessage("  |cffff5555find_aura_search_targets returned 0 hits")
        else
            SendSystemMessage("  hits=" .. #list .. " head=" .. tostring(list[1] and list[1].guid) ..
                " dist=" .. tostring(list[1] and list[1].dist))
        end
        return true
    elseif cmd == "selftest" or cmd == "st" then
        -- VERIFY THE RUNTIME FROM INSIDE THE GAME, IN ONE COMMAND.
        --
        -- The gates, unit groups and simulator all test the ADDON; none of them
        -- can reach across the bridge into the injected DLL, where a mock stands
        -- in during every headless run. That gap is where runtime defects have
        -- repeatedly survived a fully green suite. This exercises the far side
        -- for real, and most checks need no target and no particular location.
        local ST = RaijinLab.SelfTest
        if not ST then SendSystemMessage("|cff7ec8e3RaijinLab|r: selftest module unavailable"); return true end
        local function call(name, ...)
            if not RaijinLab.HasRuntime or not RaijinLab:HasRuntime() then return nil end
            local ok, a, b, c = pcall(RaijinLab.RuntimeCall, RaijinLab, name, ...)
            if not ok then return nil end
            return a, b, c
        end
        -- RESOLVE TOKENS WITH THE AUTHORITATIVE API, AND REJECT NON-ANSWERS.
        --
        -- This was `RaijinLab:ObjectGUID(tok) or UnitGUID(tok)`, which looks like
        -- a fallback and is not one: ObjectGUID used to hand the token straight
        -- back, and a non-empty string is TRUTHY, so the `or` never fired and the
        -- selftest passed the literal "target" to the bridge as a GUID. That is
        -- the same in-range-but-meaningless value this whole selftest exists to
        -- catch, in the harness itself.
        local function resolve(tok)
            local g = UnitGUID and UnitGUID(tok)
            if type(g) ~= "string" or g == "" then return nil end
            if string.find(g, "^0x0+$") then return nil end   -- a zero GUID is not an answer
            return g
        end
        local opts = {}
        if UnitExists and UnitExists("player") then opts.player_guid = resolve("player") end
        if UnitExists and UnitExists("target") then opts.target_guid = resolve("target") end
        local rows, pass, fail, skip = ST.evaluate(call, opts)
        -- To the LOG first: that is the copy the developer actually reads.
        if ST.log_rows then pcall(ST.log_rows, rows, pass, fail, skip, "manual") end
        SendSystemMessage("|cff7ec8e3RaijinLab|r selftest (runtime):")
        for _, r in ipairs(rows) do
            local tag
            if r.ok == nil then tag = "|cff888888SKIP|r"
            elseif r.ok then tag = "|cff40ff40PASS|r"
            else tag = "|cffff4040FAIL|r" end
            SendSystemMessage(string.format("  %s %-22s %s", tag, r.name, tostring(r.detail or "")))
            if r.ok == false then
                SendSystemMessage("        |cffaaaaaawhy it matters: " .. tostring(r.why) .. "|r")
            end
        end
        SendSystemMessage(string.format("  %d passed, %d failed, %d skipped%s",
            pass, fail, skip,
            skip > 0 and " (target an NPC and re-run to cover the skipped ones)" or ""))
        return true
    elseif cmd == "check" or cmd == "contracts" or cmd == "diag2" then
        -- The bot answers "why is it doing nothing?" itself, instead of a human
        -- reading a log backwards to find which subsystem quietly declined.
        local K = RaijinLab.Contract
        if not K then SendSystemMessage("|cff7ec8e3RaijinLab|r: contract engine unavailable"); return true end
        local lines = K.report()
        SendSystemMessage("|cff7ec8e3RaijinLab|r self-check:")
        for _, l in ipairs(lines) do SendSystemMessage(l) end
        local Kn = RaijinLab.Know
        if Kn and Kn.assumptions then
            local n, parts = 0, {}
            for why, cnt in pairs(Kn.assumptions()) do
                n = n + 1
                if n <= 6 then parts[#parts + 1] = why .. "x" .. cnt end
            end
            if n > 0 then
                SendSystemMessage("  guessing about: " .. table.concat(parts, ", ") ..
                    (n > 6 and (" (+" .. (n - 6) .. " more)") or ""))
            end
        end
        local Caps = RaijinLab.Caps
        if Caps and Caps.report then
            SendSystemMessage("|cff7ec8e3RaijinLab|r capabilities:")
            for _, l in ipairs(Caps.report()) do SendSystemMessage(l) end
        end
        local F = RaijinLab.Fail
        if F and F.report then
            local fl = F.report()
            if #fl > 0 then
                SendSystemMessage("|cff7ec8e3RaijinLab|r failures (retry policy):")
                for i = 1, math.min(8, #fl) do SendSystemMessage(fl[i]) end
            end
        end
        local Rp = RaijinLab.Replay
        if Rp and Rp.report then
            for _, l in ipairs(Rp.report()) do SendSystemMessage(l) end
        end
        local Ou = RaijinLab.Outcomes
        if Ou and Ou.report then
            for _, l in ipairs(Ou.report()) do SendSystemMessage(l) end
        end
        return true
    elseif cmd == "replay" then
        local Rp = RaijinLab.Replay
        if not Rp then
            SendSystemMessage("|cff7ec8e3RaijinLab|r replay: unavailable")
            return true
        end
        local sub = (args[2] or "status"):lower()
        if sub == "dump" then
            local n = Rp.persist_dump and Rp.persist_dump(180) or 0
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r replay: dumped %d frames to SavedVariables (RaijinLabDB.replay_dump)",
                n))
        elseif sub == "show" then
            local lines = Rp.dump_lines and Rp.dump_lines(12) or {}
            SendSystemMessage("|cff7ec8e3RaijinLab|r replay tail:")
            for i = 1, #lines do SendSystemMessage("  " .. lines[i]) end
            if #lines == 0 then SendSystemMessage("  (empty ring)") end
        else
            for _, l in ipairs(Rp.report and Rp.report() or {}) do
                SendSystemMessage(l)
            end
            SendSystemMessage("  usage: /raijin replay [status|show|dump]")
        end
        return true
    elseif cmd == "why" then
        -- Per-slot decision trace, in priority order: exactly why each slot was
        -- skipped and which one was chosen. Prints the last capture and arms a
        -- fresh one, so running it twice shows current data.
        local Ex = RaijinLab.RotationExecutor
        if not Ex then
            SendSystemMessage("|cff7ec8e3RaijinLab|r why: no executor")
        else
            local tr = Ex._last_trace
            if not tr or (tr.n or 0) == 0 then
                SendSystemMessage("|cff7ec8e3RaijinLab|r why: armed - run /raijin why again in a moment")
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r why (priority order):")
                for i = 1, tr.n do
                    local e = tr[i]
                    SendSystemMessage(string.format("  %d. %-18s %-10s %s",
                        e.i or i, tostring(e.name or e.sid), tostring(e.verdict),
                        e.why and ("<" .. tostring(e.why) .. ">") or ""))
                end
            end
            Ex._want_trace = true
        end
    elseif cmd == "ranks" then
        -- What each slot's stored id ACTUALLY resolves to at cast time. If this
        -- shows a different ability than you configured, rank resolution is the bug.
        local Ex = RaijinLab.RotationExecutor
        local RR = RaijinLab.RankResolver
        local rot = Ex and Ex.get_active_rotation and select(1, Ex.get_active_rotation())
        if not (rot and RR) then
            SendSystemMessage("|cff7ec8e3RaijinLab|r ranks: no rotation/resolver")
        else
            SendSystemMessage("|cff7ec8e3RaijinLab|r slot -> spell actually cast:")
            for i, slot in ipairs(rot.slots or {}) do
                local sid = tonumber(slot.spell_id) or 0
                if sid ~= 0 then
                    local rid, rt, changed, status = RR.describe(sid)
                    local sname = GetSpellInfo and GetSpellInfo(sid) or "?"
                    local rname = GetSpellInfo and GetSpellInfo(rid) or "?"
                    SendSystemMessage(string.format("  %d. %s(%d) -> %s(%d) %s%s",
                        i, tostring(sname), sid, tostring(rname), rid,
                        tostring(status), changed and " CHANGED" or ""))
                end
            end
        end
    elseif cmd == "castlog" then
        -- Real cast timing: the gap between casts, where the GCD came from, and
        -- why anything was refused. This is how we verify "sluggish" is actually
        -- fixed instead of guessing at it.
        local Ex = RaijinLab.RotationExecutor
        if not Ex then
            SendSystemMessage("|cff7ec8e3RaijinLab|r castlog: no executor")
        else
            local dur, src = 0, "n/a"
            if Ex.gcd_fallback then dur, src = Ex.gcd_fallback() end
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r castlog: gcd_observed=%s fallback=%.2fs(%s) last_src=%s",
                Ex._gcd_obs and string.format("%.2fs", Ex._gcd_obs) or "none",
                dur, src, tostring(Ex._gcd_src)))
            local log = Ex._log or {}
            if #log == 0 then
                SendSystemMessage("  (no casts recorded yet - start the rotation)")
            end
            for i = math.max(1, #log - 11), #log do
                local L = log[i]
                SendSystemMessage(string.format("  %+.3fs %-8s %s%s",
                    L.gap or 0, tostring(L.result), tostring(L.name or L.sid),
                    L.extra and ("  <" .. tostring(L.extra) .. ">") or ""))
            end
        end
    elseif cmd == "config" or cmd == "backup" then
        local CB = RaijinLab.ConfigBackup
        if not CB then
            SendSystemMessage("|cff7ec8e3RaijinLab|r config: backup module not loaded")
        else
            local a = (args or ""):match("^(%S*)")
            if a == "save" then
                local ok, why = CB.save(true)
                SendSystemMessage("|cff7ec8e3RaijinLab|r backup: " ..
                    (ok and ("written to slot " .. tostring(CB._slot)) or ("skipped (" .. tostring(why) .. ")")))
            elseif a == "restore" then
                local did, filled = CB.restore()
                SendSystemMessage("|cff7ec8e3RaijinLab|r restore: " ..
                    (did and (tostring(#filled) .. " item(s) refilled") or ("nothing to do (" .. tostring(filled) .. ")")))
            else
                local st = CB.stats()
                SendSystemMessage(string.format(
                    "|cff7ec8e3RaijinLab|r config: looks_reset=%s  dir=%s",
                    tostring(st.looks_reset), tostring(st.dir)))
                for _, sl in ipairs(st.slots) do
                    SendSystemMessage(string.format("  slot %d: %s rotations=%d",
                        sl.slot, sl.present and "present" or "empty", sl.rotations))
                end
                SendSystemMessage("  usage: /raijin config save | /raijin config restore")
                SendSystemMessage("  NOTE: WoW only writes SavedVariables on a CLEAN logout -")
                SendSystemMessage("        a crash or force-quit loses everything since login.")
            end
        end
    elseif cmd == "log" then
        -- Control the live telemetry stream and prove it is flowing.
        local Tel, Snap = RaijinLab.Telemetry, RaijinLab.Snapshot
        if not Tel then
            SendSystemMessage("|cff7ec8e3RaijinLab|r log: telemetry not loaded")
        else
            local a1, a2 = (args or ""):match("^(%S*)%s*(%S*)$")
            if a1 == "level" and a2 ~= "" then
                Tel.set_level(nil, tonumber(a2) or 3)
                SendSystemMessage("|cff7ec8e3RaijinLab|r log level -> " .. tostring(a2))
            elseif a1 ~= "" and a2 ~= "" then
                Tel.set_level(a1, tonumber(a2) or 3)
                SendSystemMessage("|cff7ec8e3RaijinLab|r log [" .. a1 .. "] -> " .. tostring(a2))
            elseif a1 == "snap" then
                if Snap then Snap.dump() end
                SendSystemMessage("|cff7ec8e3RaijinLab|r snapshot written")
            else
                local c = Tel.cfg()
                local DL = RaijinLab.DevLog
                SendSystemMessage(string.format(
                    "|cff7ec8e3RaijinLab|r log: enabled=%s level=%d  file=%s",
                    tostring(c.enabled), c.level or 3, tostring(DL and DL.path() or "?")))
                local parts = {}
                for cat, n in pairs(Tel.counts()) do parts[#parts+1] = cat .. "=" .. n end
                table.sort(parts)
                SendSystemMessage("  emitted: " .. (#parts > 0 and table.concat(parts, " ") or "nothing yet"))
                SendSystemMessage("  usage: /raijin log level <1-5> | /raijin log <cat> <1-5> | /raijin log snap")
            end
        end
    elseif cmd == "watchdog" then
        local W = RaijinLab.Watchdog
        if not W then
            SendSystemMessage("|cff7ec8e3RaijinLab|r watchdog: not loaded")
        else
            local s = W.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r watchdog: enabled=%s idle=%ds escalation=%d",
                tostring(s.enabled), s.idle or 0, s.level or 0))
            local parts = {}
            for k, n in pairs(s.counts or {}) do parts[#parts+1] = k .. "=" .. n end
            table.sort(parts)
            if #parts > 0 then SendSystemMessage("  progress seen: " .. table.concat(parts, " ")) end
            for i = math.max(1, #(s.log or {}) - 5), #(s.log or {}) do
                local e = s.log[i]
                if e then
                    SendSystemMessage(string.format("    %s%s", tostring(e.event),
                        e.idle and (" after " .. e.idle .. "s idle") or ""))
                end
            end
        end
    elseif cmd == "brain" or cmd == "director" then
        -- WHY is it doing what it is doing? Every goal, its band, whether it is
        -- applicable and how urgently - plus the recent decision history.
        local D = RaijinLab.Director
        if not D then
            SendSystemMessage("|cff7ec8e3RaijinLab|r director: not loaded")
        else
            local lines, cur = D.explain()
            SendSystemMessage("|cff7ec8e3RaijinLab|r director: running=" .. tostring(cur or "idle"))
            for _, l in ipairs(lines) do SendSystemMessage("  " .. l) end
            local h = D.history()
            if #h > 0 then
                SendSystemMessage("  recent decisions:")
                for i = math.max(1, #h - 5), #h do
                    local e = h[i]
                    SendSystemMessage(string.format("    -> %-9s (%s%s)", tostring(e.goal),
                        tostring(e.why), e.reason and (": " .. tostring(e.reason)) or ""))
                end
            end
        end
    elseif cmd == "recover" then
        local D, T = RaijinLab.Death, RaijinLab.Trainer
        if D then
            local s = D.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r death: dead=%s ghost=%s corpse_known=%s tries=%d delay=%.0fs sickness=%s",
                tostring(s.dead), tostring(s.ghost), tostring(s.has_corpse),
                s.attempts or 0, s.delay or 0, tostring(s.sickness)))
            if s.ghost and not s.has_corpse then
                SendSystemMessage("  |cffff5555corpse position unknown - will use the spirit healer|r")
            end
        end
        if T then
            local s = T.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r trainer: at_trainer=%s offered=%d affordable=%d learned=%d needs=%s%s",
                tostring(s.at_trainer), s.offered or 0, s.affordable or 0,
                s.learned_total or 0, tostring(s.needs),
                s.reason and (" ("..s.reason..")") or ""))
            local P = RaijinLab.POI
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if P and px then
                local r, d = P.nearest("trainer", px, py, pz)
                if r then
                    SendSystemMessage(string.format("  nearest trainer: %s (%.0fyd)", tostring(r.n or "?"), d or 0))
                else
                    SendSystemMessage("  no trainer remembered yet")
                end
            end
        end
    elseif cmd == "vendor" then
        local V = RaijinLab.Vendor
        if not V then
            SendSystemMessage("|cff7ec8e3RaijinLab|r vendor: not loaded")
        else
            local s = V.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r vendor: free=%d durability=%.0f%% junk=%d needs_trip=%s%s",
                s.free_slots or 0, s.durability or 100, s.junk or 0,
                tostring(s.needs_trip), s.reason and (" ("..s.reason..")") or ""))
            local P = RaijinLab.POI
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if P and px then
                for _, k in ipairs({ "vendor", "repair" }) do
                    local r, d = P.nearest(k, px, py, pz)
                    if r then
                        SendSystemMessage(string.format("  nearest %s: %s (%.0fyd)",
                            k, tostring(r.n or "?"), d or 0))
                    else
                        SendSystemMessage("  no " .. k .. " remembered yet")
                    end
                end
            end
            -- show exactly what WOULD be sold, so nothing is a surprise
            local list = V.junk_list()
            for i = 1, math.min(#list, 8) do
                SendSystemMessage("  would sell: " .. tostring(list[i].link or "?"))
            end
        end
    elseif cmd == "survival" then
        -- Can this character keep itself going unattended? Mounts for travel,
        -- food/drink for recovery - the two things whose absence quietly stalls
        -- an otherwise working bot.
        local M, R = RaijinLab.Mount, RaijinLab.Rest
        if M then
            local s = M.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r mount: %d known, mounted=%s pending=%s enabled=%s",
                s.known or 0, tostring(s.mounted), tostring(s.pending), tostring(s.enabled)))
            if (s.known or 0) == 0 then
                SendSystemMessage("  |cffff9955no mounts learned - travel will be on foot|r")
            else
                local pick = M.pick()
                if pick then SendSystemMessage("  would summon: " .. tostring(pick.name)) end
            end
        end
        if R then
            local s = R.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r rest: hp=%.0f%% mana=%s food=%d drink=%d state=%s",
                s.hp or 0, s.mana_user and string.format("%.0f%%", s.mana or 0) or "n/a",
                s.food or 0, s.drink or 0, tostring(s.state)))
            if (s.food or 0) == 0 then
                SendSystemMessage("  |cffff9955no usable food in bags|r")
            end
            if s.mana_user and (s.drink or 0) == 0 then
                SendSystemMessage("  |cffff9955no usable drink in bags (and you use mana)|r")
            end
            local ok, why = R.should_rest()
            SendSystemMessage("  should rest now: " .. tostring(ok) .. " (" .. tostring(why) .. ")")
        end
    elseif cmd == "terrain" then
        -- What the bot understands about the ground it is standing on and the
        -- route quality around it: slope, road traffic, danger, live obstacles.
        local WM, TV, OB = RaijinLab.WorldMesh, RaijinLab.Traversability, RaijinLab.Obstacles
        local px, py, pz = RaijinLab:ObjectPosition("player")
        if not (WM and px) then
            SendSystemMessage("|cff7ec8e3RaijinLab|r terrain: no position/mesh")
        else
            local id = WM.cell_id(px, py, pz)
            local slope = WM.slope_deg and WM.slope_deg(id)
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r terrain: slope=%s walkable=%s cost=%.2f",
                slope and string.format("%.1fdeg", slope) or "unmeasured",
                tostring(WM.is_walkable(px, py, pz)), WM.cost_factor(px, py, pz)))
            if TV then
                local d, r = TV.sample(px, py)
                SendSystemMessage(string.format(
                    "  traversability: road=%.1f danger=%.1f factor=%.2f  (%s)",
                    r, d, TV.factor(px, py, pz),
                    r >= 8 and "ON A ROAD" or (d >= 8 and "dangerous ground" or "open ground")))
                local s = TV.stats()
                SendSystemMessage(string.format("  field: %d cells, %d road cells", s.cells or 0, s.road_cells or 0))
            end
            if OB then
                local st = OB.stats()
                SendSystemMessage(string.format("  solid entities: %d tracked (age %.1fs) blocked_here=%s",
                    st.n or 0, st.age or 0, tostring(OB.blocks(px, py, pz))))
            end
            -- what can we actually step to from here?
            if WM.state_neighbours then
                local walk, jump = 0, 0
                for _, nb in ipairs(WM.state_neighbours(id)) do
                    if nb.edge == WM.EDGE_JUMP then jump = jump + 1 else walk = walk + 1 end
                end
                SendSystemMessage(string.format("  exits: %d walkable, %d require a jump", walk, jump))
            end
        end
    elseif cmd == "travel" and (args == nil or args == "") then
        local TN = RaijinLab.TravelNet
        if not TN then
            SendSystemMessage("|cff7ec8e3RaijinLab|r travel: not loaded")
        else
            local s = TN.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r travel[%s]: %d taxi nodes known, %d transits learned, on_taxi=%s",
                tostring(s.map), s.taxi_nodes or 0, s.transits or 0, tostring(s.on_taxi)))
            local P = RaijinLab.POI
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if P and px then
                local fm, d = P.nearest("flightmaster", px, py, pz)
                if fm then
                    SendSystemMessage(string.format("  nearest flight master: %s (%.0fyd)",
                        tostring(fm.n or "?"), d or 0))
                else
                    SendSystemMessage("  no flight master remembered yet (visit one once)")
                end
            end
        end
    elseif cmd == "patrol" then
        local P = RaijinLab.Patrol
        if not P then
            SendSystemMessage("|cff7ec8e3RaijinLab|r patrol: not loaded")
        else
            local name = (args and args ~= "") and args or nil
            local st = P.stats(name)
            SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r patrol %s: %d spawn points known, %d worked recently",
                tostring(name or "(all)"), st.points or 0, st.recently_worked or 0))
            local a = name and P.area_of(name)
            if a then
                SendSystemMessage(string.format("  camp centre (%.0f,%.0f) radius %.0fyd from %d points",
                    a.x, a.y, a.radius, a.points))
            end
        end
    elseif cmd == "questpolicy" then
        local QP = RaijinLab.QuestPolicy
        if not QP then
            SendSystemMessage("|cff7ec8e3RaijinLab|r questpolicy: not loaded")
        else
            SendSystemMessage("|cff7ec8e3RaijinLab|r quest policy: " .. QP.describe())
        end
    elseif cmd == "poi" then
        -- What the bot REMEMBERS about the world: quest givers, turn-ins,
        -- objectives, vendors... this is what makes out-of-render-range travel work.
        local P = RaijinLab.POI
        if not P then
            SendSystemMessage("|cff7ec8e3RaijinLab|r poi: module not loaded")
        else
            local s = P.stats()
            local parts = {}
            for k, n in pairs(s.by_kind or {}) do parts[#parts + 1] = k .. "=" .. n end
            table.sort(parts)
            SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r poi[%s]: %d remembered  %s",
                tostring(s.map), s.total or 0, table.concat(parts, " ")))
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if px then
                for _, kind in ipairs({ "objective", "giver", "turnin", "vendor", "repair", "trainer" }) do
                    local r, d = P.nearest(kind, px, py, pz)
                    if r then
                        SendSystemMessage(string.format("  nearest %-10s %-22s %.0fyd  seen x%d",
                            kind, tostring(r.n or "?"), d or 0, r.c or 1))
                    end
                end
            end
        end
    elseif cmd == "hier" then
        -- Long-range planner state: pyramid size, and whether the current target
        -- is provably reachable + what the wall-aware heuristic thinks it costs.
        local H, WM = RaijinLab.HLP, RaijinLab.WorldMesh
        if not (H and WM) then
            SendSystemMessage("|cff7ec8e3RaijinLab|r hier: not loaded")
        else
            local s = H.stats()
            if not s.built then
                SendSystemMessage("|cff7ec8e3RaijinLab|r hier: pyramid not built (no mesh yet)")
            else
                SendSystemMessage(string.format(
                    "|cff7ec8e3RaijinLab|r hier[%s] gen=%s open_cells=%d  blocks L1=%d L2=%d L3=%d L4=%d",
                    tostring(s.map), tostring(s.gen), s.open_cells or 0,
                    s.l1 or 0, s.l2 or 0, s.l3 or 0, s.l4 or 0))
            end
            local px, py, pz = RaijinLab:ObjectPosition("player")
            local tx, ty, tz
            if UnitExists and UnitExists("target") then
                tx, ty, tz = RaijinLab:ObjectPosition("target")
            end
            if px and tx then
                local sid = WM.nearest_known(px, py, pz, 24)
                local gid = WM.nearest_known(tx, ty, tz, 64)
                if sid and gid then
                    local ok = H.reachable(sid, gid)
                    local d = math.sqrt((tx - px) ^ 2 + (ty - py) ^ 2)
                    local f = H.potential(gid, { level = 1 })
                    local h = f and H.h_for(f, sid, tx, ty) or nil
                    SendSystemMessage(string.format(
                        "  target %.0fyd away: reachable=%s  heuristic=%s (straight %.0f)",
                        d, tostring(ok ~= false),
                        h and string.format("%.0f", h) or "n/a", d))
                else
                    SendSystemMessage("  target: no mapped ground near "
                        .. (sid and "target" or "player") .. " yet (walk/survey more)")
                end
            end
        end
    elseif cmd == "mesh" then
        local WM = RaijinLab.WorldMesh
        if WM and WM.stats then
            local s = WM.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab|r mesh[%s]: cells=%d traversed=%d seen=%d hazard=%d session=%s",
                tostring(s.map), s.cells or 0, s.traversed or 0, s.seen or 0, s.hazard or 0, tostring(s.session)))
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if px and WM.cost_factor then
                SendSystemMessage(string.format("  here: walkable=%s heat=%d cost_factor=%.2f",
                    tostring(WM.is_walkable(px, py, pz)), WM.heat(px, py, pz) or 0, WM.cost_factor(px, py, pz)))
            end
            local Sv = RaijinLab.Surveyor
            if Sv and Sv.stats then
                local ss = Sv.stats()
                SendSystemMessage(string.format("  surveyor: running=%s probes=%d fan=%d",
                    tostring(ss.running), ss.surveyed or 0, ss.fan or 0))
            end
        else
            SendSystemMessage("|cffffd200RaijinLab|r mesh: WorldMesh unavailable")
        end
    elseif cmd == "turntest" then
        -- One-time turn-primitive calibration: drives each real turn lever and logs
        -- the character's actual facing response so we build steering on hard data.
        if RaijinLab.TurnDiag then
            local ok = RaijinLab:TurnDiag()
            SendSystemMessage(ok and "|cff7ec8e3RaijinLab|r turn calibration running (~4s) - watch, then check raijinlab_dev.log [diag]"
                or "|cffffd200RaijinLab|r turntest: could not start (runtime 1.8.6+ + in world?)")
        else
            SendSystemMessage("|cffffd200RaijinLab|r turntest: TurnDiag not loaded")
        end
    elseif cmd == "nav" then
        local Nv = RaijinLab.Navigator
        local a = ((args or ""):match("^%s*(%S*)") or ""):lower()
        if a == "stop" then
            if Nv then Nv.stop() end
            SendSystemMessage("|cff7ec8e3RaijinLab|r nav stopped")
        elseif a == "target" then
            if UnitExists and UnitExists("target") and Nv then
                local g = UnitGUID and UnitGUID("target")
                local x, y, z = RaijinLab:ObjectPosition(g)
                if x then
                    Nv.move_to({ x = x, y = y, z = z }, { goal_guid = g, arrive_dist = 3 })
                    SendSystemMessage("|cff7ec8e3RaijinLab|r nav -> target (steering)")
                else
                    SendSystemMessage("|cffffd200RaijinLab|r nav: target position nil - /raijin om first")
                end
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r nav: no target")
            end
        elseif a == "steering" then
            SendSystemMessage("|cff7ec8e3RaijinLab|r nav steering = always ON (keyboard only; CTM forbidden)")
        elseif a == "trace" then
            -- Verify the real TraceLine raycast: line-of-sight to the target + the
            -- ground height under the player. Needs the 1.8.0-trace runtime + OM on.
            local px, py, pz = RaijinLab:ObjectPosition("player")
            if not px then
                SendSystemMessage("|cffffd200RaijinLab|r nav trace: no player pos - /raijin om first")
            else
                local gz = RaijinLab.TraceGround and RaijinLab:TraceGround(px, py, pz)
                SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r ground under you: %s (you z=%.1f)",
                    tostring(gz and string.format("%.2f", gz) or "none"), pz))
                if UnitExists and UnitExists("target") then
                    local g = UnitGUID and UnitGUID("target")
                    local tx, ty, tz = RaijinLab:ObjectPosition(g)
                    if tx then
                        local blocked, hx, hy, hz = RaijinLab:TraceLine(px, py, pz + 1.5, tx, ty, tz + 1.5, 0x100111)
                        SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r LoS to target: %s  hit=(%.1f, %.1f, %.1f)",
                            blocked and "|cffff5555BLOCKED|r" or "|cff55ff55CLEAR|r",
                            hx or 0, hy or 0, hz or 0))
                    end
                end
            end
        elseif a == "draw" then
            RaijinLabDB.nav = RaijinLabDB.nav or {}
            local on = not (Nv and Nv._drawing)
            if Nv and Nv.set_draw then Nv.set_draw(on) end
            RaijinLabDB.nav.draw = on
            SendSystemMessage("|cff7ec8e3RaijinLab|r nav path drawing = " .. tostring(on) ..
                " (needs 1.8.2-cam runtime; calibrate with /raijin cam)")
        else
            local x, y, z = (args or ""):match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
            if x and Nv then
                Nv.move_to({ x = tonumber(x), y = tonumber(y), z = tonumber(z) }, { arrive_dist = 3 })
                SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r nav -> %s, %s, %s (steering)", x, y, z))
            elseif a == "swim" then
                -- Live water probe: what the controller believes right now.
                local px, py, pz = RaijinLab:ObjectPosition("player")
                local swim = IsSwimming and IsSwimming()
                local br = Nv and Nv.breath_frac and Nv.breath_frac()
                local aact = Nv and Nv._active
                SendSystemMessage(string.format(
                    "|cff7ec8e3RaijinLab nav swim|r swimming=%s z=%s breath=%s latch=%s asc=%s desc=%s state=%s",
                    tostring(swim and true or false),
                    pz and string.format("%.1f", pz) or "?",
                    br ~= nil and string.format("%.2f", br) or "nil",
                    tostring(Nv and Nv._breath_surface),
                    tostring(Nv and Nv._ascend), tostring(Nv and Nv._descend),
                    tostring(Nv and Nv.state)))
                if aact then
                    SendSystemMessage(string.format(
                        "  active shore=%s vert=%s water_ahead=%s floor_ahead=%s goal=(%.0f,%.0f,%.0f)",
                        tostring(aact.shore), tostring(aact.swim_vert),
                        tostring(aact.water_ahead), tostring(aact.floor_ahead),
                        aact.goal and aact.goal.x or 0, aact.goal and aact.goal.y or 0,
                        aact.goal and aact.goal.z or 0))
                else
                    SendSystemMessage("  no active move (survival-only if latch=true)")
                end
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r usage: /raijin nav target | stop | steering | draw | trace | swim | <x> <y> <z>  (state=" ..
                    tostring(Nv and Nv.state) .. ")")
            end
        end
    elseif cmd == "cam" then
        -- Camera calibration dump: confirms the runtime is reading the view
        -- matrix correctly (fwd/right/up should each have magnitude ~1.0, fov
        -- ~0.7-1.5 rad) and shows where the target projects.
        local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
        if not c then
            SendSystemMessage("|cffffd200RaijinLab cam|r no data (need 1.8.2-cam runtime + OM on)")
        else
            local function m(x, y, z) return math.sqrt(x * x + y * y + z * z) end
            SendSystemMessage(string.format("|cff7ec8e3cam|r pos=(%.1f, %.1f, %.1f)  fov=%.4f", c.px, c.py, c.pz, c.fov))
            SendSystemMessage(string.format("  fwd=(%.3f, %.3f, %.3f) |%.3f|", c.fx, c.fy, c.fz, m(c.fx, c.fy, c.fz)))
            SendSystemMessage(string.format("  right=(%.3f, %.3f, %.3f) |%.3f|", c.rx, c.ry, c.rz, m(c.rx, c.ry, c.rz)))
            SendSystemMessage(string.format("  up=(%.3f, %.3f, %.3f) |%.3f|", c.ux, c.uy, c.uz, m(c.ux, c.uy, c.uz)))
            if UnitExists and UnitExists("target") then
                local tx, ty, tz = RaijinLab:ObjectPosition(UnitGUID and UnitGUID("target"))
                if tx then
                    local on, nx, ny = RaijinLab.WorldToScreen(tx, ty, tz)
                    SendSystemMessage(string.format("  target projects: onScreen=%s  ndc=(%.3f, %.3f from bottom-left)",
                        tostring(on), nx or -1, ny or -1))
                end
            end
        end
    elseif cmd == "path" then
        -- Real pathfinding (async A* around terrain) then steer the route.
        local Nv = RaijinLab.Navigator
        local a = ((args or ""):match("^%s*(%S*)") or ""):lower()
        if a == "target" and UnitExists and UnitExists("target") then
            -- The object manager must be resolving positions to read a UNIT's world
            -- pos. Ensure it's on and retry a few times before giving up, so a
            -- transient miss doesn't spam "no target pos".
            if RaijinLab.RuntimeCall then RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1") end
            local g = UnitGUID and UnitGUID("target")
            local tx, ty, tz
            for _ = 1, 4 do
                tx, ty, tz = RaijinLab:ObjectPosition(g)
                if tx and ty and tz then break end
            end
            if tx and ty and tz and Nv and Nv.pathfind_to then
                Nv.pathfind_to({ x = tx, y = ty, z = tz }, { arrive_dist = 3, goal_guid = g })
                SendSystemMessage("|cff7ec8e3RaijinLab|r pathing to target...")
            else
                SendSystemMessage("|cffffd200RaijinLab|r path: target pos unavailable (out of range / not loaded)")
            end
        else
            local x, y, z = (args or ""):match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
            if x and Nv and Nv.pathfind_to then
                Nv.pathfind_to({ x = tonumber(x), y = tonumber(y), z = tonumber(z) }, { arrive_dist = 3 })
                SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r pathfinding to %s, %s, %s (async)...", x, y, z))
            else
                SendSystemMessage("|cff7ec8e3RaijinLab|r usage: /raijin path target | <x> <y> <z>")
            end
        end
    elseif cmd == "perf" then
        local S = RaijinLab.Scheduler
        if S and S.stats then
            local s = S.stats()
            SendSystemMessage(string.format(
                "|cff7ec8e3RaijinLab perf|r sched=%.2fms peak=%.2fms  budget=%.2fms%s  jobs=%d",
                s.last_ms or 0, s.peak_ms or 0, s.budget or 0,
                (RaijinLabDB.perf and RaijinLabDB.perf.budget_ms) and " (pinned)" or " (adaptive)",
                s.alive or 0))
            if s.frame_ms then
                SendSystemMessage(string.format("  frame=%.1fms (~%.0f fps)  -> budget auto-tunes to spare frame time",
                    s.frame_ms, s.fps or 0))
            end
            local gc = RaijinLab.GroundCache and RaijinLab.GroundCache.stats()
            if gc then
                SendSystemMessage(string.format(
                    "  ground cache: %d cells  hit-rate %.0f%%  (%d hits / %d miss)",
                    gc.count or 0, (gc.rate or 0) * 100, gc.hits or 0, gc.misses or 0))
            end
            local wm = RaijinLab.WorldMesh and RaijinLab.WorldMesh.stats()
            if wm then
                SendSystemMessage(string.format(
                    "  world memory [%s]: %d learned snag spots, %d proven seams",
                    tostring(wm.map), wm.stuck or 0, wm.ramps or 0))
            end
            SendSystemMessage("  (set RaijinLabDB.perf.budget_ms to tune the per-frame compute budget)")
        else
            SendSystemMessage("|cff7ec8e3RaijinLab|r scheduler not loaded")
        end
    elseif cmd == "quest" then
        local Suite = RaijinLab.QuestSuite
        local a = ((args or ""):match("^%s*(%S*)") or ""):lower()
        if a == "on" or a == "start" then
            if not Suite then
                SendSystemMessage("|cffff5555RaijinLab|r QuestSuite not loaded - /reload")
                return true
            end
            -- Master gate suppresses Suite.tick while master is OFF. Starting
            -- quest alone then looks like "on did nothing". Arm master first.
            local M = RaijinLab.Master
            if M then
                RaijinLabDB = RaijinLabDB or {}
                RaijinLabDB.modules = RaijinLabDB.modules or {}
                RaijinLabDB.modules.quest = true
                RaijinLabDB.modules.rotation = true
                RaijinLabDB.modules.combat = true
                if M.start_all then
                    pcall(M.start_all, "quest_on")
                else
                    RaijinLabDB.master = true
                    Suite.start()
                end
            else
                Suite.start()
            end
            local master_on = not (M and M.suppressed and M.suppressed())
            local ver = RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion()
                or (RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("GetRuntimeVersion"))
            SendSystemMessage(string.format(
                "|cff55ff55RaijinLab quest ON|r  master=%s  runtime=%s",
                master_on and "ON" or "|cffff5555OFF|r",
                tostring(ver or "?")))
            if Suite.status then
                SendSystemMessage("|cff7ec8e3  state|r " .. tostring(Suite.status()))
            end
            if not master_on then
                SendSystemMessage("|cffffd200  tip|r Master is OFF - click the minimap master button or /raijin master on")
            end
        elseif a == "off" or a == "stop" then
            if Suite then Suite.stop() end
            SendSystemMessage("|cffff5555RaijinLab quest OFF|r")
        elseif a == "givers" then
            -- Dump nearby NPC dialog status (CGObject+0x90). A zero this frame
            -- may still query the server; run twice a few seconds apart.
            -- Enum list needs om.enable=1 after warm; never force during suite warm.
            local Mw = RaijinLab.Master
            if not (Mw and Mw.in_suite_warm and Mw.in_suite_warm()) then
                if RaijinLab.RuntimeCall then
                    pcall(function() RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1") end)
                end
                if RaijinLab.InitObjectManager and RaijinLab.GetObjManagerFrame
                    and not RaijinLab:GetObjManagerFrame() then
                    pcall(function() RaijinLab:InitObjectManager() end)
                end
            else
                SendSystemMessage("|cffffd200RaijinLab|r OM warming after suite-on - wait ~8s")
            end
            local om = RaijinLab.om and RaijinLab.om.object_list
            local ver = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("GetRuntimeVersion")
            local n = om and om.npcs and #om.npcs or 0
            if not om or not om.npcs then
                SendSystemMessage("|cffffd200RaijinLab quest|r OM not running - /raijin om first")
            elseif n == 0 then
                SendSystemMessage(string.format(
                    "|cffffd200RaijinLab quest givers|r runtime=%s  npcs=0 (wait 1s / /raijin om)",
                    tostring(ver)))
            else
                SendSystemMessage(string.format(
                    "|cffffd200RaijinLab quest givers|r runtime=%s  (7/8=!  9/10=?  0=none/pending)",
                    tostring(ver)))
                local shown, zeroed = 0, 0
                for i = 1, math.min(n, 40) do
                    local s = om.npcs[i]
                    local key = s.Guid or s.Object
                    local st = RaijinLab.ObjectQuestGiverStatus
                        and RaijinLab:ObjectQuestGiverStatus(key)
                    st = tonumber(st) or 0
                    if st ~= 0 then
                        shown = shown + 1
                        local tag = ""
                        if st == 8 or st == 7 or st == 2 or st == 4 then tag = " !"
                        elseif st == 10 or st == 9 or st == 6 or st == 3 then tag = " ?"
                        elseif st == 5 then tag = " grey"
                        end
                        SendSystemMessage(string.format("   %s = %d%s", tostring(s.Name), st, tag))
                    else
                        zeroed = zeroed + 1
                    end
                end
                SendSystemMessage(string.format(
                    "   non-zero=%d  zero/pending=%d  npcs=%d  (re-run in 3s if pending)",
                    shown, zeroed, n))
            end
        elseif a == "giverprobe" then
            local g = UnitGUID and UnitGUID("target")
            if not g then
                SendSystemMessage("|cff7ec8e3RaijinLab|r giverprobe: target a ! or ? NPC")
                return true
            end
            -- Status field reads do not need OM enum, but enable it for nearby scans.
            if RaijinLab.RuntimeCall then
                RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1")
            end
            local nm = (UnitName and UnitName("target")) or "?"
            local ver = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("GetRuntimeVersion")
            local diag = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("ObjectQuestGiverDiag", g)
            local st = RaijinLab.ObjectQuestGiverStatus and RaijinLab:ObjectQuestGiverStatus(g)
            local inst90 = RaijinLab.ObjectInstanceField
                and tonumber(RaijinLab:ObjectInstanceField(g, 0x90))
            SendSystemMessage(string.format(
                "|cff7ec8e3giverprobe|r %s  runtime=%s", nm, tostring(ver)))
            SendSystemMessage(string.format(
                "  status=%s  instance+0x90=%s  guid=%s",
                tostring(st), tostring(inst90), tostring(g)))
            if diag then
                SendSystemMessage("|cff7ec8e3  diag|r " .. tostring(diag))
            end
            -- Wait and re-read after the query the first call issued.
            if C_Timer and C_Timer.After then
                C_Timer.After(1.5, function()
                    local st2 = RaijinLab.ObjectQuestGiverStatus
                        and RaijinLab:ObjectQuestGiverStatus(g)
                    local d2 = RaijinLab.RuntimeCall
                        and RaijinLab:RuntimeCall("ObjectQuestGiverDiag", g)
                    SendSystemMessage(string.format(
                        "|cff7ec8e3giverprobe +1.5s|r status=%s", tostring(st2)))
                    if d2 then
                        SendSystemMessage("|cff7ec8e3  diag+1.5s|r " .. tostring(d2))
                    end
                end)
            end
        elseif a == "obj" or a == "objectives" then
            if not RaijinLab.QuestLog then
                SendSystemMessage("|cff7ec8e3RaijinLab|r QuestLog not loaded")
            else
                for _, q in ipairs(RaijinLab.QuestLog.scan()) do
                    SendSystemMessage(string.format("|cff7ec8e3%s|r%s", tostring(q.title),
                        q.complete and " |cff55ff55(COMPLETE)|r" or ""))
                    for _, o in ipairs(q.objectives) do
                        SendSystemMessage(string.format("   [%s] %s  %s/%s %s",
                            tostring(o.kind), tostring(o.name),
                            tostring(o.current or "-"), tostring(o.required or "-"),
                            o.finished and "|cff55ff55DONE|r" or ""))
                    end
                end
                local t = RaijinLab.QuestOM and RaijinLab.QuestOM.nearest_objective({})
                if t then
                    SendSystemMessage(string.format("|cffffd200nearest tied|r %s (%s) %.1f yd",
                        tostring(t.name), tostring(t.kind), t.dist or -1))
                else
                    SendSystemMessage("|cffffd200nearest tied|r none in range")
                end
            end
        else
            if Suite and Suite.status then
                SendSystemMessage("|cff7ec8e3RaijinLab|r " .. Suite.status())
            end
            -- Force a log flush so the user can read disk immediately.
            if RaijinLab.DevLog and RaijinLab.DevLog.flush then
                pcall(RaijinLab.DevLog.flush)
            end
            local path = RaijinLab.DevLog and RaijinLab.DevLog.path and RaijinLab.DevLog.path()
            if path then
                SendSystemMessage("|cff7ec8e3RaijinLab|r disk log: " .. tostring(path))
            end
            SendSystemMessage("|cff7ec8e3RaijinLab|r usage: /raijin quest on|off|status|obj|givers|giverprobe")
        end
    elseif cmd == "grindwp" then
        if RaijinLab.Grinder then RaijinLab.Grinder.add_waypoint() end
    elseif cmd == "grindclear" then
        if RaijinLab.Grinder then RaijinLab.Grinder.clear_route() end
    elseif cmd == "status" then
        local v, b, toc = RaijinLab:ClientBuild()
        SendSystemMessage(string.format("RaijinLab status | runtime=%s | build=%s (%s) toc=%s | ascension=%s",
            tostring(RaijinLab:RuntimeVersion() or "none"),
            tostring(v), tostring(b), tostring(toc),
            tostring(RaijinLab:IsAscensionClient())))
        if args == "ui" then
            if RaijinLab.Menu then RaijinLab.Menu:Show()
            elseif RaijinLab.ShowStatusFrame then RaijinLab:ShowStatusFrame() end
        end
    elseif cmd == "om" then
        -- Live object-manager probe + ensure the world list is running.
        -- Never force-enable during suite-on warm (hard-crash path).
        local Mw = RaijinLab.Master
        if Mw and Mw.in_suite_warm and Mw.in_suite_warm() then
            SendSystemMessage(string.format(
                "|cffffd200RaijinLab|r OM warming (%.0fs left) - not forcing enable",
                Mw.suite_om_eta and Mw.suite_om_eta() or 0))
            return true
        end
        RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1")
        RaijinLab:RuntimeCall("SetSystemVar", "om.probe", "1")
        if not RaijinLab:GetObjManagerFrame() and RaijinLab.InitObjectManager then
            RaijinLab:InitObjectManager()
        end
        local probe = RaijinLab:RuntimeCall("OmProbe")
        if type(probe) == "string" and probe ~= "" then
            print("|cff7ec8e3RaijinLab OM|r  " .. probe)
            local px, py, pz = probe:match("player=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
            local objs = probe:match("objects=(%d+)")
            local npcs = probe:match("npcs=(%d+)")
            local players = probe:match("players=(%d+)")
            local gobs = probe:match("gameobjects=(%d+)")
            local enum = probe:match("enum=([%w%-]+)")
            local mode = probe:match("mode=([%w%-]+)")
            print(string.format(
                "|cff7ec8e3RaijinLab OM|r  player=(%s, %s, %s)  objects=%s npcs=%s players=%s gos=%s  enum=%s mode=%s",
                tostring(px), tostring(py), tostring(pz),
                tostring(objs), tostring(npcs), tostring(players), tostring(gobs),
                tostring(enum), tostring(mode)))
            if enum == "list-only" then
                print("|cffffd200RaijinLab OM|r  EnumVisibleObjects latched off this inject; list-walk still feeds the snapshot.")
            end
        else
            local pos = RaijinLab:RuntimeCall("ObjectPosition")
            local x, y, z
            if type(pos) == "string" then
                x, y, z = pos:match("([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
            else
                x, y, z = pos, nil, nil
            end
            local objs    = RaijinLab:RuntimeCall("GetObjectCount")
            local npcs    = RaijinLab:RuntimeCall("GetNpcCount")
            local players = RaijinLab:RuntimeCall("GetPlayerCount")
            local gobs    = RaijinLab:RuntimeCall("GetGameObjectCount")
            print(string.format("|cff7ec8e3RaijinLab OM|r  player=(%s, %s, %s)  |  objects=%s  npcs=%s  players=%s  gameobjects=%s",
                tostring(x), tostring(y), tostring(z),
                tostring(objs), tostring(npcs), tostring(players), tostring(gobs)))
        end
    elseif cmd == "nearby" then
        -- Live unit dump from OM (requires units to be enumerated)
        local range = tonumber(args) or 60
        local raw = RaijinLab:RuntimeCall("NearbyUnits", range, 12)
        if type(raw) ~= "string" or raw == "" or raw == "0" then
            print("|cff7ec8e3RaijinLab|r nearby: no units in OM (npcs still missing from enum - check runtime.log hist unit=)")
        else
            print("|cff7ec8e3RaijinLab nearby|r  " .. raw)
            -- Pretty lines
            local n = raw:match("^(%d+)")
            print(string.format("|cff7ec8e3RaijinLab|r  %s unit(s) within %s yd", tostring(n), tostring(range)))
            for entry in string.gmatch(raw, "|([^|]+)") do
                local guid, id, x, y, z, d = entry:match("([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)")
                if guid then
                    print(string.format("  %s entry=%s dist=%s pos=(%s,%s,%s)", guid, id, d, x, y, z))
                end
            end
        end
    elseif cmd == "castable" then
        -- Master toggle for the implicit auto-castable gate (skip un-castable
        -- spells: unusable / out of line-of-sight / target immune).
        RaijinLabDB = RaijinLabDB or {}
        local a = string.lower(args or "")
        if a == "on" or a == "true" or a == "1" then
            RaijinLabDB.auto_castable = true
        elseif a == "off" or a == "false" or a == "0" then
            RaijinLabDB.auto_castable = false
        else
            local cur = (RaijinLabDB.auto_castable ~= false)  -- default true
            RaijinLabDB.auto_castable = not cur
        end
        SendSystemMessage("|cff7ec8e3RaijinLab|r auto-castable gate: " ..
            (RaijinLabDB.auto_castable ~= false
                and "|cff55ff55ON|r (skips unusable / out-of-LoS / immune)"
                or  "|cffaaaaaaOFF|r"))
    elseif cmd == "dist" then
        -- Diagnose range model. Always prints (not gated by verbose).
        local rt = RaijinLab:HasRuntime() and (RaijinLab:RuntimeVersion() or "yes") or "OFF"
        SendSystemMessage("|cff7ec8e3RaijinLab|r runtime: " .. tostring(rt))
        if not (UnitExists and UnitExists("target")) then
            SendSystemMessage("|cff7ec8e3RaijinLab|r dist: no target selected.")
        else
            local tg = UnitGUID and UnitGUID("target") or "?"
            local px, py, pz = RaijinLab:ObjectPosition("player")
            local tx, ty, tz = RaijinLab:ObjectPosition("target")
            -- Raw bridge probe (bypass Lua helpers) for debugging.
            local rawP = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("ObjectPosition")
            local rawT = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("ObjectPosition", tostring(tg))
            local function fmt(x, y, z)
                if not x then return "nil (no position)" end
                return string.format("%.1f, %.1f, %.1f", x, y or 0, z or 0)
            end
            local d2, d3 = "n/a", "n/a"
            if px and tx then
                local dx, dy = px - tx, py - ty
                d2 = string.format("%.2f yd", math.sqrt(dx * dx + dy * dy))
                local dz = (pz or 0) - (tz or 0)
                d3 = string.format("%.2f yd", math.sqrt(dx * dx + dy * dy + dz * dz))
            end
            local bucket = "n/a"
            if CheckInteractDistance then
                if CheckInteractDistance("target", 3) then bucket = "<=9.9yd"
                elseif CheckInteractDistance("target", 2) then bucket = "<=11.1yd"
                elseif CheckInteractDistance("target", 1) or CheckInteractDistance("target", 4) then
                    bucket = "<=28yd"
                else bucket = ">28yd" end
            end
            SendSystemMessage("|cff7ec8e3RaijinLab|r target GUID: " .. tostring(tg))
            SendSystemMessage("|cff7ec8e3RaijinLab|r player pos: " .. fmt(px, py, pz)
                .. "  raw=" .. tostring(rawP))
            SendSystemMessage("|cff7ec8e3RaijinLab|r target pos: " .. fmt(tx, ty, tz)
                .. "  raw=" .. tostring(rawT))
            SendSystemMessage("|cff7ec8e3RaijinLab|r 2D center: " .. d2
                .. "   3D: " .. d3 .. "   interact: " .. bucket)
            local pReach = RaijinLab.ObjectCombatReach and RaijinLab:ObjectCombatReach("player") or nil
            local tReach = RaijinLab.ObjectCombatReach and RaijinLab:ObjectCombatReach("target") or nil
            local pBound = RaijinLab.ObjectBoundingRadius and RaijinLab:ObjectBoundingRadius("player") or nil
            local tBound = RaijinLab.ObjectBoundingRadius and RaijinLab:ObjectBoundingRadius("target") or nil
            local function rr(v) return v and string.format("%.2f", v) or "nil" end
            SendSystemMessage("|cff7ec8e3RaijinLab|r combat reach: player=" .. rr(pReach)
                .. " target=" .. rr(tReach)
                .. "  |  bounding: player=" .. rr(pBound) .. " target=" .. rr(tBound))
            if RaijinLab.CombatDistance then
                local edge, ctr, pra, trb = RaijinLab:CombatDistance("player", "target")
                if ctr then
                    -- Self-AoE: pure center for normal models; giants extend only.
                    local aoe, _, ext = nil, nil, 0
                    if RaijinLab.AoEDistance then
                        aoe, _, ext = RaijinLab:AoEDistance("player", "target")
                    end
                    if not aoe then aoe = ctr end
                    SendSystemMessage(string.format(
                        "|cff55ff55RaijinLab|r combat EDGE (melee) = center-pCombat-tCombat: %.2f yd",
                        edge or -1))
                    SendSystemMessage(string.format(
                        "|cff7ec8e3RaijinLab|r center2d: %.2f   pCombat: %s   tCombat: %s",
                        ctr, rr(pra), rr(trb)))
                    SendSystemMessage(string.format(
                        "|cff7ec8e3RaijinLab|r AoE gap (WW) = %.2f yd  (center - giantExtend %.2f)  tBound=%s",
                        aoe, tonumber(ext) or 0, rr(tBound)))
                    local ww = (aoe <= 8.05) and "|cff55ff55WW IN|r" or "|cffff5555WW OOR|r"
                    SendSystemMessage("|cff7ec8e3RaijinLab|r Whirlwind (gap <= 8 center-based): " .. ww)
                end
            end
            local probe = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("PosProbe", tostring(tg))
            if probe then
                SendSystemMessage("|cff7ec8e3RaijinLab|r PosProbe: " .. tostring(probe))
            end
            if not px then
                SendSystemMessage("|cffff5555RaijinLab|r player pos nil - re-inject NEW runtime (tools\\inject.bat) in-world, then /reload")
            elseif not tx then
                SendSystemMessage("|cffffd200RaijinLab|r target pos nil - object ptr miss; try /raijin om")
            end
        end
    elseif cmd == "power" then
        -- Ground-truth dump of every power source so a custom resource
        -- (e.g. FelFury) can be pinned to its real mechanism. Set the resource
        -- to a KNOWN value first (e.g. FelFury at 3/6), run this, and look for
        -- where "3 / 6" shows up: a UnitPower[index] line = it's a power type;
        -- a "buff ... x3" line = it's an aura stack.
        SendSystemMessage("|cffffd200RaijinLab power dump|r  (set your custom resource to a KNOWN value first, e.g. 3/6)")
        if UnitPowerType then
            local pt, token = UnitPowerType("player")
            SendSystemMessage(string.format("  primary power type = %s (%s)", tostring(pt), tostring(token)))
        end
        if UnitPower and UnitPowerMax then
            local any = false
            for i = 0, 15 do
                local cur = UnitPower("player", i)
                local max = UnitPowerMax("player", i)
                if (cur and cur ~= 0) or (max and max ~= 0) then
                    any = true
                    SendSystemMessage(string.format("  UnitPower[%d] = %s / %s", i, tostring(cur), tostring(max)))
                end
            end
            if not any then
                SendSystemMessage("  (no non-zero UnitPower index 0-15)")
            end
        end
        if UnitBuff then
            SendSystemMessage("  player buffs (name xStacks):")
            local n = 0
            for i = 1, 40 do
                local nm, _, _, count = UnitBuff("player", i)
                if not nm then break end
                n = n + 1
                SendSystemMessage(string.format("    %s x%s", tostring(nm), tostring(count or 0)))
            end
            if n == 0 then SendSystemMessage("    (none)") end
        end
        -- What the rotation currently *reads* for FelFury, so we can compare.
        do
            local W = RaijinLab.World
            local ctx = W and W._last_ctx
            if ctx and ctx.power_amount_by_type then
                SendSystemMessage(string.format("  rotation sees felfury = %s / %s",
                    tostring(ctx.power_amount_by_type.felfury),
                    tostring(ctx.power_amount_max_by_type and ctx.power_amount_max_by_type.felfury)))
            else
                SendSystemMessage("  rotation context not built yet (start the rotation, then retry)")
            end
        end
    elseif cmd == "debug" then
        RaijinLab._debug_print = not RaijinLab._debug_print
        if RaijinLab.RotationExecutor then
            RaijinLab.RotationExecutor._debug = RaijinLab._debug_print
        end
        SendSystemMessage("|cff7ec8e3RaijinLab|r rotation/action debug prints: " .. tostring(RaijinLab._debug_print))
    elseif cmd == "quiet" or cmd == "verbose" then
        -- Toggle passive chatter (boot print, "menu opened", module traces).
        -- Explicit `on`/`off`/`true`/`false` arg overrides; no arg = toggle.
        local a = string.lower(args or "")
        if a == "on" or a == "true" or a == "1" then
            RaijinLab.chat_verbose = true
        elseif a == "off" or a == "false" or a == "0" then
            RaijinLab.chat_verbose = false
        elseif cmd == "quiet" and (a == "" or a == "toggle") then
            RaijinLab.chat_verbose = false
        elseif cmd == "verbose" and (a == "" or a == "toggle") then
            RaijinLab.chat_verbose = true
        else
            RaijinLab.chat_verbose = not RaijinLab.chat_verbose
        end
        RaijinLab:SetSystemVar("RaijinLab.chat_verbose", tostring(RaijinLab.chat_verbose))
        SendSystemMessage("|cff7ec8e3RaijinLab|r chat: " ..
            (RaijinLab.chat_verbose and "|cff55ff55verbose|r (passive chatter on)"
                                     or "|cffaaaaaaquiet|r (passive chatter suppressed)"))
    elseif cmd == "diag" then
        -- Comprehensive one-shot diagnostic - captures everything needed to
        -- debug "addon isn't detecting runtime even though it's injected".
        local out = { "|cffffd200RaijinLab|r diag:" }
        table.insert(out, "  addon v" .. tostring(RaijinLab.ADDON_VERSION or "?"))
        table.insert(out, "  IsLinuxClient       type=" .. type(IsLinuxClient))
        table.insert(out, "  RaijinLab_Runtime   type=" .. type(RaijinLab_Runtime))
        if type(IsLinuxClient) == "function" then
            local ok, ver = pcall(IsLinuxClient, "GetRuntimeVersion")
            table.insert(out, "  probe(GetRuntimeVersion)  ok=" .. tostring(ok) .. " ver=" .. tostring(ver))
            local ok2, ping = pcall(IsLinuxClient, "Ping")
            table.insert(out, "  probe(Ping)               ok=" .. tostring(ok2) .. " r=" .. tostring(ping))
        end
        table.insert(out, "  RaijinLab:HasRuntime()   = " .. tostring(RaijinLab:HasRuntime()))
        table.insert(out, "  RaijinLab:RuntimeVersion = " .. tostring(RaijinLab:RuntimeVersion()))
        if RaijinLab.RuntimeDetectDiag then
            table.insert(out, "  detect: " .. tostring(RaijinLab:RuntimeDetectDiag()))
        end
        local d = RaijinLab:RuntimeCall("DiagPlayer")
        table.insert(out, "  DiagPlayer               = " .. tostring(d))
        if RaijinLab.RotationExecutor and RaijinLab.RotationExecutor.status then
            table.insert(out, "  Executor: " .. RaijinLab.RotationExecutor.status())
        end
        for _, line in ipairs(out) do print(line) end
    elseif cmd == "save" then
        -- Force-flush active rotation + mirror character bucket to legacy backup.
        -- SavedVariables still only hit disk on clean exit /reload / char-select.
        local flushed = RaijinLab.FlushRotations and RaijinLab:FlushRotations() or false
        if RaijinLab.SyncActiveCharacterToLegacy then
            pcall(RaijinLab.SyncActiveCharacterToLegacy, RaijinLab)
        end
        pcall(function() if RaijinLab.SanitizeDB then RaijinLab:SanitizeDB() end end)
        local Ex = RaijinLab.RotationExecutor
        local names, active = {}, "?"
        if Ex and Ex.list_configs then names, active = Ex.list_configs() end
        local key = RaijinLab.CharacterKey and RaijinLab:CharacterKey() or "legacy"
        SendSystemMessage(string.format(
            "|cff7ec8e3RaijinLab|r save: ok=%s active=%s configs=%d char=%s ( /reload to disk )",
            tostring(flushed), tostring(active), #names, tostring(key)))
    elseif cmd == "configs" then
        -- Diagnostic: which character bucket, which active, which names exist.
        local Ex = RaijinLab.RotationExecutor
        local key = RaijinLab.CharacterKey and RaijinLab:CharacterKey() or "(no character yet)"
        local names, active = {}, "?"
        if Ex and Ex.list_configs then names, active = Ex.list_configs() end
        SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r configs for %s | active=%s",
            tostring(key), tostring(active)))
        if #names == 0 then
            SendSystemMessage("  (none)")
        else
            for i = 1, #names do
                local mark = (names[i] == active) and " *" or ""
                SendSystemMessage(string.format("  %d. %s%s", i, names[i], mark))
            end
        end
    elseif cmd == "memtop" then
        -- Per-addon Lua memory, sorted descending. Diagnoses "who's eating the heap?"
        -- when the 32-bit process hits its ~2 GB address-space wall (ERROR #134).
        if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
        local n = (GetNumAddOns and GetNumAddOns()) or 0
        local rows = {}
        for i = 1, n do
            local name = GetAddOnInfo and select(1, GetAddOnInfo(i)) or ("addon-" .. i)
            local kb   = (GetAddOnMemoryUsage and GetAddOnMemoryUsage(i)) or 0
            rows[#rows + 1] = { name = name, kb = kb }
        end
        table.sort(rows, function(a, b) return a.kb > b.kb end)
        local total = collectgarbage("count")
        print(string.format("|cffffd200RaijinLab memtop|r total Lua heap = %d KB  (top 15 addons)", math.floor(total)))
        for i = 1, math.min(15, #rows) do
            local r = rows[i]
            print(string.format("  %2d. %-32s %8d KB", i, r.name, math.floor(r.kb)))
        end
    elseif cmd == "gc" then
        local before = collectgarbage("count")
        collectgarbage("collect")
        local after = collectgarbage("count")
        SendSystemMessage(string.format("|cff7ec8e3RaijinLab|r gc: %d KB -> %d KB  (freed %d KB)",
            math.floor(before), math.floor(after), math.floor(before - after)))
    elseif cmd == "help" then
        SendSystemMessage("|cff7ec8e3RaijinLab|r commands:")
        SendSystemMessage("  |cffffcc00suite:    on | off  (master switch - off also releases movement)|r")
        SendSystemMessage("  |cffffcc00check:    self-diagnosis - which contracts are violated and why|r")
        SendSystemMessage("  |cffffcc00navgrid:  [verify] - extracted terrain vs the client's own raycasts|r")
        SendSystemMessage("  |cffffcc00show:     grid | path | search | target | controller | all | off|r")
        SendSystemMessage("  |cffffcc00ctl:      steering loop readout - heading, aim, cone, inputs|r")
        SendSystemMessage("  ui:       menu | status [ui] | diag | debug | quiet | verbose | help")
        SendSystemMessage("  memory:   memtop (per-addon KB, sorted) | gc (force collect)")
        SendSystemMessage("  save:     save (flush rotation to RaijinLabDB - /reload to commit to disk)")
        SendSystemMessage("  data:     save (commit rotation; /reload persists to disk)")
        SendSystemMessage("  rotation: rotation [start|stop|status|debug|cast <spellId>]")
        SendSystemMessage("  om:       om | nearby [range] | tracker | track <add|del> <id|name>")
        SendSystemMessage("  movement: mj | aa | fly | nc | gps")
        SendSystemMessage("  modules:  farm <name|stop> | grindwp | grindclear | travel <dest> | trace <start|stop>")
        SendSystemMessage("  slashes:  /raijin (canonical) | /raijinlab | /rlab | /rl (may be shadowed)")
    elseif cmd == "gps" then
        RaijinLab:GPS()
    else
        SendSystemMessage("|cff7ec8e3RaijinLab|r: unknown. /raijin help")
    end
end


-- Slash commands. NOTE: many Ascension/3.3.5 clients bind "/rl" as a built-in
-- (e.g. reload UI), which SHADOWS an addon's /rl so it silently never fires. So the
-- primary aliases are the guaranteed-unshadowed ones; /rl is kept last as a bonus.
-- Ascension's client binds "/rl" as a native /reload alias and prefix-matches it
-- greedily, so ANY slash starting with /rl (/rl, /rlm, /rlab) is intercepted BEFORE
-- addon slash handlers see it. Aliases below deliberately avoid the /rl prefix.
-- /rj is deliberately NOT registered: it prefix-eats /rjm in WoW's slash matcher
-- (same shape of bug as Ascension's /rl eating /rlm).
SLASH_RAIJINLAB1 = "/raijin"
SLASH_RAIJINLAB2 = "/raijinlab"
SlashCmdList["RAIJINLAB"] = function(msg)
    RaijinLab:RunCommand(msg or "")
end

-- Localized names for the key-binding UI (so it shows friendly text, not raw IDs).
BINDING_HEADER_RAIJINLAB             = "RaijinLab"
BINDING_NAME_RAIJINLAB_TOGGLE_MENU   = "Toggle RaijinLab menu"
BINDING_NAME_RAIJINLAB_TOGGLE_ROTATION = "Toggle rotation module"

-- Global entry point for macros and key-bindings. Bindings.xml calls this.
function RaijinLab_ToggleMenu()
    if RaijinLab and RaijinLab.Menu and RaijinLab.Menu.Toggle then
        RaijinLab.Menu:Toggle()
    else
        print("|cffff5555RaijinLab:|r menu module not loaded yet.")
    end
end

-- Toggle ONLY the rotation module (Home tab selection + start/stop if suite on).
-- Bind in Esc -> Key Bindings -> RaijinLab -> "Toggle rotation module".
function RaijinLab_ToggleRotation()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    local on = not RaijinLabDB.modules.rotation
    RaijinLabDB.modules.rotation = on
    if RaijinLab and RaijinLab.Menu and RaijinLab.Menu.ApplyModuleState then
        pcall(function() RaijinLab.Menu:ApplyModuleState("rotation") end)
    elseif RaijinLab and RaijinLab.RotationExecutor then
        -- Suite off: arm only (ApplyModuleState no-ops start when suppressed).
        -- Suite on: start/stop rotation ticker.
        local suppressed = RaijinLab.Master and RaijinLab.Master.suppressed
            and RaijinLab.Master.suppressed()
        if not suppressed then
            if on then
                pcall(RaijinLab.RotationExecutor.start)
            else
                pcall(RaijinLab.RotationExecutor.stop)
            end
        end
    end
    -- Keep rotation_enabled in sync when suite is running.
    if RaijinLab.Master and not (RaijinLab.Master.suppressed and RaijinLab.Master.suppressed()) then
        RaijinLabDB.rotation_enabled = on and true or false
    end
    if print then
        print("|cff7ec8e3RaijinLab|r rotation module "
            .. (on and "|cff10ff10ON|r" or "|cffff5555OFF|r")
            .. "  (bind: Esc->Key Bindings->RaijinLab)")
    end
    if RaijinLab and RaijinLab.Menu and RaijinLab.Menu.RefreshHome then
        pcall(function() RaijinLab.Menu:RefreshHome() end)
    end
end

SLASH_RAIJINMENU1 = "/rjm"
SLASH_RAIJINMENU2 = "/rmenu"
SlashCmdList["RAIJINMENU"] = function() RaijinLab_ToggleMenu() end

SLASH_RAIJINROT1 = "/rjrot"
SlashCmdList["RAIJINROT"] = function() RaijinLab_ToggleRotation() end

local function RL_ForceMenuHash()
    if hash_SlashCmdList then
        hash_SlashCmdList["/RJM"]   = SlashCmdList["RAIJINMENU"]
        hash_SlashCmdList["/RMENU"] = SlashCmdList["RAIJINMENU"]
    end
end
RL_ForceMenuHash()

local rf = CreateFrame("Frame")
rf:RegisterEvent("PLAYER_LOGIN")
rf:RegisterEvent("PLAYER_ENTERING_WORLD")
rf:SetScript("OnEvent", RL_ForceMenuHash)

-- Hidden button for macros: "/click RaijinLabMenuButton".
-- MUST NOT use SecureActionButtonTemplate - that taints secure paths and
-- produces "RaijinLab tainted the call of UNKNOWN()" on Ascension.
local menuBtn = CreateFrame("Button", "RaijinLabMenuButton", UIParent)
menuBtn:SetScript("OnClick", function()
    if type(RaijinLab_ToggleMenu) == "function" then
        pcall(RaijinLab_ToggleMenu)
    end
end)
menuBtn:Hide()

-- (REMOVED) Periodic collectgarbage("collect") OnUpdate ticker.
-- Rationale: forcing a full GC from within the render tick can fire a userdata
-- __gc metamethod that invalidates a native pointer some other addon (or our
-- own runtime bridge) still holds. Observed crash: EIP jumped to a heap
-- address containing garbage (0x3C34E810 with byte pattern `63 62 18 23`),
-- classic corrupted-callback-pointer signature reached via Extensions.dll AC
-- callback dispatch. Manual GC is still available via `/raijin gc`.

-- Boot-time confirmation, gated by RaijinLab.chat_verbose (SavedVar, default OFF).
-- Toggle via `/raijin quiet` (on/off/toggle). Suppressed by default so /reload isn't
-- noisy - a broken registration is still diagnosable by trying a slash.
-- pcall-wrap so a missing Chatter (should not happen, API.lua loads first) can't
-- throw during addon load and cascade into WoW's ErrorHandler traceback machinery.
pcall(function()
    if RaijinLab and RaijinLab.Chatter then
        RaijinLab:Chatter("|cff7ec8e3Raijin|r|cffffffffLab|r slash: /raijin /raijinlab  |  menu: /rjm /rmenu  |  macro: /click RaijinLabMenuButton  or  /run RaijinLab_ToggleMenu()")
    end
end)

-- Visible confirmation that this command handler registered (so a silent /rl is
-- immediately diagnosable: if you see this line, use /raijin - /rl is shadowed).
-- No boot print (chat spam is visible to anyone watching / can be logged).
