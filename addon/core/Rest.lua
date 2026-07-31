-- Rest - eating and drinking back to fighting shape.
--
-- Without this the bot has exactly two failure modes: it fights on at 15% health
-- until something kills it, or it stands at full-idle forever because nothing
-- ever restores its mana. Both look and behave nothing like a player.
--
-- The rules a person actually follows:
--   * only rest OUT of combat, and abandon the meal the instant something pulls;
--   * only drink if you actually have a mana bar worth filling - most classes on
--     a custom server may not, so this is decided from the POWER BAR, never from
--     a class name;
--   * eat and drink together when you need both (they stack);
--   * pick the best consumable you own that your level can actually use;
--   * sit down (it restores faster), and get up when you are done.
--
-- Food detection has to survive a custom server, so it is layered: the item's own
-- type first, then a learned per-character list, then a tooltip/name heuristic.
-- An item we cannot classify is simply never eaten - guessing would burn quest
-- items or reagents.

local Rest = {}

local floor, min, max = math.floor, math.min, math.max

Rest.DEFAULTS = {
    rest_hp     = 55,    -- % health below which we eat
    rest_mana   = 45,    -- % mana below which we drink
    rest_to     = 92,    -- % to recover to before moving on
    min_level_gap = 0,   -- consumables above our level are unusable
    max_wait    = 45,    -- s: never sit forever if nothing is recovering
}

Rest._state = "idle"
Rest._t0 = 0

local function now() return (GetTime and GetTime()) or 0 end

function Rest.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.rest = RaijinLabDB.rest or {}
    local c = RaijinLabDB.rest
    for k, v in pairs(Rest.DEFAULTS) do if c[k] == nil then c[k] = v end end
    c.food_ids = c.food_ids or {}
    c.drink_ids = c.drink_ids or {}
    c.never_ids = c.never_ids or {}
    return c
end

-- ---- vitals --------------------------------------------------------------

function Rest.hp_pct()
    if not (UnitHealth and UnitHealthMax) then return 100 end
    local mx = UnitHealthMax("player") or 0
    if mx <= 0 then return 100 end
    return (UnitHealth("player") or 0) / mx * 100
end

-- Mana is decided from the POWER BAR, not the class: on a classless/custom server
-- a "warrior-like" build may still have mana and a caster may not.
function Rest.is_mana_user()
    if not (UnitPowerMax) then return false end
    local ok, mx = pcall(UnitPowerMax, "player", 0)   -- 0 = mana
    return ok and (tonumber(mx) or 0) > 0
end

function Rest.mana_pct()
    if not (UnitPower and UnitPowerMax) then return 100 end
    local ok, mx = pcall(UnitPowerMax, "player", 0)
    if not ok or (tonumber(mx) or 0) <= 0 then return 100 end
    local _, cur = pcall(UnitPower, "player", 0)
    return (tonumber(cur) or 0) / mx * 100
end

-- ---- consumable classification ------------------------------------------

local FOOD_WORDS  = { "bread", "meat", "cheese", "fish", "ration", "biscuit",
                      "pie", "stew", "apple", "banana", "conjured", "food", "jerky" }
local DRINK_WORDS = { "water", "juice", "milk", "wine", "ale", "tea", "drink",
                      "conjured water" }

local function lower(s) return string.lower(tostring(s or "")) end
local function has_word(hay, list)
    hay = lower(hay)
    for _, w in ipairs(list) do if hay:find(w, 1, true) then return true end end
    return false
end

-- Classify one item into "food" | "drink" | nil.
-- `info` = { id, name, itemType, itemSubType, level }
function Rest.classify(info, c)
    c = c or Rest.cfg()
    if not info then return nil end
    local id = tonumber(info.id)
    if id and c.never_ids[id] then return nil end
    if id and c.food_ids[id] then return "food" end
    if id and c.drink_ids[id] then return "drink" end

    local sub = lower(info.itemSubType)
    local typ = lower(info.itemType)
    -- 3.3.5 groups both under Consumable / "Food & Drink", so the subtype alone
    -- does not separate them - fall through to the name for that.
    -- A KNOWN non-consumable type disqualifies outright: no subtype should ever
    -- be able to make a sword edible. Only an absent/unknown type falls through
    -- to the subtype+name evidence below.
    if typ ~= "" and typ ~= "consumable" then return nil end
    local consumable = (typ == "consumable") or sub:find("food", 1, true) or sub:find("drink", 1, true)
    if not consumable then return nil end

    local name = lower(info.name)
    -- DRINK is checked first because the subtype cannot separate the two: 3.3.5
    -- files both under "Food & Drink", and drinks are the smaller, far more
    -- recognisable set (water/juice/milk/wine/ale/tea).
    if has_word(name, DRINK_WORDS) then return "drink" end
    -- The SUBTYPE is authoritative when the client gives us one - relying on a
    -- food-name list would silently miss anything not in it (jerky, kimchi, any
    -- custom server item), which is exactly the sort of gap that leaves the bot
    -- starving next to a full bag.
    if sub:find("food", 1, true) or sub:find("drink", 1, true) then return "food" end
    if has_word(name, FOOD_WORDS) then return "food" end
    return nil
end

-- Every usable consumable in our bags, split by kind and sorted best-first.
-- "Best" is the highest required level we can actually use - on this client that
-- reliably tracks restore amount without needing a tooltip scan.
function Rest.find_consumables()
    local out = { food = {}, drink = {} }
    if not (GetContainerNumSlots and GetContainerItemLink) then return out end
    local c = Rest.cfg()
    local plevel = (UnitLevel and UnitLevel("player")) or 0
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = tonumber(link:match("item:(%d+)"))
                local name, _, _, _, reqLevel, itemType, itemSubType
                if GetItemInfo then
                    local ok, a, _, _, d, e, f, g = pcall(GetItemInfo, link)
                    if ok then name, reqLevel, itemType, itemSubType = a, e, f, g end
                end
                if not name then name = link:match("%[(.-)%]") end
                local kind = Rest.classify({ id = id, name = name,
                    itemType = itemType, itemSubType = itemSubType }, c)
                if kind then
                    local req = tonumber(reqLevel) or 0
                    if plevel == 0 or req <= plevel then
                        out[kind][#out[kind] + 1] = {
                            bag = bag, slot = slot, id = id, name = name, req = req,
                        }
                    end
                end
            end
        end
    end
    local function best_first(t) table.sort(t, function(a, b) return (a.req or 0) > (b.req or 0) end) end
    best_first(out.food); best_first(out.drink)
    return out
end

-- ---- the decision --------------------------------------------------------

-- Pure: what do we need right now? Returns need_food, need_drink.
function Rest.needs(hp, mana, mana_user, c)
    c = c or Rest.cfg()
    local need_food  = (tonumber(hp) or 100) < (c.rest_hp or 55)
    local need_drink = mana_user and ((tonumber(mana) or 100) < (c.rest_mana or 45)) or false
    return need_food, need_drink
end

-- Are we recovered enough to get moving again?
function Rest.recovered(hp, mana, mana_user, c)
    c = c or Rest.cfg()
    local target = c.rest_to or 92
    if (tonumber(hp) or 100) < target then return false end
    if mana_user and (tonumber(mana) or 100) < target then return false end
    return true
end

-- Three-valued form: unknown if we cannot read vitals APIs at all.
function Rest.should_rest_k()
    local Kn = RaijinLab and RaijinLab.Know
    if UnitIsDeadOrGhost then
        local ok, dead = pcall(UnitIsDeadOrGhost, "player")
        if ok and dead then
            if Kn then return Kn.no("dead") end
            return false, "dead"
        end
    end
    if UnitAffectingCombat then
        local ok, combat = pcall(UnitAffectingCombat, "player")
        if ok and combat then
            if Kn then return Kn.no("combat") end
            return false, "combat"
        end
    end
    if not (UnitHealth and UnitHealthMax) then
        if Kn then return Kn.unknown("no_health_api") end
        return nil, "no_health_api"
    end
    local c = Rest.cfg()
    local hp, mana = Rest.hp_pct(), Rest.mana_pct()
    local mu = Rest.is_mana_user()
    local nf, nd = Rest.needs(hp, mana, mu, c)
    if not (nf or nd) then
        if Kn then return Kn.no("healthy") end
        return false, "healthy"
    end
    local why = nf and (nd and "food+drink" or "food") or "drink"
    if Kn then return Kn.yes(why, why) end
    return true, why
end

function Rest.should_rest()
    local k, why = Rest.should_rest_k()
    if type(k) == "table" and k.state then
        if k.state == "yes" then return true, k.value or k.why end
        if k.state == "no" then return false, k.why or "no" end
        -- Unknown: do not sit forever on missing APIs.
        return false, "unknown"
    end
    return k, why
end

-- ---- doing it ------------------------------------------------------------

local function use_item(it)
    if not it then return false end
    local A = RaijinLab and RaijinLab.Actions
    if A and A.UseContainerItem then
        local ok = pcall(A.UseContainerItem, it.bag, it.slot)
        if ok then return true end
    end
    if UseContainerItem then
        local ok = pcall(UseContainerItem, it.bag, it.slot)
        if ok then return true end
    end
    return false
end

-- One rest step. Returns a status string while it is in control, or nil when
-- there is nothing to do (so the caller carries on).
-- ctx.stop_fn halts movement; eating while running does nothing.
function Rest.tick(ctx)
    ctx = ctx or {}
    -- Combat always wins: drop the meal immediately.
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        Rest._state = "idle"
        return nil
    end
    local c = Rest.cfg()
    local hp, mana = Rest.hp_pct(), Rest.mana_pct()
    local mu = Rest.is_mana_user()

    if Rest._state == "resting" then
        -- Finished, or waited long enough that nothing is coming back.
        if Rest.recovered(hp, mana, mu, c) then
            Rest._state = "idle"
            return "rest:recovered"
        end
        if (now() - (Rest._t0 or 0)) > (c.max_wait or 45) then
            Rest._state = "idle"
            return "rest:gave up waiting"
        end
        return string.format("rest:recovering (hp %.0f%%%s)", hp,
            mu and string.format(" mana %.0f%%", mana) or "")
    end

    local ok, why = Rest.should_rest()
    if not ok then return nil end

    local nf, nd = Rest.needs(hp, mana, mu, c)
    local items = Rest.find_consumables()
    -- Check we can actually act BEFORE cancelling movement: a no-food tick used to
    -- stop the character dead and then hold the slot, which is the worst of both.
    local have = (nf and items.food[1]) or (nd and items.drink[1])
    if not have then
        -- CRITICAL: return NIL, not a status. Rest sits in band 4 and the vendor
        -- errand that would buy food sits in band 5 - holding this slot starved
        -- the only goal that could resolve the situation, so the bot sat hungry
        -- next to a merchant forever. Releasing lets the errand run.
        Rest._no_consumables_t = now()
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then Tel.warn("rest", "no_consumables", { need = why,
            hp = math.floor(hp), mana = mu and math.floor(mana) or nil }) end
        return nil
    end
    local ate = false
    if ctx.stop_fn then ctx.stop_fn() end
    -- Food and drink stack, so when we need both we consume both.
    if nf and items.food[1] then ate = use_item(items.food[1]) or ate end
    if nd and items.drink[1] then ate = use_item(items.drink[1]) or ate end
    if not ate then return nil end
    -- Sitting speeds recovery considerably.
    if SitStandOrDescendStart then pcall(SitStandOrDescendStart) end
    Rest._state = "resting"
    Rest._t0 = now()
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel then Tel.info("rest", "eating", { need = why, hp = math.floor(hp),
        mana = mu and math.floor(mana) or nil,
        food = items.food[1] and items.food[1].name or nil,
        drink = items.drink[1] and items.drink[1].name or nil }) end
    return "rest:eating (" .. tostring(why) .. ")"
end

function Rest.reset() Rest._state = "idle" end

function Rest.stats()
    local items = Rest.find_consumables()
    return { state = Rest._state, hp = Rest.hp_pct(),
             mana_user = Rest.is_mana_user(), mana = Rest.mana_pct(),
             food = #items.food, drink = #items.drink }
end

if RaijinLab then RaijinLab.Rest = Rest end
return Rest
