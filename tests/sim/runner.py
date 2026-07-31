"""Load the REAL addon into a simulated world and run it for simulated hours.

The point is not to test the simulator. The point is that the code under test is
the same code that ships - loaded from addon/, in TOC order, driven through its
own tickers. A scenario that passes here is a claim about the shipping bot.

What a run produces is not just pass/fail but a TRACE: distance travelled, casts
attempted, contract violations, which runtime calls were never made. "The bot did
not crash" is not the bar - seven subsystems once ran for 166 minutes without
crashing and without doing anything.
"""
from __future__ import annotations

import math
from pathlib import Path

from .bridge import Bridge
from .world import World

ROOT = Path(__file__).resolve().parent.parent.parent
ADDON = ROOT / "addon"

# Loaded in dependency order. UI, minimap and editor files are skipped: they need
# a real frame/texture stack and none of them decide whether the bot moves.
SKIP = {
    "core/UI.lua", "core/Menu.lua", "core/MinimapIcon.lua", "core/StatusUI.lua",
    "core/Drawing.lua", "core/rotation/Editor.lua", "core/TurnDiag.lua",
    "core/Surveyor.lua", "core/Instrument.lua", "core/Hooks.lua",
}


def toc_order() -> list[str]:
    """Read load order from the TOC so the simulator can never drift out of sync
    with what the client actually loads."""
    toc = (ADDON / "RaijinLab.toc").read_text(encoding="utf-8", errors="replace")
    out = []
    for line in toc.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().endswith(".lua"):
            rel = line.replace("\\", "/")
            # SKIP VENDORED THIRD-PARTY DATA. addon/RaijinQuest is pfQuest plus
            # the Ascension pack, renamed and moved in-tree. Its 12MB of database
            # tables are loaded by XML manifests the client processes and this
            # harness does not, so the .lua entries here would run against
            # globals that do not exist yet (RaijinQuestDB, GetAddOnMetadata).
            # It is DATA, not logic under test - our adapter (QuestDB.lua) is the
            # thing with behaviour, and scenarios mock the lookups.
            if "RaijinQuest/" in rel:
                continue
            out.append(rel)
    return out


class SimRun:
    def __init__(self, world: World, *, modules: list[str] | None = None, quiet: bool = True):
        from lupa import LuaRuntime

        self.w = world
        self.lua = LuaRuntime(unpack_returned_tuples=False)
        # Seed it. Nothing in the simulator seeded Lua, so any math.random in
        # the addon varied per run: the same tree scored 6/7 then 7/7. A
        # scenario harness that disagrees with itself cannot tell you whether
        # a change helped, and a flaky red trains you to ignore it.
        self.lua.execute("math.randomseed(42)")
        self.quiet = quiet
        self.printed: list[str] = []
        self.load_errors: list[tuple[str, str]] = []

        self.lua.execute("RaijinLab = {}")
        self.lua.execute("RaijinLabDB = { modules = {} }")
        self.bridge = Bridge(self.lua, world)
        self.bridge.install()

        cap = self.printed
        def _print(*a):
            cap.append(" ".join(str(x) for x in a))
        self.lua.globals()["print"] = _print

        self.modules = modules if modules is not None else [
            m for m in toc_order() if m not in SKIP
        ]
        self._load()

    # ---------------------------------------------------------------- load
    def _load(self) -> None:
        NL = chr(10)
        for rel in self.modules:
            path = ADDON / rel
            if not path.exists():
                self.load_errors.append((rel, "missing"))
                continue
            src = path.read_text(encoding="utf-8", errors="replace")
            try:
                # WoW passes (addonName, addonTable) as `...` to every addon file,
                # and some use it at file scope - so the wrapper must be a vararg
                # function or those files fail to even parse.
                self.lua.execute("__m = (function(...)" + NL + src + NL +
                                 'end)("RaijinLab", __sim_addon_tbl)')
            except Exception as e:                       # noqa: BLE001
                self.load_errors.append((rel, str(e).split(NL)[0][:160]))

    # ----------------------------------------------------------------- run
    def enable(self, **modules) -> None:
        db = self.lua.globals().RaijinLabDB
        for k, v in modules.items():
            db.modules[k] = bool(v)

    def fire(self, event: str, *args) -> None:
        self.lua.globals()["__sim_fire"](event, *args)

    def boot(self, **modules) -> None:
        """Run the real login sequence, then start the requested modules.

        Setting RaijinLabDB.modules flags is NOT enough and assuming otherwise
        produced a 0yd run: the flags say what SHOULD run, while the tickers that
        actually run it are created by each module's start(). The client creates
        them in response to login events, so the simulator has to fire those too
        or it tests a bot that was never switched on.
        """
        for ev, args in (
            ("ADDON_LOADED", ("RaijinLab",)),
            ("VARIABLES_LOADED", ()),
            ("PLAYER_LOGIN", ()),
            ("PLAYER_ENTERING_WORLD", ()),
        ):
            try:
                self.fire(ev, *args)
            except Exception:                            # noqa: BLE001
                pass
        if modules:
            self.enable(**modules)
        # THE WORLD DATABASE, IN THE SIMULATOR.
        #
        # The engine no longer guesses where anything is - with no known location
        # it parks the quest instead of sweeping a probability field. That is the
        # shipped behaviour, so a scenario that wants the bot to TRAVEL to an
        # unseen objective must supply the knowledge the real client gets from
        # RaijinQuest. `world.known` maps an objective name to a world point.
        self.lua.execute("""
RaijinLab.QuestDB = RaijinLab.QuestDB or {}
RaijinLab.QuestDB.locate = function(name, px, py)
    local k = __sim_known and __sim_known[name]
    if not k then return nil end
    local d = 0
    if px and py then d = math.sqrt((k.x - px) ^ 2 + (k.y - py) ^ 2) end
    return { x = k.x, y = k.y, z = k.z, dist = d }
end
RaijinLab.QuestDB.available = function() return true end
""")
        # Start through the master switch so the sim exercises the same path the
        # UI does, rather than a private back door.
        self.lua.execute("""
if RaijinLab.Master and RaijinLab.Master.start_all then
    RaijinLab.Master.start_all("sim")
else
    for _, m in ipairs({ RaijinLab.RotationExecutor, RaijinLab.QuestSuite,
                         RaijinLab.Gatherer, RaijinLab.Grinder, RaijinLab.CombatBrain }) do
        if m and m.start then pcall(m.start) end
    end
end
if RaijinLab.Contracts and RaijinLab.Contracts.install then
    pcall(RaijinLab.Contracts.install)
end
""")
        # The master switch turns the rotation engine on unconditionally (by
        # explicit product rule), so every scenario inherits it. A real character
        # has SOME rotation; a scenario that has not made one otherwise trips
        # rotation_can_act as pure noise. Seed a minimal valid one only when the
        # store is genuinely empty, so a scenario that sets its own still wins.
        self.lua.execute("""
local c = RaijinLab.CharacterDB and RaijinLab:CharacterDB()
local store = (c and c.rotations) or RaijinLabDB.rotations
if store then
    local has = false
    for _, r in pairs(store) do
        for _, sl in ipairs((type(r) == "table" and r.slots) or {}) do
            if (tonumber(sl.spell_id) or 0) ~= 0 then has = true end
        end
    end
    if not has then
        store["Default"] = { name = "Default", enabled = true,
                             slots = { { spell_id = 100, name = "SimStrike" } } }
        if c then c.active_config = "Default" end
        RaijinLabDB.active_rotation = "Default"
        if RaijinLab.RotationExecutor then
            RaijinLab.RotationExecutor._active_cache = nil
            RaijinLab.RotationExecutor._resolved_from = nil
        end
    end
end
""")

    def run(self, seconds: float, *, on_tick=None) -> "SimResult":
        """Advance the world and pump the addon's tickers in lockstep."""
        w = self.w
        pump = self.lua.globals()["__sim_pump"]
        steps = int(seconds / w.step)
        start = (w.player.x, w.player.y)
        travelled = 0.0
        stationary = 0
        samples = 0
        last = (w.player.x, w.player.y)
        errors: list[str] = []

        self.lua.globals()["__sim_dt"] = w.step
        # Publish what the world says the bot should KNOW, so the
        # QuestDB stub can answer without a real database.
        if getattr(w, "known", None):
            tbl = self.lua.eval("{}")
            for name, pt in w.known.items():
                e = self.lua.eval("{}")
                e["x"], e["y"], e["z"] = pt.get("x", 0.0), pt.get("y", 0.0), pt.get("z", 0.0)
                tbl[name] = e
            self.lua.globals()["__sim_known"] = tbl
        for i in range(steps):
            w.tick()
            try:
                pump(w.t)
            except Exception as e:                       # noqa: BLE001
                errors.append(str(e)[:200])
                if len(errors) > 50:
                    break
            if i % 30 == 0:                              # ~1Hz sampling
                d = math.hypot(w.player.x - last[0], w.player.y - last[1])
                travelled += d
                samples += 1
                if d < 0.5:
                    stationary += 1
                last = (w.player.x, w.player.y)
                if on_tick:
                    on_tick(self, i)

        return SimResult(
            run=self,
            seconds=seconds,
            travelled=travelled,
            stationary_pct=(100.0 * stationary / samples) if samples else 100.0,
            start=start,
            end=(w.player.x, w.player.y),
            casts=list(w.casts),
            errors=errors,
            printed=list(self.printed),
        )

    # ---------------------------------------------------------- inspection
    def contracts(self):
        C = self.lua.globals().RaijinLab.Contract
        if C is None:
            return None
        try:
            self.lua.globals().RaijinLab.Contracts.install()
        except Exception:                                # noqa: BLE001
            pass
        return C

    def diagnose(self) -> dict:
        C = self.lua.globals().RaijinLab.Contract
        if C is None:
            return {"violated": [], "ok": [], "na": []}
        d = C.diagnose()
        def names(t):
            out = []
            if t is None:
                return out
            i = 1
            while True:
                v = t[i]
                if v is None:
                    break
                out.append(v.name if hasattr(v, "name") else
                           (v["name"] if isinstance(v, dict) else str(v)))
                i += 1
            return out
        viol = []
        i = 1
        while d.violated[i] is not None:
            e = d.violated[i]
            viol.append({"name": e.name, "held": e.held, "explain": e.explain})
            i += 1
        return {"violated": viol, "ok": names(d.ok), "na": names(d.na)}


class SimResult:
    def __init__(self, *, run, seconds, travelled, stationary_pct, start, end,
                 casts, errors, printed):
        self.run = run
        self.seconds = seconds
        self.travelled = travelled
        self.stationary_pct = stationary_pct
        self.start = start
        self.end = end
        self.casts = casts
        self.errors = errors
        self.printed = printed

    @property
    def moved(self) -> float:
        return math.hypot(self.end[0] - self.start[0], self.end[1] - self.start[1])

    def called(self, name: str) -> int:
        return self.run.bridge.calls.get(name, 0)

    def summary(self) -> str:
        return (f"{self.seconds:.0f}s sim | travelled {self.travelled:.0f}yd | "
                f"net {self.moved:.0f}yd | stationary {self.stationary_pct:.0f}% | "
                f"casts {len(self.casts)} | errors {len(self.errors)}")
