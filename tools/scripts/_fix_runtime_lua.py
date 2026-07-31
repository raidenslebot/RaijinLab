from pathlib import Path
p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Runtime.lua")
p.write_text(r'''-- RaijinLab runtime bridge detection + safe stubs
-- Loads before privileged features fully engage.

local RL = RaijinLab

local function bridge()
    if type(RaijinLab_Runtime) == "function" then
        return RaijinLab_Runtime
    end
    if type(IsLinuxClient) == "function" then
        return IsLinuxClient
    end
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
    local b = bridge()
    if not b then
        return nil
    end
    local ok, ver = pcall(b, "GetRuntimeVersion")
    if ok and ver ~= nil then
        return ver
    end
    -- Some bridges return nothing for version; still count as present
    if type(b) == "function" then
        return "present"
    end
    return nil
end

function RL:AssertRuntime(feature)
    if self:HasRuntime() then
        return true
    end
    if not self._runtime_warned then
        self._runtime_warned = true
        print("|cff7ec8e3RaijinLab|r: runtime not loaded — privileged features disabled (" ..
                  tostring(feature or "generic") .. ")")
        print("|cff7ec8e3RaijinLab|r: run RaijinLabLoader.exe while in-game, then /rl status")
    end
    return false
end

function RL:PrintBanner()
    if self:HasRuntime() then
        print("|cff7ec8e3RaijinLab|r |cffffffff1.1|r — runtime: |cff55ff55" ..
                  tostring(self:RuntimeVersion() or "yes") .. "|r")
    else
        print("|cff7ec8e3RaijinLab|r |cffffffff1.1|r — runtime: |cffff5555not loaded|r")
        print("|cff7ec8e3RaijinLab|r: inject with |cffffffffRaijinLabLoader.exe|r (game must be running)")
        print("|cff7ec8e3RaijinLab|r: path: Workspace\\RaijinLab\\runtime\\dist\\")
    end
end

-- Detect inject after addon load without /reload
do
    local f = CreateFrame("Frame")
    local t, had = 0, false
    f:SetScript("OnUpdate", function(_, e)
        t = t + e
        if t < 1.0 then return end
        t = 0
        local has = RL:HasRuntime()
        if has and not had then
            print("|cff7ec8e3RaijinLab|r: runtime |cff55ff55ONLINE|r — " .. tostring(RL:RuntimeVersion() or "?"))
        end
        had = has
    end)
end
''', encoding='utf-8', newline='\n')
print('Runtime.lua written')
