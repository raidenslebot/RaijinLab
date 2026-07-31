"""A simulated Azeroth, good enough to be wrong in the ways the real one is.

Every bug this project shipped was found by a human playing for an hour and then
someone reading a log backwards. That loop cannot scale and it cannot run at 3am.
This module is the world half of the fix: enough of a game that the REAL addon Lua
can be run against it, headless, for simulated hours.

The design rule that matters, learned from the bugs it exists to catch:

    THE SIMULATOR MUST REPRODUCE THE CLIENT'S IGNORANCE, NOT JUST ITS KNOWLEDGE.

A world that answers every question perfectly cannot reproduce a single one of the
real failures, because every one of them was the bot MISREADING AN ABSENCE:
  - TraceLine over a 2203yd gap returned "clear" - nothing was loaded out there
  - an objective was "not remembered" because it had never been looked for
  - a mount was owned but not rideable
  - a rotation existed but held no spells
So collision here is only loaded within a radius, objects are only visible within
render range, and a query outside those bounds returns the same shrug the client
gives - never the truth.

Coordinates are WoW-like: x/y ground plane, z up, facing in radians CCW from +x.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field


# The client streams collision and objects in around the player. Beyond these
# radii the world does not answer "no" - it answers nothing, and code that reads
# that as "no" is the bug we are hunting.
COLLISION_LOAD_RADIUS = 250.0
RENDER_RADIUS = 200.0


@dataclass
class Wall:
    """An axis-aligned solid box. Crude on purpose: precise geometry is not what
    catches navigation bugs, blocking geometry is."""
    x0: float
    y0: float
    x1: float
    y1: float
    top: float = 5.0
    bottom: float = 0.0

    def contains(self, x: float, y: float, z: float | None = None) -> bool:
        if not (min(self.x0, self.x1) <= x <= max(self.x0, self.x1)):
            return False
        if not (min(self.y0, self.y1) <= y <= max(self.y0, self.y1)):
            return False
        if z is None:
            return True
        return self.bottom <= z <= self.top

    def segment_hit(self, x0, y0, z0, x1, y1, z1, steps: int = 64):
        """First hit along a segment, or None. Sampled rather than solved - the
        error is bounded by step size and that is fine for a blocking test."""
        for i in range(1, steps + 1):
            t = i / steps
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            z = z0 + (z1 - z0) * t
            if self.contains(x, y, z):
                return x, y, z
        return None


@dataclass
class Unit:
    guid: str
    name: str
    entry: int = 0
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    level: int = 1
    health: float = 100.0
    max_health: float = 100.0
    hostile: bool = True
    dead: bool = False
    otype: int = 3                      # 3 = unit, 5 = gameobject
    tied_to_quest: bool = False
    respawn_at: float | None = None
    spawn_x: float = 0.0
    spawn_y: float = 0.0
    # Quest-giver dialog status (3.3.5 GetQuestInteractType enum): 8 = yellow "!"
    # available, 10 = yellow "?" turn-in, 0/None = not a giver. See
    # giver_status_flaky for why this is not simply read back verbatim.
    giver_status: int = 0
    # THE READ IS INTERMITTENT, THE GIVER IS NOT. The live client only answers
    # GetQuestInteractType while an npc's status is currently resolved: measured
    # asked=7154 nonzero=450, i.e. a real yellow-! giver reads as 0 on ~94% of
    # ticks. Modelling that is the whole point - with a perfect sensor the bug it
    # caused (progress_step flipping accept<->objective ~3x/sec, never closing the
    # last 21 yards) is unreproducible.
    giver_status_flaky: int = 1          # answer honestly 1 call in N


@dataclass
class WaterBody:
    """Axis-aligned water volume. surface is the liquid free surface; bed is the
    solid floor the client's TraceGround hits (no liquid bit). A character is
    swimming when inside the XY and between bed and surface."""
    x0: float
    y0: float
    x1: float
    y1: float
    surface: float = 10.0
    bed: float = 0.0

    def contains_xy(self, x: float, y: float) -> bool:
        return (min(self.x0, self.x1) <= x <= max(self.x0, self.x1)
                and min(self.y0, self.y1) <= y <= max(self.y0, self.y1))

    def contains(self, x: float, y: float, z: float) -> bool:
        if not self.contains_xy(x, y):
            return False
        return self.bed - 0.1 <= z <= self.surface + 0.5


@dataclass
class Terrain:
    """Ground height plus solid boxes. A flat world with walls is enough to
    reproduce every navigation failure seen so far; a heightmap hook is here so
    slope handling can be exercised later."""
    walls: list[Wall] = field(default_factory=list)
    ground_fn = None                    # optional (x, y) -> z
    waters: list[WaterBody] = field(default_factory=list)

    def ground_z(self, x: float, y: float) -> float:
        # Under water the solid floor is the bed (matches client TraceGround).
        for w in self.waters:
            if w.contains_xy(x, y):
                return float(w.bed)
        if self.ground_fn:
            return float(self.ground_fn(x, y))
        return 0.0

    def water_at(self, x: float, y: float, z: float | None = None) -> WaterBody | None:
        for w in self.waters:
            if z is None:
                if w.contains_xy(x, y):
                    return w
            elif w.contains(x, y, z):
                return w
        return None

    def blocked_at(self, x: float, y: float, z: float) -> bool:
        return any(w.contains(x, y, z) for w in self.walls)

    def trace(self, x0, y0, z0, x1, y1, z1):
        """Returns (blocked, hx, hy, hz).

        THE IMPORTANT PART: a ray that leaves the loaded collision radius stops
        being evidence. Past that we report 'clear' exactly as the real client
        does - not because the way is open, but because nothing is loaded to hit.
        This single behaviour is what reproduces the walks-straight-into-walls
        bug, and a simulator without it would have certified that bug as fixed.
        """
        seg = math.hypot(x1 - x0, y1 - y0)
        limit = COLLISION_LOAD_RADIUS
        if seg > limit:
            t = limit / seg
            x1 = x0 + (x1 - x0) * t
            y1 = y0 + (y1 - y0) * t
            z1 = z0 + (z1 - z0) * t
        best = None
        best_d = None
        for w in self.walls:
            hit = w.segment_hit(x0, y0, z0, x1, y1, z1)
            if hit:
                d = math.hypot(hit[0] - x0, hit[1] - y0)
                if best_d is None or d < best_d:
                    best, best_d = hit, d

        # THE GROUND IS SOLID TOO. Testing only walls left the world with no floor
        # for a downward probe to hit, so TraceGround always answered "nothing
        # within reach" - which the Navigator correctly reads as a ledge and
        # refuses to walk off. The simulated bot then stood still forever while
        # looking perfectly healthy, for a reason that does not exist in the real
        # game. A terrain model without terrain is not a conservative simplification.
        steps = 48
        for i in range(1, steps + 1):
            t = i / steps
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            z = z0 + (z1 - z0) * t
            gz = self.ground_z(x, y)
            if z <= gz:
                d = math.hypot(x - x0, y - y0)
                if best_d is None or d < best_d:
                    best, best_d = (x, y, gz), d
                break

        if best:
            return True, best[0], best[1], best[2]
        return False, x1, y1, z1


@dataclass
class Player:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    facing: float = 0.0
    level: int = 1
    name: str = "Simtest"
    realm: str = "Simrealm - Season 1"
    health: float = 100.0
    max_health: float = 100.0
    power: float = 100.0
    max_power: float = 100.0
    in_combat: bool = False
    dead: bool = False
    ghost: bool = False          # released spirit; UnitIsGhost
    mounted: bool = False
    swimming: bool = False
    indoors: bool = False
    # Reproduces the live client where the turn primitives are ACCEPTED but do
    # not rotate the character (keyboard turning on this Ascension build).
    turn_broken: bool = False
    # Strafe as well: live the character had only forward+turn, and letting the
    # sim sidestep to the goal hides every steering failure behind it.
    strafe_broken: bool = False
    casting: str | None = None
    cast_ends: float = 0.0
    cast_uninterruptible: bool = False
    # Power keyed BY INDEX (0=mana,1=rage,2=focus,3=energy,6=runic). A max of 0
    # means the pool does NOT EXIST for this character - the absent-pool guards
    # depend on that being distinguishable from "empty".
    power_type: int = 0
    powers: dict = field(default_factory=lambda: {0: 100.0})
    power_max: dict = field(default_factory=lambda: {0: 100.0})
    # held movement inputs, exactly as the runtime bridge sets them
    fwd: bool = False
    strafe: int = 0                     # -1 left, +1 right
    turn: int = 0                       # -1 right, +1 left (CCW positive)
    ascend: bool = False                # JumpOrAscend held
    descend: bool = False               # SitStandOrDescend held
    target: str | None = None
    breath: float = 1.0                 # 0..1 remaining; only drains submerged

    RUN_SPEED = 7.0                     # yd/s, 3.3.5 base run
    SWIM_SPEED = 4.5                    # yd/s horizontal while swimming
    SWIM_VERT = 3.5                     # yd/s ascend/descend while swimming
    MOUNT_MULT = 2.0
    TURN_RATE = 3.1                     # rad/s, the client's fixed keyboard turn
    # ~20s of air when full (client is longer; compressed so scenarios finish).
    BREATH_DRAIN = 0.05                 # fraction per second fully submerged
    BREATH_RECOVER = 0.35               # fraction per second at/above surface


class World:
    """The simulated world plus its clock. Advanced in fixed steps so a run is
    deterministic and reproducible from a seed - a bug that only shows up once is
    not a bug you can fix."""

    def __init__(self, *, seed: int = 1, step: float = 1.0 / 30.0):
        self.t = 1000.0
        self.step = step
        self.seed = seed
        self._rng = seed
        self.player = Player()
        self.terrain = Terrain()
        self.units: dict[str, Unit] = {}
        # Objective name -> {x,y,z}: the simulator's stand-in for what
        # RaijinQuest ships. The engine no longer guesses, so a scenario
        # that wants the bot to travel to an unseen objective must state
        # what it is supposed to KNOW.
        self.known: dict = {}
        self.quests: list[dict] = []
        self.bags: list[list[dict | None]] = [[None] * 16 for _ in range(5)]
        self.equipped: dict[int, str] = {}
        # link -> {name,type,subtype,...} for equipped/known items, so a
        # fishing pole can be distinguished from a sword by SUBTYPE.
        self.item_meta: dict[str, dict] = {}
        self.spells: dict[int, str] = {}
        self.known_spells: set[int] = set()
        self.companions: list[dict] = []
        self.skills: list[tuple[str, bool, int]] = []
        self.casts: list[tuple[float, str]] = []
        self.events: list[tuple[str, tuple]] = []
        self.merchant_open = False
        # Quest dialog state, so accept / turn-in can actually be simulated.
        self.quest_frame: dict = {}
        self.quest_events: list[str] = []
        self.log: list[str] = []

    # ---- deterministic randomness (no Math.random from the harness) --------
    def rand(self) -> float:
        self._rng = (1103515245 * self._rng + 12345) % (1 << 31)
        return self._rng / float(1 << 31)

    # ---- visibility -------------------------------------------------------
    def visible_units(self) -> list[Unit]:
        """Only what is in render range. Objects outside it are not 'absent' -
        they are unknown, and the bot must go and look."""
        p = self.player
        out = []
        for u in self.units.values():
            if u.dead:
                continue
            if math.hypot(u.x - p.x, u.y - p.y) <= RENDER_RADIUS:
                out.append(u)
        return out

    def unit(self, guid: str) -> Unit | None:
        return self.units.get(guid)

    def add_unit(self, u: Unit) -> Unit:
        u.spawn_x, u.spawn_y = u.x, u.y
        self.units[u.guid] = u
        return u

    # ---- physics ----------------------------------------------------------
    def _apply_breath(self, dt: float) -> None:
        p = self.player
        wbody = self.terrain.water_at(p.x, p.y, p.z)
        submerged = bool(wbody and p.z < (wbody.surface - 0.4))
        if submerged:
            p.breath = max(0.0, p.breath - Player.BREATH_DRAIN * dt)
            if p.breath <= 0.0:
                p.health = max(0.0, p.health - 15.0 * dt)
        else:
            p.breath = min(1.0, p.breath + Player.BREATH_RECOVER * dt)

    def _apply_movement(self, dt: float) -> None:
        p = self.player
        # A corpse (dead, not released) cannot move. A ghost CAN and MUST walk
        # back to its body - blocking that made recover_when_dead impossible to
        # exercise and would certify a permanently stranded death path.
        if p.dead and not p.ghost:
            return
        if p.turn:
            p.facing = (p.facing + p.turn * Player.TURN_RATE * dt) % (2 * math.pi)

        # Enter/leave water from position (not from the input - swimming is a
        # world fact the client reports via IsSwimming).
        w_here = self.terrain.water_at(p.x, p.y, p.z)
        if w_here and p.z <= w_here.surface + 0.2:
            p.swimming = True
        elif p.swimming:
            # Leave only when clear of the volume (or standing on dry ground).
            if not self.terrain.water_at(p.x, p.y):
                p.swimming = False
                p.z = self.terrain.ground_z(p.x, p.y)
            elif w_here is None:
                p.swimming = False

        speed = (Player.SWIM_SPEED if p.swimming
                 else Player.RUN_SPEED * (Player.MOUNT_MULT if p.mounted else 1.0))
        dx = dy = 0.0
        if p.fwd:
            dx += math.cos(p.facing) * speed * dt
            dy += math.sin(p.facing) * speed * dt
        if p.strafe:
            a = p.facing - p.strafe * (math.pi / 2)
            dx += math.cos(a) * speed * dt
            dy += math.sin(a) * speed * dt

        # Vertical: ONLY while swimming, and ONLY while the matching key is held.
        # A one-shot Jump that is not held must not keep lifting - that was the
        # weak "complete enough" lie.
        dz = 0.0
        if p.swimming:
            wbody = self.terrain.water_at(p.x, p.y) or w_here
            if wbody:
                if p.ascend and not p.descend:
                    dz = Player.SWIM_VERT * dt
                elif p.descend and not p.ascend:
                    dz = -Player.SWIM_VERT * dt

        nx, ny = p.x + dx, p.y + dy
        nz = p.z
        if p.swimming:
            wbody = self.terrain.water_at(nx, ny) or self.terrain.water_at(p.x, p.y)
            if wbody:
                nz = min(wbody.surface, max(wbody.bed + 0.5, p.z + dz))
                # Climb-out: at surface, driving onto dry land exits the water.
                if (p.ascend or p.fwd) and nz >= wbody.surface - 0.05 \
                        and not self.terrain.water_at(nx, ny):
                    p.swimming = False
                    nz = self.terrain.ground_z(nx, ny)
            else:
                p.swimming = False
                nz = self.terrain.ground_z(nx, ny)
        else:
            nz = self.terrain.ground_z(nx, ny)
            # Walk into water: next cell is a water body and feet reach the bank.
            wnext = self.terrain.water_at(nx, ny)
            if wnext and abs(nz - wnext.surface) <= 2.0:
                p.swimming = True
                nz = min(wnext.surface - 0.3, max(wnext.bed + 0.5, wnext.surface - 0.3))

        moved = (abs(dx) + abs(dy) + abs(dz)) > 1e-9
        if moved:
            if self.terrain.blocked_at(nx, ny, nz + 1.0):
                self._apply_breath(dt)
                return
            p.x, p.y, p.z = nx, ny, nz
        self._apply_breath(dt)

    def _apply_casting(self) -> None:
        p = self.player
        if p.casting and self.t >= p.cast_ends:
            p.casting = None

    def _apply_respawns(self) -> None:
        for u in self.units.values():
            if u.dead and u.respawn_at is not None and self.t >= u.respawn_at:
                u.dead = False
                u.health = u.max_health
                u.x, u.y = u.spawn_x, u.spawn_y
                u.respawn_at = None

    def tick(self, dt: float | None = None) -> None:
        dt = self.step if dt is None else dt
        self.t += dt
        self._apply_movement(dt)
        self._apply_casting()
        self._apply_respawns()

    # ---- convenience for scenarios ---------------------------------------
    def guid_hex(self, name: str) -> str:
        """Stable hex-shaped GUID. Actions.guid_of() pattern-matches ^0[xX]%x+$,
        so a friendly name is rejected outright and targeting silently fails."""
        h = 0
        for ch in str(name):
            h = (h * 131 + ord(ch)) % (1 << 48)
        return "0x%016X" % h

    def dist_to(self, x: float, y: float) -> float:
        return math.hypot(x - self.player.x, y - self.player.y)

    def put_item(self, bag: int, slot: int, item: dict) -> None:
        self.bags[bag][slot] = item

    def add_quest(self, title: str, quest_id: int, objectives: list[dict]) -> dict:
        q = {"title": title, "questId": quest_id, "objectives": objectives,
             "isComplete": None, "isHeader": False}
        self.quests.append(q)
        return q
