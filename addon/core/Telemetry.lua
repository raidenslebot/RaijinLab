-- Telemetry - make everything the bot does visible from outside the game.
--
-- The bugs that actually hurt here are invisible ones: a goal that holds a slot
-- while achieving nothing, a path that is re-planned three times a second, a
-- store that quietly evicts the wrong records. None of them throw an error and
-- none of them look wrong on screen. The only way to find them is to record what
-- the bot decided and why, continuously, and read it back afterwards.
--
-- So this writes a STRUCTURED, machine-readable line for every meaningful event:
--
--   1234.567 [director] I choose goal=rest band=4 why=preempted urgency=0.62
--
-- key=value after the event name, so a whole session can be filtered, counted and
-- correlated with grep/awk without parsing prose. Levels let the firehose be
-- turned down per category without editing code, and hot loops use `every` so a
-- 33Hz path can report at 1Hz.
--
-- It writes through DevLog (runtime AppendFile -> <WoW>/Logs/raijinlab_dev.log),
-- batched off the render path.

local T = {}

T.LEVELS = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
T.LEVEL_TAG = { [1] = "E", [2] = "W", [3] = "I", [4] = "D", [5] = "T" }

T.DEFAULTS = {
    enabled = true,
    -- Default debug again: more decision visibility. Cost is low because Debug
    -- tab only mirrors warn+ and DevLog batches AppendFile.
    level = 4,
    categories = {
        cam = 1,               -- camera project: opt-in only (was 40% of log volume)
        hb  = 3,
        snap = 3,
        perf = 3,
        director = 4,
        nav = 4,
        quest = 4,
        om = 3,
        world = 3,
        path = 4,
    },
}

T._seq = 0
T._counts = {}
T._last = {}

local function now() return (GetTime and GetTime()) or 0 end

function T.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.telemetry = RaijinLabDB.telemetry or {}
    local c = RaijinLabDB.telemetry
    for k, v in pairs(T.DEFAULTS) do
        if c[k] == nil then
            if type(v) == "table" then
                local t = {}
                for kk, vv in pairs(v) do t[kk] = vv end
                c[k] = t
            else
                c[k] = v
            end
        end
    end
    return c
end

function T.level_for(cat)
    local c = T.cfg()
    local per = c.categories and c.categories[cat]
    return per or c.level or 3
end

function T.enabled(cat, lvl)
    local c = T.cfg()
    if not c.enabled then return false end
    return (lvl or 3) <= T.level_for(cat)
end

-- Render a value so the line stays parseable: no spaces, no newlines, and floats
-- rounded so a position does not print 14 digits of noise.
local function val(v)
    local tv = type(v)
    if tv == "number" then
        if v ~= v then return "nan" end                       -- NaN survives round-trip
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.3f", v)
    end
    if tv == "boolean" then return v and "true" or "false" end
    if v == nil then return "nil" end
    local s = tostring(v)
    s = s:gsub("%s+", "_")
    if #s > 120 then s = s:sub(1, 117) .. "..." end
    return s
end
T._val = val

-- Deterministic key order: a line is far easier to diff and eyeball when the
-- fields always appear in the same sequence.
local function kvstring(kv)
    if type(kv) ~= "table" then return kv and tostring(kv) or "" end
    local keys = {}
    for k in pairs(kv) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. val(kv[k]) end
    return table.concat(parts, " ")
end
T._kv = kvstring

-- The primary entry point. `event` is a short stable token (goal, plan, refuse),
-- `kv` a table of fields.
function T.emit(cat, lvl, event, kv)
    cat = cat or "misc"
    lvl = lvl or 3
    T._counts[cat] = (T._counts[cat] or 0) + 1
    if not T.enabled(cat, lvl) then return end
    T._seq = T._seq + 1
    local body = kvstring(kv)
    local msg = (T.LEVEL_TAG[lvl] or "I") .. " " .. tostring(event)
    if body ~= "" then msg = msg .. " " .. body end
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then DL.log(cat, msg) end
    -- Also land in the in-game Debug tab so "nothing in the logs" is not
    -- "only on disk under Logs/". Warn+ always; info/debug for quest/nav/director.
    local DBG = RaijinLab and RaijinLab.DebugLog
    if DBG and DBG.Log then
        -- UI Debug tab: warn+ only. Hot info/debug to disk only (no frame list churn).
        if (lvl or 3) <= 2 then
            pcall(DBG.Log, cat, "%s", msg)
        end
    end
    return msg
end

-- Level helpers. `err` and `warn` are deliberately never filtered by default.
function T.err(cat, event, kv)   return T.emit(cat, 1, event, kv) end
function T.warn(cat, event, kv)  return T.emit(cat, 2, event, kv) end
function T.info(cat, event, kv)  return T.emit(cat, 3, event, kv) end
function T.debug(cat, event, kv) return T.emit(cat, 4, event, kv) end
function T.trace(cat, event, kv) return T.emit(cat, 5, event, kv) end

-- Rate-limited emit for hot loops: at most once per `gap` seconds per key.
function T.every(key, gap, cat, lvl, event, kv)
    local t = now()
    local last = T._last[key]
    if last and (t - last) < (gap or 1.0) then return end
    T._last[key] = t
    return T.emit(cat, lvl, event, kv)
end

-- Emit only when a watched value CHANGES. Transitions are the interesting part of
-- a state machine; repeating the steady state just buries them.
function T.on_change(key, value, cat, event, kv)
    local prev = T._last["chg:" .. key]
    if prev == value then return end
    T._last["chg:" .. key] = value
    kv = kv or {}
    kv.from = prev
    kv.to = value
    return T.emit(cat, 3, event, kv)
end

function T.counts() return T._counts end

function T.set_level(cat, lvl)
    local c = T.cfg()
    if cat and cat ~= "" then
        c.categories = c.categories or {}
        c.categories[cat] = lvl
    else
        c.level = lvl
    end
end

if RaijinLab then RaijinLab.Telemetry = T end
return T
