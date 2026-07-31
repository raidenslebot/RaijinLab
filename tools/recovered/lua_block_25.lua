
fails = {}
function check(name, cond)
  if cond then
    print("  PASS  " .. name)
  else
    print("  FAIL  " .. name)
    fails[#fails+1] = name
  end
end

print("=== Conditions (shipped Conditions.lua) ===")
local ok, err = Conditions.evaluate_one({id="always", args={}}, {})
check("always passes", ok == true)
ok, err = Conditions.evaluate_one({id="never", args={}}, {})
check("never fails", ok == false)

ok = Conditions.evaluate_one({id="health_pct_below", args={pct=50}}, {health_pct=40})
check("health_pct_below 40<50", ok == true)
ok = Conditions.evaluate_one({id="health_pct_below", args={pct=50}}, {health_pct=80})
check("health_pct_below 80<50 false", ok == false)

ok = Conditions.evaluate_all({
  {id="in_combat", args={}},
  {id="target_is_enemy", args={}},
  {id="cooldown_ready", args={spell_id=123}},
}, {
  in_combat=true, target_exists=true, target_is_enemy=true, cooldowns={[123]=0},
})
check("AND all pass", ok == true)

ok = Conditions.evaluate_all({
  {id="in_combat", args={}},
  {id="health_pct_below", args={pct=30}},
}, {in_combat=true, health_pct=90})
check("AND fails on second", ok == false)

local catalog = Conditions.list()
check("condition catalog >= 20", #catalog >= 20)
local ids = {}
for _, c in ipairs(catalog) do ids[c.id] = true end
-- Consolidated visible ids the picker must expose (unified schema).
for _, need in ipairs({
  "aura","enemies_in_range","power","target_ttd","cooldown",
  "pvp_enemy_nearby","facing_target","gcd_ready","form_equals",
}) do
  check("has "..need, ids[need] == true)
end
-- Legacy ids must still be REGISTERED (hidden from picker but evaluable)
-- so saved rotations pre-migration keep casting.
local all_ids = {}
for _, r in ipairs(Conditions.list_all()) do all_ids[r.id] = true end
for _, legacy in ipairs({
  "buff_present","debuff_on_target","enemies_in_range_at_least",
  "combo_points_at_least","time_to_die_below","cooldown_ready",
}) do
  check("legacy still registered: "..legacy, all_ids[legacy] == true)
end

print("=== Rotation Engine (shipped Engine.lua) ===")
local rot = Engine.new_rotation("T")
Engine.ensure_trailing_empty(rot)
check("empty trail slot", #rot.slots == 1 and rot.slots[1].spell_id == 0)

Engine.add_slot(rot, {spell_id=100, name="First"})
Engine.add_slot(rot, {spell_id=200, name="Second"})
Engine.ensure_trailing_empty(rot)
check("two filled + empty", rot.slots[1].spell_id == 100 and rot.slots[2].spell_id == 200 and rot.slots[#rot.slots].spell_id == 0)

Engine.add_condition(rot, 1, {id="never", args={}})
Engine.add_condition(rot, 2, {id="always", args={}})
local act = Engine.evaluate(rot, {}, Conditions)
check("priority skips failed first", act ~= nil and act.spell_id == 200)

local rot2 = Engine.new_rotation("T2")
Engine.add_slot(rot2, {spell_id=10, name="A"})
Engine.add_slot(rot2, {spell_id=20, name="B"})
Engine.add_condition(rot2, 1, {id="health_pct_below", args={pct=50}})
Engine.add_condition(rot2, 2, {id="always", args={}})
local a1 = Engine.evaluate(rot2, {health_pct=80}, Conditions)
check("B when A health cond fails", a1 ~= nil and a1.spell_id == 20)
local a2 = Engine.evaluate(rot2, {health_pct=20}, Conditions)
check("A when health cond passes", a2 ~= nil and a2.spell_id == 10)

Engine.move_slot(rot2, 2, 1)
local a3 = Engine.evaluate(rot2, {health_pct=20}, Conditions)
check("reorder: B first now", a3 ~= nil and a3.spell_id == 20)

-- Pet-action slots have spell_id 0 but must NOT be collapsed as "empty".
local rotPet = Engine.new_rotation("PET")
Engine.ensure_trailing_empty(rotPet)  -- editor always has a trailing empty to drop onto
Engine.set_slot_action(rotPet, 1, {spell_id=0, name="Attack", action_type="petaction", pet_cmd="attack", pet_index=1})
check("petaction not-empty", not Engine.slot_is_empty(rotPet.slots[1]))
check("petaction survives collapse", rotPet.slots[1].action_type == "petaction" and rotPet.slots[1].pet_cmd == "attack")
check("petaction gets trailing empty", rotPet.slots[#rotPet.slots].spell_id == 0 and #rotPet.slots == 2)
-- Dragging repeatedly must never manufacture interior empties around a pet slot.
Engine.ensure_trailing_empty(rotPet)
Engine.ensure_trailing_empty(rotPet)
check("petaction stays single trailing empty", #rotPet.slots == 2)
-- Real spell slot with 0 id IS empty (guard the inverse).
check("spell id0 is empty", Engine.slot_is_empty({spell_id=0, action_type="spell"}))

-- ---- Persistence sanitizer ----------------------------------------------
local San = RaijinLab.Sanitize
check("sanitize exists", type(San) == "function")
-- keeps primitives + nested tables
local clean = San({ a = 1, b = "x", c = true, nested = { d = 2 } })
check("sanitize keeps data", clean.a == 1 and clean.b == "x" and clean.c == true and clean.nested.d == 2)
-- drops functions and (simulated) userdata-like values it can't serialize
local dirty = San({ keep = 5, fn = function() end, sub = { ok = 1, bad = print } })
check("sanitize drops function", dirty.keep == 5 and dirty.fn == nil and dirty.sub.ok == 1 and dirty.sub.bad == nil)
-- breaks reference cycles instead of infinite-looping
local cyc = { x = 1 }; cyc.self = cyc
local okc, res = pcall(San, cyc)
check("sanitize breaks cycle", okc and res.x == 1)
-- a rotation with a stray function survives serialize (function stripped, data kept)
local rotDirty = Engine.new_rotation("DIRTY")
Engine.ensure_trailing_empty(rotDirty)
Engine.set_slot_action(rotDirty, 1, {spell_id=123, name="Keep"})
rotDirty._frame = function() end            -- simulate accidental non-serializable field
local ser = Engine.serialize(rotDirty)
check("serialize strips non-serializable", ser._frame == nil and ser.slots[1].spell_id == 123)
-- round-trip preserves slots + conditions
Engine.add_condition(rotDirty, 1, {id="always", args={}})
local rt = Engine.deserialize(Engine.serialize(rotDirty))
check("serialize round-trip keeps slot", rt.slots[1].spell_id == 123)
check("serialize round-trip keeps condition", rt.slots[1].conditions[1].id == "always")

-- Empty conditions = always fire (no required scaffolding)
local rotEmpty = Engine.new_rotation("EMPTY")
Engine.add_slot(rotEmpty, {spell_id=999, name="Bare"})
check("empty cond list", #(rotEmpty.slots[1].conditions or {}) == 0)
local aE = Engine.evaluate(rotEmpty, {
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, Conditions)
check("empty conditions still picks spell", aE ~= nil and aE.spell_id == 999)

-- Built-in readiness fallthrough: slot1 on CD, no user conditions → slot2
local rotReady = Engine.new_rotation("READY")
Engine.add_slot(rotReady, {spell_id=100, name="OnCD"})
Engine.add_slot(rotReady, {spell_id=200, name="Ready"})
-- no conditions on either
local aR = Engine.evaluate(rotReady, {
  cooldowns={[100]=5.0, [200]=0},
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, Conditions)
check("built-in CD fallthrough no conds", aR ~= nil and aR.spell_id == 200)
local aR2 = Engine.evaluate(rotReady, {
  cooldowns={[100]=0, [200]=0},
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, Conditions)
check("both ready → first priority", aR2 ~= nil and aR2.spell_id == 100)

local aBusy = Engine.evaluate(rotReady, {
  is_casting=true, cooldowns={[100]=0,[200]=0},
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, Conditions)
check("player casting → no match", aBusy == nil)
-- Executor combat gate: require_attackable_target blocks no-target spam
local aNoT = Engine.evaluate(rotReady, {
  require_attackable_target=true, cooldowns={[100]=0,[200]=0}, target_exists=false,
}, Conditions)
check("no target → no cast spam", aNoT == nil)
local ready, why = Engine.spell_ready({
  require_attackable_target=true, cooldowns={[50]=0},
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, 50)
check("spell_ready free with target", ready == true)
ready, why = Engine.spell_ready({cooldowns={[50]=3}}, 50)
check("spell_ready on CD", ready == false and why == "cooldown")
ready, why = Engine.spell_ready({
  require_attackable_target=true, cooldowns={[50]=0}, target_exists=false,
}, 50)
check("spell_ready no_target", ready == false and why == "no_target")
local aOk = Engine.evaluate(rotReady, {
  require_attackable_target=true, cooldowns={[100]=0,[200]=0},
  target_exists=true, target_is_enemy=true, target_is_dead=false,
}, Conditions)
check("ready with target → first spell", aOk ~= nil and aOk.spell_id == 100)


-- condition reorder + remove
local rotC = Engine.new_rotation("COND")
Engine.add_slot(rotC, {spell_id=50, name="Test"})
Engine.add_condition(rotC, 1, {id="always", args={}})
Engine.add_condition(rotC, 1, {id="never", args={}})
Engine.add_condition(rotC, 1, {id="health_pct_below", args={pct=50}})
check("3 conditions", #rotC.slots[1].conditions == 3)
Engine.move_condition(rotC, 1, 3, 1)
check("move_condition to front", rotC.slots[1].conditions[1].id == "health_pct_below")
Engine.remove_condition(rotC, 1, 2) -- remove always (now index 2 after move: health, always, never)
check("remove_condition", #rotC.slots[1].conditions == 2)
check("remove kept health first", rotC.slots[1].conditions[1].id == "health_pct_below")

local ser = Engine.serialize(rot2)
local rot3 = Engine.deserialize(ser)
local a4 = Engine.evaluate(rot3, {health_pct=20}, Conditions)
check("deserialize preserves order", a4 ~= nil and a4.spell_id == 20)

-- GCD condition on slot1 only; built-in no longer blocks all on gcd_remaining
local rot4 = Engine.new_rotation("GCD")
Engine.add_slot(rot4, {spell_id=1, name="GCDBlocked"})
Engine.add_slot(rot4, {spell_id=2, name="Free"})
Engine.add_condition(rot4, 1, {id="gcd_ready", args={}})
Engine.add_condition(rot4, 2, {id="always", args={}})
local g1 = Engine.evaluate(rot4, {gcd_remaining=1.2}, Conditions)
check("gcd cond fails → second slot", g1 ~= nil and g1.spell_id == 2)
local g2 = Engine.evaluate(rot4, {gcd_remaining=0}, Conditions)
check("gcd allows first when ready", g2 ~= nil and g2.spell_id == 1)
-- gcd_active (executor-tracked GCD window) blocks all normal spells...
local gS = Engine.evaluate(rot4, {gcd_active=true}, Conditions)
check("gcd_active blocks all normal spells", gS == nil)
-- ...but an off_gcd slot bypasses it (weaves during the GCD).
do
  local rotOG = Engine.new_rotation("OFFGCD")
  Engine.add_slot(rotOG, {spell_id=5, name="OffGcd", off_gcd=true})
  Engine.add_slot(rotOG, {spell_id=6, name="Normal"})
  local og = Engine.evaluate(rotOG, {gcd_active=true}, Conditions)
  check("off_gcd slot bypasses gcd_active", og ~= nil and og.spell_id == 5)
  -- A rotation of only normal slots is fully blocked during the GCD window.
  local rotN = Engine.new_rotation("NORM")
  Engine.add_slot(rotN, {spell_id=6, name="Normal"})
  check("gcd_active blocks a normal-only rotation", Engine.evaluate(rotN, {gcd_active=true}, Conditions) == nil)
end
-- Cast/channel weaving: while casting, cast-time spells are blocked but instants
-- (auto-detected) and while_casting-flagged slots still fire.
do
  local rotC = Engine.new_rotation("CAST")
  Engine.add_slot(rotC, {spell_id=7, name="CastTime"})
  Engine.add_slot(rotC, {spell_id=8, name="Instant"})
  local c1 = Engine.evaluate(rotC, {is_casting=true, spell_instant={[7]=false, [8]=true}}, Conditions)
  check("casting: instant weaves past cast-time slot", c1 ~= nil and c1.spell_id == 8)
  local c2 = Engine.evaluate(rotC, {is_casting=true, spell_instant={[7]=false, [8]=false}}, Conditions)
  check("casting: no instant -> nothing fires", c2 == nil)
  -- while_casting flag forces a cast-time spell through
  local rotW = Engine.new_rotation("WHILECAST")
  Engine.add_slot(rotW, {spell_id=9, name="Forced", while_casting=true})
  local w1 = Engine.evaluate(rotW, {is_casting=true, spell_instant={[9]=false}}, Conditions)
  check("while_casting flag lets a cast-time slot fire while casting", w1 ~= nil and w1.spell_id == 9)
  -- channeling behaves the same
  local ch = Engine.evaluate(rotC, {is_channeling=true, spell_instant={[7]=false, [8]=true}}, Conditions)
  check("channeling: instant weaves", ch ~= nil and ch.spell_id == 8)
end
-- User condition alone (ignore built-in gcd via zero remaining, condition on slot1 only):
local rot4b = Engine.new_rotation("GCD2")
Engine.add_slot(rot4b, {spell_id=1, name="NeedsGcdCond"})
Engine.add_slot(rot4b, {spell_id=2, name="Always"})
Engine.add_condition(rot4b, 1, {id="never", args={}})
Engine.add_condition(rot4b, 2, {id="always", args={}})
local g3 = Engine.evaluate(rot4b, {gcd_remaining=0}, Conditions)
check("condition fallthrough still works", g3 ~= nil and g3.spell_id == 2)

print("=== SpellUtil (shipped SpellUtil.lua) ===")
local id1 = SpellUtil.spell_id_from_link("|cff71d5ff|Hspell:133|h[Fireball]|h|r")
check("parse Hspell link", id1 == 133)
local id2 = SpellUtil.spell_id_from_link("spell:2098")
check("parse raw spell: link", id2 == 2098)
check("parse empty nil", SpellUtil.spell_id_from_link("") == nil)

-- Simulate 3.3.5 cursor: slot=12, bookType=spell → GetSpellLink returns hyperlink
local function fake_link(slot, book)
  assert(slot == 12 and book == "spell")
  return "|Hspell:47540|h[Penance]|h"
end
local function fake_name(slot, book) return "Penance" end
local function fake_info(id) if id == 47540 then return "Penance" end end
local sid, sname = SpellUtil.resolve_spellbook_cursor(12, "spell", fake_link, fake_name, fake_info)
check("resolve spellbook cursor id", sid == 47540)
check("resolve spellbook cursor name", sname == "Penance")

local auras = { Rejuvenation = true }
SpellUtil.mark_aura_ids(auras, {774, 8936}, function(id)
  if id == 774 then return "Rejuvenation" end
  if id == 8936 then return "Regrowth" end
end)
check("mark aura id from name", auras[774] == true)
check("unmarked missing aura", auras[8936] ~= true)

-- buff_present uses name key
local bp = Conditions.evaluate_one(
  {id="buff_present", args={spell_id=774, name="Rejuvenation"}},
  {player_buffs={Rejuvenation=true, [774]=true}}
)
check("buff_present by id after mark", bp == true)
local bm = Conditions.evaluate_one(
  {id="buff_missing", args={spell_id=8936}},
  {player_buffs={Rejuvenation=true, [774]=true}}
)
check("buff_missing when absent", bm == true)
local cool = Conditions.evaluate_one(
  {id="cooldown_ready", args={spell_id=133}},
  {cooldowns={[133]=1.5}}
)
check("cooldown_ready false when rem>0", cool == false)
local cool2 = Conditions.evaluate_one(
  {id="cooldown_ready", args={spell_id=133}},
  {cooldowns={[133]=0}}
)
check("cooldown_ready true when rem=0", cool2 == true)

-- ready=false means "must be on cooldown"
local oncd = Conditions.evaluate_one(
  {id="cooldown_ready", args={spell_id=133, ready=false}},
  {cooldowns={[133]=5}}
)
check("cooldown_ready ready=false when on CD", oncd == true)
local oncd2 = Conditions.evaluate_one(
  {id="cooldown_ready", args={spell_id=133, ready=false}},
  {cooldowns={[133]=0}}
)
check("cooldown_ready ready=false fails when ready", oncd2 == false)

-- universal invert
local inv = Conditions.evaluate_one(
  {id="always", args={invert=true}},
  {}
)
check("invert always => false", inv == false)
local inv2 = Conditions.evaluate_one(
  {id="never", args={invert=true}},
  {}
)
check("invert never => true", inv2 == true)

local atmost = Conditions.evaluate_one(
  {id="cooldown_remaining_at_most", args={spell_id=1, seconds=2}},
  {cooldowns={[1]=1.0}}
)
check("cooldown_remaining_at_most", atmost == true)

print("=== Conditions upgrades (target buffs, stacks, range, power, usable) ===")
-- target buffs (not only debuffs)
local tbo = Conditions.evaluate_one(
  {id="buff_on_target", args={spell_id=774, name="Rejuvenation"}},
  {target_exists=true, target_buffs={Rejuvenation=true, [774]=true}}
)
check("buff_on_target present", tbo == true)
local tbo_miss = Conditions.evaluate_one(
  {id="buff_on_target", args={spell_id=774}},
  {target_exists=true, target_buffs={}}
)
check("buff_on_target missing", tbo_miss == false)
local tbo_notgt = Conditions.evaluate_one(
  {id="buff_on_target", args={spell_id=774}},
  {target_exists=false, target_buffs={[774]=true}}
)
check("buff_on_target requires target", tbo_notgt == false)
local tbm = Conditions.evaluate_one(
  {id="buff_missing_on_target", args={spell_id=774}},
  {target_exists=true, target_buffs={}}
)
check("buff_missing_on_target", tbm == true)

-- stacks / remaining
local st = Conditions.evaluate_one(
  {id="buff_present", args={spell_id=48517, min_stacks=2}},
  {player_buffs={[48517]=true}, player_buff_stacks={[48517]=3}}
)
check("buff_present min_stacks 3>=2", st == true)
local st_fail = Conditions.evaluate_one(
  {id="buff_present", args={spell_id=48517, min_stacks=5}},
  {player_buffs={[48517]=true}, player_buff_stacks={[48517]=2}}
)
check("buff_present min_stacks 2<5 fails", st_fail == false)
local rem_ok = Conditions.evaluate_one(
  {id="buff_present", args={spell_id=774, min_remaining=3}},
  {player_buffs={[774]=true}, player_buff_remaining={[774]=5.5}}
)
check("buff_present min_remaining 5.5>=3", rem_ok == true)
local rem_fail = Conditions.evaluate_one(
  {id="buff_present", args={spell_id=774, min_remaining=10}},
  {player_buffs={[774]=true}, player_buff_remaining={[774]=2}}
)
check("buff_present min_remaining 2<10 fails", rem_fail == false)

local as = Conditions.evaluate_one(
  {id="aura_stacks_at_least", args={spell_id=1822, stacks=3, unit="target", kind="debuff"}},
  {target_exists=true, target_debuffs={[1822]=true}, target_debuff_stacks={[1822]=5}}
)
check("aura_stacks_at_least target debuff", as == true)
local ar = Conditions.evaluate_one(
  {id="aura_remaining_at_least", args={spell_id=774, seconds=2, unit="player", kind="buff"}},
  {player_buff_remaining={[774]=4}}
)
check("aura_remaining_at_least player buff", ar == true)

-- power type selection
local pp = Conditions.evaluate_one(
  {id="power_pct_below", args={pct=50, power_type="rage"}},
  {power_pct=90, power_by_type={rage=20, mana=90}}
)
check("power_pct_below rage 20<50", pp == true)
local pp2 = Conditions.evaluate_one(
  {id="power_pct_below", args={pct=50, power_type="mana"}},
  {power_pct=20, power_by_type={rage=20, mana=90}}
)
check("power_pct_below mana 90<50 false", pp2 == false)
local pp3 = Conditions.evaluate_one(
  {id="power_pct_above", args={pct=80, power_type="energy"}},
  {power_by_type={energy=100}}
)
check("power_pct_above energy", pp3 == true)
local pp_primary = Conditions.evaluate_one(
  {id="power_pct_below", args={pct=40, power_type="primary"}},
  {power_pct=30, power_by_type={mana=90}}
)
check("power_pct primary uses power_pct", pp_primary == true)

-- arbitrary enemy range via count_enemies_within
local ectx = {
  count_enemies_within = function(r)
    local dists = {3, 7, 12, 25}
    local n = 0
    for _, d in ipairs(dists) do if d <= r then n = n + 1 end end
    return n
  end,
  enemies_in_8 = 2, enemies_in_10 = 2, enemies_in_40 = 4,
}
local e1 = Conditions.evaluate_one(
  {id="enemies_in_range_at_least", args={n=3, range=15}},
  ectx
)
check("enemies range=15 count 3>=3", e1 == true)
local e2 = Conditions.evaluate_one(
  {id="enemies_in_range_at_least", args={n=3, range=8}},
  ectx
)
check("enemies range=8 count 2>=3 false", e2 == false)
local e3 = Conditions.evaluate_one(
  {id="enemies_in_range_at_most", args={n=1, range=5}},
  ectx
)
check("enemies range=5 at most 1 (count=1)", e3 == true)
-- bucket fallback without function
local e4 = Conditions.evaluate_one(
  {id="enemies_in_range_at_least", args={n=2, range=8}},
  {enemies_in_8=3}
)
check("enemies bucket fallback 8yd", e4 == true)

-- spell_usable
local su = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_range=true, require_known=true, require_off_cd=true}},
  {
    known_spells={[133]=true}, cooldowns={[133]=0},
    spell_usable={[133]=true}, spell_in_range={[133]=true},
  }
)
check("spell_usable all gates pass", su == true)
local su_cd = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133}},
  {
    known_spells={[133]=true}, cooldowns={[133]=3},
    spell_usable={[133]=true}, spell_in_range={[133]=true},
  }
)
check("spell_usable fails on CD", su_cd == false)
local su_range = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_range=true}},
  {
    known_spells={[133]=true}, cooldowns={[133]=0},
    spell_usable={[133]=true}, spell_in_range={[133]=false},
  }
)
check("spell_usable fails out of range", su_range == false)
local su_norange = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_range=false}},
  {
    known_spells={[133]=true}, cooldowns={[133]=0},
    spell_usable={[133]=true}, spell_in_range={[133]=false},
  }
)
check("spell_usable ignore range ok", su_norange == true)
local su_slot = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=0}},
  {
    slot_spell_id=2098, known_spells={[2098]=true}, cooldowns={[2098]=0},
    spell_usable={[2098]=true}, spell_in_range={[2098]=true},
  }
)
check("spell_usable 0=slot spell", su_slot == true)

-- Pure World shape: spell_usable is IsUsableSpell only (resource/stance), not CD/known.
-- require_off_cd=false must succeed when rem>0 if resource-usable is true.
local su_ignore_cd = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_off_cd=false, require_known=true, require_range=false}},
  {
    known_spells={[133]=true},
    cooldowns={[133]=12.5},
    spell_usable={[133]=true},  -- pure IsUsableSpell (mana ok)
    spell_in_range={[133]=true},
  }
)
check("spell_usable require_off_cd=false when rem>0", su_ignore_cd == true)
-- require_off_cd=true still fails when rem>0 (same pure usable table)
local su_need_cd = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_off_cd=true, require_known=true, require_range=false}},
  {
    known_spells={[133]=true},
    cooldowns={[133]=12.5},
    spell_usable={[133]=true},
    spell_in_range={[133]=true},
  }
)
check("spell_usable require_off_cd=true fails when rem>0", su_need_cd == false)
-- require_known=false when known=false but resource-usable true
local su_ignore_known = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_known=false, require_off_cd=true, require_range=false}},
  {
    known_spells={[133]=false},
    cooldowns={[133]=0},
    spell_usable={[133]=true},
    spell_in_range={[133]=true},
  }
)
check("spell_usable require_known=false when unknown", su_ignore_known == true)
-- require_known=true must fail when known=false even if pure IsUsableSpell is true
-- (no fallback that treats resource-usable as known)
local su_need_known = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_known=true, require_off_cd=false, require_range=false}},
  {
    known_spells={[133]=false},
    cooldowns={[133]=0},
    spell_usable={[133]=true},  -- pure resource OK but unlearned
    spell_in_range={[133]=true},
  }
)
check("spell_usable require_known=true fails unknown even if pure usable", su_need_known == false)
-- also fails when both unknown and pure-unusable
local su_need_known2 = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_known=true, require_off_cd=false, require_range=false}},
  {
    known_spells={[133]=false},
    cooldowns={[133]=0},
    spell_usable={[133]=false},
    spell_in_range={[133]=true},
  }
)
check("spell_usable require_known=true fails unknown+unusable", su_need_known2 == false)
-- pure spell_usable=false always fails (resource/stance) even if known and off CD
local su_resource = Conditions.evaluate_one(
  {id="spell_usable", args={spell_id=133, require_known=false, require_off_cd=false, require_range=false}},
  {
    known_spells={[133]=true},
    cooldowns={[133]=0},
    spell_usable={[133]=false},
    spell_in_range={[133]=true},
  }
)
check("spell_usable pure false fails regardless of require_*", su_resource == false)

-- gcd ready=false
local gcd_on = Conditions.evaluate_one(
  {id="gcd_ready", args={ready=false}},
  {gcd_remaining=1.0}
)
check("gcd_ready ready=false when on GCD", gcd_on == true)
local gcd_off = Conditions.evaluate_one(
  {id="gcd_ready", args={ready=false}},
  {gcd_remaining=0}
)
check("gcd_ready ready=false fails when free", gcd_off == false)

-- multi-param intermediate fail-then-pass via engine priority
local rot5 = Engine.new_rotation("MULTI")
Engine.add_slot(rot5, {spell_id=100, name="Burst"})
Engine.add_slot(rot5, {spell_id=200, name="Filler"})
Engine.add_condition(rot5, 1, {id="cooldown_ready", args={spell_id=100, ready=true}})
Engine.add_condition(rot5, 1, {id="buff_present", args={spell_id=48517, min_stacks=2}})
Engine.add_condition(rot5, 2, {id="always", args={}})
-- intermediate: CD ready but stacks fail → skip to filler
local m1 = Engine.evaluate(rot5, {
  cooldowns={[100]=0}, player_buffs={[48517]=true}, player_buff_stacks={[48517]=1},
}, Conditions)
check("multi-param intermediate stacks fail → filler", m1 ~= nil and m1.spell_id == 200)
-- both pass → burst
local m2 = Engine.evaluate(rot5, {
  cooldowns={[100]=0}, player_buffs={[48517]=true}, player_buff_stacks={[48517]=3},
}, Conditions)
check("multi-param both pass → burst", m2 ~= nil and m2.spell_id == 100)
-- invert on second gate of first slot
Engine.add_condition(rot5, 1, {id="is_moving", args={invert=true}})
local m3 = Engine.evaluate(rot5, {
  cooldowns={[100]=0}, player_buffs={[48517]=true}, player_buff_stacks={[48517]=3},
  is_moving=true,
}, Conditions)
check("invert is_moving blocks burst while moving", m3 ~= nil and m3.spell_id == 200)
local m4 = Engine.evaluate(rot5, {
  cooldowns={[100]=0}, player_buffs={[48517]=true}, player_buff_stacks={[48517]=3},
  is_moving=false,
}, Conditions)
check("invert is_moving allows burst standing", m4 ~= nil and m4.spell_id == 100)

-- The upgraded aura/cooldown/spell params live under the unified ids now.
-- Verify the unified defs expose the expected params.
local function _has_param(def_id, key)
    local def = Conditions.get(def_id)
    if not def or not def.params then return false end
    for _, p in ipairs(def.params) do if p.key == key then return true end end
    return false
end
check("aura has unit param",           _has_param("aura", "unit"))
check("aura has kind param",           _has_param("aura", "kind"))
check("aura has state param",          _has_param("aura", "state"))
check("aura has min_stacks param",     _has_param("aura", "min_stacks"))
check("aura has min_remaining param",  _has_param("aura", "min_remaining"))
check("cooldown has op param",         _has_param("cooldown", "op"))
check("cooldown has seconds param",    _has_param("cooldown", "seconds"))
check("spell_usable has spell_id",     _has_param("spell_usable", "spell_id"))
check("spell_in_range has spell_id",   _has_param("spell_in_range", "spell_id"))

-- default_args: new cooldown carries op + seconds; universal invert included
local da_cd = Conditions.default_args("cooldown")
check("default_args(cooldown) has invert", da_cd.invert == false)
check("default_args(cooldown) has op",     da_cd.op == "ready")

print("=== Protection (shipped Protection.lua) ===")
local bare = { exists=true, is_dead=false, can_attack=true, is_friend=false, buffs={}, debuffs={} }
local p, r = Protection.is_protected(bare, {spell_id=133, spell_name="Fireball", school="auto"})
check("vulnerable naked target", p == false)

local ds = { exists=true, is_dead=false, can_attack=true, buffs={["Divine Shield"]=true, [642]=true}, debuffs={} }
p, r = Protection.is_protected(ds, {spell_id=133, spell_name="Fireball"})
check("divine shield blocks fireball", p == true and tostring(r):find("immune") ~= nil)

p, r = Protection.is_protected(ds, {spell_id=78, spell_name="Heroic Strike", school="physical"})
check("divine shield blocks physical too", p == true)

local hop = { exists=true, can_attack=true, buffs={["Hand of Protection"]=true}, debuffs={} }
p = Protection.is_protected(hop, {spell_id=78, school="physical"})
check("HoP blocks physical", p == true)
p = Protection.is_protected(hop, {spell_id=133, spell_name="Fireball", school="fire"})
check("HoP allows fire", p == false)

local cloak = { exists=true, can_attack=true, buffs={["Cloak of Shadows"]=true}, debuffs={} }
p = Protection.is_protected(cloak, {spell_id=133, school="fire"})
check("cloak blocks magic", p == true)
p = Protection.is_protected(cloak, {spell_id=78, school="physical"})
check("cloak allows physical", p == false)

local ward = { exists=true, can_attack=true, buffs={["Fire Ward"]=true}, debuffs={}, absorb_amounts={["Fire Ward"]=5000} }
p = Protection.is_protected(ward, {spell_id=133, school="fire", treat_absorb_as_protected=true})
check("fire ward absorbs fire", p == true)
p = Protection.is_protected(ward, {spell_id=116, school="frost", treat_absorb_as_protected=true})
check("fire ward allows frost", p == false)

local dead = { exists=true, is_dead=true, can_attack=true, buffs={} }
p, r = Protection.is_protected(dead, {spell_id=133})
check("dead is protected", p == true and r == "target_dead")

local notgt = { exists=false }
p, r = Protection.is_protected(notgt, {spell_id=133})
check("no target protected", p == true and r == "no_target")

local reflect = { exists=true, can_attack=true, buffs={["Spell Reflection"]=true} }
p = Protection.is_protected(reflect, {spell_id=133, school="fire"})
check("spell reflect blocks magic", p == true)

-- CLEU recent miss
local miss = {
  exists=true, can_attack=true, buffs={},
  recent_miss={ [133]={ type="IMMUNE", t=10 }, fire={ type="IMMUNE", t=10 } },
}
p = Protection.is_protected(miss, {spell_id=133, school="fire", now=11, miss_ttl=2})
check("recent CLEU immune blocks", p == true)
p = Protection.is_protected(miss, {spell_id=133, school="fire", now=20, miss_ttl=2})
check("stale CLEU immune expires", p == false)

local can = Protection.can_damage(bare, {spell_id=133})
check("can_damage naked", can == true)
local can2 = Protection.can_damage(ds, {spell_id=133})
check("can_damage DS false", can2 == false)

-- Condition wiring: target_can_take_damage skips protected high-prio
local ok_prot = Conditions.evaluate_one(
  {id="target_protected", args={spell_id=133}},
  {target_exists=true, target_buffs={["Divine Shield"]=true}, target_is_enemy=true}
)
check("cond target_protected DS", ok_prot == true)

local ok_can = Conditions.evaluate_one(
  {id="target_can_take_damage", args={spell_id=0}},
  {
    slot_spell_id=133, target_exists=true, target_is_enemy=true,
    target_buffs={["Divine Shield"]=true},
  }
)
check("cond can_take_damage DS false", ok_can == false)

local ok_can2 = Conditions.evaluate_one(
  {id="target_can_take_damage", args={spell_id=0}},
  {
    slot_spell_id=133, target_exists=true, target_is_enemy=true,
    target_buffs={},
  }
)
check("cond can_take_damage naked true", ok_can2 == true)

-- Priority: fireball blocked by cloak → heroic strike physical works
local rotP = Engine.new_rotation("PROT")
Engine.add_slot(rotP, {spell_id=133, name="Fireball"})
Engine.add_slot(rotP, {spell_id=78, name="Heroic Strike"})
Engine.add_condition(rotP, 1, {id="target_can_take_damage", args={spell_id=0, school="auto"}})
Engine.add_condition(rotP, 2, {id="target_can_take_damage", args={spell_id=0, school="physical"}})
local ctxP = {
  target_exists=true, target_is_enemy=true, target_is_dead=false,
  target_buffs={["Cloak of Shadows"]=true},
}
local actP = Engine.evaluate(rotP, ctxP, Conditions)
check("priority: skip fireball under cloak → physical", actP ~= nil and actP.spell_id == 78)

local ctxP2 = {
  target_exists=true, target_is_enemy=true, target_is_dead=false,
  target_buffs={},
}
local actP2 = Engine.evaluate(rotP, ctxP2, Conditions)
check("priority: fireball when vulnerable", actP2 ~= nil and actP2.spell_id == 133)

-- HoP: physical blocked, fire works
local rotH = Engine.new_rotation("HOP")
Engine.add_slot(rotH, {spell_id=78, name="Heroic Strike"})
Engine.add_slot(rotH, {spell_id=133, name="Fireball"})
Engine.add_condition(rotH, 1, {id="target_can_take_damage", args={}})
Engine.add_condition(rotH, 2, {id="target_can_take_damage", args={}})
local actH = Engine.evaluate(rotH, {
  target_exists=true, target_is_enemy=true,
  target_buffs={["Hand of Protection"]=true},
}, Conditions)
check("priority: skip physical under HoP → fire", actH ~= nil and actH.spell_id == 133)

for _, need in ipairs({"target_protected", "target_can_take_damage"}) do
  check("has "..need, ids[need] == true)
end

print("=== Nav (shipped Nav.lua) ===")
local p, c = Nav.shortest_path({x=0,y=0,z=0}, {x=10,y=0,z=0}, {}, {}, {})
check("direct path 2 nodes", p ~= nil and #p == 2)
check("direct cost ~10", c > 9.9 and c < 10.1)

local obs = {{x=5, y=0, z=0, radius=2}}
local p2, e2 = Nav.shortest_path({x=0,y=0,z=0}, {x=10,y=0,z=0}, {}, obs, {})
check("blocked direct", p2 == nil)

local nodes = {{id="side", x=5, y=8, z=0}}
local p3, c3 = Nav.shortest_path({x=0,y=0,z=0}, {x=10,y=0,z=0}, nodes, obs, {})
check("path via waypoint", p3 ~= nil and #p3 >= 3)

local kind, slope = Nav.classify_slope(0, 5, 10)
check("slope class", kind == "incline" or kind == "flat" or kind == "steep")

local ents = Nav.obstacles_from_entities({{x=1,y=1,bounding_radius=2}}, 1.5)
check("obstacle from entity", #ents == 1 and ents[1].radius == 2)

print("=== Engine invariants (regression: stale-rotation fix) ===")
-- The Editor stale-closure bug was: callbacks captured `rotation` by upvalue
-- from Refresh, then a later Refresh re-deserialized a fresh copy. Mutating
-- the stale table and saving it silently dropped intervening changes.
-- We can't test the Editor UI without WoW, but we CAN prove the Engine
-- treats two independently-deserialized rotations as fully independent, so
-- the "re-fetch at fire time" fix is well-defined:
local rotA = Engine.new_rotation("SAVED")
Engine.add_slot(rotA, {spell_id=1, name="A"})
Engine.add_slot(rotA, {spell_id=2, name="B"})
local ser = Engine.serialize(rotA)
local liveOld = Engine.deserialize(ser)   -- simulates the stale capture
local liveNew = Engine.deserialize(ser)   -- simulates a Refresh re-read
Engine.add_condition(liveNew, 1, {id="always", args={}})
Engine.set_slot_action(liveNew, 2, {spell_id=99, name="B-edited"})
check("independent deserializations do not alias", liveOld.slots[2].spell_id == 2)
check("independent deserializations mutate independently", liveNew.slots[2].spell_id == 99)
check("independent conditions do not leak", (#(liveOld.slots[1].conditions or {})) == 0)
-- Round-trip after mutation: serialize the fresh one, deserialize again ->
-- exactly the edited state (Save + Refresh should round-trip losslessly).
local ser2 = Engine.serialize(liveNew)
local roundtrip = Engine.deserialize(ser2)
check("save+reload roundtrip preserves edit", roundtrip.slots[2].spell_id == 99)
check("save+reload roundtrip preserves condition", (#(roundtrip.slots[1].conditions or {})) == 1)

