-- Ascension / 3.3.5 compatibility shims for retail-era API usage in the pack.

local RL = RaijinLab

-- C_Timer polyfill (retail -> 3.3.5)
if not C_Timer then
    C_Timer = {}
    local waiters = {}
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(_, elapsed)
        local i = 1
        -- Snapshot the count at pass entry. Tickers re-arm by APPENDING a new
        -- waiter mid-drain (via C_Timer.After inside w.fn); those land at index
        -- > n and must be deferred to the next frame. Without this snapshot, a
        -- sub-frame-interval ticker (delay <= elapsed) re-qualifies instantly and
        -- pins i/#waiters at 1 -> infinite loop -> main-thread freeze.
        local n = #waiters
        while i <= n do
            local w = waiters[i]
            w.t = w.t - elapsed
            if w.t <= 0 then
                table.remove(waiters, i)
                n = n - 1
                local ok, err = pcall(w.fn)
                if not ok then
                    geterrorhandler()(err)
                end
            else
                i = i + 1
            end
        end
    end)
    function C_Timer.After(delay, fn)
        waiters[#waiters + 1] = {t = delay, fn = fn}
    end
    function C_Timer.NewTicker(delay, fn, iters)
        -- MUST return a handle with :Cancel() - modules call ticker:Cancel().
        -- Also refuse sub-frame delays (would re-arm infinitely under large elapsed).
        if type(delay) ~= "number" or delay < 0.05 then
            delay = 0.05
        end
        local count = 0
        local cancelled = false
        local function tick()
            if cancelled then return end
            count = count + 1
            local ok, err = pcall(fn)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
            if cancelled then return end
            if not iters or count < iters then
                C_Timer.After(delay, tick)
            end
        end
        C_Timer.After(delay, tick)
        return {
            Cancel = function()
                cancelled = true
            end,
        }
    end
end

-- C_QuestLog / modern quest APIs -> classic fallbacks
if not C_QuestLog then
    C_QuestLog = {}
end

if not C_QuestLog.IsOnQuest then
    function C_QuestLog.IsOnQuest(questID)
        if not questID then
            return false
        end
        for i = 1, (GetNumQuestLogEntries and GetNumQuestLogEntries() or 0) do
            -- INDEX 9, NOT 8. Stock Blizzard 3.3.5 returns eight values and no
            -- quest id; this server appends questId as a NINTH. Reading index 8
            -- picks up isDaily - a boolean - so the comparison against a numeric
            -- questID never matched and IsOnQuest silently always returned false.
            -- QuestLog.lua:128 already reads index 9; this shim disagreed with it.
            -- Both layouts are tolerated: prefer 9, fall back to 8 when 9 is not
            -- a number (a genuinely stock client).
            local _, _, _, _, _, _, _, eighth, ninth = GetQuestLogTitle(i)
            local id = tonumber(ninth) or tonumber(eighth)
            if id and id == questID then
                return true
            end
        end
        return false
    end
end

-- UnitCastingInfo / UnitChannelInfo exist on 3.3.5 Wrath
-- Nameplate / AreaTrigger APIs are retail-only; modules must guard.

function RL:IsAscensionClient()
    -- Heuristic: custom globals / events from Extensions
    if type(GetAscensionSeasonalPoints) == "function" then
        return true
    end
    if type(LoadAscensionContentJSON) == "function" then
        return true
    end
    local ver = GetBuildInfo and select(4, GetBuildInfo()) or 0
    return ver >= 30300 and ver < 40000
end

function RL:ClientBuild()
    if GetBuildInfo then
        local version, build, _, toc = GetBuildInfo()
        return version, build, toc
    end
    return "unknown", "0", 0
end
