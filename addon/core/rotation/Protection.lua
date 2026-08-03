-- Pure "is this unit protected from this ability?" evaluation.
-- No FrameScript dependency - unit-tested via lupa; World supplies live aura/flags.

local Protection = {}

-- School bit flags (WotLK SpellSchoolMask-style, simplified names)
Protection.SCHOOL = {
    physical = "physical",
    holy     = "holy",
    fire     = "fire",
    nature   = "nature",
    frost    = "frost",
    shadow   = "shadow",
    arcane   = "arcane",
    magic    = "magic", -- any non-physical
    all      = "all",
}

-- Catalog: aura name (lower) or spell id -> protection descriptor
-- kind: "immune" | "absorb" | "reflect" | "deflect" | "evade" | "dr"
-- schools: list of schools blocked (or {"all"})
-- amount_key: optional - if true, stacks/tooltip amount matters for absorb
local AURA_CATALOG = {
    -- Full immunities
    ["divine shield"]           = { kind = "immune", schools = { "all" } },
    [642]                       = { kind = "immune", schools = { "all" } },
    ["ice block"]               = { kind = "immune", schools = { "all" } },
    [45438]                     = { kind = "immune", schools = { "all" } },
    ["banish"]                  = { kind = "immune", schools = { "all" } },
    [710]                       = { kind = "immune", schools = { "all" } },
    [18647]                     = { kind = "immune", schools = { "all" } },
    ["cyclone"]                 = { kind = "immune", schools = { "all" } },
    [33786]                     = { kind = "immune", schools = { "all" } },
    ["dispersion"]              = { kind = "dr", schools = { "all" }, dr = 0.9 }, -- heavy DR, treat as soft
    [47585]                     = { kind = "dr", schools = { "all" }, dr = 0.9 },
    -- Physical immunity
    ["hand of protection"]      = { kind = "immune", schools = { "physical" } },
    ["blessing of protection"]  = { kind = "immune", schools = { "physical" } },
    [1022]                      = { kind = "immune", schools = { "physical" } },
    [5599]                      = { kind = "immune", schools = { "physical" } },
    [10278]                     = { kind = "immune", schools = { "physical" } },
    -- Magic immunity / cloak
    ["cloak of shadows"]        = { kind = "immune", schools = { "magic" } },
    [31224]                     = { kind = "immune", schools = { "magic" } },
    ["anti-magic shell"]        = { kind = "absorb", schools = { "magic" }, amount_key = true },
    [48707]                     = { kind = "absorb", schools = { "magic" }, amount_key = true },
    ["anti-magic zone"]         = { kind = "dr", schools = { "magic" }, dr = 0.75 },
    [50461]                     = { kind = "dr", schools = { "magic" }, dr = 0.75 },
    -- Reflect / ground
    ["spell reflection"]        = { kind = "reflect", schools = { "magic" } },
    [23920]                     = { kind = "reflect", schools = { "magic" } },
    ["grounding totem effect"]  = { kind = "reflect", schools = { "magic" } },
    ["grounding totem"]         = { kind = "reflect", schools = { "magic" } },
    [8178]                      = { kind = "reflect", schools = { "magic" } },
    -- Deterrence (physical + some spells)
    ["deterrence"]              = { kind = "deflect", schools = { "physical", "magic" } },
    [19263]                     = { kind = "deflect", schools = { "physical", "magic" } },
    -- Bladestorm magic immune
    ["bladestorm"]              = { kind = "immune", schools = { "magic" } },
    [46924]                     = { kind = "immune", schools = { "magic" } },
    -- Common absorbs (not full immune unless amount huge / treat_absorb)
    ["power word: shield"]      = { kind = "absorb", schools = { "all" }, amount_key = true },
    [17]                        = { kind = "absorb", schools = { "all" }, amount_key = true },
    [25217]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [25218]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [48065]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [48066]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    ["ice barrier"]             = { kind = "absorb", schools = { "all" }, amount_key = true },
    [11426]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [13031]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [43038]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [43039]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    ["mana shield"]             = { kind = "absorb", schools = { "all" }, amount_key = true },
    [1463]                      = { kind = "absorb", schools = { "all" }, amount_key = true },
    [43019]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    [43020]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    ["fire ward"]               = { kind = "absorb", schools = { "fire" }, amount_key = true },
    [543]                       = { kind = "absorb", schools = { "fire" }, amount_key = true },
    [43010]                     = { kind = "absorb", schools = { "fire" }, amount_key = true },
    ["frost ward"]              = { kind = "absorb", schools = { "frost" }, amount_key = true },
    [6143]                      = { kind = "absorb", schools = { "frost" }, amount_key = true },
    [43012]                     = { kind = "absorb", schools = { "frost" }, amount_key = true },
    ["sacred shield"]           = { kind = "absorb", schools = { "all" }, amount_key = true },
    [53601]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    ["bone shield"]             = { kind = "absorb", schools = { "all" }, amount_key = true },
    [49222]                     = { kind = "absorb", schools = { "all" }, amount_key = true },
    -- School-ish creature / boss patterns (matched by name contains)
}

-- Name substrings that imply full or school immunity (case-insensitive).
-- Keep patterns specific: bare "immune"/"evade" as free substrings false-positive
-- on custom/quest auras and mislabeled units (live: cast gates called everything
-- immune). Prefer "immunity", school-prefixed forms, and known ability names.
local NAME_PATTERNS = {
    { pattern = "immunity",         kind = "immune",  schools = { "all" } },
    { pattern = "invulnerab",       kind = "immune",  schools = { "all" } },
    { pattern = "divine shield",    kind = "immune",  schools = { "all" } },
    { pattern = "ice block",        kind = "immune",  schools = { "all" } },
    { pattern = "banish",           kind = "immune",  schools = { "all" } },
    { pattern = "cyclone",          kind = "immune",  schools = { "all" } },
    { pattern = "spell reflection", kind = "reflect", schools = { "magic" } },
    { pattern = "grounding totem",  kind = "reflect", schools = { "magic" } },
    { pattern = "cloak of shadows", kind = "immune",  schools = { "magic" } },
    { pattern = "anti%-magic shell", kind = "absorb", schools = { "magic" } },
    { pattern = "hand of protection", kind = "immune", schools = { "physical" } },
    { pattern = "blessing of protection", kind = "immune", schools = { "physical" } },
    { pattern = "deterrence",       kind = "deflect", schools = { "physical", "magic" } },
    { pattern = "dodge all",        kind = "deflect", schools = { "physical" } },
    -- "Immune to X" / "X Immune" forms (not bare substring "immune" alone).
    { pattern = "immune to ",       kind = "immune",  schools = { "all" } },
    { pattern = " is immune",       kind = "immune",  schools = { "all" } },
    -- School immunity bosses often use "Fire Immunity" etc.
    { pattern = "fire immune",      kind = "immune",  schools = { "fire" } },
    { pattern = "frost immune",     kind = "immune",  schools = { "frost" } },
    { pattern = "nature immune",    kind = "immune",  schools = { "nature" } },
    { pattern = "shadow immune",    kind = "immune",  schools = { "shadow" } },
    { pattern = "arcane immune",    kind = "immune",  schools = { "arcane" } },
    { pattern = "holy immune",      kind = "immune",  schools = { "holy" } },
    { pattern = "physical immune",  kind = "immune",  schools = { "physical" } },
    { pattern = "magic immune",     kind = "immune",  schools = { "magic" } },
}

-- Spell-id -> default school for common damage spells (expandable; auto falls back to "magic")
local SPELL_SCHOOL = {
    -- Physical
    [78] = "physical", [772] = "physical", [6343] = "physical", [12294] = "physical",
    [23881] = "physical", [47465] = "physical", [47475] = "physical", [47450] = "physical",
    [2098] = "physical", [48668] = "physical", [48666] = "physical", [48638] = "physical",
    [1752] = "physical", [26862] = "physical", [48691] = "physical",
    [2973] = "physical", [75] = "physical", -- Auto Shot
    -- Fire
    [133] = "fire", [11366] = "fire", [2120] = "fire", [2948] = "fire", [42833] = "fire",
    [42859] = "fire", [55360] = "fire", [11113] = "fire",
    -- Frost
    [116] = "frost", [122] = "frost", [10] = "frost", [30455] = "frost", [42842] = "frost",
    [42914] = "frost", [44572] = "frost",
    -- DK frost / disease (common ranks; name fallback also covers variants)
    [45477] = "frost", [49896] = "frost", [49903] = "frost", [49904] = "frost",
    [49909] = "frost", -- Icy Touch ranks
    [45524] = "frost", -- Chains of Ice
    [49184] = "frost", [51409] = "frost", [51410] = "frost", [51411] = "frost", -- Howling Blast
    -- Arcane
    [1449] = "arcane", [5143] = "arcane", [30451] = "arcane", [42897] = "arcane", [44425] = "arcane",
    -- Nature
    [403] = "nature", [421] = "nature", [1064] = "nature", [8050] = "nature", [49238] = "nature",
    [49271] = "nature", [60043] = "nature", [33763] = "nature",
    -- Shadow
    [686] = "shadow", [689] = "shadow", [980] = "shadow", [48125] = "shadow", [48181] = "shadow",
    [32379] = "shadow", [48158] = "shadow", [49821] = "shadow",
    -- Holy
    [585] = "holy", [14914] = "holy", [48135] = "holy", [34861] = "holy", [48785] = "holy",
    [635] = "holy", [19750] = "holy", [48801] = "holy", [48819] = "holy",
}

local MAGIC_SCHOOLS = {
    holy = true, fire = true, nature = true, frost = true, shadow = true, arcane = true,
}

local function lower(s)
    if s == nil then return "" end
    return string.lower(tostring(s))
end

function Protection.is_magic_school(school)
    school = lower(school)
    if school == "magic" then return true end
    return MAGIC_SCHOOLS[school] == true
end

function Protection.school_matches(blocker_schools, attack_school)
    attack_school = lower(attack_school or "magic")
    if not blocker_schools then return true end
    for _, s in ipairs(blocker_schools) do
        s = lower(s)
        if s == "all" then return true end
        if s == attack_school then return true end
        if s == "magic" and Protection.is_magic_school(attack_school) then return true end
    end
    return false
end

function Protection.guess_school(spell_id, name_hint, explicit)
    if explicit and explicit ~= "" and lower(explicit) ~= "auto" then
        return lower(explicit)
    end
    spell_id = tonumber(spell_id) or 0
    if spell_id > 0 and SPELL_SCHOOL[spell_id] then
        return SPELL_SCHOOL[spell_id]
    end
    local n = lower(name_hint or "")
    if n:find("strike") or n:find("slash") or n:find("shot") or n:find("rupture")
        or n:find("mangle") or n:find("shred") or n:find("hemorrhage")
        or n:find("mortal") or n:find("heroic") or n:find("bloodthirst")
        or n:find("sinister") or n:find("eviscerat") or n:find("backstab") then
        return "physical"
    end
    if n:find("fire") or n:find("pyro") or n:find("scorch") or n:find("immolate") or n:find("conflag") then
        return "fire"
    end
    if n:find("frost") or n:find("ice ") or n:find("icy ") or n:find("icy t")
        or n:find("freeze") or n:find("blizzard") or n:find("howling blast")
        or n:find("chains of ice") then
        return "frost"
    end
    if n:find("plague strike") or n:find("blood strike") or n:find("heart strike")
        or n:find("death strike") or n:find("rune strike") or n:find("scourge strike") then
        return "physical"
    end
    if n:find("arcane") or n:find("missile") then return "arcane" end
    if n:find("shadow") or n:find("mind ") or n:find("vampir") or n:find("haunt") or n:find("death coil") then
        return "shadow"
    end
    if n:find("holy") or n:find("smite") or n:find("consecrat") or n:find("exorcism") or n:find("flash of light") then
        return "holy"
    end
    if n:find("lightning") or n:find("earth ") or n:find("chain ") or n:find("stormstrike")
        or n:find("wrath") or n:find("starfire") or n:find("insect") then
        return "nature"
    end
    -- Default damaging ability assumption: magic (safer for "skip when cloaked")
    return "magic"
end

local function lookup_aura(key)
    if key == nil then return nil end
    local d = AURA_CATALOG[key]
    if d then return d end
    if type(key) == "string" then
        return AURA_CATALOG[lower(key)]
    end
    if type(key) == "number" then
        return AURA_CATALOG[key] or AURA_CATALOG[tostring(key)]
    end
    return nil
end

-- Scan presence tables (name/id -> true) + optional stacks/remaining
-- Returns list of { kind, schools, source, absorb_amount? }
function Protection.collect_effects(auras_present, absorb_amounts)
    local effects = {}
    auras_present = auras_present or {}
    absorb_amounts = absorb_amounts or {}
    local seen = {}

    local function add(desc, source)
        if not desc then return end
        local tag = (desc.kind or "?") .. ":" .. table.concat(desc.schools or {}, ",") .. ":" .. tostring(source)
        if seen[tag] then return end
        seen[tag] = true
        local e = {
            kind = desc.kind,
            schools = desc.schools,
            source = source,
            dr = desc.dr,
        }
        if desc.amount_key then
            e.absorb_amount = tonumber(absorb_amounts[source]) or tonumber(absorb_amounts[lower(tostring(source))]) or 0
        end
        effects[#effects + 1] = e
    end

    for key, present in pairs(auras_present) do
        if present then
            local desc = lookup_aura(key)
            if desc then
                add(desc, key)
            elseif type(key) == "string" then
                local lk = lower(key)
                for _, pat in ipairs(NAME_PATTERNS) do
                    if lk:find(pat.pattern) then
                        add({ kind = pat.kind, schools = pat.schools }, key)
                        break
                    end
                end
            end
        end
    end
    return effects
end

--[[
  Evaluate protection for a spell against a target snapshot.

  target = {
    exists, is_dead, can_attack, is_friend,
    buffs = { [name|id]=true },
    debuffs = { ... },  -- some immunities are debuffs (banish, cyclone)
    absorb_amounts = { [name|id]=n },
    creature_type = string,
    recent_miss = { school|spell_id -> { type="IMMUNE"|"ABSORB"|"DEFLECT"|"REFLECT"|"EVADE", t=... } },
  }
  opts = {
    spell_id, spell_name, school ("auto"|...),
    treat_absorb_as_protected = bool (default true for full-block decision when absorb known > 0),
    absorb_threshold = number (default 1 - any positive absorb matching school counts if treat_absorb),
    treat_dr_as_protected = bool (default false - 90% DR still "can damage"),
    treat_heavy_dr_as_protected = bool (default true if dr >= 0.75),
    respect_recent_miss = bool (default true),
    miss_ttl = seconds (default 2.0),
    now = number,
  }

  Returns: protected:boolean, reason:string, details:table
]]
function Protection.is_protected(target, opts)
    opts = opts or {}
    target = target or {}

    if not target.exists then
        return true, "no_target", { reason = "no_target" }
    end
    if target.is_dead then
        return true, "target_dead", { reason = "dead" }
    end
    -- Friendly target: damaging abilities "protected" in the sense of won't harm enemy;
    -- allow self-buffs via opts.allow_friend
    if target.is_friend and not opts.allow_friend and target.can_attack == false then
        return true, "friendly", { reason = "friendly" }
    end
    if target.can_attack == false and not opts.allow_friend then
        -- UnitCanAttack false (evade state, taxi, etc.)
        if target.exists then
            return true, "cannot_attack", { reason = "cannot_attack" }
        end
    end

    local school = Protection.guess_school(opts.spell_id, opts.spell_name, opts.school)
    local present = {}
    for k, v in pairs(target.buffs or {}) do present[k] = v end
    for k, v in pairs(target.debuffs or {}) do present[k] = v end

    local effects = Protection.collect_effects(present, target.absorb_amounts)
    local treat_absorb = opts.treat_absorb_as_protected
    if treat_absorb == nil then treat_absorb = true end
    local absorb_threshold = tonumber(opts.absorb_threshold) or 1
    local treat_heavy_dr = opts.treat_heavy_dr_as_protected
    if treat_heavy_dr == nil then treat_heavy_dr = true end
    local details = { school = school, effects = effects, blockers = {} }

    for _, e in ipairs(effects) do
        if Protection.school_matches(e.schools, school) then
            if e.kind == "immune" or e.kind == "reflect" or e.kind == "deflect" or e.kind == "evade" then
                details.blockers[#details.blockers + 1] = e
                return true, e.kind .. ":" .. tostring(e.source), details
            end
            if e.kind == "absorb" and treat_absorb then
                local amt = tonumber(e.absorb_amount) or 0
                -- Unknown amount: still treat school-specific wards / AMS as protected
                if amt >= absorb_threshold or amt == 0 then
                    -- amt==0 means we know the aura is up but not the number - still block
                    details.blockers[#details.blockers + 1] = e
                    return true, "absorb:" .. tostring(e.source), details
                end
            end
            if e.kind == "dr" and treat_heavy_dr and (tonumber(e.dr) or 0) >= 0.75 then
                details.blockers[#details.blockers + 1] = e
                return true, "heavy_dr:" .. tostring(e.source), details
            end
        end
    end

    -- Recent combat-log evidence (live)
    if opts.respect_recent_miss ~= false and target.recent_miss then
        local now = tonumber(opts.now) or 0
        local ttl = tonumber(opts.miss_ttl) or 2.0
        local sid = tonumber(opts.spell_id) or 0
        local candidates = {
            target.recent_miss[sid],
            target.recent_miss[tostring(sid)],
            target.recent_miss[school],
            target.recent_miss["all"],
            target.recent_miss["magic"],
        }
        for _, m in ipairs(candidates) do
            if m and m.type then
                local age = now > 0 and m.t and (now - m.t) or 0
                if now == 0 or not m.t or age <= ttl then
                    local t = string.upper(tostring(m.type))
                    if t == "IMMUNE" or t == "EVADE" or t == "DEFLECT" or t == "REFLECT"
                        or t == "MISS" and m.force then
                        details.blockers[#details.blockers + 1] = { kind = "recent_miss", type = t, source = m }
                        return true, "recent_miss:" .. t, details
                    end
                    if t == "ABSORB" and treat_absorb then
                        details.blockers[#details.blockers + 1] = { kind = "recent_miss", type = t }
                        return true, "recent_miss:ABSORB", details
                    end
                end
            end
        end
    end

    -- Creature-type soft rules (optional)
    local ct = lower(target.creature_type or "")
    if ct == "totem" and school ~= "physical" then
        -- many totems die to anything; don't block
    end

    return false, "vulnerable", details
end

-- Convenience for rotations: can this spell deal damage?
function Protection.can_damage(target, opts)
    local prot, reason, details = Protection.is_protected(target, opts)
    return not prot, reason, details
end

-- Cast-gate filter: is_protected() returns protected=true for relationship
-- states (no_target / dead / friendly / cannot_attack) so CONDITIONS like
-- target_can_take_damage stay correct. CAST GATES must not treat those as
-- "immune" - that froze non-aura_search slots and mislabeled live targets.
-- Only real combat protection blocks a cast attempt.
function Protection.blocks_cast(reason)
    if reason == nil or reason == false then return false end
    local r = tostring(reason)
    if r == "" or r == "vulnerable" then return false end
    if r == "no_target" or r == "target_dead" or r == "friendly"
        or r == "cannot_attack" then
        return false
    end
    -- immune:/reflect:/deflect:/evade:/absorb:/heavy_dr:/recent_miss:
    if r:find("^immune", 1, false) or r:find("^reflect", 1, false)
        or r:find("^deflect", 1, false) or r:find("^evade", 1, false)
        or r:find("^absorb", 1, false) or r:find("^heavy_dr", 1, false)
        or r:find("^recent_miss", 1, false) then
        return true
    end
    -- Bare kind without prefix (catalog may return "immune" alone).
    if r == "immune" or r == "reflect" or r == "deflect" or r == "evade" then
        return true
    end
    return false
end

-- Short wait-log label for cast-block reasons (keep "immune" prefix for real ones).
function Protection.cast_block_why(reason)
    local r = tostring(reason or "immune")
    if r:find("^immune", 1, false) or r == "immune" then return "immune" end
    if r:find("^reflect", 1, false) then return "reflect" end
    if r:find("^deflect", 1, false) then return "deflect" end
    if r:find("^evade", 1, false) then return "evade" end
    if r:find("^absorb", 1, false) then return "absorb" end
    if r:find("^heavy_dr", 1, false) then return "heavy_dr" end
    if r:find("^recent_miss", 1, false) then return "recent_miss" end
    return r
end

-- Register custom aura (addon or tests)
function Protection.register_aura(key, desc)
    AURA_CATALOG[key] = desc
    if type(key) == "string" then
        AURA_CATALOG[lower(key)] = desc
    end
end

function Protection.register_spell_school(spell_id, school)
    SPELL_SCHOOL[tonumber(spell_id)] = lower(school)
end

if RaijinLab then
    RaijinLab.Protection = Protection
end

return Protection
