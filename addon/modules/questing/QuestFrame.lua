-- Quest / gossip FRAME automation on stock WoW 3.3.5a APIs.
--
-- Everything that happens once a quest window is already open: greet an NPC,
-- accept an offered quest, hand one in, and pick a reward. This is deliberately
-- EVENT-driven (the engine registers these on QUEST_GREETING / GOSSIP_SHOW /
-- QUEST_DETAIL / QUEST_PROGRESS / QUEST_COMPLETE) rather than polling frame
-- visibility, so it reacts the same frame the server opens the window and can't
-- double-fire. Pure decision helpers (should_accept / pick_reward) are split out
-- so they're unit-testable without a live client.

local QF = {}

local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.quest = RaijinLabDB.quest or {}
    return RaijinLabDB.quest
end

-- ---- pure decision helpers (unit-tested) ---------------------------------

-- Reward selection policy for a quest that forces a CHOICE (GetNumQuestChoices
-- > 0). `choices` is a list of { quality, isUsable, link } gathered from
-- GetQuestItemInfo. Returns the 1-based choice index to take.
--   policy "quality" (default): highest item quality, then first usable, then 1.
--   policy "first": always index 1 (matches the old behavior).
--   a numeric cfg.reward_index pins a fixed slot.
-- Never returns nil when there is at least one choice - an unattended quester
-- MUST pick something to proceed.
function QF.pick_reward(choices, policy, forced_index)
    local n = choices and #choices or 0
    if n == 0 then return nil end
    if type(forced_index) == "number" and forced_index >= 1 and forced_index <= n then
        return forced_index
    end
    policy = tostring(policy or "quality"):lower()
    -- Richer policies (vendor value, usable-first, per-quest forced) live in
    -- QuestPolicy; use them when available. "manual" is the one case where
    -- returning nil is correct - but an UNATTENDED quester must still proceed, so
    -- we only honour a nil when the caller explicitly asked for manual.
    local QP = RaijinLab and RaijinLab.QuestPolicy
    if QP and QP.reward_choice and policy ~= "quality" and policy ~= "first" then
        local rewards = {}
        for i = 1, n do
            local c = choices[i] or {}
            rewards[#rewards + 1] = { index = i, quality = c.quality,
                                      sell = c.sell or c.sellPrice, usable = c.isUsable }
        end
        local ok, idx = pcall(QP.reward_choice, nil, rewards, { policy = policy })
        if ok and type(idx) == "number" then return idx end
        if ok and idx == nil and policy == "manual" then return nil end
    end
    if policy == "first" then return 1 end
    -- "quality": maximize quality; prefer a usable item on ties; then lowest index.
    local best, besti = nil, 1
    for i = 1, n do
        local c = choices[i] or {}
        local q = tonumber(c.quality) or 0
        local score = q * 10 + (c.isUsable and 1 or 0)
        if best == nil or score > best then best = score; besti = i end
    end
    return besti
end

-- Whether to accept an offered quest given what little the client exposes at
-- offer time. `info` = { isTrivial, isDaily, isRepeatable, tag, group }. Most of
-- these are nil at QUEST_DETAIL on 3.3.5 (only gossip lists expose isTrivial/
-- isDaily); we accept by default and only refuse on an explicit opt-out so the
-- bot never silently stalls in front of a quest it "decided" to skip.
function QF.should_accept(info)
    info = info or {}
    local c = cfg()
    -- The policy engine is the richer authority (per-quest overrides, title/zone
    -- rules, level window, category switches) and it explains itself. Fall back to
    -- the simple switches below when it is not loaded, so nothing depends on it.
    local QP = RaijinLab and RaijinLab.QuestPolicy
    if QP and QP.should_accept then
        local ok, accept, why = pcall(QP.should_accept, {
            id = info.questId or info.id,
            title = info.title,
            level = info.level,
            zone = info.zone,
            tag = info.tag,
            daily = info.isDaily,
            suggested_group = info.group,
        })
        if ok and accept == false then
            local DL = RaijinLab.DevLog
            if DL then DL.log("quest", "policy refused %s (%s)",
                tostring(info.title or info.questId or "?"), tostring(why)) end
            return false
        end
        if ok and accept == true and why == "whitelisted" then return true end
    end
    if c.skip_trivial == true and info.isTrivial then return false end
    if c.accept_daily == false and info.isDaily then return false end
    local tag = tostring(info.tag or "")
    if c.accept_elite ~= true
        and (tag == "Elite" or tag == "Dungeon" or tag == "Raid" or tag == "Group") then
        return false
    end
    if c.accept_pvp ~= true and tag == "PvP" then return false end
    if c.accept_group ~= true and (tonumber(info.group) or 0) > 0 then return false end
    return true
end

-- ---- live frame drivers (one per quest event) ----------------------------

-- QUEST_GREETING: some NPCs use the older "greeting" frame with lists of
-- available/active quests instead of gossip. Turn in first, else accept first.
function QF.on_quest_greeting()
    if not QuestFrame or not QuestFrame:IsShown() then return nil end
    local active = GetNumActiveQuests and GetNumActiveQuests() or 0
    for i = 1, active do
        -- SelectActiveQuest opens the turn-in flow for a ready quest; the
        -- QUEST_PROGRESS/COMPLETE handlers finish it.
        if SelectActiveQuest then SelectActiveQuest(i) end
        return "greeting_active"
    end
    local avail = GetNumAvailableQuests and GetNumAvailableQuests() or 0
    if avail > 0 and SelectAvailableQuest then
        SelectAvailableQuest(1)
        return "greeting_available"
    end
    return nil
end

-- GOSSIP_SHOW: an NPC whose menu also offers quests. Prefer turning in a
-- ready quest (active) before picking up new ones (available).
function QF.on_gossip()
    if not GossipFrame or not GossipFrame:IsShown() then return nil end
    local a = GetNumGossipActiveQuests and GetNumGossipActiveQuests() or 0
    if a > 0 and SelectGossipActiveQuest then
        SelectGossipActiveQuest(1)
        return "gossip_active"
    end
    local n = GetNumGossipAvailableQuests and GetNumGossipAvailableQuests() or 0
    if n > 0 and SelectGossipAvailableQuest then
        SelectGossipAvailableQuest(1)
        return "gossip_available"
    end
    return nil
end

-- QUEST_DETAIL: the offered-quest window. Accept (subject to policy) or decline.
-- WHERE GIVER MEMORY ACTUALLY COMES FROM.
--
-- QuestOM.observe() was the only writer of the "giver"/"turnin" POI kinds, and
-- it records what nearest_giver() found - which is nothing, because the runtime
-- command behind it is a `return 0` stub. So the remembered-giver fallback was
-- structurally empty: a memory that could only be filled by the sensor it was
-- supposed to compensate for.
--
-- An open quest dialog is PROOF. Whatever we are talking to is a quest giver,
-- the client says so by showing the frame, and no runtime read is involved. It
-- costs nothing to record here, and it is the one signal that cannot lie.
--
-- Recorded on accept AND on turn-in because the two are frequently different
-- npcs, and the turn-in location is the one the bot has to travel back to.

-- The quest id of the dialog that is open RIGHT NOW, or nil (unknown) when the
-- client cannot say. GetQuestID() is stock on 3.3.5 (added in 3.3.0) and is
-- only meaningful while a QUEST_DETAIL / QUEST_PROGRESS / QUEST_COMPLETE frame
-- is up: outside that window it returns 0, and 0 is truthy in Lua, so a raw
-- read would store quest=0 and the POI id join would silently never match a
-- real id. Callers must read this BEFORE AcceptQuest / GetQuestReward - both
-- start the dialog teardown, and an id read after that races it.
local function dialog_quest_id()
    if type(GetQuestID) ~= "function" then return nil end  -- absent -> unknown
    local ok, v = pcall(GetQuestID)
    v = ok and tonumber(v) or nil
    if v and v ~= 0 then return v end
    return nil
end

local function remember_giver(kind, qid)
    local R = RaijinLab
    local P = R and R.POI
    if not (P and P.record and R.ObjectPosition) then return end
    local x, y, z = R:ObjectPosition("player")
    if not x then return end
    -- The player's own position, not the npc's: we are standing in interact
    -- range, which is close enough to navigate back to, and it needs no object
    -- lookup that could itself be stubbed out.
    -- An open quest frame PROVES this npc is a giver. Tell QuestOM, so that if
    -- the status sensor reported nothing for it we learn the sensor is broken
    -- from one observation instead of guessing from a run of zeros.
    local OM = RaijinLab.QuestOM
    if OM and OM.witness_giver and UnitGUID then
        pcall(OM.witness_giver, UnitGUID("npc"))
    end
    local nm = (UnitName and UnitName("npc")) or (GetUnitName and GetUnitName("npc")) or "quest npc"
    -- Record the quest id too: without it the only join between "which quest"
    -- and "where do I hand it in" is the npc name, which the caller does not
    -- know at lookup time (that exact mismatch shipped once as the
    -- npc-name/quest-title bug). POI.nearest filters on `quest` (verified).
    -- `qid` is captured by the event handler via dialog_quest_id() while the
    -- frame is still open. The old code read GetQuestID() here - after
    -- AcceptQuest/GetQuestReward had already started closing the dialog - and
    -- then fell back to RaijinLab.QuestLog.selected_id, which has NEVER
    -- existed in QuestLog.lua, so the fallback was dead code and a late read
    -- stored quest=0: a record the id join could never find. Unknown stays
    -- unknown - a q=0 record is still a usable generic giver/turnin POI for
    -- the unfiltered lookups.
    if not (qid and qid ~= 0) then qid = nil end
    pcall(P.record, kind, { x = x, y = y, z = z, name = nm, quest = qid })
    local Tel = R.Telemetry
    if Tel and Tel.every then
        Tel.every("quest:giver_poi", 10, "quest", 3, "learned_giver",
            { kind = kind, name = tostring(nm) })
    end
end

function QF.on_quest_detail()
    -- Capture the dialog's quest id BEFORE AcceptQuest: accepting starts the
    -- frame teardown and a read after it can already be 0 (id lost forever).
    local qid = dialog_quest_id()
    local info = {
        isDaily = QuestIsDaily and QuestIsDaily() or nil,
        questId = qid,
    }
    if QF.should_accept(info) then
        if AcceptQuest then AcceptQuest() end
        remember_giver("giver", qid)
        return "accept"
    end
    if DeclineQuest then DeclineQuest() end
    return "decline"
end

-- QUEST_PROGRESS: the "are your requirements met?" window on turn-in. Complete
-- when the client says it's completable, else back out (still working on it).
function QF.on_quest_progress()
    -- COUSIN OF THE DRAW-GATE BUG, BUT NOT THE SAME BUG - the difference matters.
    --
    -- IsPlayerInWorld gated the entire renderer and was nil in 125 of 154 samples
    -- where the position proved the character WAS in the world, so it is broken or
    -- absent here and cannot be believed. That is ignorance.
    --
    -- IsQuestCompletable is different: 3.3.5 boolean APIs return 1/nil rather than
    -- true/false, so a nil from a function that EXISTS is the idiomatic "no" and is
    -- authoritative. Only a MISSING function is ignorance. Conflating the two would
    -- spam CompleteQuest at every progress window whose requirements are unmet.
    --
    -- So: present -> trust it. Absent -> attempt, because a rejected CompleteQuest
    -- costs one no-op while a skipped one stalls the quester forever.
    -- One shared primitive rather than a third hand-rolled copy of this rule.
    -- probe() answers yes / no / unknown; assume() is the only sanctioned place
    -- to collapse an unknown, and it counts and logs every time it does.
    local K = RaijinLab and RaijinLab.Know
    local completable
    if K then
        completable = K.assume(K.probe(IsQuestCompletable), true, "quest_completable")
    else
        -- Fallback for a load order where Know is not up yet. It must obey the
        -- same rule AND be crash-safe: the first version called the api bare and
        -- a throwing api took the whole turn-in handler down with it.
        if type(IsQuestCompletable) ~= "function" then
            completable = true                       -- absent -> unknown -> attempt
        else
            local ok, v = pcall(IsQuestCompletable)
            completable = (not ok) or (v and true or false)
        end
    end
    if completable then
        if CompleteQuest then CompleteQuest() end
        return "complete"
    end
    if CloseQuest then CloseQuest() end
    return "not_ready"
end


-- QUEST_COMPLETE: the reward window. Gather choices, pick one per policy, claim.
function QF.on_quest_complete()
    local c = cfg()
    -- Capture BEFORE GetQuestReward: claiming the reward starts the dialog
    -- teardown, and an id read afterwards races it.
    local qid = dialog_quest_id()
    local n = GetNumQuestChoices and GetNumQuestChoices() or 0
    if n and n > 0 then
        local choices = {}
        for i = 1, n do
            -- GetQuestItemInfo("choice", i) -> name, texture, numItems, quality, isUsable
            local name, _, _, quality, isUsable
            if GetQuestItemInfo then
                name, _, _, quality, isUsable = GetQuestItemInfo("choice", i)
            end
            choices[i] = {
                quality = quality, isUsable = isUsable,
                link = GetQuestItemLink and GetQuestItemLink("choice", i) or nil,
                name = name,
            }
        end
        local idx = QF.pick_reward(choices, c.reward_policy, c.reward_index) or 1
        if GetQuestReward then GetQuestReward(idx) end
        remember_giver("turnin", qid)
        return "reward_choice", idx
    end
    -- No choice (fixed or no reward): claim slot 1 (harmless when none).
    if GetQuestReward then GetQuestReward(1) end
    -- This branch is MOST quests (fixed rewards) and it never recorded the
    -- turn-in POI, so turn-in memory only ever learned choice-reward quests -
    -- despite remember_giver's contract saying accept AND turn-in.
    remember_giver("turnin", qid)
    return "reward"
end

if RaijinLab then RaijinLab.QuestFrame = QF end
return QF
