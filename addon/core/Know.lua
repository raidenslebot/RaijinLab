-- Know - three-valued knowledge, because two is a lie.
--
-- Nearly every bug in this codebase has been the same shape: a function that can
-- mean YES, NO, or I-COULD-NOT-TELL, forced through a return type that only has
-- room for two. The third case then silently aliases to whichever of the other
-- two was convenient WHERE THE FUNCTION WAS WRITTEN - and that is always wrong
-- for someone, because the safe default belongs to the CALLER, not the sensor.
--
-- Real examples, all shipped, all found in live play:
--   TraceLine to a goal 2203yd away    -> "clear"      meant "nothing loaded there"
--   profession_enabled("fishing")      -> true         meant "user never said"
--   a rotation table exists            -> "valid"      meant "holds no spells"
--   GetNumCompanions("MOUNT") > 0      -> "can mount"  meant "owns one, may not ride"
--   remembered_objective() -> nil      -> "not there"  meant "never looked"
--   _cam_ok = false                    -> "lying"      meant "could not check"
--
-- So: sensors report what they actually know, including that they do not know,
-- and every collapse to a boolean happens at a call site that can justify it and
-- is greppable afterwards.
--
--   local k = Mount.can_ride()
--   if Know.is_yes(k) then ... elseif Know.is_no(k) then ... else ... end
--   if Know.assume(k, false, "refuse to mount when we cannot verify") then ... end
--
-- Deliberately a plain table, not a metatable-heavy class: this is called inside
-- 70Hz loops and must stay allocation-cheap and dump-readable in a log line.

local Know = {}

Know.YES     = "yes"
Know.NO      = "no"
Know.UNKNOWN = "unknown"

-- ---- construction ---------------------------------------------------------

function Know.yes(value, why)
    return { state = Know.YES, value = value, why = why }
end

function Know.no(why)
    return { state = Know.NO, why = why }
end

function Know.unknown(why)
    return { state = Know.UNKNOWN, why = why }
end

-- Lift a legacy boolean. `why` should say WHY the boolean is trustworthy here -
-- if you cannot say, the honest answer is Know.unknown.
function Know.from_bool(b, why)
    if b == nil then return Know.unknown(why or "nil") end
    if b then return Know.yes(true, why) end
    return Know.no(why)
end

-- Wrap a call that may error or may be missing entirely. A function that does
-- not exist is the canonical UNKNOWN: it is not evidence of absence.
--
-- NIL IS A REAL ANSWER ON THIS CLIENT. 3.3.5 boolean apis return 1/nil, not
-- true/false, so IsSwimming() answering nil means "not swimming" - it is not
-- ignorance. The earlier rule here mapped nil to UNKNOWN, which would have made
-- every negative answer in the game infectious the moment this was wired up
-- (UNKNOWN poisons `all`/`any` by design). It was never wired up, so the bug
-- stayed theoretical - but the renderer and the quest turn-in each grew their
-- own hand-rolled version of this decision, and one of them was wrong for a
-- whole session. Hence: one primitive, correct for the client we actually run.
--
-- Only two things are ignorance: an api that is not there, and one that throws.
function Know.probe(fn, ...)
    if type(fn) ~= "function" then return Know.unknown("no_api") end
    local ok, res = pcall(fn, ...)
    if not ok then return Know.unknown("error") end
    if res == nil or res == false then return Know.no("probed") end
    return Know.yes(res, "probed")
end

-- ---- inspection -----------------------------------------------------------

local function state_of(k)
    if type(k) == "table" and k.state then return k.state end
    -- Tolerate raw booleans/nil from code not yet converted, but treat nil as
    -- UNKNOWN rather than NO - that asymmetry is the whole point of this module.
    if k == nil then return Know.UNKNOWN end
    if k == false then return Know.NO end
    return Know.YES
end
Know.state = state_of

function Know.is_yes(k)     return state_of(k) == Know.YES end
function Know.is_no(k)      return state_of(k) == Know.NO end
function Know.is_unknown(k) return state_of(k) == Know.UNKNOWN end

-- "Definitely not" - the ONLY safe basis for refusing to act on evidence.
-- Distinct from `not is_yes`, which also swallows UNKNOWN.
function Know.known_false(k) return state_of(k) == Know.NO end
function Know.known_true(k)  return state_of(k) == Know.YES end

function Know.value(k, default)
    if type(k) == "table" then
        if k.value ~= nil then return k.value end
        return (k.state == Know.YES) or default
    end
    if k == nil then return default end
    return k
end

function Know.why(k)
    if type(k) == "table" then return k.why end
    return nil
end

-- ---- the deliberate collapse ----------------------------------------------

-- Force a decision, stating what you assume when the answer is unknown and WHY
-- that is the safe assumption HERE. Every such choice is greppable and appears
-- in telemetry, so an assumption can never quietly become an invisible policy.
function Know.assume(k, when_unknown, reason)
    local st = state_of(k)
    if st == Know.YES then return true end
    if st == Know.NO then return false end
    Know._assumptions = Know._assumptions or {}
    local key = tostring(reason or "?")
    Know._assumptions[key] = (Know._assumptions[key] or 0) + 1
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.every then
        Tel.every("know:" .. key, 30, "know", 4, "assumed",
            { as = when_unknown and "yes" or "no", why = key, unknown = Know.why(k) })
    end
    return when_unknown and true or false
end

-- Every assumption made this session, so "what is this bot guessing about?" is a
-- question with an answer.
function Know.assumptions() return Know._assumptions or {} end

-- ---- combination ----------------------------------------------------------
-- UNKNOWN is infectious in exactly one direction, which is what makes these
-- correct rather than convenient:
--   all(): one NO decides it; otherwise any UNKNOWN means UNKNOWN.
--   any(): one YES decides it; otherwise any UNKNOWN means UNKNOWN.

function Know.all(...)
    local n = select("#", ...)
    local unknown = nil
    for i = 1, n do
        local k = select(i, ...)
        local st = state_of(k)
        if st == Know.NO then return Know.no(Know.why(k) or "one_false") end
        if st == Know.UNKNOWN then unknown = unknown or k end
    end
    if unknown then return Know.unknown(Know.why(unknown) or "incomplete") end
    return Know.yes(true, "all")
end

function Know.any(...)
    local n = select("#", ...)
    local unknown = nil
    for i = 1, n do
        local k = select(i, ...)
        local st = state_of(k)
        if st == Know.YES then return Know.yes(Know.value(k, true), Know.why(k) or "one_true") end
        if st == Know.UNKNOWN then unknown = unknown or k end
    end
    if unknown then return Know.unknown(Know.why(unknown) or "incomplete") end
    return Know.no("none")
end

-- NOT must preserve ignorance: the negation of "I do not know" is "I do not know".
function Know.negate(k)
    local st = state_of(k)
    if st == Know.YES then return Know.no("negated") end
    if st == Know.NO then return Know.yes(true, "negated") end
    return Know.unknown(Know.why(k) or "negated_unknown")
end

-- A positive observation is PROOF and outranks every heuristic from then on.
-- (Mount learned this the hard way: a character that has actually mounted can
-- ride, whatever the skill probes think.)
function Know.proven(flag, k, why)
    if flag then return Know.yes(true, why or "proven") end
    return k
end

function Know.tostring(k)
    local st = state_of(k)
    local w = Know.why(k)
    return st .. (w and ("(" .. tostring(w) .. ")") or "")
end

if RaijinLab then RaijinLab.Know = Know end
return Know
