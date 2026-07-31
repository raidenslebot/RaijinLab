-- Mount - riding, because walking everywhere is the single biggest time sink.
--
-- Mounting is not just "press the button": it has a cast time, it is cancelled by
-- moving or being hit, it is impossible indoors / in combat / while swimming, and
-- it must be given up the instant we need to fight, loot or talk. Getting that
-- sequencing wrong is worse than never mounting at all - a half-cast mount that
-- keeps getting interrupted stalls the bot in place forever.
--
-- NOTE ON APIS: this client is 3.3.5. Mounts are COMPANIONS here
-- (GetNumCompanions / GetCompanionInfo / CallCompanion "MOUNT"). The retail
-- C_MountJournal namespace does not exist and calling it errors, so it is never
-- referenced. Anything newer is probed defensively before use.

local Mount = {}

Mount.MIN_DIST      = 60.0    -- yd: below this, mounting costs more than it saves
Mount.CAST_TIME     = 3.0     -- s: generous upper bound on a mount cast
Mount.RETRY_GAP     = 2.0     -- s between mount attempts
Mount.DISMOUNT_NEAR = 12.0    -- yd from the goal: get off and finish on foot

Mount._last_try = 0
Mount._enabled = true
Mount._fails = 0             -- consecutive summons that never produced a mount
Mount._blocked_until = 0     -- suppressed after repeated failures
Mount.MAX_FAILS = 3
Mount.BLOCK_SECS = 120
Mount.BLOCK_MAX  = 1800      -- s: ceiling on the escalating backoff
Mount._blocks = 0            -- how many times we have given up in a row
Mount._proven = false        -- this character HAS successfully mounted at least once

-- Riding skill spells through 3.3.5 (later ids are harmless if the server has
-- never heard of them). Owning a mount and being ALLOWED TO RIDE IT are two
-- different things, and a level-1 character owns the former without the latter.
Mount.RIDING_SPELLS = { 33388, 33391, 34090, 34091, 90265 }

local function now() return (GetTime and GetTime()) or 0 end

-- ---- can this character ride at all? -------------------------------------
--
-- The bot was looping stop -> summon -> fail -> wait -> repeat on a level-1
-- character, because "the summon did not take" was treated as a transient
-- failure. Lacking the riding skill is not transient: it is a fact about the
-- character that will not change until it levels or trains. Detect it up front
-- and refuse instantly, so the bot walks instead of standing still.
--
-- Three-valued: Know.yes / Know.no / Know.unknown. Legacy Mount.has_riding_skill
-- still returns true/false/nil for older callers; prefer has_riding_skill_k.
function Mount.has_riding_skill_k()
    local Kn = RaijinLab and RaijinLab.Know
    local answered = false
    if IsSpellKnown then
        answered = true
        for _, id in ipairs(Mount.RIDING_SPELLS) do
            local ok, known = pcall(IsSpellKnown, id)
            if ok and known then
                if Kn then return Kn.yes(true, "spell:" .. id) end
                return true
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        local ok, n = pcall(GetNumSkillLines)
        if ok and tonumber(n) then
            answered = true
            for i = 1, n do
                local ok2, nm, isHeader, _, rank = pcall(GetSkillLineInfo, i)
                if ok2 and nm and not isHeader
                   and tostring(nm):lower():find("riding", 1, true)
                   and (tonumber(rank) or 0) > 0 then
                    if Kn then return Kn.yes(true, "skill:" .. tostring(nm)) end
                    return true
                end
            end
        end
    end
    if not answered then
        if Kn then return Kn.unknown("no_api") end
        return nil
    end
    if Kn then return Kn.no("no_riding_skill") end
    return false
end

-- Returns true / false / nil, where NIL MEANS "cannot tell".
function Mount.has_riding_skill()
    local k = Mount.has_riding_skill_k()
    if type(k) == "table" and k.state then
        if k.state == "yes" then return true end
        if k.state == "no" then return false end
        return nil
    end
    return k
end

-- Has this character ever actually mounted? A success outranks every heuristic.
-- Uses Know.proven so a positive observation permanently outranks "no skill".
function Mount.can_ride_k()
    local Kn = RaijinLab and RaijinLab.Know
    local skill = Mount.has_riding_skill_k()
    if Kn and Kn.proven then
        return Kn.proven(Mount._proven, skill, "mounted_once")
    end
    if Mount._proven then
        if Kn then return Kn.yes(true, "proven") end
        return true
    end
    return skill
end

function Mount.can_ride()
    local k = Mount.can_ride_k()
    local Kn = RaijinLab and RaijinLab.Know
    -- Unknown: let the attempt decide (assume true, greppable).
    if Kn and Kn.assume then
        return Kn.assume(k, true, "mount:attempt_when_skill_unknown")
    end
    if type(k) == "table" and k.state then
        if k.state == "yes" then return true end
        if k.state == "no" then return false end
        return true
    end
    if k == nil then return true end
    return not not k
end

-- ---- state ---------------------------------------------------------------

function Mount.is_mounted_k()
    local Kn = RaijinLab and RaijinLab.Know
    if IsMounted then
        local ok, m = pcall(IsMounted)
        if ok then
            if m then
                if Kn then return Kn.yes(true, "IsMounted") end
                return true
            end
            -- 3.3.5: nil/false both mean not mounted when the API exists.
            if Kn then return Kn.no("IsMounted") end
            return false
        end
        if Kn then return Kn.unknown("IsMounted_error") end
    end
    local RL = RaijinLab
    if RL and RL.UnitIsMounted then
        local ok, m = pcall(RL.UnitIsMounted, RL, "player")
        if ok then
            if m then
                if Kn then return Kn.yes(true, "UnitIsMounted") end
                return true
            end
            if Kn then return Kn.no("UnitIsMounted") end
            return false
        end
        if Kn then return Kn.unknown("UnitIsMounted_error") end
    end
    if Kn then return Kn.unknown("no_mount_api") end
    return nil
end

function Mount.is_mounted()
    local k = Mount.is_mounted_k()
    local Kn = RaijinLab and RaijinLab.Know
    -- Unknown: treat as not mounted (safe for dismount/summon decisions).
    if Kn and Kn.assume then
        return Kn.assume(k, false, "mount:assume_unmounted_when_unknown")
    end
    if type(k) == "table" and k.state then
        return k.state == "yes"
    end
    return not not k
end

function Mount.is_casting()
    if UnitCastingInfo then
        local ok, name = pcall(UnitCastingInfo, "player")
        if ok and name then return true end
    end
    return false
end

-- Everything that makes mounting impossible or pointless right now.
-- Returns false + a reason, so the caller can log WHY rather than silently idling.
function Mount.can_mount(ctx)
    ctx = ctx or {}
    if not Mount._enabled then return false, "disabled" end
    -- Suppressed after repeated failures: walking is far better than looping.
    if now() < (Mount._blocked_until or 0) then return false, "summon_failing" end
    if Mount.is_mounted() then return false, "already_mounted" end
    -- The cheap, decisive check, before any of the situational ones: a character
    -- that cannot ride will never mount no matter how good the moment is.
    if not Mount.can_ride() then
        -- Permanent fact until level/train - shared Fail engine, not a flat timer.
        local F = RaijinLab and RaijinLab.Fail
        if F and F.permanent then
            F.permanent("mount:no_riding", "no riding skill",
                { "PLAYER_LEVEL_UP", "TRAINER_SHOW", "SKILL_LINES_CHANGED" })
        end
        return false, "no_riding_skill"
    end
    do
        local F = RaijinLab and RaijinLab.Fail
        if F and F.may_retry then
            local ok = F.may_retry("mount:summon")
            if not ok then return false, "fail_backoff" end
            local ok2 = F.may_retry("mount:no_riding")
            if not ok2 then return false, "no_riding_skill" end
        end
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return false, "combat" end
    if IsSwimming and IsSwimming() then return false, "swimming" end
    if IsIndoors and IsIndoors() then return false, "indoors" end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false, "dead" end
    if Mount.is_casting() then return false, "casting" end
    if ctx.in_combat then return false, "combat" end
    return true
end

-- ---- the mount list (3.3.5 companions) -----------------------------------

function Mount.list()
    local out = {}
    if not (GetNumCompanions and GetCompanionInfo) then return out end
    local ok, n = pcall(GetNumCompanions, "MOUNT")
    if not ok or not n then return out end
    for i = 1, n do
        local ok2, creatureID, name, spellID, icon, summoned = pcall(GetCompanionInfo, "MOUNT", i)
        if ok2 and name then
            out[#out + 1] = { index = i, id = creatureID, name = name,
                              spell = spellID, summoned = summoned and true or false }
        end
    end
    return out
end

-- Which mount to use. A user-pinned favourite wins; otherwise we take the last
-- one learned, which on almost every character is the fastest they own (mounts
-- are learned in speed order as you level).
function Mount.pick()
    local list = Mount.list()
    if #list == 0 then return nil end
    local pinned = RaijinLabDB and RaijinLabDB.mount and RaijinLabDB.mount.favorite
    if pinned then
        for _, m in ipairs(list) do
            if m.name == pinned or m.index == pinned or m.spell == pinned then return m end
        end
    end
    return list[#list]
end

-- ---- actions -------------------------------------------------------------

-- Summon. Movement cancels the cast, so the caller MUST have stopped first -
-- this is the mistake that makes a bot stand still re-casting forever.
function Mount.summon()
    local t = now()
    if (t - (Mount._last_try or 0)) < Mount.RETRY_GAP then return false, "cooldown" end
    local ok, why = Mount.can_mount()
    if not ok then return false, why end
    local m = Mount.pick()
    if not m then return false, "no_mounts" end
    Mount._last_try = t
    Mount._pending = { t = t, name = m.name }
    local Ou = RaijinLab and RaijinLab.Outcomes
    if Ou and Ou.begin then Mount._outcome = Ou.begin("mount", { name = m.name }) end
    if CallCompanion then
        local done = pcall(CallCompanion, "MOUNT", m.index)
        if done then return true, m.name end
    end
    -- Some custom servers expose mounts as ordinary spells instead.
    if m.spell and RaijinLab and RaijinLab.Actions and RaijinLab.Actions.CastSpell then
        local done = pcall(RaijinLab.Actions.CastSpell, m.spell)
        if done then return true, m.name end
    end
    if Ou and Mount._outcome then Ou.settle(Mount._outcome, -0.5, "no_call_api"); Mount._outcome = nil end
    return false, "no_call_api"
end

function Mount.dismount()
    if not Mount.is_mounted() then return false, "not_mounted" end
    if Dismount then
        local ok = pcall(Dismount)
        if ok then return true end
    end
    -- Deliberately NO blind buff-cancel fallback here: cancelling an arbitrary
    -- aura slot is far worse than failing to dismount. Report the truth instead.
    return Mount.is_mounted() == false
end

-- Are we still waiting on a mount cast we started?
function Mount.pending()
    local p = Mount._pending
    if not p then return false end
    if Mount.is_mounted() then
        Mount._pending = nil
        Mount._fails = 0            -- it worked; forget past failures
        Mount._blocks = 0
        Mount._proven = true        -- settles the skill question permanently
        local Ou = RaijinLab and RaijinLab.Outcomes
        if Ou and Mount._outcome then Ou.settle(Mount._outcome, 1.0, "mounted"); Mount._outcome = nil end
        return false
    end
    if (now() - p.t) > Mount.CAST_TIME then
        -- The window closed and we are still on foot: the summon did not take.
        local Ou = RaijinLab and RaijinLab.Outcomes
        if Ou and Mount._outcome then Ou.settle(Mount._outcome, -1.0, "summon_failed"); Mount._outcome = nil end
        -- Without counting this, a server that silently rejects the mount loops
        -- stop -> summon -> wait forever and the character never travels at all.
        Mount._pending = nil
        Mount._fails = (Mount._fails or 0) + 1
        local Tel = RaijinLab and RaijinLab.Telemetry
        if Tel then Tel.warn("mount", "summon_failed", { fails = Mount._fails }) end
        if Mount._fails >= Mount.MAX_FAILS then
            Mount._blocks = (Mount._blocks or 0) + 1
            local skill = Mount.has_riding_skill()
            local F = RaijinLab and RaijinLab.Fail
            if skill == false and F and F.permanent then
                F.permanent("mount:no_riding", "summon failed + no riding skill",
                    { "PLAYER_LEVEL_UP", "TRAINER_SHOW", "SKILL_LINES_CHANGED" })
            elseif F and F.record then
                F.record("mount:summon", F.TRANSIENT or "transient", {
                    why = "summon_failed",
                    backoff = Mount.BLOCK_SECS,
                })
            end
            local secs = math.min(Mount.BLOCK_MAX,
                                  Mount.BLOCK_SECS * (2 ^ (Mount._blocks - 1)))
            Mount._blocked_until = now() + secs
            Mount._fails = 0
            if Tel then Tel.warn("mount", "suppressed",
                { secs = secs, blocks = Mount._blocks,
                  riding = tostring(skill) }) end
            if Mount._blocks == 1 and print then
                if skill == false then
                    print("|cff7ec8e3RaijinLab|r mount: this character has no riding " ..
                          "skill - travelling on foot.")
                else
                    print("|cff7ec8e3RaijinLab|r mount: summon keeps failing - " ..
                          "travelling on foot.")
                end
            end
        end
        return false
    end
    return true
end

-- ---- the decision --------------------------------------------------------

-- Should we be mounted for a trip of `dist` yards?
function Mount.should_mount(dist, ctx)
    ctx = ctx or {}
    if not Mount._enabled then return false, "disabled" end
    if (tonumber(dist) or 0) < (ctx.min_dist or Mount.MIN_DIST) then return false, "too_close" end
    local ok, why = Mount.can_mount(ctx)
    if not ok then return false, why end
    if #Mount.list() == 0 then return false, "no_mounts" end
    return true, "travel"
end

-- Should we get OFF right now? Being mounted blocks looting, interacting and
-- attacking, so we dismount as we arrive rather than after we have failed.
function Mount.should_dismount(dist, ctx)
    ctx = ctx or {}
    if not Mount.is_mounted() then return false, "not_mounted" end
    if ctx.want_action then return true, "action" end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true, "combat" end
    if dist and dist <= (ctx.near or Mount.DISMOUNT_NEAR) then return true, "arrived" end
    return false, nil
end

-- One maintenance step for a trip toward a goal `dist` yards away.
-- `stop_fn` halts movement (mounting requires standing still).
-- Returns a status string when it took control this tick, else nil so the caller
-- carries on walking.
function Mount.maintain(dist, ctx)
    ctx = ctx or {}
    if Mount.should_dismount(dist, ctx) then
        local ok = Mount.dismount()
        Mount._dis_n = ok and 0 or ((Mount._dis_n or 0) + 1)
        -- A dismount that silently fails must not block movement forever: after a
        -- few tries, give up and let the caller travel (mounted if need be).
        if Mount._dis_n < 5 then return "mount:dismounting" end
        Mount._blocked_until = now() + Mount.BLOCK_SECS
        return nil
    end
    if Mount.is_mounted() then return nil end          -- already riding: just travel
    if Mount.pending() then
        -- Cast in progress: hold still or it will be cancelled.
        if ctx.stop_fn then ctx.stop_fn() end
        return "mount:summoning"
    end
    local ok = Mount.should_mount(dist, ctx)
    if not ok then return nil end
    if ctx.stop_fn then ctx.stop_fn() end
    local done, why = Mount.summon()
    if done then return "mount:summoning (" .. tostring(why) .. ")" end
    return nil
end

-- A refusal must not outlive its reason. Training riding or levelling up changes
-- the answer, so drop every block and re-evaluate on the next trip.
function Mount.reconsider(why)
    Mount._blocked_until = 0
    Mount._fails = 0
    Mount._blocks = 0
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel then Tel.info("mount", "reconsider", { why = why or "?" }) end
end

if CreateFrame then
    local f = CreateFrame("Frame")
    for _, ev in ipairs({ "LEARNED_SPELL_IN_TAB", "SKILL_LINES_CHANGED",
                          "PLAYER_LEVEL_UP", "COMPANION_LEARNED" }) do
        pcall(f.RegisterEvent, f, ev)
    end
    f:SetScript("OnEvent", function(_, ev) Mount.reconsider(ev) end)
    Mount._frame = f
end

function Mount.set_enabled(on) Mount._enabled = on and true or false end

function Mount.stats()
    local ok, why = Mount.can_mount()
    return { enabled = Mount._enabled, mounted = Mount.is_mounted(),
             known = #Mount.list(), pending = Mount.pending(),
             riding_skill = Mount.has_riding_skill(), proven = Mount._proven,
             blocks = Mount._blocks, blocked_for = math.max(0, (Mount._blocked_until or 0) - now()),
             can_mount = ok, reason = why }
end

if RaijinLab then RaijinLab.Mount = Mount end
return Mount
