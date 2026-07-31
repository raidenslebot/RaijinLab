-- Live rotation tick.
-- Casts ONLY via RaijinLab.Actions -> runtime Spell_C_CastSpell (0x80DA40 cdecl).
-- Design: empty conditions = try when capable (target + not busy + off CD).
-- Never spam "ok" without evidence the client accepted the cast.

-- FORWARD DECLARATION.
--
-- log_cast is used at line ~155 but was declared with `local function` further
-- down, so at that point the name resolved to a GLOBAL and found nil: every
-- refusal path died with "attempt to call a nil value". A function closes over
-- the scope visible AT ITS DEFINITION, so the name has to exist first.
local log_cast
-- Same forward-declaration reason as log_cast: gate() is called at ~line 147
-- but declared far below, so the name resolved to a nil GLOBAL at that point.
local gate

local Executor = {}
Executor._last_cast = nil
Executor._last_err = nil
Executor._last_action = nil
Executor._cast_count = 0
Executor._tick_count = 0
Executor._debug = false
Executor._last_print_t = 0
Executor._last_attempt_t = 0
Executor._last_skip_key = nil
Executor._no_runtime_warned = false
Executor._gcd_until = 0          -- authoritative global-cooldown end time (GetTime clock)
Executor._pending = nil          -- a cast in flight awaiting client confirmation
Executor._recent = nil           -- { [sid] = expire_t } synthetic per-spell floor (anti self-spam)
Executor._unconf = nil           -- { sid, count } consecutive unconfirmed-cast streak (blind-detection guard)

-- Latency philosophy: the only acceptable delay is (a) the real GCD after a
-- CONFIRMED cast and (b) one client frame. Artificial recovery windows after
-- OOR / refuse must collapse the same tick the client state is known.

local function now()
    return (GetTime and GetTime()) or 0
end

-- One-way latency seconds (home/world max). Used to avoid "spell not ready"
-- spam when the action bar looks ready but the server still has GCD.
local function latency_sec()
    if not GetNetStats then return 0.08 end
    local ok, _, _, latHome, latWorld = pcall(GetNetStats)
    if not ok then return 0.08 end
    local ms = math.max(tonumber(latHome) or 0, tonumber(latWorld) or 0)
    if ms <= 0 then return 0.08 end
    local s = ms / 1000
    if s < 0.05 then s = 0.05 end
    if s > 0.40 then s = 0.40 end
    return s
end

-- Authoritative remaining GCD/CD for a spell (seconds). Prefer live GetSpellCooldown;
-- also honor Executor._gcd_until after a wire attempt. Includes lag pad so we
-- never re-fire while the server still thinks we are on GCD.
local function spell_ready_remaining(sid, name)
    local t = now()
    local best = 0
    local until_t = tonumber(Executor._gcd_until) or 0
    if until_t > t then best = until_t - t end
    if GetSpellCooldown then
        local function sample(key)
            if not key then return end
            local s, d = GetSpellCooldown(key)
            s, d = tonumber(s) or 0, tonumber(d) or 0
            if d > 0 then
                local rem = (s + d) - t
                if rem > best then best = rem end
            end
        end
        if name and name ~= "" then sample(name) end
        if sid and sid > 0 then sample(sid) end
        -- Any short CD is a GCD witness (WotLK book).
        sample(61304) -- GCD proxy if present on this client
    end
    -- Lag pad: bar can clear before server accepts next press.
    local pad = latency_sec() * 0.6
    if pad < 0.04 then pad = 0.04 end
    if best > 0 then best = best + pad end
    return best
end

local function refuse_is_not_ready(reason)
    reason = string.lower(tostring(reason or ""))
    if reason == "" then return false end
    return reason:find("not ready", 1, true)
        or reason:find("isn't ready", 1, true)
        or reason:find("is not ready", 1, true)
        or reason:find("not yet recovered", 1, true)
        or reason:find("on cooldown", 1, true)
        or reason:find("another action", 1, true)
end

local function metrics()
    return RaijinLab and RaijinLab.RotationMetrics
end

local function tick_timer_start()
    if debugprofilestop then return debugprofilestop() end
    return (GetTime and GetTime() or 0) * 1000
end

local function tick_timer_ms(t0)
    if not t0 then return 0 end
    if debugprofilestop then return debugprofilestop() - t0 end
    return ((GetTime and GetTime() or 0) * 1000) - t0
end

-- ---- Event-driven cast outcome (instant landed / refused) -----------------
-- Act.CastSpell returning true only means the CLIENT accepted the call; the
-- server can still refuse it (facing / LoS / range / not-ready / resource).
-- We used to POLL for the answer (GetSpellCooldown / UnitCastingInfo), which is
-- blind to many custom Ascension spells - so a refused "phantom" cast sat on the
-- provisional lock for the ENTIRE grace window (ping+60ms, up to 400ms) before
-- the deadline released it. That window is the "split second" before it retried.
-- The client already announces the outcome the frame it happens, so listen.
Executor._evt = { ok_t = 0, fail_t = 0, ok_name = nil, fail_name = nil, fail_msg = nil,
                  err_t = 0, err_msg = nil }
Executor._gcd_obs = nil          -- observed real GCD length (learned, smoothed)
Executor._gcd_src = "none"       -- where the last GCD came from (diagnostic)
Executor._refuse = nil           -- { sid, n } consecutive refusals of the same spell
Executor._log = {}               -- rolling cast log for /raijin castlog

-- UI_ERROR_MESSAGE fires for everything (bags, loot, ...), so only treat it as a
-- cast refusal when the text actually reads like one.
local CAST_ERR = {
    "range", "line of sight", "facing", "in front", "not ready", "isn't ready",
    "mana", "energy", "rage", "focus", "runic", "power", "immune", "too far",
    "can't do that", "cannot do that", "another action", "not yet recovered",
    "no target", "invalid target", "must be", "while moving", "interrupted",
    "corpse", "no corpses", "not enough", "you are in", "can't attack",
    "cannot attack", "item is busy", "busy", "spell not learned",
    "out of range", "you are too far", "target needs to be", "nothing to attack",
    "you can't", "you cannot", "not in line", "must have a", "more powerful",
    "a more powerful", "already", "on cooldown", "not enough runic",
    "i can't", "i cannot", "requires", "need a", "need to be",
    "friendly", "not attackable", "cannot be attacked", "wrong way",
    "you don't have a target", "need a target",
}

-- Bad cast targets (friendlies / invalid) — skip for a few seconds so we do not
-- spam the same GUID. Keyed by tostring(guid).
Executor._guid_bl = Executor._guid_bl or {}

local function blacklist_guid(guid, sec, why)
    guid = guid and tostring(guid) or nil
    if not guid or guid == "" then return end
    -- Cap multi-dot face/cast blacklist — long holds left Icy Touch stuck for
    -- 10–20s when every nearby unit was briefly "facing" blacklisted.
    sec = tonumber(sec) or 0.35
    if sec > 0.6 then sec = 0.6 end
    if sec < 0.05 then sec = 0.05 end
    Executor._guid_bl[guid] = (now()) + sec
end

function Executor.guid_blacklisted(guid)
    if not guid then return false end
    local t = Executor._guid_bl and Executor._guid_bl[tostring(guid)]
    if not t then return false end
    if t <= now() then
        Executor._guid_bl[tostring(guid)] = nil
        return false
    end
    return true
end

local function refuse_looks_bad_target(reason)
    reason = string.lower(tostring(reason or ""))
    if reason == "" then return false end
    return reason:find("invalid target", 1, true)
        or reason:find("friendly", 1, true)
        or reason:find("can't attack", 1, true)
        or reason:find("cannot attack", 1, true)
        or reason:find("not attackable", 1, true)
        or reason:find("cannot be attacked", 1, true)
        or reason:find("no target", 1, true)
        or reason:find("wrong way", 1, true)
        or reason:find("in front", 1, true)
        or reason:find("facing", 1, true)
end
local function looks_like_cast_error(msg)
    msg = tostring(msg or ""):lower()
    if msg == "" then return false end
    for i = 1, #CAST_ERR do
        if msg:find(CAST_ERR[i], 1, true) then return true end
    end
    return false
end

-- NOTE: we deliberately do NOT soft-exclude a failed sid across ticks.
-- Priority always re-evaluates top-down; the same ability may cast again as
-- soon as the client says it can (GCD / CD / range / conditions). Same-tick
-- fallthrough still uses a one-pass exclude so we can try the next slot if
-- THIS wire attempt failed, without locking the ability out of future ticks.
local function mark_failed_sid(_sid)
    -- no-op by design (kept as a call site so refuse paths stay readable)
end

-- Instant re-eval after a cast refuse. Prefer SAME-frame pcall(tick); only defer
-- if already inside a tick (then chain once on exit).
local function request_retick(why)
    if not RaijinLabDB or not RaijinLabDB.rotation_enabled then return end
    Executor._retick_why = why
    if Executor._in_tick then
        Executor._retick_pending = true
        return
    end
    if Executor._retick_depth and Executor._retick_depth >= 3 then
        -- Cap re-entry storms; one frame later is still far faster than grace.
        if C_Timer and C_Timer.After and not Executor._retick_armed then
            Executor._retick_armed = true
            C_Timer.After(0, function()
                Executor._retick_armed = false
                pcall(Executor.tick)
            end)
        end
        return
    end
    Executor._retick_depth = (Executor._retick_depth or 0) + 1
    pcall(Executor.tick)
    Executor._retick_depth = math.max(0, (Executor._retick_depth or 1) - 1)
end
Executor.request_retick = request_retick

-- Apply a refuse NOW (event path). Must not wait for the next OnUpdate or the
-- pending confirmation grace -- that was the multi-hundred-ms "forever" gap.
local function clear_sid_soft_locks(sid)
    sid = tonumber(sid) or 0
    if sid > 0 and Executor._recent then
        Executor._recent[sid] = nil
        Executor._recent[tostring(sid)] = nil
    end
    do
        local G = gate()
        if G and G.clear and sid > 0 then pcall(G.clear, sid) end
    end
end

-- Refuse handling: free the in-flight slot, but NEVER zero the GCD on
-- "not ready" — that was the mass spam of "spell not ready yet".
local function apply_pending_refuse(reason, fail_name)
    local p = Executor._pending
    if not p then return false end
    local pname = tostring(p.name or ""):lower()
    local fn = fail_name and tostring(fail_name):lower() or nil
    if fn and pname ~= "" and fn ~= pname and fn ~= "" then
        if not reason or reason == "" then return false end
    end
    local sid = p.sid
    local name = p.name
    local cast_t = p.cast_t
    local pguid = p.guid
    local rl = tostring(reason or ""):lower()
    Executor._pending = nil
    Executor._unconf = nil
    Executor._idle_until = nil
    Executor._next_gap = 0

    if refuse_is_not_ready(rl) then
        -- Server still on GCD/CD. Hold to live remaining. When GetSpellCooldown
        -- still reports ~0 (race after wire), use a full GCD floor — that is
        -- the real "not ready yet" state, not an artificial pause. Without
        -- this floor, Consecration re-wired every frame and spammed UI errors.
        local hold = spell_ready_remaining(sid, name)
        local gcd_floor = 0.75
        if Executor.gcd_fallback then
            local d = select(1, Executor.gcd_fallback())
            if d and d > gcd_floor then gcd_floor = d end
        end
        if hold < gcd_floor then hold = gcd_floor end
        if hold > 8.0 then hold = 8.0 end -- ability CDs (Consecration ~8s)
        Executor._gcd_until = now() + math.min(hold, gcd_floor + 0.05)
        -- Per-spell floor tracks full ability CD; global only tracks GCD so
        -- lower-priority spells can cast while Consecration recovers.
        Executor._gcd_provisional = true
        Executor._gcd_src = "not_ready_hold"
        Executor._recent = Executor._recent or {}
        if sid then Executor._recent[sid] = now() + hold end
        log_cast("refused", sid, name or fail_name, "not_ready_hold:" .. string.format("%.2f", hold), cast_t)
        return true
    end

    -- Other refuses: free GCD so a different slot can cast this frame.
    Executor._gcd_until = 0
    Executor._gcd_provisional = false
    Executor._gcd_src = "refuse_instant"
    clear_sid_soft_locks(sid)
    if refuse_looks_bad_target(rl) then
        -- Cap 0.6s via blacklist_guid; was 3s and killed multi-dot recovery.
        blacklist_guid(pguid or (Executor._last_cast and Executor._last_cast.guid), 0.45, rl)
        Executor._recent = Executor._recent or {}
        if sid then Executor._recent[sid] = now() + 0.08 end
    end
    -- Facing / LoS: short GUID cool (cap 0.6) so next mob can be tried soon.
    if rl:find("in front", 1, true) or rl:find("facing", 1, true)
        or rl:find("line of sight", 1, true) or rl:find("not in line", 1, true) then
        blacklist_guid(pguid or (Executor._last_cast and Executor._last_cast.guid), 0.35, rl)
    end
    if rl:find("corpse") then
        local WW = RaijinLab and RaijinLab.World
        local cg = Executor._last_cast and Executor._last_cast.corpse
        if WW then
            if cg and WW.invalidate_corpse then pcall(WW.invalidate_corpse, cg)
            elseif WW.invalidate_nearest_corpse then pcall(WW.invalidate_nearest_corpse, 40) end
        end
    end
    log_cast("refused", sid, name or fail_name, reason ~= "" and reason or "fail", cast_t)
    return true
end
Executor._apply_pending_refuse = apply_pending_refuse

local function ensure_events()
    if Executor._evt_frame or type(CreateFrame) ~= "function" then return end
    local f = CreateFrame("Frame")
    Executor._evt_frame = f
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    f:RegisterEvent("UNIT_SPELLCAST_FAILED")
    f:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    f:RegisterEvent("UI_ERROR_MESSAGE")
    f:SetScript("OnEvent", function(_, event, a1, a2)
        local e = Executor._evt
        local cast_fail, fail_name, reason = false, nil, nil
        if event == "UI_ERROR_MESSAGE" then
            local msg = (type(a2) == "string" and a2) or (type(a1) == "string" and a1) or ""
            if msg ~= "" then e.err_t = now(); e.err_msg = msg end
            if looks_like_cast_error(msg) then
                e.fail_t = now(); e.fail_msg = msg; e.fail_name = nil
                cast_fail, reason = true, msg
            end
        elseif a1 == "player" then
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                e.ok_t = now(); e.ok_name = a2
            else
                e.fail_t = now(); e.fail_name = a2; e.fail_msg = event
                cast_fail, fail_name, reason = true, a2, event
                if e.err_msg and (e.err_t or 0) >= (now() - 0.15) then
                    reason = e.err_msg
                end
            end
        end
        if cast_fail then
            if Executor._pending then
                local rl = tostring(reason or e.fail_msg or "")
                if apply_pending_refuse(reason, fail_name) then
                    -- Only re-eval immediately when another ability can cast
                    -- (not when we are holding for not-ready GCD).
                    if not refuse_is_not_ready(rl) then
                        request_retick("event_fail_instant")
                    end
                elseif looks_like_cast_error(rl) then
                    local p = Executor._pending
                    if p then
                        apply_pending_refuse(reason or "cast_err", p.name)
                        if not refuse_is_not_ready(reason or "") then
                            request_retick("event_fail_force")
                        end
                    end
                end
            end
        end
    end)
end
Executor._ensure_events = ensure_events

-- Always -> Debug tab. chat_verbose also mirrors to chat (DebugLog.Log).
-- Rotation logging is intentionally compact: casts/refuses always, idle waits
-- as a single line on change + slow heartbeat. Full per-slot dumps only when
-- Executor._debug is on or /raijin debug is enabled.
local function dlog(cat, fmt, ...)
    local RL = RaijinLab
    if RL and RL.Log then
        return RL:Log(cat, fmt, ...)
    end
    if RL and RL.DebugLog and RL.DebugLog.Log then
        return RL.DebugLog.Log(cat, fmt, ...)
    end
end

local function rot_detail()
    return Executor._debug or (RaijinLab and RaijinLab._debug_print) or false
end

-- Compact one-line summary of priority trace (no range spam).
local function format_trace_compact(trace)
    if not trace or not trace.n or trace.n <= 0 then return "" end
    local parts = {}
    for i = 1, math.min(trace.n, 12) do
        local tr = trace[i]
        if tr then
            local short = tostring(tr.name or ("#" .. tostring(tr.i)))
            if #short > 12 then short = short:sub(1, 10) .. ".." end
            local v = tostring(tr.verdict or "?")
            local why
            if v == "CAST" then
                why = "CAST"
            elseif v == "cond_fail" or v == "not_ready" or v == "basic_deny" then
                -- Always surface the real gate (was hiding as "basic_deny").
                why = tostring(tr.why or v)
            else
                why = v
            end
            if #why > 14 then why = why:sub(1, 12) .. ".." end
            parts[#parts + 1] = string.format("%s=%s", short, why)
        end
    end
    return table.concat(parts, " ")
end

-- Rolling diagnostic: what actually happened, and how long the gap really was.
function log_cast(result, sid, name, extra, cast_t)
    do
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then
            local prev = Executor._log[#Executor._log]
            Tel.info("cast", result, { spell = name, id = sid, why = extra,
                gap = prev and (now() - (prev.t or 0)) or nil,
                gcd_src = Executor._gcd_src })
        end
    end
    local t = now()
    local prev = Executor._log[#Executor._log]
    local gap = prev and (t - prev.t) or 0
    Executor._log[#Executor._log + 1] = {
        t = t, result = result, sid = sid, name = name,
        gap = gap, gcd_src = Executor._gcd_src, extra = extra,
    }
    while #Executor._log > 48 do table.remove(Executor._log, 1) end
    -- Always log land/refuse - the useful lines. Keep short.
    dlog("cast", "%s  %s  %s",
        tostring(result), tostring(name),
        extra and tostring(extra) or "")
    local M = metrics()
    if M then
        if result == "landed" and M.note_landed then
            M.note_landed(sid, cast_t, t)
        elseif result == "refused" and M.note_refused then
            M.note_refused(sid, cast_t, t, extra)
        end
    end
end
Executor._log_cast = log_cast

local function spell_name(sid, fallback)
    sid = tonumber(sid) or 0
    if sid > 0 and GetSpellInfo then
        local n = GetSpellInfo(sid)
        if n and n ~= "" then return n end
    end
    if fallback and fallback ~= "" and not tostring(fallback):match("^Spell%s") then
        return fallback
    end
    return fallback or ("Spell " .. tostring(sid))
end

-- 3.3.5 GetSpellInfo: name, rank, icon, cost, isFunnel, powerType, castTime,
-- minRange, maxRange. maxRange==0 usually means melee/self (no yard band).
local function spell_range_info(sid)
    sid = tonumber(sid) or 0
    if sid <= 0 or not GetSpellInfo then return 0, 0 end
    local _, _, _, _, _, _, _, minR, maxR = GetSpellInfo(sid)
    return tonumber(minR) or 0, tonumber(maxR) or 0
end

-- Combat reach (melee / unit-targeted). Descriptor + Trinity default 1.5.
local function combat_reach(unit)
    if not (RaijinLab and RaijinLab.ObjectCombatReach) then return 1.5 end
    local ok, v = pcall(RaijinLab.ObjectCombatReach, RaijinLab, unit)
    if not ok then return 1.5 end
    v = tonumber(v)
    if not v or v ~= v or v < 0 or v > 100 then return 1.5 end
    return v
end

-- Bounding radius (model body). Used only to EXTEND self-AoE for giant models.
local function bounding_radius(unit)
    if RaijinLab and RaijinLab.ObjectBoundingRadius then
        local ok, v = pcall(RaijinLab.ObjectBoundingRadius, RaijinLab, unit)
        if ok then
            v = tonumber(v)
            if v and v == v and v > 0 and v <= 80 then return v end
        end
    end
    return 0
end

-- Whirlwind / player-centered AoE radius (yards). Classic WotLK WW = 8.
local SELF_AOE_RADIUS = 8.0
-- Float noise only - never a soft range expand.
local RANGE_EPS = 0.05
-- Bounding must exceed this to extend the WW disk (boss/giant models).
local AOE_BOSS_BOUND = 2.0

local function aoe_extend_for(unit)
    local tb = bounding_radius(unit)
    if tb > AOE_BOSS_BOUND then return tb end
    return 0
end

-- Known self-AoE spell ids (Ascension / WotLK). Name match is a backup.
local SELF_AOE_IDS = {
    [1680] = true, [1681] = true, [1682] = true, [1683] = true,
    [1684] = true, [1685] = true, [1686] = true, -- Whirlwind ranks
    [6343] = true, [8198] = true, [8204] = true, [8205] = true, -- Thunder Clap
    [1449] = true, -- Arcane Explosion rank 1 (others by name)
}

local function is_self_aoe_spell(sid, name)
    sid = tonumber(sid) or 0
    if sid > 0 and SELF_AOE_IDS[sid] then return true end
    local n = string.lower(tostring(name or ""))
    if n == "" then return false end
    if n:find("whirlwind", 1, true) then return true end
    if n:find("thunder clap", 1, true) then return true end
    if n:find("arcane explosion", 1, true) then return true end
    if n:find("consecration", 1, true) then return true end
    if n:find("death and decay", 1, true) then return true end
    if n:find("fan of knives", 1, true) then return true end
    if n:find("blood boil", 1, true) then return true end
    if n:find("howling blast", 1, true) then return true end
    return false
end

-- Ground-under-feet AoE (Consecration, DnD, ...): cast at player, NEVER gate on
-- current target distance. Optional-disk spells (WW) still range-check when policy
-- is require.
local function is_ground_self_aoe(sid, name)
    local n = string.lower(tostring(name or ""))
    if n == "" and sid and GetSpellInfo then
        local ok, sn = pcall(GetSpellInfo, sid)
        if ok and sn then n = string.lower(sn) end
    end
    if n:find("consecration", 1, true) then return true end
    if n:find("death and decay", 1, true) then return true end
    if n:find("blizzard", 1, true) then return true end
    if n:find("rain of fire", 1, true) then return true end
    if n:find("hurricane", 1, true) then return true end
    if n:find("flamestrike", 1, true) then return true end
    if n:find("explosive trap", 1, true) then return true end
    if n:find("freezing trap", 1, true) then return true end
    if n:find("snake trap", 1, true) then return true end
    return false
end

-- Live 2D range model for the current target.
-- AUTHORITY: ObjectPosition(GUID) + ObjectCombatReach only.
-- Nameplates / CheckInteractDistance never supply yards.
-- Returns: edge, aoe_gap, center, pCombat, tCombat, precise.
local function live_range_model(ctx)
    local function pack(center, pr, tr, tguid)
        center = tonumber(center)
        if not center or center < 0 or center >= 900 then
            return nil, nil, nil, nil, nil, false
        end
        -- Collapsed-to-player is not a real reading.
        if center < 0.05 and tguid and UnitGUID then
            local pg = UnitGUID("player")
            if pg and tostring(tguid) ~= tostring(pg) then
                return nil, nil, nil, nil, nil, false
            end
        end
        pr = tonumber(pr) or 1.5
        tr = tonumber(tr) or 1.5
        if pr < 0 or pr > 100 then pr = 1.5 end
        if tr < 0 or tr > 100 then tr = 1.5 end
        local edge = center - pr - tr
        if edge < 0 then edge = 0 end
        -- Self-AoE: pure center for normal models; giant bound extends only.
        local aoe = center - aoe_extend_for(tguid or "target")
        if aoe < 0 then aoe = 0 end
        return edge, aoe, center, pr, tr, true
    end

    if RaijinLab and UnitExists and UnitExists("target") then
        local tguid = UnitGUID and UnitGUID("target") or nil
        -- GUID-first live positions every tick (no token / nameplate geometry).
        if RaijinLab.ObjectPosition then
            local okp, px, py = pcall(RaijinLab.ObjectPosition, RaijinLab, "player")
            local okt, tx, ty
            if tguid then
                okt, tx, ty = pcall(RaijinLab.ObjectPosition, RaijinLab, tguid)
            end
            if not (okt and tx) then
                okt, tx, ty = pcall(RaijinLab.ObjectPosition, RaijinLab, "target")
            end
            if okp and okt and px and tx then
                local dx, dy = px - tx, py - ty
                local center = math.sqrt(dx * dx + dy * dy)
                return pack(center,
                    combat_reach("player"),
                    combat_reach(tguid or "target"),
                    tguid)
            end
        end
        -- CombatDistance is ObjectPosition + reach under the hood; pass GUID.
        if RaijinLab.CombatDistance then
            local ok, edge, center, pr, tr =
                pcall(RaijinLab.CombatDistance, RaijinLab, "player", tguid or "target")
            if ok and center then
                local e, a, c, p, t, prec = pack(center, pr, tr, tguid)
                if prec then return (edge or e), a, c, p, t, true end
            end
        end
    end
    if ctx and ctx.target_distance_precise == true then
        local center = tonumber(ctx.target_distance_center)
        local tguid = UnitGUID and UnitGUID("target") or nil
        if center then
            return pack(center,
                tonumber(ctx.player_combat_reach),
                tonumber(ctx.target_combat_reach),
                tguid)
        end
    end
    return nil, nil, nil, nil, nil, false
end

function gate()
    return RaijinLab and RaijinLab.SpellGate
end

-- Authoritative in-range check (hitbox-accurate).
--
-- TARGETED: combat EDGE = center - pCombat - tCombat  vs  spell maxRange
--   Large boss combat reach => smaller edge => in range from farther pivot.
--
-- SELF-AoE (Whirlwind): aoe_gap = center - tBounding  vs  radius 8
--   Disk around your pivot; target BOUNDING radius into the disk (not the
--   inflated combat-reach field that was false-IN at 10+ yd).
--
-- Returns ok, why, diag
local function spell_in_range_vs_target(sid, name, ctx)
    name = name or spell_name(sid)
    local minR, maxR = spell_range_info(sid)
    local edge, aoe, center, pr, tr, precise = live_range_model(ctx)

    local client_r = nil
    if IsSpellInRange and name and name ~= "" and UnitExists and UnitExists("target") then
        local ok, r = pcall(IsSpellInRange, name, "target")
        if ok then client_r = r end
    end

    local is_aoe = is_self_aoe_spell(sid, name)
    if not is_aoe then
        if client_r == 0 or client_r == 1 then
            is_aoe = false
        elseif not maxR or maxR <= 0 then
            is_aoe = true
        end
    end

    local band = is_aoe and SELF_AOE_RADIUS or ((maxR and maxR > 0) and maxR or 5.0)
    local diag = {
        sid = sid, name = name, minR = minR, maxR = maxR, band = band,
        gap = is_aoe and aoe or edge, edge = edge, aoe = aoe, center = center,
        pReach = pr, tReach = tr, precise = precise and true or false,
        client = client_r == nil and "nil" or tostring(client_r),
        kind = is_aoe and "aoe" or "targeted",
    }

    -- Ground-at-feet self-AoE: always castable (optional target); never OOR on
    -- whoever happens to be targeted (that broke Consecration after auto-target).
    if is_aoe and is_ground_self_aoe(sid, name) then
        diag.verdict = "in_ground_aoe"
        diag.kind = "ground_aoe"
        return true, nil, diag
    end

    if not (UnitExists and UnitExists("target")) then
        -- Non-ground self-AoE (WW) / targeted: no target => not in range here.
        -- Optional-policy slots skip this function via skip_range.
        diag.verdict = "no_target"
        return false, "no_target", diag
    end

    ----------------------------------------------------------------------
    -- TARGETED: edge vs maxRange (both hitboxes)
    ----------------------------------------------------------------------
    if not is_aoe then
        if client_r == 0 then
            diag.verdict = "oor_client"
            return false, "oor", diag
        end
        if client_r == 1 then
            -- Client hitbox-aware; still reject obvious contradicting precise edge.
            if precise and edge ~= nil and maxR and maxR > 0
                and edge > (maxR + 0.75) then
                diag.verdict = "oor_client_vs_edge"
                diag.gap = edge
                return false, "oor", diag
            end
            diag.verdict = "in_client"
            return true, nil, diag
        end
        if precise and edge ~= nil then
            diag.gap = edge
            if minR and minR > 0 and edge + RANGE_EPS < minR then
                diag.verdict = "oor_min"
                return false, "oor", diag
            end
            if edge > band + RANGE_EPS then
                diag.verdict = "oor_edge"
                return false, "oor", diag
            end
            diag.verdict = "in_edge"
            return true, nil, diag
        end
        -- No CheckInteract soft-IN. Without ObjectPosition yards we fail closed.
        diag.verdict = "oor_no_pos"
        return false, "oor", diag
    end

    ----------------------------------------------------------------------
    -- SELF-AoE: ALWAYS gate on CURRENT TARGET (never nearest pack member).
    -- gap ~= center2d (humanoids); giants subtract large bounding only.
    -- Fail-closed: no interact soft-IN, no measure-nil cast.
    ----------------------------------------------------------------------
    local measure, via = nil, nil
    local tguid = UnitGUID and UnitGUID("target") or nil
    local tref = tguid or "target"
    if precise and aoe ~= nil then
        measure, via = aoe, "target_guid"
    end
    if measure == nil and RaijinLab and RaijinLab.AoEDistance then
        local ok, gap = pcall(RaijinLab.AoEDistance, RaijinLab, "player", tref)
        if ok and gap and gap >= 0 and gap < 900 then
            measure, via = gap, "live_guid"
        end
    end
    if measure == nil and RaijinLab and RaijinLab.ObjectPosition then
        local okp, px, py = pcall(RaijinLab.ObjectPosition, RaijinLab, "player")
        local okt, tx, ty = pcall(RaijinLab.ObjectPosition, RaijinLab, tref)
        if okp and okt and px and tx then
            local dx, dy = px - tx, py - ty
            local d = math.sqrt(dx * dx + dy * dy)
            if d >= 0 and d < 900 then
                local gap = d - aoe_extend_for(tref)
                if gap < 0 then gap = 0 end
                measure, via = gap, "pos_guid"
            end
        end
    end

    diag.gap = measure
    diag.via = via
    diag.center = center
    diag.extend = aoe_extend_for("target")
    diag.precise = measure ~= nil

    if measure ~= nil then
        if measure > SELF_AOE_RADIUS + RANGE_EPS then
            diag.verdict = "oor_aoe"
            return false, "oor", diag
        end
        diag.verdict = "in_aoe"
        return true, nil, diag
    end

    -- No precise position -> do NOT cast (fail closed). Interact is not enough.
    diag.verdict = "oor_need_pos"
    return false, "oor", diag
end

-- Corpse condition range on a slot (nil if not a corpse-gated slot).
local function slot_corpse_range(slot)
    if not slot then return nil end
    for _, c in ipairs(slot.conditions or {}) do
        if c and c.id == "corpse" then
            return tonumber(c.args and c.args.range) or 30
        end
    end
    return nil
end

local function slot_policy(slot)
    local Eng = RaijinLab and RaijinLab.RotationEngine
    if Eng and Eng.slot_target_policy then return Eng.slot_target_policy(slot) end
    if slot_corpse_range(slot) then return "corpse" end
    return "require"
end

local function is_corpse_consume_name(name)
    local nm = string.lower(tostring(name or ""))
    if nm == "" then return false end
    return nm:find("soul capture", 1, true)
        or nm:find("capture soul", 1, true)
        or nm:find("soulsteal", 1, true)
        or nm:find("corpse explosion", 1, true)
        or nm:find("cannibal", 1, true)
        or nm:find("raise dead", 1, true)
        or nm:find("animate dead", 1, true)
end

-- Live client castability.
-- opts.policy = require|optional|forbid|corpse (from Target Existence / corpse).
-- opts.skip_range / skip_usable for corpse path that already validated.
-- When ctx.aura_search_hit.guid is set, multi-dot may cast on that GUID without
-- a successful client TargetUnit (avoids taint + lag).
local function live_castable(sid, name, opts)
    opts = opts or {}
    name = name or spell_name(sid)
    local policy = opts.policy or "require"
    local needs_enemy = (policy == "require")
    if opts.needs_enemy ~= nil then needs_enemy = opts.needs_enemy end
    local search_guid = opts.ctx and opts.ctx.aura_search_hit and opts.ctx.aura_search_hit.guid
    if needs_enemy then
        local have_target = UnitExists and UnitExists("target")
        if not have_target and not search_guid then
            return false, "no_target"
        end
        if have_target then
            if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") and not search_guid then
                return false, "target_dead"
            end
            if UnitCanAttack and not UnitCanAttack("player", "target") and not search_guid then
                return false, "not_enemy"
            end
        end
        if not opts.skip_range then
            if have_target and (not search_guid or (UnitGUID and UnitGUID("target")
                and tostring(UnitGUID("target")) == tostring(search_guid))) then
                local ok, why = spell_in_range_vs_target(sid, name, opts.ctx)
                if not ok then return false, why end
            elseif search_guid and RaijinLab and RaijinLab.ObjectPosition then
                -- Range vs search unit by GUID positions (no client target needed).
                local px, py = RaijinLab:ObjectPosition("player")
                local tx, ty = RaijinLab:ObjectPosition(search_guid)
                if px and tx then
                    local dx, dy = px - tx, py - ty
                    local center = math.sqrt(dx * dx + dy * dy)
                    local minR, maxR = spell_range_info(sid)
                    local band = (maxR and maxR > 0) and maxR or 30
                    local pr = 1.5
                    local tr = 1.5
                    if RaijinLab.ObjectCombatReach then
                        pr = tonumber(RaijinLab:ObjectCombatReach("player")) or 1.5
                        tr = tonumber(RaijinLab:ObjectCombatReach(search_guid)) or 1.5
                    end
                    local edge = center - pr - tr
                    if edge < 0 then edge = 0 end
                    if edge > band + 0.5 then return false, "oor" end
                    if minR and minR > 0 and edge + 0.05 < minR then return false, "oor" end
                end
            end
        end
        -- FACING + LOS (unit-target only): WotLK HasInArc(M_PI) = 180° front
        -- hemisphere (half-angle π/2). Instant re-eval every tick — no sticky
        -- lockout. NEVER wire a cast that will spam "in front" / "line of sight".
        -- skip_facing is set for ground self-AoE / self / no unit target.
        if not opts.skip_facing or not opts.skip_los then
            local Wf = RaijinLab and RaijinLab.World
            local face_ref = search_guid
            if not face_ref and have_target and UnitGUID then
                face_ref = UnitGUID("target")
            end
            if face_ref then
                local BR = RaijinLab and RaijinLab.BasicRules
                if BR and BR.guid_cast_gates then
                    local gok, gwhy = BR.guid_cast_gates(face_ref, {
                        skip_facing = opts.skip_facing,
                        skip_los = opts.skip_los,
                    })
                    if not gok then return false, gwhy end
                else
                    -- Only measured not-facing blocks (nil undetermined allows).
                    if not opts.skip_facing and Wf and Wf.is_not_facing_guid then
                        if Wf.is_not_facing_guid(face_ref, Wf.CAST_FACE_HALF_ARC) then
                            return false, "facing"
                        end
                    end
                    if not opts.skip_los and Wf and Wf.is_los_guid then
                        if Wf.is_los_guid(face_ref) == false then
                            return false, "los"
                        end
                    end
                end
            end
        end
    elseif policy == "forbid" then
        if UnitExists and UnitExists("target") then return false, "has_target" end
    end
    -- IsUsableSpell greys targeted spells when client has no "target" unit even
    -- if we will CastSpell(guid). With aura_search_hit.guid, only trust nomana.
    if not opts.skip_usable and IsUsableSpell then
        local usable, nomana = IsUsableSpell(name)
        if usable == nil and sid then usable, nomana = IsUsableSpell(sid) end
        if not usable then
            if nomana then return false, "no_resource" end
            if policy == "require" and not search_guid then
                return false, "unusable"
            end
            -- search_guid / optional / corpse: ignore grey-from-no-target.
        end
    end
    -- Hard CD + GCD gate (lag-padded). Never wire when server still has GCD.
    local rem = spell_ready_remaining(sid, name)
    if rem > 0.05 then return false, "cooldown" end
    return true, nil
end

-- Authoritative per-spell readiness from the client THIS frame.
-- Overwrites ctx cooldowns / usable / range / instant so evaluate never uses stale data.
local function fill_live_spell_state(ctx, spell_ids)
    ctx = ctx or {}
    ctx.cooldowns = ctx.cooldowns or {}
    ctx.spell_usable = ctx.spell_usable or {}
    ctx.spell_in_range = ctx.spell_in_range or {}
    ctx.spell_instant = ctx.spell_instant or {}
    ctx.spell_targeted = ctx.spell_targeted or {}
    ctx.known_spells = ctx.known_spells or {}
    local t = now()
    local gcd_rem = 0
    local has_target = UnitExists and UnitExists("target")
    for _, id in ipairs(spell_ids or {}) do
        id = tonumber(id) or 0
        if id > 0 then
            local name = spell_name(id)
            -- Cooldown
            local rem = 0
            if GetSpellCooldown then
                local s, d = GetSpellCooldown(name)
                if (not s or s == 0) then s, d = GetSpellCooldown(id) end
                s, d = tonumber(s) or 0, tonumber(d) or 0
                if d > 0 then
                    rem = (s + d) - t
                    if rem < 0 then rem = 0 end
                    -- Track real GCD window from any short CD
                    if d <= 1.6 and rem > gcd_rem then gcd_rem = rem end
                end
            end
            ctx.cooldowns[id] = rem
            ctx.cooldowns[tostring(id)] = rem
            -- Usable (resource/stance) - definitive false only
            if IsUsableSpell then
                local u, nomana = IsUsableSpell(name)
                if u == nil then u, nomana = IsUsableSpell(id) end
                local can = not not u
                if nomana then can = false end
                ctx.spell_usable[id] = can
                ctx.spell_usable[tostring(id)] = can
            end
            -- Always probe live client state. No sticky hard-blocks.
            ctx.spell_range_diag = ctx.spell_range_diag or {}
            ctx.spell_sticky = ctx.spell_sticky or {}
            local targeted = false
            local inr = true
            if has_target then
                local ok, why, diag = spell_in_range_vs_target(id, name, ctx)
                ctx.spell_range_diag[id] = diag
                ctx.spell_range_diag[tostring(id)] = diag
                local self_aoe = (diag and diag.kind == "aoe") or is_self_aoe_spell(id, name)
                if not ok and (why == "oor" or why == "facing" or why == "los") then
                    inr = false
                    targeted = not self_aoe
                elseif self_aoe then
                    targeted = false
                else
                    local _, maxR_live = spell_range_info(id)
                    if maxR_live and maxR_live > 0 then targeted = true end
                    if IsSpellInRange and name and name ~= "" then
                        local rok, r = pcall(IsSpellInRange, name, "target")
                        if rok and r ~= nil then targeted = true end
                    end
                end
            else
                local minR, maxR = spell_range_info(id)
                if maxR and maxR > 0 and not is_self_aoe_spell(id, name) then
                    targeted = true
                    inr = false
                end
                ctx.spell_range_diag[id] = { sid = id, name = name, minR = minR, maxR = maxR, verdict = "no_target" }
            end
            ctx.spell_in_range[id] = inr
            ctx.spell_in_range[tostring(id)] = inr
            ctx.spell_targeted[id] = targeted
            ctx.spell_targeted[tostring(id)] = targeted
            -- Instant?
            local instant = true
            if GetSpellInfo then
                local _, _, _, _, _, _, castTime = GetSpellInfo(id)
                castTime = tonumber(castTime)
                if castTime and castTime > 0 then instant = false end
            end
            ctx.spell_instant[id] = instant
            ctx.spell_instant[tostring(id)] = instant
            -- Known: Ascension custom IDs often fail IsSpellKnown while still
            -- castable. If GetSpellInfo resolves a name, treat as known.
            local k = true
            if IsSpellKnown then
                local okk, known = pcall(IsSpellKnown, id)
                if okk and known == false then
                    k = false
                    if GetSpellInfo then
                        local okn, sn = pcall(GetSpellInfo, id)
                        if okn and sn and sn ~= "" then k = true end
                    end
                end
            end
            ctx.known_spells[id] = k
            ctx.known_spells[tostring(id)] = k
        end
    end
    ctx.live_gcd_remaining = gcd_rem
    return ctx
end

-- Policy overrides: corpse range-to-body; Target Existence any/no_target skip range.
local function apply_slot_policy_overrides(ctx, rotation)
    if not ctx or not rotation then return end
    local W = RaijinLab and RaijinLab.World
    ctx._corpse_for_spell = ctx._corpse_for_spell or {}
    ctx._slot_policy_by_sid = ctx._slot_policy_by_sid or {}
    for _, slot in ipairs(rotation.slots or {}) do
        local sid = tonumber(slot.spell_id) or 0
        if sid > 0 then
            local policy = slot_policy(slot)
            ctx._slot_policy_by_sid[sid] = policy
            if policy == "optional" or policy == "forbid" then
                -- Explicitly allowed without a target: never living-target range gate.
                ctx.spell_in_range[sid] = true
                ctx.spell_in_range[tostring(sid)] = true
                ctx.spell_targeted[sid] = false
                ctx.spell_targeted[tostring(sid)] = false
            end
            -- Ground self-AoE always in range regardless of target (Consecration).
            local sname = spell_name(sid, slot.name)
            if is_ground_self_aoe(sid, sname) then
                ctx.spell_in_range[sid] = true
                ctx.spell_in_range[tostring(sid)] = true
                ctx.spell_targeted[sid] = false
                ctx.spell_targeted[tostring(sid)] = false
            end
            if policy == "corpse" and W and W.nearest_available_corpse then
                local cr = slot_corpse_range(slot) or 30
                local corpse = W.nearest_available_corpse(cr)
                local minR, maxR = spell_range_info(sid)
                local lim = cr
                if maxR and maxR > 0 and maxR < lim then lim = maxR end
                local inr = false
                -- Require verified client-visible body only.
                if corpse and corpse.guid and corpse.verified
                    and tonumber(corpse.dist) and corpse.dist <= lim then
                    inr = true
                end
                ctx.spell_in_range[sid] = inr
                ctx.spell_in_range[tostring(sid)] = inr
                ctx.spell_targeted[sid] = false
                ctx.spell_targeted[tostring(sid)] = false
                if inr then
                    ctx.spell_usable[sid] = true
                    ctx.spell_usable[tostring(sid)] = true
                    ctx._corpse_for_spell[sid] = corpse
                else
                    ctx._corpse_for_spell[sid] = nil
                end
            end
        end
    end
end

-- Does this slot need a living attackable enemy?
local function slot_needs_enemy(slot, sid, ctx)
    local policy = (slot and slot_policy(slot))
        or (ctx and ctx._slot_policy_by_sid and ctx._slot_policy_by_sid[sid])
        or "require"
    return policy == "require"
end

local function target_guid()
    if UnitGUID and UnitExists and UnitExists("target") then
        return UnitGUID("target")
    end
    return nil
end

local function say(msg)
    dlog("rot", "%s", tostring(msg))
end

local function say_throttled(msg, minGap)
    -- No longer throttles away from the Debug log: every call is recorded.
    -- minGap only dedupes identical consecutive chat floods if needed later.
    dlog("rot", "%s", tostring(msg))
end

-- Snapshot of cast-related client state for pre/post comparison
local function cast_snapshot(sid)
    local name = spell_name(sid)
    local snap = {
        t = now(),
        casting = (UnitCastingInfo and UnitCastingInfo("player") ~= nil) or false,
        channel = (UnitChannelInfo and UnitChannelInfo("player") ~= nil) or false,
        current = false,
        cd_start = 0,
        cd_dur = 0,
        gcd_start = 0,
        gcd_dur = 0,
    }
    if IsCurrentSpell then
        local ok, cur = pcall(IsCurrentSpell, sid)
        if ok then snap.current = not not cur end
    end
    if GetSpellCooldown then
        local s, d = GetSpellCooldown(sid)
        if (not s or s == 0) and name then s, d = GetSpellCooldown(name) end
        snap.cd_start = tonumber(s) or 0
        snap.cd_dur = tonumber(d) or 0
        -- Global cooldown often exposed via any known auto-attack / book spell remaining
        local gs, gd = GetSpellCooldown(61304) -- retail GCD token; may be nil on 3.3.5
        if not gs then
            -- fallback: if any short CD appeared after cast we still detect via spell CD
            gs, gd = 0, 0
        end
        snap.gcd_start = tonumber(gs) or 0
        snap.gcd_dur = tonumber(gd) or 0
    end
    return snap
end

-- True if post-cast client state shows the cast was accepted
local function cast_had_effect(before, after, sid)
    if not before or not after then return false end
    if after.casting and not before.casting then return true, "casting" end
    if after.channel and not before.channel then return true, "channel" end
    if after.current and not before.current then return true, "current" end
    -- Spell cooldown started or duration increased
    if after.cd_dur and after.cd_dur > 0 then
        if after.cd_start > (before.cd_start or 0) + 0.01 then return true, "cooldown" end
        if after.cd_dur > (before.cd_dur or 0) + 0.01 and after.cd_start > 0 then
            return true, "cooldown"
        end
    end
    if after.gcd_dur and after.gcd_dur > 0 and after.gcd_start > (before.gcd_start or 0) + 0.01 then
        return true, "gcd"
    end
    -- Combat swing / attack toggle as weak signal for melee
    if IsCurrentSpell then
        local ok, cur = pcall(IsCurrentSpell, sid)
        if ok and cur then return true, "current" end
    end
    return false, nil
end

-- ============================================================
-- Config storage (account SV with per-character buckets)
-- ============================================================
-- ALWAYS write active_config through set_active_name() so it hits the real
-- SavedVariables fields. Never use a throwaway table for active_config - that
-- was the "configs keep switching" bug (ephemeral wrapper lost the pointer).
--
-- Preferred store: RaijinLabDB.characters[Name-Realm]
-- Fallback (pre-PEW / no UnitName): RaijinLabDB.rotations + active_rotation
-- On logout we mirror character -> legacy so both sources stay consistent.

local function _store()
    RaijinLabDB = RaijinLabDB or {}
    local c = RaijinLab.CharacterDB and RaijinLab:CharacterDB() or nil
    if c then
        c.rotations = c.rotations or {}
        if type(c.active_config) ~= "string" or c.active_config == "" then
            c.active_config = "Default"
        end
        return c.rotations, c, false
    end
    RaijinLabDB.rotations = RaijinLabDB.rotations or {}
    if type(RaijinLabDB.active_rotation) ~= "string" or RaijinLabDB.active_rotation == "" then
        RaijinLabDB.active_rotation = "Default"
    end
    -- Synthetic character-like table that WRITES THROUGH to real SV fields.
    -- rotations is a shared reference; active_config is a property we re-read.
    local proxy = {
        rotations = RaijinLabDB.rotations,
    }
    -- Lua 5.1 has no property syntax; callers must use _get_active/_set_active.
    return RaijinLabDB.rotations, proxy, true
end

local function _get_active(c, legacy)
    if legacy then
        return RaijinLabDB.active_rotation or "Default"
    end
    return (c and c.active_config) or "Default"
end

local function _set_active(c, legacy, name)
    name = tostring(name or "Default")
    if name == "" then name = "Default" end
    if legacy then
        RaijinLabDB.active_rotation = name
    else
        if c then c.active_config = name end
        -- Always mirror so account-level backup and pre-PEW paths agree.
        RaijinLabDB.active_rotation = name
    end
    return name
end

-- How many slots hold a real spell? A rotation can be PRESENT and still be
-- incapable of doing anything, which is a different state from missing.
local function _filled_count(data)
    if type(data) ~= "table" then return 0 end
    local n = 0
    for _, sl in ipairs(data.slots or {}) do
        if (tonumber(sl.spell_id) or 0) ~= 0 then n = n + 1 end
    end
    return n
end

-- The most populated rotation in the store, excluding `skip`. Deterministic:
-- ties break on lowercase name so the choice never flickers between ticks.
local function _best_populated(rots, skip)
    local names = {}
    for k in pairs(rots or {}) do
        if type(k) == "string" and k ~= "" then names[#names + 1] = k end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    local bn, bc
    for _, n in ipairs(names) do
        if n ~= skip then
            local c = _filled_count(rots[n])
            if c > 0 and (not bc or c > bc) then bn, bc = n, c end
        end
    end
    return bn, bc
end

local function _first_config_name(rots)
    local names = {}
    for k, _ in pairs(rots or {}) do
        if type(k) == "string" and k ~= "" then names[#names + 1] = k end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names[1]
end

function Executor.get_active_rotation()
    if not RaijinLabDB then return nil end
    local Engine = RaijinLab.RotationEngine
    if not Engine then return nil end
    -- Heal character/legacy stores before reading (empty shell vs real config).
    if RaijinLab.MigrateLegacyRotationsToCharacter and UnitName and UnitName("player") then
        if not Executor._migrated_tick then
            Executor._migrated_tick = true
            pcall(RaijinLab.MigrateLegacyRotationsToCharacter, RaijinLab)
        end
    end
    local rots, c, legacy = _store()
    local name = _get_active(c, legacy)

    -- Fast path. Keyed on the SELECTED name, not the resolved one: when an empty
    -- selection falls back to a populated rotation the two differ, and comparing
    -- against the resolved name would miss every time and re-deserialize at 70Hz.
    local selected = name
    if Executor._active_cache and Executor._resolved_from == selected then
        return Executor._active_cache, Executor._active_name
    end

    local data = rots[name]
    -- Dangling pointer (deleted/renamed config, migration glitch): fall back to
    -- an existing config instead of silently inventing an empty "Default".
    if type(data) ~= "table" then
        local fallback = _first_config_name(rots)
        if fallback and fallback ~= name then
            name = _set_active(c, legacy, fallback)
            data = rots[name]
        end
    end
    if type(data) ~= "table" then
        -- Try account-level legacy once more before inventing empty Default.
        if type(RaijinLabDB.rotations) == "table" then
            for n, d in pairs(RaijinLabDB.rotations) do
                if type(n) == "string" and type(d) == "table" then
                    if RaijinLab.MergeRotationInto then
                        RaijinLab.MergeRotationInto(rots, n, d)
                    elseif rots[n] == nil then
                        rots[n] = d
                    end
                end
            end
            data = rots[name] or rots[_first_config_name(rots)]
            if data then name = name or _first_config_name(rots) end
        end
    end
    if type(data) ~= "table" then
        -- Truly empty store: create one Default so the UI has something.
        name = _set_active(c, legacy, "Default")
        local r = Engine.new_rotation(name)
        Engine.ensure_trailing_empty(r)
        -- Only seed if still missing — never clobber a real config.
        if rots[name] == nil then
            rots[name] = Engine.serialize(r)
        end
        data = rots[name]
    end

    -- EMPTY BUT PRESENT. The dangling-pointer check above only catches a missing
    -- table, so an empty rotation sails through it. That is how a character stood
    -- idle for 166 minutes with a 10-spell "Raiden Reaper" sitting directly beside
    -- the empty "Raiden Hero" it had selected, while the executor warned 2671
    -- times and did nothing about it. Presence is not capability.
    --
    -- We do NOT rewrite the stored selection: the editor shares it, so silently
    -- reassigning it would make an empty rotation impossible to open and edit.
    -- This is an execution-time fallback only, announced once.
    if _filled_count(data) == 0 then
        local alt, cnt = _best_populated(rots, name)
        if alt then
            if Executor._empty_notice ~= name then
                Executor._empty_notice = name
                say("rotation '" .. tostring(name) .. "' is empty - running '" ..
                    tostring(alt) .. "' (" .. tostring(cnt) .. " spells) instead." ..
                    "  Pick one with /raijin rotation use <name>")
                local Tel = RaijinLab and RaijinLab.Telemetry
                if Tel then Tel.warn("rot", "autoswitch",
                    { from = name, to = alt, spells = cnt }) end
            end
            name = alt
            data = rots[alt]
        end
    else
        Executor._empty_notice = nil
        _set_active(c, legacy, name)
    end

    local rot = Engine.deserialize(data)
    Executor._active_cache = rot
    Executor._active_name = name
    Executor._resolved_from = selected
    return rot, name
end

-- Config-management API for the multi-config picker UI.
function Executor.list_configs()
    local rots, c, legacy = _store()
    local out = {}
    for k, _ in pairs(rots or {}) do
        if type(k) == "string" and k ~= "" then out[#out + 1] = k end
    end
    table.sort(out, function(a, b) return string.lower(a) < string.lower(b) end)
    return out, _get_active(c, legacy)
end

-- Name -> number of slots that actually hold a spell, for THIS character's store.
-- Exists because "which of my rotations are empty?" was previously unanswerable
-- without opening each one in the editor - which is how an empty rotation stayed
-- selected for a whole session while a filled one sat beside it.
function Executor.config_summary()
    local rots, c, legacy = _store()
    local out, order = {}, {}
    for name, data in pairs(rots or {}) do
        if type(name) == "string" and name ~= "" then
            local filled, total = 0, 0
            local slots = (type(data) == "table" and data.slots) or {}
            for _, sl in ipairs(slots) do
                total = total + 1
                if type(sl) == "table" and (tonumber(sl.spell_id) or 0) ~= 0 then
                    filled = filled + 1
                end
            end
            out[name] = { filled = filled, total = total }
            order[#order + 1] = name
        end
    end
    table.sort(order, function(a, b) return string.lower(a) < string.lower(b) end)
    return out, order, _get_active(c, legacy)
end

-- opts.create = true  -> create empty config if missing (New button only)
-- Without create, missing names refuse so Cycle never invents empty slots.
function Executor.set_active_config(name, opts)
    if type(name) ~= "string" or name == "" then return false, "empty_name" end
    opts = opts or {}
    local rots, c, legacy = _store()
    if not rots[name] then
        if not opts.create then return false, "not_found" end
        local Engine = RaijinLab.RotationEngine
        if not Engine then return false, "no_engine" end
        local r = Engine.new_rotation(name)
        Engine.ensure_trailing_empty(r)
        rots[name] = Engine.serialize(r)
    end
    -- Flush current in-memory rotation into its previous name BEFORE switching,
    -- so we never lose unsaved slot edits when the user flips configs.
    if Executor._active_cache and Executor._active_name and Executor._active_name ~= name then
        local Engine = RaijinLab.RotationEngine
        if Engine then
            rots[Executor._active_name] = Engine.serialize(Executor._active_cache)
        end
    end
    _set_active(c, legacy, name)
    Executor._active_cache = nil
    Executor._active_name = nil
    Executor._dirty_since_flush = true
    return true
end

function Executor.rename_config(oldName, newName)
    if type(newName) ~= "string" or newName == "" then return false, "empty_name" end
    if oldName == newName then return true end
    local rots, c, legacy = _store()
    if not rots[oldName] then return false, "not_found" end
    if rots[newName] ~= nil then return false, "name_taken" end
    -- Persist live edits under the old name first.
    if Executor._active_cache and Executor._active_name == oldName then
        local Engine = RaijinLab.RotationEngine
        if Engine then
            rots[oldName] = Engine.serialize(Executor._active_cache)
        end
    end
    rots[newName] = rots[oldName]
    rots[oldName] = nil
    if _get_active(c, legacy) == oldName then
        _set_active(c, legacy, newName)
    end
    if Executor._active_name == oldName then
        Executor._active_name = newName
    end
    Executor._dirty_since_flush = true
    return true
end

function Executor.delete_config(name)
    local rots, c, legacy = _store()
    if not rots[name] then return false end
    -- Never delete the last config - leave at least Default.
    local count = 0
    for k, _ in pairs(rots) do
        if type(k) == "string" then count = count + 1 end
    end
    if count <= 1 then return false, "last_config" end
    rots[name] = nil
    if _get_active(c, legacy) == name then
        local next_name = _first_config_name(rots) or "Default"
        _set_active(c, legacy, next_name)
    end
    if Executor._active_name == name then
        Executor._active_cache = nil
        Executor._active_name = nil
    end
    Executor._dirty_since_flush = true
    return true
end

-- Deep-copy one config into another name. Overwrites dest if it exists unless
-- opts.no_overwrite. Copies the serialized rotation table (slots + conditions).
-- opts.switch = true (default) makes the copy the active config.
function Executor.copy_config(srcName, destName, opts)
    opts = opts or {}
    if type(srcName) ~= "string" or srcName == "" then return false, "empty_src" end
    if type(destName) ~= "string" or destName == "" then return false, "empty_dest" end
    if srcName == destName then return false, "same_name" end
    local rots, c, legacy = _store()
    if not rots[srcName] then return false, "src_not_found" end
    if rots[destName] ~= nil and opts.no_overwrite then return false, "dest_exists" end
    -- Flush live edits of source if it's the active in-memory rotation.
    local Engine = RaijinLab.RotationEngine
    if Executor._active_cache and Executor._active_name == srcName and Engine then
        rots[srcName] = Engine.serialize(Executor._active_cache)
    end
    local src = rots[srcName]
    local copy
    if Engine and Engine.serialize and Engine.deserialize then
        -- Round-trip through deserialize/serialize for a clean deep copy.
        local live = Engine.deserialize(src)
        if type(live) == "table" then
            live.name = destName
            copy = Engine.serialize(live)
        end
    end
    if not copy then
        -- Fallback: shallow table clone of serializable fields via Persistence.
        local P = RaijinLab.Persistence
        if P and P.Sanitize then
            copy = P.Sanitize(src)
        else
            copy = src  -- last resort (shared ref - avoid)
            if type(src) == "table" then
                copy = {}
                for k, v in pairs(src) do copy[k] = v end
            end
        end
        if type(copy) == "table" then copy.name = destName end
    end
    if type(copy) ~= "table" then return false, "copy_failed" end
    copy.name = destName
    rots[destName] = copy
    if opts.switch ~= false then
        _set_active(c, legacy, destName)
        Executor._active_cache = nil
        Executor._active_name = nil
    end
    Executor._dirty_since_flush = true
    return true
end

function Executor.save_rotation(rotation, name, opts)
    if not RaijinLabDB then return false end
    opts = opts or {}
    local Engine = RaijinLab.RotationEngine
    if not Engine then return false end
    local rots, c, legacy = _store()
    name = name or _get_active(c, legacy) or "Default"
    local ser = Engine.serialize(rotation)
    if type(ser) ~= "table" then return false end
    -- NEVER silently wipe a real config with an empty shell (flush/autocommit/
    -- deserialize glitch). Explicit editor save may pass force=true to clear.
    local existing = rots[name]
    local is_real = RaijinLab.IsRealRotation or function(r)
        if type(r) ~= "table" then return false end
        for _, sl in ipairs(r.slots or {}) do
            if type(sl) == "table" and (tonumber(sl.spell_id) or 0) ~= 0 then return true end
        end
        return false
    end
    if not opts.force and not is_real(ser) and is_real(existing) then
        -- Keep the real store; refresh cache from store instead of writing empty.
        return false, "refuse_empty_overwrite"
    end
    rots[name] = ser
    _set_active(c, legacy, name)
    -- Safe merge into account mirror (never empty-over-real).
    if type(RaijinLabDB.rotations) == "table" then
        if RaijinLab.MergeRotationInto then
            RaijinLab.MergeRotationInto(RaijinLabDB.rotations, name, ser)
        elseif is_real(ser) or not is_real(RaijinLabDB.rotations[name]) then
            RaijinLabDB.rotations[name] = ser
        end
    end
    Executor._active_cache = rotation
    Executor._active_name = name
    Executor._dirty_since_flush = true
    return true
end

-- Re-commit the active rotation into the DB. Used by the PLAYER_LOGOUT flush so
-- the final in-memory state is captured before WoW writes the SavedVariables file.
function Executor.flush()
    if not RaijinLabDB then return false end
    local r = Executor._active_cache
    local name = Executor._active_name
    if r and name then
        -- Never flush an empty in-memory shell over a real saved rotation.
        local ok = Executor.save_rotation(r, name)
        if not ok then
            -- Drop stale empty cache so next get reloads from DB.
            Executor._active_cache = nil
            Executor._active_name = nil
            Executor._resolved_from = nil
        end
    else
        local rot, n = Executor.get_active_rotation()
        if rot and n then Executor.save_rotation(rot, n) end
    end
    if RaijinLab.SyncActiveCharacterToLegacy then
        pcall(RaijinLab.SyncActiveCharacterToLegacy, RaijinLab)
    end
    return true
end

-- Resolve a pet-bar slot index (1-10) by matching the stored command name.
-- Pet-bar indices shift between pets/forms, so name is the stable key.
local function resolve_pet_index(action)
    local want = tostring(action.pet_cmd or action.name or ""):lower()
    if GetPetActionInfo then
        for i = 1, 10 do
            local nm = GetPetActionInfo(i)
            if nm and tostring(nm):lower() == want then return i end
        end
    end
    return action.pet_index
end

function Executor.attempt_petaction(action)
    if not (UnitExists and UnitExists("pet")) then return false, "no_pet" end
    local cmd = tostring(action.pet_cmd or action.name or ""):lower()
    -- Attack: needs a hostile target; PetAttack() is the canonical, unprotected call.
    if cmd:find("attack") then
        if not (UnitExists("target")) then return false, "no_target" end
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") then return false, "target_dead" end
        if UnitCanAttack and not UnitCanAttack("player", "target") then return false, "not_enemy" end
        if PetAttack then PetAttack(); return true, "petattack" end
        return false, "no_petattack_api"
    end
    -- Other commands (Follow/Stay/stances): cast the resolved pet-bar slot.
    local idx = resolve_pet_index(action)
    if idx and CastPetAction then CastPetAction(idx); return true, "petaction:" .. tostring(idx) end
    return false, "petaction_unresolved"
end

-- Auto Attack is not a castable GCD ability. Spamming CastSpell(6603) is pure
-- noise: it never lands as a spell cast and destroys metrics / chat.
-- Forward-declared: sticky_spell is defined ~240 lines below but called from
-- four sites above it. In Lua a reference compiled BEFORE `local function f`
-- binds to a nil GLOBAL, so each of those call sites would throw the moment it
-- was reached (a refused cast, an out-of-range corpse, a failed cast) - live
-- paths that simply had not been hit in a test yet.
local sticky_spell

local function is_auto_attack(sid, name)
    if tonumber(sid) == 6603 then return true end
    local n = string.lower(tostring(name or ""))
    return n == "auto attack" or n == "attack" or n == "auto-attack"
end

function Executor.attempt_action(action, ctx)
    if not action then return false, "no_action" end
    if action.action_type == "petaction" then
        return Executor.attempt_petaction(action)
    end
    local sid = tonumber(action.spell_id) or 0
    if sid == 0 then return false, "no_spell" end
    local name = spell_name(sid, action.name)
    action.name = name

    local Act = RaijinLab and RaijinLab.Actions
    if not Act or not Act.available or not Act.available() then
        if not Executor._no_runtime_warned then
            Executor._no_runtime_warned = true
            say("|cffff5555cannot cast|r - runtime not injected. tools\\inject.bat in-world, /reload")
        end
        return false, "no_runtime"
    end

    local W = RaijinLab and RaijinLab.World
    -- Never interrupt loot / gossip / quest / trade / AH / craft / etc.
    local user_state = (ctx and ctx.user_state)
        or (W and W.user_interaction_state and W.user_interaction_state())
        or "free"
    if user_state ~= "free" then
        local Eng = RaijinLab and RaijinLab.RotationEngine
        local allows = Eng and Eng.slot_allows_user_busy
            and Eng.slot_allows_user_busy(action.slot, user_state)
        if not allows then
            if rot_detail() then
                dlog("busy", "block %s  %s", tostring(name), tostring(user_state))
            end
            return false, "user_busy:" .. tostring(user_state)
        end
    end

    -- Auto Attack: engage once if needed; never CastSpell spam.
    if is_auto_attack(sid, name) then
        if not (UnitExists and UnitExists("target")) then return false, "no_target" end
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") then return false, "target_dead" end
        if UnitCanAttack and not UnitCanAttack("player", "target") then return false, "not_enemy" end
        local already = false
        if IsCurrentSpell then
            local okc, cur = pcall(IsCurrentSpell, 6603)
            if okc and cur then already = true end
        end
        if already then return false, "already_attacking" end
        if Act.Attack then
            pcall(Act.Attack)
            Executor._last_cast = { sid = 6603, name = "Auto Attack", via = "Attack", t = now(), evidence = "attack" }
            -- Floor so we do not re-select every frame while swing starts.
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = now() + 0.75
            Executor._recent[6603] = now() + 0.75
            dlog("cast", "auto-attack")
            return true, "ok:attack", cast_snapshot(sid)
        end
        return false, "no_attack_api"
    end

    -- Fail-closed preflight. Target/range policy comes ONLY from conditions
    -- (Target Existence any|no_target, Corpse Nearby) - never from IsSpellInRange nil.
    local policy = action.target_policy or slot_policy(action.slot)
    local needs_enemy = (policy == "require")
    local corpse_range = (policy == "corpse") and (slot_corpse_range(action.slot) or 30) or nil
    local guid = nil
    local corpse_guid_for_mark = nil
    local probe_marked = false

    -- Multi-dot: cast is ALWAYS Spell_C_CastSpell(id, guid).
    -- Acquire OFF (default): NEVER TargetUnit / never leave selection on victim.
    -- Acquire ON: may Target the match; Reset after restores previous.
    local search = action.aura_search_hit or (ctx and ctx.aura_search_hit)
    if search and search.guid then
        guid = search.guid
        if ctx then ctx.aura_search_hit = search end
    end
    -- Strict truthy only. Anything else (nil/false/"false"/0) = acquire OFF.
    -- HARD RULE: acquire OFF means NEVER call Act.Target for this cast.
    local want_acquire = false
    if search then
        local a = search.acquire_target
        -- Intentionally IGNORE search.retarget alone if acquire_target is false
        -- (legacy key was re-set to acquire in Conditions; still force-off).
        want_acquire = (a == true or a == 1 or a == "true")
        if search.acquire_target == false or search.acquire_target == 0
            or search.acquire_target == "false" then
            want_acquire = false
        end
    end
    local want_reset_after = false
    if want_acquire and search then
        local ra = search.reset_after
        want_reset_after = (ra == true or ra == 1 or ra == "true")
    end
    -- Snapshot selection BEFORE any Target / Cast that might mutate it.
    local pre_target_guid = nil
    local pre_had_target = UnitExists and UnitExists("target")
    if pre_had_target and UnitGUID then
        pre_target_guid = UnitGUID("target")
    end
    -- ONLY path that may change selection for multi-dot.
    if want_acquire and search and search.guid and Act and Act.Target then
        pcall(Act.Target, search.guid)
        if W and W.sync_ctx_target and ctx then pcall(W.sync_ctx_target, ctx) end
        if ctx then ctx._aura_search_retargeted = true end
    end
    -- Acquire OFF: never Target, period. Runtime CastSpell restores after Spell_C.

    -- Auto Face is opt-in only via the "Auto Face" slot condition (not always on).
    local want_auto_face = action.auto_face == true
    if not want_auto_face and action.slot then
        local Eng = RaijinLab and RaijinLab.RotationEngine
        if Eng and Eng.slot_wants_auto_face then
            want_auto_face = Eng.slot_wants_auto_face(action.slot)
        end
    end

    if policy == "corpse" then
        -- Cast ON a verified corpse GUID only. Unverified CLEU ghosts caused
        -- "no corpses available" spam after condition falsely passed.
        local corpse = (ctx and ctx._corpse_for_spell and ctx._corpse_for_spell[sid])
            or (W and W.nearest_available_corpse and W.nearest_available_corpse(corpse_range))
        if not corpse or not corpse.guid or not corpse.verified then
            return false, "no_corpse:" .. tostring(name)
        end
        -- Live re-verify: object must still resolve this frame.
        if RaijinLab and RaijinLab.ObjectPosition then
            local cx, cy, cz = RaijinLab:ObjectPosition(corpse.guid)
            if not cx and not corpse.token then
                if W.invalidate_corpse then W.invalidate_corpse(corpse.guid) end
                return false, "no_corpse:" .. tostring(name)
            end
            if cx then
                local px, py, pz
                if RaijinLab.ObjectPosition then
                    px, py, pz = RaijinLab:ObjectPosition("player")
                end
                if px then
                    local dx, dy, dz = px - cx, py - cy, (pz or 0) - (cz or 0)
                    corpse.dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                end
            end
        end
        local minR, maxR = spell_range_info(sid)
        local lim = corpse_range
        if maxR and maxR > 0 and maxR < lim then lim = maxR end
        if tonumber(corpse.dist) and corpse.dist > lim then
            return false, "oor:" .. tostring(name)
        end
        guid = corpse.guid
        corpse_guid_for_mark = corpse.guid
        local can, why = live_castable(sid, name, {
            policy = "corpse", needs_enemy = false,
            skip_range = true, skip_usable = true, ctx = ctx,
        })
        if not can then
            return false, tostring(why) .. ":" .. tostring(name)
        end
    else
        -- Range policy:
        --   optional/forbid  -> no living-target range gate (Consecration w/ any)
        --   ground self-AoE  -> always skip target range (cast at feet)
        --   require + WW     -> check target in self-AoE disk
        local ground = is_ground_self_aoe(sid, name)
        local skip_r = (policy == "optional" or policy == "forbid" or ground)
        if is_self_aoe_spell(sid, name) and policy == "require" and not ground then
            skip_r = false
        end
        -- Ground self-AoE (Consecration) has no facing requirement.
        local skip_face = ground or policy == "optional" or policy == "forbid"
            or is_self_aoe_spell(sid, name)
        -- If Auto Face is on, skip face here — wire path will turn then recheck.
        local can, why = live_castable(sid, name, {
            policy = policy, needs_enemy = needs_enemy,
            skip_range = skip_r,
            skip_facing = skip_face or want_auto_face,
            ctx = ctx,
        })
        if not can then
            return false, tostring(why) .. ":" .. tostring(name)
        end
        -- Pack-disk self-AoE only (WW): re-check current target in radius when
        -- policy requires a living target. NEVER for Consecration / optional.
        if is_self_aoe_spell(sid, name) and policy == "require" and not ground
            and UnitExists and UnitExists("target") then
            local ok_r, why_r = spell_in_range_vs_target(sid, name, ctx)
            if not ok_r then
                return false, "oor:" .. tostring(name)
            end
        end
        -- Prefer aura_search hit GUID (multi-dot). Native CastSpell(guid) does
    -- not need TargetUnit. Ground/self optional spells cast with no unit GUID.
    if needs_enemy then
            local hit = (ctx and ctx.aura_search_hit) or search
            if hit and hit.guid then
                guid = hit.guid
            elseif not guid then
                guid = target_guid()
            end
        end
    end

    if needs_enemy and not guid then
        local hit = (ctx and ctx.aura_search_hit) or search
        if hit and hit.guid then guid = hit.guid end
    end

    -- Mark free probe consumed BEFORE wire so a refuse sticks even if we crash.
    do
        local diag = ctx and ctx.spell_range_diag
            and (ctx.spell_range_diag[sid] or ctx.spell_range_diag[tostring(sid)])
        local G = gate()
        if diag and diag.probe and G and G.mark_probed then
            G.mark_probed(sid)
            probe_marked = true
        end
    end

    local cast_sid = sid
    local RR = RaijinLab and RaijinLab.RankResolver
    if RR and RR.highest then cast_sid = RR.highest(sid) or sid end
    action._cast_name = spell_name(cast_sid, name)

    -- Final ready gate (lag-padded). Never spam Spell_C when not ready.
    do
        local rem = spell_ready_remaining(cast_sid, action._cast_name or name)
        if rem > 0.05 then
            return false, "cooldown:" .. tostring(name)
        end
    end

    -- Multi-dot: GUID is mandatory when search found a unit.
    -- Never fall back to current-target cast (melee hits wrong unit).
    if search and search.guid then
        guid = search.guid
    end
    if search and not guid then
        return false, "no_search_guid:" .. tostring(name)
    end
    if needs_enemy and not guid and not is_ground_self_aoe(sid, name) then
        return false, "no_target:" .. tostring(name)
    end

    local before = cast_snapshot(cast_sid)
    local Ou = RaijinLab and RaijinLab.Outcomes
    local oid = Ou and Ou.begin and Ou.begin("cast", {
        sid = cast_sid, name = name, gap = ctx and ctx.target_distance,
    })

    -- Selection policy for multi-dot / GUID casts:
    --   acquire OFF           -> cast by GUID; NEVER leave selection on victim
    --   acquire ON + reset    -> Target match, then restore previous
    --   acquire ON + no reset -> Target match and keep it
    -- Facing is independent of acquire: unit-targeted spells still need front cone.
    local preserve_selection = (guid ~= nil) and (not want_acquire or want_reset_after)
    local skip_face_cast = is_ground_self_aoe(sid, name) or is_self_aoe_spell(sid, name)
        or policy == "optional" or policy == "forbid" or policy == "corpse"

    -- Multi-candidate same-tick try (aura_search top-N). Face-fail → next GUID.
    -- Order is runtime authority: closest first, FOV-centre on distance ties.
    local try_list = {}
    if search and search.candidates and #search.candidates > 0 then
        for i = 1, #search.candidates do
            local c = search.candidates[i]
            if c and c.guid then try_list[#try_list + 1] = c end
        end
    elseif guid then
        try_list[1] = { guid = guid, token = search and search.token }
    end
    if #try_list == 0 and guid then try_list[1] = { guid = guid } end

    local ground_self = is_ground_self_aoe(sid, name)
    -- Ground/self casts (Consecration, optional buffs): no unit GUID required.
    -- Live bug: policy=optional (target_exists any + ground-AoE force) left
    -- try_list empty → last_why=no_candidate forever, rotation froze, client
    -- crashed ~4s later when OM re-armed mid-stuck combat.
    local self_cast_ok = ground_self
        or policy == "optional" or policy == "forbid"
        or (not needs_enemy and not search)

    local function restore_selection()
        if not preserve_selection or not Act then return end
        local cur = (UnitGUID and UnitExists and UnitExists("target") and UnitGUID("target")) or nil
        if pre_had_target and pre_target_guid then
            if tostring(cur or "") == tostring(pre_target_guid) then return end
            if Act.TargetLastTarget then pcall(Act.TargetLastTarget) end
            cur = (UnitGUID and UnitExists and UnitExists("target") and UnitGUID("target")) or nil
            if tostring(cur or "") == tostring(pre_target_guid) then return end
            if Act.Target then pcall(Act.Target, pre_target_guid) end
            cur = (UnitGUID and UnitExists and UnitExists("target") and UnitGUID("target")) or nil
            if tostring(cur or "") == tostring(pre_target_guid) then return end
            if Act.ClearTarget then pcall(Act.ClearTarget) end
            if Act.Target then pcall(Act.Target, pre_target_guid) end
        else
            if cur and Act.ClearTarget then pcall(Act.ClearTarget) end
        end
    end

    -- Multi-dot GUID wire: plain Spell_C only.
    -- NEVER CastSpellPreserveSelection here — its C_Timer TargetLastTarget spam
    -- clobbered selection and stalled the client after every Icy Touch.
    -- Runtime CastSpell already restores selection for GUID casts.
    local ok, wire_guid = false, nil
    local last_why = "no_candidate"
    local FACE = (Act.CAST_FACE_IF_NEEDED or 1)
    local SKIP = (Act.CAST_SKIP_IF_NOT_FACING or 4)
    local NOTGT = (Act.CAST_NO_TARGET_CHANGE or 2)
    for ci = 1, #try_list do
        local cand = try_list[ci]
        local cg = cand.guid
        if not cg or cg == 0 or tostring(cg) == "0x0" or tostring(cg) == "0x0000000000000000" then
            last_why = "bad_guid"
        elseif Executor.guid_blacklisted(cg) then
            last_why = "blacklisted"
        else
            if not skip_face_cast and needs_enemy then
                local not_facing = W and W.is_not_facing_guid
                    and W.is_not_facing_guid(cg, W.CAST_FACE_HALF_ARC)
                if not_facing and want_auto_face then
                    if Act.FaceTowardGuid then pcall(Act.FaceTowardGuid, cg)
                    elseif W and W.face_guid then pcall(W.face_guid, cg) end
                    not_facing = W and W.is_not_facing_guid
                        and W.is_not_facing_guid(cg, W.CAST_FACE_HALF_ARC)
                end
                if not_facing then
                    last_why = "facing"
                    blacklist_guid(cg, 0.20, "facing")
                else
                    local reason = nil
                    -- Always use CastSpellEx for multi-dot GUID casts so runtime
                    -- can return not_ready/facing and pin UNIT_FIELD_TARGET.
                    if Act.CastSpellEx then
                        local flags = (want_acquire and 0 or NOTGT)
                        if want_auto_face then flags = flags + FACE + SKIP end
                        ok, reason = Act.CastSpellEx(cast_sid, cg, flags)
                    else
                        ok = Act.CastSpell(cast_sid, cg)
                        reason = ok and "ok" or "cast_fail"
                    end
                    if ok == true or ok == 1 then
                        ok = true
                        wire_guid = cg
                        guid = cg
                        if search then
                            search.guid = cg
                            search.token = cand.token
                            if ctx then ctx.aura_search_hit = search end
                        end
                        break
                    end
                    ok = false
                    last_why = reason or "cast_fail"
                    -- not_ready is a list/GCD issue, not a bad GUID — don't blacklist.
                    if tostring(last_why) ~= "not_ready" and tostring(last_why) ~= "cooldown" then
                        blacklist_guid(cg, 0.15, last_why)
                    end
                end
            else
                -- RUNTIME ONLY: multi-dot and unit casts go CastSpell(id, guid).
                -- Ground self-AoE uses CastSpell(id) with no unit.
                local cok, creason
                if ground_self then
                    if Act.CastSpellEx then
                        cok, creason = Act.CastSpellEx(cast_sid, nil, 0)
                    else
                        cok = Act.CastSpell(cast_sid)
                    end
                elseif Act.CastSpellEx then
                    local flags = (want_acquire and 0 or NOTGT)
                    cok, creason = Act.CastSpellEx(cast_sid, cg, flags)
                else
                    cok = Act.CastSpell(cast_sid, cg)
                end
                if cok then
                    ok = true
                    if not ground_self then
                        wire_guid = cg
                        guid = cg
                    end
                    break
                end
                last_why = creason or "cast_failed"
            end
        end
    end

    -- No unit candidates: self/ground cast path (Consecration etc.).
    if not ok and #try_list == 0 and self_cast_ok then
        local cok, creason
        if Act.CastSpellEx then
            cok, creason = Act.CastSpellEx(cast_sid, nil, 0)
        else
            cok = Act.CastSpell(cast_sid)
        end
        if cok then
            ok = true
            last_why = "ok"
        else
            last_why = creason or "cast_failed"
        end
    end

    -- Acquire-off: one immediate restore only (no timer spam).
    if ok and preserve_selection and not want_acquire then
        restore_selection()
    end

    if not ok then
        if Ou and oid then Ou.settle(oid, -1.0, last_why or "cast_failed") end
        -- INSTANT free: never hold list on facing/los/wire fail.
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._next_gap = 0
        Executor._pending = nil
        clear_sid_soft_locks(sid)
        -- Brief soft lock so a broken slot cannot monopolize every tick.
        if tostring(last_why or ""):find("no_candidate", 1, true)
            or tostring(last_why or ""):find("cast_failed", 1, true) then
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = now() + 0.35
        end
        return false, tostring(last_why or "cast_failed") .. ":" .. tostring(name)
    end

    local after = cast_snapshot(cast_sid)
    local evidence, how = cast_had_effect(before, after, cast_sid)
    if not evidence then
        after = cast_snapshot(cast_sid)
        evidence, how = cast_had_effect(before, after, cast_sid)
    end
    if Ou and oid then
        Ou.settle(oid, evidence and 1.0 or 0.2, evidence and tostring(how) or "wire_ok")
    end

    -- GCD after wire (FAILURE RECOVERY rules):
    --   1) evidence (CD/cast bar) -> real GCD
    --   2) multi-dot wire, same-frame no evidence -> SHORT provisional only
    --      (Spell_C often returns true before GetSpellCooldown updates; treating
    --      that as hard fail broke multi-dot. Treating it as a long pending
    --      froze the whole list. Cap at ~80ms; FAIL event frees immediately;
    --      phantom grace frees and allows lower slots next tick.)
    --   3) other wire-only -> short provisional
    local tnow = now()
    local off_gcd = action.slot and action.slot.off_gcd and true or false
    local grace = net_grace()
    local is_multidot = search and search.guid and true or false

    Executor._gcd_provisional = false
    if not off_gcd then
        if evidence and after and after.cd_dur and after.cd_dur > 0 and after.cd_dur <= 1.6 then
            if Executor._note_gcd then Executor._note_gcd(after.cd_dur) end
            Executor._gcd_until = (tonumber(after.cd_start) or tnow) + after.cd_dur
            Executor._gcd_src = "live_post"
        elseif evidence then
            local dur = 1.0
            if Executor.gcd_fallback then dur = select(1, Executor.gcd_fallback()) end
            Executor._gcd_until = tnow + dur
            Executor._gcd_src = "evidence"
        elseif is_multidot then
            -- Multi-dot: DO NOT set global _gcd_until (that clobbered every
            -- lower-priority ability). Track pending without list lock.
            Executor._gcd_until = 0
            Executor._gcd_provisional = false
            Executor._gcd_src = "multidot_wire"
            local g = 0.10
            Executor._pending = {
                sid = sid, cast_t = tnow, deadline = tnow + g, grace = g,
                before_cd = before and before.cd_start or 0,
                name = action._cast_name or name,
                off_gcd = false,
                guid = guid,
                multidot = true,
                no_gcd = true, -- critical: does not freeze other slots
            }
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = tnow + 0.05 -- anti-spam THIS spell only
        else
            -- Wire accepted: provisional GCD = real GCD length (awareness of
            -- client state), not a 120ms hope. Refuse events free early;
            -- land confirms. Stops Consecration re-wire while GCD pending.
            local gdur = grace
            if Executor.gcd_fallback then
                local d = select(1, Executor.gcd_fallback())
                if d and d > gdur then gdur = d end
            end
            if gdur < 0.75 then gdur = 0.75 end
            if gdur > 1.5 then gdur = 1.5 end
            -- If client already shows ability CD, floor THIS spell only.
            local arem = spell_ready_remaining(cast_sid, action._cast_name or name)
            Executor._gcd_until = tnow + gdur
            Executor._gcd_src = "wire_pending"
            Executor._gcd_provisional = true
            Executor._recent = Executor._recent or {}
            if arem > gdur then
                Executor._recent[sid] = tnow + math.min(arem, 10.0)
            else
                Executor._recent[sid] = tnow + gdur
            end
        end
    end

    -- Optimistic multi-dot mark ONLY with evidence (facing refuse must not mark).
    if evidence and guid and W and W.note_aura_on_guid and search and search.guid
        and tostring(guid) == tostring(search.guid) then
        local aura_sid = 0
        local aura_nm = nil
        if action.slot and action.slot.conditions then
            for _, c in ipairs(action.slot.conditions) do
                if c and c.id == "aura_search" and c.args then
                    aura_sid = tonumber(c.args.spell_id) or 0
                    aura_nm = c.args.name
                    break
                end
            end
        end
        if aura_sid > 0 or (aura_nm and aura_nm ~= "") then
            pcall(W.note_aura_on_guid, guid, aura_sid, aura_nm or name, 1, 21)
        else
            pcall(W.note_aura_on_guid, guid, cast_sid, name, 1, 21)
        end
    end

    local tag = evidence and tostring(how) or "runtime"
    Executor._last_cast = {
        sid = sid, name = name, via = "Actions.CastSpell",
        t = tnow, guid = guid, evidence = tag,
        corpse = corpse_guid_for_mark,
        gap = ctx and ctx.target_distance,
        probe = probe_marked,
    }
    Executor._cast_count = (Executor._cast_count or 0) + 1
    local Prot = RaijinLab and RaijinLab.Protection
    local school = Prot and Prot.guess_school and Prot.guess_school(sid, name, action.school)
    if Act.Attack and school == "physical" and needs_enemy
        and UnitExists and UnitExists("target") then
        pcall(Act.Attack)
    end
    if evidence then
        local G = gate()
        if G and G.note_landed then
            G.note_landed(sid, ctx and ctx.target_distance)
        end
        if W and (is_corpse_consume_name(name) or corpse_range) then
            if corpse_guid_for_mark and W.mark_corpse_consumed then
                pcall(W.mark_corpse_consumed, corpse_guid_for_mark)
                if W._death_corpses then W._death_corpses[corpse_guid_for_mark] = nil end
            elseif W.mark_nearest_corpse_consumed then
                pcall(W.mark_nearest_corpse_consumed, corpse_range or 40)
            end
        end
    end
    return true, "ok:" .. tag, before, evidence and true or false
end

-- Pending confirmation window after wire-ok.
-- Too long freezes the priority list (facing refuse that never fires events).
-- FAIL / UI_ERROR still free the same frame (apply_pending_refuse).
local function net_grace()
    local lag = 0.08
    if GetNetStats then
        local ok, _, _, latHome, latWorld = pcall(GetNetStats)
        if ok then
            local ms = math.max(tonumber(latHome) or 0, tonumber(latWorld) or 0)
            if ms > 0 then lag = ms / 1000 end
        end
    end
    -- Cap 180ms: longer provisional GCD was the "freeze after fail" feel.
    local g = lag * 1.2 + 0.06
    if g < 0.10 then g = 0.10 end
    if g > 0.18 then g = 0.18 end
    return g
end

local function micro_lock()
    return 0.016
end

-- Real cast start: cast bar, channel, or THIS ability's CD (not bare GCD).
local function cast_confirmed(sid, before_cd)
    if UnitCastingInfo and UnitCastingInfo("player") ~= nil then return true, "casting" end
    if UnitChannelInfo and UnitChannelInfo("player") ~= nil then return true, "channel" end
    if IsCurrentSpell then
        local ok, cur = pcall(IsCurrentSpell, sid)
        if ok and cur then return true, "current" end
    end
    if GetSpellCooldown then
        local name = spell_name(sid)
        local s, d = GetSpellCooldown(sid)
        if (not s or s == 0) and name then s, d = GetSpellCooldown(name) end
        s = tonumber(s) or 0; d = tonumber(d) or 0
        -- Ability cooldown only. GCD-length (d<=1.6) is NOT a land proof.
        if d > 1.65 and s > (tonumber(before_cd) or 0) + 0.05 then
            return true, "ability_cd"
        end
    end
    return false, nil
end

-- Real global-cooldown END time for a CONFIRMED cast, anchored to when the cast
-- actually happened (`anchor_t`). If GetSpellCooldown reports a GCD-length CD
-- (<= 1.6 s) use its true start+duration; for a longer ability cooldown (whose
-- own per-spell gate handles the ability) or none, derive the hasted GCD from
-- the anchor (WotLK floor 1.0 s), falling back to 1.5 s.
-- Remember the GCD lengths we actually SEE, so the fallback stops guessing.
local function note_gcd_observation(cd)
    cd = tonumber(cd) or 0
    if cd >= 0.2 and cd <= 1.6 then
        local cur = Executor._gcd_obs
        Executor._gcd_obs = cur and (cur * 0.7 + cd * 0.3) or cd
    end
end
Executor._note_gcd = note_gcd_observation

function Executor.gcd_fallback()
    -- Prefer the GCD actually OBSERVED on this character. Custom servers often
    -- never report a GCD for their own spells, and the old flat 1.5s fallback
    -- then over-locked EVERY cast by up to half a second - the "sluggish" feel.
    local dur, src = Executor._gcd_obs, "learned"
    if not dur then
        local haste = 0
        if UnitSpellHaste then
            local ok, h = pcall(UnitSpellHaste, "player")
            if ok and type(h) == "number" then haste = h end
        end
        dur = 1.5 / (1 + haste / 100)
        src = "haste"
    end
    if dur < 0.75 then dur = 0.75 elseif dur > 1.5 then dur = 1.5 end
    return dur, src
end

local function gcd_end(sid, anchor_t)
    anchor_t = anchor_t or now()
    if sid and sid > 0 and GetSpellCooldown then
        local s, cd = GetSpellCooldown(sid)
        cd = tonumber(cd) or 0
        if cd > 0 and cd <= 1.6 then
            note_gcd_observation(cd)
            Executor._gcd_src = "real"
            return (tonumber(s) or anchor_t) + cd
        end
    end
    local dur, src = Executor.gcd_fallback()
    Executor._gcd_src = src
    return anchor_t + dur
end

-- Spell-level cast rejections apply to ONE slot: exclude and try next THIS tick.
-- Multi-dot / aura_search failures are ALWAYS slot-level (never freeze the list).
local function slot_level_fail(reason)
    reason = tostring(reason or "")
    return reason:find("^unusable") ~= nil
        or reason:find("^oor") ~= nil
        or reason:find("^no_resource") ~= nil
        or reason:find("^no_corpse") ~= nil
        or reason:find("^user_busy") ~= nil
        or reason:find("^cast_failed") ~= nil
        or reason:find("cast_fail", 1, true) ~= nil
        or reason:find("^sticky") ~= nil
        or reason:find("^not_ready") ~= nil
        or reason:find("^facing") ~= nil
        or reason:find("in front", 1, true) ~= nil
        or reason:find("^los") ~= nil
        or reason:find("^bad_target") ~= nil
        or reason:find("^immune") ~= nil
        or reason:find("^no_confirm") ~= nil
        or reason:find("^no_candidate") ~= nil
        or reason:find("^blacklisted") ~= nil
        or reason:find("no_target", 1, true) ~= nil
        or reason:find("cooldown", 1, true) ~= nil
end

-- Diagnostic only. NEVER force range/usable/cooldown false across ticks.
-- That skipped the same ability on the next full re-eval. Client live state
-- is the only gate.
function sticky_spell(sid, reason, ctx, extra)
    local G = gate()
    if G and G.note_refuse then
        pcall(G.note_refuse, sid, reason, ctx, extra)
    end
end

-- Say WHY nothing was cast. The executor ticked 1800 times in a 60s simulated
-- run and emitted NOTHING, because a refusal is not an event and nothing logged
-- the steady state. "The rotation engine is on but silent" then reads identically
-- to "the rotation engine is dead" - which is exactly the ambiguity that let a
-- broken bot look healthy for 166 minutes. Rate-limited per distinct reason.
local function report_idle(reason)
    local Tel = RaijinLab and RaijinLab.Telemetry
    if not Tel then return end
    Tel.every("rot:idle:" .. tostring(reason), 5, "rot", 4, "idle",
        { reason = reason, target = (UnitExists and UnitExists("target")) and 1 or 0 })
end

function Executor._tick_body()
    -- MASTER GATE. The suite switch is authoritative: while it is off nothing
    -- ticks, no matter who armed the timer or how long ago.
    if RaijinLab.Master and RaijinLab.Master.suppressed() then return nil, "master_off" end
    local _tick_t0 = tick_timer_start()
    Executor._tick_count = (Executor._tick_count or 0) + 1
    if not RaijinLabDB or not RaijinLabDB.rotation_enabled then
        return nil, "disabled"
    end
    local Engine = RaijinLab.RotationEngine
    local Conditions = RaijinLab.Conditions
    local World = RaijinLab.World
    if not Engine or not Conditions then
        Executor._last_err = "missing_engine"
        return nil, "missing_engine"
    end

    local rotation = select(1, Executor.get_active_rotation())
    if not rotation then
        Executor._last_err = "no_rotation"
        return nil, "no_rotation"
    end

    local filled = 0
    local spell_ids = {}
    for _, slot in ipairs(rotation.slots or {}) do
        local sid = tonumber(slot.spell_id) or 0
        if sid ~= 0 then
            filled = filled + 1
            spell_ids[#spell_ids + 1] = sid
        end
    end
    if filled == 0 then
        Executor._last_err = "no_spells_in_rotation"
        -- NAME THE ROTATION. This fired hundreds of times a session saying only
        -- "no spells", which is true but useless: the actual situation was that a
        -- DIFFERENT, empty rotation was selected while the real one sat right
        -- there in the list. An empty-rotation warning that does not say which
        -- rotation is empty, and what else is available, cannot be acted on.
        local rname = tostring(RaijinLabDB and RaijinLabDB.active_rotation or "?")
        local others = {}
        local all = RaijinLabDB and RaijinLabDB.rotations
        if type(all) == "table" then
            for n, r in pairs(all) do
                if n ~= rname then
                    local c = 0
                    for _, sl in ipairs((type(r) == "table" and r.slots) or {}) do
                        if (tonumber(sl.spell_id) or 0) ~= 0 then c = c + 1 end
                    end
                    if c > 0 then others[#others + 1] = n .. "(" .. c .. ")" end
                end
            end
        end
        if Executor._tick_count % 50 == 1 then
            local msg = "active rotation '" .. rname .. "' has no spells"
            if #others > 0 then
                msg = msg .. " - these DO have spells: " .. table.concat(others, ", ")
                   .. "  (switch with /raijin rotation use <name>)"
            else
                msg = msg .. " - drop abilities onto slots"
            end
            say(msg)
        end
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then
            Tel.warn("rot", "empty_rotation", { active = rname, others = table.concat(others, ",") })
        end
        return nil, "no_spells_in_rotation"
    end

    local t = now()

    -- ---- Resolve a cast that's in flight (set on the previous cast) ---------
    -- This is the heart of "lightning fast". Act.CastSpell returning true only
    -- means the CLIENT accepted the call - the server can still refuse it for
    -- range/facing/LoS the tick snapshot didn't catch. So instead of blindly
    -- locking a full ~1.5 s GCD, the last cast set a SHORT provisional lock and
    -- a pending record; here we either promote it to the real GCD once the
    -- client confirms the cast landed, or drop the lock the instant it's clear
    -- it didn't - turning a missed press into a ~ping-length retry instead of a
    -- full-GCD stall.
    local p = Executor._pending
    if p then
        local e = Executor._evt
        local ok_t, fail_t = e.ok_t or 0, e.fail_t or 0
        local pname = tostring(p.name or ""):lower()
        local function ev_matches(nm)
            if pname == "" then return true end
            if nm == nil then return false end
            return tostring(nm):lower() == pname
        end
        local ok_hit   = ok_t > 0 and ok_t >= p.cast_t and ev_matches(e.ok_name)
        local fail_hit = fail_t > 0 and fail_t >= (p.cast_t - 0.02)
                         and (e.fail_name == nil or ev_matches(e.fail_name)
                              or looks_like_cast_error(e.fail_msg or e.err_msg or ""))
        -- Also treat any recent cast-looking UI error as fail (name optional).
        if not fail_hit and fail_t > 0 and fail_t >= (p.cast_t - 0.02)
            and looks_like_cast_error(e.err_msg or e.fail_msg or "") then
            fail_hit = true
        end

        if ok_hit and ok_t >= fail_t then
            Executor._gcd_until = p.off_gcd and 0 or gcd_end(p.sid, p.cast_t)
            Executor._gcd_src = "event_ok"
            Executor._gcd_provisional = false
            Executor._pending = nil
            Executor._unconf = nil
            Executor._refuse = nil
            -- Micro lock only after REAL land (anti double-fire).
            Executor._recent = Executor._recent or {}
            Executor._recent[p.sid] = t + micro_lock()
            do
                local G = gate()
                if G and G.note_landed then
                    G.note_landed(p.sid, Executor._last_cast and Executor._last_cast.gap)
                end
            end
            log_cast("landed", p.sid, e.ok_name, nil, p.cast_t)
        elseif fail_hit then
            local reason = ""
            if (e.err_t or 0) >= p.cast_t - 0.05 then reason = tostring(e.err_msg or "") end
            if reason == "" then reason = tostring(e.fail_msg or "") end
            if Executor._pending then
                apply_pending_refuse(reason, e.fail_name or p.name)
            end
            -- Same tick continues below and fully re-evaluates NOW.
        elseif cast_confirmed(p.sid, p.before_cd) then
            Executor._gcd_until = p.off_gcd and 0 or gcd_end(p.sid, p.cast_t)
            Executor._gcd_src = "poll_ok"
            Executor._gcd_provisional = false
            local conf_cast_t = p.cast_t
            local conf_sid = p.sid
            Executor._pending = nil
            Executor._unconf = nil
            Executor._recent = Executor._recent or {}
            Executor._recent[conf_sid] = t + micro_lock()
            do
                local G = gate()
                if G and G.note_landed then
                    G.note_landed(conf_sid, Executor._last_cast and Executor._last_cast.gap)
                end
            end
            log_cast("landed", conf_sid, p.name, "poll", conf_cast_t)
        elseif t >= (p.deadline or 0) or (t - (p.cast_t or 0)) >= (p.grace or net_grace()) then
            -- Grace expired with no SUCCESS and no FAIL event.
            local sid = p.sid
            if cast_confirmed(sid, p.before_cd) then
                Executor._gcd_until = p.off_gcd and 0 or gcd_end(sid, p.cast_t)
                Executor._gcd_src = "grace_poll"
                Executor._gcd_provisional = false
                Executor._pending = nil
                Executor._unconf = nil
                Executor._recent = Executor._recent or {}
                Executor._recent[sid] = t + micro_lock()
                -- Multi-dot land: note aura now (optimistic note was deferred).
                if p.multidot and p.guid then
                    local W = RaijinLab and RaijinLab.World
                    if W and W.note_aura_on_guid then
                        pcall(W.note_aura_on_guid, p.guid, sid, p.name, 1, 21)
                    end
                end
                log_cast("landed", sid, p.name, "grace_confirm", p.cast_t)
            else
                -- PHANTOM / FAILED RECOVERY: free the list completely so lower
                -- priority slots can cast next evaluation. Multi-dot only
                -- micro-locks this spell; never a multi-second freeze.
                Executor._pending = nil
                Executor._gcd_until = 0
                Executor._gcd_provisional = false
                Executor._gcd_src = "phantom_free"
                Executor._next_gap = 0
                Executor._idle_until = nil
                Executor._unconf = nil
                clear_sid_soft_locks(sid)
                Executor._recent = Executor._recent or {}
                Executor._recent[sid] = t + (p.multidot and 0.12 or 0.08)
                if p.multidot and p.guid then
                    blacklist_guid(p.guid, 0.20, "phantom")
                end
                log_cast("refused", sid, p.name, "phantom_grace", p.cast_t)
            end
        end
        -- else: still inside grace — short provisional only
    end

    local gap = Executor._next_gap or 0
    if gap > 0 and (t - (Executor._last_attempt_t or 0)) < gap then
        return nil, "throttle"
    end

    -- Idle throttle: short sleep. Wake on target or combat only.
    -- NEVER full collect_nearby_enemies here (that hammered ObjectHealth and
    -- crashed the client on suite enable). NEVER nameplates.
    if not Executor._pending and Executor._idle_until and t < Executor._idle_until then
        local wake = false
        if UnitExists and UnitExists("target") then
            if not Executor._idle_had_target then wake = true end
        end
        if not wake and UnitAffectingCombat and UnitAffectingCombat("player") then
            wake = true
        end
        if wake then
            Executor._idle_until = nil
        else
            return nil, "idle"
        end
    end

    local pend = Executor._pending
    local user_state = "free"
    if World and World.user_interaction_state then
        local ok_us, us = pcall(World.user_interaction_state)
        if ok_us and us then user_state = us end
    end

    -- Do NOT auto TargetUnit for the rotation. Casts use Spell_C_CastSpell(guid)
    -- (aura_search / corpse) or the existing client target. Auto-acquire was
    -- forcing targets and made multi-dot look "target required".
    -- Auto Attack still engages only when a living target already exists.

    local ctx = {
        target_exists = UnitExists and UnitExists("target") or false,
        target_is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") or false,
        target_is_enemy = UnitCanAttack and UnitCanAttack("player", "target") or false,
        is_casting = (UnitCastingInfo and UnitCastingInfo("player") ~= nil) or false,
        is_channeling = (UnitChannelInfo and UnitChannelInfo("player") ~= nil) or false,
        user_state = user_state,
        cooldowns = {},
        known_spells = {},
        spell_in_range = {},
        spell_usable = {},
        require_attackable_target = true,
        strict_gcd = false,
        strict_usable = false,
    }
    local auto_castable = not (RaijinLabDB and RaijinLabDB.auto_castable == false)

    -- Cache condition needs once per rotation object identity / second.
    local needs_enemies, needs_aura_search = false, false
    do
        local rk = tostring(rotation.name or rotation) .. ":" .. tostring(#(rotation.slots or {}))
        local nc = Executor._needs_cache
        if not nc or nc.key ~= rk or (t - (nc.t or 0)) > 2.0 then
            needs_enemies = World and World.rotation_needs_enemies
                and World.rotation_needs_enemies(rotation)
            needs_aura_search = World and World.rotation_needs_aura_search
                and World.rotation_needs_aura_search(rotation)
            Executor._needs_cache = {
                key = rk, t = t,
                enemies = needs_enemies and true or false,
                aura = needs_aura_search and true or false,
            }
        else
            needs_enemies = nc.enemies
            needs_aura_search = nc.aura
        end
    end
    local skip_enemies = not (needs_enemies or needs_aura_search)

    if World and World.build_context then
        -- fill_live overwrites spell snapshot; skip duplicate IsUsable/range work.
        -- Skip facing probes unless a condition needs them (rare).
        local okb, built = pcall(World.build_context, {
            spell_ids = spell_ids,
            skip_enemies = skip_enemies,
            skip_spell_snapshot = true,
            skip_facing = true,
            skip_los = false,
        })
        if okb and type(built) == "table" then
            ctx = built
            ctx.require_attackable_target = true
            ctx.strict_gcd = false
            ctx.strict_usable = false
            ctx.auto_castable = auto_castable
            if not ctx.user_state then ctx.user_state = user_state end
        end
    end
    ctx.auto_castable = auto_castable
    if not ctx.user_state then ctx.user_state = user_state end

    -- Flag no-target-capable slots so idle throttle does not sleep on self buffs.
    do
        local any_nt = false
        for _, slot in ipairs(rotation.slots or {}) do
            local pol = slot_policy(slot)
            if pol == "optional" or pol == "forbid" or pol == "corpse" then
                any_nt = true; break
            end
        end
        ctx._has_no_target_slot = any_nt
    end

    -- AUTHORITATIVE live client readiness THIS frame (overwrites snapshot).
    fill_live_spell_state(ctx, spell_ids)
    -- Corpse / Target Existence any|no_target policy overrides.
    apply_slot_policy_overrides(ctx, rotation)

    -- GCD freeze — ONLY real cast bar / channel / our short provisional clock.
    -- NEVER treat a per-spell cooldown on slots 1..6 as global GCD (that froze
    -- the entire rotation whenever any early ability had a CD remaining).
    local casting_now = (UnitCastingInfo and UnitCastingInfo("player"))
        or (UnitChannelInfo and UnitChannelInfo("player"))
    local gcd_active = false
    if casting_now then
        gcd_active = true
    elseif t < (Executor._gcd_until or 0) then
        gcd_active = true
    end
    -- Optional: real global GCD witness (short CD on the cast spell only is
    -- handled in BasicRules per-slot via fill_live_spell_state / cooldowns).
    pend = Executor._pending
    if pend then
        ctx.pending_sid = pend.sid
        -- Multi-dot pending must NOT lock the whole list (no_gcd flag).
        if not pend.off_gcd and not pend.no_gcd then
            gcd_active = true
        end
        local age = t - (pend.cast_t or t)
        local grace = pend.grace or 0.12
        if age > (grace + 0.05) then
            -- Expired pending confirmation window. Drop the in-flight record
            -- so we can re-eval, but do NOT zero a full provisional GCD that
            -- attempt_action set after wire (that was the Consecration spam
            -- path: grace 100ms → free → re-wire → "not ready yet").
            local sid_p = pend.sid
            local was_md = pend.no_gcd or pend.multidot
            Executor._pending = nil
            if was_md then
                -- Multi-dot: free list lock (never held a real GCD).
                Executor._gcd_until = 0
                Executor._gcd_provisional = false
                Executor._gcd_src = "pending_expire"
                clear_sid_soft_locks(sid_p)
                gcd_active = casting_now and true or false
            elseif Executor._gcd_provisional then
                -- Keep remaining provisional GCD; re-sample live CD for this sid.
                local rem = spell_ready_remaining(sid_p, pend.name)
                if rem > 0.05 then
                    Executor._recent = Executor._recent or {}
                    Executor._recent[sid_p] = t + rem
                    -- Global GCD only if still under GCD-length.
                    if rem <= 1.6 and (Executor._gcd_until or 0) < t + rem then
                        Executor._gcd_until = t + rem
                    end
                end
                -- If provisional already elapsed, clear it.
                if (Executor._gcd_until or 0) <= t then
                    Executor._gcd_until = 0
                    Executor._gcd_provisional = false
                    Executor._gcd_src = "pending_expire"
                end
            end
            pend = nil
            ctx.pending_sid = nil
        end
    end
    -- Provisional GCD tracks real GCD (~0.75–1.5s) after wire. Cap only at
    -- a full GCD length — NEVER 150ms (that re-wired Consecration every frame
    -- and produced "spell is not ready yet" spam). Refuse events free early.
    if Executor._gcd_provisional and (Executor._gcd_until or 0) > t + 1.55 then
        Executor._gcd_until = t + 1.55
    end
    if not casting_now and Executor._gcd_provisional and (Executor._gcd_until or 0) <= t then
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        gcd_active = false
    end
    ctx.gcd_active = gcd_active
    ctx.live_gcd_remaining = math.max(0, (Executor._gcd_until or 0) - t)

    local M = metrics()
    if M and M.note_gcd_active then M.note_gcd_active(gcd_active, t) end

    -- _recent is ONLY a same-frame micro lock after a successful wire (or auto-
    -- attack engage). Never used as a "skip this ability for a while" lockout.
    if Executor._recent then
        ctx.cooldowns = ctx.cooldowns or {}
        for sid, exp in pairs(Executor._recent) do
            if exp <= t then
                Executor._recent[sid] = nil
            else
                local cur = tonumber(ctx.cooldowns[sid] or ctx.cooldowns[tostring(sid)]) or 0
                local rem = exp - t
                if rem > cur then
                    ctx.cooldowns[sid] = rem
                    ctx.cooldowns[tostring(sid)] = rem
                end
            end
        end
    end

    -- Metrics ready-probe is optional and expensive (N x spell_ready). ~2 Hz.
    if M and M.note_ready and Engine.spell_ready
        and (not Executor._metrics_ready_t or (t - Executor._metrics_ready_t) >= 0.5) then
        Executor._metrics_ready_t = t
        for _, id in ipairs(spell_ids) do
            local ready = select(1, Engine.spell_ready(ctx, id))
            M.note_ready(id, ready and true or false, t)
        end
    end

    -- Strict top-down priority. First castable wins. On live fail THIS tick only,
    -- fall through to the next slot. Next tick re-evaluates the FULL list
    -- including the ability that just failed - never soft-skip it.
    local slots = rotation.slots or {}
    local maxTries = #slots + 1
    local exclude = nil
    local action, ok, how, err, before_snap
    local trace = { n = 0 }
    for _ = 1, maxTries do
        action, err = Engine.evaluate(rotation, ctx, Conditions,
            { ignore_ready = false, exclude = exclude, trace = trace })
        if not action then break end
        local had_evidence
        -- Clear search before attempt so fallthrough cannot leak hit to next slot.
        ctx.aura_search_hit = action.aura_search_hit
        ok, how, before_snap, had_evidence = Executor.attempt_action(action, ctx)
        ctx.aura_search_hit = nil
        ctx._aura_search_retargeted = nil
        if ok then break end
        -- FAILURE RECOVERY: cast fail → next priority THIS tick. Never abort.
        local how_s = tostring(how or "")
        local is_nready = how_s:find("not_ready", 1, true) or how_s:find("cooldown", 1, true)
        if is_nready then
            -- Runtime refused: spell/GCD not ready. Floor THIS spell; if it
            -- looks like global GCD, hold the list briefly so we don't spam
            -- every lower slot into the same "not ready" UI error.
            local asid = tonumber(action.spell_id) or 0
            local hold = spell_ready_remaining(asid, action.name)
            if hold < 0.75 then hold = 0.75 end
            if hold > 1.55 then hold = 1.55 end
            Executor._recent = Executor._recent or {}
            if asid > 0 then Executor._recent[asid] = t + hold end
            Executor._gcd_until = t + hold
            Executor._gcd_provisional = true
            Executor._gcd_src = "fallthrough_not_ready"
            Executor._pending = nil
            -- Stop fallthrough: nothing else is castable on GCD either.
            action = nil
            ok = false
            how = how_s
            break
        end
        -- Non-readiness fail: clear provisional locks so lower slots run.
        Executor._pending = nil
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "fallthrough_clear"
        ctx.gcd_active = false
        ctx.pending_sid = nil
        ctx.live_gcd_remaining = 0
        if rot_detail() then
            dlog("fallthrough", "#%s %s  %s",
                tostring(action.index), tostring(action.name), tostring(how))
        end
        exclude = exclude or {}
        exclude[action.index] = true
        fill_live_spell_state(ctx, spell_ids)
        apply_slot_policy_overrides(ctx, rotation)
        action = nil
    end
    Executor._last_action = action
    Executor._last_trace = trace
    Executor._last_trace_t = t

    if ok and action then
        Executor._last_err = nil
        Executor._last_attempt_t = t
        Executor._last_skip_key = nil
        Executor._skip_streak = 0
        Executor._next_gap = 0
        local sid = tonumber(action.spell_id) or 0
        if M and M.note_attempt then M.note_attempt(sid, t) end
        local off_gcd = action.slot and action.slot.off_gcd and true or false
        local is_aa = is_auto_attack(sid, action.name)
        local grace = net_grace()
        -- Do NOT soft-CD the spell on wire-ok. That blocked re-fire after silent
        -- fails for multi-frames. Only pending tracks in-flight; land sets micro.
        if is_aa then
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = t + 0.75
            Executor._recent[6603] = t + 0.75
        elseif off_gcd then
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = t + 0.05
        elseif not is_aa then
            local cast_guid = Executor._last_cast and Executor._last_cast.guid
            local is_md = action.aura_search_hit and action.aura_search_hit.guid
            -- Multi-dot may already have set a short pending in attempt_action.
            if not (Executor._pending and Executor._pending.multidot
                and tonumber(Executor._pending.sid) == sid) then
                local g = is_md and math.min(grace, 0.10) or grace
                -- Non-multidot: event window can stay short (grace), but the
                -- provisional GCD must stay at full GCD length set in
                -- attempt_action. Never shrink it back to ~100ms (Consecration spam).
                Executor._pending = {
                    sid = sid, cast_t = t, deadline = t + g, grace = g,
                    before_cd = before_snap and before_snap.cd_start or 0,
                    name = action._cast_name or action.name,
                    off_gcd = false,
                    policy = action.target_policy or slot_policy(action.slot),
                    guid = cast_guid,
                    multidot = is_md and true or false,
                }
                if is_md then
                    if (Executor._gcd_until or 0) < t + g then
                        Executor._gcd_until = t + g
                        Executor._gcd_provisional = true
                        Executor._gcd_src = "pending_grace"
                    end
                else
                    -- Preserve wire_pending GCD if already longer than grace.
                    local need = g
                    if Executor.gcd_fallback then
                        local d = select(1, Executor.gcd_fallback())
                        if d and d > need then need = d end
                    end
                    if need < 0.75 then need = 0.75 end
                    if (Executor._gcd_until or 0) < t + need then
                        Executor._gcd_until = t + need
                        Executor._gcd_provisional = true
                        Executor._gcd_src = "pending_grace"
                    end
                end
                Executor._recent = Executor._recent or {}
                local floor_t = is_md and 0.08 or (math.max(g, 0.75))
                if not Executor._recent[sid] or Executor._recent[sid] < t + floor_t then
                    if not Executor._recent[sid] or Executor._recent[sid] < t then
                        Executor._recent[sid] = t + floor_t
                    end
                end
            end
        end
        Executor._idle_until = nil
        Executor._idle_had_target = ctx.target_exists and true or false
        -- One clear line per cast attempt.
        dlog("cast", "FIRE  #%d %s  edge=%.1f",
            tonumber(action.index) or 0,
            tostring(action.name),
            tonumber(ctx.target_distance) or -1)
        if M then
            if M.note_tick then M.note_tick(tick_timer_ms(_tick_t0)) end
            if M.maybe_log then M.maybe_log(t) end
        end
        return action, how
    end

    -- Nothing cast. Compact wait log: one line on reason change, slow heartbeat.
    -- Full per-slot dump only in detail/debug mode.
    local reason = how or err or "no_match"
    Executor._last_err = reason
    -- ALSO through Telemetry, not only the debug log. The wait log below is real
    -- but goes to a different stream, so Telemetry.counts() showed ZERO for "rot"
    -- and the liveness contract concluded the engine was dead while it was in
    -- fact ticking 30 times a second. Two streams that disagree about whether a
    -- subsystem is alive is worse than one.
    report_idle(reason)

    if slot_level_fail(reason) then
        Executor._next_gap = 0
    end
    -- Key ignores edge jitter (9 vs 28) so distance buckets don't re-spam.
    local key = string.format("%s|%s|%s",
        tostring(reason),
        tostring(ctx.user_state or "free"),
        ctx.target_exists and "t" or "nt")
    local gcd_rem = 0
    if (Executor._gcd_until or 0) > t then gcd_rem = Executor._gcd_until - t end
    local changed = (key ~= Executor._last_skip_key)
    Executor._skip_streak = (not changed and (Executor._skip_streak or 0) or 0) + 1
    -- Quiet waits (no target / gcd / power): heartbeat every 5s.
    -- Other waits: every 3s. Always log on reason change.
    local boring = (reason == "no_target" or reason == "gcd" or reason == "power"
        or reason == "enemies_in_range" or reason == "user_busy" or reason == "idle")
    local hb = boring and 5.0 or 3.0
    local heartbeat = (t - (Executor._last_skip_log_t or 0)) >= hb
    if changed or heartbeat then
        Executor._last_skip_log_t = t
        Executor._last_skip_key = key
        local edge = tonumber(ctx.target_distance)
        local edge_s = (edge and edge < 900) and string.format("%.0fyd", edge) or "-"
        local gcd_s = (gcd_rem > 0.02) and string.format(" gcd=%.1f", gcd_rem) or ""
        local line = string.format("wait %s  x%d  tgt=%s  edge=%s%s",
            tostring(reason),
            Executor._skip_streak or 1,
            ctx.target_exists and "yes" or "no",
            edge_s, gcd_s)
        -- On reason change, append compact slot why (one line, not 7).
        if changed and trace and trace.n and trace.n > 0 then
            local compact = format_trace_compact(trace)
            if compact ~= "" then
                line = line .. "  |  " .. compact
            end
        end
        dlog("rot", "%s", line)
        -- Verbose: full per-slot diagnostics (debug mode only).
        if rot_detail() and trace and trace.n and trace.n > 0 then
            for i = 1, trace.n do
                local tr = trace[i]
                if tr then
                    local sid = tonumber(tr.sid) or 0
                    local diag = ctx.spell_range_diag and (ctx.spell_range_diag[sid] or ctx.spell_range_diag[tostring(sid)])
                    local dpart = ""
                    if diag then
                        dpart = string.format(" edge=%s cli=%s",
                            diag.gap and string.format("%.1f", diag.gap) or "?",
                            tostring(diag.client))
                    end
                    dlog("slot", "#%d %s  %s%s%s",
                        tonumber(tr.i) or i,
                        tostring(tr.name),
                        tostring(tr.verdict or "?"),
                        tr.why and ("/" .. tostring(tr.why)) or "",
                        dpart)
                end
            end
        end
    end

    -- Idle throttle: never sleep when aura_search / multi-dot may still find units
    -- without a client target (was freezing multi-dot at "no_target").
    do
        local has_aura_search = false
        for _, slot in ipairs(rotation.slots or {}) do
            for _, c in ipairs(slot.conditions or {}) do
                if c and c.id == "aura_search" then has_aura_search = true; break end
            end
            if has_aura_search then break end
        end
        local G = gate()
        local idle = false
        if ctx.user_state and ctx.user_state ~= "free" then
            idle = true
        elseif not ctx.target_exists and not ctx._has_no_target_slot and not has_aura_search then
            idle = true
        elseif G and G.list_is_idle and not has_aura_search then
            idle = select(1, G.list_is_idle(ctx, spell_ids))
        end
        Executor._idle_had_target = ctx.target_exists and true or false
        if idle then
            Executor._idle_until = t + 0.05
        else
            Executor._idle_until = nil
        end
    end

    if M then
        if M.note_tick then M.note_tick(tick_timer_ms(_tick_t0)) end
        if M.maybe_log then M.maybe_log(t) end
    end
    return nil, reason
end

function Executor.tick()
    if Executor._in_tick then
        Executor._retick_pending = true
        return nil, "reentrant"
    end
    Executor._in_tick = true
    local ok, a, b = pcall(Executor._tick_body)
    Executor._in_tick = false
    if Executor._retick_pending then
        Executor._retick_pending = false
        request_retick(Executor._retick_why or "chained")
    end
    if not ok then
        Executor._last_err = "tick_error:" .. tostring(a)
        return nil, Executor._last_err
    end
    return a, b
end

-- Adaptive tick cadence: full rate when something can cast, calmer OOC / UI open.
-- Capability unchanged — work is amortized, not dropped forever.
local function adaptive_tick_interval()
    if Executor._pending then return 0 end
    -- Full rate in combat or with multi-dot / hostiles work.
    if UnitAffectingCombat and UnitAffectingCombat("player") then return 0 end
    if UnitExists and UnitExists("target") then
        if UnitCanAttack and UnitCanAttack("player", "target")
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
            return 0
        end
    end
    -- Rotation with aura_search: never drop to 80ms idle (misses pack swaps).
    local nc = Executor._needs_cache
    if nc and nc.aura then return 0 end
    -- Menu / editor open: leave headroom for UI paint (major hitch source).
    if RaijinLab and RaijinLab._ui_open_hint then return 0.12 end
    local Menu = RaijinLab and RaijinLab.Menu
    if Menu and Menu.frame and Menu.frame.IsShown and Menu.frame:IsShown() then
        return 0.12
    end
    local Ed = RaijinLab and RaijinLab.RotationEditor
    if Ed and Ed.frame and Ed.frame.IsShown and Ed.frame:IsShown() then
        return 0.12
    end
    return 0.05 -- OOC no target, no aura_search
end

function Executor.start(interval)
    Executor.stop()
    ensure_events()
    -- Default adaptive (interval < 0). Explicit >= 0 pins a fixed cadence.
    local fixed = nil
    if type(interval) == "number" and interval >= 0 then fixed = interval end

    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.rotation_enabled = true
    RaijinLabDB.modules = RaijinLabDB.modules or {}
    RaijinLabDB.modules.rotation = true
    Executor._no_runtime_warned = false
    Executor._last_attempt_t = 0
    Executor._last_print_t = 0
    Executor._last_skip_key = nil
    Executor._gcd_until = 0
    Executor._pending = nil
    Executor._recent = nil
    Executor._unconf = nil
    Executor._idle_until = nil
    Executor._idle_had_target = false
    Executor._skip_streak = 0
    do
        local G = gate()
        if G and G.reset_session then G.reset_session() end
    end
    Executor._next_gap = 0
    Executor._refuse = nil
    local M = metrics()
    if M and M.reset then M.reset() end

    local f = CreateFrame("Frame", nil, UIParent)
    f:Show()
    local acc = 0
    f:SetScript("OnUpdate", function(_, e)
        if not RaijinLabDB or not RaijinLabDB.rotation_enabled then return end
        local want = fixed
        if want == nil then want = adaptive_tick_interval() end
        if want <= 0 then
            local ok, err = pcall(Executor.tick)
            if not ok then
                Executor._last_err = "tick_error:" .. tostring(err)
                say("tick error: " .. tostring(err))
            end
            return
        end
        acc = acc + (e or 0)
        if acc >= want then
            acc = 0
            local ok, err = pcall(Executor.tick)
            if not ok then
                Executor._last_err = "tick_error:" .. tostring(err)
                say("tick error: " .. tostring(err))
            end
        end
    end)
    Executor._frame = f
    Executor._cast_count = 0
    Executor._tick_count = 0

    local hasRt = RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()
    local rot = select(1, Executor.get_active_rotation())
    local n = 0
    if rot then
        for _, s in ipairs(rot.slots or {}) do
            if tonumber(s.spell_id) and tonumber(s.spell_id) ~= 0 then n = n + 1 end
        end
    end
    say(string.format(
        "rotation ON  runtime=%s  spells=%d  ver=%s",
        hasRt and "yes" or "NO",
        n,
        tostring(hasRt and RaijinLab:RuntimeVersion() or "?")
    ))
    if not hasRt then
        say("inject tools\\inject.bat in-world, then /reload")
    end
    if n == 0 then
        say("no spells configured - drop from spellbook onto slots")
    end
end

function Executor.stop()
    if Executor._frame then
        Executor._frame:SetScript("OnUpdate", nil)
        Executor._frame:Hide()
        Executor._frame = nil
    end
    if RaijinLabDB then
        RaijinLabDB.rotation_enabled = false
        if RaijinLabDB.modules then RaijinLabDB.modules.rotation = false end
    end
    say("rotation OFF")
end

function Executor.status()
    local last = Executor._last_cast
    local act = Executor._last_action
    local hasRt = RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()
    local msg = string.format(
        "enabled=%s runtime=%s ticks=%s casts=%s err=%s frame=%s",
        tostring(RaijinLabDB and RaijinLabDB.rotation_enabled),
        tostring(hasRt and (RaijinLab:RuntimeVersion() or true) or false),
        tostring(Executor._tick_count or 0),
        tostring(Executor._cast_count or 0),
        tostring(Executor._last_err or "-"),
        tostring(Executor._frame ~= nil)
    )
    if act then
        msg = msg .. string.format(" try=%s#%s", tostring(act.name), tostring(act.spell_id))
    end
    if last then
        msg = msg .. string.format(" last=%s via %s ev=%s",
            tostring(last.name), tostring(last.via), tostring(last.evidence or "-"))
    end
    local M = metrics()
    if M and M.snapshot then
        local s = M.snapshot()
        msg = msg .. string.format(" react=%.0fms free=%.0fms score=%.0f",
            s.reaction.avg or 0, s.free_react.avg or 0, s.consistency or 0)
    end
    return msg
end

function Executor.metrics_report()
    local M = metrics()
    if not M or not M.report_lines then return { "metrics unavailable" } end
    return M.report_lines()
end

if RaijinLab then
    RaijinLab.RotationExecutor = Executor
end

return Executor
