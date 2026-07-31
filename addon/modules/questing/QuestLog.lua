-- Quest-log reading + objective parsing on STOCK WoW 3.3.5a APIs.
--
-- This is the bedrock the questing engine reads from. It deliberately uses ONLY
-- stock 3.3.5 globals (GetNumQuestLogEntries / GetQuestLogTitle /
-- SelectQuestLogEntry / GetNumQuestLeaderBoards / GetQuestLogLeaderBoard /
-- GetQuestLogSpecialItemInfo). It must NOT touch the retail C_QuestLog / C_Map /
-- QuestPOI APIs - those are nil on this client (the commented GetQuestObjectiveMap
-- in API.lua uses them and would error). The pure parse_objective() is the
-- unit-tested core; everything stateful is a thin wrapper over it so the parsing
-- can be verified without a live client.

local QuestLog = {}

-- Objective "type" strings returned by GetQuestLogLeaderBoard's 2nd return on
-- 3.3.5: "monster", "item", "object", "event", "reputation", "player", "log".
-- We normalize to lowercase and derive a coarse `kind` the engine acts on.
local KILL_VERBS = {
    slain = true, killed = true, destroyed = true, defeated = true,
    slaughtered = true, exterminated = true, eliminated = true,
}
local USE_VERBS = {
    used = true, collected = true, gathered = true, ["repaired"] = true,
}

-- Trim helper (Lua 5.1, no built-in trim).
local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Pure objective parser. Given the raw leaderboard text and its type, return a
-- structured objective. Handles the common enUS formats:
--   monster: "Kobold Vermin slain: 3/10"  or  "3/10 Kobold Vermin slain"
--   item:    "Red Feather: 0/5"           or  "0/5 Red Feather"
--   object:  "Lever used: 0/1"            or  "Chest: 0/1"
--   event:   "Speak with Thomas"          (no counter -> boolean objective)
-- Returns { raw, type, kind, name, current, required, finished }.
--   kind: "kill" | "collect" | "object" | "event" | "reputation" | "other"
--   name: the target creature / item / object name, or nil when not applicable.
function QuestLog.parse_objective(text, otype, finished)
    text = tostring(text or "")
    otype = trim(tostring(otype or "")):lower()
    local o = {
        raw = text,
        type = otype,
        finished = finished == true or finished == 1,
    }

    -- Numeric progress "current/required" (present on counted objectives).
    local cur, req = text:match("(%d+)%s*/%s*(%d+)")
    if cur and req then
        o.current = tonumber(cur)
        o.required = tonumber(req)
        if not finished then o.finished = o.current >= o.required end
    end

    -- Body = text minus the counter and surrounding colon/space, used for the
    -- target name.
    local body = text:gsub("%d+%s*/%s*%d+", " ")
    body = trim(body:gsub(":", " "):gsub("%s+", " "))

    -- Coarse kind + name extraction.
    if otype == "monster" then
        o.kind = "kill"
        -- Drop a trailing kill verb ("... slain"). Only strip a KNOWN verb so a
        -- verbless name (rare) isn't truncated.
        local last = body:match("(%S+)%s*$")
        if last and KILL_VERBS[last:lower()] then
            body = trim(body:sub(1, #body - #last))
        end
        o.name = body ~= "" and body or nil
    elseif otype == "item" then
        o.kind = "collect"
        o.name = body ~= "" and body or nil
    elseif otype == "object" then
        o.kind = "object"
        local last = body:match("(%S+)%s*$")
        if last and USE_VERBS[last:lower()] then
            body = trim(body:sub(1, #body - #last))
        end
        o.name = body ~= "" and body or nil
    elseif otype == "reputation" then
        o.kind = "reputation"
        o.name = body ~= "" and body or nil
    elseif otype == "player" then
        o.kind = "pvp"
        o.name = body ~= "" and body or nil
    else
        -- "event"/"log"/unknown: a boolean objective (talk-to / explore / use).
        o.kind = "event"
        o.name = body ~= "" and body or nil
    end
    return o
end

-- ---- Live quest-log readers (thin stock-API wrappers) --------------------

-- Number of quests (excluding headers) currently in the log.
function QuestLog.num_quests()
    if not GetNumQuestLogEntries then return 0 end
    local n = 0
    local total = GetNumQuestLogEntries()
    for i = 1, total do
        local _, _, _, _, isHeader = GetQuestLogTitle(i)
        if not isHeader then n = n + 1 end
    end
    return n
end

-- The classic client caps the quest log at 25. Expose it so the engine can stop
-- accepting when full instead of silently failing.
QuestLog.MAX_QUESTS = 25
function QuestLog.is_full()
    return QuestLog.num_quests() >= QuestLog.MAX_QUESTS
end

-- Full structured scan of the quest log. Selects each entry to read its
-- objectives (SelectQuestLogEntry is unprotected and is what the stock UI does).
-- Restores the previously selected entry afterward so we don't disturb the UI.
-- Returns a list of:
--   { index, title, level, tag, group, questId, isDaily, complete, objectives }
-- where objectives is a list of parse_objective() results.
function QuestLog.scan()
    local out = {}
    if not GetNumQuestLogEntries or not GetQuestLogTitle then return out end
    local prev = GetQuestLogSelection and GetQuestLogSelection() or nil
    local total = GetNumQuestLogEntries()
    for i = 1, total do
        local title, level, tag, group, isHeader, _, isComplete, isDaily, questId =
            GetQuestLogTitle(i)
        if not isHeader and title then
            if SelectQuestLogEntry then SelectQuestLogEntry(i) end
            local ocount = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0
            local objs = {}
            local all_done = true
            for oi = 1, ocount do
                local otext, otype, ofin = GetQuestLogLeaderBoard(oi, i)
                local parsed = QuestLog.parse_objective(otext, otype, ofin)
                objs[#objs + 1] = parsed
                if not parsed.finished then all_done = false end
            end
            out[#out + 1] = {
                index = i,
                title = title,
                level = level,
                tag = tag,               -- "Elite" / "Group" / "Dungeon" / "Raid" / "PvP" / ...
                group = group,           -- suggested group size (0 = solo)
                questId = questId,
                isDaily = isDaily,
                -- isComplete: 1 when the quest is ready to turn in, -1 when
                -- failed, nil/0 otherwise. Fall back to "all objectives done".
                complete = (isComplete == 1) or (ocount > 0 and all_done),
                failed = isComplete == -1,
                objectives = objs,
            }
        end
    end
    if prev and SelectQuestLogEntry then SelectQuestLogEntry(prev) end
    return out
end

-- First quest that is ready to turn in (all objectives done / isComplete).
function QuestLog.first_complete()
    for _, q in ipairs(QuestLog.scan()) do
        if q.complete and not q.failed then return q end
    end
    return nil
end

-- First unfinished objective across the log, honoring priority = log order.
-- Returns (quest, objective) or nil when everything is complete.
-- opts.skip = { [questId]=true } - parked quests. Honouring this matters: the
-- Suite falls back to this selector whenever the ranked one returns nothing, so
-- ignoring the park set made parking a NO-OP and the engine kept grinding the
-- exact quest it had just given up on.
function QuestLog.first_incomplete_objective(opts)
    opts = opts or {}
    for _, q in ipairs(QuestLog.scan()) do
        if not q.complete and not (opts.skip and opts.skip[q.questId]) then
            for _, o in ipairs(q.objectives) do
                if not o.finished then return q, o end
            end
        end
    end
    return nil
end

-- The objective we SHOULD work next, rather than merely the first one in the log.
-- Ranking is delegated to QuestPolicy (smart / nearest / lowest-level / manual),
-- and distances come from remembered objective locations so "nearest" means
-- nearest in the world, not nearest in the list. Falls back to log order.
-- opts.skip = { [questId] = true } parks quests we cannot currently progress.
function QuestLog.best_objective(opts)
    opts = opts or {}
    local QP = RaijinLab and RaijinLab.QuestPolicy
    local list = {}
    for _, q in ipairs(QuestLog.scan()) do
        if not q.complete and not (opts.skip and opts.skip[q.questId]) then
            local done, total = 0, 0
            for _, o in ipairs(q.objectives) do
                total = total + 1
                if o.finished then done = done + 1 end
            end
            if done < total or total == 0 then
                q.id = q.questId
                q.progress_frac = (total > 0) and (done / total) or 0
                list[#list + 1] = q
            end
        end
    end
    if #list == 0 then return nil end
    if not (QP and QP.rank) then
        local q = list[1]
        for _, o in ipairs(q.objectives) do if not o.finished then return q, o end end
        return nil
    end

    -- Distance comes from what we remember about each objective, so the ranking
    -- reflects real travel rather than list position.
    local QOM = RaijinLab and RaijinLab.QuestOM
    local function dist_of(q)
        if not (QOM and QOM.remembered_objective) then return nil end
        for _, o in ipairs(q.objectives or {}) do
            if not o.finished and o.name then
                local m = QOM.remembered_objective(o.name)
                if m and m.dist then return m.dist end
            end
        end
        return nil
    end

    local ranked = QP.rank(list, { dist_of = dist_of })
    for _, q in ipairs(ranked) do
        for _, o in ipairs(q.objectives or {}) do
            if not o.finished then return q, o end
        end
    end
    return nil
end

if RaijinLab then RaijinLab.QuestLog = QuestLog end
return QuestLog
