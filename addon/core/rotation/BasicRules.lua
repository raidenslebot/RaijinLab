-- BasicRules: foundational cast gates applied BEFORE user conditions.
--
-- Order of authority for every rotation tick (per slot, top-down priority):
--   1. Slot priority (Engine walks slot 1..N; nothing lower runs until this
--      slot fully cycles: basic deny OR conditions deny OR cast attempt).
--   2. BasicRules.check  (this module — physical / client capability)
--   3. User conditions   (Conditions.evaluate_all)
--   4. Cast wire         (Executor.attempt_action)
--
-- Source checklist: Basic_Rotation_Checks_Raiden.md + Basic_Enumerable_Data.
-- Fail closed on hard gates when data is known; never invent "yes" from nil
-- for facing/LoS when positions exist. Unknown undeterminable states do not
-- hard-block (client still has the last word) except resource/CD/GCD.

local BasicRules = {}

local function num(v, d)
    v = tonumber(v)
    if v == nil then return d end
    return v
end

local function bool(v, d)
    if v == nil then return d end
    return not not v
end

local function spell_name(sid, fallback)
    sid = tonumber(sid) or 0
    if sid > 0 and GetSpellInfo then
        local n = GetSpellInfo(sid)
        if n and n ~= "" then return n end
    end
    return fallback or ("Spell " .. tostring(sid))
end

-- Ground / self-centered AoE never need a living unit target or face/LoS to it.
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

local function is_self_aoe_spell(sid, name)
    local n = string.lower(tostring(name or ""))
    if n:find("whirlwind", 1, true) then return true end
    if n:find("thunder clap", 1, true) then return true end
    if n:find("arcane explosion", 1, true) then return true end
    if n:find("fan of knives", 1, true) then return true end
    if n:find("blood boil", 1, true) then return true end
    if n:find("howling blast", 1, true) then return true end
    return is_ground_self_aoe(sid, name)
end

local function policy_of(slot, ctx)
    if ctx and ctx.slot_target_policy then return ctx.slot_target_policy end
    local Eng = RaijinLab and RaijinLab.RotationEngine
    if Eng and Eng.slot_target_policy then return Eng.slot_target_policy(slot) end
    return "require"
end

-- Resolve the unit GUID this slot would cast on (search hit or client target).
local function cast_guid(ctx)
    local hit = ctx and ctx.aura_search_hit
    if hit and hit.guid then return tostring(hit.guid) end
    if UnitGUID and UnitExists and UnitExists("target") then
        local g = UnitGUID("target")
        if g then return tostring(g) end
    end
    return nil
end

------------------------------------------------------------
-- Individual gates (checklist order, short-circuit on hard fail)
------------------------------------------------------------

local function check_identity(ctx, sid)
    if not sid or sid <= 0 then return false, "no_spell" end
    local known = ctx and ctx.known_spells
    if type(known) == "table" then
        local k = known[sid]
        if k == nil then k = known[tostring(sid)] end
        if k == false then return false, "unknown" end
    end
    return true
end

local function check_caster_busy(ctx, sid, slot)
    -- User interaction: loot/gossip/quest/... never interrupt unless opted in.
    local ust = ctx and ctx.user_state
    if ust and ust ~= "free" and not (ctx and ctx.slot_allows_busy) then
        return false, "user_busy"
    end
    -- Cast / channel: instants and while_casting slots may weave.
    if ctx and (ctx.is_casting or ctx.is_channeling) then
        local instant = false
        local si = ctx.spell_instant
        if type(si) == "table" then
            instant = (si[sid] == true or si[tostring(sid)] == true)
        end
        local while_cast = (slot and slot.while_casting) or (ctx and ctx.slot_while_casting)
        if not instant and not while_cast then
            return false, ctx.is_casting and "casting" or "channeling"
        end
    end
    -- Mounted / dead / ghost: hard block harmful rotation casts while dead/ghost.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        return false, "player_dead"
    end
    return true
end

local function check_gcd_cd(ctx, sid, slot)
    local off = (slot and slot.off_gcd) or (ctx and ctx.slot_off_gcd)
    -- Pending same spell: wait.
    if ctx and ctx.pending_sid and tonumber(ctx.pending_sid) == sid then
        return false, "pending"
    end
    -- GCD: off_gcd slots bypass. Provisional multi-dot wires are short;
    -- still honor gcd_active so we do not double-cast on real GCD.
    if ctx and ctx.gcd_active and not off then
        return false, "gcd"
    end
    -- Pending OTHER spell: only hard-block when a real (non-provisional) cast
    -- is in flight. Multi-dot wire provisional must not starve lower slots
    -- for more than the short grace (handled by gcd_active clearing).
    if ctx and ctx.pending_sid and not off then
        if tonumber(ctx.pending_sid) ~= sid then
            return false, "pending_other"
        end
    end
    -- Per-spell CD from live snapshot (+ Executor._recent via ctx.cooldowns)
    local cds = ctx and ctx.cooldowns or {}
    local rem = cds[sid]
    if rem == nil then rem = cds[tostring(sid)] end
    rem = num(rem, 0)
    local lag = 0.08
    if GetNetStats then
        local ok, _, _, lh, lw = pcall(GetNetStats)
        if ok then
            local ms = math.max(tonumber(lh) or 0, tonumber(lw) or 0)
            if ms > 0 then lag = math.min(0.35, math.max(0.05, ms / 1000 * 0.6)) end
        end
    end
    if rem > (0.04 + lag) then
        return false, "cooldown"
    end
    return true
end

local function slot_has_aura_search(slot)
    if not slot then return false end
    for _, c in ipairs(slot.conditions or {}) do
        if c and c.id == "aura_search" then return true end
    end
    return false
end

local function check_resources(ctx, sid, name, slot)
    -- IsUsableSpell greys unit-targeted spells when the client has NO current
    -- target — even when we will CastSpell(id, guid). BasicRules runs BEFORE
    -- aura_search, so aura_search_hit is still nil. Blocking on "unusable"
    -- here made multi-dot dead until the player manually selected something.
    if slot_has_aura_search(slot) then
        -- Only hard-fail on real resource starve (nomana), never on grey bar.
        if IsUsableSpell then
            local usable, nomana = IsUsableSpell(name)
            if usable == nil and sid then usable, nomana = IsUsableSpell(sid) end
            if nomana then return false, "no_resource" end
        end
        return true
    end
    local search = ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid
    local u = ctx and ctx.spell_usable
    if type(u) == "table" and (u[sid] == false or u[tostring(sid)] == false) then
        if not search then
            return false, "unusable"
        end
    end
    if not search and IsUsableSpell then
        local usable, nomana = IsUsableSpell(name)
        if usable == nil and sid then usable, nomana = IsUsableSpell(sid) end
        if not usable then
            if nomana then return false, "no_resource" end
            -- Without a definitive nomana, leave soft (policy layers decide).
        end
    end
    return true
end

local function check_target_relationship(ctx, sid, slot, name)
    local policy = policy_of(slot, ctx)
    if policy == "optional" or policy == "forbid" or policy == "corpse" then
        if policy == "forbid" and bool(ctx and ctx.target_exists, false) then
            return false, "has_target"
        end
        return true
    end
    if is_ground_self_aoe(sid, name) then
        return true
    end
    -- require living attackable unit (search GUID counts without client target).
    -- aura_search slots discover a unit during conditions — do not require a
    -- client target yet (BasicRules runs BEFORE conditions).
    local search = ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid
    if not bool(ctx and ctx.target_exists, false) and not search then
        if slot_has_aura_search(slot) then
            return true
        end
        return false, "no_target"
    end
    if bool(ctx and ctx.target_exists, false) and not search then
        if bool(ctx.target_is_dead, false) then
            return false, "target_dead"
        end
        if ctx.target_is_enemy == false then
            -- Multi-dot may cast on a different GUID while a friendly is selected.
            if slot_has_aura_search(slot) then return true end
            return false, "not_enemy"
        end
    end
    return true
end

local function check_range(ctx, sid, slot, name)
    local policy = policy_of(slot, ctx)
    if policy == "optional" or policy == "forbid" or policy == "corpse" then
        return true
    end
    if is_ground_self_aoe(sid, name) then
        return true
    end
    -- Multi-dot: range is validated vs the discovered GUID later — never vs
    -- client target. spell_in_range is often false with no target selected.
    if slot_has_aura_search(slot) then return true end
    local search = ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid
    if search then return true end
    local ir = ctx and ctx.spell_in_range
    if type(ir) == "table" then
        local r = ir[sid]
        if r == nil then r = ir[tostring(sid)] end
        if r == false then return false, "oor" end
    end
    return true
end

-- Facing: unit-targeted casts only. Fail when we can prove not facing.
local function check_facing(ctx, sid, slot, name)
    local policy = policy_of(slot, ctx)
    if policy == "optional" or policy == "forbid" or policy == "corpse" then
        return true
    end
    if is_self_aoe_spell(sid, name) or is_ground_self_aoe(sid, name) then
        return true
    end
    local guid = cast_guid(ctx)
    if not guid then return true end -- no unit => other gates handle
    local W = RaijinLab and RaijinLab.World
    if W and W.is_facing_guid then
        if not W.is_facing_guid(guid, W.CAST_FACE_HALF_ARC) then
            return false, "facing"
        end
    end
    return true
end

-- LoS: unit-targeted casts. Fail only on explicit blocked.
local function check_los(ctx, sid, slot, name)
    local policy = policy_of(slot, ctx)
    if policy == "optional" or policy == "forbid" or policy == "corpse" then
        return true
    end
    if is_ground_self_aoe(sid, name) then
        return true
    end
    local guid = cast_guid(ctx)
    local W = RaijinLab and RaijinLab.World
    -- Prefer GUID LoS when casting on a search unit (not necessarily client target).
    if guid and W and W.is_los_guid then
        local los = W.is_los_guid(guid)
        if los == false then return false, "los" end
        return true
    end
    -- Fallback: client-target LoS from context.
    if ctx and ctx.target_in_los == false then
        local search = ctx.aura_search_hit and ctx.aura_search_hit.guid
        if not search then
            return false, "los"
        end
    end
    return true
end

local function check_immunity(ctx, sid)
    if not ctx or not ctx.auto_castable then return true end
    -- Protection.is_protected returns protected=true when there is NO target
    -- (reason "no_target"). That is NOT immunity. Treating it as immune froze
    -- every non-aura_search slot with last_err=immune while tgt=no and
    -- casts=0 forever. Engine.spell_ready already requires target_exists —
    -- match that here. aura_search GUID casts are not about the client target.
    if not bool(ctx.target_exists, false) then
        return true
    end
    if ctx.aura_search_hit and ctx.aura_search_hit.guid then
        return true
    end
    local prot = ctx.target_protected
    if type(prot) ~= "table" then return true end
    if not (prot[sid] == true or prot[tostring(sid)] == true) then
        return true
    end
    -- Never alias relationship failures as "immune".
    local reasons = ctx.target_protected_reason
    if type(reasons) == "table" then
        local r = reasons[sid] or reasons[tostring(sid)]
        if r == "no_target" or r == "target_dead" or r == "friendly" then
            return true
        end
    end
    return false, "immune"
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Returns ok, reason (reason nil on pass).
-- `slot` may be nil; `ctx` must carry live spell snapshot fields when available.
function BasicRules.check(ctx, spell_id, slot, opts)
    opts = opts or {}
    ctx = ctx or {}
    local sid = tonumber(spell_id) or 0
    local name = (slot and slot.name) or ctx.slot_name or spell_name(sid)

    local ok, why

    ok, why = check_identity(ctx, sid)
    if not ok then return false, why end

    ok, why = check_caster_busy(ctx, sid, slot)
    if not ok then return false, why end

    ok, why = check_gcd_cd(ctx, sid, slot)
    if not ok then return false, why end

    ok, why = check_resources(ctx, sid, name, slot)
    if not ok then return false, why end

    ok, why = check_target_relationship(ctx, sid, slot, name)
    if not ok then return false, why end

    ok, why = check_range(ctx, sid, slot, name)
    if not ok then return false, why end

    -- Facing / LoS after relationship so we do not TraceLine/face-check no-target.
    -- aura_search slots: face/LoS are re-checked against the discovered GUID later.
    if not opts.skip_facing and not slot_has_aura_search(slot) then
        ok, why = check_facing(ctx, sid, slot, name)
        if not ok then return false, why end
    end
    if not opts.skip_los and not slot_has_aura_search(slot) then
        ok, why = check_los(ctx, sid, slot, name)
        if not ok then return false, why end
    end

    -- Immunity map is for current client target — skip until search resolves.
    if not slot_has_aura_search(slot) then
        ok, why = check_immunity(ctx, sid)
        if not ok then return false, why end
    end

    return true, nil
end

-- Lightweight face/LoS recheck for a concrete GUID (cast path final gate).
function BasicRules.guid_cast_gates(guid, opts)
    opts = opts or {}
    if not guid then return true, nil end
    local W = RaijinLab and RaijinLab.World
    if not opts.skip_facing and W and W.is_not_facing_guid then
        -- Only refuse when MEASURED not-facing (nil undetermined allows cast).
        if W.is_not_facing_guid(guid, W.CAST_FACE_HALF_ARC) then
            return false, "facing"
        end
    elseif not opts.skip_facing and W and W.is_facing_guid then
        if W.is_facing_guid(guid, W.CAST_FACE_HALF_ARC) == false then
            return false, "facing"
        end
    end
    if not opts.skip_los and W and W.is_los_guid then
        if W.is_los_guid(guid) == false then
            return false, "los"
        end
    end
    return true, nil
end

if RaijinLab then
    RaijinLab.BasicRules = BasicRules
end

return BasicRules
