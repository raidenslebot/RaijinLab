-- Rotation priority-list model + evaluator (pure Lua).
-- Slots are ordered top-down: first matching slot wins.

local Engine = {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local n = {}
    for k, v in pairs(t) do
        n[k] = deepcopy(v)
    end
    return n
end

function Engine.new_rotation(name)
    return {
        name = name or "Default",
        enabled = true,
        slots = {},
        -- Always keep one empty trailing slot for the UI "drop next ability" affordance
        ensure_empty_slot = true,
    }
end

function Engine.new_slot(action)
    action = action or {}
    local sid = tonumber(action.spell_id or action.spellId) or 0
    return {
        id = action.id or (tostring(math.random(1, 1e9)) .. "-" .. tostring(math.random(1, 1e9))),
        action_type = action.action_type or "spell", -- spell | item | petaction | macro | custom
        spell_id = sid,
        name = action.name or "Empty",
        icon = action.icon,
        pet_index = action.pet_index,   -- pet-bar slot hint (re-resolved by name at cast)
        pet_cmd = action.pet_cmd,       -- lowercased pet command name (e.g. "attack")
        conditions = action.conditions or {},
        enabled = action.enabled ~= false,
        notes = action.notes or "",
        -- Per-spell casting attributes (user-set in the editor). off_gcd: this
        -- ability ignores the global cooldown, so it may fire during another
        -- spell's GCD. while_casting: it can be cast while you're already
        -- casting/channeling (instants auto-qualify; this forces it on).
        off_gcd = action.off_gcd and true or false,
        while_casting = action.while_casting and true or false,
    }
end

-- A slot counts as "empty" only if it holds no castable action. Non-spell action
-- types (pet commands, macros, custom) legitimately have spell_id 0, so they are
-- NOT empty - otherwise ensure_trailing_empty would silently delete them.
function Engine.slot_is_empty(s)
    if not s then return true end
    local at = s.action_type
    if at and at ~= "spell" and at ~= "item" then return false end
    local sid = s.spell_id
    return (not sid) or sid == 0
end

function Engine.ensure_trailing_empty(rotation)
    if not rotation or not rotation.ensure_empty_slot then return rotation end
    local slots = rotation.slots
    -- Canonical shape: [populated slots..., single trailing empty]. NO interior
    -- empties. Previous impl only trimmed trailing duplicates, so dragging the
    -- last real slot down pushed the empty above it and left an "orphan" empty
    -- above - repeated drags multiplied those interior empties without limit.
    -- Simplest robust fix: filter out ALL empties, then append exactly one.
    local kept = {}
    for i = 1, #slots do
        if not Engine.slot_is_empty(slots[i]) then
            kept[#kept + 1] = slots[i]
        end
    end
    kept[#kept + 1] = Engine.new_slot({ name = "Empty", spell_id = 0 })
    rotation.slots = kept
    return rotation
end

function Engine.set_slot_action(rotation, index, action)
    if not rotation or not rotation.slots[index] then return false end
    local s = rotation.slots[index]
    s.spell_id = action.spell_id or action.spellId or s.spell_id
    s.name = action.name or s.name
    s.icon = action.icon or s.icon
    s.action_type = action.action_type or s.action_type
    if action.pet_index ~= nil then s.pet_index = action.pet_index end
    if action.pet_cmd ~= nil then s.pet_cmd = action.pet_cmd end
    if action.conditions then s.conditions = action.conditions end
    Engine.ensure_trailing_empty(rotation)
    return true
end

function Engine.add_slot(rotation, action)
    rotation = rotation or Engine.new_rotation()
    local slot = Engine.new_slot(action)
    -- insert before trailing empty if present
    local slots = rotation.slots
    if #slots > 0 and slots[#slots].spell_id == 0 then
        table.insert(slots, #slots, slot)
    else
        slots[#slots + 1] = slot
    end
    Engine.ensure_trailing_empty(rotation)
    return slot
end

function Engine.remove_slot(rotation, index)
    if not rotation or not rotation.slots[index] then return false end
    table.remove(rotation.slots, index)
    Engine.ensure_trailing_empty(rotation)
    return true
end

-- Drag-and-drop reorder: move slot from `from` to `to` (1-based indices)
function Engine.move_slot(rotation, from, to)
    local slots = rotation and rotation.slots
    if not slots then return false end
    local n = #slots
    if from < 1 or from > n or to < 1 or to > n or from == to then return false end
    local item = table.remove(slots, from)
    table.insert(slots, to, item)
    Engine.ensure_trailing_empty(rotation)
    return true
end

function Engine.add_condition(rotation, slot_index, condition)
    local slot = rotation and rotation.slots[slot_index]
    if not slot then return false end
    slot.conditions = slot.conditions or {}
    slot.conditions[#slot.conditions + 1] = condition
    return true
end

function Engine.remove_condition(rotation, slot_index, cond_index)
    local slot = rotation and rotation.slots[slot_index]
    if not slot or not slot.conditions or not slot.conditions[cond_index] then return false end
    table.remove(slot.conditions, cond_index)
    return true
end

-- Reorder conditions within a slot (1-based indices)
function Engine.move_condition(rotation, slot_index, from, to)
    local slot = rotation and rotation.slots[slot_index]
    local list = slot and slot.conditions
    if not list then return false end
    local n = #list
    if from < 1 or from > n or to < 1 or to > n or from == to then return false end
    local item = table.remove(list, from)
    table.insert(list, to, item)
    return true
end

function Engine.update_condition(rotation, slot_index, cond_index, patch)
    local slot = rotation and rotation.slots[slot_index]
    local cond = slot and slot.conditions and slot.conditions[cond_index]
    if not cond then return false end
    for k, v in pairs(patch or {}) do
        if k == "args" and type(v) == "table" then
            cond.args = cond.args or {}
            for ak, av in pairs(v) do cond.args[ak] = av end
        else
            cond[k] = v
        end
    end
    return true
end

-- Per-slot target policy from user conditions (NOT from IsSpellInRange nil).
--   require  = need living attackable target + range check (default)
--   optional = Target Existence "any"  - may cast with/without target, no range
--   forbid   = Target Existence "no_target" - must have none, no range
--   corpse   = Corpse Nearby condition - cast on body, not living target range
function Engine.slot_target_policy(slot)
    local policy = "require"
    if not slot then return policy end
    for _, c in ipairs(slot.conditions or {}) do
        if c then
            if c.id == "corpse" then
                return "corpse"
            end
            if c.id == "target_exists" then
                local st = string.lower(tostring((c.args and c.args.state) or "has_target"))
                if st == "no_target" or st == "none" or st == "missing" or st == "no" then
                    policy = "forbid"
                elseif st == "any" or st == "both" or st == "either" then
                    if policy ~= "forbid" then policy = "optional" end
                end
            end
        end
    end
    -- Ground self-AoE (Consecration, DnD, ...) never requires a living target
    -- even if the user forgot Target Existence "any".
    if policy == "require" and slot then
        local nm = string.lower(tostring(slot.name or ""))
        local sid = tonumber(slot.spell_id) or 0
        if nm == "" and sid > 0 and GetSpellInfo then
            local ok, sn = pcall(GetSpellInfo, sid)
            if ok and sn then nm = string.lower(sn) end
        end
        if nm:find("consecration", 1, true) or nm:find("death and decay", 1, true)
            or nm:find("blizzard", 1, true) or nm:find("rain of fire", 1, true)
            or nm:find("hurricane", 1, true) or nm:find("flamestrike", 1, true) then
            policy = "optional"
        end
    end
    return policy
end

-- Slot policy: Auto Face condition present (and not inverted) → cast path may
-- TurnByDelta toward the cast unit before Spell_C. Absence = no auto turn.
function Engine.slot_wants_auto_face(slot)
    if not slot then return false end
    for _, c in ipairs(slot.conditions or {}) do
        if c and c.id == "auto_face" then
            local inv = c.args and (c.args.invert == true or c.args.invert == 1
                or c.args.invert == "true"
                or c.args.want == false or c.args.want == 0 or c.args.want == "false")
            return not inv
        end
    end
    return false
end

-- May this slot cast while the player is in a user-interaction UI?
-- Default NO. Only an explicit player_state condition that matches the current
-- busy state (or "busy"/"any_interaction") is an opt-in.
function Engine.slot_allows_user_busy(slot, user_state)
    user_state = string.lower(tostring(user_state or "free"))
    if user_state == "" or user_state == "free" then return true end
    if not slot then return false end
    for _, c in ipairs(slot.conditions or {}) do
        if c and c.id == "player_state" then
            local st = string.lower(tostring((c.args and c.args.state) or "free"))
            local inv = c.args and (c.args.invert == true or c.args.invert == 1 or c.args.invert == "true")
            local matches = false
            if st == "busy" or st == "any_interaction" or st == "any_busy" then
                matches = true
            elseif st == "free" then
                matches = false -- "is free" cannot authorize a busy cast
            elseif st == user_state then
                matches = true
            end
            if inv then matches = not matches end
            if matches then return true end
        end
    end
    return false
end

-- Built-in readiness (NOT user conditions).
-- Empty condition lists mean "no extra filters" - still only cast when the
-- engine knows the ability can fire (target, not busy, off CD, etc.).
function Engine.spell_ready(ctx, spell_id)
    ctx = ctx or {}
    spell_id = tonumber(spell_id) or 0
    if spell_id == 0 then return false, "no_spell" end

    -- Cast / channel gate, PER SPELL. Most spells can't be cast while you're
    -- casting or channeling, but INSTANTS and spells flagged "castable while
    -- casting" weave freely. ctx.spell_instant[id] auto-detects instants from
    -- GetSpellInfo cast time; ctx.slot_while_casting is the per-slot override.
    -- This is what lets the rotation keep the highest-priority instant flowing
    -- during a long cast instead of stalling the whole list.
    if ctx.is_casting or ctx.is_channeling then
        local instant = false
        local si = ctx.spell_instant
        if type(si) == "table" then
            instant = (si[spell_id] == true or si[tostring(spell_id)] == true)
        end
        if not instant and not ctx.slot_while_casting then
            return false, ctx.is_casting and "casting" or "channeling"
        end
    end

    -- In-flight pending: never re-select the SAME spell while its cast is
    -- awaiting confirm. GCD provisional (net_grace) blocks other non-offGCD
    -- casts so lag cannot multi-fire the list.
    if ctx.pending_sid and tonumber(ctx.pending_sid) == spell_id then
        return false, "pending"
    end

    -- User interaction hard gate: loot/gossip/quest/trade/AH/craft/etc.
    -- Never interrupt unless this slot opted in via player_state.
    local ust = ctx.user_state
    if ust and ust ~= "free" and not ctx.slot_allows_busy then
        return false, "user_busy"
    end

    -- No sticky lockouts. Full re-eval every tick; client GCD/CD/range decide.

    -- Target policy: ONLY corpse / Target Existence any|no_target may cast
    -- without a living attackable enemy. IsSpellInRange==nil is NOT an opt-out
    -- (that was casting self-buffs with no target arbitrarily).
    local policy = ctx.slot_target_policy
    if not policy then
        if ctx.slot_requires_corpse then
            policy = "corpse"
        elseif ctx.slot_allows_no_target then
            policy = "optional"
        else
            policy = "require"
        end
    end
    local needs_enemy = (policy == "require")
    -- aura_search_hit.guid is a valid cast target without client TargetUnit /
    -- nameplates. Multi-dot must never require UnitExists("target").
    local search_guid = ctx.aura_search_hit and ctx.aura_search_hit.guid
    if needs_enemy and ctx.require_attackable_target then
        if not ctx.target_exists and not search_guid then
            return false, "no_target"
        end
        if ctx.target_exists and not search_guid then
            if ctx.target_is_dead then
                return false, "target_dead"
            end
            if ctx.target_is_enemy == false then
                return false, "not_enemy"
            end
        end
    end

    local cds = ctx.cooldowns or {}
    local rem = cds[spell_id]
    if rem == nil then rem = cds[tostring(spell_id)] end
    rem = tonumber(rem) or 0
    -- Lag-aware: bar can clear a few ms before the server accepts the next cast.
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

    -- Global cooldown gate. off_gcd slots bypass. Pending cast also blocks.
    if ctx.gcd_active and not ctx.slot_off_gcd then
        return false, "gcd"
    end
    if ctx.pending_sid and not ctx.slot_off_gcd then
        -- Any non-offGCD ability waits while a cast is in flight (not just same sid).
        if tonumber(ctx.pending_sid) ~= spell_id then
            return false, "pending_other"
        end
    end

    local known = ctx.known_spells
    if type(known) == "table" then
        local k = known[spell_id]
        if k == nil then k = known[tostring(spell_id)] end
        if k == false then return false, "unknown" end
    end

    -- Out of range. Skipped only when policy says no living-target range
    -- (Target Existence any/no_target, or corpse - corpse range is applied
    -- separately by the executor).
    local skip_range = ctx.slot_skip_range
        or policy == "optional" or policy == "forbid" or policy == "corpse"
    if not skip_range then
        local ir = ctx.spell_in_range
        if type(ir) == "table" then
            local r = ir[spell_id]
            if r == nil then r = ir[tostring(spell_id)] end
            if r == false then return false, "oor" end
        end
    end

    -- ------------------------------------------------------------------
    -- Auto-castable gate. Implicitly applied to EVERY spell so the rotation
    -- never wastes a GCD trying to cast something that can't land, and always
    -- fires the highest-priority spell that CAN. Enabled by ctx.auto_castable
    -- (the executor sets it from RaijinLabDB.auto_castable, default on). Each
    -- check blocks ONLY on a definitive negative so an unknown/undeterminable
    -- state never suppresses a valid cast ("cast as soon as possible, never
    -- try if impossible").
    -- ------------------------------------------------------------------
    -- Multi-dot / optional / ground AoE: GUID or feet cast does not require
    -- client target; IsUsableSpell greys without one — never unusable then.
    local search_hit = ctx.aura_search_hit and ctx.aura_search_hit.guid
    local policy = ctx.slot_target_policy
    if not policy then
        if ctx.slot_requires_corpse then policy = "corpse"
        elseif ctx.slot_allows_no_target then policy = "optional"
        else policy = "require" end
    end
    local skip_usable_grey = search_hit
        or policy == "optional" or policy == "forbid" or policy == "corpse"
    if not skip_usable_grey then
        local sn = tostring(ctx.slot_name or "")
        local low = string.lower(sn)
        if low:find("consecration", 1, true) or low:find("death and decay", 1, true)
            or low:find("blizzard", 1, true) or low:find("rain of fire", 1, true) then
            skip_usable_grey = true
        end
    end
    if ctx.auto_castable then
        -- (1) Usable now: IsUsableSpell (resources / stance / form). Authoritative
        --     client check; false means genuinely not castable this instant.
        --     Exception: multi-dot / optional / ground feet casts (bar greys).
        local u = ctx.spell_usable
        if type(u) == "table" and (u[spell_id] == false or u[tostring(spell_id)] == false) then
            if not skip_usable_grey then
                return false, "unusable"
            end
        end

        -- Target-directed checks apply only to spells that actually target the
        -- enemy (World.spell_targeted), so self-buffs/cooldowns are never gated
        -- on LoS or immunity. Skip when casting on a search GUID (not client target).
        local tt = ctx.spell_targeted
        local is_targeted = type(tt) == "table"
            and (tt[spell_id] == true or tt[tostring(spell_id)] == true)
        if is_targeted and ctx.target_exists and not search_hit then
            -- (2) Line of sight: block only on an explicit false.
            if ctx.target_in_los == false then
                return false, "los"
            end
            -- (3) Real combat protection only (not no_target/friendly/cannot_attack).
            local reasons = ctx.target_protected_reason
            local r = type(reasons) == "table"
                and (reasons[spell_id] or reasons[tostring(spell_id)]) or nil
            local Prot = RaijinLab and RaijinLab.Protection
            if Prot and Prot.blocks_cast and Prot.blocks_cast(r) then
                local why = (Prot.cast_block_why and Prot.cast_block_why(r)) or "immune"
                return false, why
            elseif (not Prot or not Prot.blocks_cast) then
                local prot = ctx.target_protected
                if type(prot) == "table"
                    and (prot[spell_id] == true or prot[tostring(spell_id)] == true) then
                    return false, "immune"
                end
            end
        end
    elseif ctx.strict_usable then
        -- Back-compat: honor the old explicit flag when auto_castable is off.
        local u = ctx.spell_usable or {}
        if (u[spell_id] == false or u[tostring(spell_id)] == false) and not search_hit then
            return false, "unusable"
        end
    end

    return true, nil
end

-- Evaluate: strict slot priority (slot 1 highest). For each enabled slot:
--   1) BasicRules (physical / client capability) — BEFORE user conditions so
--      expensive discovery (aura_search) never runs when GCD/CD/range already deny.
--   2) User conditions (Conditions.evaluate_all)
--   3) First fully-confirmed ready slot wins; denied slots fall through immediately.
-- Empty conditions = always pass (conditions only restrict, never required).
-- conditions_mod must provide evaluate_all(list, ctx)
-- opts.ignore_ready = true -> skip built-in readiness (tests / force)
function Engine.evaluate(rotation, ctx, conditions_mod, opts)
    if not rotation or rotation.enabled == false then
        return nil, "rotation_disabled"
    end
    conditions_mod = conditions_mod or (RaijinLab and RaijinLab.Conditions)
    if not conditions_mod then
        return nil, "no_conditions_module"
    end
    opts = opts or {}
    ctx = ctx or {}
    local slots = rotation.slots or {}
    local last_skip = nil
    local Basic = RaijinLab and RaijinLab.BasicRules
    -- opts.exclude = { [index]=true } lets the executor re-evaluate with a slot
    -- removed after that slot was selected but rejected at cast time, so the
    -- next-highest castable slot fires THIS tick (strict priority even when a
    -- live cast-time check disagrees with the tick snapshot).
    local exclude = opts.exclude
    -- Clear the per-slot scratch fields once we're done (see below).
    local function done(result, why)
        ctx.slot_spell_id, ctx.slot_index, ctx.slot_name = nil, nil, nil
        ctx.slot_off_gcd, ctx.slot_while_casting = nil, nil
        ctx.slot_requires_corpse, ctx.slot_allows_no_target = nil, nil
        ctx.slot_skip_range, ctx.slot_target_policy = nil, nil
        ctx.slot_allows_busy = nil
        return result, why
    end
    local user_state = tostring(ctx.user_state or "free")
    for i = 1, #slots do
        local slot = slots[i]
        local sid = tonumber(slot.spell_id) or 0
        if slot.enabled ~= false and sid ~= 0 and not (exclude and exclude[i]) then
            -- Set the per-slot fields DIRECTLY on the shared ctx. Conditions and
            -- spell_ready only READ ctx, so the old per-slot deepcopy (a full
            -- recursive copy of every aura/cooldown/protection table, once per
            -- slot, at 50 Hz) was pure waste. Fields are cleared on return.
            ctx.slot_spell_id = sid
            ctx.slot_index = i
            ctx.slot_name = slot.name
            ctx.slot_off_gcd = slot.off_gcd and true or false
            ctx.slot_while_casting = slot.while_casting and true or false
            -- Isolate multi-dot search per slot (never leak into lower priority).
            ctx.aura_search_hit = nil
            ctx._aura_search_retargeted = nil
            -- Target / range policy from conditions only (see slot_target_policy).
            local policy = Engine.slot_target_policy(slot)
            ctx.slot_target_policy = policy
            ctx.slot_requires_corpse = (policy == "corpse")
            ctx.slot_allows_no_target = (policy == "optional" or policy == "forbid")
            ctx.slot_skip_range = (policy ~= "require")
            -- User-busy opt-in via player_state condition only.
            ctx.slot_allows_busy = Engine.slot_allows_user_busy(slot, user_state)
            local tr = opts.trace
            if user_state ~= "free" and not ctx.slot_allows_busy then
                if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "user_busy", why = user_state } end
                last_skip = "user_busy"
            else
                -- ----------------------------------------------------------
                -- PHASE A: BasicRules (before conditions / discovery work).
                -- Skip face/LoS here when aura_search will pick a unit later;
                -- those re-run after conditions with the resolved GUID.
                -- ----------------------------------------------------------
                local has_aura_search = false
                for _, c in ipairs(slot.conditions or {}) do
                    if c and c.id == "aura_search" then has_aura_search = true; break end
                end
                local basic_ok, basic_why = true, nil
                if not opts.ignore_ready then
                    if Basic and Basic.check then
                        basic_ok, basic_why = Basic.check(ctx, sid, slot, {
                            skip_facing = has_aura_search,
                            skip_los = has_aura_search,
                        })
                    else
                        -- Fallback: legacy spell_ready without face/LoS of search.
                        basic_ok, basic_why = Engine.spell_ready(ctx, sid)
                    end
                end
                if not basic_ok then
                    if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "basic_deny", why = basic_why } end
                    last_skip = basic_why or "basic_deny"
                    -- Slot fully cycled (denied). Next priority slot only.
                else
                    -- ------------------------------------------------------
                    -- PHASE B: user conditions (may set aura_search_hit).
                    -- ------------------------------------------------------
                    local pass, err = conditions_mod.evaluate_all(slot.conditions, ctx)
                    if pass then
                        local want_auto_face = Engine.slot_wants_auto_face(slot)
                        -- After aura_search: only hard-block LoS here. Facing is
                        -- handled in Executor (optional Auto Face condition may turn).
                        if has_aura_search and ctx.aura_search_hit and ctx.aura_search_hit.guid
                            and Basic and Basic.guid_cast_gates then
                            local gok, gwhy = Basic.guid_cast_gates(ctx.aura_search_hit.guid, {
                                -- Skip face precheck when Auto Face will turn; otherwise
                                -- still skip here so multi-cand Executor can try next GUID.
                                skip_facing = true,
                            })
                            if not gok and gwhy == "los" then
                                -- Try next candidate with clear LoS if any.
                                local cands = ctx.aura_search_hit.candidates
                                local picked = nil
                                if type(cands) == "table" then
                                    local W = RaijinLab and RaijinLab.World
                                    for ci = 1, #cands do
                                        local c = cands[ci]
                                        if c and c.guid and (not W or not W.is_los_guid
                                            or W.is_los_guid(c.guid) ~= false) then
                                            picked = c
                                            break
                                        end
                                    end
                                end
                                if picked then
                                    ctx.aura_search_hit.guid = picked.guid
                                    ctx.aura_search_hit.token = picked.token
                                    ctx.aura_search_hit.dist = picked.dist
                                    gok = true
                                else
                                    if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "basic_deny", why = gwhy } end
                                    last_skip = gwhy or "basic_deny"
                                    ctx.aura_search_hit = nil
                                end
                            end
                            if gok ~= false and ctx.aura_search_hit then
                                local action = {
                                    index = i,
                                    slot = slot,
                                    spell_id = sid,
                                    name = slot.name,
                                    action_type = slot.action_type or "spell",
                                    target_policy = policy,
                                    aura_search_hit = ctx.aura_search_hit,
                                    auto_face = want_auto_face,
                                }
                                if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "CAST" } end
                                return done(action, nil)
                            end
                        else
                            local action = {
                                index = i,
                                slot = slot,
                                spell_id = sid,
                                name = slot.name,
                                action_type = slot.action_type or "spell",
                                target_policy = policy,
                                aura_search_hit = ctx.aura_search_hit,
                                auto_face = want_auto_face,
                            }
                            if opts.ignore_ready then
                                if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "CAST" } end
                                return done(action, nil)
                            end
                            -- Final spell_ready pass (LoS on client target, immunity, ...).
                            local ready, why = Engine.spell_ready(ctx, sid)
                            if ready then
                                if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "CAST" } end
                                return done(action, nil)
                            end
                            if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "not_ready", why = why } end
                            last_skip = why or "not_ready"
                        end
                    else
                        if tr then tr.n = tr.n + 1; tr[tr.n] = { i = i, name = slot.name, sid = sid, verdict = "cond_fail", why = err } end
                        last_skip = err or ("cond:" .. tostring(slot.conditions and slot.conditions[1] and slot.conditions[1].id))
                    end
                end
            end
        end
    end
    return done(nil, last_skip or "no_match")
end

-- Serialize / deserialize for SavedVariables.
-- Use the persistence sanitizer when available so a rotation can never carry a
-- function/frame/cycle into RaijinLabDB (which would fail the whole file write).
-- Falls back to a plain deepcopy if Persistence.lua hasn't loaded yet.
function Engine.serialize(rotation)
    if RaijinLab and RaijinLab.Sanitize then
        return RaijinLab.Sanitize(rotation)
    end
    return deepcopy(rotation)
end

function Engine.deserialize(data)
    if type(data) ~= "table" then
        return Engine.new_rotation()
    end
    local r = Engine.new_rotation(data.name)
    r.enabled = data.enabled ~= false
    r.ensure_empty_slot = data.ensure_empty_slot ~= false
    r.slots = {}
    -- Look up the condition-registry migration entry point once. It's
    -- optional (Conditions may not be loaded in bare unit-test contexts)
    -- but when present it upgrades hidden-legacy condition ids to their
    -- current unified equivalents on load, so old saved rotations stop
    -- carrying the deprecated ids forward with every save/load cycle.
    local Conditions = RaijinLab and RaijinLab.Conditions
    local migrate = Conditions and Conditions.migrate_record or nil
    for i, s in ipairs(data.slots or {}) do
        r.slots[i] = Engine.new_slot(s)
        r.slots[i].id = s.id or r.slots[i].id
        r.slots[i].conditions = deepcopy(s.conditions or {})
        if migrate then
            for _, c in ipairs(r.slots[i].conditions) do migrate(c) end
        end
        r.slots[i].enabled = s.enabled ~= false
        r.slots[i].notes = s.notes or ""
    end
    Engine.ensure_trailing_empty(r)
    return r
end

if RaijinLab then
    RaijinLab.RotationEngine = Engine
end

return Engine
