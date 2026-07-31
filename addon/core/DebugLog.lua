-- Ring-buffer sink for EVERY RaijinLab event.
--
-- Policy (user requirement):
--   1. Debug log (this buffer / Debug tab) receives EVERY line - always.
--   2. Chat receives those same lines ONLY when RaijinLab.chat_verbose is true.
--   3. Hard errors (red RaijinLab prefix) still always mirror to chat so the
--      user never misses inject/runtime failures.
--
-- Entry points:
--   DebugLog.Log(cat, fmt, ...)   -- preferred; always buffered
--   RaijinLab:Log(cat, fmt, ...)  -- thin alias once DebugLog is loaded
--   RaijinLab:Chatter(msg)        -- routes through Log("chat", ...)
--   print("|cff7ec8e3RaijinLab|r ...") -- hooked: buffer always, chat if verbose

local RL = RaijinLab
if not RL then return end

local DebugLog = {}
RL.DebugLog = DebugLog

local kCap = 3000
local buf = {}
local head = 0
local total = 0
local subs = {}

local function now_stamp()
    if date then return date("%H:%M:%S") end
    return tostring(math.floor((GetTime and GetTime()) or 0))
end

local function strip_colors(s)
    if type(s) ~= "string" then return tostring(s) end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    return s
end

local function safe_format(fmt, ...)
    if select("#", ...) <= 0 then return tostring(fmt) end
    local ok, s = pcall(string.format, tostring(fmt), ...)
    if ok then return s end
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    return table.concat(parts, " ")
end

function DebugLog.Push(line)
    if type(line) ~= "string" then line = tostring(line) end
    line = strip_colors(line)
    if line == "" then return end
    if #buf < kCap then
        buf[#buf + 1] = { t = now_stamp(), text = line }
        head = #buf
    else
        head = (head % kCap) + 1
        buf[head] = { t = now_stamp(), text = line }
    end
    total = total + 1
    -- Coalesce subscriber notify: many Pushes in one frame = one wake-up.
    if not DebugLog._sub_pending then
        DebugLog._sub_pending = true
        local function flush_subs()
            DebugLog._sub_pending = false
            for i = 1, #subs do
                local ok = pcall(subs[i])
                if not ok then subs[i] = nil end
            end
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, flush_subs)
        elseif CreateFrame then
            if not DebugLog._sub_frame then
                local f = CreateFrame("Frame")
                DebugLog._sub_frame = f
                f:Hide()
                f:SetScript("OnUpdate", function(self)
                    self:Hide()
                    flush_subs()
                end)
            end
            DebugLog._sub_frame:Show()
        else
            flush_subs()
        end
    end
end

-- Preferred API: always -> Debug tab. chat_verbose -> also chat.
-- cat is a short tag: rot, cast, skip, corpse, busy, eng, world, boot, ...
function DebugLog.Log(cat, fmt, ...)
    local body = safe_format(fmt, ...)
    cat = tostring(cat or "log")
    local line = string.format("[%s] %s", cat, body)
    DebugLog.Push(line)
    if RL.chat_verbose then
        local op = DebugLog._orig_print or print
        -- Flag so the print hook does not double-Push.
        DebugLog._in_log = true
        pcall(op, "|cff7ec8e3RaijinLab|r " .. line)
        DebugLog._in_log = false
    end
    -- Mirror to on-disk DevLog when available (session transcript).
    local DL = RL.DevLog
    if DL and DL.log then
        pcall(DL.log, cat, "%s", body)
    end
    return line
end

function DebugLog.Snapshot()
    local out = {}
    if #buf < kCap then
        for i = 1, #buf do out[#out + 1] = buf[i] end
    else
        for i = head + 1, kCap do out[#out + 1] = buf[i] end
        for i = 1, head do out[#out + 1] = buf[i] end
    end
    return out
end

function DebugLog.Clear()
    buf, head, total = {}, 0, total + 1
    for i = 1, #subs do pcall(subs[i]) end
end

function DebugLog.Total() return total end
function DebugLog.Cap() return kCap end

function DebugLog.Subscribe(fn)
    if type(fn) == "function" then subs[#subs + 1] = fn end
end

-- RaijinLab:Log / Chatter always go through the buffer.
function RL:Log(cat, fmt, ...)
    return DebugLog.Log(cat, fmt, ...)
end

function RL:Chatter(msg)
    return DebugLog.Log("chat", "%s", tostring(msg))
end
RL._chatter_teed = true

-- Central print hook.
--   * Any line containing "RaijinLab" -> Debug buffer always.
--   * Blue/gold RL prefix: chat only when chat_verbose.
--   * Red RL errors: chat always (inject / runtime failures must be visible).
--   * Other addons: pass through untouched.
if not _G._RL_PRINT_TEED then
    local orig_print = print
    local kBlue = "|cff7ec8e3RaijinLab"
    local kGold = "|cffffd200RaijinLab"
    local kRed  = "|cffff5555RaijinLab"
    DebugLog._orig_print = orig_print

    local function safe_join(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        return table.concat(parts, "  ")
    end

    _G.print = function(...)
        if DebugLog._in_log or DebugLog._in_chatter then
            -- Already logged via DebugLog.Log; only emit to chat if caller used print.
            -- Log path uses _orig_print directly, so this is for nested prints.
            return orig_print(...)
        end
        local first = select(1, ...)
        local joined = safe_join(...)
        local is_blue = type(first) == "string" and first:sub(1, #kBlue) == kBlue
        local is_gold = type(first) == "string" and first:sub(1, #kGold) == kGold
        local is_red  = type(first) == "string" and first:sub(1, #kRed) == kRed
        local is_rl   = is_blue or is_gold or is_red
            or (type(joined) == "string" and joined:find("RaijinLab", 1, true) ~= nil)

        if is_rl then
            DebugLog.Push(joined)
            if is_red or RL.chat_verbose then
                orig_print(...)
            end
        else
            orig_print(...)
        end
    end
    _G._RL_PRINT_TEED = true
end

-- Boot line so the Debug tab is never empty after load.
DebugLog.Log("boot", "DebugLog armed  cap=%d  verbose=%s",
    kCap, tostring(RL.chat_verbose and true or false))
