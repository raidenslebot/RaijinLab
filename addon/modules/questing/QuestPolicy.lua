-- QuestPolicy - the rules that decide WHICH quests to do and in what order.
--
-- The engine knows how to execute a quest; this decides whether it should, which
-- one to pursue next, when to give up on one, and which reward to take. All of it
-- is data-driven from RaijinLabDB.quest.policy so the behaviour can be tuned per
-- character without touching code, and every decision returns a REASON so the
-- user can see why a quest was skipped rather than guessing.
--
-- Rules are evaluated most-specific first:
--   1. an explicit per-quest override (by id)          - always wins
--   2. title / zone pattern rules, in user order
--   3. category switches (elite / group / pvp / daily / dungeon / escort)
--   4. level window
--   5. the default
--
-- Nothing here talks to the client, so the whole decision layer is unit-testable.

local QuestPolicy = {}

local DEFAULTS = {
    -- category switches
    accept_elite = false, accept_group = false, accept_pvp = false,
    accept_dungeon = false, accept_raid = false, accept_escort = true,
    accept_daily = true, accept_profession = true,
    -- level window relative to the character; nil disables the bound
    min_level_delta = -8,      -- ignore quests this far BELOW us (grey, no value)
    max_level_delta = 4,       -- ignore quests this far ABOVE us (we would die)
    skip_trivial = false,      -- honour min_level_delta at all
    -- ordering
    order = "smart",           -- smart | nearest | lowest_level | log_order | manual
    -- give-up rules
    max_attempts = 3,          -- objective attempts before parking a quest
    abandon_on_unreachable = false,
    -- rewards
    reward_policy = "quality", -- quality | vendor | first | manual | usable
    -- explicit rules
    blacklist_ids = {},        -- [questId] = true            (never take)
    whitelist_ids = {},        -- [questId] = true            (always take)
    title_rules = {},          -- { {pattern="Escort", accept=false}, ... }
    manual_order = {},         -- { questId, questId, ... }   (order == "manual")
}

function QuestPolicy.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.quest = RaijinLabDB.quest or {}
    local p = RaijinLabDB.quest.policy or {}
    RaijinLabDB.quest.policy = p
    for k, v in pairs(DEFAULTS) do
        if p[k] == nil then
            if type(v) == "table" then p[k] = {} else p[k] = v end
        end
    end
    return p
end

QuestPolicy.DEFAULTS = DEFAULTS

local function lower(s) return string.lower(tostring(s or "")) end

-- Category detection from whatever the quest log gave us. Kept permissive: a
-- custom server may tag things differently, and a missing tag must never be
-- treated as a positive match.
local function is_cat(q, cat)
    if not q then return false end
    if q[cat] == true then return true end
    local tag = lower(q.tag or q.type or "")
    local title = lower(q.title)
    if cat == "elite" then return tag:find("elite", 1, true) ~= nil end
    if cat == "group" then return tag:find("group", 1, true) ~= nil or (tonumber(q.suggested_group) or 0) > 1 end
    if cat == "pvp" then return tag:find("pvp", 1, true) ~= nil end
    if cat == "dungeon" then return tag:find("dungeon", 1, true) ~= nil end
    if cat == "raid" then return tag:find("raid", 1, true) ~= nil end
    if cat == "daily" then return q.daily == true or tag:find("daily", 1, true) ~= nil end
    if cat == "profession" then return tag:find("profession", 1, true) ~= nil end
    if cat == "escort" then return title:find("escort", 1, true) ~= nil end
    return false
end
QuestPolicy._is_cat = is_cat

-- Should we accept / pursue this quest? Returns accept(bool), reason(string).
function QuestPolicy.should_accept(q, opts)
    opts = opts or {}
    local p = QuestPolicy.cfg()
    if not q then return false, "no_quest" end
    local id = tonumber(q.id) or 0

    -- 1. explicit per-quest overrides always win
    if id ~= 0 and p.blacklist_ids[id] then return false, "blacklisted" end
    if id ~= 0 and p.whitelist_ids[id] then return true, "whitelisted" end

    -- 2. title / zone pattern rules, in the order the user wrote them
    for _, rule in ipairs(p.title_rules or {}) do
        local pat = rule.pattern
        if pat and pat ~= "" then
            local hay = lower(rule.field == "zone" and q.zone or q.title)
            local ok, found = pcall(string.find, hay, lower(pat), 1, rule.plain ~= false)
            if ok and found then
                return rule.accept ~= false, "rule:" .. tostring(pat)
            end
        end
    end

    -- 3. category switches
    local cats = { "raid", "dungeon", "pvp", "group", "elite", "escort", "profession", "daily" }
    for _, c in ipairs(cats) do
        if is_cat(q, c) and p["accept_" .. c] == false then
            return false, "category:" .. c
        end
    end

    -- 4. level window
    local plevel = tonumber(opts.player_level) or (UnitLevel and UnitLevel("player")) or 0
    local qlevel = tonumber(q.level) or 0
    if plevel > 0 and qlevel > 0 then
        local delta = qlevel - plevel
        if p.max_level_delta and delta > p.max_level_delta then
            return false, "too_high"
        end
        if p.skip_trivial and p.min_level_delta and delta < p.min_level_delta then
            return false, "trivial"
        end
    end
    return true, "ok"
end

-- Park a quest we cannot make progress on, so the engine moves to another one
-- instead of grinding forever against the same wall.
function QuestPolicy.should_park(q, state)
    local p = QuestPolicy.cfg()
    state = state or {}
    if (tonumber(state.attempts) or 0) >= (p.max_attempts or 3) then
        return true, "max_attempts"
    end
    if state.unreachable and p.abandon_on_unreachable then
        return true, "unreachable"
    end
    return false, nil
end

-- Order the quests we hold, best-first. `opts.dist_of(q) -> yards|nil` lets the
-- caller supply real distances (from POI memory or live objectives) without this
-- module needing the world.
function QuestPolicy.rank(quests, opts)
    opts = opts or {}
    local p = QuestPolicy.cfg()
    local list = {}
    for i, q in ipairs(quests or {}) do list[#list + 1] = { q = q, i = i } end

    local order = opts.order or p.order or "smart"
    local dist_of = opts.dist_of
    local plevel = tonumber(opts.player_level) or (UnitLevel and UnitLevel("player")) or 0

    local function dist(e)
        if not dist_of then return nil end
        local ok, d = pcall(dist_of, e.q)
        if ok and type(d) == "number" then return d end
        return nil
    end

    if order == "log_order" then
        -- keep as-is
    elseif order == "manual" then
        local rank = {}
        for idx, id in ipairs(p.manual_order or {}) do rank[tonumber(id) or -1] = idx end
        table.sort(list, function(a, b)
            local ra = rank[tonumber(a.q.id) or -1] or 1e6
            local rb = rank[tonumber(b.q.id) or -1] or 1e6
            if ra ~= rb then return ra < rb end
            return a.i < b.i
        end)
    elseif order == "lowest_level" then
        table.sort(list, function(a, b)
            local la, lb = tonumber(a.q.level) or 0, tonumber(b.q.level) or 0
            if la ~= lb then return la < lb end
            return a.i < b.i
        end)
    elseif order == "nearest" then
        table.sort(list, function(a, b)
            local da, db = dist(a) or math.huge, dist(b) or math.huge
            if da ~= db then return da < db end
            return a.i < b.i
        end)
    else
        -- SMART: finish what is already complete (free turn-in), then prefer
        -- quests that are close and already part-done, and push risky/high-level
        -- ones back. This is what a human does: bank the easy wins first.
        local function score(e)
            local q = e.q
            local s = 0
            if q.complete then s = s - 1000 end
            local prog = tonumber(q.progress_frac)
            if prog then s = s - prog * 200 end
            local d = dist(e)
            if d then s = s + math.min(d, 4000) / 40 end
            local ql = tonumber(q.level) or 0
            if plevel > 0 and ql > 0 then
                local delta = ql - plevel
                if delta > 0 then s = s + delta * 12 end     -- harder = later
            end
            if is_cat(q, "elite") or is_cat(q, "group") then s = s + 150 end
            return s
        end
        table.sort(list, function(a, b)
            local sa, sb = score(a), score(b)
            if sa ~= sb then return sa < sb end
            return a.i < b.i
        end)
    end

    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.q end
    return out
end

-- Which reward to take. `rewards` = { {index, name, quality, sell, usable}, ... }
-- Returns index (1-based) or nil to leave it to the player.
function QuestPolicy.reward_choice(q, rewards, opts)
    opts = opts or {}
    local p = QuestPolicy.cfg()
    rewards = rewards or {}
    if #rewards == 0 then return nil, "no_rewards" end
    if #rewards == 1 then return rewards[1].index or 1, "only" end

    local id = tonumber(q and q.id) or 0
    local forced = p.reward_by_quest and p.reward_by_quest[id]
    if forced then return forced, "forced" end

    local mode = opts.policy or p.reward_policy or "quality"
    if mode == "manual" then return nil, "manual" end
    if mode == "first" then return rewards[1].index or 1, "first" end

    local best, bestv, why = nil, -math.huge, mode
    for _, r in ipairs(rewards) do
        local v
        if mode == "vendor" then v = tonumber(r.sell) or 0
        elseif mode == "usable" then
            -- prefer something this character can actually equip/use, then quality
            v = ((r.usable and 1000) or 0) + (tonumber(r.quality) or 0) * 10 + (tonumber(r.sell) or 0) / 1000
        else
            v = (tonumber(r.quality) or 0) * 1000 + (tonumber(r.sell) or 0) / 1000
        end
        if v > bestv then best, bestv = r, v end
    end
    if not best then return nil, "none" end
    return best.index or 1, why
end

-- Convenience for the UI / chat: explain the current policy in one line.
function QuestPolicy.describe()
    local p = QuestPolicy.cfg()
    local off = {}
    for _, c in ipairs({ "elite", "group", "pvp", "dungeon", "raid", "escort", "daily", "profession" }) do
        if p["accept_" .. c] == false then off[#off + 1] = c end
    end
    local nbl, nwl, nr = 0, 0, 0
    for _ in pairs(p.blacklist_ids or {}) do nbl = nbl + 1 end
    for _ in pairs(p.whitelist_ids or {}) do nwl = nwl + 1 end
    for _ in ipairs(p.title_rules or {}) do nr = nr + 1 end
    return string.format(
        "order=%s reward=%s levels=[%s..%s] skipping=[%s] rules=%d blacklist=%d whitelist=%d",
        tostring(p.order), tostring(p.reward_policy),
        tostring(p.min_level_delta), tostring(p.max_level_delta),
        table.concat(off, ","), nr, nbl, nwl)
end

if RaijinLab then RaijinLab.QuestPolicy = QuestPolicy end
return QuestPolicy
