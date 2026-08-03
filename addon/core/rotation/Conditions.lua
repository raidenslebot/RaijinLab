-- Pure condition registry + evaluation (no FrameScript dependency).
-- Loaded by the addon and by unit tests via lupa.
--
-- Every condition receives:
--   ctx  = evaluation context (numbers/bools/tables supplied by World/Runtime glue)
--   args = condition parameters (user-edited in the UI)
-- Returns true if the condition PASSES (slot may fire).
--
-- Design (2026-07 pass):
--   Split-per-operator conditions were consolidated into ONE condition per
--   semantic concept, with an `op` cycle (>=, <=, =, in_range, etc.) picking
--   the operator. Deleted-pure-inverse pairs (out_of_combat, is_standing, ...)
--   were folded into their positive form; the universal `invert` toggle
--   handles the negation. Every removed id is still registered as a
--   `hidden = true` shim so saved rotations keep evaluating, and
--   Engine.deserialize upgrades stored data via Conditions.migrate_record.
--
--   The visible condition catalog (Conditions.list) went from ~40 entries
--   to ~20, each more powerful. Total capability is unchanged.

local Conditions = {}
Conditions._defs = {}

local function clamp(n, a, b)
    if n < a then return a end
    if n > b then return b end
    return n
end

local function num(v, d)
    v = tonumber(v)
    if v == nil then return d end
    return v
end

local function bool(v, d)
    if v == nil then return d end
    return not not v
end

function Conditions.register(id, def)
    assert(type(id) == "string" and id ~= "", "condition id required")
    assert(type(def) == "table" and type(def.eval) == "function", "def.eval required")
    def.id = id
    def.name = def.name or id
    def.category = def.category or "General"
    def.params = def.params or {}
    Conditions._defs[id] = def
end

function Conditions.get(id)
    return Conditions._defs[id]
end

-- Public catalog for the UI picker. Skips `hidden = true` defs (legacy
-- back-compat aliases that still evaluate for saved rotations but shouldn't
-- clutter the user-facing list).
function Conditions.list()
    local out = {}
    for id, def in pairs(Conditions._defs) do
        if not def.hidden then
            out[#out + 1] = {
                id = id,
                name = def.name,
                category = def.category,
                params = def.params,
                description = def.description or "",
            }
        end
    end
    table.sort(out, function(a, b)
        if a.category == b.category then return a.name < b.name end
        return a.category < b.category
    end)
    return out
end

-- Full registry including hidden defs - for tests and migration paths.
function Conditions.list_all()
    local out = {}
    for id, def in pairs(Conditions._defs) do
        out[#out + 1] = { id = id, name = def.name, hidden = def.hidden == true }
    end
    return out
end

local function want_true(args)
    -- Universal invert: args.invert = true means "condition must FAIL to pass
    -- the slot". args.want = false is a legacy synonym.
    if args == nil then return true end
    if args.invert == true or args.invert == 1 or args.invert == "true" then
        return false
    end
    if args.want == false or args.want == 0 or args.want == "false" then
        return false
    end
    return true
end

function Conditions.evaluate_one(cond, ctx)
    if type(cond) ~= "table" or type(cond.id) ~= "string" then
        return false, "invalid_condition"
    end
    local def = Conditions._defs[cond.id]
    if not def then
        return false, "unknown_condition:" .. tostring(cond.id)
    end
    ctx = ctx or {}
    local args = cond.args or {}
    local ok, result = pcall(def.eval, ctx, args)
    if not ok then
        return false, "error:" .. tostring(result)
    end
    result = not not result
    if not want_true(args) then
        result = not result
    end
    return result, nil
end

function Conditions.evaluate_all(list, ctx)
    if type(list) ~= "table" or #list == 0 then
        return true, nil
    end
    -- Target-acquisition conditions MUST run first. Example: Icy Touch with
    -- (1) aura missing on target + (2) aura_search. If (1) runs first while the
    -- current target already has Frost Fever, the slot fails and never
    -- retargets. Running aura_search first snaps to a unit missing the debuff;
    -- then (1) sees the new target and passes.
    local order = {}
    for i = 1, #list do order[i] = i end
    table.sort(order, function(a, b)
        local function prio(id)
            id = tostring(id or "")
            if id == "aura_search" then return 0 end
            return 1
        end
        local pa = prio(list[a] and list[a].id)
        local pb = prio(list[b] and list[b].id)
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    for oi = 1, #order do
        local i = order[oi]
        local pass, err = Conditions.evaluate_one(list[i], ctx)
        if not pass then
            return false, err or (list[i] and list[i].id)
        end
    end
    return true, nil
end

function Conditions.default_args(id)
    local def = Conditions._defs[id]
    if not def then return {} end
    local args = { invert = false }
    for _, p in ipairs(def.params) do
        args[p.key] = p.default
    end
    return args
end

------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------

-- Numeric comparison with a user-picked operator. Called by every
-- op-carrying condition (health_pct, power, target_health_pct, ...).
-- `left` is the observed value, `args.value` / `args.value_max` supply
-- thresholds. Unknown ops fail closed (return false) - a typo can't ever
-- silently pass a slot.
local function cmp_op(left, args, defaults)
    defaults = defaults or {}
    local op = args.op or defaults.op or ">="
    if type(op) == "string" then op = string.lower(op) end
    local v = num(args.value, defaults.value or 0)
    if op == ">=" or op == "ge" or op == "atleast" then return left >= v end
    if op == "<=" or op == "le" or op == "atmost"  then return left <= v end
    if op == ">"  or op == "gt" or op == "above"   then return left >  v end
    if op == "<"  or op == "lt" or op == "below"   then return left <  v end
    if op == "="  or op == "==" or op == "eq" or op == "equals" then return left == v end
    if op == "in_range" or op == "between" or op == "range" then
        local vmax = num(args.value_max, defaults.value_max or v)
        if vmax < v then vmax, v = v, vmax end
        return left >= v and left <= vmax
    end
    return false
end

-- Cycle definitions consumed by the Editor (via param.cycle). Kept here
-- so the runtime is the single source of truth for what operators each
-- condition accepts; Editor just displays whatever list we hand it.
local OP_CYCLE_NUMERIC     = { ">=", "<=", "=", ">", "<", "in_range" }
local OP_CYCLE_DISTANCE    = { "<=", ">=", ">", "<", "=" }
local OP_CYCLE_COUNT       = { ">=", "<=", "=", ">", "<" }
local OP_CYCLE_COOLDOWN    = { "ready", "on_cd", ">=", "<=", ">", "<" }
local POWER_TYPE_CYCLE     = { "primary", "mana", "rage", "energy", "runic", "focus", "runes", "combo_points", "felfury" }
local CORPSE_STATE_CYCLE   = { "available", "consumed", "any" }

-- show_if predicates for conditional param visibility in the editor. Each
-- returns true when the param should be shown given the current args. The
-- editor calls these to hide irrelevant controls (e.g. the "Max" field only
-- matters when the operator is in_range).
local function only_in_range(args) return string.lower(tostring(args.op or "")) == "in_range" end
local function cd_uses_seconds(args)
    local op = string.lower(tostring(args.op or "ready"))
    return op ~= "ready" and op ~= "on_cd" and op ~= "oncd"
end
local function aura_is_present(args) return string.lower(tostring(args.state or "present")) ~= "missing" end
local function aura_rem_uses_value(args)
    if not aura_is_present(args) then return false end
    local op = string.lower(tostring(args.remaining_op or "any"))
    if op == "any" or op == "" or op == "none" then
        -- Legacy min_remaining still shows the value field when set.
        return num(args.min_remaining, 0) > 0
    end
    return true
end
local function aura_rem_uses_max(args)
    if not aura_is_present(args) then return false end
    return string.lower(tostring(args.remaining_op or "any")) == "in_range"
end
local AURA_REM_OP_CYCLE = { "any", ">=", "<=", "=", ">", "<", "in_range" }
local MODE_CYCLE           = { "pct", "units" }
local UNIT_CYCLE           = { "player", "target" }
local KIND_CYCLE           = { "buff", "debuff" }
local STATE_CYCLE          = { "present", "missing" }
local AUTO_MODE_CYCLE      = { "melee", "ranged", "any" }
local SCHOOL_CYCLE         = { "auto", "physical", "holy", "fire", "nature", "frost", "shadow", "arcane", "magic" }

-- Aura table helpers (unchanged from prior revision).
local function _trim(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _find_name_ci(table_, needle)
    if not needle or needle == "" then return nil end
    if table_[needle] ~= nil then return needle end
    local trimmed = _trim(needle)
    if trimmed ~= needle and table_[trimmed] ~= nil then return trimmed end
    local lower = string.lower(trimmed or needle)
    for k, _ in pairs(table_) do
        if type(k) == "string" and string.lower(k) == lower then return k end
    end
    return nil
end

local function _resolve_spell_name(id)
    if not id or id == 0 or not GetSpellInfo then return nil end
    local ok, n = pcall(GetSpellInfo, id)
    if ok and type(n) == "string" and n ~= "" then return n end
    return nil
end

-- Presence / stacks / remaining for an aura.
-- When spell_id > 0 it is the APPLICATION id (authoritative). Prefer exact id
-- keys from UnitBuff/UnitDebuff. Fall back to the name of THAT id only (never
-- to an unrelated name field that might describe a different spell).
-- When spell_id is 0, match by the name field alone.
local function aura_has(table_, id, name)
    if not table_ then return false end
    id = tonumber(id) or 0
    if id ~= 0 then
        if table_[id] == true or table_[tostring(id)] == true then return true end
        -- Name of this exact application id (not a separate user name that may
        -- have been filled from a different skill with the same label).
        local n = _resolve_spell_name(id)
        if n and table_[n] == true then return true end
        return false
    end
    local hit = _find_name_ci(table_, name)
    if hit and table_[hit] == true then return true end
    return false
end

local function aura_stat(stat_table, id, name)
    if not stat_table then return 0 end
    id = tonumber(id) or 0
    if id ~= 0 then
        local v = stat_table[id] or stat_table[tostring(id)]
        if v ~= nil then return num(v, 0) end
        local n = _resolve_spell_name(id)
        if n and stat_table[n] ~= nil then return num(stat_table[n], 0) end
        return 0
    end
    local hit = _find_name_ci(stat_table, name)
    if hit and stat_table[hit] ~= nil then return num(stat_table[hit], 0) end
    return 0
end

-- Power lookup (percent or raw units), consumed by the unified `power`
-- condition and the legacy power shims. Understanding for readers:
--   * `power_type` names must line up with World.lua's POWER_TYPES /
--     POWER_CUSTOM (World populates ctx.power_by_type / ctx.power_amount_by_type
--     with matching keys).
--   * "primary" is a synonym for "the pool the class uses right now" and
--     falls back to ctx.power_pct / ctx.power_amount.
--   * Unknown power_type also falls back to primary - so a typo doesn't
--     hard-fail; user gets a still-meaningful comparison against primary.
-- Numeric power indices (from very old saved data) mapped to the NAME keys World
-- uses for power_amount_by_type / power_amount_max_by_type, so units-mode and the
-- absent-pool guard resolve the right pool (those tables are name-keyed only).
-- 0 is intentionally left numeric so it keeps meaning "primary (current pool)".
local _PTYPE_BY_INDEX = {
    [1] = "rage", [2] = "focus", [3] = "energy",
    [4] = "happiness", [5] = "runes", [6] = "runic",
}
local function _norm_power_type(v)
    if v == nil or v == "" then return "primary" end
    if type(v) == "number" then return _PTYPE_BY_INDEX[v] or v end
    return string.lower(tostring(v))
end

local function _power_pct(ctx, ptype)
    if ptype == "primary" or ptype == 0 or ptype == "0" then
        return num(ctx.power_pct, 100)
    end
    local by = ctx.power_by_type or {}
    local v = by[ptype] or by[tostring(ptype)]
    if v == nil then return num(ctx.power_pct, 100) end
    return num(v, 100)
end

local function _power_units(ctx, ptype)
    if ptype == "primary" or ptype == 0 or ptype == "0" then
        return num(ctx.power_amount, 0)
    end
    local by = ctx.power_amount_by_type or {}
    local v = by[ptype] or by[tostring(ptype)]
    if v == nil then return num(ctx.power_amount, 0) end
    return num(v, 0)
end

local function power_value(ctx, args)
    local ptype = _norm_power_type(args.power_type or args.ptype)
    local mode = string.lower(tostring(args.mode or "pct"))
    if mode == "units" or mode == "amount" or mode == "raw" then
        return _power_units(ctx, ptype)
    end
    return _power_pct(ctx, ptype)
end

------------------------------------------------------------
-- Logic placeholders
------------------------------------------------------------

Conditions.register("always", {
    name = "Always (placeholder)",
    category = "Logic",
    description = "Always true. Empty conditions already cast; use this only as an explicit no-op placeholder.",
    eval = function() return true end,
})

Conditions.register("never", {
    name = "Never (disable slot)",
    category = "Logic",
    description = "Always false - skips this slot without removing the spell. Toggle Invert or Remove when done.",
    eval = function() return false end,
})

------------------------------------------------------------
-- Combat + physical self state
------------------------------------------------------------

Conditions.register("in_combat", {
    name = "In Combat",
    category = "Combat",
    description = "Player is in combat. Toggle Invert for 'out of combat'.",
    eval = function(ctx) return bool(ctx.in_combat, false) end,
})

Conditions.register("is_moving", {
    name = "Is Moving",
    category = "Self",
    description = "Player is moving. Toggle Invert for 'standing still'.",
    eval = function(ctx) return bool(ctx.is_moving, false) end,
})

Conditions.register("is_mounted", {
    name = "Is Mounted",
    category = "Self",
    description = "Player is on a mount. Toggle Invert for 'dismounted'.",
    eval = function(ctx) return bool(ctx.is_mounted, false) end,
})

-- Player interaction / busy state. ALSO the only way to allow the rotation to
-- cast while the player is in a user-action UI (loot, gossip, quest, trade,
-- auction, crafting, bank, mail, taxi, ...). Default engine policy: never
-- interrupt those. A slot with player_state matching the current busy state
-- is an explicit opt-in to cast during that state.
local PLAYER_STATE_CYCLE = {
    "free", "busy", "looting", "gossip", "quest", "merchant", "trade",
    "auction", "crafting", "bank", "mail", "taxi", "trainer", "dead",
    "spell_targeting", "cursor", "popup", "stable", "petition", "tabard",
    "item_text",
}

Conditions.register("player_state", {
    name = "Player State",
    category = "Self",
    description = "Player interaction state. free = not in loot/gossip/quest/trade/AH/craft/etc. busy = any of those. Specific states match exactly. Slots with this condition matching a busy state may cast during that UI (opt-in); all other slots hard-block so the rotation never interrupts you.",
    params = {
        { key = "state", type = "string", default = "free", label = "State", cycle = PLAYER_STATE_CYCLE },
    },
    eval = function(ctx, args)
        local want = string.lower(tostring((args and args.state) or "free"))
        local cur = string.lower(tostring(ctx.user_state or "free"))
        if want == "free" then return cur == "free" end
        if want == "busy" or want == "any_interaction" or want == "any_busy" then
            return cur ~= "free"
        end
        return cur == want
    end,
})

Conditions.register("is_casting", {
    name = "Is Casting / Channeling",
    category = "Self",
    description = "Player is currently casting or channeling. Set include_channel=false to check ONLY casts (no channels). Toggle Invert for 'not casting'.",
    params = {
        { key = "include_channel", type = "bool", default = true, label = "Include channels" },
    },
    eval = function(ctx, args)
        local include_channel = args.include_channel
        if include_channel == nil then include_channel = true end
        if bool(ctx.is_casting, false) then return true end
        if include_channel and bool(ctx.is_channeling, false) then return true end
        return false
    end,
})

Conditions.register("has_pet", {
    name = "Has Pet",
    category = "Self",
    eval = function(ctx) return bool(ctx.has_pet, false) end,
})

Conditions.register("form_equals", {
    name = "Stance / Form Equals",
    category = "Self",
    description = "GetShapeshiftForm() index (0=none). Warrior: 1=Battle, 2=Defensive, 3=Berserker typically. Prefer this over aura checks for stances - forms often never appear in UnitBuff.",
    params = { { key = "form", type = "number", default = 0, label = "Form index" } },
    eval = function(ctx, args)
        return num(ctx.form, 0) == num(args.form, 0)
    end,
})

Conditions.register("auto_repeat", {
    name = "Auto-Attack / Auto-Shot",
    category = "Self",
    description = "Melee auto-attack (Attack) or ranged auto-repeat (Auto Shot / wand Shoot) is currently active. Pick Melee, Ranged, or Any. Toggle Invert for 'not attacking'. Auto Search (with Invert ON): when not autoing, engage the current target OR the nearest hostile within auto-attack range — zero target acquisition (the client's selection is never changed).",
    params = {
        { key = "mode", type = "string", default = "melee", label = "Repeat type", cycle = AUTO_MODE_CYCLE },
        { key = "auto_search", type = "bool", default = false, label = "Auto Search" },
    },
    eval = function(ctx, args)
        local mode = string.lower(tostring(args.mode or "melee"))
        -- ROUND 49 (TAINT): IsCurrentSpell / IsAutoRepeatSpell are PROTECTED
        -- FrameScript APIs — calling them from addon Lua taints the client
        -- ("RaijiNLab tainted the call of the secure function 'bl'" + other
        -- addons crashing). All auto-state reads go through the RUNTIME's
        -- native current-spells walk (pure client memory, never protected):
        --   IsAttacking      -> "1|0xGUID" while melee auto-attacking
        --   AutoRepeatSpell  -> current auto-repeat spell id (75 auto-shot /
        --                       5019 wand), 0/none otherwise
        local function rt_state(name)
            if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
                and RaijinLab:HasRuntime()) then return nil end
            local ok, r = pcall(RaijinLab.RuntimeCall, RaijinLab, name)
            if ok then return r end
            return nil
        end
        local function melee()
            local r = rt_state("IsAttacking")
            return type(r) == "string" and r:match("^1") ~= nil
        end
        local function shoot()
            local r = tonumber(rt_state("AutoRepeatSpell")) or 0
            return r == 75 or r == 5019
        end
        if mode == "melee"  then return melee() end
        if mode == "ranged" then return shoot() end
        return melee() or shoot()
    end,
})

------------------------------------------------------------
-- Self stats - health, power
------------------------------------------------------------

Conditions.register("health_pct", {
    name = "Health %",
    category = "Self",
    description = "Your health percent compared against the value. Pick an operator (greater than, less than, equals, in range). Turn on Invert to negate.",
    params = {
        { key = "op",        type = "string", default = "<=", label = "Operator", cycle = OP_CYCLE_NUMERIC },
        { key = "value",     type = "number", default = 50, min = 0, max = 100, label = "Health %", step = 5 },
        { key = "value_max", type = "number", default = 80, min = 0, max = 100, label = "Max %", step = 5, show_if = only_in_range },
    },
    eval = function(ctx, args)
        return cmp_op(num(ctx.health_pct, 100), args, { op = "<=", value = 50 })
    end,
})

Conditions.register("power", {
    name = "Power",
    category = "Self",
    description = "Compare a power pool against the value. 'Compare as' percent treats the value as 0-100%; raw units treats it as a count (right for FelFury 0-6, combo points 0-5, etc.). Power type picks the pool.",
    params = {
        { key = "power_type", type = "string", default = "primary", label = "Power type", cycle = POWER_TYPE_CYCLE },
        { key = "mode",       type = "string", default = "pct", label = "Compare as", cycle = MODE_CYCLE },
        { key = "op",         type = "string", default = ">=", label = "Operator",  cycle = OP_CYCLE_NUMERIC },
        { key = "value",      type = "number", default = 60, min = 0, max = 200000, label = "Threshold", step = 1 },
        { key = "value_max",  type = "number", default = 100, min = 0, max = 200000, label = "Max", step = 1, show_if = only_in_range },
    },
    eval = function(ctx, args)
        local ptype = _norm_power_type(args.power_type or args.ptype)
        -- Absent-pool guard. Without this, a warrior asking about "focus %
        -- >= 60" would evaluate 100 >= 60 = true (because World's safe-default
        -- for missing pools populates 100 in power_by_type so below-threshold
        -- questions don't spuriously fire). For above-threshold questions the
        -- SAME safe-default becomes a false positive; only a hard guard fixes
        -- both directions. Skip the guard when power_amount_max_by_type isn't
        -- populated (test harnesses provide power_by_type directly).
        if ptype ~= "primary" and ptype ~= 0 and ptype ~= "0" then
            local mxby = ctx.power_amount_max_by_type
            if mxby ~= nil then
                local pmax = mxby[ptype] or mxby[tostring(ptype)]
                if pmax ~= nil and num(pmax, 0) <= 0 then return false end
            end
        end
        return cmp_op(power_value(ctx, args), args, { op = ">=", value = 60 })
    end,
})

------------------------------------------------------------
-- PvP
------------------------------------------------------------

Conditions.register("pvp_flagged", {
    name = "PvP Flagged",
    category = "PvP",
    eval = function(ctx) return bool(ctx.pvp_flagged, false) end,
})

Conditions.register("pvp_enemy_nearby", {
    name = "Enemy Player Nearby",
    category = "PvP",
    params = { { key = "range", type = "number", default = 40, min = 1, max = 100, label = "Range (yd)", step = 5 } },
    eval = function(ctx, args)
        return num(ctx.enemy_players_in_range, 0) > 0
            and num(ctx.nearest_enemy_player_dist, 999) <= num(args.range, 40)
    end,
})

------------------------------------------------------------
-- Target
------------------------------------------------------------

local TARGET_EXIST_CYCLE = { "has_target", "no_target", "any" }

Conditions.register("target_exists", {
    name = "Target Existence",
    category = "Target",
    description = "Target presence. has_target = must have a target; no_target = must have none; any = always pass (both).",
    params = {
        { key = "state", type = "string", default = "has_target", label = "State", cycle = TARGET_EXIST_CYCLE },
    },
    eval = function(ctx, args)
        local st = string.lower(tostring((args and args.state) or "has_target"))
        local exists = bool(ctx.target_exists, false)
        if st == "any" or st == "both" or st == "either" then return true end
        if st == "no_target" or st == "none" or st == "missing" or st == "no" then
            return not exists
        end
        -- has_target / exists / yes / default
        return exists
    end,
})

Conditions.register("target_is_enemy", {
    name = "Target Is Enemy",
    category = "Target",
    description = "Target is attackable (UnitCanAttack). Prefer Target Hostility for hostile/neutral/friendly multi-select.",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and bool(ctx.target_is_enemy, false)
    end,
})

Conditions.register("target_is_friend", {
    name = "Target Is Friend",
    category = "Target",
    description = "Target is friendly (UnitIsFriend). Prefer Target Hostility for multi-select bands.",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and bool(ctx.target_is_friend, false)
    end,
})

-- Multi-select hostility bands (OR). Check any combination of hostile /
-- neutral / friendly. Uses UnitReaction when available:
--   hostile = 1..3, neutral = 4, friendly = 5..8.
Conditions.register("target_hostility", {
    name = "Target Hostility",
    category = "Target",
    description = "Target reaction band. Tick one or more: Hostile (red), Neutral (yellow), Friendly (green). Passes if the target matches ANY checked band. With Aura Search, checks the search unit (runtime hostiles), not client target.",
    params = {
        { key = "hostile",  type = "bool", default = true,  label = "Hostile (red / attackable-hated)" },
        { key = "neutral",  type = "bool", default = false, label = "Neutral (yellow)" },
        { key = "friendly", type = "bool", default = false, label = "Friendly (green)" },
    },
    eval = function(ctx, args)
        args = args or {}
        local want_h = args.hostile
        local want_n = args.neutral
        local want_f = args.friendly
        -- Empty args (no UI seed): default to hostile only.
        if want_h == nil and want_n == nil and want_f == nil then
            want_h = true
        end
        want_h = want_h == true or want_h == 1 or want_h == "true"
        want_n = want_n == true or want_n == 1 or want_n == "true"
        want_f = want_f == true or want_f == 1 or want_f == "true"
        if not (want_h or want_n or want_f) then return false end

        -- Multi-dot: aura_search already filtered living attackable hostiles in
        -- the runtime AuraSearch pack. Requiring client UnitExists("target")
        -- forced multi-dot to depend on selection and made melee look broken.
        local hit = ctx and ctx.aura_search_hit
        if hit and hit.guid then
            -- Runtime AuraSearch only returns hostile/attackable units.
            -- Hostile/neutral multi-dot configs pass; friendly-only fails.
            if want_h or want_n then return true end
            return false
        end

        if not bool(ctx.target_exists, false) then return false end

        local band = ctx.target_hostility
        if type(band) ~= "string" or band == "" then
            -- Derive from reaction / legacy flags when World did not fill it.
            local r = tonumber(ctx.target_reaction)
            if r then
                if r <= 3 then band = "hostile"
                elseif r == 4 then band = "neutral"
                else band = "friendly" end
            elseif bool(ctx.target_is_friend, false) then
                band = "friendly"
            elseif bool(ctx.target_is_enemy, false) then
                band = "hostile"
            else
                band = "neutral"
            end
        end
        band = string.lower(band)
        if band == "hostile" or band == "enemy" or band == "hated" or band == "unfriendly" then
            return want_h
        end
        if band == "neutral" then
            return want_n
        end
        if band == "friendly" or band == "friend" then
            return want_f
        end
        return false
    end,
})

Conditions.register("target_is_dead", {
    name = "Target Is Dead",
    category = "Target",
    description = "Target is dead. Toggle Invert for 'alive'.",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and bool(ctx.target_is_dead, false)
    end,
})

-- Is your current target targeting you (targettarget == player)?
local TARGET_TARGETING_YOU_CYCLE = { "is", "is_not" }

Conditions.register("target_targeting_you", {
    name = "Target Targeting You",
    category = "Target",
    description = "Whether your current target has you as their target (they are targeting / attacking you). Use is_not for units that are free or focused on someone else.",
    params = {
        { key = "state", type = "string", default = "is", label = "State", cycle = TARGET_TARGETING_YOU_CYCLE },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local st = string.lower(tostring((args and args.state) or "is"))
        local on_you = ctx.target_targeting_you
        -- Always re-check live (ctx can lag one tick after retarget).
        local W = RaijinLab and RaijinLab.World
        if W and W.target_is_targeting_you then
            on_you = W.target_is_targeting_you() and true or false
        elseif on_you == nil then
            if UnitIsUnit then
                local ok, r = pcall(UnitIsUnit, "targettarget", "player")
                on_you = ok and r and true or false
            else
                on_you = false
            end
            if not on_you and UnitName then
                local tn, pn = UnitName("targettarget"), UnitName("player")
                if tn and pn and tn == pn then on_you = true end
            end
        else
            on_you = bool(on_you, false)
        end
        if st == "is_not" or st == "not" or st == "no" or st == "false" then
            return not on_you
        end
        return on_you
    end,
})

Conditions.register("target_health_pct", {
    name = "Target Health %",
    category = "Target",
    description = "Target health percent compared against the value. Pick an operator (greater than, less than, equals, in range).",
    params = {
        { key = "op",        type = "string", default = "<=", label = "Operator", cycle = OP_CYCLE_NUMERIC },
        { key = "value",     type = "number", default = 20, min = 0, max = 100, label = "Health %", step = 5 },
        { key = "value_max", type = "number", default = 80, min = 0, max = 100, label = "Max %", step = 5, show_if = only_in_range },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        return cmp_op(num(ctx.target_health_pct, 100), args, { op = "<=", value = 20 })
    end,
})

Conditions.register("target_distance", {
    name = "Target Distance",
    category = "Target",
    description = "Hitbox-aware combat EDGE yards from ObjectPosition(GUID) + combat reach: edge = center2d - pCombat - tCombat. Fail-closed when positions are unavailable (no CheckInteract buckets).",
    params = {
        { key = "op",    type = "string", default = "<=", label = "Operator", cycle = OP_CYCLE_DISTANCE },
        { key = "range", type = "number", default = 5, min = 0, max = 100, label = "Range (yd)", step = 1 },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        -- Only precise ObjectPosition+reach yards. Never invent from interact buckets.
        if ctx.target_distance_precise ~= true and ctx.target_distance_precise ~= nil then
            return false
        end
        local op = tostring((args and args.op) or "<=")
        local thr = num(args and args.range, 5)
        local shim = { op = op, value = thr, value_max = args and args.value_max, invert = args and args.invert }
        return cmp_op(num(ctx.target_distance, 999), shim, { op = "<=", value = 5 })
    end,
})

Conditions.register("target_ttd", {
    name = "Target Time-To-Die",
    category = "Target",
    description = "Estimated seconds to target death compared against threshold. Requires an active TTD tracker.",
    params = {
        { key = "op",      type = "string", default = "<=", label = "Operator", cycle = OP_CYCLE_NUMERIC },
        { key = "seconds", type = "number", default = 5, min = 0, max = 600, label = "Seconds", step = 1 },
        { key = "value_max", type = "number", default = 10, min = 0, max = 600, label = "Max seconds", step = 1, show_if = only_in_range },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local ttd = ctx.target_ttd
        if ttd == nil then return false end
        local shim = { op = args.op, value = args.seconds, value_max = args.value_max, invert = args.invert }
        return cmp_op(num(ttd, 999), shim, { op = "<=", value = 5 })
    end,
})

Conditions.register("facing_target", {
    name = "Facing Target",
    category = "Target",
    description = "Already facing the current client target. Does not turn you. Prefer Auto Face if you want the rotation to turn for this slot.",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and bool(ctx.facing_target, false)
    end,
})

-- Policy marker (always passes). Executor reads slot conditions for this id and
-- turns toward the cast unit (target or aura_search GUID) before CastSpell.
-- Without this condition, unit-targeted slots only cast when already facing.
Conditions.register("auto_face", {
    name = "Auto Face",
    category = "Target",
    description = "Before casting this slot, turn to face the cast unit (current target or Aura Search GUID). Does NOT change your selected target. Without this condition the slot only fires when you are already facing — no automatic turn.",
    params = {},
    eval = function()
        -- Always true: presence on the slot is the policy. Invert disables it
        -- the same as removing the condition (handled via want_true).
        return true
    end,
})

Conditions.register("behind_target", {
    name = "Behind Target",
    category = "Target",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and bool(ctx.behind_target, false)
    end,
})

------------------------------------------------------------
-- AoE
------------------------------------------------------------

local function count_enemies(ctx, range)
    range = num(range, 8)
    if type(ctx.count_enemies_within) == "function" then
        return num(ctx.count_enemies_within(range), 0)
    end
    if range <= 8  then return num(ctx.enemies_in_8 or ctx.enemies_in_range, 0) end
    if range <= 10 then return num(ctx.enemies_in_10, 0) end
    if range <= 40 then return num(ctx.enemies_in_40, 0) end
    return num(ctx.enemies_in_40, 0)
end

Conditions.register("enemies_in_range", {
    name = "Enemies In Range",
    category = "AoE",
    description = "Count of enemies within `range` (yards) compared against `count`.",
    params = {
        { key = "op",    type = "string", default = ">=", label = "Operator", cycle = OP_CYCLE_COUNT },
        { key = "count", type = "number", default = 3, min = 0, max = 40, label = "Count", step = 1 },
        { key = "range", type = "number", default = 8, min = 1, max = 100, label = "Range (yd)", step = 1 },
    },
    eval = function(ctx, args)
        local shim = { op = args.op, value = args.count, value_max = args.value_max, invert = args.invert }
        return cmp_op(count_enemies(ctx, args.range), shim, { op = ">=", value = 3 })
    end,
})

------------------------------------------------------------
-- Corpses (abilities that require a body: Raise Dead, etc.)
------------------------------------------------------------

local function count_corpses(ctx, range, state)
    range = num(range, 30)
    state = string.lower(tostring(state or "available"))
    if type(ctx.count_corpses_within) == "function" then
        return num(ctx.count_corpses_within(range, state), 0)
    end
    -- Fallback when World did not attach a list (pure unit tests).
    local list = ctx.corpse_list
    if type(list) == "table" then
        local n = 0
        for i = 1, #list do
            local c = list[i]
            local d = num(c.dist, 999)
            if d <= range then
                if state == "any" or state == "both" then n = n + 1
                elseif (state == "available" or state == "not_consumed" or state == "fresh") and c.available then n = n + 1
                elseif (state == "consumed" or state == "empty") and c.consumed then n = n + 1
                end
            end
        end
        return n
    end
    if state == "available" or state == "not_consumed" or state == "fresh" then
        return num(ctx.corpses_available, 0)
    end
    if state == "consumed" or state == "empty" then
        return num(ctx.corpses_consumed, 0)
    end
    return num(ctx.corpses_total, 0)
end

Conditions.register("corpse", {
    name = "Corpse Nearby",
    category = "World",
    description = "Count of corpses within range. State is about CORPSE-ABILITY use (Cannibalize, Raise Dead, ...), NOT loot: available = not yet consumed by such an ability; consumed = already used by one; any = either. Looted vs unlooted does not matter.",
    params = {
        { key = "state", type = "string", default = "available", label = "State (ability use)", cycle = CORPSE_STATE_CYCLE },
        { key = "op",    type = "string", default = ">=", label = "Operator", cycle = OP_CYCLE_COUNT },
        { key = "count", type = "number", default = 1, min = 0, max = 40, label = "Count", step = 1 },
        { key = "range", type = "number", default = 30, min = 1, max = 100, label = "Range (yd)", step = 1 },
    },
    eval = function(ctx, args)
        local n = count_corpses(ctx, args.range, args.state)
        local shim = { op = args.op, value = args.count, value_max = args.value_max, invert = args.invert }
        return cmp_op(n, shim, { op = ">=", value = 1 })
    end,
})

------------------------------------------------------------
-- Spells
------------------------------------------------------------

Conditions.register("spell_known", {
    name = "Spell Known",
    category = "Spell",
    params = { { key = "spell_id", type = "number", default = 0, label = "Spell ID" } },
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local known = ctx.known_spells
        if type(known) == "table" then
            return known[id] == true or known[tostring(id)] == true
        end
        return bool(ctx.spell_known, true)
    end,
})

Conditions.register("cooldown", {
    name = "Cooldown",
    category = "Spell",
    description = "Check a spell's cooldown. Operator 'ready' means off cooldown; 'on cooldown' means still cooling; 'greater than' / 'less than' compare the remaining seconds. Spell ID 0 = this slot's spell.",
    params = {
        { key = "op",       type = "string", default = "ready", label = "Operator", cycle = OP_CYCLE_COOLDOWN },
        { key = "spell_id", type = "number", default = 0, label = "Spell ID (0=slot)" },
        { key = "seconds",  type = "number", default = 1, min = 0, max = 600, label = "Seconds", step = 1, show_if = cd_uses_seconds },
    },
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local cds = ctx.cooldowns or {}
        local rem = num(cds[id] or cds[tostring(id)] or ctx.cooldown_remaining, 0)
        local op = string.lower(tostring(args.op or "ready"))
        if op == "ready" then return rem <= 0 end
        if op == "on_cd" or op == "oncd" then return rem > 0 end
        local shim = { op = args.op, value = args.seconds, invert = args.invert }
        return cmp_op(rem, shim, { op = ">=", value = 1 })
    end,
})

Conditions.register("spell_usable", {
    name = "Spell Usable",
    category = "Spell",
    description = "Combined gates: known_spells, cooldowns, IsUsableSpell (resource/stance only), and spell_in_range. require_* defaults true; set false to skip a gate. spell_id 0 = slot spell.",
    params = {
        { key = "spell_id",       type = "number", default = 0, label = "Spell ID (0=slot)" },
        { key = "require_range",  type = "bool", default = true, label = "Require in range" },
        { key = "require_known",  type = "bool", default = true, label = "Require known" },
        { key = "require_off_cd", type = "bool", default = true, label = "Require off cooldown" },
    },
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        if id == 0 then return false end

        local require_known  = args.require_known;  if require_known  == nil then require_known  = true end
        local require_off_cd = args.require_off_cd; if require_off_cd == nil then require_off_cd = true end
        local require_range  = args.require_range;  if require_range  == nil then require_range  = true end

        if require_known then
            local known = ctx.known_spells or {}
            if not (known[id] == true or known[tostring(id)] == true) then return false end
        end
        if require_off_cd then
            local cds = ctx.cooldowns or {}
            local rem = cds[id] or cds[tostring(id)] or 0
            if num(rem, 0) > 0 then return false end
        end
        local usable = ctx.spell_usable or {}
        if usable[id] == false or usable[tostring(id)] == false then return false end
        if require_range then
            local ir = ctx.spell_in_range or {}
            if ir[id] == false or ir[tostring(id)] == false then return false end
        end
        return true
    end,
})

Conditions.register("spell_in_range", {
    name = "Spell In Range",
    category = "Spell",
    params = {
        { key = "spell_id", type = "number", default = 0, label = "Spell ID (0=slot)" },
    },
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local ir = ctx.spell_in_range or {}
        if ir[id] == nil and ir[tostring(id)] == nil then
            return bool(ctx.target_exists, false)
        end
        return ir[id] == true or ir[tostring(id)] == true
    end,
})

Conditions.register("gcd_ready", {
    name = "GCD Ready / On GCD",
    category = "Spell",
    description = "ready=true: not on GCD. ready=false: currently on GCD.",
    params = {
        { key = "ready", type = "bool", default = true, label = "GCD must be ready" },
    },
    eval = function(ctx, args)
        local is_ready = num(ctx.gcd_remaining, 0) <= 0
        local want_ready = args.ready
        if want_ready == nil then want_ready = true end
        if want_ready == false or want_ready == 0 or want_ready == "false" then
            return not is_ready
        end
        return is_ready
    end,
})

------------------------------------------------------------
-- Auras (unified) - one condition covers all of {buff, debuff} x
-- {present, missing} x {player, target}, with stack/remaining thresholds.
------------------------------------------------------------

local function aura_tables_for(ctx, unit, kind)
    if unit == "target" then
        if kind == "debuff" then
            return ctx.target_debuffs, ctx.target_debuff_stacks, ctx.target_debuff_remaining
        end
        return ctx.target_buffs, ctx.target_buff_stacks, ctx.target_buff_remaining
    end
    if kind == "debuff" then
        return ctx.player_debuffs, ctx.player_debuff_stacks, ctx.player_debuff_remaining
    end
    return ctx.player_buffs, ctx.player_buff_stacks, ctx.player_buff_remaining
end

Conditions.register("aura", {
    name = "Aura",
    category = "Auras",
    description = "Buff/debuff on player or target. state=present/missing. Stacks: min/max. Duration remaining: operator any/>=/<=/=/in_range with seconds. Aura spell ID is the APPLICATION id (often different from the skill that applies it, even when names match). The editor fills the name from that id for display but never overwrites your id from the name.",
    params = {
        { key = "unit",          type = "string", default = "player",  label = "Unit",  cycle = UNIT_CYCLE },
        { key = "kind",          type = "string", default = "buff",    label = "Kind",  cycle = KIND_CYCLE },
        { key = "state",         type = "string", default = "present", label = "State", cycle = STATE_CYCLE },
        { key = "spell_id",      type = "number", default = 0,         label = "Aura spell ID" },
        { key = "name",          type = "string", default = "",        label = "Aura name" },
        { key = "min_stacks",    type = "number", default = 1, min = 1, max = 99, label = "Min stacks", step = 1, show_if = aura_is_present },
        { key = "max_stacks",    type = "number", default = 0, min = 0, max = 99, label = "Max stacks (0=any)", step = 1, show_if = aura_is_present },
        { key = "remaining_op",  type = "string", default = "any", label = "Duration remaining", cycle = AURA_REM_OP_CYCLE, show_if = aura_is_present },
        { key = "remaining",     type = "number", default = 0, min = 0, max = 600, label = "Remaining (s)", step = 0.5, show_if = aura_rem_uses_value },
        { key = "remaining_max", type = "number", default = 30, min = 0, max = 600, label = "Max remaining (s)", step = 0.5, show_if = aura_rem_uses_max },
        -- Legacy field kept for saved rotations; editor hides it (use remaining_op + remaining).
        { key = "min_remaining", type = "number", default = 0, min = 0, max = 600, label = "Min remaining (legacy)", step = 1, show_if = function() return false end },
    },
    eval = function(ctx, args)
        local unit  = string.lower(tostring(args.unit  or "player"))
        local kind  = string.lower(tostring(args.kind  or "buff"))
        local state = string.lower(tostring(args.state or "present"))
        local id = num(args.spell_id, 0)
        local nm = args.name or ""
        if id > 0 and (nm == "" or not nm) then
            nm = _resolve_spell_name(id) or ""
        end

        -- Multi-dot companion: aura_search already picked a unit this slot.
        -- Prefer GUID (CLEU / optimistic) — never require mouseover token or
        -- UnitExists("target"). That was why Icy Touch only worked on hover.
        local hit = ctx and ctx.aura_search_hit
        if unit == "target" and hit and (hit.guid or hit.token) then
            local W = RaijinLab and RaijinLab.World
            local has, stacks, rem = false, 0, 0
            if hit.token and W and W.unit_aura_probe
                and UnitExists and UnitExists(hit.token) then
                has, stacks, rem = W.unit_aura_probe(hit.token, kind, id, nm)
            elseif hit.guid and W and W.guid_aura_state then
                has, stacks, rem = W.guid_aura_state(hit.guid, id, nm)
            elseif hit.guid then
                -- No CLEU yet: missing = true, present = false (safe multi-dot).
                has = false
            end
            if state == "missing" then return not has end
            if not has then return false end
            if stacks < 1 then stacks = 1 end
            if stacks < num(args.min_stacks, 1) then return false end
            local max_st = num(args.max_stacks, 0)
            if max_st > 0 and stacks > max_st then return false end
            local op = string.lower(tostring(args.remaining_op or "any"))
            local rem_val = num(args.remaining, nil)
            if (op == "any" or op == "" or op == "none") and num(args.min_remaining, 0) > 0 then
                op = ">="
                if rem_val == nil then rem_val = num(args.min_remaining, 0) end
            end
            if op ~= "any" and op ~= "" and op ~= "none" then
                rem_val = num(rem_val, 0)
                local shim = {
                    op = op, value = rem_val,
                    value_max = num(args.remaining_max, rem_val),
                }
                if not cmp_op(rem or 0, shim, { op = ">=", value = 0 }) then
                    return false
                end
            end
            return true
        end

        if unit == "target" and not bool(ctx.target_exists, false) then
            return false
        end
        local present, stacks_tbl, rem_tbl = aura_tables_for(ctx, unit, kind)
        local here = aura_has(present, id, nm)
        local st, rem = 0, 0
        -- 2026-08-03 (ROUND 47 FIX): the UnitDebuff scan (ctx.target_debuffs)
        -- misses custom Ascension auras — Frost Fever/Blood Plague never land in
        -- ctx.target_debuffs, so "missing" ALWAYS passed (Icy Touch #6 re-fired
        -- every GCD after Frost Fever was already up) and "present" NEVER passed
        -- (Blood Strike, which requires both diseases, never fired at melee).
        -- Union in World.guid_aura_state (UnitDebuff + runtime HasUnitAura +
        -- CLEU notes) so the condition reflects the REAL aura state. The user's
        -- rotation is authoritative; the engine must honor its conditions.
        if not here and unit == "target" and RaijinLab and RaijinLab.World
            and RaijinLab.World.guid_aura_state and UnitGUID then
            local tguid = UnitGUID("target")
            if tguid then
                local has, s2, r2 = RaijinLab.World.guid_aura_state(tguid, id, nm)
                if has then
                    here = true
                    if s2 and s2 > st then st = s2 end
                    if r2 and r2 > rem then rem = r2 end
                end
            end
        end
        if state == "missing" then
            return not here
        end
        if not here then return false end
        if st < 1 then st = aura_stat(stacks_tbl, id, nm) end
        if st < 1 then st = 1 end
        if st < num(args.min_stacks, 1) then return false end
        local max_st = num(args.max_stacks, 0)
        if max_st > 0 and st > max_st then return false end

        -- Duration remaining.
        if rem <= 0 then rem = aura_stat(rem_tbl, id, nm) end
        local op = string.lower(tostring(args.remaining_op or "any"))
        local rem_val = num(args.remaining, nil)
        -- Legacy min_remaining: treat as remaining_op >= when new fields unused.
        if (op == "any" or op == "" or op == "none") and num(args.min_remaining, 0) > 0 then
            op = ">="
            if rem_val == nil then rem_val = num(args.min_remaining, 0) end
        end
        if op ~= "any" and op ~= "" and op ~= "none" then
            rem_val = num(rem_val, 0)
            local shim = {
                op = op,
                value = rem_val,
                value_max = num(args.remaining_max, rem_val),
            }
            if not cmp_op(rem, shim, { op = ">=", value = 0 }) then
                return false
            end
        end
        return true
    end,
})

------------------------------------------------------------
-- Aura Search - scan nearby units for buff/debuff present OR missing.
-- Default: cast via Spell_C_CastSpell(guid) WITHOUT changing client target.
-- Optional "Acquire target" swaps selection to the match; "Reset after"
-- (only when acquire is on) restores the previous selection after the cast.
------------------------------------------------------------

local function aura_search_acquire_on(args)
    args = args or {}
    -- New key: acquire_target. Legacy: retarget (migrated on load, still read).
    if args.acquire_target == true or args.acquire_target == 1 or args.acquire_target == "true" then
        return true
    end
    if args.retarget == true or args.retarget == 1 or args.retarget == "true" then
        return true
    end
    return false
end

local function aura_search_reset_after_on(args)
    args = args or {}
    if not aura_search_acquire_on(args) then return false end
    return args.reset_after == true or args.reset_after == 1 or args.reset_after == "true"
end

local function show_if_acquire_target(args)
    return aura_search_acquire_on(args)
end

Conditions.register("aura_search", {
    name = "Aura Search",
    category = "Auras",
    description = "Runtime multi-dot: finds living attackable units (OM) missing/having an aura. Casts Spell_C(guid). Does NOT use mouseover/target. Acquire target is optional selection; default leaves your target alone. Use Target Hostility / Target Targeting You for extra unit policy.",
    params = {
        { key = "kind",            type = "string", default = "debuff",  label = "Kind",  cycle = KIND_CYCLE },
        { key = "state",           type = "string", default = "missing", label = "State", cycle = STATE_CYCLE },
        { key = "spell_id",        type = "number", default = 0,         label = "Aura spell ID" },
        { key = "name",            type = "string", default = "",        label = "Aura name" },
        { key = "range",           type = "number", default = 40, min = 1, max = 100, label = "Search range (yd)", step = 1 },
        { key = "min_stacks",      type = "number", default = 1, min = 1, max = 99, label = "Min stacks", step = 1, show_if = aura_is_present },
        { key = "max_stacks",      type = "number", default = 0, min = 0, max = 99, label = "Max stacks (0=any)", step = 1, show_if = aura_is_present },
        { key = "acquire_target",  type = "bool",   default = false, label = "Acquire target" },
        { key = "reset_after",     type = "bool",   default = false, label = "Reset after", show_if = show_if_acquire_target },
    },
    eval = function(ctx, args)
        args = args or {}
        local W = RaijinLab and RaijinLab.World
        if not W or not W.find_aura_search_targets then return false end

        local state = string.lower(tostring(args.state or "missing"))
        local id = num(args.spell_id, 0)
        local nm = args.name or ""
        if id > 0 and (nm == "" or not nm) then
            nm = _resolve_spell_name(id) or ""
        end
        if id <= 0 and (nm == "" or not nm) then
            return false
        end

        if args.prefer_current ~= nil then args.prefer_current = nil end
        local acquire = aura_search_acquire_on(args)
        local reset_after = aura_search_reset_after_on(args)
        if not acquire then
            args.retarget = false
            args.acquire_target = false
            args.reset_after = false
        end

        -- RUNTIME AuraSearch only — no Unit* discovery.
        -- 2026-08-02 (NO FALLBACKS — user directive): the search range is
        -- min(user condition range, the SPELL's REAL max range). The spell's
        -- range is decoded from the client's Spell.dbc by the runtime — it is
        -- the authority. An ability with a 20yd range must NEVER be searched
        -- at 30/40yd, and a spell whose range cannot be decoded is a HARD
        -- failure (never a silent 30/40-yard search that finds targets the
        -- spell cannot reach).
        local search_range = num(args.range, 40)
        local spell_max = W.spell_max_range and W.spell_max_range(id)
        if not spell_max then
            -- ROUND 48 (SPAM FIX): this fired on EVERY aura_search eval for any
            -- aura-id (55078/55095 etc. are auras, not castable spells — they
            -- NEVER have a Spell.dbc range). Throttle to once per 10s per id;
            -- the noise was thousands of lines/session and added I/O churn on
            -- top of the per-tick evaluation.
            if W.dlog then
                local tnow = (GetTime and GetTime()) or 0
                W._range_unknown_log_t = W._range_unknown_log_t or {}
                local lt = W._range_unknown_log_t[id]
                if not lt or (tnow - lt) > 10 then
                    W._range_unknown_log_t[id] = tnow
                    W.dlog("search", "aura_search RANGE_UNKNOWN sid=%d — using configured "
                        .. "range %d (spell_max decode unavailable)", id, search_range)
                end
            end
            -- 2026-08-02 (23:48): RANGE_UNKNOWN must NOT silently kill the
            -- search. The hard-fail left the rotation stuck in "wait no_target"
            -- for every aura-search slot whenever the runtime SpellMeleeInfo
            -- max= decode was unavailable — "aura search not working at all".
            -- The condition's own `range` param is explicit USER intent (not a
            -- silent malformed fallback), so use it as the search bound; the
            -- cast-side range gate + the client are still the final authority
            -- on reachability (and the native path now reports nrc cleanly).
            -- We only clamp DOWN when the spell's real max IS known.
            -- Do NOT set ctx.aura_search_hit yet — fall through to search.
        elseif search_range > spell_max then
            search_range = spell_max
        end
        local list = W.find_aura_search_targets({
            kind = string.lower(tostring(args.kind or "debuff")),
            state = state,
            spell_id = id,
            name = nm,
            range = search_range,
            min_stacks = num(args.min_stacks, 1),
            max_stacks = num(args.max_stacks, 0),
            max_n = 8,
        })
        if not list or #list == 0 then
            ctx.aura_search_hit = nil
            return false
        end

        -- Second pass: drop units that client UnitDebuff / notes already show
        -- as having the aura. Runtime notes alone lag CLEU; UnitAura on the
        -- current target is instant. Without this, single-target multi-dot
        -- re-cast PS while Blood Plague was already present.
        if state == "missing" or state == "absent" or state == "lacks" then
            local filtered = {}
            for i = 1, #list do
                local c = list[i]
                if c and c.guid then
                    local has = false
                    if W.guid_aura_state then
                        has = select(1, W.guid_aura_state(c.guid, id, nm))
                    end
                    if not has then
                        filtered[#filtered + 1] = c
                    end
                end
            end
            list = filtered
        end
        if not list or #list == 0 then
            ctx.aura_search_hit = nil
            return false
        end

        -- 2026-08-02 (MAIN-TARGET PREFERENCE): the list is closest-first, but
        -- when the player's CURRENT target is also a valid match (alive,
        -- attackable, aura-missing) it MUST be the head — the rotation should
        -- refresh the main target before spreading dots to adds. This is what
        -- "wasn't using Icy Touch on the main target" was about: the runtime
        -- distance sort can put a closer add first while the main target sits
        -- a yard further and never gets re-dotted until every add is covered.
        local current_guid = (UnitExists and UnitExists("target") and UnitGUID
            and UnitGUID("target")) or nil
        if current_guid then
            for i = 1, #list do
                local c = list[i]
                if c and c.guid and tostring(c.guid) == tostring(current_guid) then
                    if i ~= 1 then
                        table.remove(list, i)
                        table.insert(list, 1, c)
                    end
                    break
                end
            end
        end

        local best = list[1]
        ctx.aura_search_hit = {
            token = nil,
            guid = best.guid,
            dist = best.dist,
            facing = best.facing,
            face_err = best.face_err,
            candidates = list,
            acquire_target = acquire,
            reset_after = reset_after,
            retarget = acquire,
        }
        local sid = num(ctx.slot_spell_id, 0)
        if sid > 0 then
            ctx.spell_in_range = ctx.spell_in_range or {}
            ctx.spell_in_range[sid] = true
            ctx.spell_in_range[tostring(sid)] = true
            ctx.spell_targeted = ctx.spell_targeted or {}
            ctx.spell_targeted[sid] = true
            ctx.spell_targeted[tostring(sid)] = true
        end
        return true
    end,
})

------------------------------------------------------------
-- Target protection (kept as two first-class conditions since they read
-- as distinct UX affordances - "don't cast damage into a shielded target"
-- vs "cast the fallback that still lands").
------------------------------------------------------------

local function resolve_spell_for_protection(ctx, args)
    local id = num(args.spell_id, 0)
    if id == 0 then id = num(ctx.slot_spell_id, 0) end
    local name = args.name or args.spell_name or ctx.slot_name or ""
    local school = args.school or "auto"
    return id, name, school
end

local function eval_is_protected(ctx, args)
    local id, name, school = resolve_spell_for_protection(ctx, args)
    local treat_absorb = args.treat_absorb;   if treat_absorb   == nil then treat_absorb   = true end
    local treat_heavy_dr = args.treat_heavy_dr; if treat_heavy_dr == nil then treat_heavy_dr = true end

    if type(ctx.is_spell_protected) == "function" and id ~= 0 then
        local prot = ctx.is_spell_protected(id, name, school, {
            treat_absorb_as_protected = treat_absorb,
            treat_heavy_dr_as_protected = treat_heavy_dr,
            absorb_threshold = num(args.absorb_threshold, 1),
        })
        return not not prot
    end

    local map = ctx.target_protected or {}
    if id ~= 0 and (map[id] ~= nil or map[tostring(id)] ~= nil) then
        return map[id] == true or map[tostring(id)] == true
    end

    local Prot = (RaijinLab and RaijinLab.Protection) or (Protection or nil)
    if Prot and type(Prot.is_protected) == "function" then
        local target = ctx.protection_target or {
            exists = bool(ctx.target_exists, false),
            is_dead = bool(ctx.target_is_dead, false),
            can_attack = bool(ctx.target_is_enemy, true),
            is_friend = bool(ctx.target_is_friend, false),
            buffs = ctx.target_buffs or {},
            debuffs = ctx.target_debuffs or {},
            absorb_amounts = ctx.target_absorb_amounts or {},
            recent_miss = ctx.recent_miss or {},
            creature_type = ctx.target_creature_type or "",
        }
        local prot = Prot.is_protected(target, {
            spell_id = id,
            spell_name = name,
            school = school,
            treat_absorb_as_protected = treat_absorb,
            treat_heavy_dr_as_protected = treat_heavy_dr,
            absorb_threshold = num(args.absorb_threshold, 1),
            now = num(ctx.now, 0),
            respect_recent_miss = true,
        })
        return not not prot
    end

    return false
end

Conditions.register("target_protected", {
    name = "Target Protected From Spell",
    category = "Protection",
    description = "TRUE when the selected spell CANNOT damage the target (immunity, absorb/ward, reflect, deflect, evade, heavy DR, or recent CLEU immune). Use for skip-guards on lower-priority spells.",
    params = {
        { key = "spell_id",         type = "number", default = 0, label = "Spell ID (0=slot)" },
        { key = "school",           type = "string", default = "auto", label = "School", cycle = SCHOOL_CYCLE },
        { key = "treat_absorb",     type = "bool",   default = true, label = "Treat absorbs/wards as protected" },
        { key = "treat_heavy_dr",   type = "bool",   default = true, label = "Treat heavy DR as protected" },
        { key = "absorb_threshold", type = "number", default = 1, min = 0, max = 1000000, label = "Min absorb to count" },
    },
    eval = function(ctx, args) return eval_is_protected(ctx, args) end,
})

Conditions.register("target_can_take_damage", {
    name = "Target Can Take Damage",
    category = "Protection",
    description = "TRUE when the selected damage spell should actually land. Attach to damage spells so a higher-priority ability that is blocked is skipped and a still-usable lower-priority one can fire.",
    params = {
        { key = "spell_id",         type = "number", default = 0, label = "Spell ID (0=slot)" },
        { key = "school",           type = "string", default = "auto", label = "School", cycle = SCHOOL_CYCLE },
        { key = "treat_absorb",     type = "bool",   default = true, label = "Treat absorbs/wards as protected" },
        { key = "treat_heavy_dr",   type = "bool",   default = true, label = "Treat heavy DR as protected" },
        { key = "absorb_threshold", type = "number", default = 1, min = 0, max = 1000000, label = "Min absorb to count" },
    },
    eval = function(ctx, args) return not eval_is_protected(ctx, args) end,
})

------------------------------------------------------------
-- Live-state conditions. These read the WoW API directly at eval time
-- (like auto_repeat), but honor a ctx override first so unit tests can
-- inject state. They cover essential rotation primitives that aren't part
-- of the World context snapshot.
------------------------------------------------------------

Conditions.register("is_stealthed", {
    name = "Is Stealthed",
    category = "Self",
    description = "Player is stealthed (Stealth, Prowl, Shadowmeld, Vanish). Toggle Invert for 'not stealthed'.",
    eval = function(ctx)
        if ctx.is_stealthed ~= nil then return bool(ctx.is_stealthed, false) end
        return (_G.IsStealthed and _G.IsStealthed() == 1) or false
    end,
})

Conditions.register("is_stunned", {
    name = "Is Stunned / Disarmed / Confused / Fleeing",
    category = "Self",
    description = "Player is under a movement-impairing crowd control (stunned, disarmed, confused, or fleeing). Runtime UnitMovementImpairing reads UNIT_FIELD_FLAGS from descriptor — no Blizzard API. Use Invert for 'not impaired'.",
    params = {
        { key = "kind", type = "string", default = "stunned", label = "Impair type", cycle = { "stunned", "disarmed", "confused", "fleeing", "any" } },
    },
    eval = function(ctx, args)
        if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab:HasRuntime()) then
            -- Fallback to ctx for non-runtime environments
            if ctx.is_stunned ~= nil then return bool(ctx.is_stunned, false) end
            return false
        end
        local ok, packed = pcall(RaijinLab.RuntimeCall, RaijinLab, "UnitMovementImpairing", "player")
        if not ok then return false end
        local mask = tonumber(packed) or 0
        if mask < 0 then return false end
        local kind = string.lower(tostring((args and args.kind) or "stunned"))
        -- Use bit.band (Lua 5.1 compat) — no & operator on WoW 3.3.5
        local function has_bit(m, b) return (math.floor(m / b) % 2) ~= 0 end
        if kind == "stunned"  then return has_bit(mask, 1) end
        if kind == "disarmed" then return has_bit(mask, 2) end
        if kind == "confused" then return has_bit(mask, 4) end
        if kind == "fleeing"  then return has_bit(mask, 8) end
        if kind == "any" then return mask ~= 0 end
        return false
    end,
})

Conditions.register("is_silenced", {
    name = "Is Silenced / School Locked",
    category = "Self",
    description = "Player is silenced or school-locked for the relevant spell school. Checks player debuffs dynamically (no hardcoded spell IDs), matching silence/lockout/interrupt keywords against debuff names. Use Invert for 'not silenced'.",
    params = {
        { key = "spell_id", type = "number", default = 0, label = "Spell ID (for school)" },
    },
    eval = function(ctx, args)
        if ctx.is_silenced ~= nil then return bool(ctx.is_silenced, false) end

        -- Dynamically scan player debuffs for silence/school-lock interrupts.
        -- No hardcoded spell IDs — works on any client including Ascension.
        local pid = tonumber(args and args.spell_id) or tonumber(ctx.slot_spell_id) or 0
        if pid <= 0 then return false end

        -- Get spell school: prefer runtime SpellInfo (accurate), fallback Blizzard
        local school = -1
        local RL = RaijinLab
        if RL and RL.RuntimeCall and RL:HasRuntime() then
            local ok, info = pcall(RL.RuntimeCall, RL, "SpellInfo", pid)
            if ok and type(info) == "string" then
                school = tonumber(string.match(info, "school=(-?%d+)")) or -1
            end
        end
        if school < 0 then return false end

        -- Scan all player debuffs for interrupt/silence mechanics
        local function is_lockout(debuffName, debuffId)
            if not debuffName or debuffName == "" then return false end
            local lower = string.lower(tostring(debuffName))
            -- Generic silence keywords
            if lower:find("silence") or lower:find("locked") or lower:find("lockout") then return true end
            if lower:find("interrupt") or lower:find("counterspell") then return true end
            -- Melee interrupts (work by keyword, not by hardcoded ID)
            if lower:find("kick") or lower:find("pummel") or lower:find("bash") then return true end
            if lower:find("mind freeze") or lower:find("strangulate") then return true end
            -- School-specific locks: cross-reference debuff school with our spell school
            if debuffId and debuffId > 0 and RL and RL.RuntimeCall and RL:HasRuntime() then
                local ok2, dinfo = pcall(RL.RuntimeCall, RL, "SpellInfo", debuffId)
                if ok2 and type(dinfo) == "string" then
                    local dsch = tonumber(string.match(dinfo, "school=(-?%d+)")) or 0
                    -- -2 school = all-school silence; matching school = school lock
                    if dsch == -2 or (dsch == school and dsch > 0) then return true end
                end
            end
            return false
        end

        -- Check Blizzard debuff API (works even without runtime)
        local i = 1
        while i <= 40 do
            local name, _, _, _, _, _, _, _, sid = UnitDebuff("player", i)
            if not name then break end
            if is_lockout(name, tonumber(sid)) then return true end
            i = i + 1
        end

        return false
    end,
})

Conditions.register("target_is_player", {
    name = "Target Is Player",
    category = "Target",
    description = "Target is a player character, not an NPC. Useful for PvP-only abilities.",
    eval = function(ctx)
        if not bool(ctx.target_exists, false) then return false end
        if ctx.target_is_player ~= nil then return bool(ctx.target_is_player, false) end
        return (_G.UnitIsPlayer and _G.UnitIsPlayer("target")) or false
    end,
})

-- Returns casting, channeling, remaining(s), interruptible for the target.
-- Interruptibility isn't exposed by stock 3.3.5 UnitCastingInfo, so it is
-- assumed interruptible unless the client reports a notInterruptible flag.
local function _target_cast_state(ctx)
    if ctx.target_casting ~= nil or ctx.target_channeling ~= nil then
        local interruptible = true
        if ctx.target_cast_interruptible ~= nil then interruptible = bool(ctx.target_cast_interruptible, true) end
        return bool(ctx.target_casting, false), bool(ctx.target_channeling, false),
               num(ctx.target_cast_remaining, 0), interruptible
    end
    local now = (_G.GetTime and _G.GetTime()) or 0
    if _G.UnitCastingInfo then
        local name, _, _, _, _, endMS, _, _, notInterruptible = _G.UnitCastingInfo("target")
        if name then
            local rem = (tonumber(endMS) or 0) / 1000 - now
            return true, false, rem > 0 and rem or 0, not notInterruptible
        end
    end
    if _G.UnitChannelInfo then
        local name, _, _, _, _, endMS, _, notInterruptible = _G.UnitChannelInfo("target")
        if name then
            local rem = (tonumber(endMS) or 0) / 1000 - now
            return false, true, rem > 0 and rem or 0, not notInterruptible
        end
    end
    return false, false, 0, false
end

Conditions.register("target_casting", {
    name = "Target Casting",
    category = "Target",
    description = "Target is casting or channeling a spell. Kind = cast, channel, or any. 'Interruptible only' requires an interruptible cast (best-effort: stock 3.3.5 does not expose interruptibility, so casts are assumed interruptible). Min remaining gates on the time left, so you can interrupt late.",
    params = {
        { key = "kind",               type = "string", default = "any", label = "Kind", cycle = { "cast", "channel", "any" } },
        { key = "interruptible_only", type = "bool",   default = false, label = "Interruptible only" },
        { key = "min_remaining",      type = "number", default = 0, min = 0, max = 30, label = "Min remaining (s)", step = 1 },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local casting, channeling, rem, interruptible = _target_cast_state(ctx)
        local kind = string.lower(tostring(args.kind or "any"))
        local active
        if kind == "cast" then active = casting
        elseif kind == "channel" then active = channeling
        else active = casting or channeling end
        if not active then return false end
        if bool(args.interruptible_only, false) and not interruptible then return false end
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})

Conditions.register("target_classification", {
    name = "Target Classification",
    category = "Target",
    description = "Target's classification equals the selected value. 'boss' matches world bosses and ??-level (skull) mobs. Gate burst cooldowns on bosses/elites.",
    params = {
        { key = "value", type = "string", default = "elite", label = "Classification",
          cycle = { "normal", "elite", "rareelite", "rare", "worldboss", "boss", "trivial" } },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local want = string.lower(tostring(args.value or "elite"))
        local cls = ctx.target_classification
        if cls == nil and _G.UnitClassification then cls = _G.UnitClassification("target") end
        cls = string.lower(tostring(cls or "normal"))
        local lvl = ctx.target_level
        if lvl == nil and _G.UnitLevel then lvl = _G.UnitLevel("target") end
        lvl = tonumber(lvl) or 0
        if want == "boss" then
            return cls == "worldboss" or lvl == -1
        end
        return cls == want
    end,
})

Conditions.register("group_size", {
    name = "Group Size",
    category = "Group",
    description = "Number of players in your group INCLUDING you, compared against the count. 1 = solo, 5 = full party, up to 40 in a raid.",
    params = {
        { key = "op",    type = "string", default = ">=", label = "Operator", cycle = OP_CYCLE_COUNT },
        { key = "count", type = "number", default = 2, min = 1, max = 40, label = "Members", step = 1 },
    },
    eval = function(ctx, args)
        local size = ctx.group_size
        if size == nil then
            local raid = (_G.GetNumRaidMembers and _G.GetNumRaidMembers()) or 0
            if raid and raid > 0 then
                size = raid
            else
                size = 1 + ((_G.GetNumPartyMembers and _G.GetNumPartyMembers()) or 0)
            end
        end
        local shim = { op = args.op, value = args.count, invert = args.invert }
        return cmp_op(num(size, 1), shim, { op = ">=", value = 2 })
    end,
})

Conditions.register("item_ready", {
    name = "Item Ready",
    category = "Item",
    description = "An item (by item ID) or an equipped slot is off cooldown. For on-use trinkets, set slot 13 (top) or 14 (bottom). If slot is greater than 0 it takes priority over item ID.",
    params = {
        { key = "item_id", type = "number", default = 0, min = 0, max = 1000000, label = "Item ID" },
        { key = "slot",    type = "number", default = 0, min = 0, max = 19, label = "Equip slot (13/14 = trinkets)" },
    },
    eval = function(ctx, args)
        if ctx.item_ready ~= nil then return bool(ctx.item_ready, false) end
        local now = (_G.GetTime and _G.GetTime()) or 0
        local slot = num(args.slot, 0)
        local start, duration
        if slot and slot > 0 then
            if not _G.GetInventoryItemCooldown then return true end
            start, duration = _G.GetInventoryItemCooldown("player", slot)
        else
            local id = num(args.item_id, 0)
            if id == 0 then return false end
            if not _G.GetItemCooldown then return true end
            start, duration = _G.GetItemCooldown(id)
        end
        start = tonumber(start) or 0
        duration = tonumber(duration) or 0
        if duration <= 0 then return true end
        return (start + duration - now) <= 0
    end,
})

Conditions.register("threat_situation", {
    name = "Threat Situation",
    category = "Combat",
    description = "Your threat status on the target: 0 = low / not on the table, 1 = high threat but not tanking, 2 = tanking (insecure), 3 = tanking (secure). Compare against a level.",
    params = {
        { key = "op",    type = "string", default = ">=", label = "Operator", cycle = OP_CYCLE_COUNT },
        { key = "level", type = "number", default = 3, min = 0, max = 3, label = "Threat level (0-3)", step = 1 },
    },
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local sit = ctx.threat_situation
        if sit == nil and _G.UnitThreatSituation then
            sit = _G.UnitThreatSituation("player", "target")
        end
        local shim = { op = args.op, value = args.level, invert = args.invert }
        return cmp_op(num(sit, 0), shim, { op = ">=", value = 3 })
    end,
})

------------------------------------------------------------
-- Legacy shims (hidden = true). Each old id still evaluates for saved
-- rotations exactly as it used to; the picker doesn't show them, and
-- Engine.deserialize upgrades them to the new schema opportunistically.
------------------------------------------------------------

local function _legacy(id, def)
    def.hidden = true
    def.category = def.category or "General"
    Conditions.register(id, def)
end

_legacy("out_of_combat", {
    name = "Out of Combat (legacy)",
    eval = function(ctx) return not bool(ctx.in_combat, false) end,
})
_legacy("is_standing", {
    name = "Is Standing (legacy)",
    eval = function(ctx) return not bool(ctx.is_moving, false) end,
})
_legacy("not_mounted", {
    name = "Not Mounted (legacy)",
    eval = function(ctx) return not bool(ctx.is_mounted, false) end,
})
_legacy("not_casting", {
    name = "Not Casting/Channeling (legacy)",
    eval = function(ctx)
        return not bool(ctx.is_casting, false) and not bool(ctx.is_channeling, false)
    end,
})
_legacy("target_is_alive", {
    name = "Target Is Alive (legacy)",
    eval = function(ctx)
        return bool(ctx.target_exists, false) and not bool(ctx.target_is_dead, false)
    end,
})

-- Old auto-attack family (ROUND 49: runtime-native only — the Lua
-- IsCurrentSpell/IsAutoRepeatSpell are PROTECTED and taint the client).
local function _rt_auto_state()
    if not (RaijinLab and RaijinLab.RuntimeCall and RaijinLab.HasRuntime
        and RaijinLab:HasRuntime()) then return 0, 0 end
    local ok1, atk = pcall(RaijinLab.RuntimeCall, RaijinLab, "IsAttacking")
    local ok2, ar  = pcall(RaijinLab.RuntimeCall, RaijinLab, "AutoRepeatSpell")
    local melee = (ok1 and type(atk) == "string" and atk:match("^1")) and 1 or 0
    local shoot = (ok2 and tonumber(ar)) or 0
    return melee, shoot
end
local function _melee_active()
    local m, _ = _rt_auto_state()
    return m == 1
end
local function _shoot_active()
    local _, s = _rt_auto_state()
    return s == 75 or s == 5019
end
_legacy("auto_attacking",     { name = "Auto-Attacking (legacy)",         eval = function() return _melee_active() end })
_legacy("not_auto_attacking", { name = "Not Auto-Attacking (legacy)",     eval = function() return not _melee_active() end })
_legacy("auto_shooting",      { name = "Auto-Shooting (legacy)",          eval = function() return _shoot_active() end })
_legacy("not_auto_shooting",  { name = "Not Auto-Shooting (legacy)",      eval = function() return not _shoot_active() end })
_legacy("auto_repeating",     { name = "Auto-Repeating (legacy)",         eval = function() return _melee_active() or _shoot_active() end })

-- Old health/target-health/target-distance/ttd operator variants
_legacy("health_pct_below", {
    name = "Health % Below (legacy)",
    eval = function(ctx, args) return num(ctx.health_pct, 100) < num(args.pct, 50) end,
})
_legacy("health_pct_above", {
    name = "Health % Above (legacy)",
    eval = function(ctx, args) return num(ctx.health_pct, 100) > num(args.pct, 80) end,
})
_legacy("health_pct_between", {
    name = "Health % Between (legacy)",
    eval = function(ctx, args)
        local h = num(ctx.health_pct, 100)
        return h >= num(args.min, 0) and h <= num(args.max, 100)
    end,
})
_legacy("target_health_pct_below", {
    name = "Target Health % Below (legacy)",
    eval = function(ctx, args)
        return bool(ctx.target_exists, false) and num(ctx.target_health_pct, 100) < num(args.pct, 20)
    end,
})
_legacy("target_health_pct_above", {
    name = "Target Health % Above (legacy)",
    eval = function(ctx, args)
        return bool(ctx.target_exists, false) and num(ctx.target_health_pct, 100) > num(args.pct, 80)
    end,
})
_legacy("target_in_range", {
    name = "Target In Range (legacy)",
    eval = function(ctx, args)
        return bool(ctx.target_exists, false) and num(ctx.target_distance, 999) <= num(args.range, 5)
    end,
})
_legacy("target_out_of_range", {
    name = "Target Out Of Range (legacy)",
    eval = function(ctx, args)
        return bool(ctx.target_exists, false) and num(ctx.target_distance, 0) > num(args.range, 5)
    end,
})
_legacy("time_to_die_below", {
    name = "Target TTD Below (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local ttd = ctx.target_ttd
        if ttd == nil then return false end
        return num(ttd, 999) < num(args.seconds, 5)
    end,
})

-- Old enemies_in_range operator variants
_legacy("enemies_in_range_at_least", {
    name = "Enemies In Range >= (legacy)",
    eval = function(ctx, args) return count_enemies(ctx, args.range) >= num(args.n, 3) end,
})
_legacy("enemies_in_range_at_most", {
    name = "Enemies In Range <= (legacy)",
    eval = function(ctx, args) return count_enemies(ctx, args.range) <= num(args.n, 1) end,
})

-- Old power split
_legacy("power_pct_below", {
    name = "Power % Below (legacy)",
    eval = function(ctx, args)
        return _power_pct(ctx, _norm_power_type(args.power_type or args.ptype)) < num(args.pct, 40)
    end,
})
_legacy("power_pct_above", {
    name = "Power % Above (legacy)",
    eval = function(ctx, args)
        return _power_pct(ctx, _norm_power_type(args.power_type or args.ptype)) > num(args.pct, 60)
    end,
})
-- The amount family defaults power_type to "felfury" to MATCH its migration
-- (LEGACY_MIGRATIONS below). Without this, a saved record with power_type unset
-- reads the PRIMARY pool before migration and felfury after - opposite results
-- for identical data. Same reasoning for power_equals.
_legacy("power_amount_at_least", {
    name = "Power Amount >= (legacy)",
    eval = function(ctx, args)
        return _power_units(ctx, _norm_power_type(args.power_type or args.ptype or "felfury")) >= num(args.amount, 3)
    end,
})
_legacy("power_amount_at_most", {
    name = "Power Amount <= (legacy)",
    eval = function(ctx, args)
        return _power_units(ctx, _norm_power_type(args.power_type or args.ptype or "felfury")) <= num(args.amount, 1)
    end,
})
_legacy("power_amount_equals", {
    name = "Power Amount = (legacy)",
    eval = function(ctx, args)
        return _power_units(ctx, _norm_power_type(args.power_type or args.ptype or "felfury")) == num(args.amount, 6)
    end,
})
_legacy("power_at_least", {
    name = "Power >= (legacy)",
    eval = function(ctx, args)
        return power_value(ctx, args) >= num(args.value, 60)
    end,
})
_legacy("power_at_most", {
    name = "Power <= (legacy)",
    eval = function(ctx, args)
        return power_value(ctx, args) <= num(args.value, 40)
    end,
})
_legacy("power_equals", {
    name = "Power = (legacy)",
    -- Migration defaults this to felfury + units; the shim must match (a bare
    -- power_value() would default to primary + pct and flip the result).
    eval = function(ctx, args)
        return _power_units(ctx, _norm_power_type(args.power_type or args.ptype or "felfury")) == num(args.value, 0)
    end,
})
_legacy("power_between", {
    name = "Power In Range (legacy)",
    eval = function(ctx, args)
        local v = power_value(ctx, args)
        return v >= num(args.min, 0) and v <= num(args.max, 100)
    end,
})
_legacy("combo_points_at_least", {
    name = "Combo Points >= (legacy)",
    eval = function(ctx, args) return num(ctx.combo_points, 0) >= num(args.n, 5) end,
})

-- Old cooldown split
_legacy("cooldown_ready", {
    name = "Cooldown Ready (legacy)",
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local cds = ctx.cooldowns or {}
        local rem = cds[id] or cds[tostring(id)] or ctx.cooldown_remaining
        local is_ready = num(rem, 0) <= 0
        local want_ready = args.ready; if want_ready == nil then want_ready = true end
        if want_ready == false or want_ready == 0 or want_ready == "false" then
            return not is_ready
        end
        return is_ready
    end,
})
_legacy("cooldown_remaining_at_least", {
    name = "Cooldown Remaining >= (legacy)",
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local cds = ctx.cooldowns or {}
        local rem = cds[id] or cds[tostring(id)] or 0
        return num(rem, 0) >= num(args.seconds, 1)
    end,
})
_legacy("cooldown_remaining_at_most", {
    name = "Cooldown Remaining <= (legacy)",
    eval = function(ctx, args)
        local id = num(args.spell_id, 0)
        if id == 0 then id = num(ctx.slot_spell_id, 0) end
        local cds = ctx.cooldowns or {}
        local rem = cds[id] or cds[tostring(id)] or 0
        return num(rem, 0) <= num(args.seconds, 1.5)
    end,
})

-- Old aura family
_legacy("buff_present", {
    name = "Buff Present Self (legacy)",
    eval = function(ctx, args)
        if not aura_has(ctx.player_buffs, num(args.spell_id, 0), args.name) then return false end
        local stacks = aura_stat(ctx.player_buff_stacks, num(args.spell_id, 0), args.name)
        if stacks < 1 then stacks = 1 end
        if stacks < num(args.min_stacks, 1) then return false end
        local rem = aura_stat(ctx.player_buff_remaining, num(args.spell_id, 0), args.name)
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})
_legacy("buff_missing", {
    name = "Buff Missing Self (legacy)",
    eval = function(ctx, args)
        return not aura_has(ctx.player_buffs, num(args.spell_id, 0), args.name)
    end,
})
_legacy("buff_on_target", {
    name = "Buff On Target (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        if not aura_has(ctx.target_buffs, num(args.spell_id, 0), args.name) then return false end
        local stacks = aura_stat(ctx.target_buff_stacks, num(args.spell_id, 0), args.name)
        if stacks < 1 then stacks = 1 end
        if stacks < num(args.min_stacks, 1) then return false end
        local rem = aura_stat(ctx.target_buff_remaining, num(args.spell_id, 0), args.name)
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})
_legacy("buff_missing_on_target", {
    name = "Buff Missing On Target (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        return not aura_has(ctx.target_buffs, num(args.spell_id, 0), args.name)
    end,
})
_legacy("debuff_on_target", {
    name = "Debuff On Target (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        if not aura_has(ctx.target_debuffs, num(args.spell_id, 0), args.name) then return false end
        local stacks = aura_stat(ctx.target_debuff_stacks, num(args.spell_id, 0), args.name)
        if stacks < 1 then stacks = 1 end
        if stacks < num(args.min_stacks, 1) then return false end
        local rem = aura_stat(ctx.target_debuff_remaining, num(args.spell_id, 0), args.name)
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})
_legacy("debuff_missing_on_target", {
    name = "Debuff Missing On Target (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        return not aura_has(ctx.target_debuffs, num(args.spell_id, 0), args.name)
    end,
})
_legacy("buff_present_by_id", {
    name = "Buff Present Self by ID (legacy)",
    eval = function(ctx, args)
        local sid = num(args.spell_id, 0)
        if sid == 0 then return false end
        if not aura_has(ctx.player_buffs, sid, nil) then return false end
        local stacks = aura_stat(ctx.player_buff_stacks, sid, nil)
        if stacks < 1 then stacks = 1 end
        if stacks < num(args.min_stacks, 1) then return false end
        local rem = aura_stat(ctx.player_buff_remaining, sid, nil)
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})
_legacy("buff_missing_by_id", {
    name = "Buff Missing Self by ID (legacy)",
    eval = function(ctx, args)
        local sid = num(args.spell_id, 0)
        if sid == 0 then return false end
        return not aura_has(ctx.player_buffs, sid, nil)
    end,
})
_legacy("debuff_on_target_by_id", {
    name = "Debuff On Target by ID (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local sid = num(args.spell_id, 0)
        if sid == 0 then return false end
        if not aura_has(ctx.target_debuffs, sid, nil) then return false end
        local stacks = aura_stat(ctx.target_debuff_stacks, sid, nil)
        if stacks < 1 then stacks = 1 end
        if stacks < num(args.min_stacks, 1) then return false end
        local rem = aura_stat(ctx.target_debuff_remaining, sid, nil)
        if num(args.min_remaining, 0) > 0 and rem < num(args.min_remaining, 0) then return false end
        return true
    end,
})
_legacy("debuff_missing_on_target_by_id", {
    name = "Debuff Missing On Target by ID (legacy)",
    eval = function(ctx, args)
        if not bool(ctx.target_exists, false) then return false end
        local sid = num(args.spell_id, 0)
        if sid == 0 then return false end
        return not aura_has(ctx.target_debuffs, sid, nil)
    end,
})
_legacy("aura_stacks_at_least", {
    name = "Aura Stacks >= (legacy)",
    eval = function(ctx, args)
        local unit = string.lower(tostring(args.unit or "player"))
        local kind = string.lower(tostring(args.kind or "buff"))
        local present, stacks_tbl = aura_tables_for(ctx, unit, kind)
        if unit == "target" and not bool(ctx.target_exists, false) then return false end
        local stacks = aura_stat(stacks_tbl, num(args.spell_id, 0), args.name)
        if stacks < 1 and aura_has(present, num(args.spell_id, 0), args.name) then stacks = 1 end
        return stacks >= num(args.stacks, 1)
    end,
})
_legacy("aura_remaining_at_least", {
    name = "Aura Remaining >= (legacy)",
    eval = function(ctx, args)
        local unit = string.lower(tostring(args.unit or "player"))
        local kind = string.lower(tostring(args.kind or "buff"))
        if unit == "target" and not bool(ctx.target_exists, false) then return false end
        local _, _, rem_tbl = aura_tables_for(ctx, unit, kind)
        local rem = aura_stat(rem_tbl, num(args.spell_id, 0), args.name)
        return rem >= num(args.seconds, 3)
    end,
})

------------------------------------------------------------
-- Migration: legacy id -> new id + arg translator. Applied at
-- Engine.deserialize time so saved rotations opportunistically upgrade
-- to the unified schema. Old rotations continue to evaluate correctly
-- (via the hidden shims above) even if migration hasn't run yet.
------------------------------------------------------------

-- Copy the source condition's `invert` into the migrated record - but only
-- when the migrator hasn't already chosen an invert value. This matters for
-- flip migrations (e.g. out_of_combat -> in_combat with invert flipped):
-- unconditional copy would overwrite the flip with the source's own invert
-- and defeat the migration.
local function _keep_invert(a, next_args)
    if a and a.invert ~= nil and next_args.invert == nil then
        next_args.invert = a.invert
    end
    return next_args
end

Conditions.LEGACY_MIGRATIONS = {
    -- Combat / self flags: invert-only
    out_of_combat = { id = "in_combat",   translate = function(a) return _keep_invert(a, { invert = not (a and a.invert) }) end },
    is_standing   = { id = "is_moving",   translate = function(a) return _keep_invert(a, { invert = not (a and a.invert) }) end },
    not_mounted   = { id = "is_mounted",  translate = function(a) return _keep_invert(a, { invert = not (a and a.invert) }) end },
    not_casting   = { id = "is_casting",  translate = function(a) return { include_channel = true, invert = not (a and a.invert) } end },
    target_is_alive = { id = "target_is_dead", translate = function(a) return _keep_invert(a, { invert = not (a and a.invert) }) end },

    -- Auto-repeat family
    auto_attacking     = { id = "auto_repeat", translate = function(a) return _keep_invert(a, { mode = "melee" }) end },
    not_auto_attacking = { id = "auto_repeat", translate = function(a) return { mode = "melee",  invert = not (a and a.invert) } end },
    auto_shooting      = { id = "auto_repeat", translate = function(a) return _keep_invert(a, { mode = "ranged" }) end },
    not_auto_shooting  = { id = "auto_repeat", translate = function(a) return { mode = "ranged", invert = not (a and a.invert) } end },
    auto_repeating     = { id = "auto_repeat", translate = function(a) return _keep_invert(a, { mode = "any" }) end },

    -- Health / target-health operator variants
    health_pct_below   = { id = "health_pct", translate = function(a) return _keep_invert(a, { op = "<", value = num(a.pct, 50) }) end },
    health_pct_above   = { id = "health_pct", translate = function(a) return _keep_invert(a, { op = ">", value = num(a.pct, 80) }) end },
    health_pct_between = { id = "health_pct", translate = function(a) return _keep_invert(a, { op = "in_range", value = num(a.min, 20), value_max = num(a.max, 80) }) end },
    target_health_pct_below = { id = "target_health_pct", translate = function(a) return _keep_invert(a, { op = "<", value = num(a.pct, 20) }) end },
    target_health_pct_above = { id = "target_health_pct", translate = function(a) return _keep_invert(a, { op = ">", value = num(a.pct, 80) }) end },

    -- Target distance / TTD
    target_in_range     = { id = "target_distance", translate = function(a) return _keep_invert(a, { op = "<=", range = num(a.range, 5) }) end },
    target_out_of_range = { id = "target_distance", translate = function(a) return _keep_invert(a, { op = ">",  range = num(a.range, 5) }) end },
    time_to_die_below   = { id = "target_ttd",      translate = function(a) return _keep_invert(a, { op = "<",  seconds = num(a.seconds, 5) }) end },

    -- Enemies count
    enemies_in_range_at_least = { id = "enemies_in_range", translate = function(a) return _keep_invert(a, { op = ">=", count = num(a.n, 3), range = num(a.range, 8) }) end },
    enemies_in_range_at_most  = { id = "enemies_in_range", translate = function(a) return _keep_invert(a, { op = "<=", count = num(a.n, 1), range = num(a.range, 8) }) end },

    -- Power split (both older splits and the intermediate power_at_least set)
    power_pct_below       = { id = "power", translate = function(a) return _keep_invert(a, { op = "<",  mode = "pct",   value = num(a.pct, 40), power_type = a.power_type or "primary" }) end },
    power_pct_above       = { id = "power", translate = function(a) return _keep_invert(a, { op = ">",  mode = "pct",   value = num(a.pct, 60), power_type = a.power_type or "primary" }) end },
    power_amount_at_least = { id = "power", translate = function(a) return _keep_invert(a, { op = ">=", mode = "units", value = num(a.amount, 3), power_type = a.power_type or "felfury" }) end },
    power_amount_at_most  = { id = "power", translate = function(a) return _keep_invert(a, { op = "<=", mode = "units", value = num(a.amount, 1), power_type = a.power_type or "felfury" }) end },
    power_amount_equals   = { id = "power", translate = function(a) return _keep_invert(a, { op = "=",  mode = "units", value = num(a.amount, 6), power_type = a.power_type or "felfury" }) end },
    power_at_least        = { id = "power", translate = function(a) return _keep_invert(a, { op = ">=", mode = a.mode or "pct", value = num(a.value, 60), power_type = a.power_type or "primary" }) end },
    power_at_most         = { id = "power", translate = function(a) return _keep_invert(a, { op = "<=", mode = a.mode or "pct", value = num(a.value, 40), power_type = a.power_type or "primary" }) end },
    power_equals          = { id = "power", translate = function(a) return _keep_invert(a, { op = "=",  mode = a.mode or "units", value = num(a.value, 0), power_type = a.power_type or "felfury" }) end },
    power_between         = { id = "power", translate = function(a) return _keep_invert(a, { op = "in_range", mode = a.mode or "pct", value = num(a.min, 20), value_max = num(a.max, 80), power_type = a.power_type or "primary" }) end },
    combo_points_at_least = { id = "power", translate = function(a) return _keep_invert(a, { op = ">=", mode = "units", value = num(a.n, 5), power_type = "combo_points" }) end },

    -- Cooldown
    cooldown_ready = { id = "cooldown", translate = function(a)
        local want_ready = a.ready
        if want_ready == nil then want_ready = true end
        local op = (want_ready == false or want_ready == 0 or want_ready == "false") and "on_cd" or "ready"
        return _keep_invert(a, { op = op, spell_id = num(a.spell_id, 0) })
    end },
    cooldown_remaining_at_least = { id = "cooldown", translate = function(a) return _keep_invert(a, { op = ">=", seconds = num(a.seconds, 1),   spell_id = num(a.spell_id, 0) }) end },
    cooldown_remaining_at_most  = { id = "cooldown", translate = function(a) return _keep_invert(a, { op = "<=", seconds = num(a.seconds, 1.5), spell_id = num(a.spell_id, 0) }) end },

    -- Aura family
    buff_present            = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "player", kind = "buff",   state = "present", spell_id = num(a.spell_id, 0), name = a.name or "", min_stacks = num(a.min_stacks, 1), min_remaining = num(a.min_remaining, 0) }) end },
    buff_missing            = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "player", kind = "buff",   state = "missing", spell_id = num(a.spell_id, 0), name = a.name or "" }) end },
    buff_on_target          = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "buff",   state = "present", spell_id = num(a.spell_id, 0), name = a.name or "", min_stacks = num(a.min_stacks, 1), min_remaining = num(a.min_remaining, 0) }) end },
    buff_missing_on_target  = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "buff",   state = "missing", spell_id = num(a.spell_id, 0), name = a.name or "" }) end },
    debuff_on_target        = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "debuff", state = "present", spell_id = num(a.spell_id, 0), name = a.name or "", min_stacks = num(a.min_stacks, 1), min_remaining = num(a.min_remaining, 0) }) end },
    debuff_missing_on_target = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "debuff", state = "missing", spell_id = num(a.spell_id, 0), name = a.name or "" }) end },
    buff_present_by_id      = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "player", kind = "buff",   state = "present", spell_id = num(a.spell_id, 0), min_stacks = num(a.min_stacks, 1), min_remaining = num(a.min_remaining, 0) }) end },
    buff_missing_by_id      = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "player", kind = "buff",   state = "missing", spell_id = num(a.spell_id, 0) }) end },
    debuff_on_target_by_id  = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "debuff", state = "present", spell_id = num(a.spell_id, 0), min_stacks = num(a.min_stacks, 1), min_remaining = num(a.min_remaining, 0) }) end },
    debuff_missing_on_target_by_id = { id = "aura", translate = function(a) return _keep_invert(a, { unit = "target", kind = "debuff", state = "missing", spell_id = num(a.spell_id, 0) }) end },
    aura_stacks_at_least    = { id = "aura", translate = function(a) return _keep_invert(a, { unit = a.unit or "player", kind = a.kind or "buff", state = "present", spell_id = num(a.spell_id, 0), name = a.name or "", min_stacks = num(a.stacks, 1) }) end },
    aura_remaining_at_least = { id = "aura", translate = function(a) return _keep_invert(a, { unit = a.unit or "player", kind = a.kind or "buff", state = "present", spell_id = num(a.spell_id, 0), name = a.name or "", min_remaining = num(a.seconds, 3) }) end },
}

function Conditions.migrate_record(rec)
    if type(rec) ~= "table" then return rec end
    local mig = Conditions.LEGACY_MIGRATIONS and Conditions.LEGACY_MIGRATIONS[rec.id]
    if mig then
        rec.args = mig.translate(rec.args or {})
        rec.id = mig.id
    end
    -- aura_search field rename: retarget -> acquire_target; drop prefer_current
    -- and removed toggles (hostile_only / include_players).
    if rec.id == "aura_search" and type(rec.args) == "table" then
        local a = rec.args
        if a.acquire_target == nil and a.retarget ~= nil then
            a.acquire_target = a.retarget
        end
        a.prefer_current = nil
        a.hostile_only = nil
        a.include_players = nil
        -- reset_after only meaningful with acquire; force off when acquire off.
        local acq = a.acquire_target == true or a.acquire_target == 1 or a.acquire_target == "true"
            or a.retarget == true or a.retarget == 1 or a.retarget == "true"
        if not acq then
            a.reset_after = false
        end
    end
    return rec
end

if RaijinLab then
    RaijinLab.Conditions = Conditions
end

return Conditions
