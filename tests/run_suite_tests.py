#!/usr/bin/env python3
"""Unit tests driving shipped Lua modules (Conditions, Engine, Nav) via lupa."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addon"
INLINE = Path(__file__).resolve().parent / "inline"   # extracted test Lua blocks


def _check_ascii_only() -> int:
    """Every shipped addon .lua must be pure ASCII. WoW 3.3.5's default fonts
    render non-ASCII bytes as '?', which has repeatedly leaked into user-facing
    strings (operator glyphs, middot separators, em-dashes). Fail loudly here so
    it can never ship again."""
    bad = []
    for p in sorted(ADDON.rglob("*.lua")):
        # VENDORED THIRD-PARTY DATA IS EXEMPT. addon/RaijinQuest is pfQuest +
        # the Ascension pack, renamed and moved in-tree so a launcher update
        # cannot overwrite it. Its locale tables and item/quest names contain
        # legitimate non-ASCII, and it is not OUR user-facing string source -
        # this rule exists to stop em-dashes and middots leaking out of code we
        # write. Scanning it produced 536 false failures.
        if "RaijinQuest" in p.parts:
            continue
        for lineno, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for ch in line:
                if ord(ch) > 0x7F:
                    bad.append((p.relative_to(ROOT), lineno, hex(ord(ch)), ch))
                    break
    print("=== ASCII-only guard (shipped addon) ===")
    if not bad:
        print("  PASS  all addon/*.lua are pure ASCII")
        return 0
    for rel, lineno, code, ch in bad:
        print(f"  FAIL  {rel}:{lineno} contains {code} {ch!r} (renders as '?' on 3.3.5)")
    return len(bad)


def _check_lua_syntax() -> int:
    """Every shipped addon .lua must COMPILE. A single syntax error voids the
    WHOLE file at load in WoW (e.g. the colon-method-as-value slip
    `obj:method and obj:method(...)` -> 'function arguments expected'), which the
    text-only source guards don't catch and which can break the addon in-game.
    Compile every shipped file via the Lua parser (load), no execution."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    compile_check = lua.eval(
        "function(src, name)\n"
        "  local ld = load or loadstring\n"
        "  local f, e = ld(src, name)\n"
        "  if f then return nil else return tostring(e) end\n"
        "end"
    )
    bad = []
    for p in sorted(ADDON.rglob("*.lua")):
        if "archive" in p.parts:
            continue  # archive/ files are not shipped (not in the TOC)
        src = p.read_text(encoding="utf-8")
        err = compile_check(src, "@" + str(p.relative_to(ROOT)))
        if err is not None:
            bad.append((p.relative_to(ROOT), err))
    print("=== Lua syntax check (shipped addon compiles) ===")
    if not bad:
        print("  PASS  all shipped addon/*.lua compile")
        return 0
    for rel, err in bad:
        print(f"  FAIL  {rel}: {err}")
    return len(bad)


def _source_guards() -> list:
    """Invariants checked against the SOURCE, not against behaviour.

    Restored: this aggregator was called by main() but its definition had been
    removed, which took the whole suite down with a NameError - and with it the
    guards that had already caught real regressions today.

    A source guard exists where a runtime assertion cannot reach: the tests
    themselves legitimately toggle some of these, so only the shipped text can
    answer. Each returns a human-readable failure, never a bare count.
    """
    fails: list = []

    # ZERO PROBABILITY. The belief field invented destinations out of
    # probability mass and committed the character to walking there - the direct
    # cause of "runs off in random directions". A guessed destination is wrong by
    # construction. The shipped default must be OFF; tests flip it deliberately,
    # so only the source can be asked.
    suite = (ADDON / "modules/questing/Suite.lua").read_text(encoding="utf-8", errors="replace")
    if "Suite.ALLOW_BELIEF_SEARCH = false" not in suite:
        fails.append("Suite.ALLOW_BELIEF_SEARCH must ship as false "
                     "(no probability-driven destinations)")

    # Click-to-move is forbidden, but the check belongs where it already lives:
    # tools/rl.py's gate_ctm distinguishes USING it from DISABLING it. A naive
    # substring scan here flagged DisableCTM.lua and every runtime file that
    # names the address in order to turn it OFF - i.e. it condemned the code that
    # enforces the rule. Two guards for one invariant, one of them wrong, is
    # worse than one correct guard.

    n = _check_ascii_only()
    if n:
        fails.append("%d shipped .lua file(s) contain non-ASCII bytes" % n)
    n = _check_lua_syntax()
    if n:
        fails.append("%d shipped .lua file(s) failed to parse" % n)
    n = _check_debuglog()
    if n:
        fails.append("%d debug-log routing check(s) failed" % n)
    return fails


def _check_debuglog() -> int:
    """Debug tab receives EVERY RaijinLab event always. Chat mirrors only when
    chat_verbose is on (except red error notices, which always show)."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute(
        r"""
        chatlines = {}
        function print(...)
          local p = {}
          for i=1,select("#",...) do p[i] = tostring((select(i,...))) end
          chatlines[#chatlines+1] = table.concat(p, "  ")
        end
        function GetTime() return 123 end
        function date() return "00:00:00" end
        function pcall(f, ...) return true, f(...) end
        RaijinLab = { chat_verbose = false }
        function RaijinLab:Chatter(msg) if self.chat_verbose then print(msg) end end
        """
    )
    lua.execute((ADDON / "core/DebugLog.lua").read_text(encoding="utf-8"))

    def bufn():
        return int(lua.eval("#RaijinLab.DebugLog.Snapshot()"))

    def chatn():
        return int(lua.eval("#chatlines"))

    fails = []

    def ck(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        if not cond:
            fails.append(name)

    print("=== DebugLog chat gate ===")
    # Boot line is already in the buffer from DebugLog load.
    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab.chat_verbose = false')
    lua.execute('print("|cff7ec8e3RaijinLab|r executor line")')
    ck("verbose off: RL line not in chat", chatn() == 0)
    ck("verbose off: RL line in Debug buffer", bufn() == 1)

    lua.execute('chatlines = {}; print("OtherAddon hi")')
    ck("non-RL line always in chat", chatn() == 1)

    lua.execute('chatlines = {}; print("|cffff5555RaijinLab|r error notice")')
    ck("red error line always in chat", chatn() == 1)

    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab.chat_verbose = true')
    lua.execute('print("|cffffd200RaijinLab|r gold line")')
    ck("verbose on: RL line mirrored to chat", chatn() == 1)
    ck("verbose on: captured once (no dupe)", bufn() == 1)

    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab:Chatter("via chatter")')
    ck("chatter verbose on: single buffer entry", bufn() == 1)
    ck("chatter verbose on: mirrored to chat", chatn() == 1)

    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab.chat_verbose = false; RaijinLab:Chatter("quiet chatter")')
    ck("chatter verbose off: not in chat", chatn() == 0)
    ck("chatter verbose off: still buffered", bufn() == 1)

    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab.chat_verbose = false; RaijinLab.DebugLog.Log("rot", "skip gcd")')
    ck("Log verbose off: buffered", bufn() == 1)
    ck("Log verbose off: not in chat", chatn() == 0)
    lua.execute('chatlines = {}; RaijinLab.DebugLog.Clear(); RaijinLab.chat_verbose = true; RaijinLab.DebugLog.Log("cast", "fire Reap")')
    ck("Log verbose on: buffered", bufn() == 1)
    ck("Log verbose on: in chat", chatn() == 1)

    return len(fails)


def test_scheduler() -> list:
    """The frame-budgeted scheduler must run a job across multiple frames, honor
    the per-frame time budget (yield when spent), and complete it. Drives it with
    a mocked debugprofilestop clock."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/Scheduler.lua").read_text(encoding="utf-8")
    lua.execute("Scheduler = (function()\n" + src + "\nend)()")
    lua.execute(
        r"""
sc_fails = {}
local function sc(name, cond) if not cond then sc_fails[#sc_fails+1] = name end end

-- ---- THE BUDGET MUST NOT COLLAPSE ON A SLOW-BUT-STABLE MACHINE ----------
-- Live defect: the adaptive controller compared frame time to a hardcoded
-- 1000/60 = 16.7ms. This client runs a stable 30fps (33.3ms), so `ema > target`
-- was true every frame, `b = b*0.8 - 0.05` ran every frame, and the budget sat
-- pinned at the 0.3ms floor for the whole session. The pathfinder then got ~9ms
-- per SECOND and returned 2-node stubs: 149 of 151 plans came back "partial",
-- and the bot drifted and re-planned instead of travelling.
RaijinLabDB = { perf = {} }
Scheduler._adaptive = 1.5
Scheduler._baseline_ms = nil
Scheduler._last_spent_ms = 0            -- we are doing NOTHING
for _ = 1, 400 do Scheduler.update_frame(33.3) end
sc_fails_budget = Scheduler._adaptive
sc("30fps with no work must NOT starve the budget", Scheduler._adaptive > 0.5)

-- RECOVERY. The first frames after a reload are genuinely slow, so the budget
-- legitimately collapses to the floor. It must be able to CLIMB BACK once the
-- frame rate settles. The first version of this fix grew only below target*0.85
-- and shrank only above target, so a steady 30fps landed in the dead band and
-- the budget stayed pinned at 0.30 for the whole session.
Scheduler._adaptive = 0.3                  -- collapsed, as it was live
Scheduler._baseline_ms = nil
Scheduler._last_spent_ms = 0
for _ = 1, 60 do Scheduler.update_frame(33.3) end
sc("a collapsed budget RECOVERS at a steady frame rate", Scheduler._adaptive > 1.0)
sc("...and it learns the machine's real baseline",
   Scheduler._baseline_ms ~= nil and math.abs(Scheduler._baseline_ms - 33.3) < 1.0)

-- and it must still back off when WE are the ones making frames slow
Scheduler._adaptive = 4.0
Scheduler._last_spent_ms = 5.0           -- our own work is heavy now
for _ = 1, 200 do Scheduler.update_frame(60.0) end
sc("a frame we actually inflated still backs the budget off",
   Scheduler._adaptive < 4.0)
__ms = 0
function debugprofilestop() return __ms end
RaijinLabDB = { perf = { budget_ms = 5 } }
Scheduler._q = { {}, {}, {} }

local done, count = false, 0
Scheduler.run(function()
  for i = 1, 100 do
    count = count + 1
    __ms = __ms + 1                       -- each step "costs" 1ms
    if Scheduler.over_budget() then Scheduler.yield() end
  end
  return "ok"
end, 2, function() done = true end)

Scheduler.tick()                          -- one frame: ~5ms budget => ~5 steps
sc("frame 1 made partial progress", count > 0 and count < 100)
sc("frame 1 respected budget (<=8 steps)", count <= 8)
sc("frame 1 not finished", done == false)
local guard = 0
while not done and guard < 200 do Scheduler.tick(); guard = guard + 1 end
sc("job completes across frames", done == true)
sc("job ran every step exactly once", count == 100)
sc("scheduler queue drained", (#Scheduler._q[1] + #Scheduler._q[2] + #Scheduler._q[3]) == 0)

-- cancel: a cancelled job never runs to completion
local ran2 = 0
local h = Scheduler.run(function() for i=1,10 do ran2 = ran2 + 1; Scheduler.yield() end end, 2)
Scheduler.cancel(h)
Scheduler.tick()
sc("cancelled job removed", (#Scheduler._q[2]) == 0)

-- adaptive budget controller: soaks up spare frame time, backs off when busy
RaijinLabDB.perf = { target_fps = 60, max_budget = 8, min_budget = 0.3 }   -- not pinned
Scheduler._adaptive = 1.5; Scheduler._ema_ms = nil
for i = 1, 80 do Scheduler.update_frame(10) end     -- 10ms frames = 100fps, headroom
sc("adaptive ramps UP on fast frames", Scheduler._adaptive > 4.0)
for i = 1, 80 do Scheduler.update_frame(30) end     -- 30ms frames = 33fps, over target
sc("adaptive backs OFF on slow frames", Scheduler._adaptive < 1.0)
sc("adaptive never below min", Scheduler._adaptive >= 0.3)
Scheduler.update_frame(0)                            -- junk dt ignored (no crash / change)
Scheduler.update_frame(5000)                         -- hitch spike ignored
sc("adaptive ignores junk frame deltas", Scheduler._adaptive >= 0.3 and Scheduler._adaptive <= 8)
RaijinLabDB.perf = { budget_ms = 5 }                 -- pin it
sc("pinned budget honored", Scheduler.stats().budget == 5)
"""
    )
    t = lua.eval("sc_fails")
    n = int(lua.eval("#sc_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_groundcache() -> list:
    """The shared ground cache must serve repeat cells from memory (one probe per
    cell), cache 'no ground' as well as hits, separate stacked geometry by
    elevation level, and re-probe after TTL. Driven with a mocked probe/clock."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/GroundCache.lua").read_text(encoding="utf-8")
    lua.execute("GroundCache = (function()\n" + src + "\nend)()")
    lua.execute(
        r"""
gc_fails = {}
local function gc(name, cond) if not cond then gc_fails[#gc_fails+1] = name end end
__t = 100
function GetTime() return __t end


__probes = 0
local function probe(x, y, zh)
  __probes = __probes + 1
  if x > 100 then return nil end     -- a chasm region (no ground)
  return 42.0
end

gc("first query returns ground", GroundCache.ground(0, 0, 50, probe) == 42.0)
gc("first query was a miss (probed)", __probes == 1)
gc("same cell served from cache", GroundCache.ground(0.2, 0.1, 50, probe) == 42.0)
gc("cache hit did NOT re-probe", __probes == 1)

gc("chasm returns nil", GroundCache.ground(200, 0, 50, probe) == nil)
local before = __probes
GroundCache.ground(200.1, 0, 50, probe)
gc("'no ground' is cached (no re-probe)", __probes == before)

local p2 = __probes
GroundCache.ground(0, 0, 90, probe)     -- level 9 vs level 5 -> different cell
gc("elevation level separates stacked cells", __probes == p2 + 1)

-- Span is part of the answer: a 14yd discovery hit must not answer a 6yd
-- walkability question (deep water looked like ground, then airborne on arrival).
-- First queries used the default down=6; a 14yd probe on the same xy must miss.
local p_span = __probes
GroundCache.ground(0, 0, 50, probe, 3.0, 14.0)
gc("same xy+level with different down re-probes", __probes == p_span + 1)
local p_span2 = __probes
GroundCache.ground(0, 0, 50, probe, 3.0, 14.0)
gc("same span serves from its own cache key", __probes == p_span2)

__t = 100 + GroundCache._ttl + 5        -- past the TTL, whatever it is tuned to
-- Read the TTL from the module rather than hardcoding it: it was raised
-- from 20s to 45s for cache hit-rate and this test silently began asserting
-- that a still-valid cell gets re-probed.
local p3 = __probes
GroundCache.ground(0, 0, 50, probe)
gc("expired cell is re-probed", __probes == p3 + 1)

local st = GroundCache.stats()
gc("stats reports hits+misses", (st.hits + st.misses) > 0 and st.count > 0)

-- route_z: the shared walk/swim/cliff policy pathfinder and terrain_probe share.
local rz, k
rz, k = GroundCache.route_z(100, 99, false)
gc("shallow dry drop is walk", k == "walk" and rz == 99)
rz, k = GroundCache.route_z(100, 97, true)
gc("shallow water is wade", k == "wade" and rz == 97)
rz, k = GroundCache.route_z(100, 90, true)
gc("deep water keeps altitude band (not lake bed)", k == "swim" and rz == 100)
rz, k = GroundCache.route_z(100, 90, false)
gc("deep dry drop is cliff", k == "cliff" and rz == nil)
rz, k = GroundCache.route_z(100, nil, true)
gc("no solid + water is swim at band", k == "swim" and rz == 100)
rz, k = GroundCache.route_z(100, nil, false)
gc("no solid + dry is void", k == "void" and rz == nil)
gc("WALK_DOWN is 6", GroundCache.WALK_DOWN == 6.0)
gc("DISCOVERY_DOWN is 14", GroundCache.DISCOVERY_DOWN == 14.0)
"""
    )
    t = lua.eval("gc_fails")
    n = int(lua.eval("#gc_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_devlog() -> list:
    """Dev logging: pure line formatting, batching + flush at max_buf, correct
    append path, formatted args, log_every throttling, and WriteFile fallback when
    the runtime lacks AppendFile. Mocked clock + file API."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/DevLog.lua").read_text(encoding="utf-8")
    lua.execute("DevLog = (function()\n" + src + "\nend)()")
    lua.execute(
        r"""
dl_fails = {}
local function dc(name, cond) if not cond then dl_fails[#dl_fails+1] = name end end
__t = 12.5
function GetTime() return __t end

dc("line = ts [cat] msg", DevLog.line("nav", "hello 42") == "12.500 [nav] hello 42")

RaijinLab.GetWoWDirectory = function() return "C:\\wow" end
__appended = ""; __apath = nil
RaijinLab.AppendFile = function(self, path, content) __apath = path; __appended = __appended .. content; return true end
DevLog._max_buf = 3
DevLog.log("nav", "one")
DevLog.log("nav", "two %d", 2)
dc("buffered, not yet flushed", #DevLog._buf == 2 and __appended == "")
DevLog.log("nav", "three")
dc("flush at max_buf", #DevLog._buf == 0)
dc("appended 3 lines", select(2, __appended:gsub("\n", "")) == 3)
dc("path = <wow>\\Logs\\raijinlab_dev.log", __apath == "C:\\wow\\Logs\\raijinlab_dev.log")
dc("formatted args applied", __appended:find("two 2") ~= nil)

__t = 20; DevLog._buf = {}
DevLog.log_every("hb", 1.0, "hb", "beat1")
DevLog.log_every("hb", 1.0, "hb", "beat2")     -- within gap -> skipped
dc("log_every throttles within gap", #DevLog._buf == 1)
__t = 21.5
DevLog.log_every("hb", 1.0, "hb", "beat3")     -- past gap -> logged
dc("log_every fires after gap", #DevLog._buf == 2)

-- fallback: no AppendFile -> rewrite via WriteFile
RaijinLab.AppendFile = nil
__written = nil
RaijinLab.WriteFile = function(self, path, content) __written = content end
DevLog._buf = {}; DevLog._accum = nil
DevLog.log("x", "fallback line")
DevLog.flush()
dc("WriteFile fallback carries the line", __written ~= nil and __written:find("fallback line") ~= nil)
"""
    )
    t = lua.eval("dl_fails")
    n = int(lua.eval("#dl_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_chain() -> list:
    """The pipeline diagnostic (/raijin chain).

    This is the first command run when something is wrong, so it must survive a
    world where EVERY subsystem is missing, half-built, or throwing - that is
    precisely the world it gets used in. A diagnostic that errors is worse than
    none: it hides the fault it was written to name.
    """
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/Chain.lua").read_text(encoding="utf-8")
    lua.execute("Chain = (function()" + chr(10) + src + chr(10) + "end)()")
    lua.execute(
        r"""
c_fails = {}
local function cc(name, cond) if not cond then c_fails[#c_fails+1] = name end end
local C = RaijinLab.Chain

-- 1. THE EMPTY WORLD. Nothing exists at all.
local rows, first = C.evaluate()
cc("evaluates with nothing loaded at all", type(rows) == "table" and #rows > 0)
cc("every row has a name and a verdict", (function()
    for _, r in ipairs(rows) do
        if type(r.name) ~= "string" then return false end
        if not (r.ok == true or r.ok == false or r.ok == nil) then return false end
    end
    return true
end)())
cc("the FIRST failure is reported", first == 1)
cc("...and it is the runtime, which everything else needs",
   rows[1].name == "runtime" and rows[1].ok == false)
cc("every row explains why it matters", (function()
    for _, r in ipairs(rows) do
        if type(r.why) ~= "string" or r.why == "" then return false end
    end
    return true
end)())

-- 2. A THROWING SUBSYSTEM must be caught and reported, not propagated.
RaijinLab.HasRuntime = function() error("boom") end
local rows2 = C.evaluate()
cc("a throwing check is caught, not propagated", type(rows2) == "table")
cc("...and reported as a failure with its error",
   rows2[1].ok == false and string.find(tostring(rows2[1].detail), "errored", 1, true) ~= nil)

-- 3. THE BLINDNESS CASE - the defect that cost days. Bridge sees units, the
--    engine snapshot is empty. That must be named exactly, not passed over.
RaijinLab.HasRuntime = function() return true end
RaijinLab.RuntimeVersion = function() return "1.8.34" end
RaijinLab._runtime_armed = true
RaijinLab.GetObjManagerFrame = function() return {} end
RaijinLab.RuntimeCall = function(_, name)
    if name == "GetUnitCount" then return 95 end
end
RaijinLab.om = { object_list = { npcs = {}, raw = { npcs = { 1, 2, 3 } } } }
local rows3, first3 = C.evaluate()
local snap
for _, r in ipairs(rows3) do if r.name == "engine_snapshot" then snap = r end end
cc("raw populated + npcs empty is FAILED, not skipped", snap and snap.ok == false)
cc("...and it names ObjectProcessor as the culprit",
   snap and string.find(tostring(snap.detail), "ObjectProcessor", 1, true) ~= nil)
cc("the runtime link passes once wired", rows3[1].ok == true)

-- 4. UNKNOWABLE is not FAILED. A missing precondition must not be blamed.
RaijinLab.om = { object_list = { npcs = { 1 }, raw = { npcs = { 1 } } } }
RaijinLab.QuestLog = { first_incomplete_objective = function() return nil end }
local rows4 = C.evaluate()
local ql
for _, r in ipairs(rows4) do if r.name == "quest_log" then ql = r end end
cc("no quests in the log reports UNKNOWN, not a failure", ql and ql.ok == nil)
"""
    )
    t = lua.eval("c_fails")
    n = int(lua.eval("#c_fails"))
    fails = [t[i + 1] for i in range(n)]
    print("=== Chain pipeline diagnostic ===")
    for f in fails:
        print("  FAIL  " + str(f))
    if not fails:
        print("  PASS  survives an empty world, a throwing subsystem, and names blindness")
    return fails


def test_worldmesh() -> list:
    """Persistent learned walkability: stuck spots accumulate to a blacklist,
    soft penalties scale before blacklisting, ramps record, tables trim at cap,
    and everything lives under RaijinLabDB (SavedVariables). Mocked clock/map."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/WorldMesh.lua").read_text(encoding="utf-8")
    lua.execute("WorldMesh = (function()\n" + src + "\nend)()")
    lua.execute(
        r"""
wm_fails = {}
-- THE TEST OWNS ITS FIXTURE.
--
-- These checks exercise mesh LOGIC - link formation, slope measurement, jump
-- edges, blacklisting - using samples placed 4 yards apart because that is what
-- "adjacent" meant when MRES was 4. They are not assertions ABOUT the cell size.
--
-- Inheriting the product default coupled 16 of them to that constant, so
-- refining the planning grid (a 4yd cell cannot contain a 2-4yd doorway, which
-- is why no planned route could ever pass through one) failed the suite for
-- reasons that had nothing to do with the behaviour under test. Pin the
-- resolution the geometry below assumes; the product is free to ship a finer one.
if RaijinLab and RaijinLab.WorldMesh then RaijinLab.WorldMesh.MRES = 4.0 end
if WorldMesh then WorldMesh.MRES = 4.0 end

local function wc(name, cond) if not cond then wm_fails[#wm_fails+1] = name end end
__t = 1000
function GetTime() return __t end
RaijinLabDB = {}
WorldMesh._test_map = "testmap"

wc("clean cell: no penalty", WorldMesh.penalty(10, 10, 0) == 0)
wc("clean cell: not blacklisted", WorldMesh.is_blacklisted(10, 10, 0) == false)

WorldMesh.mark_stuck(10, 10, 0)
wc("1 stuck: soft penalty 15", WorldMesh.penalty(10, 10, 0) == 15)
wc("1 stuck: not yet blacklisted", WorldMesh.is_blacklisted(10, 10, 0) == false)
WorldMesh.mark_stuck(10.4, 9.8, 0)     -- same 2yd cell
wc("2 stuck: penalty scales", WorldMesh.penalty(10, 10, 0) == 30)
WorldMesh.mark_stuck(10, 10, 0)
wc("3 stuck: BLACKLISTED", WorldMesh.is_blacklisted(10, 10, 0) == true)
wc("blacklisted: huge penalty", WorldMesh.penalty(10, 10, 0) >= 1e6)
wc("neighbor cell unaffected", WorldMesh.is_blacklisted(20, 20, 0) == false)
wc("different elevation = different cell", WorldMesh.is_blacklisted(10, 10, 30) == false)

WorldMesh.mark_ramp(50, 50, 5)
local st = WorldMesh.stats()
wc("stats counts stuck cells", st.stuck >= 1)
wc("stats counts ramp cells", st.ramps == 1)
wc("persists under RaijinLabDB (SavedVariables)",
   RaijinLabDB.worldmesh ~= nil and RaijinLabDB.worldmesh.testmap ~= nil)

-- ---- v2 packed cells + travel heatmap + quality cost ----
local cid = WorldMesh.cell_id(123, -45, 60)
local rx, ry = WorldMesh.cell_center(cid)
wc("cell_id/center round-trip within a cell",
   math.abs(rx - 123) <= WorldMesh.MRES and math.abs(ry - (-45)) <= WorldMesh.MRES)
wc("pack/unpack fields independently", (function()
     local w = WorldMesh._fset(0, "visits", 200); w = WorldMesh._fset(w, "stuck", 5)
     w = WorldMesh._fset(w, "seen", 900)
     return WorldMesh._fget(w, "visits") == 200 and WorldMesh._fget(w, "stuck") == 5
        and WorldMesh._fget(w, "seen") == 900 end)())
wc("pack/unpack ALL fields at MAX, no cross-corruption / overflow", (function()
     local maxv = { state=3, hazard=15, links=255, visits=255, stuck=7, conf=15, dz=127, seen=1023 }
     local w = 0
     for f, v in pairs(maxv) do w = WorldMesh._fset(w, f, v) end
     for f, v in pairs(maxv) do if WorldMesh._fget(w, f) ~= v then return false end end
     -- and rewriting one field leaves the others intact
     w = WorldMesh._fset(w, "visits", 7)
     return WorldMesh._fget(w, "visits") == 7 and WorldMesh._fget(w, "seen") == 1023
        and WorldMesh._fget(w, "links") == 255 and WorldMesh._fget(w, "state") == 3 end)())
-- ---- the premapped world is part of the movement model ----
-- state_neighbours used to accept a cell on state + slope + step height alone
-- and never consulted NavGrid, so the GRAPH contained edges through buildings
-- and fences. Every planner tier that walks it inherited them: live, plan_hier
-- produced a 10-node route straight through a fence that 3637 tiles of
-- extracted WMO/doodad geometry already marked STRUCTURE.
do
    -- lay a walkable strip, then declare the middle of it solid on the map
    WorldMesh._last_id = nil
    for i = 0, 6 do WorldMesh._last_id = nil; WorldMesh.observe(500 + i * 4, 500, 10, true) end
    local blocked_at = { x = 512, y = 500 }
    RaijinLab.NavGrid = {
        STRUCTURE = 5, WATER = 4,
        -- flat ground everywhere, so the ONLY thing that can reject a neighbour
        -- in this test is the STRUCTURE verdict itself
        height = function() return 10 end,
        walkable = function() return true end,
        at = function(x, y)
            if math.abs(x - blocked_at.x) < 2.5 and math.abs(y - blocked_at.y) < 2.5 then
                return 5
            end
            return 1
        end,
    }
    -- state_neighbours takes a CELL ID, not coordinates. Passing (x,y,z) looked
    -- up cell 508, found nothing, returned {} - and an empty list makes a
    -- "not reached" assertion pass for the wrong reason. Resolve the id.
    local from_id = WorldMesh.cell_id(508, 500, 10)
    local function nbrs()
        return WorldMesh.state_neighbours(from_id, {}) or {}
    end
    local function reaches(tx)
        for _, n in ipairs(nbrs()) do
            if math.abs(n.x - tx) < 2.5 then return true end
        end
        return false
    end
    -- guard the guard: if this list were empty the STRUCTURE assertion below
    -- would pass whatever the code did
    wc("the neighbour sweep actually returns cells", #nbrs() > 0)
    wc("a mapped STRUCTURE cell is NOT offered as a neighbour", reaches(512) == false)
    wc("a clear cell in the same sweep still is", reaches(504) == true)
    -- experience outranks the map: a cell we have physically walked is a doorway
    WorldMesh.mark_ramp(512, 500, 10)
    RaijinLab.NavGrid = nil
end

-- observe builds the heatmap on cell ENTRY while moving
WorldMesh._last_id = nil; WorldMesh.observe(300, 300, 10, true)
wc("observe: traversed => walkable", WorldMesh.is_walkable(300, 300, 10) == true)
wc("observe: heat >= 1 after entry", WorldMesh.heat(300, 300, 10) >= 1)
WorldMesh._last_id = nil; WorldMesh.observe(300.5, 300.5, 10, true)   -- re-enter same cell
wc("observe: heat grows on re-entry", WorldMesh.heat(300, 300, 10) >= 2)
wc("observe: NOT moving does not bump heat",
   (function() local h = WorldMesh.heat(700,700,0); WorldMesh._last_id=nil; WorldMesh.observe(700,700,0,false); return WorldMesh.heat(700,700,0) == h end)())
-- quality cost: proven corridor cheaper than unknown; blacklist = hole; >= floor
local f_trav = WorldMesh.cost_factor(300, 300, 10)
local f_unk  = WorldMesh.cost_factor(9000, 9000, 0)
wc("cost: traversed corridor cheaper than unknown", f_trav < f_unk)
wc("cost: factor never below the floor", f_trav >= WorldMesh.W.F_FLOOR)
wc("cost: blacklisted cell is a hole (1e6)", WorldMesh.cost_factor(10, 10, 0) >= 1e6)

-- ---- mesh graph: links written on traversal + neighbours + nearest_known ----
WorldMesh._last_id = nil
WorldMesh.observe(400, 400, 0, true)   -- A
WorldMesh.observe(404, 400, 0, true)   -- B (4yd east = adjacent cell)
WorldMesh.observe(408, 400, 0, true)   -- C
local idA = WorldMesh.cell_id(400, 400, 0)
local idB = WorldMesh.cell_id(404, 400, 0)
local nbrsA = WorldMesh.neighbours(idA)
wc("traversal writes a walkable link (A->B)", #nbrsA >= 1 and nbrsA[1].id == idB)
wc("neighbours symmetric (B->A too)", (function()
     for _, nb in ipairs(WorldMesh.neighbours(idB)) do if nb.id == idA then return true end end
     return false end)())
wc("nearest_known finds a mapped walkable cell", (WorldMesh.nearest_known(401, 401, 0, 12)) ~= nil)
wc("nearest_known nil in unexplored space", WorldMesh.nearest_known(50000, 50000, 0, 12) == nil)

-- cap eviction: low-traffic chunks dropped once over cap, memory stays bounded
WorldMesh._cap = 8
for i = 1, 40 do
  __t = 1000 + i
  WorldMesh.mark_stuck(i * 10, 500, 0)   -- 40 distinct cells across several chunks
end
WorldMesh.evict()
local st2 = WorldMesh.stats()
wc("cap eviction keeps store bounded", st2.cells <= 8)

-- ================= REGRESSION: adversarial-review bug fixes =================
-- Fresh, isolated map so earlier fixtures don't interfere.
WorldMesh._test_map = "regress"
WorldMesh._cap = 20000
WorldMesh._cur_map = nil        -- force bucket() to re-init _last_id/_healed for this map
WorldMesh._session = nil
WorldMesh._adds = 0
WorldMesh.new_session()         -- clean session => _healed reset, _last_id nil

-- BUG: mark_seen(false) must NOT clobber a cell the BODY proved walkable.
WorldMesh._last_id = nil
WorldMesh.observe(1000, 1000, 0, true)          -- body traversed => OPEN_TRAVERSED
WorldMesh.mark_seen(1000, 1000, 0, false)       -- a look-ahead ray "sees" a block
wc("mark_seen(false) does not clobber a TRAVERSED cell",
   WorldMesh.is_walkable(1000, 1000, 0) == true)
WorldMesh.mark_seen(1040, 1000, 0, false)       -- but an unseen cell can still be blocked
wc("mark_seen(false) still blocks a non-traversed cell",
   WorldMesh.is_blacklisted(1040, 1000, 0) == true)

-- BUG: ramp/stairs links (one Z-bucket change) must stay connected in the mesh graph.
WorldMesh._last_id = nil
-- A realistic ramp that still CROSSES a vertical bucket boundary. The boundary is
-- absolute, so a gentle 1yd rise from 3.5 to 4.5 changes bucket at VBUCKET=4 while
-- remaining a 14-degree slope anyone can walk up. (The old +8yd data was a single
-- bucket only while VBUCKET was 8, and is a 63-degree wall besides.)
WorldMesh.observe(1200, 1200, 3.5, true)        -- R0 (bucket 0)
WorldMesh.observe(1204, 1200, 4.5, true)        -- R1: 4yd east, +1yd, one bucket up
local idR0 = WorldMesh.cell_id(1200, 1200, 3.5)
local idR1 = WorldMesh.cell_id(1204, 1200, 4.5)
wc("ramp link resolves across a Z bucket (R0 -> R1)", (function()
     for _, nb in ipairs(WorldMesh.neighbours(idR0)) do if nb.id == idR1 then return true end end
     return false end)())

-- BUG: self-heal must fire at most ONCE per cell per session (not on every revisit).
-- Old code keyed on a single global _heal_id, so healing an intermediate snaggy cell
-- let the original heal all over again on return.
WorldMesh.mark_stuck(1400, 1400, 0)
WorldMesh.mark_stuck(1400.3, 1400.2, 0)         -- 1400: stuck = 2 (not blacklisted; n=3)
WorldMesh.mark_stuck(1408, 1400, 0)             -- intermediate cell is ALSO snaggy
WorldMesh._last_id = nil; WorldMesh.observe(1400, 1400, 0, true)   -- 1st clean pass: 2 -> 1
WorldMesh._last_id = nil; WorldMesh.observe(1408, 1400, 0, true)   -- heal the intermediate too
WorldMesh._last_id = nil; WorldMesh.observe(1400, 1400, 0, true)   -- revisit: must NOT re-heal
wc("self-heal fires once per session (stuck stays 1 on revisit)",
   WorldMesh._fget(WorldMesh.get(1400, 1400, 0), "stuck") == 1)

-- BUG: the Surveyor writing `seen` ahead of the body must NOT suppress the heal (so the
-- heal dedup can't be keyed on `seen`).
WorldMesh.new_session()                         -- fresh session => healable again
WorldMesh.mark_seen(1400, 1400, 0, true)        -- Surveyor pre-touches => seen = session
WorldMesh._last_id = nil; WorldMesh.observe(1400, 1400, 0, true)   -- body clean pass heals 1 -> 0
wc("surveyor pre-seen does not block self-heal",
   WorldMesh._fget(WorldMesh.get(1400, 1400, 0), "stuck") == 0)

-- BUG: dz residual must round-trip through ground_hint (no half-bucket +/-4yd drift).
WorldMesh._last_id = nil
WorldMesh.observe(600, 600, 13.0, true)
wc("ground_hint round-trips the observed Z (no bucket drift)",
   math.abs(WorldMesh.ground_hint(600, 600, 13.0) - 13.0) < 0.3)

-- BUG: eviction must keep a compact high-traffic chokepoint over a low-traffic sprawl.
-- Old code scored chunks by SUM of visits, so a big low-traffic sprawl outranked a
-- single hard-hammered corridor cell. Score by PEAK.
WorldMesh._test_map = "evict_peak"
WorldMesh._cur_map = nil
WorldMesh._adds = 0
WorldMesh._cap = 10
for i = 1, 10 do WorldMesh._last_id = nil; WorldMesh.observe(0, 0, 0, true) end   -- peak 10, sum 10
for i = 0, 11 do WorldMesh._last_id = nil; WorldMesh.observe(2000 + i * 4, 0, 0, true) end -- peak 1, sum 12
-- Clear the "standing here" marker so this exercises the SCORING itself; the
-- current-chunk protection is asserted separately below.
WorldMesh._last_id = nil
WorldMesh.evict()
wc("eviction keeps the high-PEAK chokepoint cell", WorldMesh.is_walkable(0, 0, 0) == true)
wc("eviction dropped the low-peak sprawl", WorldMesh.stats().cells <= 10)

-- The ground under our feet is never evicted: dropping it would break navigation
-- at exactly the moment we are using it.
WorldMesh._test_map = "evict_here"; WorldMesh._cur_map = nil; WorldMesh._adds = 0
WorldMesh._cap = 6
for i = 1, 12 do WorldMesh._last_id = nil; WorldMesh.observe(500 + i * 8, 0, 0, true) end
for i = 1, 9 do WorldMesh._last_id = nil; WorldMesh.observe(0, 0, 0, true) end  -- busy corridor
WorldMesh._last_id = nil
WorldMesh.observe(900, 900, 0, true)          -- now we are standing HERE, seen once
WorldMesh.evict()
wc("the chunk we are standing in survives eviction", WorldMesh.is_walkable(900, 900, 0) == true)

-- AGEING: a chunk not seen for many sessions must lose to freshly used ground,
-- otherwise `visits` only grows and the map FREEZES once a continent hits cap -
-- every newly explored chunk would be the lowest scorer and evicted on sight.
WorldMesh._test_map = "evict_age"; WorldMesh._cur_map = nil; WorldMesh._adds = 0
-- Cap must exceed one chunk (6 cells here) or BOTH chunks get dropped and the
-- test proves nothing about ordering.
WorldMesh._cap = 10
do
  WorldMesh.stats()                       -- force the map bucket into existence
  local m = RaijinLabDB.worldmesh["evict_age"]
  -- hand-build: an OLD chunk with heavy traffic, and a NEW chunk barely used
  local function put(x, y, visits, seen)
    local id = WorldMesh.cell_id(x, y, 0)
    local w = WorldMesh._fset(0, "state", WorldMesh.OPEN_TRAVERSED)
    w = WorldMesh._fset(w, "visits", visits)
    w = WorldMesh._fset(w, "seen", seen)
    m.cells[id] = w
  end
  WorldMesh._session = 40
  for i = 1, 6 do put(i * 8, 0, 200, 2) end        -- ancient highway, 38 sessions ago
  for i = 1, 6 do put(5000 + i * 8, 0, 3, 40) end  -- new ground, used right now
  WorldMesh._last_id = nil
  WorldMesh.evict()
  wc("stale heavy traffic loses to freshly used ground (map can still learn)",
     WorldMesh.is_walkable(5008, 0, 0) == true)
end
"""
    )
    t = lua.eval("wm_fails")
    n = int(lua.eval("#wm_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_pathfinder() -> list:
    """The async A* core (pure): binary heap ordering, routing AROUND an
    impassable chasm using a synthetic ground/edge oracle, and line-of-sight
    simplification. No client needed."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/Pathfinder.lua").read_text(encoding="utf-8")
    lua.execute("Pathfinder = (function()\n" + src + "\nend)()")
    lua.execute(
        r"""
pf_fails = {}
local function pf(name, cond) if not cond then pf_fails[#pf_fails+1] = name end end

-- ---- a mapped wall needs POSITIVE evidence of a gap to be crossed ----
-- edge_clear used to block a STRUCTURE cell only when a live ray ALSO confirmed
-- it, so the cell was passable whenever the raycast could not answer: collision
-- not streamed in, a thin ray between fence posts, or a throw reporting
-- state="unknown" which collapsed to "not blocked". 3637 tiles of extracted
-- building/doodad geometry were subordinate to the least reliable sensor.
do
    RaijinLab.NavGrid = {
        STRUCTURE = 5,
        at = function(x, y)
            if x >= 10 and x <= 30 then return 5 end
            return 1
        end,
        height = function() return 0 end,
    }
    RaijinLab.GroundCache = { ground = function(x, y) return 0 end }
    local trace_state = "unknown"
    RaijinLab.TraceLine = function(_, x1, y1, z1, x2, y2, z2)
        if trace_state == "blocked" then return true, x2, y2, z2, "blocked" end
        if trace_state == "clear" then return false, nil, nil, nil, "clear" end
        return false, nil, nil, nil, "unknown"
    end
    local o = Pathfinder._live_oracle()

    trace_state = "unknown"
    pf("UNKNOWN ray over a mapped wall does NOT open it",
       o.edge_clear(0, 0, 0, 40, 0, 0) == false)
    trace_state = "blocked"
    pf("a confirming ray still blocks", o.edge_clear(0, 0, 0, 40, 0, 0) == false)
    trace_state = "clear"
    pf("a DEFINITE clear ray opens a doorway through structure",
       o.edge_clear(0, 0, 0, 40, 0, 0) == true)

    RaijinLab.NavGrid = nil
    RaijinLab.GroundCache = nil
    RaijinLab.TraceLine = nil
end

-- heap: pops in ascending priority
local H = Pathfinder.Heap.new()
H:push("c", 3); H:push("a", 1); H:push("b", 2); H:push("d", 0)
-- ---- buildings must dominate routing cost -------------------------------
-- The mutation harness proved this behaviour was UNDEFENDED: reverting the
-- structure multiplier to 1.8x changed no test outcome. At 1.8x the shortest
-- route is straight through the church.
local __NG = { STRUCTURE = 5, STRUCTURE_COST = 12.0 }
pf("structure routing cost dominates (>=10x)",
   Pathfinder.grid_mult(__NG.STRUCTURE, __NG) >= 10.0)
pf("structure cost is finite (doorways must stay reachable)",
   Pathfinder.grid_mult(__NG.STRUCTURE, __NG) < 1000)
pf("plain walk cells are not marked up",
   Pathfinder.grid_mult(1, __NG) == 1.0)
pf("nil code prices neutral", Pathfinder.grid_mult(nil, __NG) == 1.0)

pf("heap pop 1 = d(0)", H:pop() == "d")
pf("heap pop 2 = a(1)", H:pop() == "a")
pf("heap pop 3 = b(2)", H:pop() == "b")
pf("heap pop 4 = c(3)", H:pop() == "c")
pf("heap empty", H:empty() == true)

-- flat open world with a CHASM (no ground) at x in (4,6), y < 8: must go around.
-- edge_clear samples the ground ALONG the edge (like the live oracle) so an edge
-- that strides over the chasm between two nodes is correctly rejected.
local function oracle(chasm)
  local function grd(x, y)
    if chasm and x > 4 and x < 6 and y < 8 then return nil end
    return 0
  end
  return {
    ground = function(x, y, zh) return grd(x, y) end,
    edge_clear = function(ax,ay,az,bx,by,bz)
      local horiz = math.sqrt((bx-ax)*(bx-ax) + (by-ay)*(by-ay))
      local steps = math.max(1, math.floor(horiz / 0.8))
      for k = 0, steps do
        local t = k / steps
        if grd(ax + (bx-ax)*t, ay + (by-ay)*t) == nil then return false end
      end
      return true
    end,
  }
end

-- open world (no chasm): path found, straight
local p1, s1 = Pathfinder.search({x=0,y=0,z=0}, {x=10,y=0,z=0}, oracle(false), {step=2.5, arrive=2.0})
pf("open world: found", s1 == "found" and p1 ~= nil)
pf("open world: reaches goal", p1 and math.abs(p1[#p1].x - 10) <= 3)

-- simplify a straight-shot path -> 2 points (all intermediate are LoS-clear)
local simp = Pathfinder.simplify(p1, oracle(false))
pf("simplify straight path -> 2 nodes", #simp == 2)

-- with chasm: still found, and NO node sits inside the chasm
local p2, s2 = Pathfinder.search({x=0,y=0,z=0}, {x=10,y=0,z=0}, oracle(true), {step=2.0, arrive=2.5, max_nodes=6000})
pf("chasm: route found", s2 == "found" and p2 ~= nil)
local inside = false
if p2 then for _, n in ipairs(p2) do if n.x > 4 and n.x < 6 and n.y < 8 then inside = true end end end
pf("chasm: route avoids the chasm", inside == false)
pf("chasm: route detours upward (some y >= 8)", (function()
  if not p2 then return false end
  for _, n in ipairs(p2) do if n.y >= 7.5 then return true end end
  return false
end)())

-- capsule clearance: a thin ray FITS a narrow gap that a body does not.
-- tracer blocks any ray whose path passes through the corridor walls at x=5
-- except a thin center slot |y| < 0.2 (narrower than the 0.45 body half-width).
local function slot_tracer(x1,y1,z1,x2,y2,z2)
  -- sample the segment; blocked if any sample is at the wall x in [4.8,5.2]
  -- and outside the thin center slot
  local steps = 12
  for k=0,steps do
    local t = k/steps
    local sx, sy = x1+(x2-x1)*t, y1+(y2-y1)*t
    if sx > 4.8 and sx < 5.2 and math.abs(sy) > 0.2 then return true end
  end
  return false
end
-- center line (y=0) passes the thin slot, but the +-0.45 body rays hit the wall
pf("capsule: body wider than slot is BLOCKED",
   Pathfinder.capsule_clear(0,0,0, 10,0,0, slot_tracer, {half_width=0.45}) == false)
-- a genuinely wide opening (slot |y|<1.0) lets the body through
local function wide_tracer(x1,y1,z1,x2,y2,z2)
  local steps=12
  for k=0,steps do local t=k/steps; local sx,sy=x1+(x2-x1)*t,y1+(y2-y1)*t
    if sx>4.8 and sx<5.2 and math.abs(sy)>1.0 then return true end end
  return false
end
pf("capsule: body fits a wide opening",
   Pathfinder.capsule_clear(0,0,0, 10,0,0, wide_tracer, {half_width=0.45}) == true)

-- learned cost: cost_extra steers the route off penalized cells
local function cost_oracle(penalty_band)
  return {
    ground = function(x,y,zh) return 0 end,
    edge_clear = function() return true end,
    cost_extra = function(x,y,z)
      -- heavy penalty on the direct line (y near 0), cheap detour at y~4
      if penalty_band and math.abs(y) < 1.5 then return 500 end
      return 0
    end,
  }
end
local pc, sc2 = Pathfinder.search({x=0,y=0,z=0}, {x=10,y=0,z=0}, cost_oracle(true), {step=2.0, arrive=2.0, max_nodes=6000})
pf("learned cost: route found", sc2 == "found" and pc ~= nil)
pf("learned cost: route avoids penalized band (detours off y=0)", (function()
  if not pc then return false end
  for _, n in ipairs(pc) do if math.abs(n.y) >= 1.5 then return true end end
  return false
end)())

-- adaptive multi-resolution: coarse step misses a 1yd doorway, fine step finds it.
-- Wall along x=5 for all y except a 1yd door at y in [0,1]; coarse step 3 can't
-- land in the door, fine step 0.75 can.
local function door_oracle()
  return {
    ground = function(x,y,zh) return 0 end,
    edge_clear = function(ax,ay,az,bx,by,bz)
      local steps=8
      for k=0,steps do local t=k/steps; local sx,sy=ax+(bx-ax)*t,ay+(by-ay)*t
        if sx>4.7 and sx<5.3 and not (sy>=0 and sy<=1) then return false end end
      return true
    end,
  }
end
local pd, sd = Pathfinder.search_adaptive({x=0,y=0.5,z=0}, {x=10,y=0.5,z=0}, door_oracle(), {steps={3.0,1.5,0.75}, arrive=2.0, max_nodes=8000})
pf("adaptive: fine resolution finds the narrow door", sd == "found" and pd ~= nil)

-- BUG: find() must tolerate being called with NO opts. Tier 2 writes opts.deadline,
-- so a nil opts crashed. With no Scheduler it runs the body inline; live_oracle
-- degrades to a flat ground so an open-world search still succeeds.
function GetTime() return 100 end
local nilopts_hit = false
local ok_nilopts = pcall(function()
  Pathfinder.find({x=0,y=0,z=0}, {x=8,y=0,z=0}, function(p, s) nilopts_hit = true end)
end)
pf("find() tolerates nil opts (no crash, callback fires)", ok_nilopts == true and nilopts_hit == true)
"""
    )
    t = lua.eval("pf_fails")
    n = int(lua.eval("#pf_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_surveyor() -> list:
    """The ambient perception fan: angular-wrap on the rebuild trigger, wall probes
    that distinguish a real near wall from distant terrain and walkable upslopes, and
    ground-z-keyed freshness so a mapped cell is never re-surveyed. Mocked rays."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    wm_src = (ADDON / "core/WorldMesh.lua").read_text(encoding="utf-8")
    sv_src = (ADDON / "core/Surveyor.lua").read_text(encoding="utf-8")
    lua.execute("(function()\n" + wm_src + "\nend)()")
    lua.execute("(function()\n" + sv_src + "\nend)()")
    lua.execute(
        r"""
sv_fails = {}
local function sc(name, cond) if not cond then sv_fails[#sv_fails+1] = name end end
__t = 1000
function GetTime() return __t end
RaijinLabDB = {}
local WM = RaijinLab.WorldMesh
local SV = RaijinLab.Surveyor
WM._test_map = "surv"
WM._cur_map = nil
WM.new_session()

-- angdiff wraps across the +/-pi seam (raw subtraction would read ~6 rad here)
sc("angdiff wraps the +/-pi seam (3,-3 ~ 0.28)", math.abs(SV._angdiff(3.0, -3.0)) < 0.5)
sc("angdiff zero", SV._angdiff(0, 0) == 0)
sc("angdiff quarter", math.abs(SV._angdiff(math.pi / 2, 0) - math.pi / 2) < 1e-6)

RaijinLab.TraceGround = function(self, sx, sy, zh, up, down) return 0 end
local function set_wall(hx, hy)
  RaijinLab.TraceLine = function(self, x1,y1,z1, x2,y2,z2, flags)
    if hx == nil then return false end
    return true, hx, hy, 0
  end
end

-- A far LoS block (beyond wall_range 45) must NOT be recorded as a wall.
set_wall(90, 0)
SV._probe(0, 0, 0, 0, 100)
sc("far LoS block is not marked a wall", WM.is_blacklisted(90, 0, 0) == false)

-- A near block clearly BEFORE the sample IS a wall.
set_wall(8, 0)
SV._probe(0, 0, 0, 0, 20)
sc("near wall in the path is marked blocked", WM.is_blacklisted(8, 0, 0) == true)

-- A block right AT the sample is that spot's own upslope terrain, not a corridor wall.
set_wall(19, 0)
SV._probe(0, 0, 0, 0, 20)
sc("block at the sample (upslope) is not walled off", WM.is_blacklisted(19, 0, 0) == false)

-- No floor under the sample => cliff/gap hazard recorded.
RaijinLab.TraceGround = function(self, sx, sy, zh, up, down) return nil end
RaijinLab.TraceLine = function() return false end
SV._probe(0, 0, 0, math.pi, 30)
sc("no floor => cliff hazard recorded", WM.get(-30, 0, 0) ~= 0)

-- Clear + floor => walkable, at the GROUND z. Then the same sloped sample is skipped
-- via ground-z freshness (not player-z) so no wall ray is spent re-surveying it.
RaijinLab.TraceGround = function(self, sx, sy, zh, up, down) return 10 end   -- ground one bucket up
RaijinLab.TraceLine = function() return false end
SV._probe(0, 0, 0, -math.pi / 2, 40)                 -- sample (0,-40), ground z=10
sc("clear+floor => walkable at ground z", WM.is_walkable(0, -40, 10) == true)
local wall_rays = 0
RaijinLab.TraceLine = function() wall_rays = wall_rays + 1; return false end
SV._probe(0, 0, 0, -math.pi / 2, 40)                 -- revisit: player z=0 != ground z=10
sc("mapped sample skipped via ground-z freshness (no wall ray)", wall_rays == 0)
"""
    )
    t = lua.eval("sv_fails")
    n = int(lua.eval("#sv_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_rankresolver() -> list:
    """Highest-known-rank resolver: maps a spell NAME to the player's top known
    rank so gating + the cast use max rank. Mocked spellbook; no client."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    su = (ADDON / "core/SpellUtil.lua").read_text(encoding="utf-8")
    rr = (ADDON / "core/RankResolver.lua").read_text(encoding="utf-8")
    lua.execute("(function()\n" + su + "\nend)()")
    lua.execute("(function()\n" + rr + "\nend)()")
    lua.execute(
        r"""
rr_fails = {}
local function rc(name, cond) if not cond then rr_fails[#rr_fails+1] = name end end

-- Mock spellbook rows: {name, rankText, id}
local book = {
  { "Fireball",     "Rank 1", 133 },
  { "Fireball",     "Rank 2", 145 },
  { "Fireball",     "Rank 3", 146 },
  { "Frost Nova",   "Rank 1", 122 },
  { "Counterspell", "",       2139 },
  { "Weird Spell",  "",       900 },
  { "Weird Spell",  "",       901 },   -- two distinct rank-0 same-name => ambiguous
}
BOOKTYPE_SPELL = "spell"
function GetSpellName(i, bt) local e = book[i]; if not e then return nil end; return e[1], e[2] end
function GetSpellLink(i, bt) local e = book[i]; if not e then return nil end; return "spell:" .. e[3] end
local id2name = { [133]="Fireball",[145]="Fireball",[146]="Fireball",[122]="Frost Nova",
                  [2139]="Counterspell",[900]="Weird Spell",[901]="Weird Spell",[999]="Loose Spell" }
function GetSpellInfo(id) return id2name[id] end
RaijinLabDB = {}

local RR = RaijinLab.RankResolver
RR._dirty = true
rc("resolves low rank to highest (133 -> 146)", RR.highest(133) == 146)
rc("resolves mid rank to highest (145 -> 146)", RR.highest(145) == 146)
rc("single-rank resolves to itself (122)", RR.highest(122) == 122)
rc("no-rank single entry resolves to itself (2139)", RR.highest(2139) == 2139)
rc("ambiguous same-name rank-0 is pinned (900 -> 900)", RR.highest(900) == 900)
rc("not-in-spellbook id unchanged (999 -> 999)", RR.highest(999) == 999)
rc("zero id -> 0", RR.highest(0) == 0)

-- master switch off => passthrough
RaijinLabDB.highest_rank = false
rc("disabled: passthrough (133 -> 133)", RR.highest(133) == 133)
RaijinLabDB.highest_rank = nil

-- live rank-up: learn Rank 4, invalidate, re-resolve
book[8] = { "Fireball", "Rank 4", 147 }
id2name[147] = "Fireball"
RR._dirty = true
rc("rank-up picked up after invalidation (133 -> 147)", RR.highest(133) == 147)

-- CONSERVATIVE GUARD: never swap to a DIFFERENT ability. On a custom server a
-- bare name lookup can land on an unrelated spell; casting that would be a wrong
-- cast the rotation never asked for. Only a genuine same-name rank upgrade may remap.
book[9]  = { "Shadow Bolt", "Rank 1", 700 }
book[10] = { "Shadow Bolt", "",       701 }   -- no rank number => not a rank upgrade
id2name[700] = "Shadow Bolt"; id2name[701] = "Shadow Bolt"
RR._dirty = true
rc("no rank number -> never remapped (700 stays 700)", RR.highest(700) == 700)
-- a resolved id whose NAME differs must be rejected even if the map points at it
book[11] = { "Chaos Bolt", "Rank 2", 800 }
id2name[800] = "Totally Different Spell"      -- name disagrees with the book entry
id2name[801] = "Chaos Bolt"
book[12] = { "Chaos Bolt", "Rank 1", 801 }
RR._dirty = true
rc("name mismatch -> refuses to remap (801 stays 801)", RR.highest(801) == 801)

-- describe() for the editor UI
local rid, rt, changed, status = RR.describe(133)
rc("describe: changed + status ok", rid == 147 and changed == true and status == "ok")
local rid2, _, changed2, status2 = RR.describe(999)
rc("describe: unlisted spell", status2 == "unlisted" and changed2 == false)
"""
    )
    t = lua.eval("rr_fails")
    n = int(lua.eval("#rr_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_hlp() -> list:
    """Hierarchical long-range planner + the mesh state-graph it walks.
    Proves: raycast-observed ground is plannable (the link graph cannot see it),
    height gating, a SOUND unreachable proof, a wall-aware heuristic, and that
    plan_hier routes over observed-only ground. No client."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    for rel, name in (("core/WorldMesh.lua", "WorldMesh"),
                      ("core/HLP.lua", "HLP"),
                      ("core/Pathfinder.lua", "Pathfinder")):
        src = (ADDON / rel).read_text(encoding="utf-8")
        NL = chr(10)
        lua.execute("__m = (function()" + NL + src + NL + "end)()")
        lua.execute(f"{name} = __m; RaijinLab.{name} = __m")
    lua.execute(
        r"""
hlp_fails = {}
-- THE TEST OWNS ITS FIXTURE.
--
-- These checks exercise mesh LOGIC - link formation, slope measurement, jump
-- edges, blacklisting - using samples placed 4 yards apart because that is what
-- "adjacent" meant when MRES was 4. They are not assertions ABOUT the cell size.
--
-- Inheriting the product default coupled 16 of them to that constant, so
-- refining the planning grid (a 4yd cell cannot contain a 2-4yd doorway, which
-- is why no planned route could ever pass through one) failed the suite for
-- reasons that had nothing to do with the behaviour under test. Pin the
-- resolution the geometry below assumes; the product is free to ship a finer one.
if RaijinLab and RaijinLab.WorldMesh then RaijinLab.WorldMesh.MRES = 4.0 end
if WorldMesh then WorldMesh.MRES = 4.0 end

local function hc(name, cond) if not cond then hlp_fails[#hlp_fails+1] = name end end
__t = 1000
function GetTime() return __t end
RaijinLabDB = {}
local WM, H, PF = WorldMesh, HLP, Pathfinder
WM._test_map = "hlpmap"
WM._cur_map = nil
WM.new_session()

-- ============ state graph ============
-- Two adjacent cells seen ONLY by raycast (never body-traversed).
WM.mark_seen(0, 0, 10, true)
WM.mark_seen(4, 0, 10, true)
local idA = WM.cell_id(0, 0, 10)
local idB = WM.cell_id(4, 0, 10)
hc("mark_seen records ground z (dz written)", math.abs((WM.ground_z(idA) or -999) - 10) < 0.3)
hc("link graph does NOT connect raycast-only cells", #WM.neighbours(idA) == 0)
local sn = WM.state_neighbours(idA)
local foundB = false
for _, nb in ipairs(sn) do if nb.id == idB then foundB = true end end
hc("state graph DOES connect raycast-only cells", foundB)
hc("raycast edge is OBSERVED (not proven)", (function()
     for _, nb in ipairs(sn) do if nb.id == idB then return nb.edge == WM.EDGE_OBSERVED end end
     return false end)())

-- A blocked / unknown endpoint is never a neighbour.
WM.mark_seen(0, WM.MRES, 10, false)          -- BLOCKED
hc("state graph excludes BLOCKED cells", (function()
     for _, nb in ipairs(WM.state_neighbours(idA)) do
       if nb.id == WM.cell_id(0, WM.MRES, 10) then return false end end
     return true end)())

-- Height gate: a cell 6yd above is an impossible climb (STEP_UP 2.5).
WM.mark_seen(0, -4, 16, true)
hc("state graph rejects an impossible climb", (function()
     for _, nb in ipairs(WM.state_neighbours(idA)) do
       if nb.id == WM.cell_id(0, -4, 16) then return false end end
     return true end)())
-- ...but a gentle step is fine.
WM.mark_seen(-4, 0, 11.5, true)
hc("state graph allows a walkable step", (function()
     for _, nb in ipairs(WM.state_neighbours(idA)) do
       if nb.id == WM.cell_id(-4, 0, 11.5) then return true end end
     return false end)())

-- Body traversal upgrades the edge to PROVEN.
WM._last_id = nil
WM.observe(200, 0, 10, true); WM.observe(204, 0, 10, true)
hc("traversed edge is PROVEN", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(200,0,10))) do
       if nb.edge == WM.EDGE_PROVEN then return true end end
     return false end)())

-- ============ terrain / slope model ============
WM._test_map = "slopemap"; WM._cur_map = nil; WM._gen = 0
-- Flat plain: every cell at z=0
for i = -2, 6 do for j = -2, 2 do WM.mark_seen(i*WM.MRES, j*WM.MRES, 0, true) end end
local flat = WM.cell_id(0, 0, 0)
local sdeg = WM.slope_deg(flat)
hc("flat ground measures ~0 degrees", sdeg ~= nil and sdeg < 5)
-- slope lives in a PARALLEL sparse store, not the packed word (the packed word
-- must stay under 14 significant digits so a SavedVariables round-trip is exact)
hc("slope is cached after measuring", (function()
     local id = WM.cell_id(0,0,0)
     return WM.slope_deg(id) ~= nil end)())
-- Computed across EVERY registered field, so ADDING a field that breaks the
-- budget fails here rather than silently corrupting cells on the next reload.
hc("packed word stays inside the precision budget", (function()
     local w = WM._max_word()
     return tonumber(string.format("%.14g", w)) == w end)())
-- A ONE-SIDED reading (edge of explored ground) must not be cached: it can look
-- like a cliff, and caching it would permanently mark walkable ground too steep
-- long after the neighbours became known.
hc("a one-sided slope measurement is not cached", (function()
     WM._test_map = "onesided"; WM._cur_map = nil
     WM.mark_seen(0, 0, 0, true)
     WM.mark_seen(4, 0, 0, true)          -- only ONE neighbour on the x axis
     local id = WM.cell_id(0, 0, 0)
     WM.slope_deg(id)                      -- measure (one-sided)
     local m = RaijinLabDB.worldmesh["onesided"]
     return m.slopes[id] == nil end)())
hc("a central-difference measurement IS cached", (function()
     WM.mark_seen(-4, 0, 0, true)          -- now both sides known
     local id = WM.cell_id(0, 0, 0)
     WM.slope_deg(id)
     local m = RaijinLabDB.worldmesh["onesided"]
     return m.slopes[id] ~= nil end)())
WM._test_map = "slopemap"; WM._cur_map = nil
hc("unmeasured slope reads as nil, not flat", (function()
     WM.mark_seen(5000, 5000, 0, true)     -- isolated: no neighbours to differentiate
     return WM.slope_deg(WM.cell_id(5000,5000,0)) == nil end)())

-- A hill with a GENTLE side (rise 1 per 4yd ~ 14 deg) and a STEEP face
-- (rise 8 per 4yd ~ 63 deg). The planner must be able to tell them apart.
WM._test_map = "hillmap"; WM._cur_map = nil
-- Space samples by the mesh's OWN cell size. Hardcoding 4yd tied the test to
-- MRES=4: when the planning grid was refined to 2yd (a doorway is narrower than
-- a 4yd cell, so no route could ever pass through one) these samples stopped
-- landing in adjacent cells, slope_deg returned nil, and the group died on a
-- nil comparison rather than reporting a failure.
local MR = WM.MRES
for i = 0, 8 do WM.mark_seen(i*MR, 0, i*1.0, true) end      -- gentle ramp, y=0
for i = 0, 8 do WM.mark_seen(i*MR, 40, i*8.0, true) end     -- steep face, y=40
local gentle = WM.cell_id(4*MR, 0, 4*1.0)
local steep  = WM.cell_id(4*MR, 40, 4*8.0)
local gdeg, sdeg2 = WM.slope_deg(gentle), WM.slope_deg(steep)
hc("gentle hillside measures a shallow angle", gdeg ~= nil and gdeg > 5 and gdeg < 25)
hc("steep face measures a severe angle", sdeg2 ~= nil and sdeg2 > 55)
hc("steep face is steeper than the gentle side", sdeg2 > gdeg)

-- step_kind: the movement model
hc("small rise is walkable", (WM.step_kind(0, 0.5, 4)) == true)
-- Slope is what decides, not raw height: 1yd over 4yd is a 14deg ramp you run up,
-- and even 4yd over 4yd is a 45deg slope (still under the slide limit).
hc("gentle rise over distance is a RAMP, not a ledge",
   (function() local ok,k = WM.step_kind(0, 1.4, 4); return ok and k=="walk" end)())
hc("45deg ramp is walkable", (WM.step_kind(0, 4.0, 4)) == true)
-- The same height over a SHORT run is a genuine riser: too steep to walk, low
-- enough to jump.
hc("abrupt riser needs a jump",
   (function() local ok,k = WM.step_kind(0, 1.4, 1.0); return ok and k=="jump" end)())
hc("tall abrupt face is a wall", (WM.step_kind(0, 6.0, 1.0)) == false)
hc("beyond the slide limit is not walkable",
   (function() local ok = WM.step_kind(0, 10.0, 4); return ok == false end)())
hc("small drop walks", (function() local ok,k = WM.step_kind(0, -2.0, 4); return ok and k=="walk" end)())
hc("big drop is a deliberate jump", (function() local ok,k = WM.step_kind(0, -6.0, 4); return ok and k=="jump" end)())
hc("cliff drop is refused", (WM.step_kind(0, -40.0, 4)) == false)
hc("unmeasured heights stay permissive", (WM.step_kind(nil, nil, 4)) == true)

-- the gentle ramp is traversable end-to-end; the steep face is NOT walkable
hc("gentle ramp yields walk edges", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0))) do
       if nb.edge == WM.EDGE_OBSERVED then return true end end
     return false end)())
hc("steep face is rejected as unwalkable", (function()
     -- from the base of the steep face, the next cell up is a 8yd rise = wall
     local nbs = WM.state_neighbours(WM.cell_id(0,40,0))
     for _, nb in ipairs(nbs) do
       if nb.id == WM.cell_id(4,40,8) then return false end end
     return true end)())

-- PARKOUR. At 4yd resolution a "ledge" is always a ramp, so the meaningful jump
-- is clearing a GAP: two platforms with a chasm between them.
WM._test_map = "jumpmap"; WM._cur_map = nil
WM.mark_seen(0, 0, 0, true)          -- near platform
WM.mark_seen(8, 0, 0, true)          -- far platform, 8yd away, nothing between
hc("gap between platforms yields a JUMP edge", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0))) do
       if nb.id == WM.cell_id(8,0,0) then
         return nb.edge == WM.EDGE_JUMP and nb.jump == true and nb.why == "gap" end end
     return false end)())
hc("jump edges can be disabled", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0), { no_jump = true })) do
       if nb.id == WM.cell_id(8,0,0) then return false end end
     return true end)())
-- A WALL between two platforms is not jumpable (you cannot fly through geometry).
WM._test_map = "wallgap"; WM._cur_map = nil
WM.mark_seen(0, 0, 0, true)
WM.mark_seen(4, 0, 0, false)         -- solid wall in between
WM.mark_seen(8, 0, 0, true)
hc("a wall between platforms blocks the jump", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0))) do
       if nb.id == WM.cell_id(8,0,0) then return false end end
     return true end)())
-- A gap wider than the jump range is not offered.
WM._test_map = "widegap"; WM._cur_map = nil
WM.mark_seen(0, 0, 0, true)
WM.mark_seen(40, 0, 0, true)
hc("an unjumpable gap is not offered", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0))) do
       if nb.id == WM.cell_id(40,0,0) then return false end end
     return true end)())

-- slope-aware cost: steep ground costs more than flat
WM._test_map = "costmap"; WM._cur_map = nil
for i = -2, 2 do for j = -2, 2 do WM.mark_seen(i*WM.MRES, j*WM.MRES, 0, true) end end   -- flat
for i = -2, 2 do for j = -2, 2 do WM.mark_seen(500+i*WM.MRES, j*WM.MRES, i*3.0*(WM.MRES/4), true) end end -- ~37deg
WM.slope_deg(WM.cell_id(0,0,0)); WM.slope_deg(WM.cell_id(500,0,0))
hc("steep ground costs more than flat", WM.cost_factor(500,0,0) > WM.cost_factor(0,0,0))

-- ============ multi-level indoors ============
-- REGRESSION: with an 8yd vertical bucket two storeys of a building collapsed
-- into ONE cell, so the mesh believed the upstairs and downstairs were the same
-- place and would happily "route" between them through a floor.
WM._test_map = "storeys"; WM._cur_map = nil; WM._gen = 0
WM.mark_seen(0, 0, 0, true)      -- ground floor
WM.mark_seen(0, 0, 6, true)      -- upper floor, 6yd above (a normal storey)
hc("two storeys are DISTINCT cells", WM.cell_id(0,0,0) ~= WM.cell_id(0,0,6))
hc("ground floor keeps its own height",
   math.abs((WM.ground_z(WM.cell_id(0,0,0)) or -999) - 0) < 0.3)
hc("upper floor keeps its own height",
   math.abs((WM.ground_z(WM.cell_id(0,0,6)) or -999) - 6) < 0.3)
-- and they must NOT be neighbours: you cannot walk up through a ceiling
hc("storeys are not walkable neighbours", (function()
     for _, nb in ipairs(WM.state_neighbours(WM.cell_id(0,0,0))) do
       if nb.id == WM.cell_id(0,0,6) then return false end end
     return true end)())

-- ============ vbucket migration ============
-- Changing the vertical resolution re-keys every cell_id. Without a migration the
-- character would appear to forget the entire world; with it, the learned map is
-- rebucketed and the heights survive.
do
  RaijinLabDB.worldmesh = RaijinLabDB.worldmesh or {}
  -- Hand-build a store as it existed under the OLD 8yd bucketing: a cell whose
  -- ground sits at z=6 was bucket 0 back then (floor(6/8)==0).
  local ZB, OLDV = 512, 8.0
  local oldcb = math.floor(6 / OLDV) + ZB
  local cx, cy = math.floor(700 / WM.MRES) + 8192, math.floor(700 / WM.MRES) + 8192
  local oldid = (cx * 16384 + cy) * 1024 + oldcb
  local oldcz = (oldcb - ZB + 0.5) * OLDV
  local q = math.floor((6 - oldcz) / 0.25 + 0.5) + 64
  local w = WM._fset(0, "state", WM.OPEN_TRAVERSED)
  w = WM._fset(w, "visits", 5)
  w = WM._fset(w, "dz", q)
  RaijinLabDB.worldmesh["oldmap"] = { cells = { [oldid] = w }, vbucket = OLDV, session = 1 }

  WM._test_map = "oldmap"; WM._cur_map = nil
  local st = WM.stats()           -- touching the bucket triggers the migration
  hc("migration keeps the cell (map is not forgotten)", st.cells == 1)
  hc("migration re-keys to the new bucket",
     RaijinLabDB.worldmesh["oldmap"].vbucket == WM.VBUCKET)
  hc("migration preserves the ground height",
     math.abs((WM.ground_z(WM.cell_id(700, 700, 6)) or -999) - 6) < 0.4)
  hc("migration preserves the traversed state", WM.is_walkable(700, 700, 6) == true)
  hc("migration preserves the visit count", WM._fget(WM.get(700,700,6), "visits") == 5)
end

-- ============ pyramid ============
local st = H.stats()
hc("pyramid builds", st.built == true and (st.l1 or 0) > 0)
hc("pyramid has all 4 levels", st.l1 and st.l2 and st.l3 and st.l4)
hc("block_of/block_xy round-trip", (function()
     local bid = H.block_of(8, 12345, 6789)
     local bx, by = H.block_xy(8, bid)
     return bx == math.floor(12345/8) and by == math.floor(6789/8) end)())

-- pyramid must invalidate when the mesh grows (derived, never stale)
local gen0 = WM._gen
WM.mark_seen(9000, 9000, 0, true)
hc("mesh growth bumps the generation", WM._gen > gen0)
hc("pyramid rebuilds after growth", H.stats().gen == WM._gen)

-- ============ reachability (sound negative) ============
-- Build a connected corridor, and a far-away island with no connection.
WM._test_map = "reachmap"; WM._cur_map = nil; WM._gen = 0
for i = 0, 40 do WM.mark_seen(i * WM.MRES, 0, 0, true) end    -- corridor, MRES-spaced
for i = 0, 5 do WM.mark_seen(6000 + i * WM.MRES, 0, 0, true) end -- distant island
local corrA = WM.cell_id(0, 0, 0)
local corrB = WM.cell_id(160, 0, 0)
local island = WM.cell_id(6000, 0, 0)
hc("reachable along a connected corridor", H.reachable(corrA, corrB) ~= false)
hc("UNREACHABLE island is proven (sound negative)", H.reachable(corrA, island) == false)

-- ============ heuristic ============
local field = H.potential(corrB, { level = 1 })
hc("potential field builds", field ~= nil and field.pot ~= nil)
hc("goal block potential is 0", field and field.pot[field.goal_block] == 0)
hc("potential grows with distance", (function()
     if not field then return false end
     local function pot_at(id)
       local cx, cy = WM.cell_coords(id)
       return field.pot[H.block_of(field.span, cx, cy)] end
     local near_p = pot_at(WM.cell_id(140, 0, 0))
     local far_p  = pot_at(WM.cell_id(0, 0, 0))
     return near_p and far_p and far_p > near_p end)())
hc("h_for never returns less than the straight-line floor", (function()
     local h = H.h_for(field, corrA, WM.cell_center(corrB))
     local ax, ay = WM.cell_center(corrA)
     local bx, by = WM.cell_center(corrB)
     local e = math.sqrt((bx-ax)^2 + (by-ay)^2)
     return h >= e - 0.01 end)())
hc("h_for with no field falls back to euclid", H.h_for(nil, corrA, 0, 0) >= 0)

-- ============ plan_hier ============
-- A long corridor of OBSERVED-only ground: plan_mesh (body links) must fail,
-- plan_hier must succeed - this is the whole point of the state graph.
local sxy = { x = 0, y = 0, z = 0 }
local gxy = { x = 160, y = 0, z = 0 }
local mp = PF.plan_mesh(sxy, gxy, {})
local hp, hstatus = PF.plan_hier(sxy, gxy, {})
hc("plan_mesh cannot route observed-only ground", mp == nil)
hc("plan_hier routes observed-only ground", hp ~= nil and hstatus == "found")
hc("plan_hier path starts near the start", hp and math.abs(hp[1].x - 0) <= 8)
hc("plan_hier path reaches the goal", hp and math.abs(hp[#hp].x - 160) <= 8)

-- CONTRACT CHANGED DELIBERATELY. This asserted that a coarse-flood miss is
-- "no_path". It is not: the flood only walks blocks WorldMesh has already
-- recorded, so unexplored ground is indistinguishable from a wall, and after a
-- resurrect/hearth/flight the mesh holds disconnected islands. Promoting that
-- mesh-local miss to a global verdict made the bot stand still forever for
-- places it could have walked to.
--
-- It now reports "coarse_miss" and the caller falls through to the tiers that
-- can actually see the world (TIER 2 reads NavGrid terrain extracted from the
-- client). Only a searcher with real visibility earns the right to say no.
local _, istatus = PF.plan_hier(sxy, { x = 6000, y = 0, z = 0 }, {})
hc("plan_hier reports coarse_miss, not a global no_path",
   istatus == "coarse_miss")
hc("plan_hier never claims no_path from mesh-only evidence",
   istatus ~= "no_path")
"""
    )
    t = lua.eval("hlp_fails")
    n = int(lua.eval("#hlp_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_poi() -> list:
    """Persistent point-of-interest memory + the questing memory lookups built on
    it. This is what lets the quester travel to something it cannot currently see
    (the old engine just reported 'travel needed'). No client."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    for rel, name in (("core/POI.lua", "POI"),):
        src = (ADDON / rel).read_text(encoding="utf-8")
        lua.execute("__m = (function()" + NL + src + NL + "end)()")
        lua.execute(f"{name} = __m; RaijinLab.{name} = __m")
    lua.execute(
        r"""
poi_fails = {}
local function pc(name, cond) if not cond then poi_fails[#poi_fails+1] = name end end
__t = 500
function GetTime() return __t end
RaijinLabDB = {}
POI._test_map = "poimap"

-- record + query
pc("rejects an unknown kind", POI.record("banana", {x=1,y=2,z=3}) == nil)
pc("rejects a record with no position", POI.record("vendor", {name="X"}) == nil)
local r = POI.record("giver", { x = 100, y = 200, z = 10, name = "Marshal", entry = 42 })
pc("records a sighting", r ~= nil and r.n == "Marshal" and r.e == 42)
pc("nearest finds it", (function()
     local f, d = POI.nearest("giver", 100, 205, 10)
     return f == r and d and d < 6 end)())
pc("nearest respects kind", POI.nearest("vendor", 100, 200, 10) == nil)
pc("nearest respects max_dist", POI.nearest("giver", 100, 200, 10, { max_dist = 0.1 }) ~= nil
   and POI.nearest("giver", 9000, 9000, 0, { max_dist = 50 }) == nil)

-- de-duplication: re-seeing the same thing must NOT grow the store
local n0 = #POI.list()
for i = 1, 25 do POI.record("giver", { x = 100 + (i % 3), y = 200, z = 10, name = "Marshal", entry = 42 }) end
pc("re-sightings de-duplicate (no unbounded growth)", #POI.list() == n0)
pc("re-sighting bumps the seen count", POI.list("giver")[1].c > 1)

-- a genuinely different place IS a new record
POI.record("giver", { x = 900, y = 200, z = 10, name = "Other", entry = 43 })
pc("a distinct location is a distinct record", #POI.list("giver") == 2)

-- objectives keyed by NAME (the join with the quest log, since IsTiedToQuest is
-- only a boolean and carries no quest id)
POI.record("objective", { x = 300, y = 300, z = 0, name = "Kobold Vermin", entry = 77 })
POI.record("objective", { x = 800, y = 300, z = 0, name = "Mangy Wolf", entry = 78 })
pc("nearest objective filters by name", (function()
     local f = POI.nearest("objective", 0, 0, 0, { name = "Mangy Wolf" })
     return f and f.e == 78 end)())

-- forget keeps the memory honest
local ghost = POI.record("objective", { x = 1234, y = 0, z = 0, name = "Ghost", entry = 99 })
pc("forget removes a stale record", POI.forget(ghost) == true
   and POI.nearest("objective", 1234, 0, 0, { name = "Ghost" }) == nil)

-- IDENTITY INDEPENDENCE: a DB sanitize pass or a reload replaces persisted tables
-- wholesale, so anything that remembers a record by TABLE would silently lose it.
do
  local r = POI.record("objective", { x = 4321, y = 0, z = 0, name = "Copyme", entry = 55 })
  local k = POI.key_of(r)
  pc("records expose a stable key", type(k) == "string" and #k > 0)
  -- simulate the sanitize: same data, brand new table
  local copy = {}
  for kk, vv in pairs(r) do copy[kk] = vv end
  pc("a copied record has the SAME stable key", POI.key_of(copy) == k)
  pc("forget works on a re-created record", POI.forget(copy) == true)
  pc("and it is really gone",
     POI.nearest("objective", 4321, 0, 0, { name = "Copyme" }) == nil)
end

-- eviction keeps the store bounded, keeping the most recently seen
POI._cap = 20
for i = 1, 60 do
  __t = 500 + i
  POI.record("herb", { x = i * 100, y = 0, z = 0, name = "H" .. i, entry = 1000 + i })
end
pc("eviction bounds the store", #POI.list() <= 20)
pc("eviction keeps the most recent", (function()
     for _, rec in ipairs(POI.list("herb")) do if rec.n == "H60" then return true end end
     return false end)())

-- per-map isolation: another continent must not see these
POI._test_map = "othermap"
pc("memory is per-map", #POI.list() == 0)
POI._test_map = "poimap"
pc("original map memory intact", #POI.list() > 0)

-- stats
local st = POI.stats()
pc("stats reports totals by kind", st.total == #POI.list() and st.by_kind ~= nil)

-- ===== AUDIT REGRESSIONS (POI) =====
-- Landmarks are discovered ONCE by walking to them; spawns are re-learned for free.
-- Patrol writes a spawn per visible NPC ~1Hz, so a purely time-ordered eviction
-- deleted the town vendor to make room for a boar. Landmarks must survive.
POI._test_map = "evictmap"
POI._cap = 30
POI._spawn_cap = 500      -- high, so the GLOBAL cap is what forces eviction here
POI.record("vendor", { x = 0, y = 0, z = 0, name = "Town Vendor", entry = 1 })
POI.record("flightmaster", { x = 20, y = 0, z = 0, name = "Flight Master", entry = 2 })
for i = 1, 400 do
  __t = __t + 1
  POI.record("spawn", { x = i * 40, y = 500, z = 0, name = "Boar", entry = 1000 + i })
end
pc("global cap forced eviction", #POI.list() <= POI._cap)
pc("the vendor landmark SURVIVED the spawn flood", (function()
     for _, r in ipairs(POI.list("vendor")) do if r.n == "Town Vendor" then return true end end
     return false end)())
pc("the flight master landmark SURVIVED too", #POI.list("flightmaster") == 1)
pc("store stays inside the global cap", #POI.list() <= POI._cap)
do
  -- WoW's time() is a real epoch; the harness has no such global, so provide one
  -- and assert the persisted stamp uses IT rather than GetTime (uptime).
  function time() return 1770000000 end
  local r = POI.record("vendor", { x = 950, y = 950, z = 0, name = "Stamped", entry = 78 })
  pc("record timestamps are wall clock, not uptime", (r.t or 0) > 1e9)
  time = nil
end
"""
    )
    t = lua.eval("poi_fails")
    n = int(lua.eval("#poi_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_travel_obstacles() -> list:
    """Long-haul travel decisions (walk vs fly, cross-continent transit memory)
    and the transient solid-entity layer. No client."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    for rel, name in (("core/POI.lua", "POI"),
                      ("core/TravelNet.lua", "TravelNet"),
                      ("core/Obstacles.lua", "Obstacles")):
        src = (ADDON / rel).read_text(encoding="utf-8")
        lua.execute("__m = (function()" + NL + src + NL + "end)()")
        lua.execute(f"{name} = __m; RaijinLab.{name} = __m")
    lua.execute(
        r"""
tv_fails = {}
local function tc(name, cond) if not cond then tv_fails[#tv_fails+1] = name end end
__t = 100
function GetTime() return __t end
RaijinLabDB = {}
POI._test_map = "tvmap"
RaijinLab.WorldMesh = { map_key = function() return "tvmap" end }

-- ===== travel decisions =====
-- Short hop: never worth an airport run.
local p = TravelNet.plan(0,0,0, 100,0,0)
tc("short hop walks", p.mode == "walk" and p.why == "short")

-- Long haul with no known flight master: we cannot fly what we do not know.
local p2 = TravelNet.plan(0,0,0, 9000,0,0)
tc("no known flightmaster -> walk", p2.mode == "walk" and p2.why == "no_known_flightmaster")

-- With flight masters at both ends, flying wins for a long trip.
POI.record("flightmaster", { x = 50, y = 0, z = 0, name = "Home FM" })
POI.record("flightmaster", { x = 8950, y = 0, z = 0, name = "Far FM" })
local p3 = TravelNet.plan(0,0,0, 9000,0,0)
tc("long haul prefers flying", p3.mode == "fly" and p3.why == "faster")
tc("flight plan names both ends",
   p3.from_master and p3.from_master.n == "Home FM" and p3.to_master and p3.to_master.n == "Far FM")
tc("flying really is modelled as faster", p3.fly_s < p3.walk_s)

-- A flight master right next to the goal but also next to us = pointless flight.
POI._test_map = "tvmap2"
POI.record("flightmaster", { x = 0, y = 0, z = 0, name = "Only FM" })
local p4 = TravelNet.plan(0,0,0, 9000,0,0)
tc("same node -> no pointless flight", p4.mode == "walk" and p4.why == "same_node")
POI._test_map = "tvmap"

-- cost model sanity
tc("walk time scales with distance", TravelNet.walk_seconds(700) > TravelNet.walk_seconds(70))
tc("flight has real overhead", TravelNet.fly_seconds(0,0,0) >= TravelNet.TAXI_OVERHEAD)

-- ===== cross-continent transit memory =====
-- Boarding then arriving on a DIFFERENT map records a usable transit edge.
TravelNet.note_transit_board("boat", 10, 20, 0, "Menethil Dock")
RaijinLab.WorldMesh.map_key = function() return "othercont" end
local edge = TravelNet.note_transit_arrive(500, 600, 0)
tc("transit edge is learned from experience", edge ~= nil and edge.to_map == "othercont")
tc("transit remembers both endpoints",
   edge and edge.from_map == "tvmap" and edge.from.x == 10 and edge.to.x == 500)

-- routing back across
RaijinLab.WorldMesh.map_key = function() return "tvmap" end
local route, why = TravelNet.route_to_map("othercont", 0, 0, 0)
tc("routes to another continent via a known transit", route ~= nil and why == "direct")
local none, why2 = TravelNet.route_to_map("nevervisited", 0, 0, 0)
tc("unknown continent reports no known transit", none ~= nil or why2 ~= nil)
tc("same map needs no transit", (TravelNet.route_to_map("tvmap", 0,0,0)) == nil)

-- boarding but NOT changing map records nothing (we just stood on the dock)
TravelNet.note_transit_board("boat", 10, 20, 0, "Dock")
tc("no map change -> no bogus transit", TravelNet.note_transit_arrive(11, 21, 0) == nil)

-- ===== solid entities =====
-- No object manager -> nothing blocks (must fail OPEN, never invent obstacles).
Obstacles.refresh(true)
tc("no OM -> nothing blocks", Obstacles.blocks(0,0,0) == false)
tc("no OM -> no penalty", Obstacles.penalty(0,0,0) == 0)

-- Feed a fake OM: one mob at (10,0,0).
RaijinLab.om = { object_list = { npcs = { { Guid = "mob1", Name = "Boar", Info = { Unit = { Dead = false } } } } } }
RaijinLab.ObjectPosition = function(self, g)
  if g == "player" then return 0, 0, 0 end
  if g == "mob1" then return 10, 0, 0 end
end
RaijinLab.ObjectCombatReach = function(self, g) return 2.0 end
function UnitGUID(u) return "me" end
__t = 200
Obstacles.refresh(true)
tc("entity is captured", Obstacles.stats().n == 1)
tc("inside the entity is blocked", Obstacles.blocks(10, 0, 0) == true)
tc("well clear of it is not blocked", Obstacles.blocks(40, 0, 0) == false)
tc("brushing past it costs extra", Obstacles.penalty(13.0, 0, 0) > 0)
tc("far away costs nothing", Obstacles.penalty(40, 0, 0) == 0)
tc("an ignored entity does not block", Obstacles.blocks(10,0,0, { ignore = { mob1 = true } }) == false)
tc("a different floor does not block", Obstacles.blocks(10, 0, 20) == false)

-- a path that runs through it is flagged
local hit, d = Obstacles.nearest_intrusion(0, 0, 20, 0, 0)
tc("intrusion on the walked segment is detected", hit ~= nil and hit.guid == "mob1")
tc("a segment that misses it is clear", Obstacles.nearest_intrusion(0, 50, 20, 50, 0) == nil)

-- the dead do not block
RaijinLab.om.object_list.npcs[1].Info.Unit.Dead = true
__t = 300
Obstacles.refresh(true)
tc("corpses do not block movement", Obstacles.blocks(10,0,0) == false)

-- master switch
RaijinLab.om.object_list.npcs[1].Info.Unit.Dead = false
__t = 400
Obstacles.refresh(true)
Obstacles.set_enabled(false)
tc("can be disabled entirely", Obstacles.blocks(10,0,0) == false and Obstacles.penalty(10,0,0) == 0)
Obstacles.set_enabled(true)
"""
    )
    t = lua.eval("tv_fails")
    n = int(lua.eval("#tv_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_TV_BODY = r'''tr_fails = {}
local function rc(name, cond) if not cond then tr_fails[#tr_fails+1] = name end end
__t = 1000
function GetTime() return __t end
function UnitLevel(u) return 30 end
RaijinLabDB = {}
TV._test_map = "trmap"
POI._test_map = "trmap"

-- ===== the field: roads pull, danger pushes =====
rc("off-road ground carries a premium", TV.factor(0,0,0) > TV.W.FLOOR)

for i = 1, 20 do TV.add_traffic(100, 0, 1) end
rc("a road is CHEAPER than open ground", TV.factor(100,0,0) < TV.factor(0,0,0))
rc("a road never goes below the floor", TV.factor(100,0,0) >= TV.W.FLOOR - 1e-9)

for i = 1, 20 do TV.add_danger(500, 0, 2) end
rc("a hostile camp is MORE expensive", TV.factor(500,0,0) > TV.factor(0,0,0))
rc("danger outweighs a road when both present", (function()
     for i = 1, 20 do TV.add_danger(100, 0, 2) end
     return TV.factor(100,0,0) > 1.0 end)())

rc("danger tolerance reduces the penalty",
   TV.factor(500,0,0,{danger_tolerance=1.0}) < TV.factor(500,0,0,{danger_tolerance=0}))

rc("an elite is a bigger threat", TV.threat_weight(30,true,30) > TV.threat_weight(30,false,30))
rc("a higher-level mob is a bigger threat", TV.threat_weight(38,false,30) > TV.threat_weight(30,false,30))
rc("a trivial grey barely counts", TV.threat_weight(5,false,30) < TV.threat_weight(30,false,30))

-- ===== decay =====
local d_before = TV.danger_at(500, 0)
local r_before = TV.traffic_at(100, 0)
__t = 1000 + TV.DANGER_HALFLIFE
local d_after = TV.danger_at(500, 0)
local r_after = TV.traffic_at(100, 0)
rc("danger decays by about half over its half-life",
   d_after < d_before * 0.6 and d_after > d_before * 0.4)
rc("roads barely decay over the same period", r_after > r_before * 0.95)

__t = 1000 + TV.DANGER_HALFLIFE * 40
TV.prune()
rc("prune keeps the road", TV.traffic_at(100,0) > 0)
rc("prune drops the faded camp", TV.danger_at(500,0) <= 0.2)

rc("an equal-length shortcut with more danger is refused",
   TV.prefer_road(100, 100, 0, 10) == true)
rc("a much shorter safe shortcut is taken",
   TV.prefer_road(500, 100, 0, 0) == false)

-- ===== growth bounds (audit) =====
-- Traversability was the largest unbounded store in the DB: cells were added ~1Hz
-- from world sampling and only the CURRENT map was ever pruned.
TV._test_map = "capmap"
TV._cap = 200
__t = 20000
for i = 1, 900 do TV.add_traffic(i * 100, 0, 3) end
-- The sweep is amortized (checked every ~10% of cap additions), so assert the
-- bound it genuinely guarantees rather than pretending it is a hard ceiling.
rc("traversability enforces a per-map cap", (function()
     local n = 0
     for _ in pairs(RaijinLabDB.traverse["capmap"].cells) do n = n + 1 end
     return n <= TV._cap * 1.2 end)())

-- prune must clean EVERY map, not just the one we are standing in - the others
-- are precisely the ones that will never be revisited to clean themselves.
TV._test_map = "othermap"
TV.add_danger(0, 0, 5)
TV._test_map = "capmap"
__t = 20000 + TV.DANGER_HALFLIFE * 60      -- long enough for danger to vanish
TV.prune()
rc("prune reaches maps we are not standing in", (function()
     local m = RaijinLabDB.traverse["othermap"]
     local n = 0
     for _ in pairs(m.cells) do n = n + 1 end
     return n == 0 end)())

-- a backwards clock (GetTime resets every session) must not freeze decay
__t = 100
TV._test_map = "clockmap"
TV.add_danger(0, 0, 10)
__t = 50                                    -- clock went BACKWARDS
rc("a backwards clock still decays (never freezes)", TV.danger_at(0, 0) < 10)

-- ===== patrol =====
__t = 5000
POI._test_map = "patrolmap"
Patrol.reset_visits()
Patrol.note_spawn("Kobold", 0, 0, 0)
Patrol.note_spawn("Kobold", 60, 0, 0)
Patrol.note_spawn("Kobold", 0, 60, 0)
Patrol.note_spawn("Wolf", 400, 0, 0)
rc("spawns are remembered per mob", #Patrol.points("Kobold") == 3)
rc("other mobs are not mixed in", #Patrol.points("Wolf") == 1)

local pt, d, why = Patrol.next_point("Kobold", 0, 0, 0)
rc("patrol picks a real spawn point", pt ~= nil and why == "ok")
rc("patrol does not pick the spot we are standing on", pt and not (pt.x == 0 and pt.y == 0))

Patrol.mark_visited(pt)
local pt2 = Patrol.next_point("Kobold", pt.x, pt.y, 0)
rc("patrol rotates to a different point after clearing one", pt2 ~= nil and pt2 ~= pt)

__t = 5000 + Patrol.RECENT * 2
local pt3 = Patrol.next_point("Kobold", pt.x, pt.y, 0)
rc("patrol returns after the respawn window", pt3 ~= nil)

rc("area_of describes the camp", (function()
     local a = Patrol.area_of("Kobold")
     return a and a.points == 3 and a.radius > 0 end)())
rc("circuit visits every point once", #Patrol.circuit("Kobold", 0, 0) == 3)
rc("unknown mob yields no patrol", (Patrol.next_point("Dragon", 0,0,0)) == nil)

-- ===== quest policy =====
local p = QP.cfg()
rc("policy has defaults", p.order ~= nil and p.reward_policy ~= nil)

rc("ordinary quest is accepted", (QP.should_accept({ id=1, title="Kill Boars", level=30 })) == true)
rc("far-too-high quest is refused", (function()
     local ok, why = QP.should_accept({ id=2, title="Raid Boss", level=60 })
     return ok == false and why == "too_high" end)())
p.accept_elite = false
rc("elite quest refused by category", (function()
     local ok, why = QP.should_accept({ id=3, title="Elite Thing", level=30, tag="Elite" })
     return ok == false and why:find("elite") ~= nil end)())
p.blacklist_ids[4] = true
rc("blacklist always wins", (QP.should_accept({ id=4, title="Nope", level=30 })) == false)
p.whitelist_ids[5] = true
rc("whitelist overrides category refusal",
   (QP.should_accept({ id=5, title="Elite But Wanted", level=30, tag="Elite" })) == true)
p.title_rules = { { pattern = "Escort", accept = false } }
rc("title rule refuses by pattern", (function()
     local ok, why = QP.should_accept({ id=6, title="An Escort Job", level=30 })
     return ok == false and why:find("rule") ~= nil end)())

rc("quest is parked after repeated failure", (QP.should_park({id=7}, { attempts = 5 })) == true)
rc("quest is not parked early", (QP.should_park({id=7}, { attempts = 0 })) == false)

local ranked = QP.rank({
  { id=10, title="Far",      level=30, progress_frac=0 },
  { id=11, title="Complete", level=30, complete=true },
  { id=12, title="Near",     level=30, progress_frac=0.8 },
}, { dist_of = function(q) if q.id==10 then return 3000 end return 50 end, player_level = 30 })
rc("smart order turns in completed quests first", ranked[1].id == 11)
rc("smart order prefers the near, part-done quest next", ranked[2].id == 12)

local rl = QP.rank({ {id=20,level=40}, {id=21,level=10} }, { order="lowest_level" })
rc("lowest_level ordering works", rl[1].id == 21)

rc("single reward is auto-taken", (QP.reward_choice({id=1}, { {index=1,quality=2} })) == 1)
rc("quality policy picks the best item",
   (QP.reward_choice({id=1}, { {index=1,quality=2,sell=99}, {index=2,quality=4,sell=1} })) == 2)
p.reward_policy = "vendor"
rc("vendor policy picks the most valuable",
   (QP.reward_choice({id=1}, { {index=1,quality=2,sell=99}, {index=2,quality=4,sell=1} })) == 1)
p.reward_policy = "manual"
rc("manual policy defers to the player", (QP.reward_choice({id=1}, { {index=1},{index=2} })) == nil)
p.reward_policy = "quality"
rc("describe() summarises the policy", type(QP.describe()) == "string" and #QP.describe() > 10)
'''

def test_traversability() -> list:
    """The traversability field (roads inferred from player traffic, danger from
    hostiles, time decay), spawn-point patrol, and the quest policy engine."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    for rel, name in (("core/POI.lua", "POI"),
                      ("core/Traversability.lua", "TV"),
                      ("core/Patrol.lua", "Patrol"),
                      ("modules/questing/QuestPolicy.lua", "QP")):
        src = (ADDON / rel).read_text(encoding="utf-8")
        lua.execute("__m = (function()" + NL + src + NL + "end)()")
        lua.execute(f"{name} = __m; RaijinLab.{name} = __m")
    lua.execute("RaijinLab.Traversability = TV; RaijinLab.QuestPolicy = QP")
    lua.execute(LUA_TV_BODY)
    t = lua.eval("tr_fails")
    n = int(lua.eval("#tr_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_QI_BODY = r'''qi_fails = {}
local function ic(name, cond) if not cond then qi_fails[#qi_fails+1] = name end end
__t = 100
function GetTime() return __t end
RaijinLabDB = {}

-- ===== objective classification: pick the right VERB =====
ic("kill objective classifies as kill", QI.classify({ kind="kill", raw="Mangy Wolf slain: 3/8" }) == "kill")
ic("use-item objective is detected", QI.classify({ kind="event", raw="Use the Smoldering Torch on the Pyre" }) == "use_item")
ic("apply wording is use_item", QI.classify({ kind="event", raw="Apply Bandage to Wounded Soldier" }) == "use_item")
ic("plant wording is use_item", QI.classify({ kind="event", raw="Plant the Banner" }) == "use_item")
ic("collect defaults to loot", QI.classify({ kind="collect", raw="Wolf Pelt: 0/6" }) == "loot")
ic("collect + use wording is use_item", QI.classify({ kind="collect", raw="Use the Net to collect Fish: 0/6" }) == "use_item")
ic("talk wording is talk", QI.classify({ kind="event", raw="Speak with Marshal Dughan" }) == "talk")
ic("object defaults to interact", QI.classify({ kind="object", raw="Lever" }) == "interact")
ic("nil objective is safe", QI.classify(nil) == "interact")

-- ===== escort detection =====
ic("escort quest detected by title", QI.is_escort({ title="Escort the Miner" }, nil) == true)
ic("protect wording detected", QI.is_escort({ title="Protect the Caravan" }, nil) == true)
ic("defend wording detected", QI.is_escort(nil, { raw="Defend the camp" }) == true)
ic("ordinary quest is not an escort", QI.is_escort({ title="Kill Boars" }, { raw="Boar slain: 0/8" }) == false)

-- ===== quest items from bags =====
-- Mock a 2-bag inventory: one quest item, one ordinary item.
local bags = {
  [0] = { { link = "|Hitem:1111|h[Smoldering Torch]|h", quest = true,  qid = 42, active = true },
          { link = "|Hitem:2222|h[Linen Cloth]|h",      quest = false } },
  [1] = { { link = "|Hitem:3333|h[Ancient Relic]|h",    quest = true,  qid = 77, active = false } },
}
function GetContainerNumSlots(b) return bags[b] and #bags[b] or 0 end
function GetContainerItemLink(b, s) local e = bags[b] and bags[b][s]; return e and e.link end
function GetContainerItemQuestInfo(b, s)
  local e = bags[b] and bags[b][s]
  if not e then return nil end
  return e.quest, e.qid, e.active
end

local items = QI.quest_items()
ic("finds exactly the quest items", #items == 2)
ic("parses item name from the link", (function()
     for _, it in ipairs(items) do if it.name == "Smoldering Torch" then return true end end
     return false end)())
ic("parses item id from the link", (function()
     for _, it in ipairs(items) do if it.id == 1111 then return true end end
     return false end)())
ic("ordinary items are excluded", (function()
     for _, it in ipairs(items) do if it.name == "Linen Cloth" then return false end end
     return true end)())

ic("item_for_quest matches the right quest", (function()
     local it = QI.item_for_quest(77); return it and it.name == "Ancient Relic" end)())
ic("item_for_quest prefers the ACTIVE item when quest is unknown", (function()
     local it = QI.item_for_quest(nil); return it and it.name == "Smoldering Torch" end)())
ic("item_by_name finds by partial name", (function()
     local it = QI.item_by_name("Torch"); return it and it.id == 1111 end)())
ic("item_by_name misses cleanly", QI.item_by_name("Nonexistent Thing") == nil)

-- using an item targets first, then uses the slot
local used, targeted = nil, nil
RaijinLab.Actions = {
  Target = function(g) targeted = g end,
  UseContainerItem = function(b, s) used = { b, s } end,
}
local ok = QI.use_item(QI.item_by_name("Torch"), "pyre-guid")
ic("use_item issues the use", ok == true and used ~= nil and used[1] == 0 and used[2] == 1)
ic("use_item targets first", targeted == "pyre-guid")
ic("use_item with no item is refused", (QI.use_item(nil)) == false)

-- ===== escort station keeping =====
Escort.reset()
-- station point must be BEHIND the npc heading and offset to a side
local sx, sy = Escort.station(100, 100, 0, 0)   -- heading +x
ic("station sits behind the NPC", sx < 100)
ic("station is offset to one side", math.abs(sy - 100) > 0.001)
ic("station offset stays bounded", math.abs(sy - 100) <= Escort.SIDE_MAX + 0.001)

-- the band: no re-path while comfortably in station
local pos = { player = {0,0,0}, npc = {8,0,0} }
RaijinLab.ObjectPosition = function(self, g)
  local p = (g == "player") and pos.player or pos.npc
  return p[1], p[2], p[3]
end
RaijinLab.om = { object_list = { npcs = {} } }
local moved = false
local function goto_fn() moved = true end
local st = Escort.step({ npc = { guid = "npc1", name = "Miner" }, goto_fn = goto_fn })
ic("in-band escort does not re-path", st == "escort:in station" and moved == false)

-- fallen behind -> follows. Step TWICE: the heading (and therefore the atan2
-- path inside station-keeping) is only computed once a previous NPC position is
-- known, so a single call would leave that branch untested.
pos.npc = {16,0,0}
moved = false
st = Escort.step({ npc = { guid = "npc1", name = "Miner" }, goto_fn = goto_fn })
ic("out-of-band escort follows", st == "escort:following" and moved == true)
pos.npc = {18,3,0}
moved = false
st = Escort.step({ npc = { guid = "npc1", name = "Miner" }, goto_fn = goto_fn })
ic("escort keeps following as the NPC moves (heading path)",
   st == "escort:following" and moved == true)

-- badly behind -> sprint straight at it
pos.npc = {60,0,0}
moved = false
st = Escort.step({ npc = { guid = "npc1", name = "Miner" }, goto_fn = goto_fn })
ic("far-behind escort catches up", st == "escort:catching up" and moved == true)

-- too close (npc stopped) -> stop pushing into its back
pos.npc = {1,0,0}
moved = false
st = Escort.step({ npc = { guid = "npc1", name = "Miner" }, goto_fn = goto_fn })
ic("escort holds instead of shoving the NPC", st == "escort:holding" and moved == false)

-- a threat outranks following
pos.npc = {16,0,0}
RaijinLab.om = { object_list = { npcs = {
  { Guid = "mob1", Name = "Bandit", Info = { Unit = { Dead = false, InCombat = true } } },
} } }
RaijinLab.ObjectPosition = function(self, g)
  if g == "player" then return 0,0,0 end
  if g == "mob1" then return 10,0,0 end
  return 16,0,0
end
function UnitCanAttack(a, b) return b == "mob1" end
local engaged = nil
st = Escort.step({ npc = { guid = "npc1", name = "Miner" },
                   goto_fn = goto_fn, engage_fn = function(g) engaged = g end })
ic("escort breaks off to defend", st:find("defending") ~= nil and engaged == "mob1")

-- losing the npc entirely is reported
st = Escort.step({ npc = nil, goto_fn = goto_fn })
ic("lost NPC is reported", st == "escort:npc lost")
'''

def test_quest_interact() -> list:
    """The quest verbs beyond killing: objective classification, quest-item
    discovery/use, and human-like escort station keeping. No client."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    for rel, name in (("modules/questing/QuestInteract.lua", "QI"),
                      ("modules/questing/Escort.lua", "Escort")):
        src = (ADDON / rel).read_text(encoding="utf-8")
        lua.execute("__m = (function()" + NL + src + NL + "end)()")
        lua.execute(f"{name} = __m; RaijinLab.{name} = __m")
    lua.execute("RaijinLab.QuestInteract = QI")
    lua.execute(LUA_QI_BODY)
    t = lua.eval("qi_fails")
    n = int(lua.eval("#qi_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_MOUNT_BODY = r'''mt_fails = {}
local function mc(name, cond) if not cond then mt_fails[#mt_fails+1] = name end end
__t = 1000
function GetTime() return __t end
RaijinLabDB = {}

-- ---- mocked 3.3.5 companion API (NOT retail C_MountJournal) ----
local mounts = {
  { id = 1, name = "Brown Horse",  spell = 111 },
  { id = 2, name = "Swift Ram",    spell = 222 },
}
function GetNumCompanions(kind) return (kind == "MOUNT") and #mounts or 0 end
function GetCompanionInfo(kind, i)
  local m = mounts[i]; if not m then return nil end
  return m.id, m.name, m.spell, "icon", false
end
local called = nil
function CallCompanion(kind, i) called = i end

-- world state knobs
local state = { mounted=false, combat=false, swimming=false, indoors=false, dead=false, casting=nil }
function IsMounted() return state.mounted end
function UnitAffectingCombat(u) return state.combat end
function IsSwimming() return state.swimming end
function IsIndoors() return state.indoors end
function UnitIsDeadOrGhost(u) return state.dead end
function UnitCastingInfo(u) return state.casting end
function Dismount() state.mounted = false end

-- ---- enumeration ----
mc("enumerates companion mounts", #Mount.list() == 2)
mc("picks the last-learned mount by default", (function()
     local m = Mount.pick(); return m and m.name == "Swift Ram" end)())
RaijinLabDB.mount = { favorite = "Brown Horse" }
mc("honours a pinned favourite", (function()
     local m = Mount.pick(); return m and m.name == "Brown Horse" end)())
RaijinLabDB.mount = nil

-- ---- gating: all the ways mounting is impossible ----
mc("can mount on open ground", (Mount.can_mount()) == true)
state.combat = true
mc("refuses in combat", (function() local ok, why = Mount.can_mount(); return ok == false and why == "combat" end)())
state.combat = false
state.swimming = true
mc("refuses while swimming", (function() local ok, why = Mount.can_mount(); return ok == false and why == "swimming" end)())
state.swimming = false
state.indoors = true
mc("refuses indoors", (function() local ok, why = Mount.can_mount(); return ok == false and why == "indoors" end)())
state.indoors = false
state.dead = true
mc("refuses while dead", (function() local ok, why = Mount.can_mount(); return ok == false and why == "dead" end)())
state.dead = false
state.casting = "Something"
mc("refuses mid-cast", (function() local ok, why = Mount.can_mount(); return ok == false and why == "casting" end)())
state.casting = nil
state.mounted = true
mc("refuses when already mounted", (function() local ok, why = Mount.can_mount(); return ok == false and why == "already_mounted" end)())
state.mounted = false

-- ---- distance decision ----
mc("short hop is not worth mounting", (function()
     local ok, why = Mount.should_mount(10); return ok == false and why == "too_close" end)())
mc("long leg is worth mounting", (Mount.should_mount(500)) == true)

-- ---- summoning ----
Mount._last_try = 0
local ok, why = Mount.summon()
mc("summon calls the companion API", ok == true and called ~= nil)
mc("summon marks a pending cast", Mount.pending() == true)
-- retry throttle: must not spam the summon every tick
called = nil
local ok2, why2 = Mount.summon()
mc("summon is throttled", ok2 == false and why2 == "cooldown" and called == nil)

-- a pending cast expires rather than hanging forever
__t = 1000 + Mount.CAST_TIME + 1
mc("a failed cast eventually clears (never hangs)", Mount.pending() == false)

-- and a successful mount clears it immediately
Mount._pending = { t = __t, name = "x" }
state.mounted = true
mc("landing the mount clears pending", Mount.pending() == false)

-- ---- dismount rules ----
mc("dismounts on arrival", (Mount.should_dismount(5)) == true)
mc("stays mounted while still travelling", (Mount.should_dismount(500)) == false)
mc("dismounts to act", (Mount.should_dismount(500, { want_action = true })) == true)
state.combat = true
mc("dismounts when combat starts", (Mount.should_dismount(500)) == true)
state.combat = false

-- ---- maintain(): the tick contract ----
-- mounted + far => hands control back (nil) so the caller keeps travelling
state.mounted = true
mc("mounted and travelling hands control back", Mount.maintain(500) == nil)
-- mounted + arrived => dismounts
local st = Mount.maintain(4)
mc("maintain dismounts on arrival", st == "mount:dismounting" and state.mounted == false)

-- unmounted + far => stops moving and summons (movement would cancel the cast)
local stopped = false
Mount._last_try = 0
Mount._pending = nil
__t = __t + 100
st = Mount.maintain(500, { stop_fn = function() stopped = true end })
mc("maintain stops before summoning", stopped == true)
mc("maintain reports summoning", st ~= nil and st:find("summoning") ~= nil)

-- unmounted + short hop => does nothing at all
Mount._pending = nil
Mount._last_try = 0
stopped = false
st = Mount.maintain(10, { stop_fn = function() stopped = true end })
mc("maintain ignores short hops", st == nil and stopped == false)

-- disabled entirely
Mount.set_enabled(false)
mc("can be disabled", (Mount.should_mount(500)) == false and Mount.maintain(500) == nil)
Mount.set_enabled(true)

-- no mounts known => never tries
mounts = {}
mc("no mounts known -> no attempt", (function()
     local ok, why = Mount.should_mount(500); return ok == false and why == "no_mounts" end)())
'''

def test_mount() -> list:
    """Mount sequencing: 3.3.5 companion API (never retail C_MountJournal), all
    the states that forbid mounting, the retry throttle, and the guarantee that a
    failed cast expires instead of stalling the bot forever."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Mount.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Mount = __m; RaijinLab.Mount = __m")
    lua.execute(LUA_MOUNT_BODY)
    t = lua.eval("mt_fails")
    n = int(lua.eval("#mt_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_REST_BODY = r'''rs_fails = {}
local function sc(name, cond) if not cond then rs_fails[#rs_fails+1] = name end end
__t = 2000
function GetTime() return __t end
RaijinLabDB = {}

-- ---- vitals mocks ----
local V = { hp = 100, hpmax = 100, mana = 100, manamax = 100, combat = false, dead = false, level = 30 }
function UnitHealth(u) return V.hp end
function UnitHealthMax(u) return V.hpmax end
function UnitPower(u, t) return V.mana end
function UnitPowerMax(u, t) return V.manamax end
function UnitAffectingCombat(u) return V.combat end
function UnitIsDeadOrGhost(u) return V.dead end
function UnitLevel(u) return V.level end
local sat = false
function SitStandOrDescendStart() sat = true end

-- ---- mana-user detection comes from the POWER BAR, never a class name ----
sc("power bar present => mana user", Rest.is_mana_user() == true)
V.manamax = 0
sc("no mana bar => not a mana user", Rest.is_mana_user() == false)
V.manamax = 100

-- ---- pure need logic ----
local c = Rest.cfg()
sc("healthy needs nothing", (function() local f,d = Rest.needs(100,100,true,c); return f==false and d==false end)())
sc("low hp needs food", (function() local f = Rest.needs(20,100,true,c); return f==true end)())
sc("low mana needs drink", (function() local _,d = Rest.needs(100,10,true,c); return d==true end)())
sc("low mana on a NON-mana user needs no drink",
   (function() local _,d = Rest.needs(100,10,false,c); return d==false end)())
sc("both when both are low", (function() local f,d = Rest.needs(20,10,true,c); return f and d end)())
sc("recovered at target", Rest.recovered(95,95,true,c) == true)
sc("not recovered if mana still low", Rest.recovered(95,10,true,c) == false)
sc("non-mana user ignores mana for recovery", Rest.recovered(95,10,false,c) == true)

-- ---- should_rest gating ----
V.hp = 20
sc("hurt out of combat -> rest", (Rest.should_rest()) == true)
V.combat = true
sc("never rest in combat", (function() local ok,w = Rest.should_rest(); return ok==false and w=="combat" end)())
V.combat = false
V.dead = true
sc("never rest while dead", (function() local ok,w = Rest.should_rest(); return ok==false and w=="dead" end)())
V.dead = false
V.hp = 100
sc("healthy -> no rest", (function() local ok,w = Rest.should_rest(); return ok==false and w=="healthy" end)())

-- ---- consumable classification ----
sc("bread is food", Rest.classify({ id=1, name="Freshly Baked Bread", itemType="Consumable" }, c) == "food")
sc("water is drink", Rest.classify({ id=2, name="Refreshing Spring Water", itemType="Consumable" }, c) == "drink")
sc("conjured water is drink not food",
   Rest.classify({ id=3, name="Conjured Fresh Water", itemType="Consumable" }, c) == "drink")
sc("a potion is neither", Rest.classify({ id=4, name="Healing Potion", itemType="Consumable" }, c) == nil)
sc("a sword is never food", Rest.classify({ id=5, name="Bread Slicer", itemType="Weapon" }, c) == nil)
sc("unknown items are never eaten", Rest.classify({ id=6, name="Mystery Thing" }, c) == nil)
-- learned overrides
c.food_ids[900] = true
sc("a learned food id is honoured", Rest.classify({ id=900, name="Whatever" }, c) == "food")
c.never_ids[900] = true
sc("never_ids wins over everything", Rest.classify({ id=900, name="Whatever" }, c) == nil)
c.never_ids[900] = nil; c.food_ids[900] = nil

-- ---- bag scanning ----
local bags = {
  [0] = { { link="|Hitem:101|h[Tough Jerky]|h",   name="Tough Jerky",   req=15, t="Consumable" },
          { link="|Hitem:102|h[Melon Juice]|h",   name="Melon Juice",   req=25, t="Consumable" },
          { link="|Hitem:103|h[Iron Sword]|h",    name="Iron Sword",    req=20, t="Weapon" } },
  [1] = { { link="|Hitem:104|h[Moist Cornbread]|h", name="Moist Cornbread", req=45, t="Consumable" } },
}
function GetContainerNumSlots(b) return bags[b] and #bags[b] or 0 end
function GetContainerItemLink(b,s) local e=bags[b] and bags[b][s]; return e and e.link end
function GetItemInfo(link)
  for _, bag in pairs(bags) do
    for _, e in ipairs(bag) do
      if e.link == link then
        -- name, link, quality, iLevel, reqLevel, itemType, itemSubType
        local sub = (e.t == "Consumable") and "Food & Drink" or "One-Handed Swords"
        return e.name, e.link, 1, 1, e.req, e.t, sub
      end
    end
  end
end

local items = Rest.find_consumables()
sc("finds food in bags", #items.food >= 1)
sc("finds drink in bags", #items.drink >= 1)
sc("ignores weapons", (function()
     for _, it in ipairs(items.food) do if it.name == "Iron Sword" then return false end end
     return true end)())
sc("excludes consumables above our level", (function()
     for _, it in ipairs(items.food) do if it.name == "Moist Cornbread" then return false end end
     return true end)())   -- req 45 > level 30
V.level = 60
items = Rest.find_consumables()
sc("includes them once we are high enough", (function()
     for _, it in ipairs(items.food) do if it.name == "Moist Cornbread" then return true end end
     return false end)())
sc("best food first (highest usable)", items.food[1].name == "Moist Cornbread")

-- ---- the tick ----
local used = {}
RaijinLab.Actions = { UseContainerItem = function(b,s) used[#used+1] = {b,s} end,
                      StopMoving = function() end }
Rest.reset()
V.hp = 100; V.mana = 100
sc("healthy tick does nothing", Rest.tick({}) == nil)

V.hp = 20; V.mana = 10
local stopped = false
local st = Rest.tick({ stop_fn = function() stopped = true end })
sc("hurt tick eats", st ~= nil and st:find("eating") ~= nil)
sc("tick stops moving first", stopped == true)
sc("tick sits down", sat == true)
sc("consumed both food and drink when both were low", #used == 2)

-- while resting it reports progress and does not re-eat
local before = #used
st = Rest.tick({})
sc("resting reports progress", st ~= nil and st:find("recovering") ~= nil)
sc("does not spam consumables while resting", #used == before)

-- recovering finishes
V.hp = 100; V.mana = 100
st = Rest.tick({})
sc("finishes when recovered", st == "rest:recovered")

-- combat aborts the meal instantly
Rest.reset()
V.hp = 20; V.mana = 10
Rest.tick({})
V.combat = true
sc("combat aborts resting", Rest.tick({}) == nil)
V.combat = false

-- No consumables -> RELEASE the slot. Rest is band 4 and the vendor errand that
-- would buy food is band 5, so holding on here starved the only goal that could
-- fix the situation - the bot sat hungry next to a merchant forever.
bags = {}
Rest.reset()
V.hp = 20
st = Rest.tick({})
sc("releases the band when it has nothing to eat", st == nil)
sc("and records why for diagnostics", Rest._no_consumables_t ~= nil)
-- it must also NOT have cancelled movement on a tick where it cannot act
local stopped2 = false
Rest.reset()
Rest.tick({ stop_fn = function() stopped2 = true end })
sc("does not stop movement when it cannot eat", stopped2 == false)

-- never sits forever
Rest._state = "resting"; Rest._t0 = __t
__t = __t + 999
sc("gives up waiting eventually", (Rest.tick({}) or ""):find("gave up") ~= nil)
'''

def test_rest() -> list:
    """Eating and drinking: mana-user detection from the POWER BAR (not class),
    consumable classification that never eats an unknown item, level gating,
    combat abort, and the guarantee it never sits forever."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Rest.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Rest = __m; RaijinLab.Rest = __m")
    lua.execute(LUA_REST_BODY)
    t = lua.eval("rs_fails")
    n = int(lua.eval("#rs_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_VENDOR_BODY = r'''vd_fails = {}
local function vc(name, cond) if not cond then vd_fails[#vd_fails+1] = name end end
__t = 3000
function GetTime() return __t end
RaijinLabDB = {}

-- ---- mocked bags ----
-- quality: 0 poor(grey) 1 common 2 uncommon ...
local bags = {
  [0] = {
    { link="|Hitem:1|h[Chipped Claw]|h",   name="Chipped Claw",   q=0, sell=57,  t="Miscellaneous" },
    { link="|Hitem:2|h[Linen Cloth]|h",    name="Linen Cloth",    q=1, sell=10,  t="Trade Goods" },
    { link="|Hitem:3|h[Green Sword]|h",    name="Green Sword",    q=2, sell=900, t="Weapon" },
    { link="|Hitem:4|h[Quest Totem]|h",    name="Quest Totem",    q=0, sell=0,   t="Quest", quest=true },
    { link="|Hitem:5|h[Worthless Token]|h",name="Worthless Token",q=0, sell=0,   t="Miscellaneous" },
  },
  [1] = {},
}
-- bags have CAPACITY independent of how full they are
local caps = { [0] = 8, [1] = 8 }
function GetContainerNumSlots(b) return caps[b] or 0 end
function GetContainerItemLink(b,s) local e=bags[b] and bags[b][s]; return e and e.link end
function GetContainerItemQuestInfo(b,s)
  local e=bags[b] and bags[b][s]; if not e then return nil end
  return e.quest and true or false, nil, false
end
function GetItemInfo(link)
  for _, bag in pairs(bags) do
    for _, e in ipairs(bag) do
      if e.link == link then
        -- name, link, quality, iLevel, reqLevel, itemType, itemSubType, stack, equip, tex, sell
        return e.name, e.link, e.q, 1, 1, e.t, "sub", 1, nil, nil, e.sell
      end
    end
  end
end

-- ---- junk selection: everything is a refusal by default ----
local c = Vendor.cfg()
vc("grey vendor-trash IS junk", (Vendor.is_junk(0,1,c)) == true)
vc("common item is NOT junk", (function() local ok,w = Vendor.is_junk(0,2,c); return ok==false and w=="too_good" end)())
vc("uncommon item is NOT junk", (Vendor.is_junk(0,3,c)) == false)
vc("QUEST item is never junk", (function() local ok,w = Vendor.is_junk(0,4,c); return ok==false and w=="quest_item" end)())
vc("worthless (unsellable) item is skipped", (function() local ok,w = Vendor.is_junk(0,5,c); return ok==false and w=="worthless" end)())
vc("empty slot is not junk", (Vendor.is_junk(1,1,c)) == false)

-- keep-list protection
c.keep_ids[1] = true
vc("keep-list protects an item", (function() local ok,w = Vendor.is_junk(0,1,c); return ok==false and w=="keep_list" end)())
c.keep_ids[1] = nil

-- unknown quality fails CLOSED (never sell what we cannot identify)
local realGII = GetItemInfo
GetItemInfo = function(link) return nil end
vc("unknown item is never sold (fails closed)",
   (function() local ok,w = Vendor.is_junk(0,1,c); return ok==false and w=="unknown_quality" end)())
GetItemInfo = realGII

-- the junk list respects the per-visit cap
vc("junk list finds the grey item", #Vendor.junk_list() == 1)
c.max_sales = 0
vc("per-visit cap is honoured", #Vendor.junk_list() == 0)
c.max_sales = 24

-- ---- selling requires an open merchant window ----
-- (UseContainerItem outside a merchant USES the item - that would eat our food)
local shown = false
MerchantFrame = { IsShown = function() return shown end }
local used = {}
RaijinLab.Actions = { UseContainerItem = function(b,s) used[#used+1]={b,s} end }
vc("never sells without a merchant open", (Vendor.sell_junk()) == 0 and #used == 0)
shown = true
vc("sells the junk at a merchant", (Vendor.sell_junk()) == 1 and #used == 1)

-- ---- repair ----
local money, repairCost, canRep = 500000, 20000, true
function GetMoney() return money end
function CanMerchantRepair() return canRep end
function GetRepairAllCost() return repairCost end
local repaired = false
function RepairAllItems() repaired = true end
vc("repairs when affordable", (Vendor.repair()) == 20000 and repaired == true)
repaired = false
canRep = false
vc("skips when the merchant cannot repair", (function() local n,w = Vendor.repair(); return n==0 and w=="cannot_repair" end)())
canRep = true
money = 100
vc("skips repair when too poor", (function() local n,w = Vendor.repair(); return n==0 and w=="too_poor" end)())
money = 30000
repairCost = 25000
vc("refuses a repair that would strand us",
   (function() local n,w = Vendor.repair(); return n==0 and w=="would_strand" end)())
money = 500000; repairCost = 0
vc("nothing to repair is a no-op", (function() local n,w = Vendor.repair(); return n==0 and w=="nothing_to_repair" end)())

-- ---- needs_vendor: when is a trip worth it ----
function GetInventoryItemDurability(slot) return 100, 100 end
-- plenty of space, full durability, and (no Rest module) -> no trip
vc("healthy state needs no vendor trip", (Vendor.needs_vendor()) == false)

-- durability low -> trip
GetInventoryItemDurability = function(slot) if slot == 5 then return 10, 100 end return 100, 100 end
vc("worn gear triggers a repair trip", (function()
     local need, why = Vendor.needs_vendor(); return need == true and why == "durability" end)())
vc("durability reports the WORST slot", math.abs(Vendor.durability_pct() - 10) < 0.01)
GetInventoryItemDurability = function(slot) return 100, 100 end

-- bags full -> trip
local many = {}
for i = 1, 8 do many[i] = { link="|Hitem:9"..i.."|h[Thing]|h", name="Thing", q=1, sell=1, t="Misc" } end
bags[1] = many
c.min_free_slots = 4
vc("full bags trigger a trip", (function()
     local need, why = Vendor.needs_vendor(); return need == true and why == "bags_full" end)())
bags[1] = {}

-- free slot counting
vc("counts free slots", Vendor.free_slots() >= 0)

-- ---- do_business runs the whole visit in the right order ----
shown = true
bags[0][1] = { link="|Hitem:1|h[Chipped Claw]|h", name="Chipped Claw", q=0, sell=57, t="Miscellaneous" }
used = {}
repairCost = 500
function GetMerchantNumItems() return 0 end
function GetMerchantItemInfo(i) return nil end
function BuyMerchantItem(i,n) end
local msg = Vendor.do_business()
vc("do_business reports what it did", type(msg) == "string" and msg:find("vendor:") ~= nil)
vc("do_business sold the junk", #used >= 1)
'''

def test_vendor() -> list:
    """Vendor safety and behaviour. Selling is DESTRUCTIVE, so the important
    assertions are the refusals: quest items, anything above grey, keep-listed,
    worthless, unidentifiable (fails closed), and never selling at all without an
    open merchant window (UseContainerItem would otherwise USE the item)."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Vendor.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Vendor = __m; RaijinLab.Vendor = __m")
    lua.execute(LUA_VENDOR_BODY)
    t = lua.eval("vd_fails")
    n = int(lua.eval("#vd_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_DEATH_BODY = r'''dt_fails = {}
local function dc(name, cond) if not cond then dt_fails[#dt_fails+1] = name end end
__t = 5000
function GetTime() return __t end
RaijinLabDB = {}
function UnitName(u) return "Tester" end
function GetRealmName() return "Ascension" end

local S = { dead=false, ghost=false, delay=0, debuffs={} }
function UnitIsDeadOrGhost(u) return S.dead end
function UnitIsGhost(u) return S.ghost end
function GetCorpseRecoveryDelay() return S.delay end
function UnitDebuff(u, i) return S.debuffs[i] end
local released, retrieved = false, false
function RepopMe() released = true end
function RetrieveCorpse() retrieved = true end

local P = { 0, 0, 0 }
RaijinLab.ObjectPosition = function(self, g) return P[1], P[2], P[3] end

-- ---- alive: nothing to do ----
dc("alive tick does nothing", Death.tick({}) == nil)

-- ---- died: records position and releases ----
P = { 100, 200, 30 }
S.dead = true; S.ghost = false
local st = Death.tick({})
dc("death is noted before releasing", st ~= nil and st:find("releasing shortly") ~= nil)
local x, y, z = Death.corpse_pos()
dc("corpse position captured", x == 100 and y == 200 and z == 30)
dc("did not release instantly (brief delay)", released == false)
__t = __t + 5
st = Death.tick({})
dc("releases after the delay", released == true and st == "death:releasing")

-- ---- PERSISTENCE: the position must survive a reload while dead ----
-- Simulate a fresh session: wipe in-memory module state but keep SavedVariables.
local saved = RaijinLabDB
dc("corpse is stored in SavedVariables", saved.death and saved.death.corpses ~= nil)
dc("stored per character", saved.death.corpses["Tester@Ascension"] ~= nil)

-- ---- ghost: walks back and retrieves ----
S.ghost = true
P = { 0, 0, 0 }          -- far from the corpse at (100,200,30)
local went = nil
st = Death.tick({ goto_fn = function(gx, gy, gz) went = { gx, gy, gz } end })
dc("ghost runs toward the corpse", went ~= nil and went[1] == 100 and went[2] == 200)
dc("corpse run is reported", st ~= nil and st:find("corpse run") ~= nil)

-- arrive at the corpse
P = { 100, 200, 30 }
S.delay = 12
st = Death.tick({})
dc("waits out the retrieval delay", st ~= nil and st:find("waiting") ~= nil and retrieved == false)
S.delay = 0
st = Death.tick({})
dc("retrieves once allowed", retrieved == true and st == "death:retrieving corpse")

-- ---- back alive: record cleared ----
S.dead = false; S.ghost = false
dc("alive again clears the corpse record", Death.tick({}) == nil and Death.corpse_pos() == nil)

-- ---- resurrection sickness is waited out, not fought through ----
S.debuffs = { [1] = "Resurrection Sickness" }
st = Death.tick({})
dc("waits out resurrection sickness", st ~= nil and st:find("sickness") ~= nil)
S.debuffs = {}
dc("healthy again proceeds", Death.tick({}) == nil)

-- ---- UNREACHABLE corpse eventually accepts the spirit healer ----
-- (never leave a ghost stranded forever)
Death.clear()
S.dead = true; S.ghost = true
P = { 0, 0, 0 }
Death.note_death(9999, 9999, 0)
local rec = select(4, Death.corpse_pos())
rec.attempts = 99
-- With NO spirit healer known, an unreachable corpse must RELEASE the slot.
-- Death sits in band 1 of the arbiter, so returning a status string here forever
-- would hold every slot and freeze the whole bot as a ghost - the deadlock the
-- audit found. Returning nil lets the Director fall through and keep playing.
RaijinLab.POI = { nearest = function() return nil end,
                  record = function() return {} end,
                  KINDS = {} }
st = Death.tick({ goto_fn = function() end })
dc("unreachable corpse with no healer RELEASES the slot (no deadlock)", st == nil)

-- ---- lost corpse position also releases rather than freezing ----
Death.clear()
st = Death.tick({ goto_fn = function() end })
dc("unknown corpse position releases the slot too", st == nil)

-- ---- with a healer remembered, it actually walks there and accepts ----
local healer = { x = 200, y = 0, z = 0, n = "Spirit Healer" }
local hd = 200
RaijinLab.POI = { nearest = function() return healer, hd end,
                  record = function() return healer end, KINDS = {} }
local went_to = nil
st = Death.tick({ goto_fn = function(x, y, z) went_to = { x, y, z } end })
dc("walks to a remembered spirit healer", st ~= nil and st:find("to spirit healer") ~= nil)
dc("and heads for the right place", went_to ~= nil and went_to[1] == 200)

hd = 3                                   -- now standing at the healer
local accepted = false
AcceptXPLoss = function() accepted = true end
RaijinLab.Actions = { Interact = function() end }
st = Death.tick({ goto_fn = function() end })
dc("accepts the resurrection when in range", st ~= nil and st:find("accepting") ~= nil)
dc("and actually calls AcceptXPLoss", accepted == true)

-- the fallback can still be switched off for a manual player
local c = Death.cfg()
c.use_spirit_healer = false
Death.clear()
st = Death.tick({ goto_fn = function() end })
dc("fallback is optional and still never deadlocks", st == nil)
c.use_spirit_healer = true

-- ---- attempts increment on a long fruitless approach ----
Death.clear()
Death.note_death(500, 500, 0)
P = { 0, 0, 0 }
local r2 = select(4, Death.corpse_pos())
Death.tick({ goto_fn = function() end })
__t = __t + 1000
Death.tick({ goto_fn = function() end })
dc("a stalled corpse run counts an attempt", (r2.attempts or 0) >= 1)
'''

LUA_TRAINER_BODY = r'''tn_fails = {}
local function nc(name, cond) if not cond then tn_fails[#tn_fails+1] = name end end
__t = 7000
function GetTime() return __t end
RaijinLabDB = {}

function UnitName(u) return "Tester" end
function GetRealmName() return "Ascension" end
local shown = true
ClassTrainerFrame = { IsShown = function() return shown end }
local money = 500000        -- 50g
function GetMoney() return money end
function UnitLevel(u) return 20 end

-- name, rank, category ("available"|"unavailable"|"used"|"header")
local svc = {
  { "Fireball",     "Rank 4", "available",   30000 },
  { "Frostbolt",    "Rank 3", "available",   20000 },
  { "Blink",        "",       "unavailable", 10000 },   -- level too low
  { "Header",       "",       "header",      0 },
  { "Pyroblast",    "Rank 2", "available",   900000 },  -- unaffordable
}
function GetNumTrainerServices() return #svc end
function GetTrainerServiceInfo(i)
  local e = svc[i]; if not e then return nil end
  return e[1], e[2], e[3]
end
function GetTrainerServiceCost(i) local e = svc[i]; return e and e[4] or 0 end
local bought = {}
function BuyTrainerService(i) bought[#bought+1] = i end

-- ---- listing ----
local list = Trainer.services()
nc("skips header rows", (function()
     for _, s in ipairs(list) do if s.name == "Header" then return false end end
     return true end)())
nc("lists the real services", #list == 4)
nc("cheapest first", list[1].cost <= list[2].cost)
nc("marks availability", (function()
     for _, s in ipairs(list) do
       if s.name == "Blink" then return s.available == false end end
     return false end)())

-- ---- affordability keeps a reserve ----
local c = Trainer.cfg()
c.reserve = 200000                        -- keep 20g back; budget = 30g
local aff = Trainer.affordable()
nc("only affordable+available are offered", #aff == 2)
nc("never offers an unavailable service", (function()
     for _, s in ipairs(aff) do if s.name == "Blink" then return false end end
     return true end)())
nc("never offers what we cannot afford", (function()
     for _, s in ipairs(aff) do if s.name == "Pyroblast" then return false end end
     return true end)())

-- reserve is genuinely protected: raise it and the budget collapses
c.reserve = 495000
nc("a large reserve blocks training", #Trainer.affordable() == 0)
c.reserve = 200000

-- ---- buying ----
local n, spent = Trainer.train_all()
nc("learns the affordable services", n == 2 and #bought == 2)
nc("reports what it spent", spent == 50000)

-- learning must invalidate the rank map so the rotation uses the new ranks
RaijinLab.RankResolver = { _dirty = false }
bought = {}
Trainer._learned = 0
n = Trainer.train_all()
nc("marks the rank resolver dirty after learning",
   RaijinLab.RankResolver._dirty == true)

-- ---- never trains without the window open ----
shown = false
local realNum = GetNumTrainerServices
GetNumTrainerServices = function() return 0 end
bought = {}
local n2, s2, why = Trainer.train_all()
nc("refuses to train with no trainer open", n2 == 0 and why == "no_trainer" and #bought == 0)
GetNumTrainerServices = realNum
shown = true

-- ---- trip heuristic ----
Trainer.set_last_level(20)
nc("no trip needed at the same level", (Trainer.needs_training()) == false)
Trainer.set_last_level(10)
nc("levelling since the last visit warrants a trip", (Trainer.needs_training()) == true)
money = 100
nc("too poor to bother", (function()
     local need, w = Trainer.needs_training(); return need == false and w == "too_poor" end)())
money = 500000
Trainer.note_visit()
nc("visiting records the level", Trainer.last_level() == 20)
nc("and then no trip is needed", (Trainer.needs_training()) == false)

-- ---- skip list ----
c.skip_names["Fireball"] = true
nc("skip list is honoured", (function()
     for _, s in ipairs(Trainer.services()) do if s.name == "Fireball" then return false end end
     return true end)())

-- PER-CHARACTER progress: last_level lived account-wide, so once ONE character
-- trained, every alt believed it had already visited at that level.
Trainer.set_last_level(40)
nc("this character remembers its level", Trainer.last_level() == 40)
function UnitName(u) return "OtherAlt" end
nc("a different character does NOT inherit it", Trainer.last_level() == 0)
function UnitName(u) return "Tester" end
nc("and the original is unchanged", Trainer.last_level() == 40)
'''

def test_death() -> list:
    """Death recovery. The critical property is that a ghost can NEVER get stuck:
    the corpse position is persisted (survives a reload while dead), the retrieval
    delay is respected, and an unreachable or lost corpse falls back to the spirit
    healer rather than freezing forever."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Death.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Death = __m; RaijinLab.Death = __m")
    lua.execute(LUA_DEATH_BODY)
    t = lua.eval("dt_fails")
    n = int(lua.eval("#dt_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_trainer() -> list:
    """Auto-training: the SOURCE fix for casting rank 1 forever. Checks the money
    reserve is genuinely protected, unavailable/unaffordable services are never
    bought, nothing is bought without the trainer window open, and learning marks
    the rank map dirty so the rotation picks the new ranks up."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Trainer.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Trainer = __m; RaijinLab.Trainer = __m")
    lua.execute(LUA_TRAINER_BODY)
    t = lua.eval("tn_fails")
    n = int(lua.eval("#tn_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_DIRECTOR_BODY = r'''dr_fails = {}
local function rc(name, cond) if not cond then dr_fails[#dr_fails+1] = name end end
__t = 100
function GetTime() return __t end
RaijinLabDB = {}
local B = Director.BANDS

-- ============ the pure decision ============
local function C(name, band, urgency, active)
  return { name = name, band = band, urgency = urgency or 0, active = active ~= false }
end

-- nothing to do
rc("no active goal -> nil", (Director.choose({ C("progress", B.progress, 0.1, false) }, nil, 0)) == nil)

-- a lower BAND always wins, however urgent the rival is. "I really want to shop"
-- must never beat "I am on fire".
local chosen = Director.choose({
  C("errand",  B.errand,  0.99),
  C("survive", B.survive, 0.01),
}, nil, 0)
rc("band beats urgency", chosen.name == "survive")

-- urgency orders WITHIN a band
chosen = Director.choose({
  C("a", B.errand, 0.2),
  C("b", B.errand, 0.9),
}, nil, 0)
rc("urgency orders within a band", chosen.name == "b")

-- ============ hysteresis: no oscillation ============
-- Currently resting; a same-band rival appears immediately. The commitment
-- window must keep us resting rather than flip-flopping.
local cur = { name = "rest", band = B.rest, since = 100 }
local cands = { C("rest", B.rest, 0.5), C("other", B.rest, 0.9) }
chosen = Director.choose(cands, cur, 101)      -- 1s later, inside the window
rc("same-band rival cannot interrupt a fresh goal", chosen.name == "rest")
local _, why = Director.choose(cands, cur, 101)
rc("and it says why", why == "committed")

-- past the commitment window, a clearly more urgent same-band goal may take over
chosen = Director.choose(cands, cur, 100 + Director.MIN_COMMIT + 1)
rc("a clearly more urgent rival takes over after the window", chosen.name == "other")

-- but a marginally more urgent one does NOT (that is what causes ping-pong)
local cands2 = { C("rest", B.rest, 0.50), C("other", B.rest, 0.55) }
chosen = Director.choose(cands2, cur, 100 + Director.MIN_COMMIT + 1)
rc("a marginal difference does not cause a switch", chosen.name == "rest")

-- ============ preemption: higher band interrupts instantly ============
cur = { name = "progress", band = B.progress, since = 100 }
chosen = Director.choose({
  C("progress", B.progress, 0.1),
  C("combat",   B.combat,   0.5),
}, cur, 100.1)                                  -- immediately, inside any window
local _, why2 = Director.choose({
  C("progress", B.progress, 0.1),
  C("combat",   B.combat,   0.5),
}, cur, 100.1)
rc("a higher band preempts immediately", chosen.name == "combat")
rc("preemption is reported", why2 == "preempted")

-- even mid-commitment, dying outranks fighting
cur = { name = "combat", band = B.combat, since = 100 }
chosen = Director.choose({ C("combat", B.combat, 0.9), C("recover", B.recover, 1.0) }, cur, 100.1)
rc("recovery outranks combat", chosen.name == "recover")

-- ============ the current goal finishing ============
cur = { name = "rest", band = B.rest, since = 100 }
chosen = Director.choose({ C("progress", B.progress, 0.1) }, cur, 200)
local _, why3 = Director.choose({ C("progress", B.progress, 0.1) }, cur, 200)
rc("a finished goal releases the slot", chosen.name == "progress")
rc("and says the current one finished", why3 == "current_finished")

-- continuing the same goal is reported as such
cur = { name = "progress", band = B.progress, since = 100 }
local _, why4 = Director.choose({ C("progress", B.progress, 0.1) }, cur, 200)
rc("continuing is reported", why4 == "continue")

-- ============ the live tick ============
Director.clear()
local ran = {}
local st = { combat = false, dead = false }
Director.register("recover", B.recover,
  function() return st.dead, 1.0, "dead" end,
  function() ran[#ran+1] = "recover"; return "recovering" end)
Director.register("combat", B.combat,
  function() return st.combat, 0.6, "fighting" end,
  function() ran[#ran+1] = "combat"; return "fighting" end)
Director.register("progress", B.progress,
  function() return true, 0.1, "questing" end,
  function() ran[#ran+1] = "progress"; return "questing" end)

__t = 1000
local status, goal = Director.tick()
rc("tick runs the only applicable goal", goal == "progress" and status == "questing")

-- combat appears -> preempts progress immediately
st.combat = true
__t = 1000.5
status, goal = Director.tick()
rc("combat preempts progress mid-commitment", goal == "combat")

-- death outranks combat
st.dead = true
__t = 1001
status, goal = Director.tick()
rc("death outranks combat", goal == "recover")

-- everything clears -> back to progress
st.dead = false; st.combat = false
__t = 1010
status, goal = Director.tick()
rc("returns to the job when the emergency passes", goal == "progress")

-- a goal that claims to be active but does nothing must release the slot,
-- otherwise it would deadlock the arbiter forever
Director.clear()
Director.register("liar", B.errand,
  function() return true, 0.9, "claims work" end,
  function() return nil end)
Director.register("progress", B.progress,
  function() return true, 0.1 end,
  function() return "questing" end)
__t = 2000
status, goal = Director.tick()
-- The liar must not hold the slot AND the tick must not be wasted: the arbiter
-- falls through to the next candidate in priority order, so real work still
-- happens on this very tick.
rc("a no-op goal does not hold the slot", Director.current() ~= "liar")
rc("the tick falls through to real work", status == "questing" and goal == "progress")
__t = 2001
status, goal = Director.tick()
rc("and it keeps working on later ticks", status ~= nil)

-- ============ observability ============
Director.clear()
Director.register("progress", B.progress, function() return true, 0.1, "questing" end,
  function() return "questing" end)
Director.register("errand", B.errand, function() return false, 0 end, function() return nil end)
local lines, current = Director.explain()
rc("explain lists every goal", #lines == 2)
rc("explain marks the active ones", (function()
     for _, l in ipairs(lines) do if l:find("ACTIVE") then return true end end
     return false end)())
__t = 3000
Director.tick()
rc("history records the decision", #Director.history() >= 1)
rc("current() reports the running goal", Director.current() == "progress")

-- disabling a goal removes it from consideration
Director.set_enabled("progress", false)
local lines2 = Director.explain()
rc("a disabled goal is not considered", #lines2 == 1)

-- ===== AUDIT REGRESSIONS =====
-- A higher-priority goal that is ACTIVE but always returns nil (bags full with no
-- vendor known - a normal early state) used to re-stamp the commitment window on
-- every fall-through, so the window never expired and every goal beneath it was
-- starved permanently.
Director.clear()
local ran2 = {}
Director.register("stuck_errand", B.errand,
  function() return true, 0.9, "no vendor known" end,
  function() return nil end)                       -- active, but never does anything
Director.register("worker", B.progress,
  function() return true, 0.1 end,
  function() ran2[#ran2+1] = "worker"; return "working" end)
__t = 9000
local st2, goal2 = Director.tick()
rc("fall-through reaches the worker", goal2 == "worker" and st2 == "working")
local since1 = Director._cur and Director._cur.since
__t = 9001
Director.tick()
local since2 = Director._cur and Director._cur.since
rc("the commitment window is NOT re-stamped every tick", since1 == since2)
__t = 9002
Director.tick()
rc("the worker keeps running rather than being starved", #ran2 == 3)
'''

def test_director() -> list:
    """The top-level goal arbiter. The properties that matter: a lower priority
    BAND always beats urgency, urgency orders within a band, a fresh goal is
    protected from same-band flip-flopping (no oscillation), a higher band
    preempts instantly, and a goal that claims work but does nothing releases the
    slot instead of deadlocking the arbiter."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Director.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Director = __m; RaijinLab.Director = __m")
    lua.execute(LUA_DIRECTOR_BODY)
    # Goals.lua is the seam that binds every service to these bands, and no
    # group ever loaded it - so renaming its reg() helper (the one function
    # every registration flows through) survived the entire suite while making
    # install() call a nil global: bot "on", arbiter empty, nothing runs.
    gsrc = (ADDON / "modules/questing/Goals.lua").read_text(encoding="utf-8")
    lua.execute("Goals = (function()" + NL + gsrc + NL + "end)()")
    lua.execute(
        r"""
local function rc(name, cond) if not cond then dr_fails[#dr_fails+1] = name end end

-- ---- Goals.install must register REAL goals through the REAL Director ----
-- install() clears the registry FIRST, then registers via reg(). If reg() is
-- broken the clear still happens, so the failure mode is not "old goals kept"
-- but "no goals at all" - which is why presence must be asserted here.
Director.clear()
RaijinLabDB = { quest = {} }
__t = 20000
local suite = { progress_step = function() return "quest:progress" end }
local ok_install, installed = pcall(Goals.install, suite)
rc("Goals.install completes without error", ok_install == true)
rc("Goals.install reports success", installed == true)
local n_goals, have = 0, {}
for name, g in pairs(Director._goals) do have[name] = g; n_goals = n_goals + 1 end
rc("install registers the full goal set",
   have.recover ~= nil and have.survive ~= nil and have.combat ~= nil
   and have.rest ~= nil and have.errand ~= nil and have.gather ~= nil
   and have.progress ~= nil)
rc("every installed goal is unified (act(dry) = act(run))", (function()
     if n_goals == 0 then return false end
     for _, g in pairs(Director._goals) do if not g.unified then return false end end
     return true
   end)())
-- The binding must be LIVE, not merely present: in a quiet world the
-- Director's own tick must choose and run the progress goal install bound.
local st_g, goal_g = Director.tick()
rc("the installed progress goal takes the tick",
   goal_g == "progress" and st_g == "quest:progress")
"""
    )
    t = lua.eval("dr_fails")
    n = int(lua.eval("#dr_fails"))
    return [t[i] for i in range(1, n + 1)]


LUA_WATCHDOG_BODY = r'''wd_fails = {}
local function wc(name, cond) if not cond then wd_fails[#wd_fails+1] = name end end

-- ---- the supervisor must not be a passenger ----
-- It was called ONLY from inside Suite.tick, so the one failure it exists to
-- catch - the suite stopping - also stopped the supervisor. Live: a step()
-- exception killed nav, the quest tick died with it, and the heartbeat reported
-- "(moving)" for 14 minutes with nothing watching.
CreateFrame = CreateFrame or function()
    return { SetScript = function(self, k, f) self[k] = f end }
end
wc("watchdog exposes an independent heartbeat", type(Watchdog.start) == "function")
wc("and can report whether it is running", type(Watchdog.is_running) == "function")
wc("not running before start", Watchdog.is_running() == false)
Watchdog.start()
wc("running after start", Watchdog.is_running() == true)
Watchdog.start()
wc("start is idempotent", Watchdog.is_running() == true)
Watchdog.stop()
wc("stop actually stops", Watchdog.is_running() == false)
__t = 1000
function GetTime() return __t end
RaijinLabDB = { modules = { quest = true } }
local P = { 0, 0, 0 }
RaijinLab.ObjectPosition = function(self, g) return P[1], P[2], P[3] end
function UnitIsDeadOrGhost(u) return false end
local navcancelled = false
RaijinLab.Nav = { cancel = function() navcancelled = true end }
RaijinLab.Director = {}
RaijinLab.QuestSuite = {}
RaijinLab.Rest = { reset = function() RaijinLab.Rest._did = true end }
RaijinLab.Mount = {}
RaijinLab.Patrol = { reset_visits = function() RaijinLab.Patrol._did = true end }

local c = Watchdog.cfg()
Watchdog.reset()

-- ---- doing nothing is NOT progress ----
-- The whole point: ticking, choosing goals, "being busy" must never reset the timer.
__t = 1000
Watchdog.tick()
__t = 1000 + c.nudge_after - 5
wc("no escalation before the threshold", Watchdog.tick() == nil)
__t = 1000 + c.nudge_after + 1
wc("nudges after the idle threshold", Watchdog.tick() == "nudge")
wc("nudge cancelled navigation", navcancelled == true)
wc("nudge is level 1", Watchdog._level == 1)

-- it must not re-nudge every tick at the same level
__t = __t + 1
wc("does not re-fire the same level", Watchdog.tick() == nil)

-- ---- escalation ----
__t = 1000 + c.reset_after + 1
wc("escalates to a service reset", Watchdog.tick() == "reset")
wc("reset cleared the Rest state machine", RaijinLab.Rest._did == true)
wc("reset cleared patrol visits", RaijinLab.Patrol._did == true)
wc("reset is level 2", Watchdog._level == 2)

__t = 1000 + c.stop_after + 1
wc("finally halts", Watchdog.tick() == "halt")
wc("halt stops the quest module", RaijinLabDB.modules.quest == false)
wc("halt is level 3", Watchdog._level == 3)

-- ---- real progress resets everything ----
RaijinLabDB.modules.quest = true
Watchdog.note("kill")
wc("progress clears the escalation level", Watchdog._level == 0)
wc("progress resets the idle timer", Watchdog.since_progress() == 0)
wc("progress is counted by kind", Watchdog._counts["kill"] == 1)
__t = __t + 10
wc("no escalation right after progress", Watchdog.tick() == nil)

-- ---- movement counts, jitter does not ----
Watchdog.reset()
__t = __t + 100
P = { 0, 0, 0 }
Watchdog.tick()                       -- first sample
__t = __t + c.sample_every + 1
P = { 1, 0, 0 }                       -- 1yd: below move_epsilon, this is jitter
Watchdog.tick()
local idle_after_jitter = Watchdog.since_progress()
wc("jitter does not count as progress", idle_after_jitter > 0)
__t = __t + c.sample_every + 1
P = { 50, 0, 0 }                      -- real travel
Watchdog.tick()
wc("real movement counts as progress", Watchdog.since_progress() == 0)

-- ---- not supervising when nothing is running ----
RaijinLabDB.modules.quest = false
__t = __t + 10000
wc("idle bot is not escalated", Watchdog.tick() == nil)
wc("and the timer is held fresh", Watchdog.since_progress() == 0)
RaijinLabDB.modules.quest = true

-- ---- death gets a long leash, but NOT an unconditional one ----
-- The old version reset the timer on every dead tick, so a ghost that could not
-- reach its corpse and knew of no spirit healer was never supervised at all - the
-- one situation that strands a run forever was the one exempted.
Watchdog.reset()
UnitIsDeadOrGhost = function(u) return true end
__t = __t + 60
wc("a normal corpse run is not treated as a stall", Watchdog.tick() == nil)
__t = __t + (c.dead_grace or 600) + 10
wc("but a ghost stuck past the leash IS escalated", Watchdog.tick() ~= nil)
UnitIsDeadOrGhost = function(u) return false end

-- ---- can be disabled ----
c.enabled = false
Watchdog.reset()
__t = __t + 10000
wc("can be disabled entirely", Watchdog.tick() == nil)
c.enabled = true

-- ---- NEVER-PROGRESSED IS THE WORST CASE, NOT THE HEALTHIEST ------------
-- since_progress() answered 0 while _last_progress was still at its initial 0,
-- so "we have never once recorded progress" read as "progress happened this
-- instant". A bot that wedged before its first step was invisible to the
-- watchdog permanently, and the longer it sat the healthier it looked.
Watchdog._last_progress = 0
Watchdog._armed_t = nil
wc("unarmed watchdog does not accuse", Watchdog.since_progress() == 0)
Watchdog._armed_t = __t - 300
wc("armed and never progressed = 300s, not 0s",
   math.abs(Watchdog.since_progress() - 300) < 0.01)
wc("...and that is long enough to trip any threshold",
   Watchdog.since_progress() > 60)
-- a real progress stamp still wins over the armed clock
Watchdog._last_progress = __t - 5
wc("recorded progress is measured from the stamp",
   math.abs(Watchdog.since_progress() - 5) < 0.01)
Watchdog._last_progress = 0; Watchdog._armed_t = nil
'''

def test_runtime_arm() -> list:
    """The runtime-systems arm must RETRY until it succeeds, not fire once.

    ArmRuntimeSystems returns early without setting _runtime_armed when the
    player is not ready, so an edge-triggered attempt that lands a moment too
    early leaves the object manager unarmed for the whole session - the standing
    "N units from the bridge but the engine snapshot is EMPTY".
    """
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("math.randomseed(42)")
    lua.execute("""
RaijinLab = {}
__t = 1000
function GetTime() return __t end
function UnitName() return "Tester" end
function CreateFrame()
  return { SetScript = function(self, k, f) self[k] = f end }
end
""")
    src = (ADDON / "core/Runtime.lua").read_text(encoding="utf-8")
    lua.execute(src)
    lua.execute(r"""
ra_fails = {}
local function ac(name, cond) if not cond then ra_fails[#ra_fails+1] = name end end
local RL = RaijinLab
local A = RL.should_arm

ac("no runtime -> never arm", A(false, false, 0, 100, true) == false)
ac("already armed -> do not re-arm", A(true, true, 0, 100, true) == false)
ac("player not ready -> wait (the #132 in-world gate)",
   A(true, false, 0, 100, false) == false)
-- The settle is 6s (post-reload AV: om.enable=1 ~1s after BRIDGE ONLINE while
-- FrameXML was still settling). These rows once pinned a 1.25s default that no
-- longer exists; they now test the REAL boundary, including that a forgotten
-- settle argument defaults SAFE (6s), not to zero.
ac("inside the settle -> wait", A(true, false, 100, 105.9, true) == false)
ac("default settle is the production settle, not 0",
   A(true, false, 100, 101.0, true) == false)
ac("past the settle with everything ready -> ARM",
   A(true, false, 100, 106.1, true) == true)
ac("explicit shorter settle is honoured (deliberate act)",
   A(true, false, 100, 101.5, true, 1.25) == true)

-- THE REGRESSION ITSELF: an attempt that failed because the player was not
-- ready must be retried on a LATER tick. Edge-triggered code answered "arm"
-- exactly once and then never again.
local armed = false
local first = A(true, armed, 100, 106.6, false)   -- player not ready yet
ac("first attempt correctly declines", first == false)
local second = A(true, armed, 100, 107.0, true)   -- player ready now
ac("a later tick RETRIES rather than giving up", second == true)

-- and once it succeeds it must stop asking
armed = true
ac("stops retrying after success", A(true, armed, 100, 200, true) == false)
""")
    t = lua.eval("ra_fails")
    n = int(lua.eval("#ra_fails"))
    return [t[i + 1] for i in range(n)]


def test_watchdog() -> list:
    """The never-silently-wedge guarantee. Critically: merely ticking must NOT
    count as progress (a bot that looks busy for hours is the failure this
    exists to catch), jitter is not movement, escalation goes nudge -> reset ->
    halt without re-firing, and real progress clears everything."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Watchdog.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Watchdog = __m; RaijinLab.Watchdog = __m")
    lua.execute(LUA_WATCHDOG_BODY)
    t = lua.eval("wd_fails")
    n = int(lua.eval("#wd_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_nav_states() -> list:
    """Nav.tick's Navigator-state mapping. The audit found it fell through to
    "moving" for ANY unrecognised state, so the Navigator's TERMINAL states
    ("failed", "fell") were reported to the caller as travel in progress - the
    caller then never re-issued the move and the bot stood still forever while
    claiming to be on its way."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Nav.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Nav = __m; RaijinLab.Nav = __m")
    lua.execute(
        r"""
ns_fails = {}
local function nc(name, cond) if not cond then ns_fails[#ns_fails+1] = name end end
RaijinLabDB = { nav = { steering = true } }
RaijinLab.Navigator = { state = "moving" }
function GetTime() return 1 end

local function st(s) RaijinLab.Navigator.state = s; return Nav.tick(2.0) end

nc("arrived maps to arrived", st("arrived") == "arrived")
nc("idle maps to idle", st("idle") == "idle")
nc("nil maps to idle", st(nil) == "idle")
nc("moving maps to moving", st("moving") == "moving")
nc("pathfinding is still progress", st("pathfinding") == "moving")
nc("stuck maps to stuck", st("stuck") == "stuck")
-- the ones that mattered: terminal failures must NOT read as progress
nc("failed is NOT reported as moving", st("failed") ~= "moving")
nc("fell is NOT reported as moving", st("fell") ~= "moving")
-- and any future/unknown state must fail loud rather than silently look fine
nc("an unknown state is not reported as moving", st("some_new_state") ~= "moving")
"""
    )
    t = lua.eval("ns_fails")
    n = int(lua.eval("#ns_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_telemetry() -> list:
    """Structured telemetry. The log is only useful if it is machine-readable and
    stable: deterministic key order, values that never break the parser (no
    spaces/newlines), level filtering that never silences errors, and change/rate
    limiting so a 33Hz loop cannot flood the file."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/Telemetry.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("Tel = __m; RaijinLab.Telemetry = __m")
    lua.execute(
        r"""
tm_fails = {}
local function tc(name, cond) if not cond then tm_fails[#tm_fails+1] = name end end
__t = 100
function GetTime() return __t end
RaijinLabDB = {}

-- capture what would be written
local written = {}
RaijinLab.DevLog = { log = function(cat, msg) written[#written+1] = { cat = cat, msg = msg } end }

-- ---- structured, parseable output ----
Tel.info("director", "switch", { goal = "rest", band = 4, urgency = 0.625 })
local last = written[#written]
tc("writes to the right category", last.cat == "director")
tc("carries a level tag and event", last.msg:find("^I switch") ~= nil)
tc("emits key=value pairs", last.msg:find("goal=rest") ~= nil and last.msg:find("band=4") ~= nil)
tc("rounds floats (no 14-digit noise)", last.msg:find("urgency=0.625") ~= nil)

-- deterministic key ORDER, so lines diff cleanly
written = {}
Tel.info("x", "e", { zebra = 1, alpha = 2, mid = 3 })
tc("keys are sorted", written[1].msg:find("alpha=2 mid=3 zebra=1") ~= nil)

-- values must never break the parser
written = {}
Tel.info("x", "e", { s = "two words", n = nil })
tc("spaces in values are escaped", written[1].msg:find("s=two_words") ~= nil)
written = {}
Tel.info("x", "e", { b = true, f = 1/0 })
tc("booleans and infinities are safe",
   written[1].msg:find("b=true") ~= nil and written[1].msg:find("f=inf") ~= nil)

-- ---- level filtering ----
Tel.set_level(nil, 3)             -- info and above
written = {}
Tel.debug("x", "quiet", {})
tc("debug is filtered at level 3", #written == 0)
Tel.info("x", "loud", {})
tc("info still passes", #written == 1)
-- errors must NEVER be silenced by a low level
Tel.set_level(nil, 1)
written = {}
Tel.info("x", "info", {})
tc("info is filtered at level 1", #written == 0)
Tel.err("x", "boom", {})
tc("errors are never filtered", #written == 1)
Tel.set_level(nil, 4)

-- per-category override
Tel.set_level("noisy", 1)
written = {}
Tel.info("noisy", "spam", {})
tc("per-category override silences one category", #written == 0)
Tel.info("other", "kept", {})
tc("without affecting the others", #written == 1)

-- ---- flood control ----
written = {}
for i = 1, 50 do Tel.every("hot", 1.0, "x", 3, "tick", {}) end
tc("rate limit collapses a hot loop to one line", #written == 1)
__t = 102
Tel.every("hot", 1.0, "x", 3, "tick", {})
tc("and allows one again after the gap", #written == 2)

-- change-only emission: transitions matter, steady state does not
written = {}
Tel.on_change("navstate", "moving", "nav", "goto")
Tel.on_change("navstate", "moving", "nav", "goto")
Tel.on_change("navstate", "moving", "nav", "goto")
tc("repeated identical state logs once", #written == 1)
Tel.on_change("navstate", "stuck", "nav", "goto")
tc("a real change logs again", #written == 2)
tc("and records both sides of the transition",
   written[2].msg:find("from=moving") ~= nil and written[2].msg:find("to=stuck") ~= nil)

-- counts are tracked even when filtered, so silence is measurable
tc("counts every emit attempt", (Tel.counts()["noisy"] or 0) > 0)
"""
    )
    t = lua.eval("tm_fails")
    n = int(lua.eval("#tm_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_facing() -> list:
    """Facing validation. Found LIVE: the local player's facing read as 4.5e20 in
    1185/1185 heartbeat samples. That is not just a bad number - the runtime
    normalises with `while (d < -PI) d += 2PI`, which NEVER terminates at that
    magnitude (the ULP dwarfs 2PI), so a routine cast-facing check could freeze
    the client. Guard at the boundary and normalise without loops."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    lua.execute(
        r"""
fc_fails = {}
local function fc(name, cond) if not cond then fc_fails[#fc_fails+1] = name end end

-- the two pure helpers, mirrored from API.lua
local TWO_PI = math.pi * 2
local function ValidFacing(f)
    if type(f) ~= "number" then return nil end
    if f ~= f then return nil end
    if f < -TWO_PI or f > 2 * TWO_PI then return nil end
    return f
end
local function norm_pi(d)
    local two = math.pi * 2
    d = d % two
    if d > math.pi then d = d - two end
    return d
end

-- ---- validation ----
fc("a normal facing passes", ValidFacing(1.57) == 1.57)
fc("zero passes", ValidFacing(0) == 0)
fc("just under 2pi passes", ValidFacing(6.28) ~= nil)
fc("THE OBSERVED GARBAGE is rejected", ValidFacing(4.508161281211813e20) == nil)
fc("NaN is rejected", ValidFacing(0/0) == nil)
fc("huge negative is rejected", ValidFacing(-1e20) == nil)
fc("a non-number is rejected", ValidFacing("x") == nil)
fc("nil is rejected", ValidFacing(nil) == nil)

-- ---- normalisation must TERMINATE and be correct ----
fc("normalises a positive overshoot", math.abs(norm_pi(math.pi + 0.1) - (-math.pi + 0.1)) < 1e-6)
fc("normalises a negative overshoot", math.abs(norm_pi(-math.pi - 0.1) - (math.pi - 0.1)) < 1e-6)
fc("leaves an in-range angle alone", math.abs(norm_pi(1.0) - 1.0) < 1e-6)
fc("normalises many turns", math.abs(norm_pi(1.0 + 10 * TWO_PI) - 1.0) < 1e-4)
-- the critical one: this input is what hangs a subtract-loop implementation
local ok = pcall(function() return norm_pi(4.508161281211813e20) end)
fc("garbage magnitude TERMINATES (no infinite loop)", ok == true)
local v = norm_pi(4.508161281211813e20)
fc("and yields an in-range angle", v >= -math.pi - 1e-6 and v <= math.pi + 1e-6)

-- ---- ObjectIsBehind: computed in Lua for the same termination guarantee ----
-- Mirror the API.lua definition. Any future rewrite must preserve BOTH the
-- geometry (angle from TARGET to ATTACKER vs the target's facing) and the
-- termination guarantee (fmod-style normalisation), because the runtime path
-- used to spin forever on a bad facing.
local function ObjectIsBehind(atk, tgt)
    local f = ValidFacing(tgt.facing)
    if not f then return nil end
    local atan2 = math.atan2 or math.atan     -- 5.3+ merged atan2 into atan
    local ang = atan2(atk.y - tgt.y, atk.x - tgt.x)
    return math.abs(norm_pi(ang - f)) > (math.pi / 2)
end
-- Target facing +x. Attacker at (+1,0) is in front, at (-1,0) is behind.
local T = { x = 0, y = 0, facing = 0 }
fc("attacker directly in front is not behind",
   ObjectIsBehind({ x = 1, y = 0 }, T) == false)
fc("attacker directly behind IS behind",
   ObjectIsBehind({ x = -1, y = 0 }, T) == true)
fc("straight left is on the flank, not behind",
   ObjectIsBehind({ x = 0, y = 1 }, T) == false)
fc("straight right is on the flank, not behind",
   ObjectIsBehind({ x = 0, y = -1 }, T) == false)
-- rear-quadrant boundary: 135 degrees off-facing is behind, 45 is not
fc("135deg is in the rear arc",
   ObjectIsBehind({ x = -1, y = 1 }, T) == true)
fc("45deg is in the front arc",
   ObjectIsBehind({ x = 1, y = 1 }, T) == false)
-- garbage target facing must not hang and must not lie
T.facing = 4.508161281211813e20
local ok2, r = pcall(ObjectIsBehind, { x = -1, y = 0 }, T)
fc("garbage facing does NOT hang IsBehind", ok2 == true)
fc("garbage facing returns nil (unknown), not a fabricated bool", r == nil)
-- an attacker AT the target's position has no angle - must not divide-by-zero-hang
T.facing = 0
local ok3 = pcall(ObjectIsBehind, { x = 0, y = 0 }, T)
fc("coincident positions do not hang", ok3 == true)
"""
    )

    # Not tautological: also assert that the SHIPPING API.lua definition of
    # ObjectIsBehind uses the same building blocks the test just exercised. This
    # keeps the local mirror above from drifting away from the real function - a
    # drift that would leave the mirror green while shipping code silently regressed.
    api_src = (ADDON / "core/API.lua").read_text(encoding="utf-8")
    # slice down to the function so each needle scopes to ObjectIsBehind only -
    # the same tokens appear elsewhere in the file, and matching the whole file
    # would let the guards pass even when the function had been gutted.
    start = api_src.find("function RaijinLab:ObjectIsBehind(")
    end = api_src.find("\nend", start) if start >= 0 else -1
    body = api_src[start:end] if start >= 0 and end >= 0 else ""
    api_fails = []
    if not body:
        api_fails.append("API.lua ObjectIsBehind: definition missing")
    else:
        # Anti-mutation: forbid the exact patterns a regression would introduce.
        # A "must have X" check is a weak guard - a mutation that keeps X on the
        # line and neuters the surrounding code passes it.
        require = [
            ("ValidFacing(RaijinLab:ObjectFacing(object2))", "must validate target facing before use"),
            ("atan2 or math.atan",                            "must survive Lua 5.3+ removal of math.atan2"),
            ("norm_pi(ang - f)",                              "must normalise via the loop-safe helper"),
            ("math.pi / 2",                                   "rear-arc threshold must be 90 degrees"),
            ("return nil",                                    "must return unknown, not a bool, on bad input"),
        ]
        forbid = [
            ("while d < -math.pi",                            "subtract-loop normalisation re-introduced (never terminates on bad facing)"),
            ("return false end",                              "bad-input path fabricates a bool - must return nil"),
        ]
        for needle, why in require:
            if needle not in body:
                api_fails.append(f"API.lua ObjectIsBehind: {why}")
        for needle, why in forbid:
            if needle in body:
                api_fails.append(f"API.lua ObjectIsBehind: {why}")
    if api_fails:
        lua.execute("for _,m in ipairs({" +
                    ",".join(repr(m) for m in api_fails) +
                    "}) do fc_fails[#fc_fails+1] = m end")
    t = lua.eval("fc_fails")
    n = int(lua.eval("#fc_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_ui_layering() -> list:
    """Suite window layering. WoW draws by STRATA first, then frame level, and
    HIGH is BELOW DIALOG - which is why the main menu rendered underneath the very
    editor it opens. All suite windows must share one strata (so level ordering
    applies at all), the last-clicked window must come to the front, the counter
    must re-base rather than grow forever, and modal popups must stay above."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/UI.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("UI = __m; RaijinLab.UI = __m")
    lua.execute(
        r"""
ui_fails = {}
local function uc(name, cond) if not cond then ui_fails[#ui_fails+1] = name end end

-- minimal frame stub
local function frame()
  local f = { _lvl = 0, _strata = "MEDIUM", _top = false, _hooks = {}, _raised = 0 }
  function f:SetFrameLevel(n) self._lvl = n end
  function f:GetFrameLevel() return self._lvl end
  function f:SetFrameStrata(s) self._strata = s end
  function f:GetFrameStrata() return self._strata end
  function f:SetToplevel(v) self._top = v end
  function f:EnableMouse(v) self._mouse = v end
  function f:Raise() self._raised = self._raised + 1 end
  function f:HookScript(ev, fn) self._hooks[ev] = fn end
  return f
end

local menu, editor = frame(), frame()
UI.RegisterWindow(menu)
UI.RegisterWindow(editor)

-- ---- the actual reported bug: menu must not be in a LOWER strata ----
-- Assert the REQUIREMENT, not the constant: comparing the frame's strata to
-- UI.WINDOW_STRATA is tautological and passes even when that constant is set back
-- to the buggy "HIGH". The real rule is that suite windows must sit at DIALOG or
-- above, because that is where Blizzard panels and our own dialogs live.
local RANK = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
               DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
uc("window strata is at least DIALOG (above ordinary UI)",
   (RANK[UI.WINDOW_STRATA] or 0) >= RANK.DIALOG)
uc("the menu frame really got that strata", (RANK[menu:GetFrameStrata()] or 0) >= RANK.DIALOG)
uc("modal strata is strictly above the window strata",
   (RANK[UI.MODAL_STRATA] or 0) > (RANK[UI.WINDOW_STRATA] or 0))
uc("editor shares that strata", editor:GetFrameStrata() == UI.WINDOW_STRATA)
uc("sharing a strata is what makes level ordering apply",
   menu:GetFrameStrata() == editor:GetFrameStrata())

-- most recently registered/shown is on top
uc("editor opened last is above the menu", editor:GetFrameLevel() > menu:GetFrameLevel())

-- ---- click to front ----
UI.BringToFront(menu)
uc("clicking the menu brings it above the editor", menu:GetFrameLevel() > editor:GetFrameLevel())
UI.BringToFront(editor)
uc("and clicking the editor puts it back on top", editor:GetFrameLevel() > menu:GetFrameLevel())

-- windows are marked toplevel so the client raises them within the strata too
uc("windows are toplevel", menu._top == true)
uc("and mouse-enabled", menu._mouse == true)

-- OnMouseDown / OnShow are hooked so selection actually raises
uc("mouse-down is hooked", type(menu._hooks["OnMouseDown"]) == "function")
uc("show is hooked", type(menu._hooks["OnShow"]) == "function")
menu._lvl = 0
menu._hooks["OnMouseDown"](menu)
uc("the hook really raises", menu:GetFrameLevel() > editor:GetFrameLevel())

-- ---- the counter must not grow without bound ----
for i = 1, 200 do UI.BringToFront(menu); UI.BringToFront(editor) end
uc("level counter re-bases instead of growing forever", UI._z <= 700)
uc("ordering still holds after a re-base", editor:GetFrameLevel() > menu:GetFrameLevel())

-- ---- modals sit ABOVE every window and are not part of the raise set ----
local popup = frame()
UI.RegisterWindow(popup, { modal = true })
uc("a modal uses the modal strata", popup:GetFrameStrata() == UI.MODAL_STRATA)
uc("modal strata differs from the window strata", UI.MODAL_STRATA ~= UI.WINDOW_STRATA)
local before = popup:GetFrameLevel()
UI.BringToFront(menu)
uc("raising a window does not disturb the modal", popup:GetFrameLevel() == before)
uc("and the modal stays in its own strata", popup:GetFrameStrata() == UI.MODAL_STRATA)

-- registering twice must not duplicate the window in the re-base set
local n1 = #UI._windows
UI.RegisterWindow(menu)
uc("re-registering does not duplicate", #UI._windows == n1)
"""
    )
    t = lua.eval("ui_fails")
    n = int(lua.eval("#ui_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_config_backup() -> list:
    """Config backup/restore. WoW only writes SavedVariables on a CLEAN logout, so
    a crash loses everything since login ("my config reset randomly"). The safety
    rules matter more than the feature: a restore must only FILL MISSING data and
    must never overwrite live work, and an empty snapshot must never replace a
    good backup."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    NL = chr(10)
    src = (ADDON / "core/ConfigBackup.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function()" + NL + src + NL + "end)()")
    lua.execute("CB = __m; RaijinLab.ConfigBackup = __m")
    lua.execute(
        r"""
cb_fails = {}
local function bc(name, cond) if not cond then cb_fails[#cb_fails+1] = name end end
__t = 1000
function GetTime() return __t end

-- in-memory fake filesystem behind the runtime file API
local FS = {}
RaijinLab.GetWoWDirectory = function() return "WOWDIR" end
RaijinLab.WriteFile = function(self, path, text) FS[path] = text; return true end
RaijinLab.ReadFile  = function(self, path) return FS[path] end

-- ---- serialize / load round trip ----
RaijinLabDB = {
  rotations = { ["Raiden Reaper"] = { slots = { { spell_id = 561289, name = "Soul Capture" } } } },
  active_rotation = "Raiden Reaper",
  quest = { flee_hp = 20, use_mount = true },
}
bc("saves when there is real work to protect", CB.save(true) == true)
local snap = CB.load(CB._slot)
bc("backup reads back", type(snap) == "table")
bc("round-trips a nested rotation",
   snap and snap.rotations and snap.rotations["Raiden Reaper"]
   and snap.rotations["Raiden Reaper"].slots[1].spell_id == 561289)
bc("round-trips a string with spaces", snap.active_rotation == "Raiden Reaper")
bc("round-trips booleans and numbers",
   snap.quest.use_mount == true and snap.quest.flee_hp == 20)

-- ---- an EMPTY snapshot must never replace a good backup ----
local good_slot = CB._slot
RaijinLabDB = { quest = { flee_hp = 20 } }          -- no rotations at all
local ok, why = CB.save(true)
bc("refuses to back up an empty config", ok == false and why == "empty")
bc("the good backup is untouched", CB.load(good_slot) ~= nil)

-- ---- reset detection ----
bc("a config with no rotations looks reset", CB.looks_reset() == true)
RaijinLabDB = { rotations = { A = { slots = { { spell_id = 1234 } } } } }
bc("a config with rotations does not", CB.looks_reset() == false)

-- THE BUG THAT CAUSED THE USER'S "deleted rotations": when a character's store is
-- empty the Executor seeds a placeholder Default holding one blank slot. Counting
-- that as work made looks_reset() say "all good" and the backup was never offered.
RaijinLabDB = { rotations = { Default = { slots = { { spell_id = 0, name = "Empty" } } } } }
bc("an auto-created empty placeholder is NOT work", CB.looks_reset() == true)
bc("...and is not worth writing over a good backup", CB.worth_writing(RaijinLabDB) == false)
-- rotations live per character, so the count has to look there too
RaijinLabDB = { characters = { ["Sxth-Vol'jin"] = {
    rotations = { Real = { slots = { { spell_id = 555 } } } } } } }
bc("counts rotations inside character buckets", CB.looks_reset() == false)
RaijinLabDB = { characters = { ["Sxth-Vol'jin"] = {
    rotations = { Default = { slots = { { spell_id = 0 } } } } } } }
bc("a character holding only a placeholder still looks reset", CB.looks_reset() == true)

-- ---- restore fills MISSING data only ----
RaijinLabDB = {}                                     -- simulate the wipe
local did, filled = CB.restore()
bc("restores after a wipe", did == true)
bc("brings the rotation back",
   RaijinLabDB.rotations and RaijinLabDB.rotations["Raiden Reaper"] ~= nil)
bc("restores the active pointer", RaijinLabDB.active_rotation == "Raiden Reaper")

-- CRITICAL: never clobber live data
RaijinLabDB = { active_rotation = "MyNewerChoice",
                rotations = { ["Raiden Reaper"] = { slots = { { spell_id = 999 } } } } }
CB.restore()
bc("does NOT overwrite a live setting", RaijinLabDB.active_rotation == "MyNewerChoice")
bc("does NOT overwrite a live rotation",
   RaijinLabDB.rotations["Raiden Reaper"].slots[1].spell_id == 999)

-- but it DOES fill a rotation that is genuinely missing
RaijinLabDB = { rotations = { Other = { slots = { { spell_id = 77 } } } } }
CB.restore()
bc("fills a missing rotation alongside existing ones",
   RaijinLabDB.rotations["Raiden Reaper"] ~= nil and RaijinLabDB.rotations.Other ~= nil)

-- ---- placeholder replacement + per-character restore ----
-- The decoy Default occupies the name, so a fill-if-nil restore skipped exactly
-- the case it exists for.
CB._slot = 0; CB._last = 0
RaijinLabDB = { rotations = { ["Raiden Reaper"] = { slots = { { spell_id = 3030 } } } },
                characters = { ["Sxth-Vol'jin"] = { active_config = "Default",
                    rotations = { ["Raiden Hero"] = { slots = { { spell_id = 4040 } } } } } } }
CB.save(true)
-- now simulate logging in on a DIFFERENT account: the store is bare and the
-- Executor has seeded blank placeholders
RaijinLabDB = { rotations = { ["Raiden Reaper"] = { slots = { { spell_id = 0 } } } },
                characters = { ["Sxth-Vol'jin"] = { active_config = "Default",
                    rotations = { ["Raiden Hero"] = { slots = { { spell_id = 0 } } },
                                  Default = { slots = { { spell_id = 0 } } } } } } }
bc("a store of only placeholders looks reset", CB.looks_reset() == true)
CB.restore()
bc("placeholder was replaced by the real rotation",
   RaijinLabDB.rotations["Raiden Reaper"].slots[1].spell_id == 3030)
bc("per-character placeholder was replaced too",
   RaijinLabDB.characters["Sxth-Vol'jin"].rotations["Raiden Hero"].slots[1].spell_id == 4040)

-- and a REAL live rotation is still never overwritten
RaijinLabDB = { characters = { ["Sxth-Vol'jin"] = { active_config = "Default",
                    rotations = { ["Raiden Hero"] = { slots = { { spell_id = 9999 } } } } } } }
CB.restore()
bc("a real per-character rotation is never clobbered",
   RaijinLabDB.characters["Sxth-Vol'jin"].rotations["Raiden Hero"].slots[1].spell_id == 9999)


-- ---- no backup at all is handled ----
FS = {}
local d2, w2 = CB.restore()
bc("no backup is reported, not crashed", d2 == false and w2 == "no_backup")

-- ---- a corrupt backup must not execute or crash ----
FS[CB.path(1)] = "this is not lua {{{"
bc("a corrupt backup loads as nil", CB.load(1) == nil)
FS[CB.path(1)] = "error('boom')"
bc("a hostile backup cannot run against us", CB.load(1) == nil)

-- ---- throttling: the periodic timer must not thrash the disk ----
FS = {}
RaijinLabDB = { rotations = { A = { slots = { { spell_id = 42 } } } } }
CB._last = 0
bc("first save goes through", CB.save() == true)
local ok3, why3 = CB.save()
bc("an immediate second save is throttled", ok3 == false and why3 == "throttled")
__t = __t + CB.INTERVAL + 1
bc("and allowed again after the interval", CB.save() == true)
"""
    )
    t = lua.eval("cb_fails")
    n = int(lua.eval("#cb_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_empty_rotation_fallback() -> list:
    """LIVE BUG: the character sat idle 166 minutes with active='Raiden Hero' (empty)
    while 'Raiden Reaper' (10 spells) sat right beside it. The executor warned 2671
    times and never acted. An empty rotation is PRESENT but not CAPABLE."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    NL = chr(10)
    lua.execute("RaijinLab = {}")
    for f in ("core/rotation/Engine.lua",):
        src = (ADDON / f).read_text(encoding="utf-8")
        lua.execute("__e = (function()" + NL + src + NL + "end)()")
    lua.execute("RaijinLab.RotationEngine = __e")
    src = (ADDON / "core/rotation/Executor.lua").read_text(encoding="utf-8")
    lua.execute("__x = (function()" + NL + src + NL + "end)()")
    lua.execute("E = __x")
    lua.execute(
        r"""
e_fails = {}
local function ec(name, cond) if not cond then e_fails[#e_fails+1] = name end end
local function slot(id) return { spell_id = id, name = "s" .. tostring(id) } end
RaijinLabDB = {
  active_rotation = "Raiden Hero",
  rotations = {
    ["Raiden Hero"]   = { name = "Raiden Hero",   enabled = true, slots = { slot(0) } },
    ["Raiden Reaper"] = { name = "Raiden Reaper", enabled = true,
                          slots = { slot(1), slot(2), slot(3), slot(4) } },
    ["Default"]       = { name = "Default",       enabled = true, slots = { slot(9) } },
  },
}
E._active_cache = nil; E._active_name = nil; E._resolved_from = nil; E._empty_notice = nil

local rot, name = E.get_active_rotation()
ec("does not run the empty selection", name ~= "Raiden Hero")
ec("falls back to the MOST populated rotation", name == "Raiden Reaper")
ec("and returns a real rotation object", type(rot) == "table")
-- the stored selection is the editor's; the fallback must not rewrite it
ec("stored selection is left alone", RaijinLabDB.active_rotation == "Raiden Hero")

-- repeat calls must be cached, not re-resolved every tick (this runs at ~70Hz)
local rot2, name2 = E.get_active_rotation()
ec("second call is cached", rot2 == rot and name2 == name)

-- once the selection has spells, it is used unchanged
RaijinLabDB.rotations["Raiden Hero"].slots = { slot(11), slot(12) }
E._active_cache = nil; E._resolved_from = nil
local _, name3 = E.get_active_rotation()
ec("a populated selection is honoured", name3 == "Raiden Hero")

-- nothing anywhere has spells: no bogus switch, report the real state
RaijinLabDB = { active_rotation = "A", rotations = {
    A = { name = "A", slots = { slot(0) } },
    B = { name = "B", slots = { slot(0) } } } }
E._active_cache = nil; E._resolved_from = nil; E._empty_notice = nil
local _, name4 = E.get_active_rotation()
ec("no populated alternative -> keeps the selection", name4 == "A")
"""
    )
    t = lua.eval("e_fails")
    n = int(lua.eval("#e_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_compat_questid() -> list:
    """GetQuestLogTitle returns NINE values on this server (stock 3.3.5 returns
    eight and no quest id). Compat's C_QuestLog.IsOnQuest read index 8 - which is
    isDaily, a boolean - and compared it to a numeric quest id, so it could never
    match. QuestLog.lua:128 already read index 9; the shim disagreed with it."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    NL = chr(10)
    lua.execute("RaijinLab = {}")
    # Compat.lua builds a frame at load for its C_Timer polyfill.
    lua.execute("""
function CreateFrame()
  local f = {}
  local mt = { __index = function() return function() end end }
  function f:SetScript() end
  function f:RegisterEvent() end
  return setmetatable(f, mt)
end
function GetTime() return 1000 end
""")
    src = (ADDON / "core/Compat.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function(...)" + NL + src + NL + 'end)("RaijinLab", {})')
    lua.execute(
        r"""
cq_fails = {}
local function cc(name, cond) if not cond then cq_fails[#cq_fails+1] = name end end

-- Nine-value layout: index 8 is isDaily, index 9 is questId.
__q = { { "Kill Bats", 1, nil, nil, false, false, nil, false, 8471 },
        { "Daily Herb", 5, nil, nil, false, false, nil, true,  9002 } }
function GetNumQuestLogEntries() return #__q end
function GetQuestLogTitle(i)
    local e = __q[i]
    if not e then return nil end
    return e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9]
end

cc("finds a quest by its real id", C_QuestLog.IsOnQuest(8471) == true)
cc("finds a DAILY by its real id", C_QuestLog.IsOnQuest(9002) == true)
cc("does not claim a quest we do not have", C_QuestLog.IsOnQuest(1234) == false)
-- the exact bug: isDaily is `false`/`true`, and tonumber of those is nil, so a
-- shim reading index 8 matches nothing at all
cc("never matches on the isDaily column", C_QuestLog.IsOnQuest(0) == false)
cc("nil id is not on quest", C_QuestLog.IsOnQuest(nil) == false)

-- A genuinely STOCK client returns eight values with the id at 8; the shim must
-- still work there rather than trading one broken layout for another.
__q = { { "Stock Quest", 1, nil, nil, false, false, nil, 5555 } }
function GetQuestLogTitle(i)
    local e = __q[i]
    if not e then return nil end
    return e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8]
end
cc("falls back to index 8 on a stock 8-value client", C_QuestLog.IsOnQuest(5555) == true)
"""
    )
    t = lua.eval("cq_fails")
    n = int(lua.eval("#cq_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_position_guard() -> list:
    """The reading the whole bot stands on.

    Observed live: the runtime returned (0.0, 118.8, 0.0) while the camera sat at
    (1723.7, 1623.3, 129.3). The (0,0,0) sentinel missed it because y was
    non-zero, so the bot believed it stood 2000yd from where it was - grounded
    gate off, no movement, a 10698yd search leg. Only something OUTSIDE the field
    can disagree with the field."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    NL = chr(10)
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/API.lua").read_text(encoding="utf-8")
    # only the guard is under test; the file needs globals the harness lacks
    import re
    pat = "MAX_CAM_DIST"
    i0 = src.find(pat)
    m = None
    # Extract just the guard function: the rest of API.lua needs client globals
    # the harness does not provide, and loading it whole would test the harness.
    if i0 >= 0:
        j0 = src.find("function RaijinLab:ObjectPosition", i0)
        lua.execute(src[i0 - len("RaijinLab."):j0])
    # Also extract the TraceLine wrapper (pure string parsing over RLCall) and
    # TraceGround, with RLCall mocked per-case. Loading whole API.lua would test
    # the harness, not the code - same reasoning as the guard slice above.
    t0 = src.find("function RaijinLab:TraceLine")
    # TraceLine now MEMOISES, and its helpers (tl_key, TL_TTL, TL_CAP, the cache
    # tables) are declared just ABOVE the function. Slicing from the function
    # alone left tl_key nil and the whole chunk died on the first call. Walk back
    # to the start of that preamble so the slice is self-contained.
    for anchor in ("RaijinLab._tl_n", "RaijinLab._tl_cache", "local TL_TTL"):
        pre = src.rfind(anchor, 0, t0)
        if pre >= 0:
            t0 = src.rfind(chr(10), 0, pre) + 1
            break
    t1 = src.find("function RaijinLab:TraceGround")
    t2 = src.find("\nend", t1)
    assert t0 > 0 and t1 > t0 and t2 > t1, "TraceLine/TraceGround not found in API.lua"
    # The memoised TraceLine indexes RaijinLab._tl_cache, which API.lua creates
    # in a part of the file this slice deliberately does not load. Provide the
    # table (not the logic) so the slice exercises the real caching code.
    # ...and give it a clock that ADVANCES. TraceLine memoises on a 0.35s TTL;
    # with a frozen (or absent) GetTime every call after the first was a cache
    # hit, so each case below silently re-read the PREVIOUS case's mocked
    # result - 17 assertions about raycast semantics passed or failed on
    # stale data. A monotonic stub keeps the real caching code exercised
    # while making each case a genuine miss.
    lua.execute("RaijinLab._tl_cache = RaijinLab._tl_cache or {}")
    lua.execute("local __clk = 0 GetTime = function() __clk = __clk + 1 return __clk end")
    lua.execute("local function RLCall(...) return __trace_r end\n"
                + src[t0:t2 + 4].replace("RLCall(", "RLCall(", 1))
    lua.execute(
        r"""
pg_fails = {}
local function pc(name, cond) if not cond then pg_fails[#pg_fails+1] = name end end

-- ---- TRI-STATE TRACELINE --------------------------------------------------
-- The runtime used to pack a THROWN raycast as blocked=1 with an unwritten hit
-- point: a broken probe read as a wall at garbage coordinates, and the navigator
-- detoured around nothing. blocked=-1 is the honest third state. These drive the
-- REAL wrapper extracted from API.lua below.

-- An ALL-ZERO camera read is a FAILED read, not a witness at the world origin.
-- 0 is truthy in Lua, so `c.px and c.py` accepted it and the guard then trusted
-- garbage - the same shape as the quest-giver stub answering 0.
__trace_r = "1|10.000|20.000|30.000"
local b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("blocked=1 parses as a real hit", b == true and hx == 10 and st == "blocked")
__trace_r = "0|1.000|1.000|1.000"
b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("blocked=0 is clear", b == false and st == "clear")
__trace_r = "-1|0.000|0.000|0.000"
b, hx, hy, hz, st = RaijinLab:TraceLine(0,0,0, 1,1,1, 0x100111)
pc("a thrown raycast is UNKNOWN, not a wall", b == false and st == "unknown")
pc("...and carries no coordinates", hx == nil and hz == nil)
-- TraceGround must refuse to answer from an unknown trace
__trace_r = "-1|0.000|0.000|0.000"
pc("TraceGround does not invent a floor from a failed ray",
   RaijinLab:TraceGround(0, 0, 50, 3, 30) == nil)
__trace_r = "1|0.000|0.000|42.500"
pc("TraceGround still reads a real floor",
   RaijinLab:TraceGround(0, 0, 50, 3, 30) == 42.5)

RaijinLab.GetCameraData = function() return { px = 0, py = 0, pz = 0 } end
pc("all-zero camera is not a witness (accepts the reading)",
    RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2) == true)
-- ...and it must say WHICH kind of non-witness it was. Both branches used to
-- return a bare `true`, so the all-zero guard was indistinguishable from the
-- "camera too near the origin" guard and deleting it was an EQUIVALENT mutation
-- - undetectable by construction, not by omission.
pc("an all-zero camera reports no_cam_witness",
    (function()
       local _, why = RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2)
       return why == "no_cam_witness"
     end)())
RaijinLab.GetCameraData = function() return { px = 5.0, py = 7.0, pz = 3.0 } end
pc("a near-origin (but non-zero) camera reports cam_unusable",
    (function()
       local _, why = RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2)
       return why == "cam_unusable"
     end)())
RaijinLab.GetCameraData = function() return { px = 1723.7, py = 1623.3, pz = 129.3 } end
pc("a real camera still rejects a far-away position",
    RaijinLab.PlausiblePlayerPos(0.0, 118.8, 0.0) == false)

-- THE CAMERA-DISTANCE GUARD ITSELF, isolated. Undefended until now: the
-- mutation harness showed that making it `return true` passed the whole suite,
-- because every existing case was already refused by the HALF-NULL rule (an axis
-- near zero) before the distance ever mattered. These coordinates are perfectly
-- plausible on their own merits - both axes continental - so ONLY the camera
-- witness can reject them.
pc("a continental position far from the camera is refused",
    RaijinLab.PlausiblePlayerPos(5000.0, 5000.0, 100.0) == false)
pc("...and it says WHY it refused (cam_<dist>)",
    (function()
       local _, why = RaijinLab.PlausiblePlayerPos(5000.0, 5000.0, 100.0)
       return type(why) == "string" and why:find("^cam_") ~= nil
     end)())
pc("a continental position NEAR the camera is still accepted",
    RaijinLab.PlausiblePlayerPos(1725.0, 1625.0, 129.0) == true)


__cam = { px = 1723.7, py = 1623.3, pz = 129.3 }
RaijinLab.GetCameraData = function() return __cam end

-- the exact observed failure
local ok, why = RaijinLab.PlausiblePlayerPos(0.0, 118.8, 0.0)
pc("the observed bad reading is refused", ok == false)
-- The reason is now "half_null": a continental coordinate cannot have an axis
-- near zero, so this reading is refused ON ITS OWN MERITS before any witness is
-- consulted. That is strictly stronger than the camera cross-check and does not
-- depend on the camera being available.
pc("...with a reason naming why", tostring(why):find("half_null", 1, true) ~= nil)

-- a real position beside the camera is accepted
pc("a plausible position is accepted",
   RaijinLab.PlausiblePlayerPos(1722.0, 1620.0, 121.0) == true)
-- and so is one at the far edge of normal camera distance
pc("normal camera offset is not rejected",
   RaijinLab.PlausiblePlayerPos(1723.7 + 40, 1623.3 - 30, 129.3) == true)

-- ABSENCE OF A WITNESS IS NOT EVIDENCE AGAINST THE READING. With no camera the
-- guard must stay silent rather than refusing every position.
RaijinLab.GetCameraData = function() return nil end
-- Use a PLAUSIBLE reading here: (0,118,0) is now refused on its own merits, so
-- it can no longer test the camera rule. The principle under test is unchanged -
-- with no witness the guard must stay silent rather than refuse everything.
pc("no camera -> a plausible reading is not refused",
   RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2) == true)
-- CHANGED DELIBERATELY. "an axis under 30 is impossible" is only true because
-- Azeroth's zones sit far from the origin; as an ABSOLUTE rule it refuses a
-- legitimate position near (0,0). That is exactly where the simulator spawns, so
-- every travel scenario reported need_position and 0yd travelled - the guard was
-- asserting a fact about the world it had no way to know.
-- With no witness there are no grounds to refuse, so we do not.
pc("no camera -> an origin-ish reading is NOT refused (no grounds)",
   RaijinLab.PlausiblePlayerPos(0.0, 118.8, 0.0) == true)
-- ...but a CONTINENTAL camera does settle it: one of us is wrong, and it is not
-- the camera. This is the live failure (runtime said (0,88,87) while the camera
-- sat in Deathknell) and it is still caught.
RaijinLab.GetCameraData = function() return { px = 1845.3, py = 1637.2, pz = 96.9 } end
local okh, whyh = RaijinLab.PlausiblePlayerPos(0.0, 118.8, 0.0)
pc("a continental camera still refuses a half-null reading", okh == false)
pc("...naming the half-null rule", tostring(whyh):find("half_null", 1, true) ~= nil)
RaijinLab.GetCameraData = function() return nil end
RaijinLab.GetCameraData = function() return { } end
pc("a camera with no position -> a plausible reading is not refused",
   RaijinLab.PlausiblePlayerPos(1720.7, 1623.3, 121.2) == true)
"""
    )
    t = lua.eval("pg_fails")
    n = int(lua.eval("#pg_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_menu_options() -> list:
    """Config panels must edit keys the modules ACTUALLY read, and must not
    invent a second flag for something that already has one.

    Both failures look identical from the outside - you change a control and
    nothing happens - and both are invisible to any test that only checks the
    panel builds.
    """
    import re as _re
    menu = (ADDON / "core/Menu.lua").read_text(encoding="utf-8")
    quest_src = ""
    for n in ("Suite", "Goals", "QuestPolicy", "QuestInteract"):
        f = ADDON / ("modules/questing/%s.lua" % n)
        if f.exists():
            quest_src += f.read_text(encoding="utf-8")
    gather_src = (ADDON / "modules/gathering/Gatherer.lua").read_text(encoding="utf-8")
    fails = []

    for m in _re.finditer(r'self:Options\(\w+, "(\w+)"', menu):
        store = m.group(1)
        tail = menu[m.end(): m.end() + 2000]
        # "vision" is edited by the Debug tab's world-rendering toggles and is
        # consumed by core/Vision.lua rather than a module file, so it needs its
        # own source here - otherwise the guard reports a real, wired panel as
        # editing an unknown store.
        vision_src = (ADDON / "core/Vision.lua").read_text(encoding="utf-8")
        src = {"quest": quest_src, "gather": gather_src,
               "vision": vision_src}.get(store)
        if src is None:
            fails.append("panel edits unknown store '%s'" % store)
            continue
        for key in _re.findall(r'key = "(\w+)"', tail):
            if not _re.search(r'\b%s\b' % key, src):
                fails.append("%s panel edits '%s' but no module reads it" % (store, key))

    for prof in ("herbalism", "mining", "woodcutting", "fishing"):
        if prof not in gather_src:
            fails.append("profession toggle '%s' is unknown to the Gatherer" % prof)

    fm = _re.search(r'\{ "fishing",[^}]*?(true|false) \}', menu)
    if fm and fm.group(1) != "false":
        fails.append("the fishing checkbox defaults ON - it is opt-in for a reason")

    # NO SHADOW ENABLE FLAGS. RaijinLabDB.modules[key] is the only flag that
    # decides whether a module runs; a page-local `<mod>.enabled` is shadow state
    # written in two places and free to disagree with the switch that matters.
    for mod in ("quest", "gather", "grind", "combat", "rotation"):
        if _re.search(r'RaijinLabDB\.%s\.enabled\s*=' % mod, menu):
            fails.append("menu writes a shadow flag RaijinLabDB.%s.enabled - "
                         "modules.%s is the only real one" % (mod, mod))

    # Nor may a refresh READ a shadow flag: the control would then show unchecked
    # while the module is actually running, which is the same desync from the
    # other direction.
    for mod in ("quest", "gather", "grind", "combat", "rotation"):
        if _re.search(r'RaijinLabDB\.%s\.enabled\s+and' % mod, menu):
            fails.append("menu READS a shadow flag RaijinLabDB.%s.enabled" % mod)

    # A ROW THAT CANNOT BE TOGGLED MUST NOT OFFER A TOGGLE. modules.nav is read
    # nowhere outside the menu, so its button did nothing while the blurb said
    # "always on" - a control lying about being a control.
    core = "".join((ADDON / ("core/%s.lua" % n)).read_text(encoding="utf-8")
                   for n in ("Nav", "Navigator", "Pathfinder")
                   if (ADDON / ("core/%s.lua" % n)).exists())
    if _re.search(r'modules\.nav\b', core):
        fails.append("modules.nav is now read by a module - the Home row should "
                     "become a real toggle again")
    return fails


def test_vision() -> list:
    """Layered world rendering. The thing that must not happen is a visualiser
    that costs frames - one that does gets turned off and is then worth nothing -
    so the budget is the property under test, not the pixels."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    # Seed EVERY group. Only main()'s runtime was seeded, so any group
    # using math.random varied per run - SEARCH failed intermittently and
    # a flaky red trains you to ignore the suite.
    lua.execute("math.randomseed(42)")
    NL = chr(10)
    lua.execute("RaijinLab = {}")
    lua.execute("RaijinLabDB = {}")
    src = (ADDON / "core/Vision.lua").read_text(encoding="utf-8")
    lua.execute("__m = (function(...)" + NL + src + NL + 'end)("RaijinLab", {})')
    lua.execute(
        r"""
v_fails = {}
local function vc(name, cond) if not cond then v_fails[#v_fails+1] = name end end
local V = RaijinLab.Vision

__lines = 0
RaijinLab.drawing = {
    Line = function(_s) __lines = __lines + 1 end,
    SetColorRaw = function() end,
    SetWidth = function() end,
}
__cbs = {}
__init_calls = 0

-- ---- intent must be visible even with NO route ----
-- draw_path returns immediately unless Navigator._active exists, so during
-- planning, parking or any gap between goals the screen showed NOTHING - and
-- those are exactly the moments the user needs the answer to "where is it
-- going". Intent survives the absence of a route.
do
    RaijinLab.ObjectPosition = function(_, tok)
        if tok == "player" then return 0, 0, 0 end
    end
    RaijinLab.Navigator = { _active = nil, _want_goal = { x = 200, y = 150, z = 5 } }
    RaijinLab.QuestSuite = nil

    __lines = 0
    V.draw_path(RaijinLab.drawing)
    vc("no route -> the path layer draws nothing (unchanged)", __lines == 0)

    __lines = 0
    V.draw_intent(RaijinLab.drawing, 0, 0, 0)
    vc("but INTENT is drawn with no route at all", __lines > 0)

    -- and it falls back to the suite's committed search leg
    RaijinLab.Navigator = { _active = nil }
    RaijinLab.QuestSuite = { _search = { ["obj:X"] = { tx = 50, ty = 60 } } }
    __lines = 0
    V.draw_intent(RaijinLab.drawing, 0, 0, 0)
    vc("a committed search leg is shown too", __lines > 0)

    -- nothing intended -> nothing drawn (never invent a destination on screen)
    RaijinLab.QuestSuite = { _search = {} }
    __lines = 0
    V.draw_intent(RaijinLab.drawing, 0, 0, 0)
    vc("no goal -> nothing drawn, never a fabricated one", __lines == 0)

    vc("intent is ON by default", V.DEFAULT_ON.intent == true)
    RaijinLab.Navigator, RaijinLab.QuestSuite = nil, nil
end
function RaijinLab:AddDrawingCallback(k, fn) __cbs[k] = fn end
-- Registering a callback does NOT start the draw loop; InitDrawing creates the
-- canvas and the ticker. Without it every layer is enabled and draws nothing,
-- which reads as "0 segments/frame" with the layers apparently on.
function RaijinLab:InitDrawing() __init_calls = __init_calls + 1 end
RaijinLab.ObjectPosition = function(_s, tok) return 100, 100, 10 end

-- a navgrid that says WALK everywhere, so the grid layer has plenty to draw
RaijinLab.NavGrid = {
    map_name = function() return "T" end,
    tile_of = function() return 0, 0 end,
    load = function() return { res = 4 } end,
    -- Hazard codes, not WALK. draw_grid deliberately renders only steep/wall/
    -- water/structure (2..5) - drawing the walk carpet was the bulk of the old
    -- segment cost for information the player already has by looking at the
    -- ground. A mock returning 1 (WALK) therefore draws nothing, and the test
    -- asserting "draws something" was measuring the old carpet behaviour.
    at = function(x, y) return 3, 10 end,   -- BLOCKED: a hazard worth drawing
}

-- ---- layers default ON and are individually toggleable ----
--
-- CHANGED DELIBERATELY (user request): every layer now ships enabled. Rendering
-- is the only way to see what the bot believes, and shipping it dark meant the
-- one tool for diagnosing "it looks confused" was itself off, silently.
--
-- The important half of the old contract is KEPT and strengthened below: an
-- explicit false must survive, because a default that re-asserts itself over a
-- user's choice makes the off switch look broken. That is why cfg() defaults
-- only a nil, never a false.
vc("every layer is on by default", V.enabled("grid") == true and V.enabled("path") == true)
vc("any() is true by default", V.any() == true)
V.set("grid", false)
vc("a layer can be turned off", V.enabled("grid") == false)
vc("...without turning off the others", V.enabled("path") == true)
-- the crucial one: re-reading config must NOT resurrect the disabled layer
vc("an explicit off survives a re-read", V.enabled("grid") == false)
V.set("grid", true)
vc("and on again", V.enabled("grid") == true)

-- ---- THE BUDGET. This runs on the render path. ----
V.set("grid", true)
__lines = 0
V.render()
vc("the grid layer draws something", __lines > 0)
vc("and NEVER exceeds the segment cap", V._segments <= V.MAX_SEGMENTS)
-- The cap is the invariant; the RADIUS/STRIDE tuning is not. Those were since
-- reduced (36yd, stride 3) for cost, so the default grid no longer reaches the
-- cap and this assertion was silently measuring the old tuning. Force a dense
-- grid so the cap itself is what gets tested.
local __r, __st = V.GRID_RADIUS, V.GRID_STRIDE
V.GRID_RADIUS, V.GRID_STRIDE = 120, 1
V._segments = 0; __lines = 0
V.render()
vc("the cap actually bites on a dense grid", V._segments >= V.MAX_SEGMENTS - 2)
vc("...and never exceeds it", V._segments <= V.MAX_SEGMENTS)
V.GRID_RADIUS, V.GRID_STRIDE = __r, __st

-- every layer at once must still respect ONE shared budget, not one each
for _, l in ipairs(V.LAYERS) do V.set(l, true) end
__lines = 0
V.render()
vc("all layers share a single budget", V._segments <= V.MAX_SEGMENTS)

-- ---- rendering must never throw: it is on the frame path ----
-- EVERY layer must be isolated, not just the one that happened to be tested.
-- Breaking only the grid layer passes even when the others are unguarded.
RaijinLab.NavGrid.at = function() error("boom") end
vc("a broken grid layer does not propagate", pcall(V.render) == true)
RaijinLab.Navigator = { _active = setmetatable({}, {
    __index = function() error("boom") end }) }
vc("a broken path layer does not propagate", pcall(V.render) == true)
RaijinLab.QuestSuite = { _fields = setmetatable({}, {
    __index = function() error("boom") end }) }
vc("a broken search layer does not propagate", pcall(V.render) == true)
RaijinLab.Navigator = nil; RaijinLab.QuestSuite = nil
RaijinLab.NavGrid = nil
vc("a missing navgrid does not propagate", pcall(V.render) == true)
RaijinLab.drawing = nil
vc("no draw layer at all is survivable", pcall(V.render) == true)

-- ---- the controller layer: the loop must be watchable ----
-- Every value it draws has been wrong at some point (a 155-degree stale heading,
-- a cone that never opened, a turn command with no rotation behind it), and each
-- is obvious as a picture and nearly invisible as text.
RaijinLab.drawing = { Line = function() __lines = __lines + 1 end,
                      SetColorRaw = function() end, SetWidth = function() end }
for _, l in ipairs(V.LAYERS) do V.set(l, false) end
V.set("controller", true)
RaijinLab.Navigator = { _facing_real = 1.2, _target_h = 2.0,
                        _last_turn_cmd = 0.15,
                        cfg = function() return { move_cone = 1.6 } end }
__lines = 0
V.render()
-- Two rays now (measured heading + target heading), not four: the old version
-- drew a cone whose extra segments carried no information the two rays do not.
vc("the controller layer draws the loop", __lines >= 2)
vc("...within budget", V._segments <= V.MAX_SEGMENTS)
-- With no MEASURED heading the facing ray must not be drawn - that would be a
-- guess. The TARGET heading is still honestly known (it is computed, not
-- measured), and drawing it is exactly what tells the user where the bot intends
-- to go while its facing sensor is dead - the most valuable moment to see it.
RaijinLab.Navigator._facing_real = nil
RaijinLab.Navigator._cam_now = nil
__lines = 0
V.render()
vc("no measured heading -> the facing ray is not guessed", __lines <= 1)
vc("...but the intended heading is still shown", __lines >= 1)
RaijinLab.Navigator = nil
V.set("controller", false)

-- ---- the callback is only armed while something is on ----
RaijinLab.drawing = { Line = function() end, SetColorRaw = function() end,
                      SetWidth = function() end }
for _, l in ipairs(V.LAYERS) do V.set(l, false) end
vc("refresh registers a callback either way", __cbs["vision"] ~= nil)
__init_calls = 0
V.set("grid", true)
vc("turning a layer on STARTS the draw loop", __init_calls > 0)
V.set("grid", false)
__lines = 0
__cbs["vision"]()
vc("with every layer off it draws nothing", __lines == 0)
"""
    )
    t = lua.eval("v_fails")
    n = int(lua.eval("#v_fails"))
    return [t[i] for i in range(1, n + 1)]


def test_navgrid() -> list:
    """The REAL NavGrid decoder AND indexer, through NG.at().

    Everything else in this suite MOCKS NavGrid, so the module that decides where
    the ground is had no coverage: three deliberate corruptions of the packed
    decoder (off-by-one cell index, dropped height bias, swapped height byte
    order) passed the whole suite. Any one of them silently mislocates every cell
    in the world.

    A first version of this test reimplemented the unpacking in a local helper
    and therefore still missed all three - it was testing itself. The tile is fed
    through the real loader (ReadFile stubbed to serve it) and read through the
    real NG.at, so the shipped indexing arithmetic is what is under test.

    Cells are packed as STRINGS: a 1yd tile is 534x534 = 285,156 cells, which as
    Lua arrays measured ~25 MB per tile live and took Lua to 290 MB on a 32-bit
    client that had already died once at 140 MB.
    """
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("RaijinLab = {}")
    # Load Know FIRST: without it every predicate degrades to a bare boolean and
    # the REASON is never observable - which made an assertion about "too_tight"
    # silently vacuous.
    lua.execute("RaijinLab.Know = (function()" + chr(10)
                + (ADDON / "core/Know.lua").read_text(encoding="utf-8") + chr(10) + "end)()")
    lua.execute((ADDON / "core/NavGrid.lua").read_text(encoding="utf-8"))
    fails: list = []
    def ck(name, cond):
        if not cond:
            fails.append(name)

    # 3x3 tile, codes row-major 1 0 2 3 1 5 4 1 1, per-cell height deltas.
    lua.execute("""
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 3, res = 1,
            x0 = 0, y0 = 0, runs = "b1a1c1d1b1f1e1b2",
            zd = "4 4 -4 8 0 0 -8 4 4" }]]
        RaijinLab.ReadFile = function(_, path) return __TILE end
        RaijinLab.GetWoWDirectory = function() return "C:/x" end
        RaijinLab.NavGrid.map_name = function() return "M" end
        RaijinLab.NavGrid.tile_of = function() return 0, 0 end
    """)
    expect = [1, 0, 2, 3, 1, 5, 4, 1, 1]
    acc, want_h = 0, []
    for d in (4, 4, -4, 8, 0, 0, -8, 4, 4):
        acc += d
        want_h.append(acc / 4.0)

    for i, want in enumerate(expect):
        gx, gy = i % 3, i // 3
        got = lua.eval("(function() local c = RaijinLab.NavGrid.at(%d.5, %d.5, 'M') "
                       "return c end)()" % (gx, gy))
        ck("cell (%d,%d) reads code %d through NG.at" % (gx, gy, want),
           got is not None and int(got) == want)
        gh = lua.eval("(function() local _, h = RaijinLab.NavGrid.at(%d.5, %d.5, 'M') "
                      "return h end)()" % (gx, gy))
        ck("cell (%d,%d) reads height %.2f through NG.at" % (gx, gy, want_h[i]),
           gh is not None and abs(float(gh) - want_h[i]) < 0.001)

    ck("codes are packed as a string, not an array",
       lua.eval('(function() local t = RaijinLab.NavGrid.load("M", 0, 0) '
                'return type(t.codes) == "string" end)()'))
    ck("one byte per cell",
       int(lua.eval('(function() local t = RaijinLab.NavGrid.load("M", 0, 0) '
                    'return #t.codes end)()')) == 9)
    ck("two bytes per cell of height",
       int(lua.eval('(function() local t = RaijinLab.NavGrid.load("M", 0, 0) '
                    'return #t.heights end)()')) == 18)

    # below-sea-level ground must survive the packing - the bias exists for it
    lua.execute("""
        RaijinLab.NavGrid.invalidate_map()
        RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
        RaijinLab.NavGrid._misses = {}
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 1, res = 1,
            x0 = 0, y0 = 0, runs = "b1", zd = "-400" }]]
    """)
    deep = lua.eval("(function() local _, h = RaijinLab.NavGrid.at(0.5, 0.5, 'M') return h end)()")
    ck("a below-sea-level height round-trips",
       deep is not None and abs(float(deep) + 100.0) < 0.001)

    # a truncated tile must be REFUSED, not half-used
    lua.execute("""
        RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
        RaijinLab.NavGrid._misses = {}
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 3, res = 1,
            x0 = 0, y0 = 0, runs = "b4", zd = "4 4 4 4" }]]
    """)
    ck("a truncated tile is refused",
       lua.eval("RaijinLab.NavGrid.at(0.5, 0.5, 'M') == nil"))

    # ---- THE INDEXED FORMAT (cd + zq): the one that actually ships ----
    # Everything above exercises the legacy runs/zd path. The shipped tiles are
    # fixed-width now, because rebuilding 1,138,489 per-cell heights from deltas
    # at load cost 387ms and put the client under 1 fps; that work moved into the
    # generator and the addon just indexes bytes. Covering only the old path
    # would leave the code that actually runs untested.
    lua.execute("""
        RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
        RaijinLab.NavGrid._misses = {}
        -- 2x2: walk, tight, blocked, water. zstep 0.5 from zmin 100.
        --   cell 1 q=0    -> 100.0
        --   cell 2 q=2    -> 101.0
        --   cell 3 q=32   -> 116.0   (high digit = 1)
        --   cell 4 q=1023 -> 611.5   (max)
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 2, res = 1,
            x0 = 0, y0 = 0, cd = "bgde",
            zmin = 100.0, zstep = 0.5,
            zq = "0002" .. "10" .. "VV" }]]
    """)
    ck("an indexed tile decodes with no runs/zd at all",
       lua.eval('(function() local t = RaijinLab.NavGrid.load("M", 0, 0) '
                'return t ~= nil and t.codes == "bgde" end)()'))
    for idx, (gx, gy, want_code, want_h) in enumerate((
            (0, 0, 1, 100.0), (1, 0, 6, 101.0), (0, 1, 3, 116.0), (1, 1, 4, 611.5))):
        got = lua.eval("(function() local c = RaijinLab.NavGrid.at(%d.5, %d.5, 'M') return c end)()" % (gx, gy))
        ck("indexed cell (%d,%d) code is %d" % (gx, gy, want_code),
           got is not None and int(got) == want_code)
        gh = lua.eval("(function() local _, h = RaijinLab.NavGrid.at(%d.5, %d.5, 'M') return h end)()" % (gx, gy))
        # isinstance guard, not float(): a nil here means the cell did not
        # resolve, and float(None) raises a TypeError that KILLS the whole suite
        # instead of reporting one failed check. A test that dies takes every
        # later group with it.
        ck("indexed cell (%d,%d) height is %.1f" % (gx, gy, want_h),
           isinstance(gh, (int, float)) and abs(float(gh) - want_h) < 0.001)
    ck("an indexed tile with a short cd is refused",
       lua.eval("""(function()
            RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
            RaijinLab.NavGrid._misses = {}
            __TILE = [[return { map = "M", tx = 0, ty = 0, n = 2, res = 1,
                x0 = 0, y0 = 0, cd = "bg", zmin = 0, zstep = 1,
                zq = "00000000" }]]
            return RaijinLab.NavGrid.at(0.5, 0.5, 'M') == nil
        end)()"""))
    ck("an indexed tile with a short zq is refused",
       lua.eval("""(function()
            RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
            RaijinLab.NavGrid._misses = {}
            __TILE = [[return { map = "M", tx = 0, ty = 0, n = 2, res = 1,
                x0 = 0, y0 = 0, cd = "bgde", zmin = 0, zstep = 1, zq = "00" }]]
            return RaijinLab.NavGrid.at(0.5, 0.5, 'M') == nil
        end)()"""))
    ck("an indexed tile missing its height scale is refused",
       lua.eval("""(function()
            RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
            RaijinLab.NavGrid._misses = {}
            __TILE = [[return { map = "M", tx = 0, ty = 0, n = 2, res = 1,
                x0 = 0, y0 = 0, cd = "bgde", zq = "00000000" }]]
            return RaijinLab.NavGrid.at(0.5, 0.5, 'M') == nil
        end)()"""))

    # ---- TIGHT: floor a body does not fit on ----
    # The generator erodes walkable ground by the character's collision radius.
    # A cell whose CENTRE is clear is not somewhere a body can stand, and routing
    # through the band is what scrapes every doorway edge and crate corner.
    lua.execute("""
        RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
        RaijinLab.NavGrid._misses = {}
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 2, res = 1,
            x0 = 0, y0 = 0, runs = "b1g1d1e1", zd = "4 0 0 0" }]]
    """)
    ck("the tight code decodes (letter g)",
       int(lua.eval("(function() local c = RaijinLab.NavGrid.at(1.5, 0.5, 'M') return c end)()")) == 6)
    ck("TIGHT is a definite NO, never unknown",
       lua.eval("(function() local K = RaijinLab.Know "
                "local k = RaijinLab.NavGrid.walkable(1.5, 0.5, 'M') "
                "return K.is_no(k) == true end)()"))
    ck("plain walk is still yes",
       lua.eval("(function() local K = RaijinLab.Know "
                "local k = RaijinLab.NavGrid.walkable(0.5, 0.5, 'M') "
                "return K.is_yes(k) == true end)()"))
    # walkable_z is the one the PATHFINDER calls - covering only walkable() left
    # the floor-aware predicate free to accept TIGHT, and a mutation proved it.
    # Refusal alone is not enough to pin: with the TIGHT branch deleted the cell
    # still falls through to the final "blocked" refusal, so a mutation removing
    # it changes nothing observable. The REASON is the real difference, and it is
    # what --diag shows a human - "too_tight" says the body does not fit, which
    # is a different fact from "there is a wall here".
    ck("TIGHT is refused by the floor-aware predicate too",
       lua.eval("(function() local K = RaijinLab.Know "
                "local k = RaijinLab.NavGrid.walkable_z(1.5, 0.5, 0, 'M') "
                "return K.is_no(k) and k.why == 'too_tight' end)()"))
    ck("walkable_z still passes plain walk",
       lua.eval("(function() local K = RaijinLab.Know "
                "local k = RaijinLab.NavGrid.walkable_z(0.5, 0.5, 1, 'M') "
                "return K.is_yes(k) == true end)()"))

    # ---- THE RAW FORMAT (RLNAV2): what the client actually loads ----
    # A tile is data, not code. Parsing it as Lua cost ~40ms per tile; computed
    # offsets and a binary-searched layer block bring that to 0.5ms. Block
    # lengths live in the header precisely so nothing scans the payload - an
    # earlier version searched for each block and measured SLOWER than the Lua
    # form it replaced.
    def raw_tile(cd, zq, lay, n=2, zmin=100.0, zstep=0.5):
        head = ("RLNAV2 map=M tx=0 ty=0 n=%d res=1 x0=0 y0=0 zmin=%.4f "
                "zstep=%.8f cdlen=%d zqlen=%d laylen=%d"
                % (n, zmin, zstep, len(cd), len(zq), len(lay)))
        return chr(10).join((head, cd, zq, lay)) + chr(10)

    # cells: walk/tight/blocked/water; q = 0, 2, 32, 1023
    body = raw_tile("bgde", "0002" + "10" + "VV", "")
    lua.execute("__RAWT = [==[" + body + "]==]")
    ck("a raw tile parses from its header lengths",
       lua.eval('(function() local t = RaijinLab.NavGrid.parse_raw(__RAWT) '
                'return t ~= nil and t.cd == "bgde" and t.n == 2 end)()'))
    ck("raw heights use the tile's own zmin/zstep",
       lua.eval('(function() local t = RaijinLab.NavGrid.decode('
                'RaijinLab.NavGrid.parse_raw(__RAWT)) '
                'if not t then return false end '
                'local B = RaijinLab.NavGrid._b32 '
                'local a, b = t.zq:byte(3, 4) '
                'return math.abs((t.zmin + (B(a)*32+B(b))*t.zstep) - 101.0) < 0.001 end)()'))
    ck("a raw tile whose lengths do not match its payload is refused",
       lua.eval('(function() local bad = "RLNAV2 n=2 cdlen=99 zqlen=8 laylen=0" '
                '.. string.char(10) .. "bgde" .. string.char(10) .. "00000000" '
                '.. string.char(10) .. string.char(10) '
                'local t = RaijinLab.NavGrid.parse_raw(bad) '
                'return t == nil or RaijinLab.NavGrid.decode(t) == nil end)()'))
    # The payload must be WELL-FORMED for this to mean anything: a body with no
    # newline is rejected by the header scan whether or not the magic is checked,
    # so it proved nothing. This one would parse perfectly if the magic were not
    # enforced - which is the point of enforcing it.
    ck("a well-formed file without the RLNAV2 magic is refused",
       lua.eval('RaijinLab.NavGrid.parse_raw("NOPE n=2 cdlen=4 zqlen=8 laylen=0"'
                ' .. string.char(10) .. "bbbb" .. string.char(10) .. "00000000"'
                ' .. string.char(10) .. string.char(10)) == nil'))
    # A layer block that is not a whole number of 7-char records is corrupt.
    # Without the length check it would be read as records anyway and every cell
    # index would be garbage.
    ck("a layer block of the wrong width is refused as records",
       lua.eval('(function() local b = "RLNAV2 n=2 zmin=0 zstep=1 cdlen=4 zqlen=8 laylen=5"'
                ' .. string.char(10) .. "bbbb" .. string.char(10) .. "00000000"'
                ' .. string.char(10) .. "00002" .. string.char(10)'
                ' local t = RaijinLab.NavGrid.decode(RaijinLab.NavGrid.parse_raw(b))'
                ' return t ~= nil and t.lrec == nil end)()'))

    # ---- binary-searched upper floors ----
    # 7 chars per record: 5 of cell index, 2 of height. Sorted by cell, so this
    # is ~14 probes with no allocation and nothing done at load.
    def rec(cell, q):
        A = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
        return (A[(cell >> 20) & 31] + A[(cell >> 15) & 31] + A[(cell >> 10) & 31]
                + A[(cell >> 5) & 31] + A[cell & 31] + A[(q >> 5) & 31] + A[q & 31])
    # cell 2 has two floors (q=10, q=40); cell 4 has one (q=100)
    lay = rec(2, 10) + rec(2, 40) + rec(4, 100)
    lua.execute("__RAWL = [==[" + raw_tile("bbbb", "00000000", lay) + "]==]")
    lua.execute("__TL = RaijinLab.NavGrid.decode(RaijinLab.NavGrid.parse_raw(__RAWL))")
    ck("layer records are kept as a searchable string, not a table",
       lua.eval('__TL ~= nil and __TL.lrec ~= nil and __TL.lnum == 3'))
    ck("binary search finds BOTH floors of a cell",
       lua.eval('#(RaijinLab.NavGrid._ups(__TL, 2) or {}) == 2'))
    ck("the floors come back on the tile's height scale",
       lua.eval('(function() local u = RaijinLab.NavGrid._ups(__TL, 2) '
                'return u and math.abs(u[1] - (100.0 + 10*0.5)) < 0.001 '
                'and math.abs(u[2] - (100.0 + 40*0.5)) < 0.001 end)()'))
    ck("a cell with one floor returns exactly one",
       lua.eval('#(RaijinLab.NavGrid._ups(__TL, 4) or {}) == 1'))
    ck("a cell with no upper floor returns nothing",
       lua.eval('RaijinLab.NavGrid._ups(__TL, 3) == nil'))
    ck("a cell below every record returns nothing",
       lua.eval('RaijinLab.NavGrid._ups(__TL, 0) == nil'))
    ck("a cell above every record returns nothing",
       lua.eval('RaijinLab.NavGrid._ups(__TL, 99) == nil'))

    # ---- upper floors ----
    # Keeping only the lowest surface collapsed a multi-storey building to its
    # ground plan, so a character upstairs was told about the floor below it.
    lua.execute("""
        RaijinLab.NavGrid._cache, RaijinLab.NavGrid._lru = {}, {}
        RaijinLab.NavGrid._misses = {}
        __TILE = [[return { map = "M", tx = 0, ty = 0, n = 1, res = 1,
            x0 = 0, y0 = 0, runs = "b1", zd = "40", lay = "1:80" }]]
    """)
    ck("the base layer is the lower floor",
       abs(float(lua.eval("(function() local _, h = RaijinLab.NavGrid.at(0.5, 0.5, 'M') return h end)()")) - 10.0) < 0.001)
    ck("standing low selects the lower floor",
       abs(float(lua.eval("(function() local _, h = RaijinLab.NavGrid.at_z(0.5, 0.5, 10.0, 'M') return h end)()")) - 10.0) < 0.001)
    ck("standing high selects the UPPER floor",
       abs(float(lua.eval("(function() local _, h = RaijinLab.NavGrid.at_z(0.5, 0.5, 20.0, 'M') return h end)()")) - 20.0) < 0.001)
    ck("an upper floor is walkable ground",
       int(lua.eval("(function() local c = RaijinLab.NavGrid.at_z(0.5, 0.5, 20.0, 'M') return c end)()")) == 1)
    ck("surfaces() lists every floor",
       int(lua.eval("#RaijinLab.NavGrid.surfaces(0.5, 0.5, 'M')")) == 2)
    ck("without a height the base layer is returned",
       abs(float(lua.eval("(function() local _, h = RaijinLab.NavGrid.at_z(0.5, 0.5, nil, 'M') return h end)()")) - 10.0) < 0.001)
    return fails


def test_ipc() -> list:
    """The live control channel's executor. This is what turns "run this command
    and screenshot it" into something greppable, so its output contract matters
    as much as its safety: a chunk that errors must SAY so rather than returning
    an empty string that reads like success."""
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("RaijinLab = {}")
    lua.execute("function CreateFrame() return setmetatable({}, "
                "{__index=function() return function() end end}) end")
    src = (ADDON / "core/Ipc.lua").read_text(encoding="utf-8")
    lua.execute("Ipc = (function()" + chr(10) + src + chr(10) + "end)()")
    lua.execute(r"""
ipc_fails = {}
local function ic(name, cond) if not cond then ipc_fails[#ipc_fails+1] = name end end

-- a bare EXPRESSION is the common case and must not need a return
ic("expression is evaluated", Ipc.run("1 + 1") == "2")
ic("string expression comes back as itself", Ipc.run([['hello']]) == "hello")

-- statements still work
ic("statement chunk runs", string.find(Ipc.run("local x = 5 print(x * 2)"), "10") ~= nil)

-- print is CAPTURED: a snippet that prints is far more natural to write than one
-- that has to build a return value, and chat-frame output would be invisible here
ic("print output is captured", Ipc.run([[print("captured")]]) == "captured")
ic("multiple prints keep order",
   Ipc.run([[print("a") print("b")]]) == "a" .. string.char(10) .. "b")

-- errors must be LOUD. An empty reply reads exactly like a successful no-op.
ic("runtime error is reported", string.find(Ipc.run("error('boom')"), "ERROR") ~= nil)
ic("compile error is reported", string.find(Ipc.run("if if"), "COMPILE ERROR") ~= nil)
ic("empty chunk is refused", string.find(Ipc.run(""), "ERROR") ~= nil)
ic("non-string chunk is refused", string.find(Ipc.run(nil), "ERROR") ~= nil)

-- tables must render as CONTENT. tostring() gives an address, which is the
-- useless answer that made every GUID dump unreadable.
local d = Ipc.run("{1, 2, 3}")
ic("array renders as content", d == "{1, 2, 3}")
ic("map renders keys", string.find(Ipc.run("{a = 1}"), "a=1") ~= nil)
ic("nested table renders", string.find(Ipc.run("{x = {y = 2}}"), "y=2") ~= nil)
ic("cycles do not hang", string.find(Ipc.dump((function() local t = {} t.me = t return t end)()), "cycle") ~= nil)

-- multiple return values are all reported
ic("multi-return is preserved", string.find(Ipc.run("return 1, 2"), "2") ~= nil)

-- a chunk that errors must not leave print() replaced for the rest of the session
local before = print
Ipc.run("error('x')")
ic("print is restored after an error", print == before)
""")
    return list(lua.eval("ipc_fails").values())


def test_object_esp() -> list:
    """The in-world id labels. Both decision functions are PURE, so there is no
    reason for them to be untested: label() decides what you can read off the
    object, pick() decides which objects get one at all.

    The cap is the part that actually matters. Truncating before sorting would
    silently drop the NEAR objects - the only ones anybody is looking at - while
    still showing a screen full of labels, so it would look like it worked.
    """
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("RaijinLab = { enums = { GameObjectTypesInverted = "
                "{ [0]='GAMEOBJECT_TYPE_DOOR', [3]='GAMEOBJECT_TYPE_CHEST', "
                "[5]='GAMEOBJECT_TYPE_GENERIC' } } }")
    src = (ADDON / "modules/ObjectESP.lua").read_text(encoding="utf-8")
    lua.execute("ESP = (function()" + chr(10) + src + chr(10) + "end)()")
    lua.execute(r"""
esp_fails = {}
local function ec(name, cond) if not cond then esp_fails[#esp_fails+1] = name end end

-- the id is ALWAYS present: it is the whole point
ec("label leads with the entry id", string.find(ESP.label(90641, 3, 0x08), "^90641") ~= nil)
ec("label names the type", string.find(ESP.label(90641, 3, 0x08), "CHEST") ~= nil)
ec("label shows the flag word", string.find(ESP.label(90641, 3, 0x08), "0x08") ~= nil)
ec("unflagged object shows no flag word", string.find(ESP.label(1618, 3, 0), "0x") == nil)
ec("unknown type degrades to a number, never a guess",
   string.find(ESP.label(7, 42, 0), "t42") ~= nil)

-- A GUID is not a name. Showing it would push the id off the label while adding
-- nothing - and objects with no real name are exactly the ones being identified.
ec("a GUID-shaped name is not appended",
   string.find(ESP.label(90641, 3, 0, "<0xF110016211000068>"), "0xF11") == nil)
ec("a real name is appended", string.find(ESP.label(1618, 3, 0, "Mailbox"), "Mailbox") ~= nil)

-- pick(): nearest first, capped AFTER sorting
-- Built FARTHEST-FIRST on purpose. With the list already in distance order,
-- removing the sort changes nothing and the cap still keeps the nearest - the
-- test passes while proving nothing. This ordering is what makes it bite.
local list = {}
for i = 1, 40 do list[i] = { Id = i, X = (41 - i) * 10, Y = 0, Z = 0 } end
local got = ESP.pick(list, 0, 0, 0, 1000, 5)
ec("pick caps the label count", #got == 5)
ec("pick keeps the NEAREST, not the first found", got[1].o.Id == 40 and got[5].o.Id == 36)
ec("pick sorts by distance", got[1].d < got[5].d)

local near = ESP.pick(list, 0, 0, 0, 55, 70)
ec("pick honours the range limit", #near == 5)
-- ---- A WHOLE DRAW PASS, AGAINST A STUB CANVAS ----
--
-- The label colour shipped invisible: Drawing.SetColor SCALES its arguments
-- (RGB * 1/256, alpha * 1/100), so the 0-1 floats passed to it became alpha 0.01
-- and a near-black colour. Every label was drawn, every frame, and none could be
-- seen - with no error anywhere. A source guard catches the specific call, but
-- only running the draw pass and CHECKING WHAT COLOUR CAME OUT catches the class.
do
    local drawn, colour = {}, nil
    -- These stubs use the REAL semantics from Drawing.lua, including the scaling,
    -- so a caller that gets the convention wrong produces an invisible colour
    -- here exactly as it does in the client.
    RaijinLab.drawing = {
        SetColor = function(_, r, g, b, a)
            colour = { r = r * 0.00390625, g = g * 0.00390625,
                       b = b * 0.00390625, a = a and (a * 0.01) or 1 }
        end,
        SetColorRaw = function(_, r, g, b, a)
            colour = { r = r, g = g, b = b, a = a }
        end,
        Text = function(_, text, x, y, z)
            drawn[#drawn + 1] = { text = text, x = x, y = y, z = z,
                                  a = colour and colour.a or nil }
        end,
    }
    RaijinLab.ObjectPosition = function(_, who)
        if who == "player" then return 0, 0, 0 end
        return 10, 0, 0
    end
    RaijinLab.RuntimeCall = function(_, cmd) if cmd == "GameObjectBytes1" then return 3 * 256 + 1 end end
    RaijinLab.om = { object_list = { gameobjects = {
        { Guid = "0xA", Id = 90641, Name = "<0xF11>", X = 5, Y = 0, Z = 0,
          DynamicFlags = { value = 0x08 } },
        { Guid = "0xB", Id = 1618, Name = "<0xF12>", X = 9, Y = 0, Z = 0,
          DynamicFlags = { value = 0 } },
    } } }

    ESP.enabled = true
    ESP.draw()
    ec("draw emits a label per object in range", #drawn == 2)
    ec("draw puts the entry id on the label",
       drawn[1] and string.find(drawn[1].text, "90641") ~= nil)
    ec("draw shows the flag word on a flagged object",
       drawn[1] and string.find(drawn[1].text, "0x08") ~= nil)
    -- THE ONE THAT WOULD HAVE CAUGHT THE SHIPPED BUG
    for i = 1, #drawn do
        ec("label " .. i .. " is actually VISIBLE (alpha > 0.5)",
           drawn[i].a ~= nil and drawn[i].a > 0.5)
    end
    ec("labels are lifted above the object", drawn[1] and drawn[1].z > 0)

    -- and it must draw NOTHING when off, or the toggle is decorative
    drawn = {}
    ESP.enabled = false
    ESP.draw()
    ec("draw emits nothing while disabled", #drawn == 0)

    RaijinLab.om, RaijinLab.drawing = nil, nil
end

local nopos = ESP.pick(list, nil)
ec("pick with no player position returns nothing", #nopos == 0)
local nolist = ESP.pick(nil, 0, 0, 0)
ec("pick tolerates a nil list", #nolist == 0)
""")
    return list(lua.eval("esp_fails").values())


def test_selftest() -> list:
    """Runtime selftest: each check must FAIL on the exact defect it exists to
    catch, PASS on the fixed behaviour, and SKIP (not fail) when a precondition
    like a target is absent. Driven against a mock bridge, so the logic is proven
    without a client - which is the whole point of it."""
    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("math.randomseed(42)")
    lua.execute("RaijinLab = {}")
    src = (ADDON / "core/SelfTest.lua").read_text(encoding="utf-8")
    lua.execute("SelfTest = (function()" + chr(10) + src + chr(10) + "end)()")
    lua.execute("function CreateFrame() return setmetatable({}, {__index=function() return function() end end}) end")
    fsrc = (ADDON / "core/objects/Functions.lua").read_text(encoding="utf-8")
    lua.execute(fsrc)
    asrc = (ADDON / "core/Actions.lua").read_text(encoding="utf-8")
    lua.execute("A = (function()" + chr(10) + asrc + chr(10) + "end)()")
    lua.execute(
        r"""
st_fails = {}
local function dc(name, cond) if not cond then st_fails[#st_fails+1] = name end end

-- A HEALTHY pipeline by default, so om_pipeline has something real to read and
-- the "everything works" case is genuinely everything. Individual assertions
-- below break specific links to prove each failure is detected.
RaijinLab.om = RaijinLab.om or {}
RaijinLab.om.object_list = {
    npcs = { 1, 2, 3 }, players = { 1 },
    -- one gameobject with a known entry, so gameobject_fields has something to
    -- measure against instead of skipping (a check that skips proves nothing)
    gameobjects = { { Guid = "0xG1", Id = 4242, Name = "Fallen Water Pouch" } },
    raw = { npcs = { 1, 2, 3 }, players = { 1 }, gameobjects = { 1 } },
}
RaijinLab._runtime_armed = true
function RaijinLab:GetObjManagerFrame() return { real = true } end

local function rows_by_name(rows)
    local m = {}
    for _, r in ipairs(rows) do m[r.name] = r end
    return m
end

-- a bridge that behaves like the FIXED runtime
local function good(name, a, b, c, d, e, f)
    if name == "GetRuntimeVersion" then return SelfTest.EXPECT_VERSION end
    if name == "GetDistanceBetweenPositions" then
        local dx, dy, dz = d - a, e - b, f - c
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end
    if name == "GetPositionFromPosition" then
        local horiz = d * math.cos(f or 0)
        return a + horiz * math.cos(e or 0), b + horiz * math.sin(e or 0), c
    end
    if name == "GetUnitCount" then return 7 end
    if name == "UnitCasting" then return nil end
    if name == "PitchUpStart" or name == "PitchUpStop" or name == "PitchDownStop" then return true end
    if name == "MoveTo" then return false end
    if name == "ObjectIsFacing" then return true end
    if name == "ObjectQuestGiverStatus" then return 8 end
    if name == "ObjectTypeFlags" then return 1 + 32 + 64 end   -- Object|Unit|Player
    -- Descriptor reads. 0x0C is OBJECT_FIELD_ENTRY (shared by every type);
    -- 0x38 is GAMEOBJECT_DYNAMIC, packed as <timer:16><flags:16> - here a
    -- despawn timer of 0x12 with SPARKLE (0x20) lit. 0x13C is the UNIT field,
    -- which on a gameobject is well past the end of the descriptor: a plausible
    -- but WRONG number, exactly like the garbage the real client returned.
    if name == "ObjectField" then
        if b == 0x0C then return 4242 end
        if b == 0x38 then return 0x00120020 end
        if b == 0x13C then return 0x4000 end
        return 0
    end
    if name == "ObjectDynamicFlags" then return 0x20 end
    if name == "Interact" then return true end
    -- 1.11.0-truth natives. UnitAuras models the DIRECT walk: both client-
    -- visible mock auras present, plus one hidden aura UnitBuff never lists -
    -- the check must tolerate extras and fail only on a MISSING visible aura.
    if name == "UnitAuras" then return "3|1459:2:60000|172:1:30000|9999:1:0|src=d" end
    -- PlayerFacing must agree with the client's own facing. The runtime read
    -- +0x7AC, which live RE proved is not the orientation field, so this
    -- returned 1e9 (undetermined) forever and the facing gate could not fire.
    if name == "PlayerFacing" then return 1.8380 end
    if name == "SpellCastReq" then
        if a == 6603 then
            return "sid=6603|found=1|attr=0x10|targets=0x0|facing=0|castidx=1"
                .. "|cd=0|catcd=0|power=0|cost=0|ri=1|rmin=0.00|rmax=0.00"
                .. "|gcdcat=0|gcd=0|school=0x1|rune=0"
        end
        if a == 133 then
            return "sid=133|found=1|attr=0x10000|targets=0x0|facing=1|castidx=16"
                .. "|cd=0|catcd=0|power=0|cost=30|ri=35|rmin=0.00|rmax=35.00"
                .. "|gcdcat=133|gcd=1500|school=0x4|rune=0"
        end
        return "sid=" .. tostring(a) .. "|found=0"
    end
    return nil
end

-- the client aura API the aura_walk check compares against
function GetPlayerFacing() return 1.8380 end
function UnitBuff(unit, i)
    if i == 1 then return "MockBuff", "", "", 2, nil, 60, 0, "player", nil, nil, 1459 end
end
function UnitDebuff(unit, i)
    if i == 1 then return "MockDebuff", "", "", 1, nil, 30, 0, "player", nil, nil, 172 end
end

RaijinLab.om.object_list.npcs = { {}, {}, {} }
local rows, pass, fail, skip = SelfTest.evaluate(good, { player_guid = "0x1", target_guid = "0x2" })
dc("fixed runtime -> no failures", fail == 0)
dc("fixed runtime -> nothing skipped when target present", skip == 0)
dc("fixed runtime -> all checks pass", pass == #SelfTest.CHECKS)

-- with NO target the target-dependent checks SKIP rather than fail
local rows2, _, fail2, skip2 = SelfTest.evaluate(good, { player_guid = "0x1" })
dc("no target -> still zero failures", fail2 == 0)
dc("no target -> skips interact AND questgiver status", skip2 == 2)
local m2 = rows_by_name(rows2)
dc("no target -> facing still RUNS (self-vs-self proves wiring)", m2["facing_wired"].ok == true)
dc("no target -> interact skipped", m2["interact_honest"].ok == nil)

-- EACH DEFECT MUST BE CAUGHT. One mutation per real bug fixed this session.
local function with(overrides)
    return function(name, ...)
        if overrides[name] ~= nil then
            local v = overrides[name]
            if v == "__nil" then return nil end
            return v
        end
        return good(name, ...)
    end
end
local opts = { player_guid = "0x1", target_guid = "0x2" }

local m = rows_by_name(SelfTest.evaluate(with({ GetRuntimeVersion = "1.0.0-old" }), opts))
dc("stale resident DLL detected", m["runtime_version"].ok == false)

-- MUTATIONS for the aura walk: (a) a walk that cannot validate (src=n) is a
-- failure of the direct path; (b) a walk MISSING a client-visible aura is the
-- layout indictment. Both must fail; hidden extras alone must not.
-- The facing field: an undetermined read (the +0x7AC symptom) and a read that
-- disagrees with the client must both FAIL - that check is the only thing that
-- would have caught the wrong offset.
m = rows_by_name(SelfTest.evaluate(with({ PlayerFacing = 1e9 }), opts))
dc("facing undetermined -> FAIL", m.facing_field_is_live.ok == false)
m = rows_by_name(SelfTest.evaluate(with({ PlayerFacing = -0.8296 }), opts))
dc("facing disagreeing with the client -> FAIL", m.facing_field_is_live.ok == false)
m = rows_by_name(SelfTest.evaluate(with({ UnitAuras = "0|src=n" }), opts))
dc("aura walk not validating -> FAIL", m.aura_walk_vs_client.ok == false)
m = rows_by_name(SelfTest.evaluate(with({ UnitAuras = "1|1459:2:60000|src=d" }), opts))
dc("aura walk missing a visible aura -> FAIL", m.aura_walk_vs_client.ok == false)
m = rows_by_name(SelfTest.evaluate(with({ SpellCastReq = "sid=6603|found=0" }), opts))
dc("castreq undecodable -> FAIL", m.castreq_ground_truth.ok == false)
m = rows_by_name(SelfTest.evaluate(with({ GetDistanceBetweenPositions = 0 }), opts))
dc("distance-stub-returns-0 detected", m["bridge_geometry"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ GetUnitCount = "__nil" }), opts))
dc("dead unit-enum fast path detected", m["unit_enum_fastpath"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ UnitCasting = 0 }), opts))
dc("truthy-0 stub detected", m["stubs_answer_nil"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ PitchUpStart = false }), opts))
dc("pitch dispatching to STOP detected", m["pitch_dispatch"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ MoveTo = true }), opts))
dc("click-to-move still live detected", m["ctm_refused"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ ObjectIsFacing = "__nil" }), opts))
dc("unwired ObjectIsFacing detected", m["facing_wired"].ok == false)

-- THE REGRESSION THAT MATTERS MOST: reading UNIT_DYNAMIC_FLAGS (0x13C) on a
-- gameobject. 0x38 is the right field; 0x13C is past the end of the descriptor.
-- The sparkle witness is the ONLY way to find this server's custom quest
-- objects, so a silent revert here blinds the bot to all of them.
m = rows_by_name(SelfTest.evaluate(with({ ObjectDynamicFlags = 0x4000 }), opts))
dc("unit offset used for a gameobject detected", m["gameobject_fields"].ok == false)

-- the low word must be taken; returning the whole packed dword means the
-- despawn timer bleeds into the flag tests
m = rows_by_name(SelfTest.evaluate(with({ ObjectDynamicFlags = 0x00120020 }), opts))
dc("unmasked packed dword detected", m["gameobject_fields"].ok == false)

-- If the descriptor base itself is wrong, nothing read from it means anything,
-- so that must be caught BEFORE any flag conclusion. This bridge keeps the
-- dynamic-flag halves in perfect agreement and corrupts ONLY the entry, so the
-- entry check is the sole thing that can catch it.
local function bad_entry(name, a, b, c, d, e, f)
    if name == "ObjectField" and b == 0x0C then return 999 end  -- OM says 4242
    return good(name, a, b, c, d, e, f)
end
m = rows_by_name(SelfTest.evaluate(bad_entry, opts))
dc("wrong descriptor base detected", m["gameobject_fields"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ Interact = 1 }), opts))
dc("non-boolean interact return detected", m["interact_honest"].ok == false)

m = rows_by_name(SelfTest.evaluate(with({ ObjectQuestGiverStatus = "__nil" }), opts))
dc("dead quest-giver status source detected", m["questgiver_status"].ok == false)

-- ObjectTypeFlags must be a MASK, not the ObjectType enum. Live 1.8.33 returned
-- the enum, so every object was unclassifiable and object_list.npcs was empty.
m = rows_by_name(SelfTest.evaluate(with({ ObjectTypeFlags = 4 }), opts))
dc("an ObjectType enum answer is caught", m["typeflags_is_mask"].ok == false)
m = rows_by_name(SelfTest.evaluate(with({ ObjectTypeFlags = 97 }), opts))
dc("a proper Unit+Player mask passes", m["typeflags_is_mask"].ok == true)

-- om_pipeline must localise WHICH stage broke, not just that something did.
local saved_raw = RaijinLab.om.object_list.raw.npcs
RaijinLab.om.object_list.raw.npcs = {}
m = rows_by_name(SelfTest.evaluate(good, opts))
dc("classifier producing nothing is caught", m["om_pipeline"].ok == false)
dc("...and names that stage",
   tostring(m["om_pipeline"].detail):find("classified NOTHING", 1, true) ~= nil)
RaijinLab.om.object_list.raw.npcs = saved_raw
local saved_npcs = RaijinLab.om.object_list.npcs
RaijinLab.om.object_list.npcs = {}
m = rows_by_name(SelfTest.evaluate(good, opts))
dc("unpublished processor output is caught", m["om_pipeline"].ok == false)
dc("...and names THAT stage",
   tostring(m["om_pipeline"].detail):find("never published", 1, true) ~= nil)
RaijinLab.om.object_list.npcs = saved_npcs

RaijinLab.om.object_list.npcs = {}
m = rows_by_name(SelfTest.evaluate(good, opts))
dc("bridge sees units but engine snapshot EMPTY detected",
   m["unit_enum_fastpath"].ok == false)
RaijinLab.om.object_list.npcs = { {}, {}, {} }

-- a check that throws must be reported as a failure, not kill the run
local threw = SelfTest.evaluate(function(n) if n == "GetUnitCount" then error("boom") end return good(n) end,
                                opts)
dc("a throwing check does not abort the run", #threw == #SelfTest.CHECKS)

-- ---- Actions.Interact VERIFIES the outcome instead of trusting the return ----
-- The bridge's `true` only means the Lua handler did not throw. If the unit we
-- asked to interact with is not our target afterwards, the TargetUnit step did
-- not take and nothing was interacted with, whatever the bridge said.
dc("guid_same: 0x-prefix and case differences", A.guid_same("0x00F130001A", "f130001a") == true)
dc("guid_same: genuinely different guids", A.guid_same("0xF130001A", "0xF130001B") == false)
dc("guid_same: unreadable -> nil, not false", A.guid_same(nil, "0xF1") == nil)
dc("guid_same: empty after normalise -> nil", A.guid_same("0x0", "0x0") == nil)

__bridge_ret, __target = true, "0xF130001A"
RaijinLab.HasRuntime = function() return true end
RaijinLab.RuntimeCall = function(_, name) return __bridge_ret end
function UnitGUID(u) return __target end
A._armed = true

dc("interact ok when the asked-for unit IS the target",
   A.Interact("0xF130001A") == true)
__target = "0xF1300099"
dc("interact FALSE when a different unit ended up targeted",
   A.Interact("0xF130001A") == false)
__target = nil
dc("interact FALSE when nothing is targeted afterwards",
   A.Interact("0xF130001A") == false)
__target, __bridge_ret = "0xF130001A", false
dc("interact FALSE when the bridge itself refused",
   A.Interact("0xF130001A") == false)

-- ---- a unit token must never be mistaken for a GUID ----
dc("looks_like_guid: 0x-prefixed guid", A.looks_like_guid("0xF130001A") == true)
dc("looks_like_guid: bare hex guid", A.looks_like_guid("F130001A") == true)
dc("looks_like_guid: 'target' is a TOKEN", A.looks_like_guid("target") == false)
dc("looks_like_guid: 'player' is a TOKEN", A.looks_like_guid("player") == false)
dc("looks_like_guid: 'focus' is a TOKEN", A.looks_like_guid("focus") == false)
dc("looks_like_guid: 'mouseover' is a TOKEN", A.looks_like_guid("mouseover") == false)
dc("looks_like_guid: 'boss1' is a TOKEN", A.looks_like_guid("boss1") == false)
dc("looks_like_guid: 'party1' is a TOKEN", A.looks_like_guid("party1") == false)
dc("looks_like_guid: nil is not a guid", A.looks_like_guid(nil) == false)
dc("looks_like_guid: empty is not a guid", A.looks_like_guid("") == false)

-- ---- the OM snapshot must actually be PRODUCED ----
-- om.object_list.npcs had no writer anywhere in the codebase: initialised to {}
-- and only ever read, so the engine saw zero npcs while the runtime enumerated
-- ~94 and the bot was blind to quest givers AND kill objectives alike.
__units, __calls = 3, 0
RaijinLab.HasRuntime = function() return true end
RaijinLab.RuntimeCall = function(_, name, i)
    if name == "GetUnitCount" then return __units end
    if name == "GetUnitWithIndex" then __calls = __calls + 1; return "0xF13000000" .. tostring(i) end
    return nil
end
RaijinLab.ObjectId = function(_, g) return 1501 end
RaijinLab.ObjectPosition = function(_, g) return 10, 20, 30 end
__T = 100
function GetTime() return __T end

RaijinLab.om.object_list.npcs = {}
RaijinLab.om.refresh(true)
dc("refresh POPULATES an empty snapshot", #RaijinLab.om.object_list.npcs == 3)
-- and must NEVER clobber the manager's richer list
RaijinLab.om.object_list.npcs = { { Guid = 'rich', Name = 'Manager Entry' } }
__T = 400
RaijinLab.om.refresh(true)
dc("refresh does not overwrite a populated list",
   RaijinLab.om.object_list.npcs[1].Name == 'Manager Entry')
RaijinLab.om.object_list.npcs = {}
__T = 410
RaijinLab.om.refresh(true)
dc("entries carry a Guid", RaijinLab.om.object_list.npcs[1].Guid ~= nil)
dc("entries carry a position", RaijinLab.om.object_list.npcs[1].x == 10)
dc("guid index is built", RaijinLab.om.object_list.indexes.guid ~= nil)

-- throttled: a second call in the same instant must not re-scan
local before = __calls
RaijinLab.om.refresh()
dc("refresh is throttled within 0.5s", __calls == before)

-- an EMPTY sweep must NOT clobber a good snapshot - that is the exact
-- blind-for-a-tick failure this producer exists to prevent
-- count is healthy but EVERY index read fails: the guard must keep the last
-- good snapshot rather than publish an empty one. (A zero COUNT returns early
-- and never reaches the guard, so testing that case proved nothing.)
__T = 200
local realcall = RaijinLab.RuntimeCall
RaijinLab.RuntimeCall = function(_, name, i)
    if name == "GetUnitCount" then return 3 end
    return nil                      -- every GetUnitWithIndex fails
end
RaijinLab.om.refresh()
dc("a sweep that reads nothing does not blind every consumer",
   #RaijinLab.om.object_list.npcs == 3)
RaijinLab.RuntimeCall = realcall

__T = 250
__units = 0
RaijinLab.om.refresh()
dc("a zero count leaves the snapshot alone",
   #RaijinLab.om.object_list.npcs == 3)

-- no runtime -> no crash, snapshot preserved
__T = 300
RaijinLab.HasRuntime = function() return false end
RaijinLab.om.refresh()
dc("no runtime is survivable", #RaijinLab.om.object_list.npcs == 3)
"""
    )
    return list(lua.eval("st_fails") or [])


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
        "core/rotation/BasicRules.lua",
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
        elif name == "BasicRules":
            # Bound as a bare global ONLY. Publishing it as RaijinLab.BasicRules
            # makes Engine.evaluate route every slot through the full gate set,
            # which is a different unit under test - it broke 17 unrelated
            # priority/condition checks. The BasicRules block calls it directly.
            lua.execute("BasicRules = __mod")
            # BasicRules.lua self-registers onto RaijinLab at its own file
            # bottom, so loading it is enough to make Engine.evaluate route
            # every slot through the full gate set - a different unit under
            # test, and it broke 17 unrelated priority/condition checks.
            # Withdraw the registration; the block calls BasicRules directly.
            lua.execute("if RaijinLab then RaijinLab.BasicRules = nil end")
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
            print("  - " + str(f))
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
                print("  - " + str(f))
            total += len(fails)
        else:
            print("ALL " + label + " TESTS PASSED")

    print("")
    if total:
        print("SUITE FAILED: " + str(total) + " failing check(s)")
        return 1
    print("ALL SUITE TESTS PASSED (" + str(len(GROUPS)) + " groups)")
    return 0


# THE REGISTRY DERIVES ITSELF.
#
# GROUPS used to be a hand-maintained list of (function, banner, label). It was
# deleted during a refactor and main() then died on a NameError - and the time
# before that, the file was TRUNCATED and the suite happily reported success
# while running a fraction of its tests (tools/recovered/source_guards.py is
# headed "Recovered from the pre-truncation .pyc"). A registry that can disagree
# with the functions beside it will eventually disagree silently.
#
# Deriving it from the module's own namespace makes that impossible: every
# test_* function is dispatched by construction, and adding one needs no
# bookkeeping. The banner and label are generated, which is cosmetic - being
# RUN is not.

def test_spell_record() -> list:
    """World.spell_req + the classifiers that replaced the English name lists.

    These shipped with no coverage, which is how three GetSpellInfo indexing
    defects and four unimplemented basic checks all survived a green suite.
    The mock returns the same packed shape the runtime emits, including the
    cases the live 35,427-spell sweep turned up: FacingCasterFlags is a MASK
    (values 7 and 15 exist), gcdcat 0 means genuinely off-GCD, and a record
    the client does not hold answers found=0 rather than throwing.
    """
    from lupa import LuaRuntime
    fails = []

    def chk(name, cond):
        if not cond:
            fails.append(name)

    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute("""
RaijinLab = {}
function RaijinLab:HasRuntime() return true end
GetTime = function() return 100 end
BOOKTYPE_SPELL = "spell"
_BOOK = {
  [1] = { name = "Fireball",    link = "|cff71d5ff|Hspell:133|h[Fireball]|h|r" },
  [2] = { name = "Backstab",    link = "|cff71d5ff|Hspell:53|h[Backstab]|h|r" },
  [3] = { name = "Fireball",    link = "|cff71d5ff|Hspell:9999|h[Fireball]|h|r" },
}
GetSpellName = function(i) local e = _BOOK[i]; return e and e.name or nil end
GetSpellLink = function(i) local e = _BOOK[i]; return e and e.link or nil end
RaijinLab.RuntimeCall = function(self, name, a)
  if name ~= "SpellCastReq" then return nil end
  -- 10: facing MASK 7 (bit 0 set), off-GCD by data, enemy-targeted
  if a == 10 then return "sid=10|found=1|facing=7|gcdcat=0|gcd=0|targets=0x0"
    .. "|ta0=6|cd=0|catcd=0|school=0x1|power=1" end
  -- 11: facing MASK 15 (bit 0 set) - the other live value
  if a == 11 then return "sid=11|found=1|facing=15|gcdcat=133|gcd=1500"
    .. "|targets=0x0|ta0=6|cd=0|catcd=0|school=0x1|power=0" end
  -- 12: ground-targeted AoE (TARGET_FLAG_DEST_LOCATION), no facing
  if a == 12 then return "sid=12|found=1|facing=0|gcdcat=133|gcd=1500"
    .. "|targets=0x40|ta0=18|cd=8000|catcd=0|school=0x4|power=0" end
  -- 13: facing MASK 2 - bit 0 CLEAR, so the client does NOT face-check
  if a == 13 then return "sid=13|found=1|facing=2|gcdcat=133|gcd=1500"
    .. "|targets=0x0|ta0=6|cd=0|catcd=0|school=0x1|power=0" end
  if a == 14 then return "sid=14|found=0" end
  return nil
end
""")
    lua.execute((ADDON / "core/World.lua").read_text(encoding="utf-8"))
    W = "RaijinLab.World."

    chk("spell_req parses a decimal field", lua.eval(W + "spell_req(10).gcd") == 0)
    chk("spell_req parses a 0x field as hex", lua.eval(W + "spell_req(12).school") == 4)
    chk("spell_req on found=0 is nil (never a fabricated table)",
        lua.eval(W + "spell_req(14)") is None)
    chk("spell_req on an unknown id is nil", lua.eval(W + "spell_req(99)") is None)

    # FACING IS A MASK. The live sweep found values 7 and 15; a boolean test
    # (`facing == 1`) would call both of those "no facing required" and wire
    # straight into the client's own refusal.
    chk("facing mask 7 -> face-checked", lua.eval(W + "spell_needs_facing(10)") is True)
    chk("facing mask 15 -> face-checked", lua.eval(W + "spell_needs_facing(11)") is True)
    chk("facing mask 2 (bit 0 clear) -> NOT face-checked",
        lua.eval(W + "spell_needs_facing(13)") is False)
    chk("facing 0 -> NOT face-checked", lua.eval(W + "spell_needs_facing(12)") is False)
    chk("facing unknown -> nil, not false", lua.eval(W + "spell_needs_facing(14)") is None)

    chk("gcdcat 0 + gcd 0 -> off the GCD", lua.eval(W + "spell_off_gcd(10)") is True)
    chk("gcdcat 133 -> on the GCD", lua.eval(W + "spell_off_gcd(11)") is False)
    chk("off_gcd unknown -> nil", lua.eval(W + "spell_off_gcd(14)") is None)

    chk("dest-location target -> self/ground area", lua.eval(W + "spell_is_self_area(12)") is True)
    chk("enemy-targeted -> NOT self area", lua.eval(W + "spell_is_self_area(10)") is False)
    chk("self_area unknown -> nil", lua.eval(W + "spell_is_self_area(14)") is None)

    # SpellIdByName: this client's GetSpellInfo returns NO spell id, so the id
    # comes from the spellbook link. Reading it from GetSpellInfo gave powerType
    # and would have cast spell 3 for every energy ability.
    chk("name -> id from the spellbook link",
        lua.eval("RaijinLab.SpellIdByName('Fireball')") == 133)
    chk("name lookup is case-insensitive",
        lua.eval("RaijinLab.SpellIdByName('bAcKsTaB')") == 53)
    chk("duplicate name keeps the FIRST (lowest-rank) entry",
        lua.eval("RaijinLab.SpellIdByName('Fireball')") == 133)
    chk("unknown name -> nil (never a fabricated id)",
        lua.eval("RaijinLab.SpellIdByName('Nonexistent Spell')") is None)
    chk("empty name -> nil", lua.eval("RaijinLab.SpellIdByName('')") is None)

    # The index must be droppable when the spellbook changes (rank-up / new
    # ability), or a stale id is cast forever.
    lua.execute("RaijinLab.ClearSpellNameIndex()")
    lua.execute("_BOOK[1] = { name = 'Fireball', link = '|Hspell:456|h' }")
    chk("cleared index rebuilds from the new spellbook",
        lua.eval("RaijinLab.SpellIdByName('Fireball')") == 456)
    return fails


def _discover_groups() -> list:
    out = []
    for name in sorted(globals()):
        if not name.startswith("test_"):
            continue
        fn = globals()[name]
        if not callable(fn):
            continue
        stem = name[5:]
        banner = stem.replace("_", " ").capitalize()
        out.append((name, banner, stem.upper().replace("_", "-")))
    return out


GROUPS = _discover_groups()

# A suite that dispatches nothing must not be able to pass. This is the check
# that would have caught both the truncation and the deleted registry.
if not GROUPS:
    raise SystemExit("FATAL: no test_* groups discovered - the suite would "
                     "report success while running nothing")


if __name__ == "__main__":
    raise SystemExit(main())
