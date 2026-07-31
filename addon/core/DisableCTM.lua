-- Hard-disables Click-To-Move.
--
-- Ascension's Interface Options -> Mouse -> "Enable Click to Move" toggle
-- occasionally sticks ON despite unchecking it (server-side default, an
-- addon touching the CVar, or a stale value in Config.wtf). This module
-- forces it off on every relevant client event AND intercepts any attempt
-- to re-enable it at runtime.
--
-- Covers every known 3.3.5-era CTM-adjacent CVar so we don't have to know
-- which specific one Ascension is toggling.

local CTM_CVARS = {
    "autoInteract",         -- classic AutoInteract (click on mob to walk-to+interact)
    "AutoInteract",         -- some builds are case-sensitive
    "enableClickToMove",    -- retail-style CTM CVar (some Ascension builds ported it)
    "ClickToMove",
    "interactOnLeftClick",
    "interactOnRightClick",
}

local function force_off()
    -- Prefer runtime SetCVarEx (C-origin) so addon Lua never taints SetCVar.
    local use_rt = RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime()
    for _, name in ipairs(CTM_CVARS) do
        if use_rt then
            pcall(RaijinLab.RuntimeCall, RaijinLab, "SetCVarEx", name, "0")
        elseif type(SetCVar) == "function" then
            -- Last resort only when runtime is offline (char select).
            pcall(SetCVar, name, "0")
        end
    end
end

-- Optional debug print - enable with /run RaijinLabDB.ctm_debug = true
local function dbg(msg)
    if RaijinLabDB and RaijinLabDB.ctm_debug then
        print("|cff7ec8e3RaijinLab CTM|r " .. tostring(msg))
    end
end

-- Post-observation hook: `hooksecurefunc` does not let us block the write,
-- but we can immediately re-write to "0" the next frame. Guarded so we
-- don't recurse when we do our own SetCVar. Uses a re-entry flag rather
-- than checking the caller (which would need debug.getinfo and is fragile).
local _reentry = false
if type(hooksecurefunc) == "function" and type(SetCVar) == "function" then
    hooksecurefunc("SetCVar", function(name, value)
        if _reentry then return end
        if type(name) ~= "string" then return end
        -- Fast-path check - any CTM CVar being set to non-"0" gets slammed back.
        for _, ctm in ipairs(CTM_CVARS) do
            if name == ctm and tostring(value) ~= "0" then
                dbg("intercepted SetCVar(" .. name .. ", " .. tostring(value) .. ") -> forcing 0")
                _reentry = true
                -- Runtime path when available; avoid re-entering secure SetCVar
                -- from this hook (taint / UNKNOWN() popups).
                if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
                    and RaijinLab:HasRuntime() then
                    pcall(RaijinLab.RuntimeCall, RaijinLab, "SetCVarEx", name, "0")
                elseif type(SetCVar) == "function" then
                    pcall(SetCVar, name, "0")
                end
                _reentry = false
                return
            end
        end
    end)
end

-- Event-driven force-off. Runs at addon load, world entry, and re-login.
local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
-- CVAR_UPDATE exists on some builds and fires after any CVar change; ignored
-- if the client doesn't recognize it (registering is safe either way).
pcall(function() f:RegisterEvent("CVAR_UPDATE") end)
f:SetScript("OnEvent", function(_, event, cvarName)
    if event == "CVAR_UPDATE" and type(cvarName) == "string" then
        -- Only redo the force if the changed CVar is one we care about.
        for _, ctm in ipairs(CTM_CVARS) do
            if cvarName == ctm then
                force_off()
                return
            end
        end
        return
    end
    force_off()
    dbg(event .. " -> forced CTM off")
end)

-- Belt-and-suspenders: sweep every 5 s in case something enables CTM outside
-- SetCVar / CVAR_UPDATE (e.g. direct .wtf write via /console). Cheap.
local sweep = CreateFrame("Frame")
local acc = 0
sweep:SetScript("OnUpdate", function(_, e)
    acc = acc + (e or 0)
    if acc < 5 then return end
    acc = 0
    force_off()
end)

-- Expose a one-shot escape hatch (for testing / a rare user who insists on
-- CTM despite the module): /run RaijinLab.disable_ctm(false)
-- Removing every hook + timer at runtime is fragile - the simpler contract
-- is a config flag the force_off respects.
RaijinLab = RaijinLab or {}
RaijinLab.ctm = { force_off = force_off }
function RaijinLab.disable_ctm(on)
    if on == false then
        f:UnregisterAllEvents()
        sweep:SetScript("OnUpdate", nil)
        print("|cff7ec8e3RaijinLab|r CTM force-off DISABLED. Re-enable by /reload.")
    else
        f:RegisterEvent("VARIABLES_LOADED")
        f:RegisterEvent("PLAYER_LOGIN")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        force_off()
        print("|cff7ec8e3RaijinLab|r CTM force-off re-enabled.")
    end
end
