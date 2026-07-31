"""Discrimination harness - prove every test detects the bug it claims to.

A green suite means nothing on its own. Three tests written in a single day passed
while the bug they described was restored, because they asserted a mechanism the
bug did not touch, or drove a code path the wiring no longer reached.

So: each entry names a real defect, expressed as a source mutation. The harness
applies it, runs the suite, and restores the file. A mutation that leaves the
suite GREEN means the corresponding test is decorative and is reported as such.

Run:  python tests/discriminate.py            (all)
      python tests/discriminate.py know nav   (only entries matching a tag)

ADD AN ENTRY EVERY TIME A REAL BUG IS FIXED. The entry is the proof that the fix
is defended; without it the test is an opinion.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


# The suite refuses to run while our lockfile exists - that is the whole point
# of the lock (an EXTERNAL suite run mid-mutation reads a half-mutated tree and
# fails on phantoms). But OUR child runs are the legitimate exception: reading
# the mutated tree is precisely the job. The env var is the "it's me" signal.
# The first version forgot this and deadlocked itself: baseline exit=3.
import os as _os
_CHILD_ENV = {**_os.environ, "RAIJIN_MUTATION_RUNNER": "1"}


# Last child output, so a DECORATIVE verdict can SHOW its work.
LAST_OUT: str = ""


def run() -> int:
    """The unit suite.

    Keeps the child's output. Discarding it and reporting only the return code
    meant a disagreement between this harness and a hand-applied mutation was
    invisible: `field:observe` fails 2 checks by hand and read DECORATIVE here,
    with no way to see why. A mutation harness that under-reports manufactures
    confidence - exactly what it exists to prevent.
    """
    global LAST_OUT
    r = subprocess.run(
        [sys.executable, "tests/run_suite_tests.py"],
        cwd=ROOT, capture_output=True, text=True, env=_CHILD_ENV,
    )
    LAST_OUT = (r.stdout or "") + (r.stderr or "")
    return r.returncode


def run_sim() -> int:
    """The world simulator.

    Some defects are invisible to unit tests by their nature: a subsystem that
    ticks 30 times a second while emitting nothing is behaving correctly at every
    call site and wrongly only in aggregate, over time, in a running world. Those
    fixes are defended HERE or nowhere.
    """
    global LAST_OUT
    r = subprocess.run(
        [sys.executable, "tests/simulate.py"],
        cwd=ROOT, capture_output=True, text=True, env=_CHILD_ENV,
    )
    LAST_OUT = (r.stdout or "") + (r.stderr or "")
    return r.returncode


RUNNERS = {"unit": run, "sim": run_sim}


# (tag, file, original, mutated, what breaking it means)
CHECKS = [
    # ---- Know: UNKNOWN must never collapse into NO ----
    ("know", "addon/core/Know.lua",
     '    if k == nil then return Know.UNKNOWN end',
     '    if k == nil then return Know.NO end',
     "nil collapses back to NO - the original sin behind most shipped bugs"),
    # WAS: nil -> unknown. That rule was WRONG for this client and is gone.
    # 3.3.5 boolean apis return 1/nil, so a nil from an api that EXISTS is the
    # idiomatic "no"; only a missing or throwing api is ignorance. The mutation
    # below defends what actually remains true - a throwing probe must not be
    # mistaken for a definite negative.
    ("know", "addon/core/Know.lua",
     '    if not ok then return Know.unknown("error") end',
     '    if not ok then return Know.no("error") end',
     "a throwing API reads as NO instead of cannot-tell"),
    ("know", "addon/core/Know.lua",
     '    if type(fn) ~= "function" then return Know.unknown("no_api") end',
     '    if type(fn) ~= "function" then return Know.no("no_api") end',
     "a missing API reads as NO - absence of evidence as evidence of absence"),
    ("know", "addon/core/Know.lua",
     '    if unknown then return Know.unknown(Know.why(unknown) or "incomplete") end\n'
     '    return Know.yes(true, "all")',
     '    return Know.yes(true, "all")',
     "all() ignores unknown and claims YES"),
    ("know", "addon/core/Know.lua",
     '    return Know.unknown(Know.why(k) or "negated_unknown")',
     '    return Know.no("negated_unknown")',
     "negating ignorance invents certainty"),

    # ---- Fail: permanent must not be a long transient ----
    ("fail", "addon/core/Fail.lua",
     '        -- Persistent facts do NOT expire by wall clock - only by invalidated_by\n'
     '        -- events (level-up, trainer, zone). A timed "permanent" is just a\n'
     '        -- transient with a long backoff, which is how mount retried forever.\n'
     '        wait = 1e12',
     '        wait = math.min(Fail.MAX_BACKOFF, base * (2 ^ math.min(count - 1, 10)))',
     "persistent failures expire by time again - mount-style forever-retry returns"),

    # ---- Caps: livefacing must lift turn workaround ----
    ("caps", "addon/core/Caps.lua",
     '    if ver:find("livefacing", 1, true) or ver:find("1%.8%.[89]") or ver:find("1%.9")\n'
     '       or ver:find("1%.[1-9]%d") then\n'
     '        return yes(true, "version:" .. ver)\n'
     '    end',
     '    return no("disabled")',
     "live_facing capability never reports yes - Navigator stays on rotting keyboard-only path"),

    ("gather", "addon/modules/gathering/Gatherer.lua",
     '            if Kn then return Kn.no("opt_in_unset") end\n'
     '            return false',
     '            if Kn then return Kn.yes(true, "opt_in_unset") end\n'
     '            return true',
     "fishing opt-in unset becomes YES again - demands a pole on enable"),

    ("director", "addon/core/Director.lua",
     'function Director.register_unified(name, band, act, opts)',
     'function Director.register_unified_DISABLED(name, band, act, opts)',
     "unified act(dry) registration disappears - evaluate/run divergence returns"),

    ("goals", "addon/modules/questing/Goals.lua",
     'local function reg(D, name, band, act, opts)',
     'local function reg_DISABLED(D, name, band, act, opts)',
     "Goals reg() helper renamed - install would no-op and no goals register"),

    ("rest", "addon/core/Rest.lua",
     'function Rest.should_rest_k()',
     'function Rest.should_rest_k_DISABLED()',
     "should_rest_k disappears - rest decisions lose three-valued discipline"),

    ("cast", "addon/core/rotation/Executor.lua",
     '    local oid = Ou and Ou.begin and Ou.begin("cast", {',
     '    local oid = nil\n    local __cast_meta = {',
     "cast outcomes disabled - cast success/fail no longer scored"),

    ("death", "addon/core/Death.lua",
     'function Death.is_dead_k()',
     'function Death.is_dead_k_DISABLED()',
     "Death.is_dead_k disappears - recover goals lose three-valued death sensing"),

    # ---- Contract: silence must be loud ----
    ("contract", "addon/core/Contract.lua",
     '    if not applies then\n        spec._since = nil\n        return "n/a"\n    end',
     '    if not applies then\n        spec._since = nil\n        return "ok"\n    end',
     "not-applicable reported as OK - a dead subsystem reads as healthy"),
    ("contract", "addon/core/Contract.lua",
     '    if held > spec.within then return "violated", held end',
     '    if false then return "violated", held end',
     "nothing ever violates"),
    ("contract", "addon/core/Contract.lua",
     '            if prev == nil then return true end\n            return n > prev',
     '            if prev == nil then return true end\n            return true',
     "liveness always satisfied - silence invisible again"),
    ("contract", "addon/core/Contract.lua",
     'local function safe(fn, dflt)\n    if type(fn) ~= "function" then return dflt end\n'
     '    local ok, v = pcall(fn)\n    if not ok then return dflt end\n    return v\nend',
     'local function safe(fn, dflt)\n    if type(fn) ~= "function" then return dflt end\n'
     '    return fn()\nend',
     "a throwing invariant crashes the client"),

    # ---- Navigation: the live steering failures ----
    ("nav", "addon/core/Navigator.lua",
     '    return eff < 0.008',
     '    return false',
     "the turn-effectiveness fallback is disabled - a turn primitive that does "
     "not rotate the character is used forever instead of falling back"),
    ("nav", "addon/core/Navigator.lua",
     '    if live and Navigator.trusted("_pf_ok") ~= false then\n'
     '        Navigator._facing_real = live\n        return live\n    end',
     '',
     "live facing logged but not used for control - the 155-degree oscillation"),
    ("nav", "addon/core/Navigator.lua",
     '    if (now() - (Navigator[key .. "_t"] or 0)) > Navigator.TRUST_TTL then return nil end',
     '    if false then return nil end',
     "trust verdicts latch forever - cam=(ok=false) all session"),
    ("nav", "addon/core/Navigator.lua",
     '    return goal_dist <= (Navigator.LOS_SHORTCUT_MAX or 12)',
     '    return true and (',
     "a clear trace over unloaded collision trusted - walks into walls"),
    ("nav", "addon/core/Navigator.lua",
     'Navigator.LOS_TRUST_RANGE = 200',
     'Navigator.LOS_TRUST_RANGE = 100000',
     "LoS trust range effectively unbounded"),

    # ---- Questing: the stationary bug ----
    ("quest", "addon/modules/questing/Suite.lua",
     '        return Suite.search_for(kind, label, q)',
     '        return kind .. ":none in range, none remembered (" .. label .. ")"',
     "no-known-location is a dead end again - 166 minutes standing still"),


    # Two former entries were removed here, not fixed, and the distinction matters.
    # They anchored on the ring-sweep that the belief field replaced; re-anchored
    # onto the new code they report DECORATIVE, because each guard is now
    # REDUNDANT - give-up has a second path (belief exhaustion), and writing off an
    # unreachable leg has a second path (clearing st.tx). Nothing observable
    # changes when either is disabled, so there is no regression to catch.
    # Keeping entries that permanently report DECORATIVE would train the eye to
    # skip that word, and that word is the only thing this harness produces that
    # matters.

    # ---- Rotation ----
    ("rot", "addon/core/rotation/Executor.lua",
     '    if _filled_count(data) == 0 then\n        local alt, cnt = _best_populated(rots, name)',
     '    if false then\n        local alt, cnt = _best_populated(rots, name)',
     "an empty active rotation is used - 2671 warnings, zero casts"),
    ("rot", "addon/core/rotation/Executor.lua",
     '            if c > 0 and (not bc or c > bc) then bn, bc = n, c end',
     '            if c > 0 and (not bc or c < bc) then bn, bc = n, c end',
     "falls back to the LEAST populated rotation"),
    ("rot", "addon/core/rotation/Executor.lua",
     '    if Executor._active_cache and Executor._resolved_from == selected then',
     '    if Executor._active_cache and Executor._active_name == selected then',
     "cache keyed on the resolved name - re-deserializes at 70Hz"),

    # ---- Config durability ----
    ("config", "addon/core/ConfigBackup.lua",
     '            if id ~= 0 then return true end',
     '            if id ~= nil then return true end',
     "an empty placeholder counts as real work - masks the loss"),
    ("config", "addon/core/ConfigBackup.lua",
     '        return not CB.is_real_rotation(live)                       -- live is a placeholder',
     '        return false',
     "restore skips placeholders, so it never restores anything"),
    ("config", "addon/core/ConfigBackup.lua",
     '    if type(snap.characters) == "table" then\n        RaijinLabDB.characters = RaijinLabDB.characters or {}',
     '    if false then\n        RaijinLabDB.characters = RaijinLabDB.characters or {}',
     "per-character rotations are never restored"),

    # ---- Mount ----
    # BOTH ANCHORS RE-TARGETED 2026-07-29. The originals went stale when the
    # precheck grew into a Fail-engine block, and the stopped harness plus a
    # naive `replace(new, old)` restore then INSERTED the obsolete one-liner at
    # byte 0 of the file (replace("") prepends), taking the whole sim to 0/14.
    # Deletion-style mutations (new="") are now banned in this table for exactly
    # that reason - always mutate to something findable.
    ("mount", "addon/core/Mount.lua",
     "    if not Mount.can_ride() then",
     "    if false and not Mount.can_ride() then",
     "no riding-skill precheck - stops to fail every 120s forever"),
    ("mount", "addon/core/Mount.lua",
     '        if Kn then return Kn.unknown("no_api") end',
     '        if Kn then return Kn.no("no_api") end',
     "unknown APIs read as 'no skill' - would disable a working server"),
    ("mount", "addon/core/Mount.lua",
     '        Mount._proven = true        -- settles the skill question permanently',
     '',
     "a successful mount no longer overrides the heuristic"),

    # ---- Suite master switch ----
    ("master", "addon/core/Master.lua",
     '    for _, k in ipairs(M.MODULES) do\n        d.modules[k] = was[k]\n    end',
     '    for _, k in ipairs(M.MODULES) do\n        d.modules[k] = false\n    end',
     "switching OFF erases the user's module selection"),
    ("master", "addon/core/Master.lua",
     '        for _, fn in ipairs({ "MoveForward", "StrafeLeft", "StrafeRight",',
     '        for _, fn in ipairs({ "MoveForwardStop", "StrafeLeftStop", "StrafeRightStop",',
     "movement release uses names that do not exist - a kill switch that releases nothing"),

    # ---- NavGrid: absence must never read as a wall ----
    ("navgrid", "addon/core/NavGrid.lua",
     '        if Know then return Know.unknown("no_tile") end',
     '        if Know then return Know.no("no_tile") end',
     "a missing tile reads as NOT WALKABLE - every unexported zone becomes a wall"),
    ("navgrid", "addon/core/NavGrid.lua",
     '        return Know and Know.unknown("structure") or nil',
     '        return Know and Know.no("structure") or nil',
     "a building AABB reads as a wall - makes towns unreachable"),
    ("navgrid", "addon/core/NavGrid.lua",
     '    if want > 0 and (i - 1) ~= want then',
     '    if false then',
     "a truncated tile is half-used instead of refused"),
    ("navgrid", "addon/core/NavGrid.lua",
     "    local ty = math.floor((NG.ORIGIN - x) / NG.TILE)" + chr(10) +
     "    local tx = math.floor((NG.ORIGIN - y) / NG.TILE)",
     "    local tx = math.floor((NG.ORIGIN - x) / NG.TILE)" + chr(10) +
     "    local ty = math.floor((NG.ORIGIN - y) / NG.TILE)",
     "tile axes swapped - a mirrored world that still looks plausible"),

    ("navgrid", "addon/core/NavGrid.lua",
     '    return nil                 -- unknown map -> every query unknown -> live sensing',
     '    return "Azeroth"',
     "an unresolved map GUESSES a continent - confidently reports walls that are not there"),
    ("navgrid", "addon/core/NavGrid.lua",
     '    [2] = "Azeroth",          -- Eastern Kingdoms',
     '    [2] = "Kalimdor",',
     "wrong continent mapping - loads another continent's terrain as ground truth"),

    ("navgrid", "addon/core/NavGrid.lua",
     '        heights[j] = acc / 4.0',
     '        heights[j] = 0',
     "per-cell heights discarded - the 20%-within-3yd failure"),
    ("navgrid", "addon/core/NavGrid.lua",
     '        return nil, "height_count_mismatch"',
     '        return t',
     "a tile with the wrong number of heights is used anyway"),

    ("navgrid", "addon/core/NavGrid.lua",
     '    if h10 == nil or h01 == nil or h11 == nil then return h00 end',
     '    if false then return h00 end',
     "a cliff edge gets smoothed into a ramp that does not exist"),

    ("navgrid", "addon/core/NavGrid.lua",
     '        return Know and Know.yes(true, "water") or true',
     '        return Know and Know.no("water") or false',
     "water reads as a wall - every river becomes impassable"),

    ("navgrid", "addon/core/NavGrid.lua",
     '                local code = NG.at(x, y, map) or NG.UNKNOWN',
     '                local code = NG.UNKNOWN',
     "verify stops classifying its residual - back to narrating an unmeasured cause"),

    ("master", "addon/core/Master.lua",
     '    quest = { "rotation", "combat" },   -- travel + fight + loot the objective',
     '    quest = {},',
     "the quester no longer pulls up rotation/combat - enabled and standing still"),

    ("vision", "addon/core/Vision.lua",
     '    if V._segments >= V.MAX_SEGMENTS then return false end',
     '    if false then return false end',
     "the render budget is gone - a visualiser that costs frames gets turned off"),
    ("vision", "addon/core/Vision.lua",
     '    if V.enabled("path") then pcall(V.draw_path, dr) end',
     '    if V.enabled("path") then V.draw_path(dr) end',
     "a throwing layer takes the frame with it"),

    ("vision", "addon/core/Vision.lua",
     "    local head = N._facing_real or N._cam_now",
     "    local head = N._facing_real or N._cam_now or 0",
     "the controller layer invents a heading when none was measured"),

    ("menu", "addon/core/Menu.lua",
     '{ key = "use_gather",      label = "Gather nodes seen along the way", default = true },',
     '{ key = "use_gathering",   label = "Gather nodes seen along the way", default = true },',
     "a panel control bound to a key no module reads - looks like it works"),
    ("menu", "addon/core/Menu.lua",
     '{ "fishing",    "Fishing - OPT-IN: needs a pole equipped and a pool", false },',
     '{ "fishing",    "Fishing - OPT-IN: needs a pole equipped and a pool", true },',
     "the fishing checkbox defaults ON again - instantly demands a rod"),

    ("nav", "addon/core/Navigator.lua",
     '            if (Navigator._pf_still or 0) >= 20 then',
     '            if false then',
     "a frozen live facing is trusted forever - the character spins on the spot"),
    ("vision", "addon/core/Vision.lua",
     '        if R.InitDrawing then pcall(R.InitDrawing, R) end',
     '',
     "the draw loop is never started - layers on, 0 segments drawn"),

    ("menu", "addon/core/Menu.lua",
     "            RaijinLabDB.modules[key] = v",
     "            RaijinLabDB.modules[key] = v" + chr(10) +
     "            RaijinLabDB.quest.enabled = v",
     "a shadow enable flag returns - two flags for one concept, free to disagree"),

    ("search", "addon/core/SearchField.lua",
     '            if sqrt((bmx - ax) ^ 2 + (bmy - ay) ^ 2) > limit then',
     '            if false then',
     "search legs escape the field support - a 10km walk at a stale cell"),
    ("search", "addon/modules/questing/Suite.lua",
     '        if leg > Suite.SEARCH_MAX_LEG then',
     '        if false then',
     "Suite commits to an impossible leg instead of refusing it"),

    ("quest", "addon/modules/questing/Suite.lua",
     '    local gst = goto_point(st.tx, st.ty, st.tz, 18, { no_fly = true })',
     '    local gst = goto_point(st.tx, st.ty, st.tz, 18)',
     "a search leg routes through flight paths - flies to a waypoint it invented"),

    ("nav", "addon/core/API.lua",
     '        return false, "cam_" .. math.floor(d)',
     '        return true',
     "a player position 2000yd from the camera is accepted - the bot navigates a void"),
    ("nav", "addon/core/API.lua",
     '    if not (c and type(c.px) == "number" and type(c.py) == "number") then',
     '    if false then',
     "no camera is treated as evidence AGAINST the position - refuses every reading"),

    ("search", "addon/modules/questing/Suite.lua",
     "    local ok, p = pcall(QDB.quest_npc, qid, which, px, py)",
     "    local ok, p = false, nil",
     "a finished quest whose turn-in npc is out of scan range is abandoned - the "
     "bot wanders off with a completed quest in its log"),

    ("nav", "addon/core/Navigator.lua",
     "    local want_strafe = a.force_strafe or nil",
     "    local want_strafe = a.force_strafe or ((cross or 0) > 1.8 and 'right' or nil)",
     "strafe becomes a steering controller again - a second controller fighting "
     "pure-pursuit over the same error, sidestepping the whole way to the goal"),
    ("nav", "addon/core/Navigator.lua",
     "    if a.block and (a.wall_side or 0) ~= 0 and not swimming_now then",
     "    if false then",
     "sustained wall contact no longer strafes - a long wall is travelled by the "
     "bent heading alone and the body grinds the face"),

    ("search", "addon/modules/questing/QuestDB.lua",
     "    RaijinLabDB.questdb.cal = out",
     "    RaijinLabDB.questdb.cal = {}",
     "zone transforms are not persisted - every session re-walks every zone "
     "before its database coordinates become usable"),

    ("vision", "addon/core/Vision.lua",
     "    local goal = (N and (N._want_goal or N._pf_goal)) or nil",
     "    local goal = (N and N._active and N._active.goal) or nil",
     "intent is only drawn when a route already exists - the screen goes blank "
     "during planning and parking, which is exactly when 'where is it going' is asked"),

    ("chain", "addon/core/Chain.lua",
     '                return false, "raw=" .. raw .. " but npcs=0 - ObjectProcessor never published"',
     '                return true, "ok"',
     "the pipeline diagnostic stops naming the blindness case - bridge sees units, "
     "engine snapshot empty, and /raijin chain reports it as healthy"),

    ("search", "addon/modules/questing/QuestDB.lua",
     "    if QuestDB.bootstrap(map, xp, yp, wx, wy) then return end",
     "",
     "the zone can only be calibrated by WALKING - and the engine refuses to walk "
     "to an unknown location, so it parks forever and never calibrates"),
    ("search", "addon/modules/questing/QuestDB.lua",
     "            if n == 1 and here and RL.ObjectPosition then",
     "            if n >= 1 and here and RL.ObjectPosition then",
     "an npc with SEVERAL spawns is used to calibrate - we do not know which one "
     "we are looking at, so the whole zone transform is built on a guess"),

    ("search", "addon/modules/questing/QuestOM.lua",
     '        if not ok_status and want == "available" and id and kind == "O" then',
     "        if false then",
     "quest-starting OBJECTS are invisible again - giver_status reads a UNIT "
     "field, so a scroll/crate that offers a quest is skipped however close"),

    ("search", "addon/modules/questing/QuestDB.lua",
     "    local parent, w, h, cx, cy = QuestDB.zone_rect(map)",
     "    local parent, w, h, cx, cy = nil, nil, nil, nil, nil",
     "a zone can only be placed if we have STOOD IN it - an objective one zone "
     "over reads as unknown and the engine parks"),

    ("search", "addon/modules/questing/QuestOM.lua",
     '        if not ok_status and want == "available" and kind == "O" and struct then',
     "        if false then",
     "a SPARKLING lootable that begins a quest is invisible - the database cannot "
     "know a server's custom objects, and the client's own marker is ignored"),
    ("search", "addon/modules/questing/QuestOM.lua",
     "            QuestOM._scan.nopos = QuestOM._scan.nopos + 1\n"
     "            return",
     "            QuestOM._scan.nopos = QuestOM._scan.nopos + 1\n"
     "            d = 5",
     "a candidate with NO POSITION is given a fabricated distance of 5 - the "
     "engine locks onto something it can never walk to or face"),

    ("search", "addon/core/objects/Manager.lua",
     "                        local okn, nm = pcall(QDB.entry_name, struct.Id, nil)",
     "                        local okn, nm = false, nil",
     "every object in the world is named '<0xF13...>' again - UnitName takes a "
     "TOKEN, so nothing resolves and every name-based match dies silently"),

    # ---- Knowledge before search --------------------------------------------
    ("search", "addon/modules/questing/Suite.lua",
     "    local okq, known = pcall(QDB.locate, label, px, py, seen)",
     "    local okq, known = false, nil",
     "the shipped spawn database is ignored - the bot sweeps a probability field "
     "for objectives whose coordinates are on disk"),

    # ---- The premapped world is the AUTHORITY for static geometry ------------
    ("nav", "addon/core/WorldMesh.lua",
     '                                    ok, why = false, "structure"',
     '                                    ok = ok',
     "the mesh graph accepts edges through mapped buildings again - every "
     "planner tier inherits routes straight through walls and fences"),
    ("nav", "addon/core/Pathfinder.lua",
     '                        if tracer_state(ax, ay, z0, sx, sy, z1) ~= "clear" then',
     '                        if tracer(ax, ay, z0, sx, sy, z1) then',
     "a STRUCTURE cell is passable whenever the raycast cannot answer - the "
     "offline map goes back to being subordinate to the least reliable sensor"),

    # ---- Wall-following: a surface is passed by travelling ALONG it -----------
    ("nav", "addon/core/Navigator.lua",
     "    return math.min((cur or bend0) + step, cap)",
     "    return bend0",
     "the wall bend stops escalating - a constant 0.9rad keeps 62% of speed "
     "pointed into the surface, so a long wall is leaned on forever"),

    # ---- Buildings are data, not surprises ------------------------------------
    ("nav", "addon/core/Pathfinder.lua",
     "    if code == NG.STRUCTURE then return NG.STRUCTURE_COST or 12.0 end",
     "    if code == NG.STRUCTURE then return 1.8 end",
     "a building costs 1.8x again - cutting through the church is the shortest "
     "route and the wall is left to a 2.2yd raycast"),
    ("nav", "addon/modules/questing/Suite.lua",
     "        if okc and code == NG.STRUCTURE then return false end",
     "        if okc and code == NG.STRUCTURE then return true end",
     "search waypoints inside building footprints are accepted again - the "
     "sweep aims at the middle of the church"),

    # ---- Absence of evidence, found by the 2026-07-28 gate audit -------------
    ("liveness", "addon/core/Watchdog.lua",
     "        if not t0 then return 0 end        -- genuinely just started: not an accusation\n"
     "        return now() - t0",
     "        return 0",
     "never-having-progressed reads as perfectly healthy - the watchdog cannot "
     "see a bot that wedged before its first step"),
    ("nav", "addon/core/Navigator.lua",
     '    if swimming then return "swimming" end',
     '    if swimming then return "airborne" end',
     "swimming reads as falling - every deep lake aborts with 'left the ground' "
     "and burns a false BLOCKED cell into the persistent mesh"),
    ("nav", "addon/core/GroundCache.lua",
     "GroundCache.WALK_DOWN = 6.0          -- max drop a standing character tolerates",
     "GroundCache.WALK_DOWN = 14.0         -- mutated",
     "walkability default down span is 14yd again - look-ahead accepts lake "
     "bottoms the 6yd step gate rejects on arrival"),
    ("nav", "addon/core/GroundCache.lua",
     '    if is_water then\n'
     '        -- Keep the altitude band. A path node on the lake bed would make the\n'
     '        -- character dive the moment it stepped off the shore.\n'
     '        return band, "swim"\n'
     '    end',
     '    if is_water then\n'
     '        return hit, "swim"\n'
     '    end',
     "deep water path nodes sit on the lake bed again - shore entry dives"),
    ("nav", "addon/core/Navigator.lua",
     "            hit = GC.ground(ax, ay, pz, nil, 3.0, span)",
     "            hit = GC.ground(ax, ay, pz)",
     "terrain_probe ignores its own span - deep water green-lit, airborne on arrival"),
    ("nav", "addon/core/Navigator.lua",
     'function Navigator.swim_control(swimming, pz, goal_z, breath, shore, surface_latch, opts)',
     'function Navigator.swim_control_DISABLED(swimming, pz, goal_z, breath, shore, surface_latch, opts)',
     "swim_control gone - breath latch and held vertical die together"),
    ("nav", "addon/core/Navigator.lua",
     'function Navigator.shore_intent(swimming, floor_ahead, water_ahead, goal_dry)',
     'function Navigator.shore_intent_DISABLED(swimming, floor_ahead, water_ahead, goal_dry)',
     "shore enter/climb-out policy gone - water edges block or never climb"),
    ("nav", "addon/core/Actions.lua",
     'function A.Ascend(start)',
     'function A.Ascend_DISABLED(start)',
     "Ascend hold gone - swim-up becomes a one-shot Jump pulse again"),
    ("nav", "addon/core/Actions.lua",
     'function A.Descend(start)',
     'function A.Descend_DISABLED(start)',
     "Descend facade gone - swim-down cannot leave the Actions gate"),
    ("nav", "addon/core/Navigator.lua",
     '    if latch and (breath == nil or breath >= recover) then\n'
     '        latch = false\n'
     '    end',
     '    if false then\n'
     '        latch = false\n'
     '    end',
     "breath latch never clears - character surfaces forever after one panic"),
    ("outcome", "addon/core/Outcomes.lua",
     "function Outcomes.settle_progress(id, note, opts)",
     "function Outcomes.settle_progress_DISABLED(id, note, opts)",
     "progress-aware settle gone - thrashing goals score neutral forever"),
    ("nav", "addon/core/API.lua",
     '        return true, "no_cam_witness"    -- all-zero camera = no witness, not a verdict',
     '        return true, "cam_unusable"',
     "an all-zero (failed) camera read counts as a valid position witness - "
     "0 is truthy in Lua"),

    # ---- Liveness instrumentation (found BY THE SIMULATOR, defended by it) ----
    ("liveness", "addon/core/rotation/Executor.lua",
     "    report_idle(reason)", "",
     "executor refusals never reach Telemetry - ticks 30Hz while reading as dead",
     "sim"),
    ("liveness", "addon/core/Director.lua",
     '        Tel0.every("director:hb", 10,',
     '        if false then Tel0.every("director:hb", 10,',
     "director heartbeat is not at the tick ENTRY - a stable goal reads as dead",
     "sim"),

    # ---- Search sweep (simulator-defended) ----
    ("search", "addon/modules/questing/Suite.lua",
     '    if gst == "arrived" then',
     '    if false then',
     "goto_point's 'arrived' leaks out and ends the search at the first waypoint",
     "unit"),
    ("search", "addon/modules/questing/Suite.lua",
     '    field:observe(px, py, Suite.SEARCH_SIGHT)',
     '',
     # UNIT, not sim. This was tagged "sim" and no scenario exercises the belief
     # drain, so it could never be detected there and read DECORATIVE forever -
     # a mutation pointed at a runner that cannot see it is worse than none, it
     # reports a defended fix as undefended and sends you hunting.
     "search never records what it saw - re-searches ground already looked at"),
    # NOTE: the mass-exhaustion guard in search_for is deliberately NOT listed.
    # Disabling it changes nothing observable - best() returning nil is a second,
    # independent termination path that yields the same stuck status - so there is
    # no regression to catch. Listing it would mean permanently carrying an entry
    # that reports DECORATIVE, training the eye to ignore that word, which is the
    # one thing this harness cannot afford.

    # ---- Compat: quest id index ----
    ("compat", "addon/core/Compat.lua",
     '            local id = tonumber(ninth) or tonumber(eighth)',
     '            local id = tonumber(eighth)',
     "IsOnQuest reads isDaily as the quest id - never matches"),

    # ---- Gathering ----
    ("gather", "addon/modules/gathering/Gatherer.lua",
     '            if Kn then return Kn.no("opt_in_unset") end\n'
     '            return false',
     '            if Kn then return Kn.yes(true, "opt_in_unset") end\n'
     '            return true',
     "fishing defaults ON - demands a rod the moment gathering is enabled"),
    ("gather", "addon/modules/gathering/Gatherer.lua",
     '    if not Gatherer.has_fishing_pole() then return false, "no_pole" end',
     '',
     "casts Fishing with no pole equipped"),
]


MUTATION_LOCK = Path(__file__).parent / ".mutation_in_progress"

def _locked_main(argv) -> int:
    tags = set(argv[1:])
    checks = [c for c in CHECKS if not tags or c[0] in tags]
    base = run()
    print(f"baseline exit={base}   ({len(checks)} mutations)")
    if base != 0:
        print("!! suite is not green - fix that before trusting discrimination")
        return 1
    bad, stale = [], []
    for check in checks:
        tag, rel, old, new, desc = check[:5]
        runner = RUNNERS[check[5] if len(check) > 5 else "unit"]
        path = ROOT / rel
        orig = path.read_text(encoding="utf-8")
        if old not in orig:
            print(f"  ANCHOR-MISS           [{tag}] {desc}")
            stale.append(desc)
            continue
        # try/finally, ALWAYS. Without it, an interrupted or crashing runner
        # leaves the mutation applied in the REAL addon tree. That happened: a
        # run died with the executor's report_idle(reason) call deleted, the
        # simulator then failed 3 scenarios on a "rotation is silent" contract,
        # and the corruption looked exactly like a regression in whatever was
        # edited next - it cost three wrong bisections to find.
        path.write_text(orig.replace(old, new, 1), encoding="utf-8")
        try:
            rc = runner()
        finally:
            path.write_text(orig, encoding="utf-8")
        # THE EXIT CODE MUST AGREE WITH THE OUTPUT.
        #
        # A child that PRINTS "SUITE FAILED" while exiting 0 turns a detected
        # mutation into a DECORATIVE verdict - the harness then reports the fix
        # as undefended and a real regression would slip through the same hole.
        # This exact disagreement was observed on the field:observe entry, which
        # fails 2 checks when applied by hand. Never silently trust one over the
        # other: say so, and treat it as DETECTED, because the suite plainly did.
        if rc == 0 and ("SUITE FAILED" in LAST_OUT or " FAILED " in LAST_OUT):
            print(f"  INCONSISTENT (exit 0 but the suite reported failures)"
                  f"  [{tag}] {desc}")
            for ln in LAST_OUT.splitlines():
                if "FAILED" in ln:
                    print("        | " + ln)
            print("        ^ harness bug: exit code disagrees with output. "
                  "Counting as DETECTED - the suite caught it.")
        elif rc == 0:
            print(f"  DECORATIVE (exit  0)  [{tag}] {desc}")
            # SHOW THE WORK. A DECORATIVE verdict is a claim that the suite
            # passed with the fix removed - and when that disagrees with a
            # hand-applied mutation there was previously no way to see why.
            # Print the child's own summary lines so the disagreement is
            # evidence, not inference.
            for ln in LAST_OUT.splitlines():
                if "FAILED" in ln or "SUITE" in ln or "Error" in ln:
                    print("        | " + ln)
            bad.append(desc)
        else:
            print(f"  detects    (exit {rc:>2})  [{tag}] {desc}")
    print(f"\n{len(checks) - len(bad) - len(stale)}/{len(checks)} detected")
    if stale:
        print("STALE - the anchor no longer exists, so these mutations changed "
              "NOTHING and prove nothing. Re-point them at the current source:")
        for d in stale:
            print("  - " + d)
    if bad:
        print("UNDEFENDED - these fixes have no test that would catch a regression:")
        for d in bad:
            print("  - " + d)
    return 1 if (bad or stale) else 0


def main(*a, **kw):
    """Hold a lockfile while mutating the shipped tree.

    Twice now the unit suite was run concurrently with this harness and read a
    half-mutated file, producing phantom failures that cost real diagnosis time
    (SENSORS/GATHERER "failures" that vanished on re-run). The suite refuses to
    start while this file exists, which turns a subtle race into a loud, instant,
    correctly-attributed error."""
    MUTATION_LOCK.write_text("pid-lock", encoding="utf-8")
    try:
        return _locked_main(*a, **kw)
    finally:
        try:
            MUTATION_LOCK.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
