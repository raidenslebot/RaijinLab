-- QuestInteract - the quest verbs beyond "kill it".
--
-- A large share of quests are not fights: pull the lever, loot the crate, use the
-- torch on the pyre, feed the bandage to the wounded soldier, plant the banner.
-- The engine could previously only kill things, walk to things, and talk to
-- things, so every one of those quests stalled.
--
-- Two capabilities live here:
--   * QUEST ITEMS - find the item this quest gave us and use it, optionally on a
--     specific target. The client tells us honestly which bag slots are quest
--     items (GetContainerItemQuestInfo), so we never guess from names.
--   * WORLD INTERACTION - classify what an objective actually wants (interact /
--     loot / use-item-on) from the quest log's own wording, so the engine picks
--     the right verb instead of assuming.

local QI = {}

local function lower(s) return string.lower(tostring(s or "")) end

-- ---- quest items in bags -------------------------------------------------

-- Every bag slot the CLIENT flags as a quest item. Returns
-- { {bag, slot, link, name, id, questId, active}, ... }.
-- Note the client's own flag is authoritative here - matching item names against
-- objective text would break on every localisation and every custom item.
function QI.quest_items()
    local out = {}
    if not (GetContainerNumSlots and GetContainerItemLink) then return out end
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local isQuest, questId, isActive = nil, nil, nil
                if GetContainerItemQuestInfo then
                    local ok, a, b, c = pcall(GetContainerItemQuestInfo, bag, slot)
                    if ok then isQuest, questId, isActive = a, b, c end
                end
                -- Fall back to the item's own type when the quest-info API is
                -- unavailable (some custom cores do not implement it).
                if isQuest == nil and GetItemInfo then
                    local _, _, _, _, _, itype = GetItemInfo(link)
                    isQuest = (itype == "Quest")
                end
                if isQuest then
                    local name = link:match("%[(.-)%]")
                    local id = tonumber(link:match("item:(%d+)"))
                    out[#out + 1] = {
                        bag = bag, slot = slot, link = link, name = name, id = id,
                        questId = questId, active = isActive,
                    }
                end
            end
        end
    end
    return out
end

-- The quest item belonging to `questId`, or (when the client does not tell us
-- which quest an item is for) the single active quest item we hold.
function QI.item_for_quest(questId)
    local items = QI.quest_items()
    if #items == 0 then return nil end
    questId = tonumber(questId)
    if questId then
        for _, it in ipairs(items) do
            if tonumber(it.questId) == questId then return it end
        end
    end
    -- Prefer one the client marks usable-right-now; otherwise, only fall back to
    -- a lone item. Guessing between several would use the wrong one.
    local active = {}
    for _, it in ipairs(items) do if it.active then active[#active + 1] = it end end
    if #active == 1 then return active[1] end
    if #items == 1 then return items[1] end
    return nil
end

-- Also match by NAME, because objective text like "Use the Smoldering Torch"
-- names the item directly.
function QI.item_by_name(name)
    if not name or name == "" then return nil end
    local want = lower(name)
    for _, it in ipairs(QI.quest_items()) do
        local n = lower(it.name)
        if n == want or n:find(want, 1, true) or want:find(n, 1, true) then return it end
    end
    return nil
end

-- Use a bag item, optionally on a unit. Target FIRST so the item applies to the
-- right thing, then use the slot. Returns true when we actually issued the use.
function QI.use_item(item, target_guid)
    if not item then return false, "no_item" end
    local A = RaijinLab and RaijinLab.Actions
    if target_guid and A and A.Target then pcall(A.Target, target_guid) end
    -- Prefer the runtime (C-origin, no taint); fall back to the stock call.
    if A and A.UseContainerItem then
        local ok = pcall(A.UseContainerItem, item.bag, item.slot)
        if ok then return true, "runtime" end
    end
    if UseContainerItem then
        local ok = pcall(UseContainerItem, item.bag, item.slot)
        if ok then return true, "stock" end
    end
    if UseItemByName and item.name then
        local ok = pcall(UseItemByName, item.name, target_guid and "target" or nil)
        if ok then return true, "byname" end
    end
    return false, "no_use_api"
end

-- ---- what does this objective actually want? -----------------------------

local USE_WORDS   = { "use ", "using ", "apply", "place", "plant", "pour", "feed",
                      "throw", "light", "ignite", "douse", "activate" }
local LOOT_WORDS  = { "loot", "collect", "gather", "retrieve", "recover", "obtain" }
local TALK_WORDS  = { "speak", "talk", "ask", "report to", "return to", "escort" }

local function has_word(hay, list)
    hay = lower(hay)
    for _, w in ipairs(list) do
        if hay:find(w, 1, true) then return true end
    end
    return false
end

-- Classify an objective into the verb the engine should use.
-- Returns "kill" | "loot" | "use_item" | "talk" | "interact".
-- The quest log's own wording is the most reliable signal we have on 3.3.5.
function QI.classify(o)
    if not o then return "interact" end
    local raw = o.raw or o.name or ""
    if o.kind == "kill" then return "kill" end
    if has_word(raw, USE_WORDS) then return "use_item" end
    if o.kind == "collect" then
        -- "collect" is ambiguous: it can mean loot-from-corpse or use-an-item.
        return has_word(raw, USE_WORDS) and "use_item" or "loot"
    end
    if has_word(raw, LOOT_WORDS) then return "loot" end
    if has_word(raw, TALK_WORDS) then return "talk" end
    if o.kind == "object" then return "interact" end
    return "interact"
end

-- Is this objective an escort? Escorts need following + defending rather than a
-- destination, so they are detected separately from the verb.
function QI.is_escort(q, o)
    local hay = lower((q and q.title or "") .. " " .. (o and (o.raw or o.name) or ""))
    return hay:find("escort", 1, true) ~= nil
        or hay:find("protect", 1, true) ~= nil
        or hay:find("defend", 1, true) ~= nil
        or hay:find("safety", 1, true) ~= nil
end

if RaijinLab then RaijinLab.QuestInteract = QI end
return QI
