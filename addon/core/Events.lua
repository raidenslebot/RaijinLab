function RaijinLab:CoreOnUpdate(elapsed)
    if not self.last_time then
        self.last_time = 0
    end
    self.last_time = self.last_time + elapsed
    if not RaijinLab:HasRuntime() then
        return
    end
    if RaijinLab.anti_afk then
        if (self.last_time > math.random(240, 420)) then
            RaijinLab.ResetAfk()
            self.last_time = 0
        end
    end
    -- Do NOT SetCVar("AutoInteract") here - that taints and pops
    -- "RaijinLab has been blocked from an action only available to the Blizzard UI".
end

-- EVERYTHING OFF, IN THE RIGHT ORDER, BEFORE THE CLIENT TEARS DOWN.
--
-- Order matters and is deliberate:
--   1. release held INPUT first - a held MoveForward/turn/pitch key surviving
--      into logout is the one thing that can still move the character while its
--      own systems are being freed.
--   2. stop the tickers that touch the world (navigator, instrument, drawing,
--      scheduler) so nothing walks the object manager mid-teardown.
--   3. tell the runtime to stop enumerating the OM.
--   4. only THEN flush to disk.
--
-- Every step is pcall'd individually: a halt that aborts halfway is worse than
-- no halt, because it leaves exactly the subsystem that errored still running.
function RaijinLab.HaltAll(why)
    local function try(f, ...) if f then pcall(f, ...) end end

    -- 1. inputs
    local N = RaijinLab.Navigator
    if N then
        try(N.stop)
        try(N.release_all)          -- may not exist on older builds; try() is safe
        try(N._stop_ticker)
    end
    local A = RaijinLab.Actions
    if A then
        try(A.MoveForward, false); try(A.MoveBackward, false)
        try(A.StrafeLeft, false);  try(A.StrafeRight, false)
        try(A.TurnLeft, false);    try(A.TurnRight, false)
        try(A.Ascend, false);      try(A.Descend, false)
        try(A.PitchUp, false);     try(A.PitchDown, false)
        try(A.StopMoving)
    end

    -- 2. tickers and background work
    local M = RaijinLab.Master
    if M and M.stop_all then try(M.stop_all, "logout") end
    if RaijinLab._instr_t and RaijinLab._instr_t.Cancel then
        try(function() RaijinLab._instr_t:Cancel() end)
        RaijinLab._instr_t = nil
    end
    try(RaijinLab.DestroyDrawing, RaijinLab)
    local S = RaijinLab.Scheduler
    if S then try(S.clear); try(S.stop) end

    -- 3. the runtime must stop reading the object manager
    if RaijinLab.RuntimeCall then
        try(RaijinLab.RuntimeCall, RaijinLab, "SetSystemVar", "om.enable", "0")
    end

    local DL = RaijinLab.DevLog
    if DL and DL.log then try(DL.log, "boot", "halted (" .. tostring(why or "?") .. ")") end
end

local variables_loaded = false
function RaijinLab:CoreOnEvent(event, ...)
    if event == "PLAYER_LOGOUT" then
        -- STOP FIRST, THEN FLUSH. This used to flush while every ticker was
        -- still running and the runtime was still enumerating the object
        -- manager, straight through the client's own teardown.
        RaijinLab.HaltAll("logout")
        -- Last chance before WoW writes SavedVariables to disk. Flush the active
        -- rotation and sanitize the DB so the write can't be poisoned.
        if RaijinLab.DevLog then RaijinLab.DevLog.log("boot", "logout"); RaijinLab.DevLog.flush() end
        -- Bound the world map before it serializes (evict low-traffic chunks).
        if RaijinLab.WorldMesh and RaijinLab.WorldMesh.evict then pcall(RaijinLab.WorldMesh.evict) end
        -- Drop traversability cells that have decayed to irrelevance so the field
        -- stays small on disk (roads survive; a cleared camp does not).
        if RaijinLab.Traversability and RaijinLab.Traversability.prune then
            pcall(RaijinLab.Traversability.prune)
        end
        -- Keep every zone we solved: each one is solved ONCE, ever.
        if RaijinLab.QuestDB and RaijinLab.QuestDB.save then
            pcall(RaijinLab.QuestDB.save)
        end
        if RaijinLab.ConfigBackup then pcall(RaijinLab.ConfigBackup.save, true) end
        if RaijinLab.OnLogout then RaijinLab:OnLogout() end
        return
    end
    if event == "PLAYER_LEAVING_WORLD" then
        -- /reload or logout: block OM arm until next PEW.
        RaijinLab._world_entered = false
        RaijinLab._leaving_world = true
        -- Also a teardown: /reload and character-select free the object manager
        -- the same way. Cheap to repeat, and the modules re-arm on world entry.
        RaijinLab.HaltAll("leaving_world")
        -- Belt-and-suspenders flush. Fires on /reload and on transitions out of
        -- the world (character-select, exit), catching paths where PLAYER_LOGOUT
        -- might be skipped. Safe to run repeatedly.
        -- Light flush only: a loading screen is not a logout, and the full
        -- sanitize would deep-copy (and re-identify) every persisted table.
        if RaijinLab.OnZoneOut then pcall(RaijinLab.OnZoneOut, RaijinLab)
        elseif RaijinLab.OnLogout then pcall(RaijinLab.OnLogout, RaijinLab) end
        -- Do NOT return - the tick loop may want other subsystems to see it too.
    end
    if event == "VARIABLES_LOADED" then
        -- SavedVariables are only written on a CLEAN logout, so a crash or a
        -- force-kill silently loses everything since login. Check for that first
        -- and refill anything missing from our own crash-independent backup,
        -- BEFORE migration or any reader touches the config.
        if RaijinLab.ConfigBackup then pcall(RaijinLab.ConfigBackup.on_load) end
        -- Migrate + version the DB before anything reads it.
        if RaijinLab.InitPersistence then RaijinLab:InitPersistence() end
        -- Restore zone transforms before anything asks for coordinates:
        -- a zone solved in an earlier session is usable immediately, so
        -- the bot can travel INTO a zone it has never walked.
        if RaijinLab.QuestDB and RaijinLab.QuestDB.load then
            pcall(RaijinLab.QuestDB.load)
        end
        -- Keep RaijinLabDB continuously current, so a crash costs at most a few
        -- seconds of editing instead of the whole session.
        if RaijinLab.StartAutoCommit then pcall(RaijinLab.StartAutoCommit, RaijinLab) end
        RaijinLab:Init()
        if RaijinLab:HasRuntime() then
            RaijinLab.multijump_toggle = RaijinLab:GetSystemVar("RaijinLab.multijump_toggle") == "true"
            RaijinLab.anti_afk = RaijinLab:GetSystemVar("RaijinLab.anti_afk") == "true"
            RaijinLab.fly_toggle = RaijinLab:GetSystemVar("RaijinLab.fly_toggle") == "true"
            RaijinLab.tracker_toggle = RaijinLab:GetSystemVar("RaijinLab.tracker_toggle") == "true"
            RaijinLab.chat_verbose = RaijinLab:GetSystemVar("RaijinLab.chat_verbose") == "true"
            -- Object manager: PEW arm (Runtime.ArmRuntimeSystems) turns om.enable on
            -- and starts the OnUpdate frame. Tracker drawing is still opt-in.
            -- THE OBJECT MANAGER IS STARTED BY ArmRuntimeSystems, NOT HERE.
            --
            -- I previously moved InitObjectManager() out of the tracker_toggle
            -- block to here, on the theory that a debug DRAWING toggle was the
            -- only thing starting it. That was WRONG: Runtime.lua
            -- ArmRuntimeSystems() already starts it, correctly gated on
            -- HasRuntime() AND UnitName("player") - i.e. runtime up and in world.
            --
            -- Starting it here bypassed both gates and ran at VARIABLES_LOADED:
            -- before the bridge registers, and before world entry - the exact
            -- condition recorded as causing the world-load access violation
            -- (#132). Worse, this call was not pcall'd, so a throw here skipped
            -- `variables_loaded = true` and the remainder of init, which presents
            -- as "the runtime is not being detected".
            --
            -- Leave the start where its preconditions are actually checked.
            if RaijinLab.tracker_toggle then
                RaijinLab:AddDrawingCallback("objectTracker", RaijinLab.DrawTrackedObjects)
                RaijinLab:InitTrackerModule()
            end
            -- Do NOT auto EnableFlyingMode on load (secure/taint + unexpected behavior)
        end
        variables_loaded = true
    end
    if not variables_loaded then return end
    -- Real achievements reset the watchdog's stall timer. These are the events
    -- that unambiguously mean the run is going somewhere.
    if event == "QUEST_TURNED_IN" or event == "PLAYER_LEVEL_UP"
        or event == "LOOT_OPENED" or event == "QUEST_ACCEPTED" then
        if RaijinLab.Watchdog then RaijinLab.Watchdog.note(event) end
        -- Persistent Fail records (e.g. no riding skill) reconsider on progress events.
        if RaijinLab.Fail and RaijinLab.Fail.on_event then pcall(RaijinLab.Fail.on_event, event) end
        -- fall through: other handlers may also want these
    end
    if event == "TRAINER_SHOW" then
        if RaijinLab.Fail and RaijinLab.Fail.on_event then pcall(RaijinLab.Fail.on_event, event) end
        -- Remember the trainer, and learn everything affordable. New ranks are the
        -- real fix for the rotation casting rank 1 forever.
        local P = RaijinLab.POI
        if P and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition("player")
            if x then
                P.record("trainer", { x = x, y = y, z = z,
                    name = (GetUnitName and GetUnitName("npc")) or "Trainer" })
            end
        end
        if RaijinLab.Trainer then
            local ok, n, spent = pcall(RaijinLab.Trainer.train_all)
            pcall(RaijinLab.Trainer.note_visit)
            if ok and (n or 0) > 0 and RaijinLab.DevLog then
                RaijinLab.DevLog.log("trainer", "learned %d services for %s copper", n, tostring(spent))
            end
        end
        return
    end
    if event == "CONFIRM_XP_LOSS" then
        if RaijinLab.Death and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition("player")
            if x then pcall(RaijinLab.Death.note_spirit_healer, x, y, z) end
        end
        return
    end
    if event == "PLAYER_DEAD" then
        if RaijinLab.Death then pcall(RaijinLab.Death.note_death) end
        return
    end
    if event == "MERCHANT_SHOW" then
        -- Remember this merchant (and whether it repairs) so "go sell" can resolve
        -- to a real place later, then do the whole visit in one go.
        local P = RaijinLab.POI
        if P and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition("player")
            if x then
                local nm = (GetUnitName and GetUnitName("npc")) or "Merchant"
                P.record("vendor", { x = x, y = y, z = z, name = nm })
                if CanMerchantRepair and CanMerchantRepair() then
                    P.record("repair", { x = x, y = y, z = z, name = nm })
                end
            end
        end
        if RaijinLab.Vendor and RaijinLabDB and RaijinLabDB.modules
            and RaijinLabDB.modules.quest then
            local ok, msg = pcall(RaijinLab.Vendor.do_business)
            if ok and msg and RaijinLab.DevLog then RaijinLab.DevLog.log("vendor", "%s", msg) end
        end
        return
    end
    if event == "TAXIMAP_OPENED" then
        -- We are standing at a flight master: this is the one moment the client
        -- will tell us the whole taxi map for this character. Learn it, and
        -- remember this spot so we can come back and fly from here later.
        if RaijinLab.TravelNet then
            pcall(RaijinLab.TravelNet.learn_taxi_map)
            local P = RaijinLab.POI
            if P and RaijinLab.ObjectPosition then
                local x, y, z = RaijinLab:ObjectPosition("player")
                if x then
                    P.record("flightmaster", { x = x, y = y, z = z,
                        name = (GetUnitName and GetUnitName("npc")) or "Flight Master" })
                end
            end
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- A map change right after boarding a boat/zeppelin/portal tells us where
        -- that transit actually leads - the only way to learn it, since no API
        -- enumerates them.
        if RaijinLab.TravelNet and RaijinLab.ObjectPosition then
            local x, y, z = RaijinLab:ObjectPosition("player")
            if x then pcall(RaijinLab.TravelNet.note_transit_arrive, x, y, z) end
        end
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- CharacterKey() is only addressable once the world is loaded - this
        -- is the first event where UnitName/GetRealmName are guaranteed to
        -- return real values. Copy any pre-v3 top-level rotations into this
        -- character's bucket exactly once. Cheap no-op on subsequent enters.
        if RaijinLab.MigrateLegacyRotationsToCharacter then
            pcall(RaijinLab.MigrateLegacyRotationsToCharacter, RaijinLab)
        end
        -- Drop any rotation cache loaded under the legacy (pre-character) path
        -- so the next tick/editor open reloads from this character's bucket.
        if RaijinLab.RotationExecutor then
            RaijinLab.RotationExecutor._active_cache = nil
            RaijinLab.RotationExecutor._active_name = nil
        end
        -- Attach the minimap button once the world (and therefore the
        -- Minimap frame) is guaranteed to exist. Safe on subsequent enters:
        -- Init() no-ops after the first call.
        if RaijinLab.MinimapIcon and RaijinLab.MinimapIcon.Init then
            pcall(RaijinLab.MinimapIcon.Init, RaijinLab.MinimapIcon)
        end
        -- Mark world entered so should_arm may proceed (blocks arm mid-/reload).
        if RaijinLab then
            RaijinLab._world_entered = true
            RaijinLab._leaving_world = false
            -- /reload wipes _runtime_armed; allow one-shot arm again.
            RaijinLab._runtime_armed = false
        end
        -- Arm once when bridge+player exist. Idempotent after set.
        if RaijinLab:HasRuntime() and RaijinLab.ArmRuntimeSystems then
            pcall(function() RaijinLab:ArmRuntimeSystems() end)
        end
        if RaijinLab:HasRuntime() and RaijinLabDB.track_quest_objects then
            RaijinLab:EnableQuestTracker()
            if RaijinLab.AddTrackedAchievementItems then
                RaijinLab:AddTrackedAchievementItems()
            end
        end
        -- Resume the rotation if it was enabled before this /reload or relog. The
        -- persisted flag (RaijinLabDB.rotation_enabled) survives, but the OnUpdate
        -- ticker frame does NOT - so without this the UI reads "enabled" while
        -- nothing actually runs, and the user has to toggle off/on to really start
        -- it. Deferred like the arm above so we never spin the ticker up
        -- mid-load-screen; Executor.tick self-guards on no-runtime / no-target and
        -- start() is idempotent (stop-then-start). The `not _frame` guard makes
        -- this a no-op when the ticker is already alive (e.g. a plain zone change,
        -- which keeps Lua state), so it only ever restarts after a real reset.
        if RaijinLabDB.rotation_enabled and RaijinLab.RotationExecutor then
            local Ex = RaijinLab.RotationExecutor
            local function resume_rotation()
                -- Never spin rotation mid-load: wait for runtime bridge too.
                if not (RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then
                    return
                end
                if RaijinLabDB and RaijinLabDB.rotation_enabled and not Ex._frame then
                    Ex.start()
                end
            end
            if C_Timer and C_Timer.After then
                -- 8s after PEW: past OM soft-arm settle; never 3s (load crash).
                C_Timer.After(8.0, resume_rotation)
            else
                resume_rotation()
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        RaijinLab.force_update = true
    elseif event == "CRITERIA_UPDATE" and RaijinLabDB.track_quest_objects then
        if RaijinLab.AddTrackedAchievementItems then
            C_Timer.After(1, function() RaijinLab:AddTrackedAchievementItems() end)
        end
    elseif event == "TRACKED_ACHIEVEMENT_UPDATE" and RaijinLabDB.track_quest_objects then
        if RaijinLab.AddTrackedAchievementItems then
            C_Timer.After(1, function() RaijinLab:AddTrackedAchievementItems() end)
        end
    elseif event == "QUEST_WATCH_UPDATE" or event == "QUEST_LOG_UPDATE" then
        if RaijinLab.quests then
            RaijinLab.quests.wipe_quest_object_cache = true
        end
    end
end

function RaijinLab:Init()
    RaijinLab:PrintBanner()
    -- Development logging to <WoW>/Logs/raijinlab_dev.log + 1Hz state snapshots,
    -- so a whole session can be reviewed from disk while building nav/quest.
    if RaijinLab.DevLog and RaijinLab.DevLog.start then RaijinLab.DevLog.start() end
    -- Full-state snapshots once a second, so a whole unattended session can be
    -- reconstructed from disk afterwards rather than guessed at.
    if RaijinLab.Snapshot and RaijinLab.Snapshot.start then pcall(RaijinLab.Snapshot.start) end
    -- Periodic config backup: the only protection against an unclean shutdown.
    if RaijinLab.ConfigBackup and RaijinLab.ConfigBackup.start then pcall(RaijinLab.ConfigBackup.start) end
    -- Self-checking. Installed AFTER every subsystem exists so the contracts can
    -- resolve them, and started last so a violation cannot fire during boot.
    if RaijinLab.Contracts and RaijinLab.Contracts.install then pcall(RaijinLab.Contracts.install) end
    if RaijinLab.Contract and RaijinLab.Contract.start then pcall(RaijinLab.Contract.start) end
    -- Capability registry: probe once at boot so workarounds branch on truth.
    if RaijinLab.Caps and RaijinLab.Caps.refresh then pcall(RaijinLab.Caps.refresh) end
    -- Session replay ring (1Hz samples) for offline "what did it know" questions.
    if RaijinLab.Replay and RaijinLab.Replay.start then pcall(RaijinLab.Replay.start) end
    -- Re-arm any visualisation layers the user left on across a reload.
    if RaijinLab.Vision and RaijinLab.Vision.refresh then pcall(RaijinLab.Vision.refresh) end
    -- Capture Lua errors into the SAME stream. An error that only ever reached
    -- the client's error frame is invisible to anyone reading logs afterwards.
    if not RaijinLab._errhook_installed then
        RaijinLab._errhook_installed = true
        local prev = geterrorhandler and geterrorhandler()
        if seterrorhandler then
            seterrorhandler(function(err)
                local Tel = RaijinLab and RaijinLab.Telemetry
                if Tel then Tel.err("lua", "error", { msg = tostring(err) }) end
                if prev then return prev(err) end
            end)
        end
    end
    if RaijinLab.StartInstrumentation then RaijinLab:StartInstrumentation() end
    -- Start the frame-budget scheduler: the backbone that spreads heavy work
    -- (pathfinding, raycast sweeps, analysis) across frames so the whole suite
    -- runs with no frame hitches. Cheap when idle (empty budget loop).
    if RaijinLab.Scheduler and RaijinLab.Scheduler.start then RaijinLab.Scheduler.start() end
    -- New world-map session (for decay/heal), then start the ambient Surveyor so the
    -- surroundings are mapped continuously - it should know its environment before it
    -- ever needs to move (so it routes around walls, not into them).
    -- Highest-known-rank resolver: register for spell-change events so a rank-up
    -- (e.g. after auto-training) is picked up live and the rotation casts max rank.
    if RaijinLab.RankResolver and RaijinLab.RankResolver.init then pcall(RaijinLab.RankResolver.init) end
    if RaijinLab.WorldMesh and RaijinLab.WorldMesh.new_session then pcall(RaijinLab.WorldMesh.new_session) end
    -- Surveyor only when travel modules are armed (raycast fan is top idle FPS cost).
    -- Master.start_all re-arms; stop_all tears down; tick also self-gates.
    if RaijinLab.Surveyor and RaijinLab.Surveyor.needed and RaijinLab.Surveyor.needed() then
        if RaijinLab.Surveyor.start then pcall(RaijinLab.Surveyor.start) end
    end
    -- Real DLL is detected asynchronously (stock IsLinuxClient is a fake).
    -- PEW path above calls ArmRuntimeSystems -> om.enable=1 + InitObjectManager.
    if RaijinLab.InitDrawing then RaijinLab:InitDrawing() end
end
