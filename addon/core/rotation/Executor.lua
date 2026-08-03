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
-- LIVE BUG 2026-07-31: net_grace() was defined AFTER attempt_action as a
-- `local function`, so every successful cast threw
-- "attempt to call global 'net_grace' (a nil value)" mid-path. That aborted
-- GCD/_recent/aura notes → Plague Strike multi-dot spam (400+ wires/sec) and
-- Consecration "not ready" spam. Forward-declare + define early below.
local net_grace
local micro_lock

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

-- Defined early (assigns the forward-declared locals). Used by attempt_action.
net_grace = function()
    -- Short confirm window only (land/fail events free sooner). Not a cast delay.
    local lag = latency_sec()
    local g = lag * 0.8 + 0.04
    if g < 0.06 then g = 0.06 end
    if g > 0.14 then g = 0.14 end
    return g
end

micro_lock = function()
    return 0.016
end

-- Authoritative remaining GCD/CD for a spell (seconds). Primary is Blizzard
-- GetSpellCooldown (read-only query, works from insecure code). Supplement is
-- the runtime's SpellCooldownMs — PURE C++ since 1.10.x (calls the client's
-- own InternalGetCooldown/InternalGetTime directly; the old nested-lua_pcall
-- stack-corruption that forced it off is gone). Cached 100ms/spell so 8 slots
-- do not issue 8 bridge calls every tick.
local _rt_cd_cache = {}
local function runtime_cooldown_remaining(sid)
    -- 2026-08-02 (CRASH FIX — the persistent 0x512B07 Lua-VM corruption):
    -- NEVER cross the bridge from INSIDE a game event handler. The event path
    -- (apply_pending_refuse from UNIT_SPELLCAST_*/UI_ERROR) called this
    -- synchronously -> RuntimeCall("SpellCooldownMs") re-entered the runtime
    -- while the game's Lua VM was mid event-dispatch -> corrupted the VM
    -- (live forensics: SpellCooldownMs was the last bridge call, then the game
    -- crashed 6ms later at 0x512B07 reading a garbage closure). Executor._in_event
    -- is set only around the OnEvent body; Lua GetSpellCooldown is still used
    -- there, and the tick recomputes the authoritative cooldown next frame.
    if Executor._in_event then return 0 end
    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime()) then return 0 end
    local t = now()
    local e = _rt_cd_cache[sid]
    if e and e.until_t and t < e.until_t then return e.best end
    local ok, rem = pcall(RaijinLab.RuntimeCall, RaijinLab, "SpellCooldownMs", sid)
    local best = 0
    if ok then
        rem = tonumber(rem) or 0
        if rem and rem > 0 then best = rem / 1000 end
    end
    _rt_cd_cache[sid] = { until_t = t + 0.1, best = best }
    return best
end

-- AUTHORITATIVE MELEE/MELEE-RANGE CLASSIFICATION (2026-08-02). The runtime
-- decodes the client's loaded Spell.dbc record (exact 0x4CFD20/0x4CFBB0 path)
-- and reads the spell's range entry to say whether facing is REQUIRED. This
-- replaces the maxR>8 heuristic: the client only refuses "target needs to be
-- in front of you" for melee-range spells. Returns 1=melee(facing required),
-- 0=ranged(no facing), nil=unknown. Cached 120s/spell (spell data is static).
-- NEVER fail-closed: unknown -> nil -> Lua falls back to the range heuristic.
-- ALSO returns the spell's REAL max range from the client's Spell.dbc range
-- entry (max=%.2f) — GetSpellInfo returns 0 for custom Ascension spell IDs,
-- so the Lua spell_range_info() is blind for most rotation spells. The runtime
-- range is the authority for the per-candidate range gate (the "too far away"
-- client refusal was a far candidate passing a maxR=0 gate).
local _rt_melee_cache = {}
local function runtime_spell_melee(sid)
    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime()) then return nil end
    local e = _rt_melee_cache[sid]
    if e and e.until_t and now() < e.until_t then return e.melee, e.maxR end
    local ok, pack = pcall(RaijinLab.RuntimeCall, RaijinLab, "SpellMeleeInfo", sid)
    local melee, maxR = nil, nil
    if ok and type(pack) == "string" then
        local m = pack:match("melee=(%d)")
        if m then melee = (tonumber(m) or 0) ~= 0 and 1 or 0 end
        local mx = pack:match("max=([%-%d%.]+)")
        if mx then
            maxR = tonumber(mx)
            if not maxR or maxR ~= maxR or maxR <= 0 or maxR > 500 then maxR = nil end
        end
    end
    _rt_melee_cache[sid] = { until_t = now() + 120, melee = melee, maxR = maxR }
    return melee, maxR
end

local function spell_ready_remaining(sid, name)
    local t = now()
    local best = 0
    local until_t = tonumber(Executor._gcd_until) or 0
    if until_t > t then best = until_t - t end
    -- Primary: Blizzard GetSpellCooldown (works on every client)
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
    end
    -- Authoritative supplement: runtime pure-C++ cooldown (covers custom
    -- spells / cases where Lua GetSpellCooldown misses).
    if sid and sid > 0 then
        local rt = runtime_cooldown_remaining(sid)
        if rt > best then best = rt end
    end
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
    -- No time-based GUID blacklist. Same-tick exclude handles fallthrough;
    -- sticky blacklists felt like "pauses" after face/fail. Awareness only.
    return
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

-- Instant re-eval after a cast refuse / land event.
--
-- 2026-08-02 (CRASH FIX): NEVER run the full tick SYNCHRONOUSLY from inside a
-- game event handler. The old code did `pcall(Executor.tick)` right here when
-- UNIT_SPELLCAST_SUCCEEDED/FAILED fired — running the whole tick (with its
-- ~dozens of bridge calls re-entering the VM) inside the game's protected-call
-- event dispatch corrupted the Lua VM (live: rotation-enable crash, game VM
-- reading garbage 14ms after the first landed cast). Always defer one frame via
-- C_Timer.After(0) — a normal Lua execution context, not the event's protected
-- frame. One frame (~16ms) is far faster than the grace window and costs nothing
-- in feel. When already inside a tick, chain once on exit (no re-entry).
local function request_retick(why)
    if not RaijinLabDB or not RaijinLabDB.rotation_enabled then return end
    Executor._retick_why = why
    if Executor._in_tick then
        Executor._retick_pending = true
        return
    end
    if Executor._retick_armed then return end
    Executor._retick_armed = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            Executor._retick_armed = false
            -- 2026-08-02 (OFF-STILL-CASTING FIX): an armed retick can fire
            -- AFTER the user turned the rotation off (stop() only removed the
            -- OnUpdate; the already-scheduled C_Timer still runs). Re-check the
            -- enabled flag INSIDE the callback so a post-OFF retick is a no-op
            -- instead of running one more full tick (which cast again → the
            -- "too far away" spam right after OFF).
            if not RaijinLabDB or not RaijinLabDB.rotation_enabled then return end
            -- 2026-08-02 (NO-HESITATION): this is the event-driven path — it
            -- must bypass the facing/oor poll throttle so a landed cast re-
            -- evaluates the next ability immediately (no 0.25s hesitation).
            Executor._from_event = true
            pcall(Executor.tick)
            Executor._from_event = false
        end)
    else
        Executor._retick_armed = false
    end
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
        -- Floor THIS spell to live remaining. When GetSpellCooldown returns nil
        -- for Ascension custom spells, spell_ready_remaining may return 0 even
        -- when the spell genuinely IS on cooldown. Minimum floor prevents
        -- immediate re-fire → refuse → re-fire loops (observed: Consecration
        -- casting 3x in 3 seconds on an 8-second CD).
        local hold = spell_ready_remaining(sid, name)
        if hold > 10.0 then hold = 10.0 end
        if hold < 0.35 then hold = 0.35 end  -- minimum 350ms after "not ready"
        Executor._recent = Executor._recent or {}
        if sid and hold > 0 then
            Executor._recent[sid] = now() + hold
        end
        -- Probe GCD from multiple sources (spell 61304 may be nil on Ascension)
        local gcd_rem = 0
        if GetSpellCooldown then
            -- Try the GCD token first, then auto-attack, then the refused spell
            local probes = { 61304, 6603, 75, sid }
            for _, pid in ipairs(probes) do
                if pid and pid > 0 and gcd_rem <= 0 then
                    local s2, d2 = GetSpellCooldown(pid)
                    s2, d2 = tonumber(s2) or 0, tonumber(d2) or 0
                    if d2 > 0.75 and d2 <= 1.6 then
                        gcd_rem = (s2 + d2) - now()
                        if gcd_rem > 0 then break end
                    end
                end
            end
        end
        if gcd_rem > 0.02 then
            Executor._gcd_until = now() + math.min(gcd_rem, 1.55)
            Executor._gcd_provisional = true
            Executor._gcd_src = "not_ready_gcd"
        else
            Executor._gcd_until = 0
            Executor._gcd_provisional = false
            Executor._gcd_src = "not_ready_free"
        end
        log_cast("refused", sid, name or fail_name,
            "not_ready:" .. string.format("%.2f", hold), cast_t)
        return true
    end

    -- FACING REFUSE (2026-08-01 + 2026-08-02, FINAL): the CLIENT says we are
    -- not facing — the one authoritative signal. HARD RULE (Prompt.md): the
    -- rotation NEVER turns the character and never moves it. No FaceTowardGuid /
    -- TurnByDelta / StopMoving here — the player steers. We only back off this
    -- spell so it does not re-fire into the same refusal every frame, and let
    -- the next tick re-measure (the runtime snapshot reads the real facing).
    -- Pre-wire we already skip not-facing candidates (see the facing gate), so
    -- a refuse here is a rare edge (target moved mid-wire / measurement lag).
    if rl:find("in front", 1, true) or rl:find("facing", 1, true) then
        -- 2026-08-02: free the list (other spells may still work) but floor
        -- THIS spell so it does not re-fire into the same refusal every frame.
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "refuse_facing"
        Executor._recent = Executor._recent or {}
        if sid and sid > 0 then Executor._recent[sid] = now() + 0.45 end
        log_cast("refused", sid, name or fail_name,
            "facing:" .. (reason ~= "" and tostring(reason) or "in front"), cast_t)
        return true
    end
    -- LOS REFUSE: client says the path is blocked. Our TraceLine can say clear
    -- while the client disagrees (moving target / geometry). Back off so we do
    -- not spam "out of line of sight" every frame; re-evaluate after the floor.
    if rl:find("line of sight", 1, true) or rl:find("los", 1, true) then
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "refuse_los"
        Executor._recent = Executor._recent or {}
        if sid and sid > 0 then Executor._recent[sid] = now() + 0.6 end
        log_cast("refused", sid, name or fail_name,
            "los:" .. (reason ~= "" and tostring(reason) or "line of sight"), cast_t)
        return true
    end
    -- RANGE REFUSE (2026-08-02): client says out of range — the authoritative
    -- signal (our position/range model can disagree on custom Ascension spells
    -- / moving targets). Free the list but floor THIS spell 0.6s so we do not
    -- spam "too far away" every frame; the player may be approaching.
    if rl:find("too far", 1, true) or rl:find("out of range", 1, true) then
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "refuse_range"
        Executor._recent = Executor._recent or {}
        if sid and sid > 0 then Executor._recent[sid] = now() + 0.6 end
        log_cast("refused", sid, name or fail_name,
            "range:" .. (reason ~= "" and tostring(reason) or "too far away"), cast_t)
        return true
    end
    -- RESOURCE REFUSE (2026-08-02, 14:09 FIX): client says "Not enough runes" /
    -- "not enough mana" / "requires ..." etc. The old code had NO branch for
    -- this — it fell through to the generic "Other refuses" which called
    -- clear_sid_soft_locks, so the spell re-fired EVERY tick (live: Icy Touch
    -- FIRE'd 8x in ~1s at 14:09:52, all refused "Not enough runes" — a hard
    -- spam loop that ALSO starved the GCD/rotation). DK rune / resource gates
    -- are client-authoritative (IsUsableSpell misses rune availability on
    -- custom Ascension spells). Floor the spell so it re-evaluates after the
    -- resource window (rune CD ~0.5-1.0s) instead of every frame.
    if rl:find("not enough", 1, true) or rl:find("requires", 1, true)
        or rl:find("need a", 1, true) or rl:find("need to be", 1, true)
        or rl:find("need an", 1, true) then
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "refuse_resource"
        Executor._recent = Executor._recent or {}
        if sid and sid > 0 then Executor._recent[sid] = now() + 0.6 end
        log_cast("refused", sid, name or fail_name,
            "resource:" .. (reason ~= "" and tostring(reason) or "not enough"), cast_t)
        return true
    end

    -- CHARMED / CC REFUSE (2026-08-02, 19:01 SPAM FIX): "Can't attack while
    -- charmed" / fear / mind-control / stun means the player is CC'd — the
    -- client refuses EVERY spell until it clears. Floor this spell AND set a
    -- player-CC window so the whole rotation pauses (wait_cc) instead of
    -- re-firing the same cast into the refusal every ~10ms (live: Plague
    -- Strike FIRE'd ~100x/sec into "Can't attack while charmed" — a hard
    -- spam loop that also starved every lower-priority slot, aura search
    -- included).
    if rl:find("charmed", 1, true) or rl:find("can't attack", 1, true)
        or rl:find("cannot attack", 1, true)
        or rl:find("mind control", 1, true) or rl:find("mind-control", 1, true)
        or rl:find("feared", 1, true)
        or rl:find("stunned", 1, true) or rl:find("can't do that", 1, true)
        or rl:find("cannot do that", 1, true) then
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._gcd_src = "refuse_cc"
        Executor._recent = Executor._recent or {}
        if sid and sid > 0 then Executor._recent[sid] = now() + 0.6 end
        Executor._player_cc_until = now() + 0.5
        log_cast("refused", sid, name or fail_name,
            "cc:" .. (reason ~= "" and tostring(reason) or "charmed"), cast_t)
        return true
    end

    -- Other refuses: free list completely. Same-tick fallthrough / retick.
    Executor._gcd_until = 0
    Executor._gcd_provisional = false
    Executor._gcd_src = "refuse_instant"
    clear_sid_soft_locks(sid)
    -- 2026-08-02 (19:01 SPAM FIX): ALWAYS floor the refused spell — an
    -- unrecognized client refusal must NEVER re-fire at 100Hz (the charmed
    -- spam lived here: this path never set _recent). The floor is a backoff,
    -- not a fallback: the client refused, so do not hammer it.
    Executor._recent = Executor._recent or {}
    if sid and sid > 0 then Executor._recent[sid] = now() + 0.6 end
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
        -- 2026-08-02 (CRASH FIX): mark that we are INSIDE the game's event
        -- dispatch. Any bridge call made synchronously from here re-enters the
        -- runtime under the game's Lua VM and corrupts it (persistent 0x512B07).
        -- runtime_cooldown_remaining checks this and uses Lua-only cooldown here.
        Executor._in_event = true
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
                    -- Always re-eval: fail must not pause the rotation. Spell
                    -- floors keep the failed ability off; others cast now.
                    request_retick("event_fail_instant")
                elseif looks_like_cast_error(rl) then
                    local p = Executor._pending
                    if p then
                        apply_pending_refuse(reason or "cast_err", p.name)
                        request_retick("event_fail_force")
                    end
                end
            end
        end
        -- Leave the event-dispatch window: bridge calls from the next tick /
        -- OnUpdate are safe (they run in a normal Lua execution context).
        Executor._in_event = false
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
--
-- AUTHORITATIVE SOURCE (2026-08-01, RE-verified): Lua GetSpellInfo is NOT
-- hardware-event-gated (the client's GetSpellInfo handler 0x00540A30 has no
-- 0xC21000 flag check) and is a read-only spell-data query — it returns the
-- client's real min/max range for stock AND custom spells from insecure addon
-- code. A runtime SpellRange bridge was tried (direct call of that handler)
-- and REMOVED: the handler builds a spell object + touches the player via
-- 0x801650/0x7ff480 and was the prime suspect for a use-after-free crash 2s
-- after arming. Lua GetSpellInfo is the safe authoritative source. maxR==0
-- (self/melee/unknown custom) is handled by the precise edge model: the
-- default band is 5yd and the measured ObjectPosition edge overrides a lying
-- client.
local function spell_range_info(sid)
    sid = tonumber(sid) or 0
    if sid <= 0 or not GetSpellInfo then return 0, 0 end
    local ok, _, _, _, _, _, _, minR, maxR = pcall(GetSpellInfo, sid)
    if not ok then return 0, 0 end
    return tonumber(minR) or 0, tonumber(maxR) or 0
end

-- AUTHORITATIVE player cast/attack state (RE-verified 2026-08-01). The
-- runtime reads the client's real casting fields (player+0xA6C cast id,
-- +0xA7C cast end, +0xA70/0xA74 target) and the current-spells list
-- ([0xAF5254], 6603 present = auto-attacking) directly — the Lua
-- UnitCastingInfo/IsCurrentSpell NO-OP from insecure addon code (protected-
-- call / hardware-event gate), which is exactly why the old rotation re-cast
-- Attack every 0.35s and got "blocked action" errors. This is the bridge
-- authority the rotation uses for busy/attack decisions.
-- Returns: state ("free"|"attacking"|"casting"|"channeling"|"targeting"),
--          castSpellId, castEndMs, castTargetGuid.
local cast_state_cache = { t = 0, v = "free", sid = 0, end_ms = 0, tgt = 0 }
local function cast_state()
    local t = now()
    if cast_state_cache.t and (t - cast_state_cache.t) < 0.05 and cast_state_cache.v then
        return cast_state_cache.v, cast_state_cache.sid, cast_state_cache.end_ms, cast_state_cache.tgt
    end
    local state, sid, end_ms, tgt = "free", 0, 0, 0
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime() then
        local ok, packed = pcall(RaijinLab.RuntimeCall, RaijinLab, "PlayerCastState")
        if ok and type(packed) == "string" then
            -- packed: cast=<sid>|end=<ms>|tgt=0x..|attack=0|1|atk_tgt=0x..|auto=..|cur=..|tgtflag=0|1|time=..
            -- (%X is the non-hex class — use [0-9a-fA-F] because the runtime
            -- formats GUIDs with UPPERCASE hex via %llX.)
            local cid, cend, cgtg, atk, tgtf =
                packed:match("^cast=(%-?%d+)|end=(%-?%d+)|tgt=0x([0-9a-fA-F]+)|attack=(%d)|atk_tgt=0x[0-9a-fA-F]+|auto=%d+|cur=%d+|tgtflag=(%d)")
            if cid then
                sid = tonumber(cid) or 0
                end_ms = tonumber(cend) or 0
                tgt = tonumber(cgtg, 16) or 0
                if tonumber(tgtf) == 1 then state = "targeting"
                elseif sid and sid > 0 then state = "casting"
                elseif tonumber(atk) == 1 then state = "attacking"
                else state = "free" end
            end
        end
    end
    if state == "free" then
        -- Runtime offline fallback: Lua-level (may no-op when protected — the
        -- runtime is the real authority; this only prevents a hard nil crash).
        if UnitCastingInfo and UnitCastingInfo("player") ~= nil then
            state, sid = "casting", 1
        elseif UnitChannelInfo and UnitChannelInfo("player") ~= nil then
            state, sid = "channeling", 1
        end
    end
    cast_state_cache = { t = t, v = state, sid = sid, end_ms = end_ms, tgt = tgt }
    return state, sid, end_ms, tgt
end

-- Combat reach (melee / unit-targeted). Descriptor + Trinity default 1.5.
local function combat_reach(unit)
    -- 2026-08-02 (NO FALLBACKS, user directive): an unmeasured combat reach
    -- must NOT silently become 1.5 — the range model would then claim a
    -- precise geometry it does not have. Return nil so the caller's range
    -- model fails closed (never casts on a guessed hitbox).
    if not (RaijinLab and RaijinLab.ObjectCombatReach) then return nil end
    local ok, v = pcall(RaijinLab.ObjectCombatReach, RaijinLab, unit)
    if not ok then return nil end
    v = tonumber(v)
    if not v or v ~= v or v < 0 or v > 100 then return nil end
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
--
-- 2026-08-02 (FPS FIX): World.build_context fills ctx.target_distance_center /
-- player_combat_reach / target_combat_reach / target_bounding_radius ONCE per
-- tick. live_range_model is called by BOTH fill_live_spell_state AND
-- spell_in_range_vs_target, so reading the tick cache first removes ~8 bridge
-- round-trips (ObjectPosition x2 + CombatReach x2 + BoundingRadius) per tick
-- (~240/s in combat). Live reads remain the fallback when the cache is absent.
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
        pr = tonumber(pr)
        tr = tonumber(tr)
        -- 2026-08-02 (NO FALLBACKS): unknown/outlier reach => no precise
        -- model => fail closed (caller refuses the cast, never guesses).
        if not pr or pr < 0 or pr > 100 or not tr or tr < 0 or tr > 100 then
            return nil, nil, nil, nil, nil, false
        end
        local edge = center - pr - tr
        if edge < 0 then edge = 0 end
        -- Self-AoE: pure center for normal models; giant bound extends only.
        -- Use the tick-cached bounding radius when available (no bridge call).
        local ext = 0
        local tb = ctx and ctx.target_bounding_radius
        if not tb and tguid then tb = bounding_radius(tguid) end
        if tb and tb > AOE_BOSS_BOUND then ext = tb end
        local aoe = center - ext
        if aoe < 0 then aoe = 0 end
        return edge, aoe, center, pr, tr, true
    end

    -- TICK-CACHE FIRST (computed once per tick by World.build_context).
    if ctx and ctx.target_distance_precise == true
        and tonumber(ctx.target_distance_center or 0) > 0 then
        local center = tonumber(ctx.target_distance_center)
        local tguid = UnitGUID and UnitGUID("target") or nil
        return pack(center,
            tonumber(ctx.player_combat_reach),
            tonumber(ctx.target_combat_reach),
            tguid)
    end

    -- Fallback: live reads only when the tick cache is absent (non-rotation
    -- consumers / a target that changed mid-tick).
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

    -- 2026-08-02 (NO FALLBACKS — user directive): a targeted (non-AoE) spell
    -- with an UNKNOWN range is a HARD failure — never a silent 5-yard default
    -- that casts at out-of-range targets. The runtime decodes the real
    -- Spell.dbc range (SpellMeleeInfo); if BOTH GetSpellInfo and the runtime
    -- fail, surface it and fail the cast.
    local band
    if is_aoe then
        band = SELF_AOE_RADIUS
    elseif maxR and maxR > 0 then
        band = maxR
    else
        local _rt_m, rt_maxR = runtime_spell_melee(sid)
        if rt_maxR and rt_maxR > 0 then
            band = rt_maxR
        else
            local _rd = {
                sid = sid, name = name, minR = minR, maxR = maxR, band = 0,
                gap = is_aoe and aoe or edge, edge = edge, aoe = aoe,
                center = center, precise = precise and true or false,
                client = client_r == nil and "nil" or tostring(client_r),
                kind = is_aoe and "aoe" or "targeted",
                verdict = "range_unknown",
            }
            return false, "range_unknown", _rd
        end
    end
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
    -- TARGETED: CENTER vs maxRange — the CLIENT's authority (2026-08-02).
    -- The client measures CENTER distance against the spell's max range
    -- (live proof: a 5yd melee refused "Out of range" at center=5.0 with
    -- edge=2.0). The OLD gate compared EDGE (center - pr - tr), which let a
    -- 5yd melee wire at center up to ~8yd (edge 5 <= band 5) -> the client
    -- refused "Out of range" on every cast. USER DIRECTIVE (perfect range):
    -- a spell NEVER casts beyond its real max range — no tolerance, no
    -- silent slack, no edge-based looseness.
    ----------------------------------------------------------------------
    if not is_aoe then
        if precise and center ~= nil then
            diag.gap = center
            if minR and minR > 0 and center + RANGE_EPS < minR then
                diag.verdict = "oor_min"
                return false, "oor", diag
            end
            if center > band + RANGE_EPS then
                diag.verdict = "oor_center"
                return false, "oor", diag
            end
            if client_r == 0 then
                -- IsSpellInRange returns 0 for Ascension custom spells even
                -- when the target IS in range; precise center already proved
                -- in-range -> cast (measurement overrides the lying API).
                diag.verdict = "in_center_ovr"
                return true, nil, diag
            end
            diag.verdict = "in_center"
            return true, nil, diag
        end
        -- No precise center: only the client API can say.
        if client_r == 1 then
            diag.verdict = "in_client"
            return true, nil, diag
        end
        if client_r == 0 then
            diag.verdict = "oor_client"
            return false, "oor", diag
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
            -- 2026-08-02 (NO FALLBACKS): unknown range = nil (the caller's
            -- corpse check fails) — never a silent 30yd search.
            return tonumber(c.args and c.args.range)
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
            elseif search_guid then
                -- Range vs search unit.
                --
                -- AUTHORITATIVE (2026-08-02): the runtime AuraSearch pack ALWAYS
                -- carries the measured center distance (search.dist) — the exact
                -- number the runtime used to rank closest-first AND to filter
                -- (units beyond maxRange+1 are never in the pack). Use it
                -- directly. NO per-spell ObjectPosition round-trip: that re-read
                -- is the same snapshot data, and each bridge crossing inside the
                -- game Lua VM is a crash-surface (post-cast burst). The check
                -- ALWAYS runs — far units are refused, in-range units cast —
                -- with zero dependence on a fallible second call (never fail-
                -- closed: no measurement -> proceed, client is final authority).
                local search = opts.ctx and opts.ctx.aura_search_hit
                local center = search and tonumber(search.dist)
                if center and center > 0 then
                    local minR, maxR = spell_range_info(sid)
                    -- 2026-08-02 (RUNTIME RANGE AUTHORITY): GetSpellInfo returns
                    -- 0 for custom Ascension IDs. The runtime decodes the real
                    -- Spell.dbc range entry (SpellMeleeInfo) — that IS the
                    -- authority.
                    local rt_melee, rt_maxR = runtime_spell_melee(sid)
                    if rt_maxR and rt_maxR > 0 then maxR = rt_maxR end
                    -- 2026-08-02 (NO FALLBACKS — user directive): the spell's
                    -- REAL max range is REQUIRED. If BOTH GetSpellInfo AND the
                    -- runtime Spell.dbc decode fail, that is a HARD failure to
                    -- surface — never a silent 30-yard default that casts at
                    -- out-of-range targets (the "why is icy touch searching in
                    -- 30 yards" bug). Fail the cast with "range_unknown".
                    local band = (maxR and maxR > 0) and maxR
                    if not band then
                        return false, "range_unknown"
                    end
                    -- 2026-08-02 (19:05 PERFECT RANGE, user directive): compare
                    -- the search unit's CENTER distance directly against the
                    -- spell's real max range — NO tolerance (the old ranged
                    -- +1.5yd slack let a 20yd spell cast at 21.5yd center).
                    if center > band then return false, "oor" end
                    if minR and minR > 0 and center + 0.05 < minR then return false, "oor" end
                end
                -- 2026-08-02 (NO FALLBACKS): a search hit with NO valid measured
                -- distance is NOT a valid cast target (World.find_aura_search
                -- targets now excludes unplaceable units). If one ever reaches
                -- here, fail — never "proceed and let the client refuse" (that
                -- was the edge=999.0 -> Out of range spam).
                if search and not (center and center > 0) then
                    return false, "range_unknown"
                end
            end
        end
        -- FACING + LOS (unit-target only): WotLK HasInArc(M_PI) = 180° front
        -- hemisphere (half-angle π/2). Instant re-eval every tick — no sticky
        -- lockout.
        --
        -- FACING (2026-08-01): NEVER hard-skip here. The facing measurement can
        -- disagree with the client's real facing (the +0x7AC field lags the
        -- visual, and the Lua GetPlayerFacing fallback no-ops to 0.0). Hard-
        -- skipping produced "wait facing:Blood Strike" forever while the user
        -- stood facing the target — the slot never reached the wire path that
        -- TURNS and wires. Facing is now handled in the wire path (turn toward
        -- the GUID, re-measure, wire regardless — the client is the authority).
        -- LOS stays a measurement gate (TraceLine, point-blank exempt): only a
        -- CONFIDENT block refuses the cast pre-wire.
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
                    -- LOS only: confident-block refuses; facing NEVER blocks here.
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
    -- On Ascension, IsUsableSpell may return nil for custom spell IDs — treat
    -- nil as "unknown, assume usable" (fail-open, server is final authority).
    if not opts.skip_usable and IsUsableSpell then
        local usable, nomana = IsUsableSpell(name)
        if usable == nil and sid then usable, nomana = IsUsableSpell(sid) end
        -- nil=unknown → assume usable; only fail on explicit false or nomana
        if usable == false then
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

-- Static meta cache (name / instant / known) — rarely changes mid-session.
local _spell_meta = {}
local function spell_meta(id)
    local m = _spell_meta[id]
    if m then return m end
    local name = spell_name(id)
    local instant = true
    if GetSpellInfo then
        local _, _, _, _, _, _, castTime = GetSpellInfo(id)
        castTime = tonumber(castTime)
        if castTime and castTime > 0 then instant = false end
    end
    local known = true
    if IsSpellKnown then
        local okk, k = pcall(IsSpellKnown, id)
        if okk and k == false then
            known = false
            if GetSpellInfo then
                local okn, sn = pcall(GetSpellInfo, id)
                if okn and sn and sn ~= "" then known = true end
            end
        end
    end
    local minR, maxR = spell_range_info(id)
    m = { name = name, instant = instant, known = known, minR = minR, maxR = maxR }
    _spell_meta[id] = m
    return m
end

-- Authoritative per-spell readiness THIS frame.
-- Optimized: one shared range model, cached meta, light path under GCD.
local function fill_live_spell_state(ctx, spell_ids)
    ctx = ctx or {}
    ctx.cooldowns = ctx.cooldowns or {}
    ctx.spell_usable = ctx.spell_usable or {}
    ctx.spell_in_range = ctx.spell_in_range or {}
    ctx.spell_instant = ctx.spell_instant or {}
    ctx.spell_targeted = ctx.spell_targeted or {}
    ctx.known_spells = ctx.known_spells or {}
    ctx.spell_range_diag = ctx.spell_range_diag or {}
    local t = now()
    local gcd_rem = 0
    local has_target = UnitExists and UnitExists("target")
    local gcd_lock = ctx.gcd_active and true or false
    -- Shared range model once per tick (was N full ObjectPosition fan-outs).
    local edge, aoe, center, pr, tr, precise
    if has_target and not gcd_lock then
        edge, aoe, center, pr, tr, precise = live_range_model(ctx)
    end
    for _, id in ipairs(spell_ids or {}) do
        id = tonumber(id) or 0
        if id > 0 then
            local meta = spell_meta(id)
            local name = meta.name
            -- Cooldown (id first — cheaper; name fallback if needed)
            local rem = 0
            if GetSpellCooldown then
                local s, d = GetSpellCooldown(id)
                if (not d or d == 0) and name then s, d = GetSpellCooldown(name) end
                s, d = tonumber(s) or 0, tonumber(d) or 0
                if d > 0 then
                    rem = (s + d) - t
                    if rem < 0 then rem = 0 end
                    if d <= 1.6 and rem > gcd_rem then gcd_rem = rem end
                end
            end
            ctx.cooldowns[id] = rem
            ctx.cooldowns[tostring(id)] = rem

            -- Runtime ValidateCast DISABLED: calling through bridge 8 spells x
            -- 30 ticks = 240/sec corrupts Lua stack → AV_READ crash. Use safe
            -- Lua-level APIs (IsUsableSpell, IsSpellInRange) which are proven
            -- stable. Cooldowns already handled by GetSpellCooldown above.
            if not gcd_lock then
                local usable = true
                if IsUsableSpell and name and name ~= "" then
                    local u, nomana = IsUsableSpell(name)
                    if u == nil and id then u, nomana = IsUsableSpell(id) end
                    if nomana then usable = false end
                end
                ctx.spell_usable[id] = usable
                ctx.spell_usable[tostring(id)] = usable
                local inRange = true
                if IsSpellInRange and name and name ~= "" then
                    -- Ascension: IsSpellInRange returns 0/nil for custom spells
                    -- even IN range, and 0 whenever the hardware-event flag is
                    -- 0 (flag writes are BANNED — they crash the VM). Treat
                    -- 0/nil as UNKNOWN: inRange stays true (never block). The
                    -- authoritative range check is the precise runtime model
                    -- (live_range_model via ObjectPosition) at the wire path.
                    IsSpellInRange(name, "target")
                end
                ctx.spell_in_range[id] = inRange
                ctx.spell_in_range[tostring(id)] = inRange
            elseif ctx.spell_usable[id] == nil then
                ctx.spell_usable[id] = true
                ctx.spell_usable[tostring(id)] = true
            end

            local targeted = false
            local inr = true
            local self_aoe = is_self_aoe_spell(id, name) or is_ground_self_aoe(id, name)
            if gcd_lock then
                -- Keep last range verdict; only CD matters until GCD free.
                if ctx.spell_in_range[id] == nil then
                    ctx.spell_in_range[id] = true
                    ctx.spell_in_range[tostring(id)] = true
                end
            elseif self_aoe or is_ground_self_aoe(id, name) then
                inr = true
                targeted = false
                ctx.spell_range_diag[id] = { sid = id, name = name, kind = "ground_aoe", verdict = "in_ground_aoe" }
            elseif has_target then
                -- Range + usable handled by ValidateCast above. Range diag only.
                targeted = true
                ctx.spell_range_diag[id] = ctx.spell_range_diag[id] or { sid = id, name = name, kind = "targeted", verdict = "by_validatecast" }
            else
                ctx.spell_range_diag[id] = { sid = id, name = name, kind = "no_target", verdict = "no_target" }
            end
            ctx.spell_in_range[id] = inr
            ctx.spell_in_range[tostring(id)] = inr
            ctx.spell_targeted[id] = targeted
            ctx.spell_targeted[tostring(id)] = targeted
            ctx.spell_instant[id] = meta.instant
            ctx.spell_instant[tostring(id)] = meta.instant
            ctx.known_spells[id] = meta.known
            ctx.known_spells[tostring(id)] = meta.known
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
            -- Ground self-AoE always in range / usable regardless of target.
            local sname = spell_name(sid, slot.name)
            if is_ground_self_aoe(sid, sname) then
                ctx.spell_in_range[sid] = true
                ctx.spell_in_range[tostring(sid)] = true
                ctx.spell_targeted[sid] = false
                ctx.spell_targeted[tostring(sid)] = false
                -- Bar greys with no target on some ranks — never unusable here.
                ctx.spell_usable[sid] = true
                ctx.spell_usable[tostring(sid)] = true
            end
            if policy == "corpse" and W and W.nearest_available_corpse then
                -- 2026-08-02 (NO FALLBACKS): the corpse condition's range is
                -- REQUIRED — an unknown range fails the corpse check rather
                -- than silently searching 30yd.
                local cr = slot_corpse_range(slot)
                if not cr or cr <= 0 then cr = nil end
                local corpse = cr and W.nearest_available_corpse(cr)
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
        local g = UnitGUID("target")
        if g and g ~= "" then return g end
    end
    -- RUNTIME AUTHORITY (2026-08-01): UnitGUID can no-op / return nil from
    -- insecure addon code on this client while UnitExists still works. The
    -- runtime reads the client's real UNIT_FIELD_TARGET (player descriptor
    -- +0x48) — always authoritative. Use it so target_rel casts always have a
    -- real GUID and never fall into the "no_candidate"/empty-try_list trap.
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and pcall(RaijinLab.HasRuntime, RaijinLab) then
        local ok, g = pcall(RaijinLab.RuntimeCall, RaijinLab, "UnitTargetGuid", "player")
        if ok and g and tostring(g) ~= "" and tostring(g) ~= "0x0"
            and tostring(g) ~= "0x0000000000000000" then
            return g
        end
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
    local cstate = cast_state()
    local snap = {
        t = now(),
        casting = (cstate == "casting" or cstate == "channeling"),
        channel = false,
        current = false,
        cd_start = 0,
        cd_dur = 0,
        gcd_start = 0,
        gcd_dur = 0,
    }
    -- Authoritative current-spell detection for `sid` (runtime list walk).
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime() then
        local ok, cur = pcall(RaijinLab.RuntimeCall, RaijinLab, "CurrentSpell")
        if ok and tonumber(cur) == tonumber(sid) then snap.current = true end
    end
    if not snap.current and IsCurrentSpell then
        local ok, cur = pcall(IsCurrentSpell, sid)
        if ok then snap.current = not not cur end
    end
    if GetSpellCooldown then
        local s, d = GetSpellCooldown(sid)
        if (not s or s == 0) and name then s, d = GetSpellCooldown(name) end
        snap.cd_start = tonumber(s) or 0
        snap.cd_dur = tonumber(d) or 0
        -- GCD probe: try gcd token, auto-attack, auto-shot, then the spell itself
        local gs, gd = 0, 0
        local probes = { 61304, 6603, 75, sid }
        for _, pid in ipairs(probes) do
            if pid and pid > 0 and gd <= 0 then
                local ps, pd = GetSpellCooldown(pid)
                ps, pd = tonumber(ps) or 0, tonumber(pd) or 0
                if pd > 0.75 and pd <= 1.6 then
                    gs, gd = ps, pd
                    break
                end
            end
        end
        snap.gcd_start = gs
        snap.gcd_dur = gd
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
    -- 2026-08-02 (BLOCKED-DIALOG FIX): PetAttack() and CastPetAction() are
    -- PROTECTED FrameScript APIs in 3.3.5 — calling them from addon Lua pops
    -- "RaijinLab has been blocked from an action only available to the Blizzard
    -- UI" (taint; the screenshot at 15:23). The runtime has no native pet-cmd
    -- primitive yet, so fail-open: return false and let the Engine cycle to the
    -- next slot. NEVER touch a protected pet API from Lua.
    return false, "no_native_pet"
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

    -- Auto Attack: engage once if needed; never CastSpell spam / never GCD.
    if is_auto_attack(sid, name) then
        -- HARD RULE (Prompt.md): NEVER manually acquire a target here. When
        -- acquire is off the rotation must not change/acquire selection at all.
        -- Auto-targeting is permitted ONLY when a hostile/neutral unit is
        -- attacking the player (targeting/casting/damaging us — heals/buffs
        -- excluded) — and even then we let the GAME's natural targeting select
        -- it; we never TargetUnit. Act.Attack is a no-op without a selected
        -- target (runtime reads the client's selection), so it cannot acquire.
        if not (UnitExists and UnitExists("target")) then
            if Act.Attack then pcall(Act.Attack) end
            -- Re-check after the (no-op) engage attempt.
            if not (UnitExists and UnitExists("target")) then
                local WW = RaijinLab and RaijinLab.World
                local threat = WW and WW.hostile_or_neutral_attacking_me
                    and WW.hostile_or_neutral_attacking_me()
                if threat then
                    -- A hostile/neutral is attacking us: the game's natural
                    -- targeting may select it (or the player clicks it). We
                    -- wait without touching selection.
                    return false, "no_target_await_attacker"
                end
                return false, "no_target"
            end
        end
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") then return false, "target_dead" end
        if UnitCanAttack and not UnitCanAttack("player", "target") then return false, "not_enemy" end
        -- AUTHORITATIVE already-attacking check (RE-verified): the runtime walks
        -- the client's real current-spells list ([0xAF5254]) for 6603. The Lua
        -- IsCurrentSpell(6603) NO-OPS from insecure code (hardware-event gate) —
        -- that is why the old code re-engaged Attack every 0.35s and the client
        -- replied with "blocked action"/busy errors. AttackTarget in the runtime
        -- is also idempotent (never re-casts while the list says attacking).
        local already = false
        if RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime() then
            -- Authoritative: "1|0xGUID" = the GUID the player is attacking.
            -- Only skip when it matches the CURRENT target (attacking a
            -- leftover target must fall through so AttackTarget can re-aim).
            local okc, cur = pcall(RaijinLab.RuntimeCall, RaijinLab, "IsAttacking")
            if okc and type(cur) == "string" then
                local flag, atk = cur:match("^([01])|0x([0-9a-fA-F]+)$")
                if flag == "1" and atk then
                    local tgt = (UnitGUID and UnitGUID("target")) or ""
                    if tgt ~= "" and atk:lower() == tgt:lower() then
                        already = true
                    end
                end
            end
        end
        if not already and IsCurrentSpell then
            local okc, cur = pcall(IsCurrentSpell, 6603)
            if okc and cur then already = true end
        end
        -- 2026-08-03 (AUTO-ATTACK STUCK-CAST FIX — user: "auto attack casts
        -- are not working"): the old `_aa_target` memo was a PERMANENT latch.
        -- After the first Act.Attack for a target it returned
        -- "already_attacking" forever — even at melee range while NOT
        -- attacking (live: fired once at edge=33.9yd, then "wait
        -- already_attacking x312" at edge=0-5yd — the player closed to melee
        -- and auto attack NEVER re-engaged). The runtime IsAttacking check
        -- above IS the authoritative "already attacking" signal; whenever it
        -- is false the engage MUST be retried. The latch is removed; the
        -- 0.35s _recent floor below is the only throttle.
        if already then return false, "already_attacking" end
        -- 2026-08-03 (MELEE-RANGE GATE): the runtime AttackTargetFor refuses
        -- engages beyond ~6yd center (it is a staged no-op while far), so
        -- gating here at the SAME threshold makes the slot wait cleanly
        -- instead of staging a pointless engage + FIRE log every 0.35s while
        -- the player closes. Measured center from the live context; an
        -- unknown/undetermined center is left to the runtime authority (the
        -- engage attempt falls through — never a false pre-block).
        local _aa_center = ctx and tonumber(ctx.target_distance_center)
        if _aa_center and _aa_center > 0 and _aa_center < 900 and _aa_center > 6.0 then
            return false, "oor"
        end
        if Act.Attack then
            pcall(Act.Attack)
            Executor._last_cast = { sid = 6603, name = "Auto Attack", via = "Attack", t = now(), evidence = "attack" }
            -- Short re-engage floor only (not 0.75 — felt like rotation delay).
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = now() + 0.35
            Executor._recent[6603] = now() + 0.35
            dlog("cast", "auto-attack")
            return true, "ok:attack", cast_snapshot(sid)
        end
        return false, "no_attack_api"
    end

    -- Fail-closed preflight. Target/range policy comes ONLY from conditions
    -- (Target Existence any|no_target, Corpse Nearby) - never from IsSpellInRange nil.
    local policy = action.target_policy or slot_policy(action.slot)
    local needs_enemy = (policy == "require")
    -- 2026-08-02 (NO FALLBACKS): an unknown corpse range = nil (the corpse
    -- check fails open to the next slot — never a silent 30yd search).
    local corpse_range = (policy == "corpse") and slot_corpse_range(action.slot) or nil
    local guid = nil
    local corpse_guid_for_mark = nil
    local probe_marked = false

    -- Multi-dot: cast is ALWAYS Spell_C_CastSpell(id, guid).
    -- Acquire OFF (default): NEVER TargetUnit / never leave selection on victim.
    -- Acquire ON: may Target the match; Reset after restores previous.
    local search = action.aura_search_hit or (ctx and ctx.aura_search_hit)
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
    --
    -- 2026-08-02 (HARD acquire-OFF rule — the "aura_search force-acquires"
    -- fix): when acquire is OFF and we ALREADY have a current target, the
    -- aura-search unit is IGNORED — casting at it via Spell_C(guid) is exactly
    -- what makes the client visibly target it (force-acquire), and blocking it
    -- with no_acquire is what froze the rotation into a Consecration-only loop
    -- (live 16:34: search returned a unit != current target -> every aura slot
    -- blocked, melee blocked on facing, only Consecration fired). Instead we
    -- cast at the CURRENT TARGET via the native guid=0 path: it never changes
    -- selection and never force-acquires, and the rotation actually does its
    -- job on the unit you are attacking. The search unit is only reachable
    -- when there is NO current target ("cast without targeting" — the runtime
    -- selection-restore reverts the async pick).
    local has_ctarget = UnitExists and UnitExists("target")
    -- 2026-08-01 (HARD acquire-OFF rule, verified constraint): with acquire OFF
    -- we MUST cast at the CURRENT target (guid=0 native path) when one exists.
    -- There is NO way to cast at a different aura-search unit without acquiring
    -- it — UNIT_FIELD_TARGET (desc+0x48) IS the client's selection field, so the
    -- descriptor-pin + Spell_C(0) path selectes that unit (CastSpellNoAcquire
    -- force-acquired live). Per the rule "the mob I am physically targeting, if
    -- I am targeting anything, is my target," the rotation casts at the current
    -- target. The candidate/try_list logic (below) clears search guidance when
    -- acquire-off + current target, so the wire takes the guid=0 path. Search
    -- targets are cast only with NO current target ("cast without targeting").
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

    -- 2026-08-02 (NO AUTO-FACE, user directive): the rotation NEVER turns the
    -- character. Engine.slot_wants_auto_face always returns false (the "Auto
    -- Face" condition is inert); no auto-face flag is ever set. Facing is
    -- detection-only — a cast wires only when the player ALREADY faces the
    -- target (runtime ObjectIsFacing confirmed), otherwise the slot is skipped.

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
        -- 2026-08-02 (NO AUTO-FACE, user directive): facing is detection-only
        -- and UNIVERSAL. The wire path enforces confirmed facing for EVERY
        -- unit-targeted cast (melee AND ranged). Never skip facing for
        -- unit-targeted spells — the client refuses "facing the wrong way"
        -- even on ranged here. Only ground/self/optional spells skip (they
        -- have no unit target to face).
        local can, why = live_castable(sid, name, {
            policy = policy, needs_enemy = needs_enemy,
            skip_range = skip_r,
            skip_facing = skip_face,
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

    -- DIAG (2026-08-01): state at cast attempt — which policy, is there a
    -- search/guid, is a client target present. One line per wire-bound attempt.
    -- 2026-08-02 (LOG-THROTTLE, NOT DECISION-THROTTLE — user directive): the
    -- old 0.25s _next_gap pause on "facing" blocked the LITERAL-INSTANT cast the
    -- user demands ("as im turning the literal instant its possible to cast it
    -- should cast literally instantly"). The DECISION must re-check every tick
    -- (the native facing read is cheap and hook-cached); only this LOG line is
    -- throttled (~3Hz) so the log doesn't flood at 50Hz. Facing is detected
    -- natively now, so re-checking is near-free.
    do
        local tnow3 = now()
        local lk = Executor._attempt_log_key
        if not lk or lk.name ~= name or lk.sid ~= cast_sid or (tnow3 - (lk.t or 0)) > 0.33 then
            dlog("cast", "attempt %s sid=%d pol=%s needs_enemy=%s search=%s guid=%s tgt=%s",
                tostring(name), cast_sid, tostring(policy),
                needs_enemy and "y" or "n",
                (search and "y" or "n"),
                tostring(guid or "nil"),
                (UnitExists and UnitExists("target") and "y" or "n"))
            Executor._attempt_log_key = { name = name, sid = cast_sid, t = tnow3 }
        end
    end

    -- Final ready gate (latency-aware). Never spam Spell_C when not ready.
    do
        local rem = spell_ready_remaining(cast_sid, action._cast_name or name)
        local pad = math.max(0.03, latency_sec() * 0.6)
        if rem > pad then
            return false, "cooldown:" .. tostring(name)
        end
    end

    -- Multi-dot: GUID is mandatory when search found a unit.
    -- Never fall back to current-target cast (melee hits wrong unit).
    -- 2026-08-02 (HARD acquire-OFF rule, CORRECTED per user): for AURA_SEARCH
    -- slots, cast at the SEARCHED mob even when acquire is OFF and there IS a
    -- current target. Per the user's rule, "multi-dot/aura_search should CAST
    -- to a different mob Y when acquire is off" — it must NOT fall back to the
    -- current target X. Only NON-search (plain target_rel) slots fall back to
    -- the current target (guid=nil -> guid=0 current-target cast).
    local _slot_is_aura_search = search
        and (search.guid or (search.candidates and #search.candidates > 0))
    if search and search.guid then
        guid = search.guid
    end
    -- Acquire-off + current target is FINE with guid=nil only for NON-search
    -- slots (cast at current target via guid=0 path). An aura_search slot with
    -- a search guid is always mandatory — never nil it.
    if search and not guid and not (_slot_is_aura_search) then
        return false, "no_search_guid:" .. tostring(name)
    end
    -- Current-target cast (2026-08-01): a target_rel slot with a client target
    -- but no resolvable GUID (UnitGUID no-op from insecure code) must cast at
    -- the CURRENT TARGET via the guid=0 path — never return "no_target" while
    -- a valid target is selected. Only truly no-target returns no_target.
    if needs_enemy and not guid and not is_ground_self_aoe(sid, name)
        and not (UnitExists and UnitExists("target")) then
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
    -- 2026-08-02 (MULTI-DOT FACING FIX): aura_search slots are NEVER
    -- facing-gated. The search target can be anywhere around the player (dots
    -- spread to adds behind / beside), and a custom-spell facing false-positive
    -- froze the whole rotation at "wait facing:Icy Touch x36" while the player
    -- faced the target (Icy Touch is a 30yd ranged spell — it needs no front
    -- cone at all). Only plain target_rel slots consult the front cone.
    -- 2026-08-02 (UNIVERSAL FACING — user directive): facing applies to EVERY
    -- unit-targeted cast, melee AND ranged AND aura_search. The client refuses
    -- "You are facing the wrong way!" / "in front of you" even on ranged casts
    -- here. Only ground/self/optional/forbid/corpse spells skip (they have no
    -- unit target to face).
    local skip_face_cast = is_ground_self_aoe(sid, name) or is_self_aoe_spell(sid, name)
        or policy == "optional" or policy == "forbid" or policy == "corpse"

    -- Multi-candidate same-tick try (aura_search top-N). Face-fail → next GUID.
    -- Order is runtime authority: closest first, FOV-centre on distance ties.
    local try_list = {}
    -- 2026-08-02 (HARD acquire-OFF rule, CORRECTED per user): with acquire OFF
    -- and a CURRENT target, only NON-search target slots fall back to the
    -- current target (guid=0). AURA_SEARCH slots must STILL cast at the
    -- searched candidates (mob Y) — per the user rule "multi-dot/aura_search
    -- should CAST to a different mob Y when acquire is off." So _is_aura_search
    -- slots keep their try_list/guid (they cast at Y, not the current target).
    --
    -- 2026-08-02 (USER-CORRECTED, ZERO-FRAME ACQUIRE): with acquire OFF, casting
    -- at a searched mob MUST NOT touch the client's selected target / unitframe
    -- at all — it just casts directly at the mob aura_search decides. This
    -- holds EVEN with NO current target: we do NOT refuse (unlike a prior draft).
    -- The zero touch is achieved at the runtime by the CAST_NO_ACQUIRE path:
    -- pin UNIT_FIELD_TARGET descriptor -> Spell_C(spellId, 0) -> restore, never
    -- writing the 0xBD07B0 selection global the unitframe reads. No refusal.
    local _acquire_off_has_ct = (not want_acquire)
        and (UnitExists and UnitExists("target")) and (UnitGUID and UnitGUID("target"))
        and not _slot_is_aura_search
    if _acquire_off_has_ct then
        try_list = {}
        guid = nil
        search = nil
        if ctx then ctx.aura_search_hit = nil end
    elseif search and search.candidates and #search.candidates > 0 then
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
    -- Current-target cast (2026-08-01): needs_enemy slots WITHOUT a resolvable
    -- GUID (UnitGUID no-ops from insecure code) still cast at the CURRENT
    -- TARGET via the guid=0 path — Spell_C(0) resolves against client
    -- selection. This was the "literally nothing casts" bug: every target_rel
    -- slot (PS/IT/BS) returned no_candidate with try_list empty.
    local self_cast_ok = ground_self
        or policy == "optional" or policy == "forbid"
        or (not needs_enemy and not search)
        or (needs_enemy and not search and (UnitExists and UnitExists("target")))

    -- Ground feet AoE: NEVER walk try_list / GUID cast. Always CastSpell(id).
    if ground_self then
        try_list = {}
        guid = nil
    end

    -- Multi-dot GUID wire: Spell_C only. Runtime pins UNIT_FIELD_TARGET and
    -- restores descriptor — no TargetUnit from Lua after wire (crash surface).
    local ok, wire_guid = false, nil
    -- CRITICAL (2026-08-01): last_why MUST start as nil, not "no_candidate".
    -- The wire is guarded by `if not last_why then` — a non-nil initial string
    -- made that guard ALWAYS false, so the wire NEVER executed and every slot
    -- fell through as "no_candidate" (the "literally nothing casts" bug). nil
    -- means "no blocker yet — proceed to wire"; it is only set to a real reason
    -- inside the loop when a candidate is rejected (bad_guid/blacklist) or the
    -- cast runs and fails.
    local last_why = nil
    local NOTGT = (Act.CAST_NO_TARGET_CHANGE or 2)
    local NOACQ = (Act.CAST_NO_ACQUIRE or 16)
    -- Restored to working baseline flags:
    --   NOTGT when acquire-off (multi-dot must not sticky-select)
    --   NEVER FACE / SKIP / LOS — the runtime must not turn (NO AUTO-FACE) and
    --   must not refuse on its own facing guess; the Lua wire path is the
    --   single facing authority (confirmed runtime ObjectIsFacing) and the
    --   client is the final judge. Do NOT force CHECK_LOS — TraceLine false-
    --   positives killed every unit cast while Consecration still fired.
    --
    -- 2026-08-01 (CRASH FIX, definitive): CAST_NO_ACQUIRE is REMOVED from the
    -- execution path. That flag invoked CastSpellNoAcquire, which WRITES
    -- UNIT_FIELD_TARGET (the client selection field) synchronously under the
    -- Lua bridge — this races the game's cast-resolve and corrupts the Lua VM
    -- (0x512B07, proven 19:33) and force-acquires. The rotation now casts via
    -- the plain CastSpell(guid) path (deferred restore reverts the visible and
    -- pick) and, with a current target, casts at it via guid=0 (never touches
    -- another unit). Flags are NOTGT (acquire-off) only.
    -- 2026-08-02 (PROVEN UNSAFE, reverted): the descriptor-pin CAST_NO_ACQUIRE
    -- path CRASHES 0x512B07 under the bridge (proven twice) AND still force-
    -- acquires. So acquire-off guid casts do NOT set NOACQ — they use the plain
    -- CastSpell(guid) path whose deferred selection restore reverts the victim
    -- after the cast (best available without the native-hook zero-touch cast).
    -- guid=nil (current-target cast) stays the plain path.
    local function unit_cast_flags()
        local f = 0
        if not want_acquire then f = f + NOTGT end
        -- 2026-08-02 (NO AUTO-FACE, user directive): NEVER set the FACE flag.
        -- That instructed the runtime to turn the character toward the target.
        -- The rotation must never move/turn the player — facing is detection
        -- only. A cast wires only when the player ALREADY faces the target.
        return f
    end
    -- FACING ONLY APPLIES TO MELEE-RANGE SPELLS (2026-08-02). Ranged spells
    -- (Icy Touch 30yd, etc.) NEVER require facing in WoW — the client only
    -- refuses "target is not in front of you" for melee. Blocking a 30yd spell
    -- on the facing gate froze the whole rotation ("wait facing:Icy Touch
    -- x122" while the player faced the target and Icy Touch needed no facing).
    -- AUTHORITATIVE (runtime): SpellMeleeInfo decodes the client's Spell.dbc
    -- record + range entry (used for the runtime range authority below).
    local melee_rt = runtime_spell_melee(cast_sid)
    local _, maxR_spell = spell_range_info(cast_sid)
    for ci = 1, #try_list do
        local cand = try_list[ci]
        local cg = cand.guid
        -- 2026-08-03 (MULTI-CANDIDATE FIX — the "stuck on one target it can't
        -- cast on" bug the user diagnosed): last_why was NEVER reset between
        -- candidates, so when candidate #1 was rejected (oor / los / a refused
        -- cast), every later candidate's `if not last_why` guard was false and
        -- they were NEVER evaluated or wired — the rotation stayed stuck on the
        -- one uncastable target instead of falling through to a castable one
        -- (live: aura search "massively inconsistent — sometimes casts fine,
        -- sometimes not on a target right in front of me"). Reset per-candidate
        -- so each is evaluated independently and the first WIREABLE one wins.
        last_why = nil
        if not cg or cg == 0 or tostring(cg) == "0x0" or tostring(cg) == "0x0000000000000000" then
            last_why = "bad_guid"
        elseif Executor.guid_blacklisted(cg) then
            last_why = "blacklisted"
        else
            -- 2026-08-02 (HARD acquire-OFF, corrected): casting at a different
            -- mob is NOT switching targets. The native CAST_NO_ACQUIRE path
            -- pins the player descriptor UNIT_FIELD_TARGET to the aura-search
            -- guid and calls Spell_C(0) — cast-at-current-target via the
            -- descriptor, which does NOT trigger the async client-selection
            -- pick. So the client selection never moves, even for a frame, even
            -- when the cast target differs from my current physical target.
            -- This removes the old "no_acquire" refusal that blocked casting on
            -- new targets mid-fight ("fails to cast while fighting"). My
            -- physical target (if any) is never changed by a cast.
            -- FACING GATE (2026-08-01 + 2026-08-02, FINAL):
            --
            -- HARD RULE (Prompt.md): the rotation NEVER turns the character.
            -- No movement behaviour of any kind comes from the rotation — the
            -- player steers. Turning happens ONLY when the user explicitly adds
            -- the "Auto Face" condition to a slot (want_auto_face), which is an
            -- opt-in, never a default.
            --
            -- Without Auto Face: when a candidate is NOT facing us, we must
            -- NEVER wire it (that produced the client "target is not in front
            -- of you" refusal + red UI_ERROR spam) and NEVER turn. We set
            -- last_why="facing" so the try-list moves to the next candidate
            -- (multi-dot has up to 8, closest-first); if none is facing, the
            -- slot is skipped this tick with no wire at all — a clean backoff,
            -- zero UI errors, and the player turns when they want to engage.
            --
            -- Safe against the old "wait facing:X forever" failure: the runtime
            -- reads the LIVE facing field (0x7AC), not the stale 0x7A4, so a
            -- "not facing" verdict is real — the player genuinely is not in the
            -- front cone, and not casting IS correct.
            -- 2026-08-02: melee_req gates this — ranged spells never need facing
            -- (a 30yd Icy Touch frozen on "facing" for 122 ticks froze the whole
            -- rotation). Only melee-range casts consult the front cone.
            -- 2026-08-02 (STRICT): only wire melee when the runtime CONFIRMS
            -- we face the target (facing == true). Both confident-not-facing
            -- AND undetermined (target not yet in the snapshot) skip — never
            -- wire melee into a guaranteed client "target is not in front of
            -- you" refusal. An undetermined skip is a 1-frame wait (snapshot
            -- refreshes next tick), not a freeze. This is "more aware and in
            -- control" — we do not spend the player's GCD on a refusal.
            --
            -- 2026-08-02 (FACING-FREEZE FIX, FINAL): a target in MELEE RANGE
            -- (edge <= ~2yd) is by definition front-facing — the client
            -- auto-faces melee and a melee-swinging/standing player cannot be
            -- "not in front of" a mob they are standing on. The runtime facing
            -- read (0x7AC heading->target) intermittently reports a false
            -- "not facing" even at edge=0yd (proven three sessions: "wait
            -- facing:Blood Strike xN" / "wait facing:Icy Touch xN" froze the
            -- rotation on a single target being fought). So melee-range targets
            -- NEVER face-block. Mid-auto-attack is the same exemption. Only a
            -- target OUTSIDE melee range with a confident not-facing verdict
            -- blocks (and even then, only when not attacking).
            -- HARD RULE (Prompt.md, 2026-08-02 FINAL): the rotation NEVER turns
            -- the character. NO FaceTowardGuid / face_guid / StopMoving /
            -- TurnByDelta from the rotation, EVER — for ANY spell, melee OR
            -- ranged. The player steers; the rotation only detects.
            --
            -- UNIVERSAL FACING GATE (2026-08-02, user directive): facing
            -- detection must be PERFECT for EVERY unit-targeted cast — melee
            -- AND ranged. This Ascension client refuses "You are facing the
            -- wrong way!" / "Target needs to be in front of you" on ranged
            -- spells too (the user's screenshot proves it: those exact errors
            -- appeared during Icy Touch casts). So there is NO melee-only
            -- exemption and NO "melee-range = auto-facing" exemption.
            --
            -- 2026-08-02 (RUNTIME AUTHORITY + FAIL-OPEN, user directive):
            --   * facing == true   → wire NOW (instant — the native read is
            --     hook-cached, so the literal frame the player's facing is
            --     sufficient, the cast fires; NO 0.25s pause).
            --   * facing ~= true   → do NOT wire this candidate. "Fail-open"
            --     (user-corrected 2026-08-02): if nothing else is castable,
            --     CONTINUE TO CYCLE THROUGH THE ROTATION SLOTS — never force-
            --     cast a blocked ability. The Engine already falls through to
            --     the next priority slot when attempt_action returns false, so
            --     setting last_why="facing" is the correct fail-open: slot 1
            --     blocked → slot 2 → ... → next tick re-checks the FULL list.
            --     The old "wait facing:X x161" freeze was the BROKEN native
            --     facing read (LocalPtr+0x7AC = 0 → confident false on every
            --     cast), now fixed at the source (camera→ObjectPtr→+0x7AC,
            --     hook-cached). With a correct read, a not-facing verdict is a
            --     genuine 1-tick skip, and the moment the player's facing is
            --     sufficient the native cache flips and this slot wires.
            if not last_why and not skip_face_cast and needs_enemy then
                -- 2026-08-03 (ROUND 40 — facing is DETECTION-ONLY; the CLIENT is
                -- the sole determinate authority; the rotation NEVER locks on a
                -- facing guess). The developer-facing read on this Ascension
                -- build is unreliable ([obj+0x7AC] intermittently returns 0.0),
                -- so it misreport an engaged player as "not facing" and hard-
                -- blocked every cast with 'wait facing:X x80+' (00:11: Blood
                -- Strike + RANGED Icy Touch at edge=0yd). Full deterministic
                -- behavior: WIRE and let the client decide — al=1 accepted or
                -- al=0 refused ('not in front', recovered as one phantom),
                -- never a multi-second hold. The client NEVER refuses a cast it
                -- can accept based on a measurement we can't trust; a false
                -- pre-block was the source of every lockup. Facing is still
                -- used for candidate ORDERING (closest + facing-first in
                -- AuraSearchPacked) but never holds the wire.
                --
                -- (Removed: the earlier point-blank exemption and the
                -- 'if facing == false then last_why="facing" end' block — both
                -- were band-aids on the unreliable read; the fixed behavior is
                -- to not gate on it at all and let the client be the referee.)
            end
            -- WIRE (range was already validated in live_castable; facing gate above)
            -- 2026-08-02 (MULTI-CANDIDATE RANGE FIX): live_castable range-checks
            -- ONLY the HEAD candidate (ctx.aura_search_hit.dist). But the try_list
            -- iterates ALL candidates — when the head is blocked (facing/oor),
            -- candidate #2/#3 are wired WITHOUT their own distance gate, so a far
            -- add got cast and the client refused "You are too far away!" (live:
            -- FIRE edge=999.0 then refused range:too far, 23:08:25). The runtime
            -- AuraSearch filters to the aura_search condition's range (~40yd), but
            -- the SPELL's own range (Icy Touch 30yd) must gate each candidate.
            -- Use each candidate's measured dist when present; skip (next
            -- candidate) when confidently out of the spell's max range.
            -- 2026-08-02 (RUNTIME RANGE AUTHORITY): GetSpellInfo returns 0 range
            -- for custom Ascension spell IDs, so spell_range_info() was blind
            -- (maxR=0 → the gate never fired → "too far away"). The runtime's
            -- SpellMeleeInfo decodes the real Spell.dbc range entry (max=%.2f).
            -- Prefer it; fall back to GetSpellInfo; only fail-closed when BOTH
            -- are unavailable (then the client is the final authority).
            if not last_why and search and cand and not is_ground_self_aoe(sid, name)
                and not (policy == "optional" or policy == "forbid") then
                local cdist = tonumber(cand.dist or cand.dist_center or cand.dist_aoe)
                local _, cmaxR = spell_range_info(cast_sid)
                local rt_melee, rt_maxR = runtime_spell_melee(cast_sid)
                if rt_maxR and rt_maxR > 0 then cmaxR = rt_maxR end
                if cdist and cdist > 0 and cdist < 900 and cmaxR and cmaxR > 0 then
                    -- 2026-08-02 (14:09 RANGE GATE FIX — the client measures
                    -- CENTER, not edge): the OLD gate subtracted combat reaches
                    -- (cedge = cdist - pr - tr) and compared THAT to maxR+0.5.
                    -- The client refuses on CENTER distance (live: a 5yd melee
                    -- at edge=2.5 / center=5.5 got "Out of range"; edge=2.0 /
                    -- center=5.0 too). The old gate allowed center up to
                    -- maxR+0.5+pr+tr ≈ 8.5yd for a 5yd spell — every far add
                    -- passed the gate and the client refused "too far away".
                    -- Compare the CENTER distance directly against the spell's
                    -- real max range — NO tolerance (2026-08-02, user
                    -- directive: perfect range). The old ranged +1.5yd slack
                    -- let a 20yd spell wire at 21.5yd center -> client "Out
                    -- of range" refusal. A spell never casts beyond maxR.
                    if cdist > cmaxR then
                        last_why = "oor"
                    end
                end
            end
            -- 2026-08-02 (PER-CANDIDATE LOS): live_castable/Engine check LoS on
            -- the HEAD candidate only; the try_list loop wires candidates #2+ with
            -- NO LoS gate → client "target out of line of sight" refusal (the
            -- user still sees it). Gate EVERY candidate with a confident block;
            -- undetermined (nil) allows (client is final authority, and a stale
            -- TraceLine must not freeze multi-dot). Point-blank (<8yd) is already
            -- exempt inside World.is_los_guid.
            if not last_why and search and cand and cand.guid and not is_ground_self_aoe(sid, name)
                and not (policy == "optional" or policy == "forbid") then
                if W and W.is_los_guid and W.is_los_guid(cand.guid) == false then
                    last_why = "los"
                end
            end
            if not last_why then
                local reason, cdMs = nil, 0
                dlog("cast", "wire %s sid=%d cg=%s flags=%d try=%d",
                    tostring(name), cast_sid, tostring(cg), unit_cast_flags(), #try_list)
                if Act.CastQueued then
                    ok, reason = Act.CastQueued(cast_sid, cg, unit_cast_flags())
                    cdMs = 0
                elseif Act.CastSpellEx then
                    ok, reason, cdMs = Act.CastSpellEx(cast_sid, cg, unit_cast_flags())
                else
                    ok = Act.CastSpell(cast_sid, cg)
                    reason = ok and "ok" or "cast_fail"
                end
                dlog("cast", "wire-result %s ok=%s reason=%s cd=%s",
                    tostring(name), tostring(ok), tostring(reason), tostring(cdMs))
                if ok == true or ok == 1 then
                    ok = true
                    wire_guid = cg
                    guid = cg
                    if search then
                        search.guid = cg
                        search.token = cand.token
                        if ctx then ctx.aura_search_hit = search end
                    end
                    -- RESET AFTER (2026-08-01): "Acquire target" swapped selection
                    -- to the victim before the cast. With "Reset after" ON, restore
                    -- the EXACT previous target immediately after the cast lands —
                    -- never leave the rotation's selection on the victim. Native
                    -- descriptor write only (A.Target -> runtime TargetGuid = pure
                    -- UNIT_FIELD_TARGET write, no Lua pcall after wire).
                    if want_reset_after then
                        if pre_target_guid then
                            if Act and Act.Target then pcall(Act.Target, pre_target_guid) end
                        elseif Act and Act.ClearTarget then
                            pcall(Act.ClearTarget)
                        end
                        if W and W.sync_ctx_target and ctx then pcall(W.sync_ctx_target, ctx) end
                    elseif not want_acquire then
                        -- 2026-08-02 (HARD RULE — acquire OFF never changes target):
                        -- Spell_C(guid) SELECTS the cast victim as the client target,
                        -- and that selection lands ASYNCHRONOUSLY (next frame) — so
                        -- the runtime's immediate descriptor restore sees the old
                        -- selection (prev==nowSel) and skips, leaving the victim
                        -- targeted. Record the pre-cast selection here and restore
                        -- it on the NEXT tick if the client target moved to the
                        -- victim. This is the "aura_search force-targets even with
                        -- acquire disabled" bug.
                        Executor._restore_selection = {
                            had = pre_had_target,
                            guid = pre_target_guid,
                            victim = cg,
                            until_t = now() + 0.6,
                        }
                    end
                    break
                end
                ok = false
                last_why = reason or "cast_fail"
                if tostring(last_why):find("^cooldown") then
                    cdMs = tonumber(cdMs) or 0
                    if cdMs > 0 then
                        Executor._gcd_until = now() + (cdMs / 1000)
                        Executor._gcd_src = "cd_precast"
                    end
                    break
                elseif tostring(last_why) == "facing" or tostring(last_why) == "los"
                    or tostring(last_why) == "oor" then
                elseif tostring(last_why) == "not_ready" then
                    break
                end
            end
        end
    end

    -- No unit candidates: self/ground cast path (Consecration etc.).
    if not ok and #try_list == 0 and self_cast_ok then
        -- 2026-08-02 (melee current-target path): an acquire-OFF aura-search
        -- slot with a current target is routed HERE as a guid=0 native cast.
        -- It must respect the SAME universal facing gate as the GUID wire
        -- (user directive 2026-08-02): NO auto-facing, PERFECT facing detection
        -- for EVERY unit-targeted cast, melee OR ranged. Wires only when the
        -- runtime CONFIRMS the player faces the target.
        local cok, creason
        if needs_enemy then
            -- 2026-08-02 (TARGET-REL GUID CAST — 15:22 CHOKING FIX): the OLD
            -- path cast CastQueued(cast_sid, nil, 0) = Spell_C at the CURRENT
            -- CLIENT TARGET (guid=0). With acquire-off the runtime restores the
            -- client target to 0 after every aura-search cast (SelectionRestore
            -- -> 0x0), so guid=0 unit casts had NO target -> silently refused ->
            -- "phantom_grace" on EVERY Plague Strike/Blood Strike -> the slot
            -- choked and the rotation stalled for seconds (live 15:22:45-49
            -- "wait cooldown x82"). Resolve a REAL GUID (the live current
            -- target, else the rotation's own aura-search hit) and cast it as a
            -- GUID cast with the SAME acquire-off flags (NOTGT) as aura-search
            -- slots: register + Spell_C(GUID) + deferred restore. NEVER guid=0
            -- for a unit-targeted spell. This puts EVERY unit cast on ONE
            -- consistent target (the rotation's victim), never the flickering
            -- client selection.
            local cg2 = nil
            if UnitGUID and UnitExists and UnitExists("target") then
                local t2 = UnitGUID("target")
                if t2 and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
                    cg2 = t2
                end
            end
            if not cg2 and ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid then
                cg2 = ctx.aura_search_hit.guid
            end
            -- UNIVERSAL FACING (18:11 FIX — NO EXEMPTION): every unit-targeted
            -- cast face-gates on a confirmed-true verdict, melee AND ranged,
            -- ALL distances (the old melee point-blank exemption let non-faced
            -- melee casts wire -> "target needs to be in front of you" errors).
            -- Plus a LoS gate: the target-relative path had NONE -> "target out
            -- of line of sight" spam. Fail-open: a blocked target skips to the
            -- next slot / next tick.
            if not cg2 then
                last_why = "no_target"
            else
                local _c_los = true
                if W and W.is_los_guid and not is_ground_self_aoe(sid, name) then
                    if W.is_los_guid(cg2) == false then
                        _c_los = false
                    end
                end
                -- 2026-08-03 (ROUND 40 — facing is DETECTION-ONLY, never a hard
                -- block; the CLIENT is the sole determinate authority). The
                -- developer-facing read on this Ascension build is unreliable:
                -- [obj+0x7AC] intermittently returns 0.0, so an engaged player
                -- staring at a mob was misreported as "not facing" and the
                -- rotation hard-blocked the cast with 'wait facing:X x80+"
                -- (00:11 session: Blood Strike at edge=0yd, and even RANGED
                -- Icy Touch at edge=0yd). User directive (repeated): facing is
                -- detection-only, NO single ability may lock up the rotation,
                -- and nothing may be a guess. The fully deterministic answer is
                -- to WIRE the cast and let the client be the referee: it
                -- returns al=1 (accepted) or al=0 (refused 'not in front',
                -- recovered as one phantom, logged) — a determinate outcome
                -- either way, NEVER a multi-second stall. We keep only the LoS
                -- confident-block (a real, reliable measurement the user has
                -- always accepted). Facing is surfaced for tuning but never
                -- holds the wire.
                if not _c_los then
                    last_why = "los"
                else
                    if Act.CastQueued then
                        cok, creason = Act.CastQueued(cast_sid, cg2, NOTGT)
                    elseif Act.CastSpellEx then
                        cok, creason = Act.CastSpellEx(cast_sid, cg2, NOTGT)
                    else
                        cok = Act.CastSpell(cast_sid, cg2)
                    end
                    if cok then ok = true; last_why = "ok"
                    else last_why = creason or "cast_failed" end
                end
            end
        else
            if Act.CastQueued then
                cok, creason = Act.CastQueued(cast_sid, nil, 0)
            elseif Act.CastSpellEx then
                cok, creason = Act.CastSpellEx(cast_sid, nil, 0)
            else
                cok = Act.CastSpell(cast_sid)
            end
            if cok then ok = true; last_why = "ok"
            else last_why = creason or "cast_failed" end
        end
    end

    if not ok then
        if Ou and oid then Ou.settle(oid, -1.0, last_why or "cast_failed") end
        -- Free list on failure so next tick re-evaluates clean.
        -- Never invent _recent floors for pre-wire gate skips (facing/range/ready
        -- gates that skipped the cast entirely — condition may clear next frame).
        -- Only wired-and-refused failures get _recent from the event handler.
        Executor._gcd_until = 0
        Executor._gcd_provisional = false
        Executor._next_gap = 0
        Executor._pending = nil
        Executor._idle_until = nil
        clear_sid_soft_locks(sid)
        -- Retick only when a wire was actually attempted and the server refused
        -- (cast_fail / cooldown from CastSpellEx). Pre-wire gate skips (facing/
        -- oor from live_castable or our facing gate) don't need retick — the
        -- next OnUpdate will re-evaluate naturally.
        local lw = tostring(last_why or "")
        -- 2026-08-02 (NO-PAUSE FACING — user directive): a facing/oor/los block
        -- must NOT pause the whole rotation. The user's hard requirement: "as im
        -- turning the literal instant its possible to cast ... it should cast
        -- literally instantly." The old `_next_gap = 0.25` made the rotation
        -- sleep 250ms after a facing block — that is exactly the hesitation the
        -- user forbids. The native facing read is hook-cached (cheap), so the
        -- gate can re-check EVERY tick and wire the literal instant the player's
        -- facing is sufficient. The attempt LOG is throttled separately (above);
        -- the DECISION is never paused on facing/oor/los.
        -- We only keep a tiny micro-gap (30ms) so a genuinely-refused cast
        -- doesn't hammer the bridge in a tight loop; this is NOT a perceivable
        -- pause (it is below one frame).
        if lw:find("^facing") or lw:find("^oor") or lw:find("^los") then
            local tnow2 = now()
            local g = Executor._next_gap or 0
            if g < 0.03 then Executor._next_gap = 0.03 end
            Executor._last_attempt_t = tnow2
        end
        if lw:find("^cast_fail") or lw:find("^cooldown:") then
            if Executor._in_tick then
                Executor._retick_pending = true
                Executor._retick_why = "wire_refused"
            else
                request_retick("wire_refused")
            end
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
            -- Multi-dot: never freeze list. Floor THIS spell only to LIVE rem.
            Executor._gcd_until = 0
            Executor._gcd_provisional = false
            Executor._gcd_src = "multidot_wire"
            Executor._pending = {
                sid = sid, cast_t = tnow, deadline = tnow + grace, grace = grace,
                before_cd = before and before.cd_start or 0,
                name = action._cast_name or name,
                off_gcd = false,
                guid = guid,
                multidot = true,
                no_gcd = true,
            }
            local live = spell_ready_remaining(cast_sid, action._cast_name or name)
            Executor._recent = Executor._recent or {}
            if live > 0.02 then
                Executor._recent[sid] = tnow + live
                if cast_sid and cast_sid ~= sid then
                    Executor._recent[cast_sid] = tnow + live
                end
            end
        else
            -- Wire without same-frame evidence: free list unless live GCD rem.
            -- Promote to real GCD only on land event / live bar.
            local after2 = cast_snapshot(cast_sid)
            local arem = 0
            if after2 and after2.cd_dur and after2.cd_dur > 0 then
                arem = (tonumber(after2.cd_start) or tnow) + after2.cd_dur - tnow
                if arem < 0 then arem = 0 end
            end
            if arem <= 0 then
                arem = spell_ready_remaining(cast_sid, action._cast_name or name)
            end
            if arem > 10 then arem = 10 end
            if arem > 0.02 and arem <= 1.65 then
                Executor._gcd_until = tnow + arem
                Executor._gcd_provisional = true
                Executor._gcd_src = "wire_live_gcd"
            else
                -- 2026-08-02 (RED-SPAM FIX): the client ACCEPTED the wire
                -- (Spell_C al=1) but reports no live GCD (Ascension custom /
                -- instant casts skip the CD table). The server WILL apply a
                -- real GCD. Lock the observed/hasted GCD NOW so no slot
                -- re-fires into the live client GCD — that re-fire was the
                -- "spell not ready" spam + double-casts. Land/fail events
                -- refine or free it.
                -- 2026-08-02 (00:04 LOCKUP FIX — instant melee credited as
                -- landed, never phantom): the runtime returned al=1 (the cast
                -- was ACCEPTED), but instant melee (Plague Strike / Blood
                -- Strike) has NO cast bar and fires no UNIT_SPELLCAST_SUCCESS/
                -- FAILED on this client, so cast_confirmed() stays false and
                -- the ~0.14s grace expired -> phantom_grace -> the addon
                -- re-fired a cast the client HAD accepted, landing on the now-
                -- real 6s ability cooldown -> "wait cooldown:Blood Strike
                -- x80/x161" (the rotation locked for seconds). Since the
                -- runtime al=1 is a RELIABLE acceptance, credit the cast as
                -- landed on the real GCD window: set _pending.deadline to the
                -- optimistic GCD end so the grace/confirm path confirms via the
                -- GCD floor (cast_confirmed ability_cd) instead of phantoming.
                local dur = select(1, Executor.gcd_fallback())
                Executor._gcd_until = tnow + dur
                Executor._gcd_provisional = true
                Executor._gcd_src = "wire_optimistic"
                arem = dur
            end
            -- 2026-08-02 (00:04): deadline for an ACCEPTED instant wire = the
            -- optimistic GCD end (not the net_grace ~0.14s). A real short GCD
            -- is the strongest confirmation that the instant cast landed. The
            -- land/fail event path still wins if it arrives earlier (it clears
            -- _pending below); this only prevents the false phantom on the
            -- event-less melee/rune instant casts.
            if ok and Executor._gcd_until and Executor._gcd_until > tnow then
                grace = (Executor._gcd_until - tnow) + 0.05
            end
            Executor._pending = {
                sid = sid, cast_t = tnow, deadline = tnow + grace, grace = grace,
                before_cd = before and before.cd_start or 0,
                name = action._cast_name or name,
                off_gcd = false,
                guid = guid,
                multidot = false,
                no_gcd = (Executor._gcd_until or 0) <= tnow,
                -- 2026-08-02 (00:04): the runtime returned al=1 for this
                -- instant wire (accepted, cast is out). Used by the late-grace
                -- branch to credit an accepted instant cast as LANDED instead
                -- of a phantom (instant melee/rune casts fire no SUCCESS event).
                accepted = (ok == true) and true or false,
            }
            Executor._recent = Executor._recent or {}
            if arem > 0.02 then
                Executor._recent[sid] = tnow + arem
                if cast_sid and cast_sid ~= sid then
                    Executor._recent[cast_sid] = tnow + arem
                end
            end
        end
    end

    -- Optimistic multi-dot aura mark on wire success (not only evidence).
    -- Search keys Blood Plague 55078; noting cast-spell id (45513) does nothing.
    -- Without this, single-target PS double-casted every GCD (search still
    -- "missing" until CLEU AURA_APPLIED arrived — often after the next tick).
    if ok and guid and W and W.note_aura_on_guid and search and search.guid
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
        elseif evidence then
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

-- net_grace / micro_lock: defined early (forward-decl block). Do not redeclare.

-- Real cast start: cast bar, channel, or THIS ability's CD (not bare GCD).
local function cast_confirmed(sid, before_cd)
    local cstate, csid = cast_state()
    if cstate == "casting" or cstate == "channeling" then return true, "casting" end
    if RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime() then
        local ok, cur = pcall(RaijinLab.RuntimeCall, RaijinLab, "CurrentSpell")
        if ok and tonumber(cur) == tonumber(sid) then return true, "current" end
    end
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

    -- 2026-08-02 (CRASH FIX, corrected): the RUNTIME owns the acquire-off
    -- selection restore (PulseSelectionRestore — deferred, only when NOT
    -- casting, VEH-guarded). The old Lua `_restore_selection` here called
    -- A.Target/A.ClearTarget (WriteClientTargetGuid -> writes 0xBD07B0)
    -- SYNCHRONOUSLY from a later tick, racing the game's cast-resolve and
    -- corrupting the Lua VM (0x512B07). The runtime's deferred restore already
    -- reverts the client-selection global once the cast settles, so this Lua
    -- block is now a NO-OP. Keep the table reference cleared so it stops being
    -- re-armed.
    Executor._restore_selection = nil

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
            -- Set spell CD floor from observed cooldown AFTER landing.
            -- GetSpellCooldown may work post-cast even for Ascension custom
            -- spells (the client updates its internal CD table on successful
            -- cast). If it returns nil, fall back to the GCD duration.
            Executor._recent = Executor._recent or {}
            local cd_end = t + micro_lock()  -- minimum anti-double-fire
            if GetSpellCooldown and p.sid > 0 then
                local s, d = GetSpellCooldown(p.sid)
                s, d = tonumber(s) or 0, tonumber(d) or 0
                if d > 1.6 then  -- real spell CD (not GCD)
                    local end_t = s + d
                    if end_t > cd_end then cd_end = end_t end
                end
            end
            -- If no spell CD detected, use GCD end as minimum floor
            if (Executor._gcd_until or 0) > cd_end then
                cd_end = Executor._gcd_until
            end
            Executor._recent[p.sid] = cd_end
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
            -- 2026-08-02 (00:04): an ACCEPTED instant wire (runtime al=1, no
            -- castbar -> no SUCCESS event on this client) whose real GCD window
            -- has fully elapsed with no FAIL event is a LANDED cast, not a
            -- phantom. Phantoms only happen when the runtime REFUSED (al=0) —
            -- i.e. a wire that was never accepted. Crediting an accepted instant
            -- as landed stops the false "phantom_grace -> re-fire into the real
            -- ability cooldown -> wait cooldown xN" lockup (live 00:04: Plague/
            -- Blood Strike, runtime accepted al=1, addon phantomed them and
            -- locked the rotation ~4s).
            local accepted_wire = (p.accepted == true) and not fail_hit
            if cast_confirmed(sid, p.before_cd) or accepted_wire then
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
                log_cast("landed", sid, p.name, accepted_wire and "accepted_wire" or "grace_confirm", p.cast_t)
            else
                -- PHANTOM / FAILED RECOVERY (2026-08-02): a phantom is a cast
                -- that produced NO success and NO fail event — it never landed.
                -- USER DIRECTIVE (no hesitation, fail-open): recover IMMEDIATELY,
                -- never wait a full 1.5s GCD on a cast that may never have
                -- happened. The GCD floor is a guess; the spell-level _recent
                -- micro-lock prevents same-spell re-fire spam, and the real CD
                -- table (GetSpellCooldown + runtime SpellCooldownMs) still
                -- gates a genuinely-on-CD spell. Free the GCD — always.
                -- (The old `phantom_kept` branch — keeping the wire-time GCD
                -- floor on a phantom — is what locked the rotation in
                -- "wait cooldown x240" for 8+ seconds after refused casts.
                -- Live 18:36: every refused cast left a 1.5s GCD floor that
                -- compounded into a total rotation freeze. Removed.)
                Executor._pending = nil
                Executor._gcd_provisional = false
                Executor._next_gap = 0
                Executor._idle_until = nil
                Executor._unconf = nil
                clear_sid_soft_locks(sid)
                Executor._gcd_until = 0
                Executor._gcd_src = "phantom_free"
                Executor._recent = Executor._recent or {}
                Executor._recent[sid] = math.max(Executor._recent[sid] or 0,
                                                 t + (p.multidot and 0.12 or 0.08))
                log_cast("refused", sid, p.name, "phantom_grace", p.cast_t)
                -- INSTANT RECOVERY: a phantom must trigger an immediate re-eval
                -- (event-driven path bypasses the poll throttle), so the next
                -- castable spell fires THIS frame, not after the next poll.
                request_retick("phantom_recover")
            end
        end
        -- else: still inside grace — short provisional only
    end

    local gap = Executor._next_gap or 0
    -- 2026-08-02 (NO-HESITATION): an event-driven retick (cast land / refuse)
    -- MUST bypass the facing/oor poll throttle — a real game event is the
    -- fastest truth the rotation can get; delaying it 0.25s would be a visible
    -- hesitation after every landed cast. Only the free-running OnUpdate poll
    -- loop is throttled (that is where the 50Hz attempt spam lived).
    if gap > 0 and (t - (Executor._last_attempt_t or 0)) < gap
        and not Executor._from_event then
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

    local cstate = cast_state()
    local ctx = {
        target_exists = UnitExists and UnitExists("target") or false,
        target_is_dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") or false,
        target_is_enemy = UnitCanAttack and UnitCanAttack("player", "target") or false,
        is_casting = (cstate == "casting" or cstate == "channeling"),
        is_channeling = (cstate == "channeling"),
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
            -- Authoritative casting (RE-verified): build_context derives
            -- is_casting from Lua UnitCastingInfo which NO-OPS from insecure
            -- code. Re-assert the runtime's real casting state here.
            local cst2 = cast_state()
            ctx.is_casting = (cst2 == "casting" or cst2 == "channeling")
            ctx.is_channeling = (cst2 == "channeling")
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

    -- GCD freeze first so fill_live can take the light path under GCD.
    local cst = cast_state()
    local casting_now = (cst == "casting" or cst == "channeling")
        or (UnitCastingInfo and UnitCastingInfo("player"))
        or (UnitChannelInfo and UnitChannelInfo("player"))
    -- Clear STUCK provisional GCD when live client shows ready (new-target lag).
    -- Live: gcd_src=not_ready_gcd rem=1.47 while OOC no target for minutes.
    if not casting_now and (Executor._gcd_until or 0) > t then
        local live = spell_ready_remaining(61304, nil)
        if live <= 0.02 then
            -- Double-check any known gcd-triggering spell remaining
            local any = 0
            if GetSpellCooldown then
                for _, pid in ipairs({ 61304, 6603, 75 }) do
                    if pid > 0 and any <= 0 then
                        local s, d = GetSpellCooldown(pid)
                        s, d = tonumber(s) or 0, tonumber(d) or 0
                        if d > 0.75 and d <= 1.6 then any = (s + d) - t end
                    end
                end
            end
            if any <= 0.02 then
                Executor._gcd_until = 0
                Executor._gcd_provisional = false
                Executor._gcd_src = "live_clear"
            end
        end
    end
    local gcd_active = false
    if casting_now then
        gcd_active = true
    elseif t < (Executor._gcd_until or 0) then
        gcd_active = true
    end
    pend = Executor._pending
    if pend then
        ctx.pending_sid = pend.sid
        ctx.pending_no_gcd = (pend.no_gcd or pend.multidot) and true or false
        if not pend.off_gcd and not pend.no_gcd and not pend.multidot then
            gcd_active = true
        end
    end
    ctx.gcd_active = gcd_active

    -- New target: clear idle throttle + AA recent so first engage is instant.
    do
        local tg = (UnitExists and UnitExists("target") and UnitGUID and UnitGUID("target")) or nil
        if tg and tg ~= Executor._last_target_guid then
            Executor._idle_until = nil
            Executor._recent = Executor._recent or {}
            Executor._recent[6603] = nil
            if Executor._gcd_provisional then
                Executor._gcd_until = 0
                Executor._gcd_provisional = false
            end
        end
        Executor._last_target_guid = tg
    end

    -- AUTHORITATIVE live client readiness THIS frame (overwrites snapshot).
    fill_live_spell_state(ctx, spell_ids)
    -- Corpse / Target Existence any|no_target policy overrides.
    apply_slot_policy_overrides(ctx, rotation)

    -- Recompute pending expiry (may free GCD) after fill.
    pend = Executor._pending
    if pend then
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
            ctx.pending_no_gcd = nil
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
    -- Re-sync after pending expiry may have cleared GCD.
    if not casting_now and t >= (Executor._gcd_until or 0) then
        gcd_active = false
        if pend and not pend.off_gcd and not pend.no_gcd and not pend.multidot
            and t < (Executor._gcd_until or 0) then
            gcd_active = true
        end
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
    -- 2026-08-02 (19:01 CHARMED SPAM FIX): while the player is charmed (or
    -- within a short window after a "Can't attack while charmed" refusal),
    -- NOTHING can cast — the client refuses every spell. Skip the whole slot
    -- loop so the rotation enters a visible "wait_cc" state instead of
    -- re-firing the same cast into the refusal at ~100Hz. Not a fallback:
    -- it is the authoritative player state (charmed = no casts possible).
    local cc_active = (tonumber(Executor._player_cc_until) or 0) > t
    if not cc_active and UnitIsCharmed and UnitIsCharmed("player") then
        cc_active = true
        Executor._player_cc_until = t + 0.5
    elseif not cc_active then
        Executor._player_cc_until = nil -- charm ended; clear the window
    end
    if cc_active then
        how = "wait_cc"
    end
    local loopMax = cc_active and 0 or maxTries
    for _ = 1, loopMax do
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
        -- FAILURE RECOVERY: always try next priority THIS tick. Never freeze
        -- the whole rotation on one failed/not-ready slot.
        local how_s = tostring(how or "")
        local is_nready = how_s:find("not_ready", 1, true) or how_s:find("cooldown", 1, true)
        local asid = tonumber(action.spell_id) or 0
        Executor._pending = nil
        ctx.pending_sid = nil
        ctx.pending_no_gcd = nil
        if is_nready then
            -- Floor THIS spell to LIVE rem only (no invent). Free list unless
            -- client shows a real short GCD right now.
            local hold = spell_ready_remaining(asid, action.name)
            if hold > 10 then hold = 10 end
            Executor._recent = Executor._recent or {}
            if asid > 0 and hold > 0.02 then
                Executor._recent[asid] = t + hold
            end
            local gcd_rem = 0
            if GetSpellCooldown then
                for _, pid in ipairs({ 61304, 6603, 75, asid }) do
                    if pid and pid > 0 and gcd_rem <= 0 then
                        local s2, d2 = GetSpellCooldown(pid)
                        s2, d2 = tonumber(s2) or 0, tonumber(d2) or 0
                        if d2 > 0.75 and d2 <= 1.6 then
                            gcd_rem = (s2 + d2) - t
                            if gcd_rem > 0 then break end
                        end
                    end
                end
            end
            if gcd_rem > 0.02 then
                Executor._gcd_until = t + math.min(gcd_rem, 1.55)
                Executor._gcd_provisional = true
                Executor._gcd_src = "fallthrough_live_gcd"
                action = nil
                ok = false
                how = how_s
                break
            end
            Executor._gcd_until = 0
            Executor._gcd_provisional = false
            Executor._gcd_src = "fallthrough_spell_cd"
            ctx.gcd_active = false
            ctx.live_gcd_remaining = 0
        elseif how_s:find("^busy") ~= nil or how_s:find("cast_fail", 1, true) ~= nil then
            -- BUSY / CAST_FAIL (2026-08-02): the runtime/client refused the
            -- cast (Spell_C returned al=0). A silent native refusal never fires
            -- UNIT_SPELLCAST_FAILED, so there is NO event to set a floor —
            -- without one the rotation re-fires the same spell every frame at
            -- 30 Hz (the "cast_fail" spam that bloated the dev log and froze
            -- the debug-copy dialog for 20 s). Back off ~1 GCD instead of
            -- hammering; the underlying gate will clear and we retry.
            Executor._gcd_until = t + 1.0
            Executor._gcd_provisional = true
            Executor._gcd_src = (how_s:find("^busy") ~= nil) and "busy_backoff" or "castfail_backoff"
            ctx.gcd_active = true
            ctx.live_gcd_remaining = math.max(0, Executor._gcd_until - t)
            ctx.pending_sid = nil
            action = nil
            ok = false
            how = how_s
            break
        else
            -- Facing / OOR: free list hard, no invent floors.
            Executor._gcd_until = 0
            Executor._gcd_provisional = false
            Executor._gcd_src = "fallthrough_clear"
            ctx.gcd_active = false
            ctx.pending_sid = nil
            ctx.live_gcd_remaining = 0
        end
        if rot_detail() then
            dlog("fallthrough", "#%s %s  %s",
                tostring(action.index), tostring(action.name), tostring(how))
        end
        exclude = exclude or {}
        exclude[action.index] = true
        -- Push floor into ctx so evaluate won't re-pick same sid this tick.
        if Executor._recent and asid > 0 and Executor._recent[asid] then
            ctx.cooldowns = ctx.cooldowns or {}
            local rem = Executor._recent[asid] - t
            if rem > 0 then
                ctx.cooldowns[asid] = math.max(tonumber(ctx.cooldowns[asid]) or 0, rem)
                ctx.cooldowns[tostring(asid)] = ctx.cooldowns[asid]
            end
        end
        fill_live_spell_state(ctx, spell_ids)
        apply_slot_policy_overrides(ctx, rotation)
        -- Re-apply recent floors after fill_live overwrote cooldowns.
        if Executor._recent then
            for sid_r, exp_r in pairs(Executor._recent) do
                if exp_r > t then
                    local rem = exp_r - t
                    local cur = tonumber(ctx.cooldowns[sid_r] or ctx.cooldowns[tostring(sid_r)]) or 0
                    if rem > cur then
                        ctx.cooldowns[sid_r] = rem
                        ctx.cooldowns[tostring(sid_r)] = rem
                    end
                end
            end
        end
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
            Executor._recent[sid] = t + 0.35
            Executor._recent[6603] = t + 0.35
        elseif off_gcd then
            Executor._recent = Executor._recent or {}
            Executor._recent[sid] = t + 0.05
        elseif not is_aa then
            local cast_guid = Executor._last_cast and Executor._last_cast.guid
            local is_md = action.aura_search_hit and action.aura_search_hit.guid
            -- Keep pending set by attempt_action when present. Never inflate
            -- provisional GCD back to a full 1.5s here — that paused the
            -- rotation on every unconfirmed/failed wire.
            if not Executor._pending then
                local g = is_md and math.min(grace, 0.10) or grace
                local has_live_gcd = (Executor._gcd_until or 0) > t
                Executor._pending = {
                    sid = sid, cast_t = t, deadline = t + g, grace = g,
                    before_cd = before_snap and before_snap.cd_start or 0,
                    name = action._cast_name or action.name,
                    off_gcd = false,
                    policy = action.target_policy or slot_policy(action.slot),
                    guid = cast_guid,
                    multidot = is_md and true or false,
                    no_gcd = is_md or (not has_live_gcd),
                }
            end
            -- REAL GCD FLOOR on wire-ok (2026-08-01). After a SUCCESSFUL wire
            -- the pending/grace can expire before the client's land event
            -- clears, so the SAME spell re-fires next frame — that is the
            -- "blocked action spam at 30 Hz" (live: Icy Touch / Plague Strike
            -- FIRE'd dozens of times per second while the client refused every
            -- re-cast). Set a genuine GCD floor from the observed/fallback GCD
            -- so the rotation cannot re-fire the same (or any GCD-bound) spell
            -- until the real GCD window has passed. _recent floors THIS spell;
            -- the land/refuse event refines it further.
            Executor._recent = Executor._recent or {}
            local gdur = Executor.gcd_fallback and select(1, Executor.gcd_fallback()) or 1.0
            if not is_md then
                Executor._recent[sid] = t + gdur
            else
                -- Multi-dot: short floor (0.12s) then free list for the next target.
                Executor._recent[sid] = t + 0.12
            end
            -- _recent already set from live rem in attempt_action when available.
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
    -- Quiet waits (no target / gcd / power / cc): heartbeat every 5s.
    -- Other waits: every 3s. Always log on reason change.
    local boring = (reason == "no_target" or reason == "no_target_await_attacker"
        or reason == "target_dead"
        or reason == "gcd" or reason == "power"
        or reason == "enemies_in_range" or reason == "user_busy" or reason == "idle"
        or reason == "wait_cc")
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
    -- 2026-08-02 (OFF-STILL-CASTING FIX): tick must self-guard on the enabled
    -- flag. A post-OFF entry (armed C_Timer retick, stale event frame, or the
    -- Events.lua resume path racing the toggle) must be a no-op — never run a
    -- full tick (with casts) after the user turned the rotation off.
    if not RaijinLabDB or not RaijinLabDB.rotation_enabled then return nil, "off" end
    if Executor._in_tick then
        Executor._retick_pending = true
        return nil, "reentrant"
    end
    Executor._in_tick = true
    local prev_from_event = Executor._from_event
    if Executor._from_event == nil then Executor._from_event = false end
    local ok, a, b = pcall(Executor._tick_body)
    Executor._in_tick = false
    Executor._from_event = prev_from_event
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
local function ui_open()
    if RaijinLab and RaijinLab._ui_open_hint then return true end
    local Menu = RaijinLab and RaijinLab.Menu
    if Menu and Menu.frame and Menu.frame.IsShown and Menu.frame:IsShown() then return true end
    local Ed = RaijinLab and RaijinLab.RotationEditor
    if Ed and Ed.frame and Ed.frame.IsShown and Ed.frame:IsShown() then return true end
    return false
end

local function adaptive_tick_interval()
    if Executor._pending then return 0 end
    local combat = UnitAffectingCombat and UnitAffectingCombat("player")
    -- 2026-08-02 (DEAD-TARGET ANTI-FREEZE): with the current target dead, there
    -- is nothing to cast at (acquire-off never retargets a corpse) — spinning at
    -- 60fps trying the corpse froze the rotation ("wait target_dead x363").
    -- Drop to a calm cadence until a living target exists.
    if UnitExists and UnitExists("target") then
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") then
            return 0.05
        end
    end
    local ui = ui_open()
    -- UI open: leave frame budget for paint (hitches when opening menu).
    -- Combat still ~30Hz (not stopped); multi-dot remains fully capable.
    if ui then
        return combat and 0.033 or 0.08
    end
    -- Full rate in combat or with multi-dot / live target work.
    if combat then return 0 end
    if UnitExists and UnitExists("target") then
        if UnitCanAttack and UnitCanAttack("player", "target")
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("target")) then
            return 0
        end
    end
    local nc = Executor._needs_cache
    -- Multi-dot OOC: ~25Hz is enough; 60Hz + SoftRefresh was pure lag.
    if nc and nc.aura then return 0.04 end
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
    -- DIAG (2026-08-01): capture the EXACT tainted action. WoW fires
    -- ADDON_ACTION_BLOCKED with the protected function name + addon when a
    -- secure action is attempted from insecure origin — logging it pinpoints
    -- which call (StartAttack / CastSpell / movement / Interact / Target) is
    -- poisoning the session with the "blocked by Blizzard UI" popup.
    f:RegisterEvent("ADDON_ACTION_BLOCKED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self, event, ...)
        if event == "ADDON_ACTION_BLOCKED" then
            local fn, addon = ...
            if tostring(addon):lower():find("raijin", 1, true) then
                Executor._last_blocked_action = tostring(fn)
                dlog("rot", "BLOCKED ACTION fn=%s addon=%s", tostring(fn), tostring(addon))
            end
        end
    end)
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
    -- 2026-08-02 (LOCKUP FIX): clear ALL transient rotation state so a
    -- re-enable never inherits a stuck GCD / pending / recent floor. Live:
    -- gcd=1.419 gcd_src=fallthrough_clear persisted for MINUTES with the
    -- rotation OFF (stop() never reset _gcd_until) — re-enabling then waited
    -- the stale GCD and looked completely frozen. Now stop() is a hard reset.
    Executor._gcd_until = 0
    Executor._gcd_provisional = false
    Executor._gcd_src = "stopped"
    Executor._pending = nil
    Executor._unconf = nil
    Executor._recent = nil
    Executor._idle_until = nil
    Executor._next_gap = 0
    Executor._restore_selection = nil
    Executor._retick_pending = false
    Executor._retick_why = nil
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
