-- StructuredLog — unified machine-parseable logging for the entire addon
-- ==========================================================================
-- Format:  SSS.SSS|L|cat.sub|k1=v1 k2=v2 k3=v3 ...
--   SSS.SSS = GetTime() seconds since login, 3 decimal places
--   L = single-char level: T=Trace D=Debug I=Info W=Warn E=Error
--   cat.sub = hierarchical category (br.reg, cast.fire, rot.tick, om.walk)
--   Body = key=value pairs, space-separated
--
-- Sinks:
--   1. DevLog (disk)  — all levels at or above configured threshold
--   2. DebugLog (UI)  — Warn+ only, plus Info if verbose
--   3. chat (print)   — Error only (always visible)
--
-- Usage:
--   SLog.info("cast.fire", "sid", sid, "name", name, "guid", guid)
--   SLog.warn("cast.refuse", "sid", sid, "why", reason, "cdMs", cdMs)
--   SLog.error("crash",  "msg", "AV at 0x%X", addr)
--   SLog:cast_fire(sid, name, guid, edge)
--   SLog:cast_land(sid, name, gcd_src, cast_t)
--   SLog:cast_refuse(sid, name, why, cdMs)
--   SLog:hb_player(x, y, z, facing, hp, combat)
--   SLog:hb_perf(fps, frame_ms, budget, peak)
--   SLog:hb_rotation(casts, gcd_src, running, last_err)
--   SLog:hb_om(bridge, npcs, players, gos, armed, mode)

local SLog = {}
SLog._level = 3  -- 1=Error 2=Warn 3=Info 4=Debug 5=Trace (default Info)

local LEVEL_CHAR = { "E", "W", "I", "D", "T" }
local LEVEL_NUM  = { E=1, W=2, I=3, D=4, T=5 }

function SLog.set_level(lvl)
    if type(lvl) == "string" then lvl = LEVEL_NUM[string.upper(lvl)] or 3 end
    SLog._level = tonumber(lvl) or 3
end

local function now() return (GetTime and GetTime()) or 0 end

local function kv_pairs(args)
    -- args: { "k1", v1, "k2", v2 } or { k1=v1, k2=v2 } or just string
    if type(args) ~= "table" then return tostring(args) end
    -- Detect array-style {key, val, key, val}
    local parts = {}
    if #args > 0 then
        for i = 1, #args, 2 do
            local k = tostring(args[i] or "?")
            local v = args[i+1]
            if v == nil then v = "nil"
            elseif type(v) == "string" then
                if v:find(" ") then v = '"' .. v .. '"' end
            end
            parts[#parts+1] = k .. "=" .. tostring(v)
        end
    else
        -- Table-style { k1=v1, k2=v2 }
        local keys = {}
        for k in pairs(args) do keys[#keys+1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = args[k]
            if v == nil then v = "nil"
            elseif type(v) == "string" and v:find(" ") then v = '"' .. v .. '"' end
            parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    if #parts == 0 and type(args) == "string" then return args end
    return table.concat(parts, " ")
end

local function emit(level_num, cat_sub, msg_fmt, ...)
    if level_num > SLog._level then return end
    local lvl_char = LEVEL_CHAR[level_num] or "?"

    -- Format the body
    local body
    local nargs = select("#", ...)
    if nargs == 0 then
        body = tostring(msg_fmt)
    elseif nargs == 1 and type(msg_fmt) == "string" and not msg_fmt:find("%") then
        -- Single key=value string
        body = tostring(msg_fmt) .. " " .. kv_pairs(...)
    else
        -- printf-style format string
        local ok, s = pcall(string.format, msg_fmt, ...)
        body = ok and s or tostring(msg_fmt)
    end

    local line = string.format("%.3f|%s|%s|%s", now(), lvl_char, cat_sub or "?", body)

    -- Sink 1: DevLog (disk) — all levels
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log then
        local cat = string.match(cat_sub or "", "^(%w+)") or "log"
        DL.log(cat, line:sub(12)) -- strip timestamp (DevLog adds its own)
    end

    -- Sink 2: DebugLog (UI ring buffer) — Warn+
    if level_num <= 2 then
        local Dbg = RaijinLab and RaijinLab.DebugLog
        if Dbg and Dbg.Log then
            Dbg.Log(cat_sub or "log", body)
        end
    end

    -- Sink 3: Chat (print) — Error only
    if level_num == 1 then
        print("|cffff5555RaijinLab|r " .. body)
    end
end

-- ---- Public API -----------------------------------------------------------

function SLog.error(cat_sub, ...) emit(1, cat_sub, ...) end
function SLog.warn(cat_sub, ...)  emit(2, cat_sub, ...) end
function SLog.info(cat_sub, ...)  emit(3, cat_sub, ...) end
function SLog.debug(cat_sub, ...) emit(4, cat_sub, ...) end
function SLog.trace(cat_sub, ...) emit(5, cat_sub, ...) end

-- Convenience: every-N-seconds gate for hot-path logging
function SLog.every(key, gap_sec, level, cat_sub, ...)
    SLog._every = SLog._every or {}
    local t = now()
    if SLog._every[key] and (t - SLog._every[key]) < (gap_sec or 1) then return end
    SLog._every[key] = t
    local lvl = LEVEL_NUM[level] or 3
    emit(lvl, cat_sub, ...)
end

-- Convenience: log only on value change
function SLog.on_change(key, value, level, cat_sub, ...)
    SLog._prev = SLog._prev or {}
    local prev = SLog._prev[key]
    if prev == value then return end
    SLog._prev[key] = value
    local lvl = LEVEL_NUM[level] or 3
    emit(lvl, cat_sub, ...)
end

-- ---- Domain-specific structured loggers ------------------------------------

-- Cast lifecycle
function SLog.cast_fire(sid, name, guid, edge, slot_idx)
    emit(3, "cast.fire", "sid=%s name=%s guid=%s edge=%.1f slot=%s",
         tostring(sid), tostring(name), tostring(guid or 0),
         tonumber(edge) or 0, tostring(slot_idx or "?"))
end

function SLog.cast_land(sid, name, gcd_src, cast_t, gap)
    emit(3, "cast.land", "sid=%s name=%s gcd_src=%s gap=%.3f cast_t=%.3f",
         tostring(sid), tostring(name), tostring(gcd_src or "?"),
         tonumber(gap) or 0, tonumber(cast_t) or 0)
end

function SLog.cast_refuse(sid, name, why, cdMs, gap)
    emit(2, "cast.refuse", "sid=%s name=%s why=%s cdMs=%.0f gap=%.3f",
         tostring(sid), tostring(name), tostring(why or "?"),
         tonumber(cdMs) or 0, tonumber(gap) or 0)
end

function SLog.cast_preblock(sid, name, reason, cdMs)
    emit(4, "cast.preblock", "sid=%s name=%s reason=%s cdMs=%.0f",
         tostring(sid), tostring(name), tostring(reason or "?"),
         tonumber(cdMs) or 0)
end

-- Rotation lifecycle
function SLog.rot_state(reason, target, edge, gcd, trace)
    emit(4, "rot.state", "reason=%s target=%s edge=%s gcd=%s trace=%s",
         tostring(reason or "?"), tostring(target or "?"),
         tostring(edge or "?"), tostring(gcd or "?"),
         tostring(trace or ""))
end

function SLog.rot_start(spells, ver)
    emit(3, "rot.start", "spells=%d ver=%s", tonumber(spells) or 0, tostring(ver or "?"))
end

function SLog.rot_stop(reason)
    emit(3, "rot.stop", "reason=%s", tostring(reason or "?"))
end

-- Heartbeat (1Hz)
function SLog.hb_player(x, y, z, facing, hp, combat)
    emit(4, "hb.player", "x=%.2f y=%.2f z=%.2f facing=%.1f hp=%.0f combat=%s",
         tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0,
         tonumber(facing) or 0, tonumber(hp) or 0,
         combat and "1" or "0")
end

function SLog.hb_perf(fps, frame_ms, budget, peak, sched_ms)
    emit(4, "hb.perf", "fps=%d frame=%.1fms budget=%.2f peak=%.2f sched=%.2f",
         tonumber(fps) or 0, tonumber(frame_ms) or 0,
         tonumber(budget) or 0, tonumber(peak) or 0,
         tonumber(sched_ms) or 0)
end

function SLog.hb_rotation(casts, gcd_src, running, last_err)
    emit(4, "hb.rot", "casts=%d gcd_src=%s running=%s err=%s",
         tonumber(casts) or 0, tostring(gcd_src or "none"),
         running and "1" or "0", tostring(last_err or ""))
end

function SLog.hb_om(bridge, npcs, players, gos, armed, mode)
    emit(4, "hb.om", "bridge=%d npcs=%d ply=%d gos=%d armed=%s mode=%s",
         bridge and 1 or 0, tonumber(npcs) or 0,
         tonumber(players) or 0, tonumber(gos) or 0,
         armed and "1" or "0", tostring(mode or "?"))
end

function SLog.hb_nav(state, active, obstacles)
    emit(4, "hb.nav", "state=%s active=%s obs=%d",
         tostring(state or "idle"), active and "1" or "0",
         tonumber(obstacles) or 0)
end

function SLog.hb_quest(state, goal, map, solved)
    emit(4, "hb.quest", "state=%s goal=%s map=%s solved=%s",
         tostring(state or "idle"), tostring(goal or "?"),
         tostring(map or "?"), solved and "1" or "0")
end

-- Runtime events
function SLog.runtime_online(ver)
    emit(3, "rt.online", "ver=%s", tostring(ver or "?"))
end

function SLog.runtime_offline()
    emit(2, "rt.offline", "")
end

function SLog.runtime_armed()
    emit(3, "rt.armed", "")
end

function SLog.runtime_hw_armed()
    emit(3, "rt.hwarmed", "")
end

-- OM events
function SLog.om_enable()
    emit(3, "om.enable", "")
end

function SLog.om_freeze()
    emit(2, "om.freeze", "")
end

function SLog.om_discover(units, total, mode)
    emit(4, "om.discover", "units=%d total=%d mode=%s",
         tonumber(units) or 0, tonumber(total) or 0, tostring(mode or "?"))
end

-- Bridge events
function SLog.br_registered(L, ver)
    emit(3, "br.reg", "L=0x%X ver=%s", tonumber(L) or 0, tostring(ver or "?"))
end

function SLog.br_call(name, arg_count)
    emit(5, "br.call", "name=%s args=%d", tostring(name or "?"), tonumber(arg_count) or 0)
end

-- Master / suite events
function SLog.master_on(modules, reason)
    emit(3, "master.on", "modules=%s reason=%s", tostring(modules or "?"), tostring(reason or "?"))
end

function SLog.master_off(reason, was)
    emit(3, "master.off", "reason=%s was=%s", tostring(reason or "?"), tostring(was or "?"))
end

-- Navigation events
function SLog.nav_move(x, y, z, state)
    emit(4, "nav.move", "x=%.2f y=%.2f z=%.2f state=%s",
         tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0, tostring(state or "?"))
end

function SLog.nav_stuck(reason)
    emit(2, "nav.stuck", "reason=%s", tostring(reason or "?"))
end

-- Config events
function SLog.cfg_set(key, value)
    emit(4, "cfg.set", "key=%s value=%s", tostring(key or "?"), tostring(value or ""))
end

-- Taint / security events
function SLog.taint_applied(count)
    emit(3, "taint.apply", "count=%d", tonumber(count) or 0)
end

-- IPC events
function SLog.ipc_connected()
    emit(3, "ipc.connect", "")
end

function SLog.ipc_cmd(cmd, id)
    emit(4, "ipc.cmd", "cmd=%s id=%d", tostring(cmd or "?"), tonumber(id) or 0)
end

-- ---- Metrics (rotation timing) --------------------------------------------

SLog._metrics_buf = {}
SLog._metrics_t = 0

function SLog.metrics_line(sess, ticks, att, land, ref, ph,
                            react_avg, react_p50, react_p95, react_std,
                            free_avg, free_p50, conf_avg, inter_avg, inter_std,
                            tick_avg, tick_max, land_pct, ref_pct, score)
    return string.format(
        "sess=%ss ticks=%d att=%d land=%d ref=%d ph=%d | " ..
        "react_ms avg=%.1f p50=%.1f p95=%.1f std=%.1f | " ..
        "free_ms avg=%.1f p50=%.1f | " ..
        "conf_ms avg=%.1f | inter_ms avg=%.0f std=%.0f | " ..
        "tick_ms avg=%.2f max=%.2f | land%%=%.0f ref%%=%.0f score=%.0f",
        tostring(sess), ticks, att, land, ref, ph,
        react_avg, react_p50, react_p95, react_std,
        free_avg, free_p50, conf_avg, inter_avg, inter_std,
        tick_avg, tick_max, land_pct, ref_pct, score)
end

function SLog.metrics_flush(line)
    SLog._metrics_buf[#SLog._metrics_buf + 1] = line
    local t = now()
    if (t - SLog._metrics_t) >= 10 or #SLog._metrics_buf >= 10 then
        SLog._metrics_t = t
        local chunk = table.concat(SLog._metrics_buf, "\n") .. "\n"
        SLog._metrics_buf = {}
        local dir = RaijinLab and RaijinLab.GetWoWDirectory and RaijinLab:GetWoWDirectory()
        if dir then
            local path = dir .. "\\Logs\\raijinlab_rot_metrics.log"
            if RaijinLab and RaijinLab.AppendFile then
                pcall(RaijinLab.AppendFile, RaijinLab, path, chunk)
            end
        end
    end
end

return SLog
