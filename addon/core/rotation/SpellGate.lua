-- SpellGate: sticky refuse until world fingerprint changes.
-- Range yards are NOT learned here - Executor/World compute real edge-to-edge
-- distance via ObjectPosition + ObjectCombatReach (hitbox). This module only
-- prevents re-spamming the same failed cast while nothing changed.

local SpellGate = {}

-- [sid] = { reason, t, fp, gap, msg }
SpellGate._sticky = SpellGate._sticky or {}
-- [sid] = true  -- free probe used for uncertain custom spells this sticky epoch
SpellGate._probed = SpellGate._probed or {}
SpellGate._refuse_n = SpellGate._refuse_n or {}

local function now()
    return (GetTime and GetTime()) or 0
end

local function num(v, d)
    v = tonumber(v)
    if v == nil then return d end
    return v
end

-- Fingerprint without distance (distance unlock for OOR is separate via gap).
function SpellGate.fingerprint(ctx, sid)
    ctx = ctx or {}
    local exists = ctx.target_exists
    if exists == nil then
        exists = UnitExists and UnitExists("target") or false
    end
    local tguid = "-"
    if exists and UnitGUID then
        tguid = tostring(UnitGUID("target") or "-")
    end
    local power = 0
    if type(ctx.power_amount_by_type) == "table" then
        power = num(ctx.power_amount_by_type.runic, 0)
            + num(ctx.power_amount_by_type.energy, 0)
            + num(ctx.power_amount_by_type.rage, 0)
            + num(ctx.power_amount_by_type.mana, 0)
    else
        power = num(ctx.power_pct, 0)
    end
    local pq = math.floor(power / 5) * 5
    local ust = ctx.user_state
    if not ust and RaijinLab and RaijinLab.World and RaijinLab.World.user_interaction_state then
        local ok, s = pcall(RaijinLab.World.user_interaction_state)
        if ok and s then ust = s end
    end
    return string.format("%s|%s|%s|%d|%s",
        exists and "1" or "0",
        tguid,
        tostring(ust or "free"),
        pq,
        tostring(sid or 0))
end

function SpellGate.normalize_reason(why)
    why = string.lower(tostring(why or ""))
    if why == "" then return "unknown" end
    why = why:gsub("^sticky:", "")
    if why:find("oor", 1, true) or why:find("range", 1, true) or why:find("too far", 1, true) then
        return "oor"
    end
    if why:find("no_resource", 1, true) or why:find("mana", 1, true)
        or why:find("energy", 1, true) or why:find("rage", 1, true)
        or why:find("runic", 1, true) or why:find("power", 1, true) then
        return "no_resource"
    end
    if why:find("not ready", 1, true) or why:find("isn't ready", 1, true)
        or why:find("not yet", 1, true) or why:find("cooldown", 1, true) then
        return "not_ready"
    end
    if why:find("facing", 1, true) or why:find("in front", 1, true) then
        return "facing"
    end
    if why:find("line of sight", 1, true) or why:find("los", 1, true) then
        return "los"
    end
    if why:find("corpse", 1, true) then
        return "corpse"
    end
    if why:find("unusable", 1, true) then
        return "unusable"
    end
    if why:find("no_target", 1, true) or why:find("no target", 1, true) then
        return "no_target"
    end
    if why:find("target_dead", 1, true) or why:find("not_enemy", 1, true) then
        return "bad_target"
    end
    if why:find("cast_failed", 1, true) then
        return "cast_failed"
    end
    if why:find("immune", 1, true) then
        return "immune"
    end
    return "other"
end

function SpellGate.sticky(sid, reason, ctx, extra)
    sid = tonumber(sid) or 0
    if sid <= 0 then return end
    reason = SpellGate.normalize_reason(reason)
    local gap = extra and num(extra.gap, nil) or num(ctx and ctx.target_distance, nil)
    local fp_ctx = ctx
    if (not fp_ctx or fp_ctx.target_exists == nil) and UnitExists and UnitExists("target") then
        fp_ctx = {
            target_exists = true,
            user_state = ctx and ctx.user_state,
            power_pct = ctx and ctx.power_pct,
            power_amount_by_type = ctx and ctx.power_amount_by_type,
        }
    end
    SpellGate._sticky[sid] = {
        reason = reason,
        t = now(),
        fp = SpellGate.fingerprint(fp_ctx, sid),
        gap = gap,
        msg = extra and extra.msg or nil,
    }
    local rn = SpellGate._refuse_n[sid] or {}
    rn[reason] = (rn[reason] or 0) + 1
    SpellGate._refuse_n[sid] = rn
end

function SpellGate.clear(sid)
    sid = tonumber(sid) or 0
    if sid <= 0 then return end
    SpellGate._sticky[sid] = nil
    SpellGate._probed[sid] = nil
end

function SpellGate.clear_all()
    SpellGate._sticky = {}
    SpellGate._probed = {}
end

-- HARD RULE: sticky NEVER blocks reselection. The rotation always re-evaluates
-- every ability top-down. Client GCD/CD/range/conditions are the only gates.
-- Sticky is kept as diagnostic history only (who refused last, why).
function SpellGate.is_blocked(sid, ctx)
    return false, nil
end

function SpellGate.allow_probe(sid)
    sid = tonumber(sid) or 0
    if sid <= 0 then return false end
    if SpellGate._probed[sid] then return false end
    return true
end

function SpellGate.mark_probed(sid)
    sid = tonumber(sid) or 0
    if sid > 0 then SpellGate._probed[sid] = true end
end

function SpellGate.note_landed(sid, gap)
    sid = tonumber(sid) or 0
    if sid <= 0 then return end
    SpellGate.clear(sid)
end

function SpellGate.note_refuse(sid, reason, ctx, extra)
    SpellGate.sticky(sid, reason, ctx, extra)
end

function SpellGate.list_is_idle(ctx, spell_ids)
    if not ctx then return true, "no_ctx" end
    if ctx.user_state and ctx.user_state ~= "free" then
        return true, "user_busy"
    end
    if not ctx.target_exists then
        if ctx._has_no_target_slot then return false, nil end
        return true, "no_target"
    end
    -- Sticky no longer blocks; idle is never "all_sticky".
    if not spell_ids or #spell_ids == 0 then return true, "empty" end
    return false, nil
end

function SpellGate.stats_line()
    local n_sticky = 0
    for _ in pairs(SpellGate._sticky) do n_sticky = n_sticky + 1 end
    return n_sticky, 0
end

function SpellGate.reset_session()
    SpellGate.clear_all()
end

if RaijinLab then RaijinLab.SpellGate = SpellGate end
return SpellGate
