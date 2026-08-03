
-- Unified power conditions: pct mode
local u1 = Conditions.evaluate_one(
  {id="power_at_most", args={value=50, mode="pct", power_type="rage"}},
  {power_pct=90, power_by_type={rage=20, mana=90}}
)
check("power_at_most pct rage 20<=50", u1 == true)
local u2 = Conditions.evaluate_one(
  {id="power_at_least", args={value=80, mode="pct", power_type="energy"}},
  {power_by_type={energy=100}}
)
check("power_at_least pct energy 100>=80", u2 == true)
local u3 = Conditions.evaluate_one(
  {id="power_between", args={min=20, max=60, mode="pct", power_type="mana"}},
  {power_by_type={mana=45}}
)
check("power_between pct mana 45 in [20,60]", u3 == true)

-- Unified power conditions: units mode (FelFury scenario)
local ff_ctx = {
  power_amount = 3, power_amount_max = 6,
  power_amount_by_type = {felfury=3, mana=5000},
  power_amount_max_by_type = {felfury=6, mana=15000},
}
local u4 = Conditions.evaluate_one(
  {id="power_at_least", args={value=3, mode="units", power_type="felfury"}},
  ff_ctx
)
check("power_at_least units felfury 3>=3", u4 == true)
local u5 = Conditions.evaluate_one(
  {id="power_at_least", args={value=4, mode="units", power_type="felfury"}},
  ff_ctx
)
check("power_at_least units felfury 3>=4 false", u5 == false)
local u6 = Conditions.evaluate_one(
  {id="power_equals", args={value=6, mode="units", power_type="felfury"}},
  {power_amount_by_type={felfury=6}}
)
check("power_equals units felfury 6==6", u6 == true)
local u7 = Conditions.evaluate_one(
  {id="power_at_most", args={value=1, mode="units", power_type="felfury"}},
  {power_amount_by_type={felfury=0}}
)
check("power_at_most units felfury 0<=1", u7 == true)

-- Invert on the unified condition
local u8 = Conditions.evaluate_one(
  {id="power_at_most", args={value=1, mode="units", power_type="felfury", invert=true}},
  {power_amount_by_type={felfury=0}}
)
check("power_at_most inverted", u8 == false)

-- Missing power type falls through to primary
local u9 = Conditions.evaluate_one(
  {id="power_at_least", args={value=50, mode="pct", power_type="nonexistent"}},
  {power_pct=75}
)
check("unknown power_type falls to primary pct", u9 == true)

-- Legacy shims still evaluate exactly as they used to
local L1 = Conditions.evaluate_one(
  {id="power_amount_at_least", args={amount=3, power_type="felfury"}},
  {power_amount_by_type={felfury=4}}
)
check("legacy power_amount_at_least still works", L1 == true)
local L2 = Conditions.evaluate_one(
  {id="power_pct_below", args={pct=40, power_type="mana"}},
  {power_by_type={mana=30}}
)
check("legacy power_pct_below still works", L2 == true)

-- Shim default alignment (audit fix): a saved amount-family / power_equals
-- record with NO power_type must read FELFURY (matching its migration), not the
-- primary pool - otherwise the same data flips result before vs after migration.
local mixed = {
  power_pct=100, power_amount=5000,
  power_amount_by_type={felfury=0, mana=5000},
  power_amount_max_by_type={felfury=6, mana=15000},
}
check("shim power_amount_at_least (no ptype) uses felfury not primary",
  Conditions.evaluate_one({id="power_amount_at_least", args={amount=3}}, mixed) == false)
check("shim power_amount_at_most (no ptype) uses felfury not primary",
  Conditions.evaluate_one({id="power_amount_at_most", args={amount=1}}, mixed) == true)
local full = {
  power_pct=100, power_amount=5000,
  power_amount_by_type={felfury=6, mana=5000},
  power_amount_max_by_type={felfury=6, mana=15000},
}
check("shim power_equals (no ptype/mode) uses felfury units not primary pct",
  Conditions.evaluate_one({id="power_equals", args={value=6}}, full) == true)

-- Absent-pool guard (audit fix): World now reports max=0 for a felfury pool the
-- character doesn't have, so a felfury condition is SUPPRESSED (never fires) even
-- for the '<=' direction that a naive 0<=1 would pass.
local absent = { power_amount_by_type={felfury=0}, power_amount_max_by_type={felfury=0} }
check("felfury '>=' suppressed when pool absent",
  Conditions.evaluate_one({id="power", args={op=">=", value=1, mode="units", power_type="felfury"}}, absent) == false)
check("felfury '<=' suppressed when pool absent (not a false 0<=1)",
  Conditions.evaluate_one({id="power", args={op="<=", value=1, mode="units", power_type="felfury"}}, absent) == false)
-- ...but a PRESENT felfury pool at 0 still evaluates normally (0 <= 1 = true).
local present0 = { power_amount_by_type={felfury=0}, power_amount_max_by_type={felfury=6} }
check("felfury '<=' fires when pool present at 0",
  Conditions.evaluate_one({id="power", args={op="<=", value=1, mode="units", power_type="felfury"}}, present0) == true)

-- Numeric power_type (old saved data) resolves to the right pool in units mode.
local dk = { power_amount=1200, power_amount_by_type={runes=4}, power_amount_max_by_type={runes=6} }
check("numeric ptype 5 -> runes units (not primary)",
  Conditions.evaluate_one({id="power", args={op=">=", value=3, mode="units", power_type=5}}, dk) == true)

-- Legacy shims are hidden from the UI picker
local cat = Conditions.list()
local seen_pct_below, seen_at_most = false, false
for _, row in ipairs(cat) do
  if row.id == "power_pct_below" then seen_pct_below = true end
  if row.id == "power_at_most"   then seen_at_most   = true end
end
check("legacy power_pct_below hidden from list()", seen_pct_below == false)
-- power_at_most was an intermediate id (superseded by unified `power` with
-- op cycle). It's now a hidden legacy shim itself.
check("intermediate power_at_most also hidden", seen_at_most == false)

-- Engine.deserialize migrates legacy ids into unified schema
local legacy_rot = {
  name = "legacy",
  slots = { {
    id = "s1",
    spell_id = 1,
    conditions = {
      {id="power_pct_below",       args={pct=40, power_type="mana"}},
      {id="power_amount_at_least", args={amount=3, power_type="felfury"}},
    },
  } },
}
local upgraded = Engine.deserialize(legacy_rot)
local c1 = upgraded.slots[1].conditions[1]
local c2 = upgraded.slots[1].conditions[2]
check("migrate power_pct_below -> power", c1.id == "power")
check("migrate keeps pct value",          tonumber(c1.args.value) == 40)
check("migrate sets mode=pct",            c1.args.mode == "pct")
check("migrate op=<",                     c1.args.op == "<")
check("migrate keeps power_type=mana",    c1.args.power_type == "mana")
check("migrate power_amount_at_least -> power", c2.id == "power")
check("migrate sets mode=units",          c2.args.mode == "units")
check("migrate op=>=",                    c2.args.op == ">=")
check("migrate keeps units value",        tonumber(c2.args.value) == 3)

------------------------------------------------------------
-- Consolidated conditions (2026-07 pass)
------------------------------------------------------------
print("=== Consolidated conditions ===")

-- Unified `power` condition with op cycle
local P1 = Conditions.evaluate_one(
  {id="power", args={op=">=", value=50, mode="pct", power_type="rage"}},
  {power_by_type={rage=60, mana=90}, power_amount_max_by_type={rage=100, mana=15000}}
)
check("power >= pct rage 60>=50", P1 == true)
local P2 = Conditions.evaluate_one(
  {id="power", args={op="<=", value=50, mode="pct", power_type="rage"}},
  {power_by_type={rage=60}, power_amount_max_by_type={rage=100}}
)
check("power <= pct rage 60<=50 false", P2 == false)
local P3 = Conditions.evaluate_one(
  {id="power", args={op="=", value=6, mode="units", power_type="felfury"}},
  {power_amount_by_type={felfury=6}, power_amount_max_by_type={felfury=6}}
)
check("power = units felfury 6==6", P3 == true)
local P4 = Conditions.evaluate_one(
  {id="power", args={op="in_range", value=20, value_max=60, mode="pct", power_type="mana"}},
  {power_by_type={mana=45}, power_amount_max_by_type={mana=15000}}
)
check("power in_range pct mana 45 in [20,60]", P4 == true)
local P5 = Conditions.evaluate_one(
  {id="power", args={op="<", value=40, mode="pct", power_type="mana"}},
  {power_by_type={mana=39.9}, power_amount_max_by_type={mana=15000}}
)
check("power strict < 39.9<40", P5 == true)
local P5b = Conditions.evaluate_one(
  {id="power", args={op="<", value=40, mode="pct", power_type="mana"}},
  {power_by_type={mana=40}, power_amount_max_by_type={mana=15000}}
)
check("power strict < 40<40 false", P5b == false)

-- Absent-pool guard: max=0 -> false regardless of comparison direction
local Pguard1 = Conditions.evaluate_one(
  {id="power", args={op=">=", value=1, mode="pct", power_type="felfury"}},
  {power_by_type={felfury=100}, power_amount_max_by_type={felfury=0}}
)
check("power absent pool short-circuits to false (>=)", Pguard1 == false)
local Pguard2 = Conditions.evaluate_one(
  {id="power", args={op="<=", value=99, mode="pct", power_type="felfury"}},
  {power_by_type={felfury=0}, power_amount_max_by_type={felfury=0}}
)
check("power absent pool short-circuits to false (<=)", Pguard2 == false)

-- Combo points via POWER_CUSTOM synthetic pool (test provides direct ctx)
local Pcombo = Conditions.evaluate_one(
  {id="power", args={op=">=", value=5, mode="units", power_type="combo_points"}},
  {power_amount_by_type={combo_points=5}, power_amount_max_by_type={combo_points=5}}
)
check("power >= units combo_points 5>=5", Pcombo == true)

-- Unified health_pct
local H1 = Conditions.evaluate_one({id="health_pct", args={op="<=", value=30}}, {health_pct=25})
check("health_pct <= 25<=30", H1 == true)
local H2 = Conditions.evaluate_one({id="health_pct", args={op="in_range", value=20, value_max=80}}, {health_pct=50})
check("health_pct in_range 50 in [20,80]", H2 == true)

-- Unified target_health_pct
local TH = Conditions.evaluate_one(
  {id="target_health_pct", args={op="<=", value=20}},
  {target_exists=true, target_health_pct=15}
)
check("target_health_pct <= 15<=20", TH == true)

-- Unified target_distance
local TD1 = Conditions.evaluate_one(
  {id="target_distance", args={op="<=", range=5}},
  {target_exists=true, target_distance=3}
)
check("target_distance <= 3<=5", TD1 == true)
local TD2 = Conditions.evaluate_one(
  {id="target_distance", args={op=">", range=5}},
  {target_exists=true, target_distance=10}
)
check("target_distance > 10>5", TD2 == true)

-- Unified target_ttd
local TT = Conditions.evaluate_one(
  {id="target_ttd", args={op="<=", seconds=5}},
  {target_exists=true, target_ttd=3}
)
check("target_ttd <= 3<=5", TT == true)
-- target_ttd in_range uses seconds..value_max (the UI now exposes value_max)
local TTr = Conditions.evaluate_one(
  {id="target_ttd", args={op="in_range", seconds=3, value_max=8}},
  {target_exists=true, target_ttd=5}
)
check("target_ttd in_range 5 in [3,8]", TTr == true)
local TTr2 = Conditions.evaluate_one(
  {id="target_ttd", args={op="in_range", seconds=3, value_max=8}},
  {target_exists=true, target_ttd=10}
)
check("target_ttd in_range 10 not in [3,8]", TTr2 == false)

-- Unified enemies_in_range
local EA = Conditions.evaluate_one(
  {id="enemies_in_range", args={op=">=", count=3, range=8}},
  {enemies_in_8=4}
)
check("enemies_in_range >= 4>=3", EA == true)
local EB = Conditions.evaluate_one(
  {id="enemies_in_range", args={op="<=", count=1, range=5}},
  {count_enemies_within = function(r) return 1 end}
)
check("enemies_in_range <= 1<=1", EB == true)

-- Unified cooldown
local CD1 = Conditions.evaluate_one(
  {id="cooldown", args={op="ready", spell_id=101}},
  {cooldowns={[101]=0}}
)
check("cooldown ready", CD1 == true)
local CD2 = Conditions.evaluate_one(
  {id="cooldown", args={op="on_cd", spell_id=101}},
  {cooldowns={[101]=3}}
)
check("cooldown on_cd", CD2 == true)
local CD3 = Conditions.evaluate_one(
  {id="cooldown", args={op=">=", seconds=2, spell_id=101}},
  {cooldowns={[101]=3}}
)
check("cooldown remaining >= 2", CD3 == true)
local CD4 = Conditions.evaluate_one(
  {id="cooldown", args={op="<=", seconds=2, spell_id=101}},
  {cooldowns={[101]=1}}
)
check("cooldown remaining <= 2", CD4 == true)

-- Unified aura
local A1 = Conditions.evaluate_one(
  {id="aura", args={unit="player", kind="buff", state="present", spell_id=774}},
  {player_buffs={[774]=true}, player_buff_stacks={[774]=1}, player_buff_remaining={[774]=10}}
)
check("aura present player buff by id", A1 == true)
local A2 = Conditions.evaluate_one(
  {id="aura", args={unit="target", kind="debuff", state="present", spell_id=1822, min_stacks=3}},
  {target_exists=true, target_debuffs={[1822]=true}, target_debuff_stacks={[1822]=5}, target_debuff_remaining={[1822]=8}}
)
check("aura present target debuff min_stacks", A2 == true)
local A3 = Conditions.evaluate_one(
  {id="aura", args={unit="player", kind="buff", state="missing", spell_id=774}},
  {player_buffs={}}
)
check("aura missing player buff", A3 == true)
local A4 = Conditions.evaluate_one(
  {id="aura", args={unit="target", kind="debuff", state="present"}},
  {target_exists=false}
)
check("aura no-target returns false", A4 == false)

-- Unified auto_repeat: relies on globals that don't exist in lupa; behavior
-- when APIs missing should be false.
local AR = Conditions.evaluate_one({id="auto_repeat", args={mode="melee"}}, {})
check("auto_repeat with no API -> false", AR == false)

-- is_casting with include_channel
local IC1 = Conditions.evaluate_one(
  {id="is_casting", args={include_channel=false}},
  {is_casting=false, is_channeling=true}
)
check("is_casting no-channel: channel-only -> false", IC1 == false)
local IC2 = Conditions.evaluate_one(
  {id="is_casting", args={include_channel=true}},
  {is_casting=false, is_channeling=true}
)
check("is_casting with-channel: channel-only -> true", IC2 == true)

-- Legacy shims still evaluate under old ids
local L_new1 = Conditions.evaluate_one(
  {id="out_of_combat", args={}}, {in_combat=false}
)
check("legacy out_of_combat still works", L_new1 == true)
local L_new2 = Conditions.evaluate_one(
  {id="target_is_alive", args={}}, {target_exists=true, target_is_dead=false}
)
check("legacy target_is_alive still works", L_new2 == true)

-- Migration: out_of_combat -> in_combat inverted.
-- spell_id required or ensure_trailing_empty drops the slot as "empty".
local mig_rot = {
  slots = { {
    spell_id = 42,
    conditions = {
      {id="out_of_combat",           args={}},
      {id="health_pct_below",        args={pct=30}},
      {id="target_health_pct_above", args={pct=80}},
      {id="target_in_range",         args={range=5}},
      {id="enemies_in_range_at_least", args={n=3, range=8}},
      {id="cooldown_ready",          args={spell_id=101}},
      {id="buff_present",            args={spell_id=774}},
      {id="buff_missing_on_target",  args={spell_id=1822}},
      {id="debuff_on_target",        args={spell_id=1822, min_stacks=2}},
      {id="aura_stacks_at_least",    args={spell_id=774, stacks=3, unit="player", kind="buff"}},
      {id="combo_points_at_least",   args={n=5}},
      {id="auto_repeating",          args={}},
    },
  } },
}
local mig_up = Engine.deserialize(mig_rot)
local mc = mig_up.slots[1].conditions
check("migrate out_of_combat -> in_combat invert=true",   mc[1].id == "in_combat" and mc[1].args.invert == true)
check("migrate health_pct_below -> health_pct op=<",      mc[2].id == "health_pct" and mc[2].args.op == "<" and mc[2].args.value == 30)
check("migrate target_health_pct_above",                  mc[3].id == "target_health_pct" and mc[3].args.op == ">" and mc[3].args.value == 80)
check("migrate target_in_range -> target_distance",       mc[4].id == "target_distance" and mc[4].args.op == "<=" and mc[4].args.range == 5)
check("migrate enemies_in_range_at_least",                mc[5].id == "enemies_in_range" and mc[5].args.op == ">=" and mc[5].args.count == 3)
check("migrate cooldown_ready -> cooldown op=ready",      mc[6].id == "cooldown" and mc[6].args.op == "ready")
check("migrate buff_present -> aura",                     mc[7].id == "aura" and mc[7].args.unit == "player" and mc[7].args.state == "present")
check("migrate buff_missing_on_target -> aura missing",   mc[8].id == "aura" and mc[8].args.unit == "target" and mc[8].args.state == "missing")
check("migrate debuff_on_target keeps min_stacks",        mc[9].id == "aura" and mc[9].args.kind == "debuff" and mc[9].args.min_stacks == 2)
check("migrate aura_stacks_at_least",                     mc[10].id == "aura" and mc[10].args.min_stacks == 3)
check("migrate combo_points_at_least -> power combo",     mc[11].id == "power" and mc[11].args.power_type == "combo_points" and mc[11].args.value == 5)
check("migrate auto_repeating -> auto_repeat any",        mc[12].id == "auto_repeat" and mc[12].args.mode == "any")

-- End-to-end: migrated conditions actually evaluate correctly
local ee_ok = Conditions.evaluate_one(mc[2], {health_pct=25})
check("migrated health_pct_below evaluates <", ee_ok == true)
local ee2_ok = Conditions.evaluate_one(mc[1], {in_combat=false})
check("migrated out_of_combat still means 'not in combat'", ee2_ok == true)
local ee3_ok = Conditions.evaluate_one(mc[7], {player_buffs={[774]=true}, player_buff_stacks={[774]=1}})
check("migrated buff_present still evaluates true", ee3_ok == true)

-- Picker filters hidden: none of the ~30 legacy ids should appear
local visible_ids = {}
for _, row in ipairs(Conditions.list()) do visible_ids[row.id] = true end
for _, hidden_id in ipairs({
  "out_of_combat","is_standing","not_mounted","not_casting","target_is_alive",
  "auto_attacking","not_auto_attacking","auto_shooting","not_auto_shooting","auto_repeating",
  "health_pct_below","health_pct_above","health_pct_between",
  "target_health_pct_below","target_health_pct_above",
  "target_in_range","target_out_of_range","time_to_die_below",
  "enemies_in_range_at_least","enemies_in_range_at_most",
  "power_pct_below","power_pct_above","power_amount_at_least","power_amount_at_most",
  "power_amount_equals","power_at_least","power_at_most","power_equals","power_between",
  "combo_points_at_least",
  "cooldown_ready","cooldown_remaining_at_least","cooldown_remaining_at_most",
  "buff_present","buff_missing","buff_on_target","buff_missing_on_target",
  "debuff_on_target","debuff_missing_on_target",
  "buff_present_by_id","buff_missing_by_id","debuff_on_target_by_id","debuff_missing_on_target_by_id",
  "aura_stacks_at_least","aura_remaining_at_least",
}) do
  check("hidden from picker: " .. hidden_id, visible_ids[hidden_id] == nil)
end
-- Sanity: the unified names ARE visible
for _, visible_id in ipairs({
  "in_combat","is_moving","is_mounted","is_casting","auto_repeat",
  "health_pct","power","target_health_pct","target_distance","target_ttd",
  "enemies_in_range","cooldown","aura","target_is_dead",
}) do
  check("visible in picker: " .. visible_id, visible_ids[visible_id] == true)
end

-- ---- New live-state conditions (ctx-override path) ----------------
print("=== Live-state conditions ===")
check("is_stealthed true", Conditions.evaluate_one({id="is_stealthed", args={}}, {is_stealthed=true}) == true)
check("is_stealthed false", Conditions.evaluate_one({id="is_stealthed", args={}}, {is_stealthed=false}) == false)
check("is_stealthed inverted", Conditions.evaluate_one({id="is_stealthed", args={invert=true}}, {is_stealthed=false}) == true)

check("target_is_player true", Conditions.evaluate_one({id="target_is_player", args={}}, {target_exists=true, target_is_player=true}) == true)
check("target_is_player needs target", Conditions.evaluate_one({id="target_is_player", args={}}, {target_exists=false, target_is_player=true}) == false)

-- target_casting: kind + interruptible + min_remaining
check("target_casting any while casting", Conditions.evaluate_one({id="target_casting", args={kind="any"}}, {target_exists=true, target_casting=true, target_cast_remaining=2}) == true)
check("target_casting cast-kind ignores channel", Conditions.evaluate_one({id="target_casting", args={kind="cast"}}, {target_exists=true, target_channeling=true}) == false)
check("target_casting channel-kind matches channel", Conditions.evaluate_one({id="target_casting", args={kind="channel"}}, {target_exists=true, target_channeling=true, target_cast_remaining=1}) == true)
check("target_casting not casting", Conditions.evaluate_one({id="target_casting", args={kind="any"}}, {target_exists=true, target_casting=false, target_channeling=false}) == false)
check("target_casting interruptible_only blocks uninterruptible", Conditions.evaluate_one({id="target_casting", args={kind="any", interruptible_only=true}}, {target_exists=true, target_casting=true, target_cast_interruptible=false}) == false)
check("target_casting min_remaining gate", Conditions.evaluate_one({id="target_casting", args={kind="any", min_remaining=3}}, {target_exists=true, target_casting=true, target_cast_remaining=1}) == false)

-- target_classification: value match + boss special
check("classification elite match", Conditions.evaluate_one({id="target_classification", args={value="elite"}}, {target_exists=true, target_classification="elite"}) == true)
check("classification normal not elite", Conditions.evaluate_one({id="target_classification", args={value="elite"}}, {target_exists=true, target_classification="normal"}) == false)
check("classification boss via worldboss", Conditions.evaluate_one({id="target_classification", args={value="boss"}}, {target_exists=true, target_classification="worldboss"}) == true)
check("classification boss via level -1", Conditions.evaluate_one({id="target_classification", args={value="boss"}}, {target_exists=true, target_classification="elite", target_level=-1}) == true)

-- group_size: op comparison over injected size
check("group_size >=2 with 5", Conditions.evaluate_one({id="group_size", args={op=">=", count=2}}, {group_size=5}) == true)
check("group_size =1 solo", Conditions.evaluate_one({id="group_size", args={op="=", count=1}}, {group_size=1}) == true)
check("group_size >=5 with 3 false", Conditions.evaluate_one({id="group_size", args={op=">=", count=5}}, {group_size=3}) == false)

-- item_ready: ctx override
check("item_ready true", Conditions.evaluate_one({id="item_ready", args={item_id=12345}}, {item_ready=true}) == true)
check("item_ready false", Conditions.evaluate_one({id="item_ready", args={item_id=12345}}, {item_ready=false}) == false)

-- threat_situation
check("threat >=3 tanking secure", Conditions.evaluate_one({id="threat_situation", args={op=">=", level=3}}, {target_exists=true, threat_situation=3}) == true)
check("threat >=3 with 1 false", Conditions.evaluate_one({id="threat_situation", args={op=">=", level=3}}, {target_exists=true, threat_situation=1}) == false)
check("threat needs target", Conditions.evaluate_one({id="threat_situation", args={op=">=", level=1}}, {target_exists=false, threat_situation=3}) == false)

-- All seven are visible in the picker
do
  local vis = {}
  for _, row in ipairs(Conditions.list()) do vis[row.id] = true end
  for _, id in ipairs({"is_stealthed","target_is_player","target_casting","target_classification","group_size","item_ready","threat_situation"}) do
    check("new condition visible: " .. id, vis[id] == true)
  end
end

-- ---- Auto-castable gate (Engine.spell_ready) ---------------------
print("=== Auto-castable gate ===")
check("gate: unusable blocks", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_usable={[10]=false}}, 10)) == false)
check("gate: usable passes", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_usable={[10]=true}}, 10)) == true)
check("gate: LoS false blocks targeted", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=true}, target_in_los=false}, 10)) == false)
check("gate: LoS false ignores self-buff", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=false}, target_in_los=false}, 10)) == true)
check("gate: LoS nil (unknown) allows", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=true}, target_in_los=nil}, 10)) == true)
check("gate: immune blocks targeted", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=true}, target_protected={[10]=true}}, 10)) == false)
check("gate: immune ignores self-buff", (Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=false}, target_protected={[10]=true}}, 10)) == true)
check("gate: no target skips targeted checks", (Engine.spell_ready({auto_castable=true, target_exists=false, spell_targeted={[10]=true}, target_in_los=false}, 10)) == true)
check("gate: off does not gate LoS", (Engine.spell_ready({auto_castable=false, target_exists=true, spell_targeted={[10]=true}, target_in_los=false}, 10)) == true)
-- Second-return reason strings
do
  local _, why = Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=true}, target_in_los=false}, 10)
  check("gate: LoS reason string", why == "los")
  local _, why2 = Engine.spell_ready({auto_castable=true, target_exists=true, spell_targeted={[10]=true}, target_protected={[10]=true}}, 10)
  check("gate: immune reason string", why2 == "immune")
end
-- End-to-end: evaluate skips an out-of-LoS high-priority slot for a castable one
do
  local rot = Engine.new_rotation("castgate")
  Engine.add_slot(rot, {spell_id=100, name="Blocked"})
  Engine.add_slot(rot, {spell_id=200, name="Fallback"})
  local act = Engine.evaluate(rot, {
    auto_castable=true, target_exists=true,
    spell_targeted={[100]=true, [200]=false}, target_in_los=false,
  }, Conditions)
  check("evaluate: skips out-of-LoS slot -> castable fallback", act ~= nil and act.spell_id == 200)
end
-- Strict top-down priority: when several slots are simultaneously castable,
-- the HIGHEST (lowest index) always wins.
do
  local rot = Engine.new_rotation("prio")
  Engine.add_slot(rot, {spell_id=10, name="A"})
  Engine.add_slot(rot, {spell_id=20, name="B"})
  Engine.add_slot(rot, {spell_id=30, name="C"})
  local ctx = {auto_castable=true, target_exists=true}
  check("priority: all ready -> slot 1 wins", (Engine.evaluate(rot, ctx, Conditions)).spell_id == 10)
  -- Block slot 1 only -> slot 2 wins (not slot 3)
  local ctx2 = {auto_castable=true, target_exists=true, spell_usable={[10]=false}}
  check("priority: slot 1 blocked -> slot 2 wins", (Engine.evaluate(rot, ctx2, Conditions)).spell_id == 20)
  -- Block slots 1 and 2 -> slot 3 wins
  local ctx3 = {auto_castable=true, target_exists=true, spell_usable={[10]=false, [20]=false}}
  check("priority: slots 1+2 blocked -> slot 3 wins", (Engine.evaluate(rot, ctx3, Conditions)).spell_id == 30)
  -- exclude support (executor fall-through after a cast-time rejection):
  -- excluding slot 1 makes slot 2 the highest eligible.
  local ex = Engine.evaluate(rot, {auto_castable=true, target_exists=true}, Conditions, {exclude={[1]=true}})
  check("priority: exclude slot 1 -> slot 2 wins", ex ~= nil and ex.spell_id == 20)
  local ex2 = Engine.evaluate(rot, {auto_castable=true, target_exists=true}, Conditions, {exclude={[1]=true, [2]=true}})
  check("priority: exclude slots 1+2 -> slot 3 wins", ex2 ~= nil and ex2.spell_id == 30)
end

print("")
if #fails > 0 then
  print("FAILED " .. #fails)
  for _, f in ipairs(fails) do print("  - " .. f) end
  return #fails
end
print("ALL SUITE TESTS PASSED")
-- ---- BasicRules: the checklist gates -------------------------------
-- These had NO coverage at all before 2026-08-03, which is how four of the
-- Basic_Rotation_Checks entries stayed unimplemented and one shipped inverted.
print("=== BasicRules gates ===")
do
  -- ctx fields stand in for the runtime reads (BasicRules prefers ctx, then
  -- the runtime, and NEVER client Lua - the cast path must stay taint-free).
  local function base(extra)
    local c = {
      known_spells = {}, user_state = "free", cooldowns = {},
      target_exists = true, target_is_enemy = true, auto_castable = true,
      spell_targeted = {}, spell_instant = {},
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
  end

  -- Silence: only a spell whose PreventionType is silence(1) is blocked, and
  -- only on positive evidence of UNIT_FLAG_SILENCED (0x2000).
  RaijinLab.World = RaijinLab.World or {}
  RaijinLab.World.spell_req = function(sid)
    if sid == 900 then return { prevent = 1, cd = 0, catcd = 0 } end   -- silenceable
    if sid == 901 then return { prevent = 2, cd = 0, catcd = 0 } end   -- pacify (not silence)
    if sid == 902 then return { stancesnot = 2, cd = 0, catcd = 0 } end -- barred in form 2
    if sid == 903 then return { equipclass = 2, cd = 0, catcd = 0 } end -- needs a weapon
    if sid == 904 then return { casteraura = 77, cd = 0, catcd = 0 } end -- needs aura 77
    if sid == 905 then return { excaster = 88, cd = 0, catcd = 0 } end  -- barred by aura 88
    return nil
  end
  local ok, why = BasicRules.check(base({ player_unit_flags = 0x2000 }), 900)
  check("silenced blocks a silenceable spell", ok == false and why == "silenced")
  check("silenced does NOT block a pacify-type spell",
        (BasicRules.check(base({ player_unit_flags = 0x2000 }), 901)) == true)
  check("not silenced -> silenceable spell passes",
        (BasicRules.check(base({ player_unit_flags = 0 }), 900)) == true)
  check("unknown flags -> pass (never invent a refusal)",
        (BasicRules.check(base(), 900)) == true)

  -- Shapeshift exclusion mask: form 2 => bit 2^(2-1) = 2.
  check("excluded form blocks",
        (BasicRules.check(base({ shapeshift_form = 2 }), 902)) == false)
  check("other form passes",
        (BasicRules.check(base({ shapeshift_form = 1 }), 902)) == true)
  check("no form passes",
        (BasicRules.check(base({ shapeshift_form = 0 }), 902)) == true)

  -- Weapon requirement (occupancy, not item id - the live main hand read a
  -- transmog display entry, so only zero/non-zero is meaningful).
  check("empty main hand blocks a weapon spell",
        (BasicRules.check(base({ mainhand_equipped = 0 }), 903)) == false)
  check("occupied main hand passes",
        (BasicRules.check(base({ mainhand_equipped = 121696 }), 903)) == true)
  check("unknown equipment -> pass",
        (BasicRules.check(base(), 903)) == true)

  -- Required / forbidden caster auras.
  check("missing required aura blocks",
        (BasicRules.check(base({ player_aura_has = { [77] = false } }), 904)) == false)
  check("present required aura passes",
        (BasicRules.check(base({ player_aura_has = { [77] = true } }), 904)) == true)
  check("forbidden aura present blocks",
        (BasicRules.check(base({ player_aura_has = { [88] = true } }), 905)) == false)
  -- INTENT vs TARGET RELATIONSHIP (checklist 2/7/8). A harmful ability on a
  -- friendly unit and a heal on a hostile one are guaranteed client refusals.
  RaijinLab.World.spell_target_class = function(sid)
    if sid == 910 then return "enemy" end
    if sid == 911 then return "ally" end
    if sid == 912 then return "self" end
    if sid == 913 then return "any" end
    return nil
  end
  local function ictx(isEnemy, extra)
    local c = base(extra); c.target_is_enemy = isEnemy; return c
  end
  check("harmful on a FRIENDLY target blocks",
        (BasicRules.check(ictx(false), 910)) == false)
  check("harmful on a hostile target passes",
        (BasicRules.check(ictx(true), 910)) == true)
  check("helpful on a HOSTILE target blocks",
        (BasicRules.check(ictx(true), 911)) == false)
  check("helpful on a friendly target passes",
        (BasicRules.check(ictx(false), 911)) == true)
  check("self-targeted ignores the relationship",
        (BasicRules.check(ictx(true), 912)) == true)
  check("any-target ignores the relationship",
        (BasicRules.check(ictx(false), 913)) == true)
  check("unknown intent -> pass (client referees)",
        (BasicRules.check(ictx(false), 914)) == true)
  check("unknown relationship -> pass",
        (BasicRules.check(base(), 910)) == true)
  -- WHERE check_intent IS THE ONLY GATE. With policy "require",
  -- check_target_relationship already refuses a friendly target, so the
  -- harmful branch below never runs. An "optional"-policy slot skips that
  -- gate entirely - a mutation of the harmful branch was caught by ZERO
  -- checks until this case existed, which is the definition of dead cover.
  do
    local c = ictx(false)
    c.slot_target_policy = "optional"
    local ok2, why2 = BasicRules.check(c, 910)
    check("harmful on friendly blocks even when policy skips target_rel", ok2 == false)
    check("and it is the INTENT gate that says so", why2 == "harmful_on_friendly")
    local c2 = ictx(true)
    c2.slot_target_policy = "optional"
    check("helpful on hostile blocks under optional policy too",
          (BasicRules.check(c2, 911)) == false)
  end
  RaijinLab.World.spell_target_class = nil
  RaijinLab.World.spell_req = nil
end


return 0
