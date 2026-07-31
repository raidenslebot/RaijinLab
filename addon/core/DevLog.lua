-- Development logging to disk - the shared workspace for building the quester /
-- navigation together. Every subsystem calls DevLog.log(category, fmt, ...); the
-- lines are batched and appended to <WoW>/Logs/raijinlab_dev.log about once a
-- second, so a whole session's behavior can be read straight off disk instead of
-- relaying chat output. Off the render path (append is cheap; batched), so
-- logging everything costs practically nothing.
--
-- Design notes:
--   * APPEND (runtime 1.8.3+ AppendFile) so the full session accumulates without
--     rewriting; falls back to a bounded rewrite on older runtimes.
--   * A fresh file per session (WriteFile a header on start()).
--   * Per-category throttling helper (log_every) so a 33Hz loop can log a
--     heartbeat at 1Hz without flooding.
--   * Pure formatting (line()) is unit-tested; disk I/O is guarded by pcall.

local DevLog = {}
DevLog._buf = {}
DevLog._path = nil
DevLog._enabled = true
DevLog._max_buf = 500          -- larger batch = fewer AppendFile syscalls
DevLog._last = {}              -- per-key timestamps for log_every()

local function now() return (GetTime and GetTime()) or 0 end

-- Pure: format one log line. Kept separate so it's testable without a client.
function DevLog.line(cat, msg)
    return string.format("%.3f [%s] %s", now(), tostring(cat or "?"), tostring(msg))
end

function DevLog.path()
    if DevLog._path then return DevLog._path end
    local dir = RaijinLab and RaijinLab.GetWoWDirectory and RaijinLab:GetWoWDirectory()
    if not dir or dir == "" then return nil end
    DevLog._path = dir .. "\\Logs\\raijinlab_dev.log"
    return DevLog._path
end

function DevLog.log(cat, fmt, ...)
    if not DevLog._enabled then return end
    local msg
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        msg = ok and s or tostring(fmt)
    else
        msg = fmt
    end
    DevLog._buf[#DevLog._buf + 1] = DevLog.line(cat, msg)
    if #DevLog._buf >= DevLog._max_buf then DevLog.flush() end
end

-- Log at most once per `gap` seconds for a given key (heartbeats from hot loops).
function DevLog.log_every(key, gap, cat, fmt, ...)
    local t = now()
    if DevLog._last[key] and (t - DevLog._last[key]) < (gap or 1.0) then return end
    DevLog._last[key] = t
    DevLog.log(cat, fmt, ...)
end

function DevLog.flush()
    if #DevLog._buf == 0 then return end
    local path = DevLog.path()
    if not path then return end
    local chunk = table.concat(DevLog._buf, "\n") .. "\n"
    DevLog._buf = {}
    pcall(function()
        if RaijinLab.AppendFile and RaijinLab:AppendFile(path, chunk) then
            return
        end
        -- Fallback for a pre-1.8.3 runtime: accumulate and rewrite (bounded).
        DevLog._accum = (DevLog._accum or "") .. chunk
        if #DevLog._accum > 2 * 1024 * 1024 then
            DevLog._accum = DevLog._accum:sub(-1024 * 1024)
        end
        if RaijinLab.WriteFile then RaijinLab:WriteFile(path, DevLog._accum) end
    end)
end

function DevLog.start()
    if DevLog._started then return end
    DevLog._started = true
    local path = DevLog.path()
    if path and RaijinLab.WriteFile then
        local ver = RaijinLab.ADDON_VERSION or "?"
        local rt = (RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion()) or "?"
        local when = (date and date("%Y-%m-%d %H:%M:%S")) or tostring(now())
        pcall(RaijinLab.WriteFile, RaijinLab, path,
            string.format("=== RaijinLab dev log  %s  addon=%s runtime=%s ===\n", when, tostring(ver), tostring(rt)))
        DevLog._accum = nil
    end
    if C_Timer and C_Timer.NewTicker then
        -- 1.0s flush: still live-tailable; half the disk wakeups of 0.5s.
        DevLog._t = C_Timer.NewTicker(1.0, DevLog.flush)
    end
    DevLog.log("boot", "dev log started")
end

function DevLog.stop()
    DevLog.flush()
    if DevLog._t then DevLog._t:Cancel(); DevLog._t = nil end
    DevLog._started = false
end

if RaijinLab then RaijinLab.DevLog = DevLog end
return DevLog
