"""Adversarial worlds, one per real failure.

Every scenario here is a bug a human found by playing. That is the indictment this
file exists to answer: each was reproducible in seconds without a game client, and
nobody could reproduce it because there was nothing to reproduce it WITH.

A scenario states what the bot must ACHIEVE, not what it must avoid crashing on.
"Ran for ten minutes without erroring" was true of every one of these failures.
"""
from __future__ import annotations

import math
from pathlib import Path

from .runner import SimRun
from .world import Unit, Wall, WaterBody, World


class Scenario:
    name = "unnamed"
    why = ""                       # the real failure this reproduces
    seconds = 300.0

    def build(self) -> World:
        raise NotImplementedError

    def setup(self, run: SimRun) -> None:
        pass

    def check(self, run: SimRun, res) -> list[str]:
        """Return failure strings; empty means the bot did its job."""
        raise NotImplementedError


# ---------------------------------------------------------------------------

class ClosesOnFlakyQuestGiver(Scenario):
    """A giver 21 yards away whose status only answers 1 read in 16.

    The live failure this reproduces: `accept:to ? st=8 d=21 (moving)` alternating
    with `objective:searching ...` roughly three times a second, for fourteen
    minutes, while `d` never moved off 20. Every flip handed Navigator a brand-new
    goal, so the character jittered in place 21 yards from an npc it could see.

    Root cause was that giver_status treated a 0 read as "not a giver" while the
    client answers only ~6% of the time (asked=7154, nonzero=450). The intermittent
    sensor is modelled here on purpose - with a perfect one this passes even with
    the bug present, which is exactly why it went unnoticed for so long.
    """

    # NOT REGISTERED YET - and deliberately not, because it currently fails for
    # the WRONG REASON. Probed: the object manager frame is running
    # (om_frame=true, so the Events fix works here), but the simulator's object
    # enumeration never produces an npc list - object_list.raw.npcs stays nil and
    # giver_status is asked ZERO times. So this would go red on a simulator
    # fidelity gap while claiming the giver logic regressed, which is worse than
    # no test: a red that points at the wrong file trains you to ignore it.
    #
    # TO FINISH: make the sim's GetObjectCount/GetObjectWithIndex expose world
    # units to RunObjectManager (it reported count=1 for a world with a player
    # plus one npc), then register this in SCENARIOS. The giver-status memory it
    # is meant to defend IS covered at unit level in test_questom - this would add
    # the end-to-end proof that the approach actually COMMITS.
    name = "closes_on_flaky_quest_giver"
    why = ("giver 21yd away, status source answers 1 read in 16: the bot must "
           "COMMIT to the approach instead of flipping to objective search")
    seconds = 90.0

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y, w.player.level = 100.0, 100.0, 1
        w.add_unit(Unit(guid="0xF130000000000001", name="Deathguard Saltain", entry=1234,
                        x=121.0, y=100.0, level=5, hostile=False,
                        giver_status=8, giver_status_flaky=16))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(quest=True)
        run._closest = 1e9

        def watch(r, _i):
            d = math.hypot(121.0 - r.w.player.x, 100.0 - r.w.player.y)
            if d < r._closest:
                r._closest = d
        run._watch = watch

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        closest = getattr(run, "_closest", 1e9)
        # It starts 21yd away. Interact range is ~4.5yd; require real closure.
        if closest > 10.0:
            f.append(f"never closed on the giver: nearest approach {closest:.1f}yd "
                     f"(started at 21yd) - the accept goal is being abandoned")
        if res.stationary_pct > 85:
            f.append(f"stationary {res.stationary_pct:.0f}% of samples - "
                     f"jittering in place instead of walking to the npc")
        return f


class ReachesUnknownObjective(Scenario):
    name = "reaches_unknown_objective"
    why = ("166 minutes standing in Deathknell: the kill target was never in range "
           "and nothing was remembered, so no destination was produced and the nav "
           "stack logged zero lines all session. It no longer SEARCHES for this - "
           "the shipped database knows where the mob spawns, so the contract is "
           "now: knowledge in, travel out, arrive.")
    # Ends shortly after arrival. With one quest and one spawn the bot has
    # nothing left to do once it gets there, and idling is then CORRECT - the
    # stall contracts exist to catch a bot that never had a destination, which
    # is the failure this scenario was written for.
    seconds = 120.0

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y, w.player.level = 0.0, 0.0, 1
        # The quest mob is well outside render range - it MUST be searched for.
        w.add_unit(Unit(guid="duskbat1", name="Duskbat", entry=1501,
                        x=380.0, y=120.0, level=2, tied_to_quest=True))
        w.add_quest("Little Blue Bats", 1, [
            {"text": "Duskbat slain: 0/5", "type": "monster", "finished": False},
        ])
        # THE BOT IS SUPPOSED TO KNOW THIS. It no longer sweeps a probability
        # field for something it cannot see - the shipped client has
        # RaijinQuest's spawn tables, so the correct behaviour is to walk
        # straight to the known location. That is what this scenario now checks.
        w.known["Duskbat"] = {"x": 380.0, "y": 120.0, "z": 0.0}
        return w

    def setup(self, run: SimRun) -> None:
        # combat too: the bot now TRAVELS to the known spawn instead of sweeping,
        # so it arrives at the mob within seconds. Without a rotation it then
        # stands next to its objective doing nothing, which the
        # moves_while_working contract correctly calls a stall.
        run.boot(quest=True, combat=True, rotation=True)
        run._closest = 1e9

        def watch(r, _i):
            # measure against where the mob ACTUALLY is - the old (480,220) was
            # stale from before the world moved off the origin, so this scenario
            # was scoring travel toward a point nothing was ever at.
            d = math.hypot(380.0 - r.w.player.x, 120.0 - r.w.player.y)
            if d < r._closest:
                r._closest = d
        run._watch = watch

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        if res.travelled < 100:
            f.append(f"barely moved: {res.travelled:.0f}yd travelled in "
                     f"{res.seconds:.0f}s (the original bug was 92% stationary)")
        if res.stationary_pct > 80:
            f.append(f"stationary {res.stationary_pct:.0f}% of samples")
        # It should have closed distance on something it could not initially see.
        # Judge CLOSEST APPROACH from the real start, not the final position: an
        # outward sweep legitimately passes a target and keeps going, so "where
        # did it stop" is the wrong question. "Did it ever get eyes on it" is the
        # right one. (The old check also used stale coordinates from before the
        # world was moved off the origin, so it was measuring the wrong point.)
        # It starts at the origin and the objective is at (380,120). Knowing
        # where it is, the bot must CLOSE ON IT - not merely drift closer than a
        # sweep would. This is the deterministic contract: knowledge in, travel
        # out.
        d0 = math.hypot(380.0, 120.0)
        closest = getattr(run, "_closest", d0)
        if closest > 40.0:
            f.append(f"never got closer than it started ({d0:.0f}yd)")
        elif closest > 200.0:
            f.append(f"swept {res.travelled:.0f}yd but never came within render "
                     f"range (closest {closest:.0f}yd) - the sweep is not converging")
        return f


class DoesNotStandStillWithoutRiding(Scenario):
    name = "no_riding_skill_still_travels"
    why = ("a level-1 character owned a mount but could not ride it; every attempt "
           "stopped movement first, so it stood still trying to mount forever")
    # Ends shortly after arrival. The bot no longer sweeps: it walks straight
    # to the known spawn and then WAITS there, which is correct with one
    # spawn and one quest - this scenario is about travelling without a
    # mount, and the travel is what it measures.
    seconds = 120.0

    def build(self) -> World:
        w = World()
        w.player.level = 1
        w.companions = [{"creature": 1, "name": "Skeletal Horse", "spell": 100}]
        w.known_spells = set()                    # owns the mount, cannot ride it
        w.skills = [("Unarmed", False, 5)]
        w.add_unit(Unit(guid="mob1", name="Duskbat", entry=1501, x=300.0, y=0.0))
        w.add_quest("Go There", 1, [
            {"text": "Duskbat slain: 0/3", "type": "monster", "finished": False},
        ])
        # deterministic: the bot no longer sweeps, so it must KNOW where
        # the objective is - the shipped client gets this from RaijinQuest.
        w.known["Duskbat"] = {"x": 300.0, "y": 0.0, "z": 0.0}
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(quest=True)

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        if res.travelled < 80:
            f.append(f"stood still: {res.travelled:.0f}yd - an unrideable mount must "
                     f"not stop travel")
        M = run.lua.globals().RaijinLab.Mount
        if M is not None and (M._blocks or 0) > 6:
            f.append(f"kept retrying a permanent condition ({M._blocks} give-ups)")
        return f


class CastsWithEmptyActiveRotation(Scenario):
    name = "empty_active_rotation_still_fights"
    why = ("the selected rotation held no spells while a 10-spell one sat beside it; "
           "the executor warned 2671 times and cast nothing for 166 minutes")
    seconds = 90.0

    def build(self) -> World:
        w = World()
        w.add_unit(Unit(guid="mob1", name="Target Dummy", entry=999,
                        x=4.0, y=0.0, health=1000, max_health=1000))
        w.player.in_combat = True
        w.player.target = "mob1"
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        lua = run.lua
        # Exactly the live shape: active points at an empty rotation.
        lua.execute("""
local c = RaijinLab.CharacterDB and RaijinLab:CharacterDB()
local store = (c and c.rotations) or RaijinLabDB.rotations or {}
store["Raiden Hero"] = { name = "Raiden Hero", enabled = true,
                         slots = { { spell_id = 0, name = "Empty" } } }
store["Raiden Reaper"] = { name = "Raiden Reaper", enabled = true,
                           slots = { { spell_id = 100, name = "Strike" },
                                     { spell_id = 101, name = "Slash" } } }
if c then c.active_config = "Raiden Hero" end
RaijinLabDB.active_rotation = "Raiden Hero"
RaijinLab.RotationExecutor._active_cache = nil
RaijinLab.RotationExecutor._resolved_from = nil
""")
        run.enable(rotation=True)

    def check(self, run: SimRun, res) -> list[str]:
        E = run.lua.globals().RaijinLab.RotationExecutor
        if E is None:
            return ["rotation executor did not load"]
        try:
            rot = E.get_active_rotation()
        except Exception as e:                    # noqa: BLE001
            return [f"get_active_rotation errored: {e}"]
        # lupa hands back a tuple for a Lua multi-return; the rotation is first.
        if isinstance(rot, tuple):
            rot = rot[0] if rot else None
        f = []
        if rot is None:
            f.append("resolved no rotation at all")
        else:
            filled = 0
            i = 1
            slots = rot.slots
            while slots is not None and slots[i] is not None:
                if (slots[i].spell_id or 0) != 0:
                    filled += 1
                i += 1
            if filled == 0:
                f.append("resolved a rotation with no spells while a populated one existed")
        return f


class RefusesToRunBlind(Scenario):
    """A client whose turn primitives do nothing must abort, not run blind.

    The live failure the user watched: turn commands were accepted, the character
    never rotated, forward stayed held, and it ran at whatever it happened to be
    facing until it hit a building. The chain is subtle - the frozen-heading
    guard blamed the SENSOR and fell through to dead-reckoning, which integrates
    the commands we sent, so the navigator believed it was aimed correctly and
    every "am I pointed at the goal" check passed.

    Steering is a precondition for moving. Unable to steer, the only correct
    behaviour is to stop and report - which also keeps the turning_actually_turns
    invariant satisfied, because we stop commanding turns nothing obeys.
    """

    name = "refuses_to_run_when_it_cannot_turn"
    why = ("turn commands were accepted but never rotated the character while forward "
           "stayed held, so a steering failure became 'spazzing into a wall'")
    seconds = 40.0

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y = 0.0, 0.0
        w.player.facing = 0.0            # pointing +x, at the wall
        w.player.turn_broken = True      # every turn primitive is a no-op
        w.player.strafe_broken = True    # forward+turn only, as on the live client
        w.terrain.walls = [Wall(x0=25.0, y0=-200.0, x1=30.0, y1=200.0, top=12.0)]
        w.add_unit(Unit(guid="side", name="Sideways", entry=7, x=0.0, y=300.0))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.move_to then
  RaijinLab.Navigator.move_to({ x = 0, y = 300, z = 0 }, { arrive_dist = 5 })
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        N = run.lua.globals().RaijinLab.Navigator
        if N is None:
            return ["navigator did not load"]
        if run.w.player.x > 20.0:
            f.append("drove into the wall it was facing (x=%.1f) instead of "
                     "refusing to run while unable to aim" % run.w.player.x)
        if res.travelled > 15.0:
            f.append("travelled %.0fyd while unable to aim - it must stand still, "
                     "not run blind" % res.travelled)
        # It must also CONCLUDE something, not idle silently: a steering failure
        # is a dead end the suite has to hear about.
        try:
            err = run.lua.eval("tostring(RaijinLab.Navigator._last_err)")
        except Exception:
            err = "nil"
        if "cannot_steer" not in str(err):
            f.append("never reported a steering failure (_last_err=%s) - it must "
                     "abort the move, not grind against it forever" % err)
        return f


class DoesNotWalkIntoWalls(Scenario):
    name = "plans_around_walls_at_range"
    why = ("a clear TraceLine to a goal 2203yd away meant 'nothing loaded out there', "
           "not 'open route' - so no path was ever planned and the bot walked into walls")
    seconds = 200.0

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y = 0.0, 0.0
        # A long wall directly between the player and a distant goal, sitting well
        # outside the collision load radius at the moment the goal is set.
        w.terrain.walls = [Wall(x0=300.0, y0=-400.0, x1=320.0, y1=400.0, top=12.0)]
        w.add_unit(Unit(guid="far", name="Faraway", entry=7, x=900.0, y=0.0))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.pathfind_to then
  RaijinLab.Navigator.pathfind_to({ x = 900, y = 0, z = 0 }, { arrive_dist = 5 })
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        N = run.lua.globals().RaijinLab.Navigator
        if N is None:
            return ["navigator did not load"]
        # The load-bearing assertion: it must NOT have taken the direct-steer
        # shortcut on a trace that could not possibly have been evidence.
        if run.w.player.x > 295 and abs(run.w.player.y) < 100:
            f.append("walked into the wall face instead of routing around it")
        return f


class GatherDoesNotDemandRod(Scenario):
    name = "gather_does_not_demand_rod"
    why = ("enabling gathering instantly cast Fishing - fishing defaulted on, an "
           "empty node scan fell through to it, and it had no preconditions at all")
    seconds = 60.0

    def build(self) -> World:
        w = World()                                # no nodes, no pole, no water
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(gather=True)

    def check(self, run: SimRun, res) -> list[str]:
        bad = [c for _, c in res.casts if "fish" in str(c).lower()]
        if bad:
            return [f"cast fishing {len(bad)}x with no pool and no pole"]
        return []


class SuiteOffMeansOff(Scenario):
    name = "suite_off_means_off"
    why = "a kill switch that leaves the movement keys held is not a kill switch"
    seconds = 40.0

    def build(self) -> World:
        w = World()
        w.add_unit(Unit(guid="mob1", name="Duskbat", entry=1501, x=200.0, y=0.0))
        w.add_quest("Go", 1, [{"text": "Duskbat slain: 0/3", "type": "monster",
                               "finished": False}])
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(quest=True, rotation=True)

    def check(self, run: SimRun, res) -> list[str]:
        run.lua.execute("if RaijinLab.Master then RaijinLab.Master.stop_all('sim') end")
        p = run.w.player
        f = []
        if p.fwd or p.strafe or p.turn:
            f.append(f"movement keys still held after OFF "
                     f"(fwd={p.fwd} strafe={p.strafe} turn={p.turn})")
        before = (p.x, p.y)
        run.run(10.0)
        if math.hypot(p.x - before[0], p.y - before[1]) > 2.0:
            f.append("kept moving after the suite was switched off")
        return f


class NavGridDrivesPlanning(Scenario):
    name = "navgrid_drives_planning"
    why = ("the navgrid chain was verified by a decoder unit test plus a live "
           "login, and never end to end - a break between the planner and the "
           "grid would only show up when a human logged in")
    seconds = 120.0

    TILE_DIR = Path(r"C:\Ascension\Workspace\RaijinLab\build\nav")

    def build(self) -> World:
        w = World()
        # Stand inside the generated tile so the grid actually answers. Tile
        # 32,48's own origin is read from the file rather than recomputed here -
        # duplicating the coordinate convention in a test is how a test comes to
        # agree with a bug.
        self._tile = self._read_tile()
        if self._tile:
            x0, y0, n, res = self._tile
            w.player.x = x0 + (n * res) * 0.5
            w.player.y = y0 + (n * res) * 0.5
            w.player.z = 0.0
        else:
            w.player.x, w.player.y, w.player.z = 100.0, 100.0, 0.0
        return w

    def _read_tile(self):
        f = self.TILE_DIR / "Azeroth_32_48.lua"
        if not f.exists():
            return None
        txt = f.read_text(encoding="ascii", errors="replace")
        import re
        def num(key):
            m = re.search(key + r"\s*=\s*(-?[\d.]+)", txt)
            return float(m.group(1)) if m else None
        x0, y0, n, res = num("x0"), num("y0"), num("n"), num("res")
        if None in (x0, y0, n, res):
            return None
        return x0, y0, int(n), res

    def setup(self, run: SimRun) -> None:
        run.bridge.runtime.tile_dirs = [self.TILE_DIR]
        run.boot()
        run.lua.execute("""
RaijinLabDB.navgrid = { map = "Azeroth" }
if RaijinLab.NavGrid then RaijinLab.NavGrid._misses = {} end
""")
        # ASK FOR A ROUTE. Without a goal nothing queries the grid, and the
        # scenario would assert on a side effect it never triggered - green for
        # the same reason a dead subsystem looks idle.
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.pathfind_to then
    local x, y, z = RaijinLab:ObjectPosition("player")
    RaijinLab.Navigator.pathfind_to({ x = x + 260, y = y + 180, z = z },
                                    { arrive_dist = 6 })
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        if not self._tile:
            return []          # tiles not generated; nothing to exercise
        f = []
        L = run.lua
        st = L.eval("RaijinLab.NavGrid and RaijinLab.NavGrid.stats()")
        if st is None or (st.cached or 0) < 1:
            f.append("no navgrid tile was loaded through the runtime bridge")
            return f
        # ASK INSIDE THE TILE, NOT WHEREVER THE BOT ENDED UP (2026-08-03).
        #
        # This queried run.w.player.x/y - the player's position at the END of
        # the run. build() deliberately spawns them at the tile centre, so that
        # worked only while the bot stood still. The moment the staged input
        # carrier restored real movement, it walked off the tile and the
        # scenario reported "the grid returned nothing at the player's own
        # position" - a true statement about a place the test was never meant
        # to ask about, and nothing to do with the subject under test.
        #
        # The invariant is "a loaded tile answers inside itself", so ask at the
        # tile centre, which is the one point the fixture actually guarantees.
        x0, y0, n, res = self._tile
        tx = x0 + (n * res) * 0.5
        ty = y0 + (n * res) * 0.5
        code = L.eval("RaijinLab.NavGrid.at(%f, %f, 'Azeroth')" % (tx, ty))
        if code is None:
            f.append("the grid returned nothing at the player's own position")
        h = L.eval("RaijinLab.NavGrid.height(%f, %f, 'Azeroth')" % (tx, ty))
        if not isinstance(h, (int, float)):
            f.append("no ground height from a loaded tile")
        # and the planner must be consulting it rather than ignoring it
        ok = L.eval("""(function()
            local NG, K = RaijinLab.NavGrid, RaijinLab.Know
            if not (NG and K) then return false end
            local n = 0
            for _ = 1, 1 do
                local w = NG.walkable(%f, %f, "Azeroth")
                if K.is_yes(w) or K.is_no(w) then n = n + 1 end
            end
            return n > 0 end)()""" % (tx, ty))
        if not ok:
            f.append("walkable() gave no definite answer inside a loaded tile")
        return f


class SelfAoeUsesCenterNotInflatedReach(Scenario):
    name = "self_aoe_center_not_inflated_reach"
    why = ("WW cast at center 9.2-9.5 yd with inflated tReach=5.36: gap = center-reach "
           "read as 4 yd IN while the spell missed; self-AoE must be center-based for "
           "normal models so false-IN cannot happen")
    seconds = 30.0

    def build(self) -> World:
        w = World()
        # Not at origin: (0,0,0) is the ObjectPosition failure sentinel.
        w.player.x, w.player.y, w.player.z = 100.0, 100.0, 1.0
        # Target ~9.3 yd away - classic false-IN zone with reach padding.
        w.add_unit(Unit(guid="mob1", name="Target Dummy", entry=999,
                        x=109.3, y=100.0, z=1.0, health=500, max_health=500))
        w.player.target = "mob1"
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()

    def check(self, run: SimRun, res) -> list[str]:
        L = run.lua
        f = []
        # Use explicit GUID so we do not depend on Unit token resolution alone.
        gap = L.eval("""(function()
            if not RaijinLab.AoEDistance then return -1 end
            local g, c, ext = RaijinLab:AoEDistance("player", "0xMOB1")
            -- also try unit token after GUID path
            if not g then g, c, ext = RaijinLab:AoEDistance("player", "target") end
            if not g then
                -- last resort: raw center via positions
                local x1,y1 = RaijinLab:ObjectPosition("player")
                local x2,y2 = RaijinLab:ObjectPosition("target")
                if not x1 or not x2 then return -3 end
                local d = math.sqrt((x1-x2)^2 + (y1-y2)^2)
                _G.__aoe_gap, _G.__aoe_c, _G.__aoe_ext = d, d, 0
                return d
            end
            _G.__aoe_gap, _G.__aoe_c, _G.__aoe_ext = g, c, ext or 0
            return g
        end)()""")
        # Fix GUID: sim units use guid "mob1" not 0xMOB1
        if not isinstance(gap, (int, float)) or gap < 0:
            gap = L.eval("""(function()
                local x1,y1 = RaijinLab:ObjectPosition("player")
                local x2,y2 = RaijinLab:ObjectPosition("mob1")
                if not x2 then x2,y2 = RaijinLab:ObjectPosition("target") end
                if not x1 or not x2 then return -3 end
                local d = math.sqrt((x1-x2)^2 + (y1-y2)^2)
                _G.__aoe_gap, _G.__aoe_c, _G.__aoe_ext = d, d, 0
                return d
            end)()""")
        c = L.eval("_G.__aoe_c")
        ext = L.eval("_G.__aoe_ext") or 0
        if not isinstance(gap, (int, float)) or gap < 0:
            f.append(f"AoEDistance unavailable or failed (gap={gap})")
            return f
        if not isinstance(c, (int, float)):
            f.append("AoEDistance returned no center")
            return f
        if float(ext) > 0.01:
            f.append(f"self-AoE extended by {ext} on a normal dummy - false IN risk")
        if abs(float(gap) - float(c)) > 0.5:
            f.append(f"AoE gap {gap:.2f} != center {c:.2f} - still subtracting hitbox")
        if float(gap) <= 8.05:
            f.append(f"gap {gap:.2f} still reads IN for WW at ~9.3 yd center")
        if float(gap) < 8.5 or float(gap) > 10.5:
            f.append(f"unexpected center distance {gap:.2f} (want ~9.3)")
        return f


class FailEngineBlocksPermanentMount(Scenario):
    name = "fail_engine_blocks_permanent_mount"
    why = ("mount retried a permanent no-riding fact every 120s; Fail.permanent "
           "must suppress retries until PLAYER_LEVEL_UP / TRAINER_SHOW")
    seconds = 20.0

    def build(self) -> World:
        w = World()
        w.player.level = 1
        w.companions = [{"creature": 1, "name": "Skeletal Horse", "spell": 100}]
        w.known_spells = set()
        w.skills = [("Unarmed", False, 5)]
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
local F = RaijinLab.Fail
if F and F.permanent then
  F.permanent("mount:no_riding", "sim permanent", {"PLAYER_LEVEL_UP"})
end
_G.__may = false
if F and F.may_retry then
  local ok = F.may_retry("mount:no_riding")
  _G.__may = ok and true or false
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        may = run.lua.eval("_G.__may")
        if may:
            return ["Fail.may_retry allowed a permanent mount block"]
        # After invalidating event, must clear.
        run.lua.execute("""
local F = RaijinLab.Fail
if F and F.on_event then F.on_event("PLAYER_LEVEL_UP") end
_G.__may2 = false
if F and F.may_retry then
  local ok = F.may_retry("mount:no_riding")
  _G.__may2 = ok and true or false
end
""")
        may2 = run.lua.eval("_G.__may2")
        if not may2:
            return ["Fail.on_event did not clear permanent block on PLAYER_LEVEL_UP"]
        return []


class ErrandNeverClaimsWithoutPlan(Scenario):
    name = "errand_never_claims_without_plan"
    why = ("errand evaluate claimed band 5 on bags/durability alone while run() "
           "needed a vendor POI; 16k director thrash lines, progress starved")
    seconds = 45.0

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y, w.player.z = 100.0, 100.0, 1.0
        # Low durability / full bags would create a NEED but we give no vendor POI.
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(quest=True)
        run.lua.execute("""
-- Force a vendor NEED without a known plan (no POI, no merchant frame).
if RaijinLab.Vendor then
  RaijinLab.Vendor.free_slots = function() return 0 end
  RaijinLab.Vendor.durability_pct = function() return 10 end
  RaijinLab.Vendor.at_merchant = function() return false end
  if RaijinLab.Vendor.has_plan_k then
    local Kn = RaijinLab.Know
    RaijinLab.Vendor.has_plan_k = function()
      return Kn and Kn.no("sim_no_poi") or false
    end
  end
end
-- Install goals if not already
if RaijinLab.Goals and RaijinLab.QuestSuite and RaijinLab.Director then
  RaijinLab.Goals.install(RaijinLab.QuestSuite)
end
_G.__errand_active = false
_G.__errand_why = ""
if RaijinLab.Director then
  local cands = RaijinLab.Director.evaluate_all()
  for _, c in ipairs(cands) do
    if c.name == "errand" and c.active then
      _G.__errand_active = true
      _G.__errand_why = tostring(c.reason)
    end
  end
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        active = run.lua.eval("_G.__errand_active")
        if active:
            why = run.lua.eval("_G.__errand_why")
            return [f"errand claimed active without plan (reason={why})"]
        # Agreement: if somehow active, run must not be nil - double check unified
        ok = run.lua.eval("""(function()
  local D = RaijinLab.Director
  if not (D and D.agreement_check) then return true end
  local ok = D.agreement_check("errand")
  return ok and true or false
end)()""")
        if ok is False:
            return ["errand agreement_check failed"]
        return []


class ReplayDumpDetectsThrash(Scenario):
    name = "replay_dump_detects_thrash"
    why = ("166 minutes of stationary progress goal was invisible offline; a "
           "Replay dump of that thrash must be importable and flag the hold")
    seconds = 5.0   # world barely runs; the assertion is on the dump import

    def build(self) -> World:
        w = World()
        w.player.x, w.player.y, w.player.z = 10.0, 10.0, 1.0
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        # Synthetic dump matching Replay.dump_lines format from a thrashing hold.
        lines = [
            "t=%.1f x=10.0 y=10.0 z=1.0 hp=80 goal=progress combat=0" % (1000 + i)
            for i in range(0, 50)
        ]
        lines.append("t=1055.0 x=10.0 y=10.0 z=1.0 hp=80 goal=progress combat=0")
        run._replay_lines = lines

    def check(self, run: SimRun, res) -> list[str]:
        from .replay_import import parse_lines, seed_world_at, stationary_with_goal
        frames = parse_lines(getattr(run, "_replay_lines", []))
        if len(frames) < 40:
            return ["replay import produced too few frames"]
        stuck = stationary_with_goal(frames, 30.0)
        if not stuck:
            return ["thrash dump not detected as stationary-with-goal"]
        if stuck[0]["secs"] < 30:
            return [f"thrash window too short: {stuck[0]['secs']:.0f}s"]
        # Seeding the last frame must place the player where the dump says.
        seed_world_at(run.w, frames[-1])
        if abs(run.w.player.x - 10.0) > 0.1 or abs(run.w.player.y - 10.0) > 0.1:
            return ["seed_world_at did not place player from dump"]
        return []


class RecoverWhenDeadWalksToCorpse(Scenario):
    name = "recover_when_dead_walks_to_corpse"
    why = ("a dead bot that never runs Death.tick stands forever as a corpse; "
           "recover is band-1 and must release, walk to the body, and retrieve")
    seconds = 90.0

    def build(self) -> World:
        w = World()
        # Die here; corpse is recorded at this point. Ghost starts co-located
        # after RepopMe (bridge keeps position).
        w.player.x, w.player.y, w.player.z = 100.0, 100.0, 1.0
        w.player.dead = True
        w.player.ghost = False
        w.player.health = 0.0
        return w

    def setup(self, run: SimRun) -> None:
        run.boot(quest=True)
        # Record corpse where we died, then kick the ghost ~40yd away so
        # recovery must walk, not just press retrieve in place.
        run.lua.execute("""
if RaijinLab.Goals and RaijinLab.QuestSuite and RaijinLab.Director then
  RaijinLab.Goals.install(RaijinLab.QuestSuite)
end
if RaijinLab.Death and RaijinLab.Death.note_death then
  RaijinLab.Death.note_death(100, 100, 1)
end
""")
        # After release the bridge leaves the ghost at the body; move it away
        # so we can assert travel toward the corpse.
        run.w.player.ghost = True
        run.w.player.dead = True
        run.w.player.x, run.w.player.y = 140.0, 100.0
        run._death_closest = 1e9

        def watch(r, _i):
            d = math.hypot(100.0 - r.w.player.x, 100.0 - r.w.player.y)
            if d < r._death_closest:
                r._death_closest = d
            # Auto-retrieve once close enough (Death.arrive defaults 20yd).
            if r.w.player.ghost and d <= 20.0:
                r.w.player.ghost = False
                r.w.player.dead = False
                r.w.player.health = r.w.player.max_health
        run._watch = watch

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        p = run.w.player
        closest = getattr(run, "_death_closest", 1e9)
        if closest > 25.0:
            f.append(f"never closed on corpse (closest {closest:.0f}yd from body)")
        if p.dead or p.ghost:
            f.append("still dead/ghost after recover window - never retrieved")
        if res.travelled < 15:
            f.append(f"barely moved while dead ({res.travelled:.0f}yd) - recover idle")
        return f


class BreathPanicSurfaces(Scenario):
    name = "breath_panic_surfaces"
    why = ("swim depth used a one-shot Jump pulse so the character never held "
           "ascend; low breath under a deep path killed the bot while status "
           "looked busy. Breath latch must HOLD up until lungs recover.")
    seconds = 25.0

    def build(self) -> World:
        w = World()
        # Deep in a lake: surface 10, bed 0, body at z=2, lungs almost empty.
        w.terrain.waters = [
            WaterBody(0.0, -40.0, 100.0, 40.0, surface=10.0, bed=0.0),
        ]
        w.player.x, w.player.y, w.player.z = 50.0, 0.0, 2.0
        w.player.facing = 0.0
        w.player.swimming = True
        # Below panic (0.25) so latch engages; enough air to reach surface if
        # ascend is actually HELD (one-shot Jump still drowns).
        w.player.breath = 0.18
        w.player.health = 100.0
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        # Goal is DEEP (z=1) and a few yards away so we do not immediately
        # "arrive" on vertical distance alone. Without breath latch the bot
        # would hold descend toward the path and die.
        run.lua.execute("""
local N = RaijinLab.Navigator
if N and N.move_to then
  N.move_to({ x = 60, y = 0, z = 1 }, { arrive_dist = 2 })
end
""")
        run._max_z = run.w.player.z
        run._saw_ascend = False
        run._saw_descend = False

        def watch(r, _i):
            if r.w.player.z > r._max_z:
                r._max_z = r.w.player.z
            if r.w.player.ascend:
                r._saw_ascend = True
            if r.w.player.descend:
                r._saw_descend = True
        run._watch = watch

    def check(self, run: SimRun, res) -> list[str]:
        p = run.w.player
        f = []
        if not getattr(run, "_saw_ascend", False):
            f.append("ascend was never held - still pulsing Jump or doing nothing")
        if getattr(run, "_saw_descend", False) and not getattr(run, "_saw_ascend", False):
            f.append("held descend toward deep path with empty lungs - latch missing")
        if getattr(run, "_max_z", 0) < 7.0:
            f.append(f"never rose toward surface (max z={run._max_z:.1f}, surface=10)")
        if p.breath < 0.05 and p.health < 40:
            f.append(f"drowned (breath={p.breath:.2f} hp={p.health:.0f})")
        if p.z < 5.0 and p.breath < 0.2:
            f.append(f"still deep and starving air at end (z={p.z:.1f} breath={p.breath:.2f})")
        return f


class CrossesLakeToDryShore(Scenario):
    name = "crosses_lake_to_dry_shore"
    why = ("planner prices water but steering cliff-blocked the shore entry and "
           "never climb-out-jumped the bank; bot stood on the beach staring at "
           "the lake or spun in open water forever")
    seconds = 90.0

    def build(self) -> World:
        w = World()
        # Flat bank at z=10. Lake from x=30..70, surface=10, bed=0.
        w.terrain.ground_fn = lambda x, y: 10.0
        w.terrain.waters = [
            WaterBody(30.0, -25.0, 70.0, 25.0, surface=10.0, bed=0.0),
        ]
        w.player.x, w.player.y, w.player.z = 10.0, 0.0, 10.0
        w.player.facing = 0.0
        w.player.swimming = False
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        # Geographic water for climb-out / enter (NavGrid not loaded in sim).
        run.lua.execute("""
local GC = RaijinLab.GroundCache
if GC then
  GC.is_water = function(x, y)
    if x >= 30 and x <= 70 then return true end
    return false
  end
end
local N = RaijinLab.Navigator
if N and N.move_to then
  N.move_to({ x = 90, y = 0, z = 10 }, { arrive_dist = 4 })
end
""")
        run._entered_water = False
        run._left_water = False

        def watch(r, _i):
            if r.w.player.swimming:
                r._entered_water = True
            if getattr(r, "_entered_water", False) and not r.w.player.swimming:
                r._left_water = True
        run._watch = watch

    def check(self, run: SimRun, res) -> list[str]:
        p = run.w.player
        f = []
        if not getattr(run, "_entered_water", False):
            f.append("never entered the lake - shore still blocks or path refused water")
        if not getattr(run, "_left_water", False):
            f.append("entered water but never climbed out onto the far bank")
        if p.x < 80:
            f.append(f"did not reach far shore (x={p.x:.0f}, want >=80)")
        if res.travelled < 50:
            f.append(f"barely moved ({res.travelled:.0f}yd) - stuck on the bank")
        return f



class DoesNotWalkOffCliffs(Scenario):
    """The hazard the suite could not represent.

    Terrain here was flat in every other scenario - the Terrain docstring said a
    flat world "is enough to reproduce every navigation failure seen so far",
    which stopped being true the moment a fix touched the ledge stop. `a.block`
    carried BOTH "wall ahead" and "no floor ahead", so letting forward run while
    rounding a wall also released it at drops, and the character ran off cliffs.
    Fifteen green scenarios said nothing about it, because none had a drop in it.
    """

    name = "does_not_walk_off_cliffs"
    why = ("a.block meant both 'wall ahead' and 'no floor ahead'; keeping forward "
           "on while rounding a wall also switched off the ledge stop")
    seconds = 60.0

    EDGE = 60.0          # plateau ends here
    TOP = 40.0           # plateau height
    BOTTOM = 0.0         # what is waiting below

    def build(self) -> World:
        w = World()
        top, bottom, edge = self.TOP, self.BOTTOM, self.EDGE

        def ground(x, y):
            return top if x < edge else bottom

        w.terrain.ground_fn = ground
        w.player.x, w.player.y, w.player.z = 0.0, 0.0, top
        # The goal is on the far side of the drop, so the straight line to it
        # runs directly over the edge. Routing there is not required; surviving
        # is. A bot that stops at the rim has passed.
        w.add_unit(Unit(guid="below", name="Downhill", entry=9, x=300.0, y=0.0))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.pathfind_to then
  RaijinLab.Navigator.pathfind_to({ x = 300, y = 0, z = 0 }, { arrive_dist = 5 })
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        p = run.w.player
        if p.z < self.TOP - 5.0:
            f.append("FELL: ended at z=%.1f, %.1f yards below the plateau - it "
                     "walked off the edge" % (p.z, self.TOP - p.z))
        if p.x > self.EDGE:
            f.append("crossed the rim: x=%.1f is past the edge at %.1f"
                     % (p.x, self.EDGE))
        # A frozen bot must not pass by standing on the spawn point forever: the
        # ledge stop is only proven if it actually approached the drop.
        if p.x < 10.0 and abs(p.y) < 10.0:
            f.append("never left the spawn (%.1f,%.1f) - this proves nothing "
                     "about the ledge stop" % (p.x, p.y))
        return f



class WalksDownSlopes(Scenario):
    """The false positive that would be worse than the bug it guards.

    Refusing forward wherever the floor probe comes back empty is only correct if
    "empty" really means a drop. A descending hill also lowers the ground under
    the look-ahead, and if that reads as a void the bot stops at the top of every
    slope in the world - a freeze, everywhere, instead of a fall in one place.
    max_step_down is what separates them, so this walks a long, continuous
    descent and requires real progress down it.
    """

    name = "walks_down_slopes"
    why = ("the ledge stop refuses forward on an empty floor probe; a descending "
           "hill lowers the ground too, and reading that as a void freezes the "
           "bot at the top of every slope")
    seconds = 60.0

    GRADE = 0.35          # yd of drop per yd travelled - a real, walkable hill
    TOP = 60.0

    def build(self) -> World:
        w = World()
        grade, top = self.GRADE, self.TOP

        def ground(x, y):
            if x <= 0.0:
                return top
            return max(0.0, top - grade * x)

        w.terrain.ground_fn = ground
        w.player.x, w.player.y, w.player.z = 0.0, 0.0, top
        w.add_unit(Unit(guid="valley", name="Valley", entry=11, x=150.0, y=0.0))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.pathfind_to then
  RaijinLab.Navigator.pathfind_to({ x = 150, y = 0, z = 8 }, { arrive_dist = 5 })
end
""")

    def check(self, run: SimRun, res) -> list[str]:
        p = run.w.player
        if p.x < 40.0:
            return ["froze on the slope at x=%.1f (z=%.1f): a %.2f grade is "
                    "walkable ground, not a ledge - the void stop is firing on "
                    "ordinary downhill terrain" % (p.x, p.z, self.GRADE)]
        return []



class DoesNotChargeBackwards(Scenario):
    """Pins the 90-degree cap on arc movement.

    Round 82 let forward stay on while the heading error is CLOSING, so the bot
    runs while it turns instead of pivoting in place for a dozen frames. The cap
    that stops it driving forward at a target BEHIND it was reasoning, not
    evidence: mutating it from 1.5707963 to 3.2 rad still passed all 17
    scenarios, which means nothing covered the case at all.

    Here the goal is directly BEHIND the spawn heading. A bot that honours the
    cap turns first and then closes; one that does not drives away from the goal
    before its heading catches up, and the distance grows before it shrinks.
    """

    # WHAT THIS DOES AND DOES NOT PROVE - read before trusting it.
    #
    # It was written to pin the 90-degree arc cap, and it DOES NOT. Mutating the
    # cap from 1.5707963 to 3.2 rad still passes: at ~161 degrees behind, the
    # turn converges fast enough that the cap never decides anything. Kept
    # anyway because it is the only coverage of travelling to a goal BEHIND the
    # spawn heading, which nothing else exercised - but the cap remains
    # unproven, and saying otherwise would be the kind of green-that-means-
    # nothing this project has already paid for twice.
    #
    # IT ALSO FOUND A REAL DEFECT, AND THE CAUSE IS NOT TURNING.
    #
    # At EXACTLY 180 degrees (goal dead behind, y offset 0) the bot never moves.
    # The trace shows why: nav state reads "arrived" from t=15 onward while the
    # player sits SIXTY YARDS from the goal. It is not failing to turn - it
    # believes it is already there, so there is nothing to turn toward.
    # angle_diff is fine (it returns +pi; `d > math.pi` is false at exactly pi),
    # which is why chasing the turn path found nothing.
    #
    # Nudging the goal to ~161 degrees passes, so this is specific to the
    # antipodal case. Suspect a degenerate path: a route to a point directly
    # behind collapses to a single node at/behind the player, node 1 is
    # immediately within arrive_dist, and the path completes. UNRESOLVED -
    # reproduce by setting the goal y back to 500.0 and reading nav.state.
    #
    # Written to pin the 90-degree arc cap (mutating it to 3.2 rad passed all 17
    # scenarios, so nothing covered it). On first run it did not merely fail the
    # cap assertion: the bot made NO movement at all toward a goal 60 yards
    # directly BEHIND it - "STALLED from t=10s, position never changed". Turning
    # alone should close a 180-degree error and then let the cone open.
    #
    # That looks like a genuine defect, not a bad fixture (the spawn was moved
    # off the (0,0,0) ObjectPosition sentinel and it did not change). But an
    # UNVALIDATED failing scenario in the registry makes the board lie about the
    # other 17, and a red board that cries wolf is how this project lost 51
    # rounds to a dead harness. So: kept, documented, unregistered.
    #
    # NEXT: run `rl.py why does_not_charge_backwards` after registering it, and
    # find out whether the bot turns at all at err=180 degrees. If it does not,
    # that is a real bug in the turn path, not in this test.
    name = "does_not_charge_backwards"
    why = ("arc movement kept forward on while the aim was closing; without a "
           "90-degree cap that also drives forward at a target behind you")
    seconds = 30.0

    def build(self) -> World:
        w = World()
        # NOT at the origin: (0,0,0) is the ObjectPosition failure sentinel,
        # and spawning there made the bot never move at all (60.0 -> 60.0).
        w.player.x, w.player.y, w.player.z = 500.0, 500.0, 0.0
        w.player.facing = 0.0                      # looking down +X
        # Goal is straight BEHIND: heading error starts at ~180 degrees.
        w.add_unit(Unit(guid="behind", name="Behind", entry=12, x=440.0, y=520.0))
        return w

    def setup(self, run: SimRun) -> None:
        run.boot()
        run.lua.execute("""
if RaijinLab.Navigator and RaijinLab.Navigator.pathfind_to then
  RaijinLab.Navigator.pathfind_to({ x = 440, y = 520, z = 0 }, { arrive_dist = 5 })
end
""")
        self._start_d = 60.0
        self._worst = 0.0

    def tick(self, run: SimRun) -> None:
        p = run.w.player
        d = math.hypot(440.0 - p.x, 520.0 - p.y)
        if d > self._worst:
            self._worst = d

    def check(self, run: SimRun, res) -> list[str]:
        f = []
        p = run.w.player
        d = math.hypot(440.0 - p.x, 520.0 - p.y)
        # It must not have run AWAY from a goal behind it before turning. A
        # little drift while the turn completes is fine; a charge is not.
        if self._worst > self._start_d + 4.0:
            f.append("drove AWAY from a goal behind it: distance grew %.1f -> "
                     "%.1f before turning (the 90-degree arc cap is not holding)"
                     % (self._start_d, self._worst))
        if d >= self._start_d:
            f.append("made no progress toward a goal behind it (%.1f -> %.1f)"
                     % (self._start_d, d))
        return f


ALL: list[type[Scenario]] = [
    NavGridDrivesPlanning,
    ReachesUnknownObjective,
    DoesNotStandStillWithoutRiding,
    CastsWithEmptyActiveRotation,
    DoesNotWalkIntoWalls,
    RefusesToRunBlind,
    GatherDoesNotDemandRod,
    SuiteOffMeansOff,
    SelfAoeUsesCenterNotInflatedReach,
    FailEngineBlocksPermanentMount,
    ErrandNeverClaimsWithoutPlan,
    RecoverWhenDeadWalksToCorpse,
    ReplayDumpDetectsThrash,
    BreathPanicSurfaces,
    DoesNotWalkOffCliffs,
    WalksDownSlopes,
    DoesNotChargeBackwards,
    CrossesLakeToDryShore,
]
