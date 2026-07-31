-- GOFlags - decide which GO_DYNFLAG_LO_* mapping this server uses, by PROOF.
--
-- WHY THIS EXISTS. The quest-item witness rests on one bit: SPARKLE. Two real
-- TrinityCore tables disagree about which bit that is, and both are genuine -
-- the comments in this addon's own enum are verbatim TrinityCore, so whoever
-- transcribed it copied a different branch than the client targets:
--
--            MODERN            CLASSIC (3.3.5 branch)
--   HIDE_MODEL   0x02          -            -
--   ACTIVATE     0x04          ACTIVATE     0x01
--   ANIMATE      0x08          ANIMATE      0x02
--   NO_INTERACT  0x10          NO_INTERACT  0x04
--   SPARKLE      0x20          SPARKLE      0x08
--   STOPPED      0x40          STOPPED      0x10
--   DEPLETED     0x80          -            -
--
-- The same set, shifted one bit. This is NOT cosmetic: under CLASSIC the 0x04
-- that MODERN calls ACTIVATE is NO_INTERACT, so picking wrong makes the witness
-- promote exactly the objects it must skip.
--
-- No offline source settles which one Ascension's core writes. But the world
-- does, and it settles it by DEDUCTION rather than by anyone eyeballing a
-- sparkle:
--
--   * 0x01 is UNDEFINED in MODERN (its lowest flag is 0x02).
--     Observing it anywhere therefore PROVES the mapping is CLASSIC.
--   * 0x20/0x40/0x80 are UNDEFINED in CLASSIC (its highest flag is 0x10).
--     Observing any of them PROVES the mapping is MODERN.
--
-- Each is a one-way proof, not a heuristic. Until one fires the mapping is
-- UNKNOWN and every caller is told so - callers must abstain rather than pick a
-- side, because a wrong pick is worse than no pick. That is the whole discipline
-- of this project applied to a constant: act on evidence, never on the more
-- likely option.

local GOFlags = {}
RaijinLab.GOFlags = GOFlags

GOFlags.MODERN = {
    HIDE_MODEL = 0x02, ACTIVATE = 0x04, ANIMATE = 0x08,
    NO_INTERACT = 0x10, SPARKLE = 0x20, STOPPED = 0x40, DEPLETED = 0x80,
}
GOFlags.CLASSIC = {
    ACTIVATE = 0x01, ANIMATE = 0x02, NO_INTERACT = 0x04,
    SPARKLE = 0x08, STOPPED = 0x10,
}

-- Bits that exist in exactly one mapping. These are the whole proof.
GOFlags.PROVES_CLASSIC = 0x01              -- undefined in MODERN
GOFlags.PROVES_MODERN = { 0x20, 0x40, 0x80 }  -- undefined in CLASSIC

GOFlags._seen = 0        -- union of every low word observed
GOFlags._locked = nil    -- "modern" | "classic", once proven

local function has(v, f) return math.floor(v / f) % 2 == 1 end

-- Feed one observed GAMEOBJECT_DYNAMIC low word. Cheap and idempotent.
function GOFlags.observe(low)
    if type(low) ~= "number" or low <= 0 then return end
    low = math.floor(low) % 65536
    -- accumulate the union without a bit library (this file also runs headless)
    local v = 1
    for _ = 1, 16 do
        if has(low, v) and not has(GOFlags._seen, v) then
            GOFlags._seen = GOFlags._seen + v
        end
        v = v * 2
    end
    if GOFlags._locked then return end
    if has(GOFlags._seen, GOFlags.PROVES_CLASSIC) then
        GOFlags._locked = "classic"
        return
    end
    for _, b in ipairs(GOFlags.PROVES_MODERN) do
        if has(GOFlags._seen, b) then
            GOFlags._locked = "modern"
            return
        end
    end
end

-- "modern" | "classic" | nil. nil means NOT YET PROVEN - never a default.
function GOFlags.mapping()
    return GOFlags._locked
end

-- The active table, or nil while unproven.
function GOFlags.table()
    if GOFlags._locked == "modern" then return GOFlags.MODERN end
    if GOFlags._locked == "classic" then return GOFlags.CLASSIC end
    return nil
end

local function flag(name)
    local t = GOFlags.table()
    return t and t[name] or nil
end

function GOFlags.sparkle() return flag("SPARKLE") end
function GOFlags.activate() return flag("ACTIVATE") end
function GOFlags.no_interact() return flag("NO_INTERACT") end

-- Does this low word mark an object worth approaching?
--   true  - proven mapping, and it is interactable/sparkling
--   false - proven mapping, and it is not
--   nil   - MAPPING NOT PROVEN: the caller must not guess from flags
function GOFlags.is_interesting(low)
    if type(low) ~= "number" then return nil end
    local sp, ac, ni = GOFlags.sparkle(), GOFlags.activate(), GOFlags.no_interact()
    if not (sp and ac and ni) then return nil end
    low = math.floor(low) % 65536
    if has(low, ni) then return false end   -- explicitly not interactable
    return has(low, sp) or has(low, ac)
end

-- WORTH APPROACHING, WITHOUT KNOWING WHICH BIT IS WHICH.
--
-- Making the quest-item witness wait on a PROVEN mapping was my mistake: the
-- decision it actually needs does not require one. Two facts are true under both
-- tables at once, and together they decide it:
--
--   1. A zero low word means the server set nothing on this object. 40 of 55
--      objects live were exactly that. Whatever the bits mean, "none of them"
--      is not a mark of interest.
--   2. NO_INTERACT is 0x04 under CLASSIC and 0x10 under MODERN. Refusing BOTH
--      is conservative under either table - the cost is skipping an object that
--      one table calls interactable, and the alternative is walking to something
--      the client has explicitly marked untouchable.
--
-- Anything else that is lit means the server singled this object out, and no
-- reading of either table turns that into "ignore me". So this answers true or
-- false ALWAYS - no abstention, no guess, and no dependency on the open
-- question. When the mapping IS proven it defers to the real flags instead.
GOFlags.NO_INTERACT_EITHER = { 0x04, 0x10 }

function GOFlags.worth_approaching(low)
    if type(low) ~= "number" then return false end
    low = math.floor(low) % 65536
    local decided = GOFlags.is_interesting(low)
    if decided ~= nil then return decided end     -- mapping proven: use it
    if low == 0 then return false end             -- server marked nothing
    for _, b in ipairs(GOFlags.NO_INTERACT_EITHER) do
        if has(low, b) then return false end      -- untouchable under some table
    end
    return true
end

-- PROOF FROM GROUND TRUTH.
--
-- Deduction from undefined bits settles most worlds, but not all: 0x08 is
-- SPARKLE under CLASSIC and ANIMATE under MODERN, so a world where 0x08 is the
-- only flag ever seen is genuinely undecidable from bits alone. Live data showed
-- exactly that - one object at 0x0008, every other gameobject 0x0000.
--
-- There is one sensor that can break the tie and it is not the client: a person
-- can SEE which object sparkles. So they name it, and we read the answer off it.
-- That is measurement, not opinion - the bit lit on a confirmed-sparkling object
-- IS sparkle, by definition.
--
-- Returns ok, detail. Refuses rather than guesses when the object's flags cannot
-- distinguish the two tables.
function GOFlags.prove_sparkling(low)
    if type(low) ~= "number" then return false, "no flags for that object" end
    low = math.floor(low) % 65536
    if low == 0 then
        return false, "that object has NO dynamic flags set - it cannot be the "
            .. "one that sparkles, so nothing can be concluded from it"
    end
    local m_sp, c_sp = GOFlags.MODERN.SPARKLE, GOFlags.CLASSIC.SPARKLE
    local m, c = has(low, m_sp), has(low, c_sp)
    if m and not c then
        GOFlags._locked = "modern"
        return true, string.format("0x%02X is lit -> MODERN mapping", m_sp)
    end
    if c and not m then
        GOFlags._locked = "classic"
        return true, string.format("0x%02X is lit -> CLASSIC mapping", c_sp)
    end
    if m and c then
        return false, "both candidate sparkle bits are lit - this object cannot "
            .. "separate the tables; try a different sparkling object"
    end
    return false, string.format("neither 0x%02X nor 0x%02X is lit on that object "
        .. "(flags 0x%04X) - it is not sparkling, or the field is wrong",
        m_sp, c_sp, low)
end

-- Persisted so the deduction is made once per server, not once per session.
function GOFlags.save()
    if not RaijinLabDB then return end
    RaijinLabDB.go_flag_mapping = GOFlags._locked
    RaijinLabDB.go_flag_seen = GOFlags._seen
end

function GOFlags.load()
    if not RaijinLabDB then return end
    local m = RaijinLabDB.go_flag_mapping
    if m == "modern" or m == "classic" then GOFlags._locked = m end
    local s = tonumber(RaijinLabDB.go_flag_seen)
    if s and s > 0 then GOFlags._seen = math.floor(s) % 65536 end
end

-- One line for diagnostics: what we have seen and what it proves.
-- WHAT THE EVIDENCE SO FAR POINTS AT, kept separate from what is PROVEN.
--
-- Three independent lines favour CLASSIC:
--   1. this is a 3.3.5a client, and TrinityCore's 3.3.5 branch defines
--      ACTIVATE=0x01 / SPARKLE=0x08 (the modern table came from a later branch,
--      which is also where this addon's wrong GameObjectTypes came from);
--   2. tools/find_sparkle_bit.py scans Ascension.exe itself: near a load from
--      the dynamic-flags offset, 0x01 is 2.18x enriched while MODERN's 0x04 is
--      depleted and MODERN-only 0x20/0x40/0x80 appear ZERO times - though 0x20
--      is tested 328 times elsewhere, so the client does use that constant;
--   3. the only flagged object seen live read 0x08 - SPARKLE under CLASSIC.
--
-- It is still NOT a proof: (2) is statistics over unlabelled code and 0x38 is a
-- common struct offset, and (3) is a single ambiguous observation. So this
-- CHANGES NOTHING about behaviour - the module still abstains until deduction or
-- `/raijin goflags <entry>` settles it. It is recorded so that when the live
-- answer arrives, agreeing with three prior lines is confirmation rather than
-- coincidence - and so that a DISAGREEMENT is treated as the alarm it would be.
GOFlags.EXPECTED = "classic"

function GOFlags.status()
    local bits, v = "", 1
    for _ = 1, 16 do
        if has(GOFlags._seen, v) then
            bits = bits .. (bits == "" and "" or "+") .. string.format("0x%02X", v)
        end
        v = v * 2
    end
    return string.format("mapping=%s seen=%s%s",
        tostring(GOFlags._locked or "UNPROVEN"),
        bits == "" and "(nothing)" or bits,
        GOFlags._locked and ""
            or (" - need 0x01 (proves classic) or 0x20/0x40/0x80 (proves modern)"
                .. "; binary + client version point at " .. GOFlags.EXPECTED))
end

return GOFlags
