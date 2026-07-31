-- RaijinLab runtime bridge detection + safe stubs
-- Loads before privileged features fully engage.
--
-- CRITICAL: Ascension/Blizzard ships a stock global IsLinuxClient() that is a
-- harmless nil-returning stub (same body as IsMacClient). type(IsLinuxClient)
-- is ALWAYS "function" even with no DLL injected. We must NEVER treat that as
-- our unlocker - only accept a bridge that answers GetRuntimeVersion with our
-- version string (e.g. "1.5.0-suite").

local RL = RaijinLab

local function is_our_version(ver)
    if type(ver) ~= "string" or ver == "" then return false end
    -- Accept "1.10.39-bridge" / "1.x.y" / any 1.* runtime tag
    if ver:match("^1%.%d+") then return true end
    return false
end

-- Positive probe cache only (~0.2s). Never cache failure — recover the frame
-- after main-thread seal without waiting for a long timer.
local _bridge_fn, _bridge_ver, _bridge_t = nil, nil, 0

local function probe_bridge(fn)
    if type(fn) ~= "function" then return nil end
    local ok, ver = pcall(fn, "GetRuntimeVersion")
    if ok and is_our_version(ver) then
        return fn, ver
    end
    return nil
end

local function bridge()
    local now = (GetTime and GetTime()) or 0
    if _bridge_fn and _bridge_ver and (now - (_bridge_t or 0)) < 0.2 then
        return _bridge_fn, _bridge_ver
    end
    -- Stealth: ONLY stock global IsLinuxClient (rebound by inject).
    local fn, ver = probe_bridge(IsLinuxClient)
    if fn then
        _bridge_fn, _bridge_ver, _bridge_t = fn, ver, now
        return fn, ver
    end
    _bridge_fn, _bridge_ver = nil, nil
    return nil
end

function RL:HasRuntime()
    return bridge() ~= nil
end

function RL:RuntimeCall(name, ...)
    local b = bridge()
    if not b then
        return nil
    end
    return b(name, ...)
end

function RL:RuntimeVersion()
    local b, ver = bridge()
    if b and ver then return ver end
    return nil
end

-- Why HasRuntime is false (for /raijin status). Distinguishes stock stub vs missing.
function RL:RuntimeDetectDiag()
    local t = type(IsLinuxClient)
    if t ~= "function" then
        return "IsLinuxClient type=" .. tostring(t) .. " (not injected or wiped)"
    end
    local ok, ver = pcall(IsLinuxClient, "GetRuntimeVersion")
    if not ok then
        return "probe error: " .. tostring(ver)
    end
    if is_our_version(ver) then
        return "ok ver=" .. tostring(ver)
    end
    -- Stock 3.3.5 stub: function exists, returns nil / wrong value
    return "stock IsLinuxClient (wait for BRIDGE ONLINE + main seal; avoid /reload right after inject)"
end

function RL:AssertRuntime(feature)
    if self:HasRuntime() then
        return true
    end
    if not self._runtime_warned then
        self._runtime_warned = true
        print("|cff7ec8e3RaijinLab|r: runtime not detected (" ..
                  tostring(feature or "generic") .. ")")
        print("|cff7ec8e3RaijinLab|r: " .. tostring(self:RuntimeDetectDiag()))
        print("|cff7ec8e3RaijinLab|r: inject IN-WORLD, wait for BRIDGE ONLINE in inject log, then /raijin status — avoid /reload right after inject")
    end
    return false
end

function RL:PrintBanner()
    -- Silent by default (chat spam is a detection / report surface).
    -- /raijin status still prints on demand.
    if self._debug_print then
        if self:HasRuntime() then
            print("|cff7ec8e3RaijinLab|r runtime: |cff55ff55" .. tostring(self:RuntimeVersion() or "yes") .. "|r")
        else
            print("|cff7ec8e3RaijinLab|r runtime: |cffff5555off|r")
        end
    end
end

-- Lightweight notice only - NEVER OmProbe / enum / InitObjectManager here.
-- Inject at char-select must not start the world-list OnUpdate (no player yet).
function RL:OnRuntimeOnline(ver)
    if self._runtime_online_noted then return end
    self._runtime_online_noted = true
    if self._debug_print then
        print("|cff7ec8e3RaijinLab|r: runtime online " .. tostring(ver or "?"))
    end
    pcall(function()
        self:RuntimeCall("Ping")
        -- Leave om.enable alone. Inject starts at 0; PEW arm turns it on.
        -- Never force-off here - that fought Master/Suite and left status dead.
    end)
end

-- Arm AFTER PLAYER_ENTERING_WORLD + delay (see Events.lua). Fully in-world:
-- turn the object manager ON for the session. Quest/combat/gather all need it.
-- Single-GUID reads work either way; the list (nearby NPCs) needs this.
-- PURE: should we (re)try arming the runtime systems this tick?
--
-- Extracted so the RETRY is testable. The bug it exists to prevent: arming was
-- an edge trigger on the runtime coming online, but ArmRuntimeSystems returns
-- early WITHOUT setting _runtime_armed if the player is not ready - so one
-- mistimed attempt left the object manager unarmed for the whole session and no
-- second edge ever came.
--
-- Retry on the STATE we want (not armed yet), never on the event that usually
-- produces it. The settle keeps us from arming before the world exists, which is
-- what caused the world-load access violation (#132).
function RL.should_arm(has_runtime, armed, online_t, now, player_ready, settle)
    if not has_runtime then return false end
    if armed then return false end            -- idempotent: nothing to do
    if not player_ready then return false end -- in-world gate, #132
    -- Mid-/reload: LEAVING_WORLD clears _world_entered until PEW.
    if RL._leaving_world then return false end
    -- Inject mid-session (PEW already fired before inject): treat as entered.
    if not RL._world_entered then
        RL._world_entered = true
    end
    settle = settle or 0
    if type(now) ~= "number" or type(online_t) ~= "number" then
        return true
    end
    return (now - online_t) >= settle
end

function RL:ArmRuntimeSystems()
    if self._runtime_armed then return end
    if not self:HasRuntime() then return end
    if UnitName and not UnitName("player") then return end
    -- World-ready: player position must resolve. should_arm retries.
    do
        local ready = false
        if self.ObjectPosition then
            local ok, x, y = pcall(self.ObjectPosition, self, "player")
            if ok and type(x) == "number" and type(y) == "number"
                and (math.abs(x) > 0.01 or math.abs(y) > 0.01) then
                ready = true
            end
        end
        if not ready then return end
    end
    -- Split arm: HW unlock first (safe). OM enable only after a successful
    -- Ping + LocalGuid-ish existence. Live crash 15:41: PEW om=1 + enum mid-load.
    -- Runtime now defers EnumVisibleObjects until list-only warm; still keep
    -- om.enable off until we can read player pos twice (stable world).
    if not self._runtime_hw_armed then
        pcall(function()
            self:RuntimeCall("SetSystemVar", "taint.patch", "0")
            self:RuntimeCall("ArmUnlock")
            self:RuntimeCall("Ping")
        end)
        if self.Actions and self.Actions.ensure then
            pcall(function() self.Actions.ensure() end)
        end
        self._runtime_hw_armed = true
        self._arm_pos_ok = 0
    end
    -- Require two consecutive ready ticks before OM (awareness, not a sleep).
    self._arm_pos_ok = (self._arm_pos_ok or 0) + 1
    if self._arm_pos_ok < 2 then return end

    self._runtime_armed = true
    pcall(function()
        -- Soft list discovery works with om.enable 0; enable for full path.
        -- Runtime defers EnumVisibleObjects until list-warm after rebind
        -- (g_firstPlayerMs reset on OnLuaReload — 1.10.34). Safe to enable.
        self:RuntimeCall("SetSystemVar", "om.enable", "1")
    end)
    -- NEVER InitObjectManager on arm frame (GetObjectCount fan mid-load = crash).
    -- Watchdog: cheap 1Hz, only after OM arm.
    if self.Watchdog and self.Watchdog.start then
        pcall(self.Watchdog.start)
    end
    if self._debug_print then
        print("|cff7ec8e3RaijinLab|r: runtime armed (OM on, one-shot)")
    end
    local DL = self.DevLog
    if DL and DL.log then DL.log("runtime", "armed one-shot om=1") end
end

-- Detect inject after addon load without /reload. If we are already in-world
-- (PEW fired before inject), arm OM after a short settle - do not wait forever
-- for another PEW.
do
    local f = CreateFrame("Frame")
    local t, had = 0, false
    f:SetScript("OnUpdate", function(_, e)
        t = t + e
        if t < 0.5 then return end
        t = 0
        local has = RL:HasRuntime()
        if has and not had then
            RL:OnRuntimeOnline(RL:RuntimeVersion())
            RL._runtime_online_t = GetTime and GetTime() or 0
            -- Always print once so inject detection is visible without debug flag.
            print("|cff7ec8e3RaijinLab|r: runtime |cff55ff55ONLINE|r "
                .. tostring(RL:RuntimeVersion() or "?"))
        elseif not has and had then
            RL._runtime_online_noted = false
            RL._runtime_armed = false
            RL._runtime_hw_armed = false
            RL._arm_pos_ok = 0
            _bridge_fn, _bridge_ver = nil, nil
            print("|cff7ec8e3RaijinLab|r: runtime |cffff5555OFFLINE|r")
        end
        -- ARM UNTIL IT ACTUALLY ARMS - NOT ONCE, ON AN EDGE.
        --
        -- This used to fire ArmRuntimeSystems only on the has/not-had TRANSITION.
        -- But ArmRuntimeSystems returns early WITHOUT setting _runtime_armed when
        -- UnitName("player") is not ready yet - so a single attempt that landed a
        -- moment too early left the object manager unarmed for the entire
        -- session, with no second edge ever coming. That is the standing
        -- "N units from the bridge but the engine snapshot is EMPTY": the OM
        -- OnUpdate was never started, so object_list.npcs stayed the empty table
        -- it is initialised to, and questing was blind.
        --
        -- The condition to retry on is the STATE we want (armed), not the event
        -- that usually produces it. ArmRuntimeSystems is idempotent - it returns
        -- immediately when already armed - so retrying every 0.5s is free.
        --
        -- The settle is kept: arming before the world is up is what caused the
        -- world-load access violation (#132), and ArmRuntimeSystems' own
        -- UnitName gate is the second line of defence.
        if RL.ArmRuntimeSystems and RL.should_arm(
                has, RL._runtime_armed,
                RL._runtime_online_t or 0, GetTime and GetTime() or 0,
                UnitName and UnitName("player") and true or false) then
            RL:ArmRuntimeSystems()
        end
        had = has
    end)
end
