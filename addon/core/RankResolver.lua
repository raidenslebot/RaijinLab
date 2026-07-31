-- Highest-known-rank resolver.
--
-- A rotation slot stores the EXACT spell id the user dragged from the spellbook -
-- a specific RANK. The native Spell_C_CastSpell(id) fires that rank verbatim, so
-- two things go wrong as you level: (1) after training a higher rank the rotation
-- keeps casting the weaker old one forever; (2) worse, once ONLY a higher rank is
-- learned, IsSpellKnown(oldRankId) is false, so the slot is gated "unknown" and
-- silently stops firing entirely.
--
-- This module maps a spell NAME -> the player's HIGHEST currently-known rank, so
-- both gating (esp. known-ness) and the actual cast always use your best rank.
-- It resolves LIVE and never persists into the slot: the dragged id stays the
-- stable identity (and the source of the name), and rank-ups are picked up for
-- free. Cost is one memoized table lookup per slot per tick; the spellbook is
-- only re-scanned when the client fires a spell-change event.

local RankResolver = {}

RankResolver._byName   = {}     -- lower(name) -> { id, rank, slot, rankText, ambiguous }
RankResolver._resolved = {}     -- storedId -> resolvedId  (memo, cleared on rebuild)
RankResolver._dirty    = true   -- rebuild on next highest() call

local function booktype() return (BOOKTYPE_SPELL or "spell") end

-- first run of digits in the rank text ("Rank 7" -> 7); no rank -> 0
local function parse_rank(s)
    if type(s) ~= "string" then return 0 end
    local n = s:match("(%d+)")
    return tonumber(n) or 0
end

local function trim_lower(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s:lower()
end

-- Scan the spellbook once, building name -> highest-rank entry. Bounded and
-- fully guarded so it is a harmless no-op with no client (headless harness).
function RankResolver.rebuild()
    local SU = RaijinLab and RaijinLab.SpellUtil
    local acc = {}    -- key -> { id, rank, slot, rankText, n(distinct ids), maxrank }
    if GetSpellName and GetSpellLink and SU and SU.spell_id_from_link then
        local bt = booktype()
        local i = 1
        while i <= 4096 do                     -- cap: never spin if nil never comes
            local name, rankText = GetSpellName(i, bt)
            if not name then break end
            local key = trim_lower(name)
            local id = SU.spell_id_from_link(GetSpellLink(i, bt))
            if key and id then
                local rank = parse_rank(rankText)
                local e = acc[key]
                if not e then
                    acc[key] = { id = id, rank = rank, slot = i, rankText = rankText,
                                 n = 1, maxrank = rank, ids = { [id] = true } }
                else
                    if not e.ids[id] then e.ids[id] = true; e.n = e.n + 1 end
                    if rank > e.maxrank then e.maxrank = rank end
                    -- higher rank wins; on a tie the LATER book slot wins (handles
                    -- custom schemes whose rank text isn't the stock "Rank N").
                    if rank > e.rank or (rank == e.rank and i > e.slot) then
                        e.id, e.rank, e.slot, e.rankText = id, rank, i, rankText
                    end
                end
            end
            i = i + 1
        end
    end
    local map = {}
    for key, e in pairs(acc) do
        -- If a name has two+ distinct ids and NONE carries a rank number, we can't
        -- tell a rank progression from two unrelated same-named abilities - pin
        -- (never remap) to be safe.
        map[key] = { id = e.id, rank = e.rank, slot = e.slot, rankText = e.rankText,
                     ambiguous = (e.n >= 2 and e.maxrank == 0) }
    end
    RankResolver._byName   = map
    RankResolver._resolved = {}
    RankResolver._dirty    = false
    return map
end

-- Resolve a stored id to the highest known rank of its spell name. Returns the
-- resolved id (== storedId when there's nothing better / not a spellbook entry /
-- ambiguous / feature disabled). Hot path: O(1) after a memoized rebuild.
function RankResolver.highest(storedId)
    storedId = tonumber(storedId) or 0
    if storedId == 0 then return 0 end
    if RaijinLabDB and RaijinLabDB.highest_rank == false then return storedId end
    if RankResolver._dirty then RankResolver.rebuild() end
    local m = RankResolver._resolved[storedId]
    if m ~= nil then return m end
    local name = GetSpellInfo and GetSpellInfo(storedId)
    local key = trim_lower(name)
    local e = key and RankResolver._byName[key]
    -- CONSERVATIVE BY CONSTRUCTION. Only ever swap the id when this is a genuine
    -- RANK UPGRADE of the same ability:
    --   * the spellbook entry must be unambiguous,
    --   * it must carry a real rank number (rank progression exists), and
    --   * the resolved id's name must be IDENTICAL to the stored one.
    -- On Ascension (classless, custom spells/ranks) a bare name lookup can
    -- otherwise land on a DIFFERENT ability - which would silently cast something
    -- the rotation never asked for. When in any doubt, cast exactly what was saved.
    local resolved = storedId
    if e and not e.ambiguous and (e.rank or 0) > 0 and e.id ~= storedId then
        local rname = GetSpellInfo and GetSpellInfo(e.id)
        if trim_lower(rname) == key then resolved = e.id end
    end
    RankResolver._resolved[storedId] = resolved
    return resolved
end

-- Richer lookup for UI: resolved id, its rank text, whether it changed, and a
-- status ("ok" | "ambiguous" | "unlisted"=not a spellbook entry).
function RankResolver.describe(storedId)
    local rid = RankResolver.highest(storedId)
    local name = GetSpellInfo and GetSpellInfo(storedId)
    local key = trim_lower(name)
    local e = key and RankResolver._byName[key]
    if not e then return rid, nil, false, "unlisted" end
    return rid, e.rankText, rid ~= (tonumber(storedId) or 0), e.ambiguous and "ambiguous" or "ok"
end

-- Register for spell-change events so a rank-up invalidates the cache lazily.
function RankResolver.init()
    RankResolver._dirty = true
    if RankResolver._frame or type(CreateFrame) ~= "function" then return end
    local f = CreateFrame("Frame")
    RankResolver._frame = f
    if f.RegisterEvent then
        f:RegisterEvent("SPELLS_CHANGED")
        f:RegisterEvent("LEARNED_SPELL_IN_TAB")
        f:RegisterEvent("PLAYER_LOGIN")
    end
    f:SetScript("OnEvent", function() RankResolver._dirty = true end)
end

if RaijinLab then RaijinLab.RankResolver = RankResolver end
return RankResolver
