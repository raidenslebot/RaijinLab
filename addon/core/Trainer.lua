-- Trainer - learning new spells and higher ranks.
--
-- This is the SOURCE fix for the rank problem. RankResolver makes the rotation
-- cast the best rank the character currently knows; this makes the character
-- actually go and learn better ones. Without it a levelling bot fights forever
-- with rank 1 abilities no matter how clever the caster is.
--
-- Money discipline matters: training is often the largest recurring cost, and a
-- character with no repair money is a character that stops working. So a reserve
-- is always kept back, and the cheapest useful services are taken first so a
-- limited purse buys the most progress.

local Trainer = {}

local floor, max = math.floor, math.max

Trainer.DEFAULTS = {
    enabled       = true,
    reserve       = 200000,   -- copper kept back (20g) for repairs/food
    max_per_visit = 40,       -- sanity cap on purchases in one sitting
    skip_costly   = false,    -- when true, never spend more than half the purse
}

Trainer._learned = 0

local function now() return (GetTime and GetTime()) or 0 end

-- Tuning knobs are shared, but PROGRESS is per character: last_level lived in the
-- account-wide table, so the moment one character trained, every alt believed it
-- had already visited at that level and never trained again.
local function char_key()
    local n = (UnitName and UnitName("player")) or "?"
    local r = (GetRealmName and GetRealmName()) or "?"
    return n .. "@" .. r
end

function Trainer.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.trainer = RaijinLabDB.trainer or {}
    local c = RaijinLabDB.trainer
    for k, v in pairs(Trainer.DEFAULTS) do if c[k] == nil then c[k] = v end end
    c.skip_names = c.skip_names or {}
    -- per-character progress bucket, merged onto the shared settings view
    c.chars = c.chars or {}
    local ck = char_key()
    c.chars[ck] = c.chars[ck] or {}
    local mine = c.chars[ck]
    c._mine = mine
    return c
end

-- Explicit accessors rather than mirroring the fields onto the shared table:
-- a merged view would silently discard `cfg().last_level = x`, which is exactly
-- the kind of write that looks fine and quietly does nothing.
function Trainer.last_level()
    local c = Trainer.cfg()
    return (c._mine and c._mine.last_level) or 0
end
function Trainer.set_last_level(v)
    local c = Trainer.cfg()
    if c._mine then c._mine.last_level = tonumber(v) or 0; c._mine.last_t = now() end
end

function Trainer.at_trainer_k()
    local Kn = RaijinLab and RaijinLab.Know
    if ClassTrainerFrame and ClassTrainerFrame.IsShown then
        local ok, shown = pcall(ClassTrainerFrame.IsShown, ClassTrainerFrame)
        if ok and shown then
            if Kn then return Kn.yes(true, "ClassTrainerFrame") end
            return true
        end
        if ok and not shown then
            -- Fall through: custom UIs may not use this frame.
        elseif not ok then
            if Kn then return Kn.unknown("frame_error") end
        end
    end
    if GetNumTrainerServices then
        local ok, n = pcall(GetNumTrainerServices)
        if ok and (tonumber(n) or 0) > 0 then
            if Kn then return Kn.yes(true, "services") end
            return true
        end
        if ok then
            if Kn then return Kn.no("no_services") end
            return false
        end
        if Kn then return Kn.unknown("services_error") end
        return nil
    end
    if Kn then return Kn.unknown("no_trainer_api") end
    return nil
end

function Trainer.at_trainer()
    local k = Trainer.at_trainer_k()
    local Kn = RaijinLab and RaijinLab.Know
    if Kn and Kn.assume then
        return Kn.assume(k, false, "trainer:not_at_when_unknown")
    end
    if type(k) == "table" and k.state then return k.state == "yes" end
    return not not k
end

-- Everything this trainer offers that we can actually learn right now.
-- Returns { {index, name, rank, cost, available}, ... }, cheapest first.
function Trainer.services()
    local out = {}
    if not (GetNumTrainerServices and GetTrainerServiceInfo) then return out end
    local ok, n = pcall(GetNumTrainerServices)
    if not ok or not n then return out end
    local c = Trainer.cfg()
    for i = 1, n do
        local ok2, name, rank, category, expanded = pcall(GetTrainerServiceInfo, i)
        if ok2 and name and category ~= "header" then
            -- "available" = affordable + level requirement met. Anything else
            -- ("unavailable" / "used") must not be attempted.
            local cost = 0
            if GetTrainerServiceCost then
                local ok3, v = pcall(GetTrainerServiceCost, i)
                if ok3 then cost = tonumber(v) or 0 end
            end
            if not c.skip_names[name] then
                out[#out + 1] = { index = i, name = name, rank = rank,
                                  cost = cost, available = (category == "available") }
            end
        end
    end
    -- Cheapest first: a limited purse should buy the most abilities, and the
    -- expensive ones are usually still there next visit.
    table.sort(out, function(a, b) return (a.cost or 0) < (b.cost or 0) end)
    return out
end

-- What we could afford, in order, without dipping into the reserve.
function Trainer.affordable()
    local c = Trainer.cfg()
    local money = (GetMoney and GetMoney()) or 0
    local budget = max(0, money - (c.reserve or 0))
    if c.skip_costly then budget = math.min(budget, floor(money / 2)) end
    local out = {}
    for _, s in ipairs(Trainer.services()) do
        if s.available and (s.cost or 0) <= budget then
            out[#out + 1] = s
            budget = budget - (s.cost or 0)
        end
    end
    return out
end

-- Buy everything we can afford. Only ever called with the trainer window open.
-- Returns count learned, total spent.
function Trainer.train_all()
    if not Trainer.at_trainer() then return 0, 0, "no_trainer" end
    local c = Trainer.cfg()
    if not c.enabled then return 0, 0, "disabled" end
    if not BuyTrainerService then return 0, 0, "no_api" end
    local list = Trainer.affordable()
    local n, spent = 0, 0
    for _, s in ipairs(list) do
        if n >= (c.max_per_visit or 40) then break end
        local ok = pcall(BuyTrainerService, s.index)
        if ok then
            n = n + 1
            spent = spent + (s.cost or 0)
        end
    end
    Trainer._learned = (Trainer._learned or 0) + n
    if n > 0 then
        -- New ranks mean the rotation's rank map is stale; force a rebuild so the
        -- executor starts using what we just learned immediately.
        local RR = RaijinLab and RaijinLab.RankResolver
        if RR then RR._dirty = true end
    end
    return n, spent
end

-- Is a trip worth it? We only know what a trainer offers while standing at one,
-- so this is a heuristic: having levelled since the last visit is the signal.
function Trainer.needs_training_k()
    local Kn = RaijinLab and RaijinLab.Know
    local c = Trainer.cfg()
    if not c.enabled then
        if Kn then return Kn.no("disabled") end
        return false, "disabled"
    end
    if not UnitLevel then
        if Kn then return Kn.unknown("no_level_api") end
        return nil, "no_level_api"
    end
    local ok, lvl = pcall(UnitLevel, "player")
    if not ok then
        if Kn then return Kn.unknown("level_error") end
        return nil, "level_error"
    end
    lvl = tonumber(lvl) or 0
    local last = Trainer.last_level()
    if lvl > last + 1 then
        local money = 0
        if GetMoney then
            local okm, m = pcall(GetMoney)
            if okm then money = tonumber(m) or 0 end
        end
        if money <= (c.reserve or 0) then
            if Kn then return Kn.no("too_poor") end
            return false, "too_poor"
        end
        if Kn then return Kn.yes({ why = "levelled", level = lvl }, "levelled") end
        return true, "levelled"
    end
    if Kn then return Kn.no("up_to_date") end
    return false, nil
end

function Trainer.needs_training()
    local k, why = Trainer.needs_training_k()
    if type(k) == "table" and k.state then
        if k.state == "yes" then
            local v = k.value
            return true, (type(v) == "table" and v.why) or k.why or "levelled"
        end
        if k.state == "no" then return false, k.why end
        return false, "unknown"
    end
    return k, why
end

-- Remember that we visited at this level, so we do not keep walking back.
function Trainer.note_visit()
    Trainer.set_last_level((UnitLevel and UnitLevel("player")) or Trainer.last_level())
end

function Trainer.stats()
    local svc = Trainer.at_trainer() and Trainer.services() or {}
    local aff = Trainer.at_trainer() and Trainer.affordable() or {}
    local need, why = Trainer.needs_training()
    return { at_trainer = Trainer.at_trainer(), offered = #svc, affordable = #aff,
             learned_total = Trainer._learned or 0, needs = need, reason = why,
             last_level = Trainer.last_level() }
end

if RaijinLab then RaijinLab.Trainer = Trainer end
return Trainer
