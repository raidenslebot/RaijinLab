-- BasicRules: foundational cast gates applied BEFORE user conditions.
--
-- Order of authority for every rotation tick (per slot, top-down priority):
--   1. Slot priority (Engine walks slot 1..N; nothing lower runs until this
--      slot fully cycles: basic deny OR conditions deny OR cast attempt).
--   2. BasicRules.check  (this module - physical / client capability)
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
--
-- DATA FIRST, NAMES LAST (2026-08-03). The English name list below recognised
-- ~15 stock spells on a server with thousands of CUSTOM abilities - every
-- unlisted self-AoE was misclassified as unit-targeted and gated on a target
-- it does not need. World.spell_is_self_area reads the client's own record
-- (Targets dest-location flag / implicit-target ids), so classification now
-- covers every spell the client can cast. The names remain ONLY as the
-- no-runtime fallback, per the Know discipline: a definite data answer wins in
-- both directions; names never override it.
local function name_says_ground_aoe(sid, name)
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

local function is_ground_self_aoe(sid, name)
    local W = RaijinLab and RaijinLab.World
    if W and W.spell_is_self_area then
        local d = W.spell_is_self_area(sid)
        if d ~= nil then return d end
    end
    return name_says_ground_aoe(sid, name)
end

local function is_self_aoe_spell(sid, name)
    local W = RaijinLab and RaijinLab.World
    if W and W.spell_is_self_area then
        local d = W.spell_is_self_area(sid)
        if d ~= nil then return d end
    end
    local n = string.lower(tostring(name or ""))
    if n:find("whirlwind", 1, true) then return true end
    if n:find("thunder clap", 1, true) then return true end
    if n:find("arcane explosion", 1, true) then return true end
    if n:find("fan of knives", 1, true) then return true end
    if n:find("blood boil", 1, true) then return true end
    if n:find("howling blast", 1, true) then return true end
    return name_says_ground_aoe(sid, name)
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

-- Auto Attack is off-GCD swing engagement (StartAttack), never a GCD cast.
local function is_auto_attack(sid, name)
    if tonumber(sid) == 6603 then return true end
    local n = string.lower(tostring(name or ""))
    return n == "auto attack" or n == "attack" or n == "auto-attack"
end
BasicRules.is_auto_attack = is_auto_attack

local function check_gcd_cd(ctx, sid, slot)
    local name = (slot and slot.name) or (ctx and ctx.slot_name)
    -- Auto Attack: always evaluate on GCD (StartAttack is off-GCD). Live bug:
    -- after Consecration, gcd_active skipped AA forever while GCD ticked.
    if is_auto_attack(sid, name) then
        return true
    end
    local off = (slot and slot.off_gcd) or (ctx and ctx.slot_off_gcd)
    -- DATA-DRIVEN off-GCD (2026-08-03): StartRecoveryCategory 0 in the
    -- client's record means this cast never touches the GCD - the user no
    -- longer has to know to mark on-next-swing abilities by hand.
    if not off then
        local W = RaijinLab and RaijinLab.World
        if W and W.spell_off_gcd and W.spell_off_gcd(sid) == true then
            off = true
        end
    end
    -- Pending same spell: wait.
    if ctx and ctx.pending_sid and tonumber(ctx.pending_sid) == sid then
        return false, "pending"
    end
    -- GCD: off_gcd slots bypass. Provisional multi-dot wires are short;
    -- still honor gcd_active so we do not double-cast on real GCD.
    if ctx and ctx.gcd_active and not off then
        return false, "gcd"
    end
    -- Pending OTHER spell: only hard-block when a REAL cast is in flight.
    -- Multi-dot / no_gcd pending must NOT starve the rest of the list
    -- (that invented a 100-180ms rotation delay after every PS/IT wire).
    if ctx and ctx.pending_sid and not off and not ctx.pending_no_gcd then
        if tonumber(ctx.pending_sid) ~= sid then
            return false, "pending_other"
        end
    end
    -- Per-spell CD from live snapshot. Awareness only - no lag pads.
    local cds = ctx and ctx.cooldowns or {}
    local rem = cds[sid]
    if rem == nil then rem = cds[tostring(sid)] end
    rem = num(rem, 0)
    if rem > 0.02 then
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
    -- ROUND 51 (RUNTIME-ONLY RESOURCE GATE): the client's IsUsableSpell is
    -- hardware-gated - calling it from addon Lua taints the client ("tainted
    -- the call of the secure function", live 14:36/14:57) - and it misses rune
    -- costs on custom spells. World.resource_ok uses ONLY runtime natives
    -- (RuneState for rune spells, UnitPower for mana spells) and FAILS OPEN on
    -- unknown. Genuine refusals the gate cannot foresee are bounded by the
    -- client-refusal floor (0.6s) - never a storm.
    local W = RaijinLab and RaijinLab.World
    if W and W.resource_ok then
        local rok, rwhy = W.resource_ok(sid)
        if not rok then return false, rwhy or "no_resource" end
    end
    -- Ground self-AoE (Consecration) and optional-policy slots used to grey
    -- on IsUsableSpell with no target - no longer relevant (no IsUsableSpell).
    local policy = policy_of(slot, ctx)
    if slot_has_aura_search(slot) or policy == "optional" or policy == "forbid"
        or is_ground_self_aoe(sid, name) then
        return true
    end
    local search = ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid
    local hasRt = RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime()
    if not hasRt and not search then
        local u = ctx and ctx.spell_usable
        if type(u) == "table" and (u[sid] == false or u[tostring(sid)] == false) then
            return false, "unusable"
        end
    end
    return true
end

-- Checklist gates that were MISSING entirely until 2026-08-03, all data-driven
-- from World.spell_req (the client's own record). Each fails only on positive
-- evidence; req==nil is unknown and passes (the client still referees), which
-- keeps every one of these safe on a no-runtime session.

-- RUNTIME ONLY (user directive 2026-08-03: "assume everything non-runtime and
-- native is protected and convert everything to runtime"). These gates read
-- player state through runtime natives exclusively - a client Lua call here is
-- both a taint surface ("blocked from an action only available to the Blizzard
-- UI") and, on this client, unreliable. When the runtime cannot answer, the
-- gate PASSES: unknown never invents a refusal.
local function rt(call, ...)
    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime()) then
        return nil
    end
    local ok, v = pcall(RaijinLab.RuntimeCall, RaijinLab, call, ...)
    if not ok then return nil end
    return v
end

-- Weapon requirement: EquippedItemClass 2 = a weapon must be equipped
-- ("You must have a weapon equipped" / "Requires a melee weapon" refusals).
local function check_equipment(ctx, sid)
    local W = RaijinLab and RaijinLab.World
    local req = W and W.spell_req and W.spell_req(sid)
    if not req then return true end
    local cls = tonumber(req.equipclass) or -1
    if cls ~= 2 then return true end          -- only weapon requirements modelled
    -- ctx may carry a pre-read snapshot; otherwise ask the runtime. There is no
    -- client-Lua fallback BY DESIGN - a missing native means unknown, and
    -- unknown passes (the client referees) rather than inventing a block.
    -- EquippedSlotEntry 16 = main hand OCCUPANCY (a display entry, not an item
    -- id - the live main hand read 121696 for a transmogged 4562). Non-zero is
    -- exactly the question this gate asks: is a weapon there at all.
    local mh = ctx and ctx.mainhand_equipped
    if mh == nil then mh = rt("EquippedSlotEntry", 16) end
    if type(mh) ~= "number" then return true end   -- unknown -> pass
    if mh == 0 then return false, "no_weapon" end
    return true
end

-- Shapeshift EXCLUSION mask ("You can't do that while shapeshifted").
-- Only the NOT mask is enforced: Ascension marks caster spells with a positive
-- stance bit whose semantics are unconfirmed (0x200000 observed on stock
-- casters), so the positive mask is never gated until it is pinned. Refusing
-- on an unproven bit would silently stop casting - the exact failure mode this
-- project keeps hitting.
local function check_stance(ctx, sid)
    local W = RaijinLab and RaijinLab.World
    local req = W and W.spell_req and W.spell_req(sid)
    if not req then return true end
    local notmask = tonumber(req.stancesnot) or 0
    if notmask == 0 then return true end
    local form = ctx and ctx.shapeshift_form
    if form == nil then form = rt("ShapeshiftForm") end
    if type(form) ~= "number" or form <= 0 then return true end
    local bit = 2 ^ (form - 1)
    if math.floor(notmask / bit) % 2 == 1 then
        return false, "wrong_form"
    end
    return true
end

-- Required / forbidden auras on caster and target (casterAuraSpell family).
-- Exact now that HasUnitAura reads the unit's own aura array directly.
local function check_aura_requirements(ctx, sid)
    local W = RaijinLab and RaijinLab.World
    local req = W and W.spell_req and W.spell_req(sid)
    if not req then return true end
    local function player_has(aid)
        if ctx and ctx.player_aura_has then return ctx.player_aura_has[aid] end
        -- HasUnitAura returns a NUMBER (stack count, 0 = absent). 0 is truthy
        -- in Lua - the exact footgun that made ObjectQuestGiverStatus lie -
        -- so the comparison must be numeric, never `if has then`.
        local stacks = rt("HasUnitAura", 0, aid)
        if type(stacks) ~= "number" then return nil end
        return stacks > 0
    end
    local need = tonumber(req.casteraura) or 0
    if need > 0 then
        local h = player_has(need)
        if h == false then return false, "need_aura" end
    end
    local forbid = tonumber(req.excaster) or 0
    if forbid > 0 then
        local h = player_has(forbid)
        if h == true then return false, "excluded_aura" end
    end
    return true
end

-- Silence: a spell whose PreventionType is silence cannot be wired while the
-- player is silenced (UNIT_FLAG_SILENCED). Positive evidence only.
local function check_silence(ctx, sid)
    local W = RaijinLab and RaijinLab.World
    local req = W and W.spell_req and W.spell_req(sid)
    if not req then return true end
    if (tonumber(req.prevent) or 0) ~= 1 then return true end
    local flags = ctx and ctx.player_unit_flags
    if flags == nil then flags = rt("UnitFlags") end
    if type(flags) ~= "number" then return true end   -- unknown -> pass
    -- UNIT_FLAG_SILENCED = 0x2000.
    if math.floor(flags / 0x2000) % 2 == 1 then
        return false, "silenced"
    end
    return true
end

-- Player-death / ghost is checked in check_caster_busy via UnitIsDeadOrGhost.
-- Everything else in this module now reads through `rt` only.

-- INTENT vs TARGET RELATIONSHIP (checklist items 2, 7 and 8).
--
-- A harmful ability aimed at a friendly unit, or a heal aimed at a hostile
-- one, is a GUARANTEED client refusal - exactly the class of red error that is
-- supposed to be structurally impossible. Until the spell record was decoded
-- there was no way to know a spell's intent, so this could only be inferred
-- from ctx.target_is_enemy, which cannot tell a heal from a nuke. Now
-- EffectImplicitTargetA[0] says who the spell is for.
--
-- Both sides need POSITIVE evidence: an unknown intent or an unknown
-- relationship passes and lets the client referee. Nothing here guesses.
local function check_intent(ctx, sid, slot)
    local W = RaijinLab and RaijinLab.World
    local cls = W and W.spell_target_class and W.spell_target_class(sid)
    if cls == nil or cls == "any" or cls == "self" then return true end
    -- aura_search resolves its own unit later and is re-gated there.
    if slot_has_aura_search(slot) then return true end
    if ctx and ctx.aura_search_hit and ctx.aura_search_hit.guid then return true end
    if not bool(ctx and ctx.target_exists, false) then return true end
    local is_enemy = ctx and ctx.target_is_enemy
    if is_enemy == nil then return true end          -- relationship unknown
    if cls == "enemy" and is_enemy == false then
        return false, "harmful_on_friendly"
    end
    if cls == "ally" and is_enemy == true then
        return false, "helpful_on_hostile"
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
    -- aura_search slots discover a unit during conditions - do not require a
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
            -- HEAL/BUFF AUTOMATIC FRIENDLY ALLOWANCE (checklist item 4).
            -- "require a target" means a target is REQUIRED, not that it must
            -- be hostile. A friendly selection is exactly right for an
            -- ally-targeted spell, and this gate used to refuse every one of
            -- them - a heal or friendly buff could not be cast at all under the
            -- default policy. Only a spell the record says is ENEMY-targeted is
            -- refused here; check_intent then adjudicates the reverse case.
            local W = RaijinLab and RaijinLab.World
            local cls = W and W.spell_target_class and W.spell_target_class(sid)
            if cls == "ally" or cls == "any" or cls == "self" then return true end
            if cls == nil then return true end   -- intent unknown: client referees
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
    -- Multi-dot: range is validated vs the discovered GUID later - never vs
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

-- Facing: unit-targeted casts only. NEVER hard-block at BasicRules level.
-- Facing is handled at the wire path (attempt_action try_list) where auto-face
-- can turn the player before measuring. BasicRules runs before conditions and
-- has no access to auto-face - blocking here makes auto-face dead code.
-- Instead, always pass; the wire path gates with full auto-face support.
-- Also fix: is_facing_guid returns nil when position data is unavailable.
-- 'not nil' = true was blocking spells when we couldn't even measure facing.
local function check_facing(ctx, sid, slot, name)
    return true  -- deferred to wire path (attempt_action try_list)
end

-- LoS: unit-targeted casts. Fail only on explicit blocked.
local function check_los(ctx, sid, slot, name)
    local policy = policy_of(slot, ctx)
    if policy == "optional" or policy == "forbid" or policy == "corpse" then
        return true
    end
    if is_auto_attack(sid, name) then return true end
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
    -- Only the client-target protection map, and only REAL combat blocks.
    -- aura_search GUID casts are re-checked against the search unit later.
    -- Relationship (no_target / dead / friendly / cannot_attack) is handled
    -- by check_target_relationship - never renamed to "immune" here.
    if not bool(ctx.target_exists, false) then
        return true
    end
    if ctx.aura_search_hit and ctx.aura_search_hit.guid then
        return true
    end
    local reasons = ctx.target_protected_reason
    local r = nil
    if type(reasons) == "table" then
        r = reasons[sid] or reasons[tostring(sid)]
    end
    local Prot = RaijinLab and RaijinLab.Protection
    if Prot and Prot.blocks_cast then
        if not Prot.blocks_cast(r) then return true end
        local why = (Prot.cast_block_why and Prot.cast_block_why(r)) or "immune"
        return false, why
    end
    -- Fallback: use pre-filtered target_protected map (World strips non-cast).
    local prot = ctx.target_protected
    if type(prot) == "table"
        and (prot[sid] == true or prot[tostring(sid)] == true) then
        return false, "immune"
    end
    return true
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
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="identity", why=why}; return false, why end

    ok, why = check_caster_busy(ctx, sid, slot)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="busy", why=why}; return false, why end

    ok, why = check_gcd_cd(ctx, sid, slot)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="gcd_cd", why=why}; return false, why end

    ok, why = check_resources(ctx, sid, name, slot)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="resource", why=why}; return false, why end

    ok, why = check_equipment(ctx, sid)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="equip", why=why}; return false, why end

    ok, why = check_stance(ctx, sid)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="stance", why=why}; return false, why end

    ok, why = check_aura_requirements(ctx, sid)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="aura_req", why=why}; return false, why end

    ok, why = check_silence(ctx, sid)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="silence", why=why}; return false, why end

    ok, why = check_target_relationship(ctx, sid, slot, name)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="target_rel", why=why}; return false, why end

    ok, why = check_intent(ctx, sid, slot)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="intent", why=why}; return false, why end

    ok, why = check_range(ctx, sid, slot, name)
    if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="range", why=why}; return false, why end

    -- Facing / LoS after relationship so we do not TraceLine/face-check no-target.
    -- aura_search slots: face/LoS are re-checked against the discovered GUID later.
    if not opts.skip_facing and not slot_has_aura_search(slot) then
        ok, why = check_facing(ctx, sid, slot, name)
        if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="facing", why=why}; return false, why end
    end
    if not opts.skip_los and not slot_has_aura_search(slot) then
        ok, why = check_los(ctx, sid, slot, name)
        if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="los", why=why}; return false, why end
    end

    -- Immunity map is for current client target - skip until search resolves.
    if not slot_has_aura_search(slot) then
        ok, why = check_immunity(ctx, sid)
        if not ok then BasicRules._last_gate = {sid=sid, name=name, gate="immune", why=why}; return false, why end
    end

    BasicRules._last_gate = nil
    return true, nil
end

-- Lightweight face/LoS recheck for a concrete GUID (cast path final gate).
-- FACING (2026-08-01): NEVER hard-refuse here. The measurement can disagree
-- with the client's real facing (+0x7AC lags visual; Lua GetPlayerFacing
-- no-ops to 0.0). Refusing here starved the wire path (which TURNS the player
-- toward the GUID then wires) - the rotation reported "wait facing:Blood
-- Strike" forever while the user faced the target. Facing is the wire path's
-- job: turn, re-measure, wire regardless (client is final authority). LOS
-- stays: only a confident block refuses pre-wire.
function BasicRules.guid_cast_gates(guid, opts)
    opts = opts or {}
    if not guid then return true, nil end
    local W = RaijinLab and RaijinLab.World
    -- Facing: never block here (deferred to wire path with auto-face).
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
