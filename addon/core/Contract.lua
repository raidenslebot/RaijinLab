-- Contract - the bot checks itself, and says why.
--
-- Every failure this project has shipped was found the same way: a human played
-- for an hour, said "it does nothing", and someone read a log backwards to work
-- out which of nine subsystems had quietly declined to act. Nothing in the code
-- ever noticed. Seven subsystems logged ZERO lines across a 166-minute session
-- and that was not an error - it was indistinguishable from having nothing to do.
--
-- A contract turns that inside out. Each subsystem states, in code, what must be
-- OBSERVABLY TRUE while it is running:
--
--   * LIVENESS  - "while I am enabled I emit at least one line every N seconds."
--                 Silence stops being invisible and becomes a violation.
--   * BEHAVIOUR - "while I claim to be travelling, the character's position must
--                 change within 60s, or I must have logged a reason."
--
-- The engine evaluates these once a second and reports violations LOUDLY, with an
-- explanation attached, so the answer to "why is it doing nothing?" is produced
-- by the bot rather than reconstructed by a human afterwards.
--
-- Design rules learned from the bugs this replaces:
--   * A violation needs an EXPLANATION, not just a name. "nav_silent" is a
--     symptom; "nav has emitted nothing for 118s while goal=progress claims to be
--     travelling" is a diagnosis.
--   * Not-applicable is not satisfied. An invariant whose precondition is false
--     reports UNKNOWN, never OK - the same three-valued discipline as Know.lua.
--   * Checking must never itself throw. Every user predicate is pcall'd; a
--     contract that can crash the client is worse than no contract.

local Contract = {}

Contract.TICK        = 1.0     -- s between evaluations
Contract.REPORT_GAP  = 60.0    -- s between repeats of the same violation in chat
Contract._invariants = {}
Contract._order      = {}
Contract._violations = {}
Contract._running    = false

local function now() return (GetTime and GetTime()) or 0 end
local function TT() return RaijinLab and RaijinLab.Telemetry end

local function safe(fn, dflt)
    if type(fn) ~= "function" then return dflt end
    local ok, v = pcall(fn)
    if not ok then return dflt end
    return v
end

-- ---- declaring ------------------------------------------------------------

-- spec = {
--   when    = fn() -> truthy while this invariant APPLIES (its precondition)
--   require = fn() -> truthy when the required progress has been observed
--   within  = seconds `when` may hold without `require` before it is a violation
--   explain = fn() -> string, the diagnosis shown to the user
--   severity= "error" (default) | "warn"
-- }
function Contract.invariant(name, spec)
    spec = spec or {}
    spec.name = name
    spec.within = spec.within or 60
    spec.severity = spec.severity or "error"
    spec._since = nil          -- when `when` started holding
    spec._last_ok = nil        -- when `require` was last satisfied
    if not Contract._invariants[name] then Contract._order[#Contract._order + 1] = name end
    Contract._invariants[name] = spec
    return spec
end

-- LIVENESS. `active` says whether the subsystem should be doing anything at all;
-- silence only matters when it claims to be running. Progress is measured by the
-- telemetry emit COUNT for the category, which counts attempts even when the
-- level filter drops the line - so turning logging down cannot fake liveness.
function Contract.liveness(cat, active, secs, explain)
    return Contract.invariant("live:" .. cat, {
        when = active,
        require = function()
            local Tel = TT()
            if not (Tel and Tel.counts) then return true end   -- no telemetry: cannot judge
            local n = (Tel.counts() or {})[cat] or 0
            local prev = Contract._counts and Contract._counts[cat]
            Contract._counts = Contract._counts or {}
            Contract._counts[cat] = n
            if prev == nil then return true end
            return n > prev
        end,
        within = secs or 90,
        explain = explain or function()
            return "subsystem '" .. cat .. "' is enabled but has emitted nothing - " ..
                   "it is most likely never being invoked at all"
        end,
    })
end

-- ---- evaluating -----------------------------------------------------------

-- Returns "ok" | "violated" | "n/a". NOT-APPLICABLE IS NOT OK: an invariant whose
-- precondition is false has proven nothing, and reporting that as healthy is how
-- a dead subsystem reads as a working one.
function Contract.evaluate(spec, t)
    t = t or now()
    local applies = safe(spec.when, false)
    if not applies then
        spec._since = nil
        return "n/a"
    end
    spec._since = spec._since or t
    if safe(spec.require, false) then
        spec._last_ok = t
        spec._since = t
        return "ok"
    end
    local held = t - (spec._since or t)
    if held > spec.within then return "violated", held end
    return "ok", held
end

function Contract.tick()
    local t = now()
    if (t - (Contract._last or 0)) < Contract.TICK then return end
    Contract._last = t
    local Tel = TT()
    for _, name in ipairs(Contract._order) do
        local spec = Contract._invariants[name]
        if spec then
            local status, held = Contract.evaluate(spec, t)
            if status == "violated" then
                local v = Contract._violations[name]
                if not v then
                    v = { name = name, since = t, count = 0 }
                    Contract._violations[name] = v
                end
                v.count = v.count + 1
                v.held = held
                v.explain = safe(spec.explain, nil) or name
                -- Loud, but not every second: once, then at REPORT_GAP.
                if (t - (v.reported or -1e9)) > Contract.REPORT_GAP then
                    v.reported = t
                    if Tel then
                        local fn = (spec.severity == "warn") and Tel.warn or Tel.err
                        fn("contract", "violated",
                           { name = name, held = math.floor(held or 0), n = v.count })
                    end
                    if print then
                        print("|cffff5555RaijinLab CONTRACT|r " .. tostring(v.explain))
                    end
                end
            elseif Contract._violations[name] then
                -- Recovered: say so, so a fixed problem stops being reported.
                local v = Contract._violations[name]
                Contract._violations[name] = nil
                if Tel then Tel.info("contract", "recovered",
                    { name = name, was = math.floor(v.held or 0) }) end
            end
        end
    end
end

-- ---- self-explanation -----------------------------------------------------

-- The answer to "why is it doing nothing?", produced by the bot. Ordered worst
-- first, because the first violated contract is nearly always the cause and the
-- rest are consequences.
function Contract.diagnose()
    local t = now()
    local out = { violated = {}, ok = {}, na = {} }
    for _, name in ipairs(Contract._order) do
        local spec = Contract._invariants[name]
        if spec then
            local status, held = Contract.evaluate(spec, t)
            if status == "violated" then
                out.violated[#out.violated + 1] = {
                    name = name, held = held or 0,
                    explain = safe(spec.explain, nil) or name,
                }
            elseif status == "ok" then
                out.ok[#out.ok + 1] = name
            else
                out.na[#out.na + 1] = name
            end
        end
    end
    table.sort(out.violated, function(a, b) return (a.held or 0) > (b.held or 0) end)
    return out
end

function Contract.report()
    local d = Contract.diagnose()
    local lines = {}
    if #d.violated == 0 then
        lines[#lines + 1] = "|cff10ff10All contracts satisfied.|r"
        if #d.ok == 0 then
            lines[#lines + 1] = "|cffffcc00...but NOTHING is applicable - " ..
                "no subsystem currently claims to be doing anything.|r"
        end
    else
        lines[#lines + 1] = "|cffff5555" .. #d.violated .. " contract(s) violated:|r"
        for _, v in ipairs(d.violated) do
            lines[#lines + 1] = string.format("  |cffff8080%s|r (%ds) - %s",
                v.name, math.floor(v.held or 0), tostring(v.explain))
        end
    end
    lines[#lines + 1] = string.format("  ok=%d  not-applicable=%d", #d.ok, #d.na)
    return lines, d
end

-- ---- lifecycle ------------------------------------------------------------

function Contract.start()
    if Contract._running then return end
    Contract._running = true
    if C_Timer and C_Timer.NewTicker then
        Contract._ticker = C_Timer.NewTicker(Contract.TICK, function() pcall(Contract.tick) end)
    elseif CreateFrame then
        local f = CreateFrame("Frame")
        local acc = 0
        f:SetScript("OnUpdate", function(_, e)
            acc = acc + e
            if acc >= Contract.TICK then acc = 0; pcall(Contract.tick) end
        end)
        Contract._frame = f
    end
end

function Contract.stop()
    if Contract._ticker then Contract._ticker:Cancel(); Contract._ticker = nil end
    if Contract._frame then Contract._frame:SetScript("OnUpdate", nil); Contract._frame = nil end
    Contract._running = false
end

function Contract.reset()
    Contract._invariants = {}
    Contract._order = {}
    Contract._violations = {}
    Contract._counts = nil
    Contract._last = nil
end

if RaijinLab then RaijinLab.Contract = Contract end
return Contract
