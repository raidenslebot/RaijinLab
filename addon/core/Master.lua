-- Master - one switch that owns the whole suite.
--
-- Before this, the only way to stop the bot was to un-toggle each module in turn,
-- and there was no single answer to "is anything running right now?". That matters
-- most in the moment you actually want it: something is going wrong, and you need
-- EVERYTHING to stop, now, with one click - not five clicks while the character
-- keeps running.
--
-- Two things make this a real kill switch rather than a convenience:
--
--   1. It is a GATE, not just a stop() sweep. Every module ticker asks
--      Master.enabled() before doing anything. Calling stop() alone is not enough,
--      because a module that gets re-armed by an event, a timer that already fired,
--      or a Director goal mid-flight would quietly come back to life. While the
--      master is off, the answer is no regardless of who asks or why.
--
--   2. It HALTS MOVEMENT. Turning the brain off while the legs are still running
--      leaves the character sprinting into a wall (or off a cliff) with nothing
--      left to steer it. Off means the keys are released, in the same call.
--
-- THE MODEL - two different kinds of control, never blurred:
--   * Module toggles are SELECTION: "this module is part of the suite". Toggling
--     one never starts or stops the suite. While the master is off, enabling a
--     module just ARMS it.
--   * The master button is the only RUN/STOP control. ON runs whatever is armed;
--     OFF halts everything but leaves the selection exactly as it was. No saved
--     set, no auto-raise, no surprises: the switch never changes your choices,
--     and your choices never flip the switch.
--
-- The rotation executor is part of the suite and follows the master switch, and it
-- also keeps its own independent toggle for when you want to hand-fly with the
-- rotation still firing.

local M = {}

-- Ordered so that starting goes brain-last: services and the rotation come up
-- before anything that can decide to walk somewhere.
M.MODULES = { "rotation", "combat", "gather", "quest", "grind" }

-- WHAT EACH MODULE NEEDS TO ACTUALLY WORK.
--
-- Turning on the quester and watching it stand still because the rotation was off
-- is not a configuration choice the user made - it is a trap. A module that
-- cannot function without another is not "compatible" with it, it DEPENDS on it,
-- and the switch should say so by turning it on.
--
-- Deliberately one level deep and explicit rather than a general graph: there are
-- five modules, the relationships are known, and a resolver would be more code
-- than the thing it resolves. Navigation is not listed because it is not a module
-- - it is a shared service that is always available.
M.REQUIRES = {
    quest = { "rotation", "combat" },   -- travel + fight + loot the objective
    grind = { "rotation", "combat" },   -- a grinder that cannot fight is a walker
    gather = {},                        -- opportunistic; needs nothing else
    combat = { "rotation" },            -- a combat brain with no rotation casts nothing
    rotation = {},
}

-- Everything `key` needs, transitively, that is not already on.
function M.missing_deps(key)
    -- Reads RaijinLabDB directly rather than via the db() local: this sits above
    -- that definition in the file, and depending on declaration order is how a
    -- helper works in one call path and is nil in another.
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    local d = RaijinLabDB
    local out, seen = {}, {}
    local function walk(k)
        for _, dep in ipairs(M.REQUIRES[k] or {}) do
            if not seen[dep] then
                seen[dep] = true
                if not d.modules[dep] then out[#out + 1] = dep end
                walk(dep)
            end
        end
    end
    walk(key)
    return out
end

-- Rotation follows the master switch even if it was off when the suite was
-- stopped: "the main button turns the rotation on too".
M.ALWAYS_ON = { rotation = true }

local function TT() return RaijinLab and RaijinLab.Telemetry end

local function db()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    return RaijinLabDB
end

-- ---- the gate --------------------------------------------------------------

-- Default ON. A fresh install has every module off anyway, so defaulting the
-- master to off would mean a new user toggles "gather", sees nothing happen, and
-- has no way to know why. Off is a deliberate act.
function M.enabled()
    local d = db()
    return d.master ~= false
end

-- The single line every ticker uses: `if RaijinLab.Master and RaijinLab.Master.suppressed() then return end`
-- True when native/Lua OM heavy paths are safe after suite-on (not mid-arm).
-- Modules that would call NearbyHostiles / full object walks must gate on this.
function M.suite_om_safe()
    if not M.enabled or not M.enabled() then return false end
    local t0 = M._suite_on_t
    if not t0 then return true end
    local now = (GetTime and GetTime()) or 0
    -- Match Master.start_all stagger: native OM at 4s, Lua frame at 5.5s.
    return (now - t0) >= 5.5
end

function M.suppressed()
    return not M.enabled()
end

-- ---- module plumbing -------------------------------------------------------

-- Resolve a module key to its live object. Kept in one place so the master and
-- the menu can never disagree about what "quest" means.
function M.impl(key)
    local R = RaijinLab
    if not R then return nil end
    if key == "rotation" then return R.RotationExecutor end
    if key == "combat"   then return R.CombatBrain end
    if key == "gather"   then return R.Gatherer end
    if key == "quest"    then return R.QuestSuite end
    if key == "grind"    then return R.Grinder end
    return nil
end

function M.start_module(key)
    local o = M.impl(key)
    if o and o.start then pcall(o.start) ; return true end
    return false
end

function M.stop_module(key)
    local o = M.impl(key)
    if o and o.stop then pcall(o.stop) ; return true end
    return false
end

-- Which modules are SELECTED, regardless of whether the suite is running. This
-- is exactly what ON will start.
function M.armed()
    local d = db()
    local list = {}
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then list[#list + 1] = k end
    end
    return list
end

-- Which modules are actually running right now?
function M.active()
    if not M.enabled() then return {} end
    return M.armed()
end

-- ---- stopping the legs -----------------------------------------------------

-- Release every movement input. Ordered widest-to-narrowest so that even if one
-- layer is missing (runtime not injected, Navigator not loaded) the others still
-- land. Each is pcall'd: a kill switch that can itself throw is not a kill switch.
function M.halt_movement()
    local R = RaijinLab
    if not R then return end
    if R.Navigator and R.Navigator.stop then pcall(R.Navigator.stop) end
    if R.Nav and R.Nav.cancel then pcall(R.Nav.cancel) end
    local A = R.Actions
    if A then
        -- Explicitly release each key as well as StopMoving: a held key survives
        -- StopMoving on this client, which is exactly how a "stopped" bot keeps
        -- walking. These take a boolean (false = release), NOT a *Stop name.
        for _, fn in ipairs({ "MoveForward", "StrafeLeft", "StrafeRight",
                              "TurnLeft", "TurnRight" }) do
            if A[fn] then pcall(A[fn], false) end
        end
        -- Mouselook is a held state of its own; leaving it engaged keeps the
        -- camera driving the character's yaw after everything else has let go.
        if A.MouselookStop then pcall(A.MouselookStop) end
        if A.StopMoving then pcall(A.StopMoving) end
        if A.CommitMovement then pcall(A.CommitMovement) end
    end
end

-- ---- the switch ------------------------------------------------------------

-- Turn the whole suite off. Module flags are the user's SELECTION and are left
-- exactly as they are - OFF stops things from running, it does not un-choose
-- them.
function M.stop_all(reason)
    local d = db()
    local was = {}
    for _, k in ipairs(M.MODULES) do
        was[k] = d.modules[k] and true or false
    end
    d.master = false
    for _, k in ipairs(M.MODULES) do
        M.stop_module(k)
    end
    -- The modules' own stop() clears their flag as a side effect (it doubles as
    -- their run flag), which would silently erase the selection. Put it back:
    -- the flags belong to the user, not to the lifecycle.
    for _, k in ipairs(M.MODULES) do
        d.modules[k] = was[k]
    end
    M.halt_movement()
    -- Idle perf: stop ambient raycast surveying while nothing is running.
    -- Surveyor.tick also self-gates; this drops the OnUpdate entirely.
    local R = RaijinLab
    if R and R.Surveyor and R.Surveyor.stop then pcall(R.Surveyor.stop) end

    local Tel = TT()
    if Tel then Tel.warn("master", "off", { reason = reason or "user" }) end
    -- Always print so "everything randomly stopped" is attributable.
    local armed = {}
    for _, k in ipairs(M.MODULES) do if was[k] then armed[#armed + 1] = k end end
    print(string.format("|cffffd200RaijinLab master OFF|r reason=%s  was={%s}",
        tostring(reason or "user"), table.concat(armed, ",")))
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then
        DL.log("master", "OFF reason=%s was=%s",
            tostring(reason or "user"), table.concat(armed, ","))
        if DL.flush then pcall(DL.flush) end
    end
    return was
end

-- Turn the suite on: run exactly what is armed. Nothing is guessed and nothing
-- is remembered - the module flags ARE the truth.
function M.start_all(reason)
    local d = db()
    d.master = true
    M._off_armed_t = nil
    M.clear_ui_focus()
    -- Crash-hardening clock: Lua modules fail-closed on heavy OM until this
    -- window passes (see World.suite_om_safe / collect_nearby_enemies).
    M._suite_on_t = (GetTime and GetTime()) or 0

    -- ================================================================
    -- CRASH LESSON (permanent): suite-on the same frame as OM walk/enum
    -- after login hard-crashes the client. Sequence must be:
    --   0.0s  freeze OM (om.enable=0), start lightweight modules only
    --   4.0s  re-enable om.enable (native list-only warm-up begins)
    --   5.5s  start Lua OM OnUpdate (GetUnitCount fan)
    --   8.0s  Surveyor raycast fan
    -- Single-GUID casts / current-target rotation work the whole time.
    -- ================================================================
    local R = RaijinLab
    pcall(function()
        if RaijinLab.RuntimeCall then
            RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "0")
        end
        -- Tear down Lua OM frame if it was already running from PEW arm —
        -- re-creating it mid-suite-on was a concurrent crash source.
        if RaijinLab.DestroyObjectManager then
            pcall(RaijinLab.DestroyObjectManager, RaijinLab)
        end
    end)

    local function arm_om_native()
        if not (RaijinLab and RaijinLab.Master and RaijinLab.Master.enabled
            and RaijinLab.Master.enabled()) then return end
        pcall(function()
            if RaijinLab.ArmRuntimeSystems then
                -- May already be armed from PEW; idempotent.
                RaijinLab:ArmRuntimeSystems()
            end
            if RaijinLab.RuntimeCall then
                RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1")
            end
        end)
    end
    local function arm_om_lua_frame()
        if not (RaijinLab and RaijinLab.Master and RaijinLab.Master.enabled
            and RaijinLab.Master.enabled()) then return end
        pcall(function()
            if RaijinLab.InitObjectManager and RaijinLab.GetObjManagerFrame
                and not RaijinLab:GetObjManagerFrame() then
                RaijinLab:InitObjectManager()
            end
        end)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(4.0, arm_om_native)
        C_Timer.After(5.5, arm_om_lua_frame)
    else
        arm_om_native()
        arm_om_lua_frame()
    end
    -- Pathfinder jobs run on the Scheduler OnUpdate (cheap when idle).
    if R and R.Scheduler and R.Scheduler.start then pcall(R.Scheduler.start) end
    -- Surveyor: long delay — TraceLine fan at suite-on is a known crash co-factor.
    if R and R.Surveyor and R.Surveyor.start
        and (not R.Surveyor.needed or R.Surveyor.needed()) then
        if C_Timer and C_Timer.After then
            C_Timer.After(8.0, function()
                if RaijinLab and RaijinLab.Master and RaijinLab.Master.enabled
                    and RaijinLab.Master.enabled()
                    and RaijinLab.Surveyor and RaijinLab.Surveyor.start then
                    pcall(RaijinLab.Surveyor.start)
                end
            end)
        else
            pcall(R.Surveyor.start)
        end
    end

    -- The one exception, by explicit user rule: the main button turns the
    -- rotation on too. It is the part of the suite you almost always want, and
    -- it moves nothing on its own.
    for k in pairs(M.ALWAYS_ON) do d.modules[k] = true end

    -- Anything armed pulls its dependencies up with it, so a saved selection
    -- made before this rule existed still starts in a working state.
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then
            for _, dep in ipairs(M.missing_deps(k)) do d.modules[dep] = true end
        end
    end

    -- Auto-fill missing rotations from disk backup (never overwrites live work).
    -- Without this the user sees a red contract "12 rotations on disk, 3 loaded"
    -- and thinks the bot is broken when the suite is merely missing config.
    -- CB.restore() prints what it recovered.
    local CB = R and R.ConfigBackup
    if CB and CB.restore then pcall(CB.restore, CB, {}) end

    local started = {}
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then
            M.start_module(k)
            started[#started + 1] = k
        end
    end

    local Tel = TT()
    if Tel then Tel.warn("master", "on", { reason = reason or "user", modules = table.concat(started, ",") }) end
    print(string.format("|cff55ff55RaijinLab master ON|r reason=%s  modules={%s}",
        tostring(reason or "user"), table.concat(started, ",")))
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then
        DL.log("master", "ON reason=%s modules=%s",
            tostring(reason or "user"), table.concat(started, ","))
    end
    return started
end

function M.set(on, reason)
    if on then return M.start_all(reason) end
    return M.stop_all(reason)
end

-- Drop any keyboard-focused UI so Space (Jump) cannot activate "Turn OFF".
-- Live log: every wall contact was followed ~20ms later by master OFF reason=menu.
function M.clear_ui_focus()
    pcall(function()
        if ClearFocus then ClearFocus() end
        local f = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if f and f.ClearFocus then f:ClearFocus() end
        if f and f.EnableKeyboard then f:EnableKeyboard(false) end
    end)
end

function M.toggle(reason)
    local on = not M.enabled()
    -- One click OFF. (A prior double-confirm made the kill switch need 2-3 presses.)
    M._off_armed_t = nil
    M.set(on, reason)
    if on then M.clear_ui_focus() end
    return on
end

-- A one-line description for the UI and /raijin status. The count is always the
-- armed set - when running it is what runs, when stopped it is what ON would run.
function M.summary()
    return M.enabled(), #M.armed()
end

if RaijinLab then RaijinLab.Master = M end
return M
