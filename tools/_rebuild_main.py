"""DO NOT RUN THIS SCRIPT AS-IS (2026-08-03).

It rewrites the GENERATED TAIL of tests/run_suite_tests.py, and that tail holds
BOTH _source_guards and the GROUPS dispatch. Both have drifted from the module:

  * 16 dispatch entries name test_* functions that no longer exist (regenerating
    dispatches 46 groups against 36 real ones and fails dispatch integrity);
  * 5 real groups are never dispatched and have therefore never run:
    test_chain, test_runtime_arm, test_ipc, test_object_esp, test_selftest;
  * the embedded _source_guards resurrects a RETIRED guard,
    "no C_Timer.After defer in Executor cast path".

That last one is why this warning exists. The guard is stale; the code is right.
Executor.lua's C_Timer.After(0) is a deliberate fix - running the tick inside
the game's protected event dispatch CORRUPTED THE LUA VM (live rotation-enable
crash). Regenerating therefore yields a suite that stays red until someone
"fixes" the Executor by reintroducing a client crash.

Reconcile this file against tests/run_suite_tests.py before running it.
"""

"""Rebuild the truncated main() of tests/run_suite_tests.py.

WHY THIS EXISTS. A patch script ate everything from partway through main() to
EOF. The file still imported, still exited 0, and still looked like a passing
build - while running not one assertion. That is the worst failure a harness can
have, because green means "nothing ran" and nothing says so.

The recovery sources are the pre-truncation .pyc (inline Lua blocks + source
guards + dispatch order) and the captured stdout of the last good run (the full
banner list, including groups newer than the .pyc).

The rebuild is not a transcription. Two things change on purpose:

  1. Dispatch is table-driven, and the table is CHECKED against the module. If a
     test_* function exists that no entry dispatches, the suite fails loudly
     instead of quietly skipping it. The original hand-written call list is
     exactly how a group goes missing without anyone noticing.

  2. The two version guards pinned literals ("1.7.1", "## Version: 1.7") that
     have since bumped to 1.8.x. Restoring them verbatim would fail for no real
     reason. They become a consistency check between the TOC and Variables.lua,
     which is what they were actually protecting.
"""
from pathlib import Path

ROOT = Path(r"C:\Ascension\Workspace\RaijinLab")
PY = ROOT / "tests" / "run_suite_tests.py"
REC = ROOT / "tools" / "recovered"

MARK = "# ==== GENERATED TAIL (tools/_rebuild_main.py) - do not edit by hand ===="

s = PY.read_text(encoding="utf-8")
# Slice on a sentinel, NOT on "def main()". The first version cut at def main(),
# which lives INSIDE the generated body - so every re-run left the previous
# GROUPS table and _source_guards behind and stacked a new copy on top. Python
# took the last definition so it still behaved, but the file grew dead copies and
# a mutation aimed at the file edited one of them and proved nothing.
if MARK in s:
    head = s[:s.index(MARK)]
elif chr(10) + "GROUPS = [" in s:
    # one-time cleanup of the stacked copies left by the def main() slicing
    head = s[:s.index(chr(10) + "GROUPS = [") + 1]
elif "def main() -> int:" in s:
    head = s[:s.index("def main() -> int:")]
else:
    head = s
head = head + MARK + chr(10) + chr(10)

# Park the recovered inline Lua next to the harness so it is source, not a blob
# buried in a python string literal.
inline = ROOT / "tests" / "inline"
inline.mkdir(exist_ok=True)
(inline / "block_a.lua").write_text(
    (REC / "lua_block_25.lua").read_text(encoding="utf-8"), encoding="utf-8")
(inline / "block_b.lua").write_text(
    (REC / "lua_block_26.lua").read_text(encoding="utf-8"), encoding="utf-8")

GROUPS = [
    ("test_scheduler", "Scheduler (frame-budget)", "SCHEDULER"),
    ("test_groundcache", "Ground cache", "GROUNDCACHE"),
    ("test_devlog", "Dev logging", "DEVLOG"),
    ("test_worldmesh", "World memory (learned walkability)", "WORLDMESH"),
    ("test_pathfinder", "Pathfinder (async A*)", "PATHFINDER"),
    ("test_surveyor", "Surveyor (ambient perception)", "SURVEYOR"),
    ("test_rankresolver", "RankResolver (highest-known-rank)", "RANKRESOLVER"),
    ("test_hlp", "HLP hierarchical planner + state graph", "HLP"),
    ("test_poi", "POI memory (persistent world knowledge)", "POI"),
    ("test_travel_obstacles",
     "TravelNet + Obstacles (long-haul travel, solid entities)", "TRAVEL/OBSTACLES"),
    ("test_traversability",
     "Traversability field + Patrol + QuestPolicy", "TRAVERSABILITY"),
    ("test_quest_interact", "Quest interactables + Escort", "QUEST-INTERACT"),
    ("test_mount", "Mount (riding + dismount sequencing)", "MOUNT-SEQ"),
    ("test_rest", "Rest (eat / drink / recover)", "REST"),
    ("test_vendor", "Vendor (sell / repair / restock)", "VENDOR"),
    ("test_death", "Death recovery (never stranded)", "DEATH"),
    ("test_trainer", "Trainer (auto-train / rank source-fix)", "TRAINER"),
    ("test_director", "Director (goal arbitration)", "DIRECTOR"),
    ("test_watchdog", "Watchdog (never silently wedge)", "WATCHDOG"),
    ("test_nav_states",
     "Nav state mapping (terminal states are not progress)", "NAV-STATE"),
    ("test_telemetry", "Telemetry (structured live logging)", "TELEMETRY"),
    ("test_facing", "Facing validation (live-found garbage / hang guard)", "FACING"),
    ("test_ui_layering", "UI window layering (menu on top)", "UI-LAYERING"),
    ("test_config_backup", "Config backup (survives an unclean shutdown)", "CONFIG-BACKUP"),
    ("test_empty_rotation_fallback", "Empty-rotation fallback (live idle bug)",
     "EMPTY-ROTATION"),
    ("test_compat_questid", "Compat quest-id column", "COMPAT"),
    ("test_position_guard", "Player position guard", "POSITION-GUARD"),
    ("test_menu_options", "Menu option bindings", "MENU-OPTION"),
    ("test_vision", "Vision (world rendering, budgeted)", "VISION"),
    ("test_navgrid", "NavGrid (client terrain as ground truth)", "NAVGRID"),
    ("test_know", "Know (three-valued knowledge)", "KNOW"),
    ("test_caps", "Caps (capability registry)", "CAPS"),
    ("test_fail", "Fail (retry taxonomy)", "FAIL"),
    ("test_sensors_and_unified", "Sensors + Director act(dry)", "SENSORS"),
    ("test_outcomes", "Outcome scoring (progress-aware)", "OUTCOMES"),
    ("test_replay", "Replay ring (thrash detection / sim import)", "REPLAY"),
    ("test_contract", "Contract (self-checking)", "CONTRACT"),
    ("test_master_switch", "Master suite switch", "MASTER"),
    ("test_gatherer_fishing", "Gatherer fishing preconditions", "GATHERER"),
    ("test_navigator", "Navigator steering geometry (functional)", "NAVIGATOR"),
    ("test_questlog", "Questing QuestLog parser (functional)", "QUESTLOG"),
    ("test_questom", "Questing QuestOM discovery (functional)", "QUESTOM"),
    ("test_mount_riding_skill", "Mount riding-skill detection", "MOUNT"),
    ("test_search_behavior", "Objective search (live stationary bug)", "SEARCH"),
    ("test_quest_engine", "Questing engine tick (functional)", "QUEST-ENGINE"),
    ("test_executor_gcd", "Executor GCD-verification (functional)", "EXECUTOR GCD"),
]

body = '''GROUPS = [
@@GROUPS@@
]

INLINE = Path(__file__).parent / "inline"


def _source_guards() -> list:
    """Regression guards over shipped source, recovered from the pre-truncation
    build. These assert that specific fixes are still present in the files - the
    cheapest possible check, and the only one that catches a fix being reverted
    by a later edit."""
    fails = []

    def guard(name, ok):
        if ok:
            print("  PASS  " + name)
        else:
            print("  FAIL  " + name)
            fails.append(name)

    def rd(rel):
        return (ADDON / rel).read_text(encoding="utf-8")

    executor = rd("core/rotation/Executor.lua")
    chathandler = rd("core/ChatHandler.lua")
    editor = rd("core/rotation/Editor.lua")
    farming = rd("core/Farming.lua")
    toc = rd("RaijinLab.toc")
    variables = rd("core/Variables.lua")
    events = rd("core/Events.lua")
    world_src = rd("core/World.lua")
    pathfinder_src = rd("core/Pathfinder.lua")

    for m in ("QuestLog", "QuestFrame", "QuestOM", "Suite"):
        guard("questing/" + m + ".lua in TOC",
              "modules\\\\questing\\\\" + m + ".lua" in toc)
    guard("questing modules load before Suite",
          toc.index("modules\\\\questing\\\\QuestLog.lua")
          < toc.index("modules\\\\questing\\\\Suite.lua"))
    guard("Navigator.lua in TOC", "core\\\\Navigator.lua" in toc)
    guard("ChatHandler ships /raijin nav", 'cmd == "nav"' in chathandler)
    for m in ("Scheduler", "Pathfinder"):
        guard("core/" + m + ".lua in TOC", "core\\\\" + m + ".lua" in toc)
    guard("Scheduler + Pathfinder load before Navigator",
          toc.index("core\\\\Scheduler.lua") < toc.index("core\\\\Navigator.lua"))
    guard("Events starts the frame-budget scheduler", "Scheduler.start" in events)
    guard("Pathfinder routes ground queries through the shared cache",
          "GroundCache" in pathfinder_src)

    guard("no Executor._human state table", "Executor._human" not in executor)
    guard("no reaction_until in Executor", "reaction_until" not in executor)
    guard("no attempts_since_skip in Executor", "attempts_since_skip" not in executor)
    guard("no C_Timer.After defer in Executor cast path",
          "C_Timer.After" not in executor)
    guard("no stale _human poke in ChatHandler", "_human" not in chathandler)
    guard("ChatHandler resets throttle for diagnostic",
          "_last_attempt_t = 0" in chathandler)
    guard("Executor uses authoritative _gcd_until gate", "_gcd_until" in executor)
    guard("Executor no longer soft-gates on World.gcd_remaining",
          "if World and World.gcd_remaining then" not in executor)
    guard("World still exposes public gcd_remaining (used elsewhere)",
          "World.gcd_remaining = gcd_remaining" in world_src)
    guard("World felfury tries explicit UnitPower index",
          "unit_power_indices" in world_src)
    guard("World felfury has aura-stack fallback", "aura_names" in world_src)
    guard("World stores _last_ctx for diagnostics", "World._last_ctx = ctx" in world_src)
    guard("Editor callbacks re-fetch rotation at fire time (>=4 sites)",
          editor.count("self:GetRotation()") >= 4)
    guard("Farming.lua uses local found_unit", "local found_unit" in farming)
    guard("Farming.lua returns found_unit", "return found_unit" in farming)

    # WAS a literal pin on "1.7.1" / "## Version: 1.7", which is now stale at
    # 1.8.x. A frozen number only ever protects the moment it was written; what
    # the guard was really for is the TOC and Variables.lua disagreeing.
    import re as _re
    mv = _re.search(r'RaijinLab\\.ADDON_VERSION\\s*=\\s*"([^"]+)"', variables)
    mt = _re.search(r"##\\s*Version:\\s*([0-9.]+)", toc)
    guard("Variables.lua declares ADDON_VERSION", mv is not None)
    guard("TOC declares a version", mt is not None)
    if mv and mt:
        guard("TOC version agrees with ADDON_VERSION (%s vs %s)"
              % (mt.group(1), mv.group(1)),
              mv.group(1).startswith(mt.group(1)))

    # CLICK-TO-MOVE IS A HARD PROJECT CONSTRAINT, so it gets a guard rather than
    # a convention. Three violations shipped and survived review: Suite.flee(),
    # and two sites in Farming.lua. A rule that is only enforced by whoever
    # happens to read the diff is not enforced.
    #
    # Actions.lua/API.lua may DEFINE the wrapper (the runtime command still
    # exists, and Nav keeps a documented diagnostic fallback); what is banned is
    # a module CALLING it to move the character.
    import re as _re2
    ctm_callers = []
    for _f in sorted((ADDON).rglob("*.lua")):
        rel = _f.relative_to(ADDON).as_posix()
        if rel in ("core/Actions.lua", "core/API.lua", "core/Nav.lua",
                   "core/DisableCTM.lua"):
            continue
        body = _f.read_text(encoding="utf-8", errors="ignore")
        body = _re2.sub("--[^" + chr(10) + "]*", "", body)
        if _re2.search("[:.]MoveTo[ ]*[(]|ClickPosition[ ]*[(]", body):
            ctm_callers.append(rel)
    guard("no module calls click-to-move" +
          (" (" + ", ".join(ctm_callers) + ")" if ctm_callers else ""),
          not ctm_callers)

    navigator_src = rd("core/Navigator.lua")
    # terrain_probe is a file-local; its span contract cannot be reached by a
    # unit test without driving the whole tick, and the mutation harness proved
    # nothing else defends it. The span is what keeps deep water from being
    # green-lit ahead and reclassified as airborne on arrival.
    guard("terrain_probe passes its span to GroundCache",
          "GC.ground(ax, ay, pz, nil, 3.0, span)" in navigator_src)

    guard("DisableCTM.lua ships", (ADDON / "core/DisableCTM.lua").exists())
    guard("DisableCTM.lua in TOC", "core\\\\DisableCTM.lua" in toc)
    return fails


def main() -> int:
    # A mutation pass (tests/discriminate.py) edits the SHIPPED files in place.
    # Running the suite mid-pass reads a half-mutated tree and fails on phantoms
    # - which happened twice and cost real diagnosis time both times.
    import os as _os
    _mlock = Path(__file__).parent / ".mutation_in_progress"
    if _mlock.exists() and not _os.environ.get("RAIJIN_MUTATION_RUNNER"):
        print("REFUSING TO RUN: tests/discriminate.py is mutating the addon tree")
        print("(lockfile: " + str(_mlock) + " - wait, or delete a stale lock)")
        return 3

    from lupa import LuaRuntime

    ascii_fails = _check_ascii_only()
    syntax_fails = _check_lua_syntax()
    debuglog_fails = _check_debuglog()

    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("RaijinLab = nil")
    lua.execute("math.randomseed(42)")

    for rel in (
        "core/SpellUtil.lua",
        "core/rotation/Protection.lua",
        "core/rotation/Conditions.lua",
        "core/rotation/Engine.lua",
        "core/Nav.lua",
    ):
        src = (ADDON / rel).read_text(encoding="utf-8")
        name = Path(rel).stem
        lua.execute("__mod = (function()" + chr(10) + src + chr(10) + "end)()")
        if name == "SpellUtil":
            lua.execute("SpellUtil = __mod")
        elif name == "Protection":
            lua.execute("Protection = __mod")
            lua.execute("RaijinLab = RaijinLab or {}; RaijinLab.Protection = Protection")
        elif name == "Conditions":
            lua.execute("Conditions = __mod")
        elif name == "Engine":
            lua.execute("Engine = __mod")
            lua.execute("RaijinLab = RaijinLab or {};"
                        " RaijinLab.RotationEngine = Engine")
        elif name == "Nav":
            lua.execute("Nav = __mod")

    # Support files the inline blocks reach for through the RaijinLab table
    # (Sanitize et al). Loaded as plain chunks, the way the addon loads them,
    # rather than wrapped - they attach onto the global rather than returning.
    lua.execute("RaijinLab = RaijinLab or {}")
    for rel in ("core/Persistence.lua",):
        lua.execute((ADDON / rel).read_text(encoding="utf-8"))

    lua.execute((INLINE / "block_a.lua").read_text(encoding="utf-8"))
    inline_fails = lua.execute((INLINE / "block_b.lua").read_text(encoding="utf-8"))
    inline_fails = int(inline_fails or 0)

    total = inline_fails

    print("=== ASCII-only guard (shipped addon) ===")
    if ascii_fails:
        print("ASCII FAILED " + str(ascii_fails))
        total += ascii_fails
    else:
        print("  PASS  all addon/*.lua are pure ASCII")

    print("=== Lua syntax check (shipped addon compiles) ===")
    if syntax_fails:
        print("SYNTAX FAILED " + str(syntax_fails))
        total += syntax_fails
    else:
        print("  PASS  every shipped .lua parses")

    print("=== DebugLog chat gate ===")
    if debuglog_fails:
        print("DEBUGLOG FAILED " + str(debuglog_fails))
        total += debuglog_fails
    else:
        print("  PASS  debug output stays behind the gate")

    print("=== Source guards (regression checks) ===")
    sg = _source_guards()
    if sg:
        print("SOURCE-GUARD FAILED " + str(len(sg)))
        for f in sg:
            print("  - " + f)
        total += len(sg)
    else:
        print("ALL SOURCE GUARDS PASSED")

    # EVERY GROUP DEFINED MUST BE DISPATCHED. The truncation that motivated this
    # rebuild silently dropped all 41 groups and still exited 0. A harness that
    # can skip work without saying so is not a harness. This makes the omission
    # itself a failure.
    import sys as _sys
    mod = _sys.modules[__name__]
    defined = {n for n in dir(mod)
               if n.startswith("test_") and callable(getattr(mod, n))}
    dispatched = {g[0] for g in GROUPS}
    orphans = sorted(defined - dispatched)
    missing = sorted(dispatched - defined)
    if orphans or missing:
        print("=== DISPATCH INTEGRITY ===")
        for o in orphans:
            print("  FAIL  test group defined but never run: " + o)
        for m in missing:
            print("  FAIL  dispatch names a group that does not exist: " + m)
        total += len(orphans) + len(missing)

    for fn_name, banner, label in GROUPS:
        fn = getattr(mod, fn_name, None)
        if fn is None:
            continue
        print("=== " + banner + " ===")
        fails = fn()
        if fails:
            print(label + " FAILED " + str(len(fails)))
            for f in fails:
                print("  - " + f)
            total += len(fails)
        else:
            print("ALL " + label + " TESTS PASSED")

    print("")
    if total:
        print("SUITE FAILED: " + str(total) + " failing check(s)")
        return 1
    print("ALL SUITE TESTS PASSED (" + str(len(GROUPS)) + " groups)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''.replace("@@GROUPS@@",
            ",\n".join("    (%r, %r, %r)" % g for g in GROUPS))

PY.write_text(head + body, encoding="utf-8")
print("main() rebuilt:", len(GROUPS), "groups dispatched")
