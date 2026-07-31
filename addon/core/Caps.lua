-- Caps - capability registry.
--
-- Workarounds rot when they hardcode "ObjectFacing is useless" after the runtime
-- has already shipped livefacing. Capabilities are probed once (and re-probed on
-- demand) from the runtime version string and actual API calls. Every workaround
-- branches on Caps.x so a capability that appears lifts every branch that cares.
--
-- Design:
--   * probe() returns a three-valued Know-style table, never a bare boolean.
--   * Caps.has("live_facing") is the greppable collapse for code that truly
--     needs a boolean (with a recorded assumption reason).
--   * Caps.report() feeds /raijin check so "why is it still on keyboard turn"
--     is a one-line answer.

local Caps = {}

Caps._cache = {}
Caps._probed_at = 0
Caps.PROBE_TTL = 30.0     -- s: re-check periodically; version can change mid-session after reinject

local function now() return (GetTime and GetTime()) or 0 end
local function K() return RaijinLab and RaijinLab.Know end

local function yes(v, why) local Kn = K(); if Kn then return Kn.yes(v, why) end; return { state = "yes", value = v, why = why } end
local function no(why) local Kn = K(); if Kn then return Kn.no(why) end; return { state = "no", why = why } end
local function unk(why) local Kn = K(); if Kn then return Kn.unknown(why) end; return { state = "unknown", why = why } end

-- ---- individual probes ----------------------------------------------------

local function probe_runtime()
    local RL = RaijinLab
    if not (RL and RL.HasRuntime and RL:HasRuntime()) then
        return no("no_runtime")
    end
    local ver = RL:RuntimeVersion()
    if type(ver) ~= "string" or ver == "" then return unk("version_unreadable") end
    return yes(ver, "runtime")
end

local function probe_live_facing()
    local r = probe_runtime()
    if r.state ~= "yes" then return r end
    local ver = tostring(r.value or "")
    -- Runtime version string is the authority for the facing fix. The old
    -- "ObjectFacing is useless" comment was true BEFORE 1.8.8-livefacing.
    if ver:find("livefacing", 1, true) or ver:find("1%.8%.[89]") or ver:find("1%.9")
       or ver:find("1%.[1-9]%d") then
        return yes(true, "version:" .. ver)
    end
    -- Probe empirically: if ObjectFacing("player") returns a sane radian, trust it.
    local RL = RaijinLab
    if RL and RL.ObjectFacing then
        local ok, f = pcall(RL.ObjectFacing, RL, "player")
        if ok and type(f) == "number" and f == f and math.abs(f) < 20 and (f ~= 0 or true) then
            -- 0 is a valid facing (east). Accept any finite small number.
            if f > -100 and f < 100 then return yes(true, "objectfacing_ok") end
        end
    end
    return no("pre_livefacing:" .. ver)
end

local function probe_traceline()
    local RL = RaijinLab
    if not (RL and RL.TraceLine) then return no("no_api") end
    -- A zero-length call should not crash. Any result (hit or miss) proves the path.
    local ok, a = pcall(function()
        return RL:TraceLine(0, 0, 0, 0, 0, 0)
    end)
    if not ok then return unk("error") end
    return yes(true, "callable")
end

local function probe_pathfind()
    local N = RaijinLab and RaijinLab.Navigator
    if N and type(N.pathfind_to) == "function" then return yes(true, "navigator") end
    local P = RaijinLab and RaijinLab.Pathfinder
    if P and type(P.search) == "function" then return yes(true, "pathfinder") end
    return no("no_pathfind")
end

local function probe_object_position()
    local RL = RaijinLab
    if not (RL and RL.ObjectPosition) then return no("no_api") end
    local ok, x = pcall(RL.ObjectPosition, RL, "player")
    if not ok then return unk("error") end
    if type(x) == "number" and x == x and (x ~= 0 or true) then
        -- nil-return means not in world / OM cold; that is unknown, not no-api.
        if x == nil then return unk("no_pos") end
        return yes(true, "readable")
    end
    -- multi-return: ObjectPosition returns x,y,z
    if ok and x ~= nil then return yes(true, "readable") end
    return unk("no_pos")
end

local function probe_cast()
    local A = RaijinLab and RaijinLab.Actions
    if A and type(A.CastSpell) == "function" then return yes(true, "actions") end
    return no("no_cast")
end

local PROBES = {
    runtime          = probe_runtime,
    live_facing      = probe_live_facing,
    traceline        = probe_traceline,
    pathfind         = probe_pathfind,
    object_position  = probe_object_position,
    cast             = probe_cast,
}

function Caps.probe(name, force)
    local t = now()
    if not force and Caps._cache[name] and (t - Caps._probed_at) < Caps.PROBE_TTL then
        return Caps._cache[name]
    end
    local fn = PROBES[name]
    if not fn then return unk("unknown_cap:" .. tostring(name)) end
    local ok, res = pcall(fn)
    if not ok then res = unk("probe_error") end
    Caps._cache[name] = res
    Caps._probed_at = t
    return res
end

function Caps.refresh()
    Caps._cache = {}
    Caps._probed_at = 0
    for name in pairs(PROBES) do Caps.probe(name, true) end
    return Caps._cache
end

-- Greppable collapse. Prefer Caps.know(name) + Know.assume at the call site.
function Caps.has(name)
    local k = Caps.probe(name)
    local Kn = K()
    if Kn and Kn.assume then
        return Kn.assume(k, false, "caps:" .. tostring(name))
    end
    return k and k.state == "yes"
end

function Caps.know(name)
    return Caps.probe(name)
end

function Caps.report()
    local lines = {}
    for name in pairs(PROBES) do
        local k = Caps.probe(name)
        local st = (k and k.state) or "?"
        local why = (k and k.why) or ""
        lines[#lines + 1] = string.format("  cap %-16s %s%s",
            name, st, why ~= "" and (" (" .. why .. ")") or "")
    end
    table.sort(lines)
    return lines
end

if RaijinLab then RaijinLab.Caps = Caps end
return Caps
