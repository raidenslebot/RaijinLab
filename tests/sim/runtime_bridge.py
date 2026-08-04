"""The injected runtime, as the addon actually sees it.

This is the boundary that matters, and getting it wrong silently is the single
biggest risk in the whole simulator. The addon does NOT call a rich API - it calls
ONE global:

    RaijinLab_Runtime(command, ...) -> packed string | number | boolean

and parses the result itself (addon/core/API.lua). Two details from that file are
load-bearing and were both got wrong on the first attempt:

  * `is_our_bridge` REJECTS any candidate that does not answer "GetRuntimeVersion"
    with a string matching "^1%." - so a bridge that does not version itself is
    silently ignored and every call returns nil. The bot then behaves exactly as
    if the runtime were not injected: alive, ticking, and completely blind.

  * ObjectPosition returns "x|y|z" and (0,0,0) IS THE FAILURE SENTINEL
    (API.lua:1203). A simulated player standing at the origin therefore reads as
    "no position", which is indistinguishable from a broken runtime. Scenarios
    must not start at (0,0,0), and this module refuses to hand back that value.

Mocking the layer ABOVE this (overriding RaijinLab:ObjectPosition directly) does
not work and is worse than useless: the addon's own API.lua overwrites it at load,
so the override vanishes and the mock tests nothing.
"""
from __future__ import annotations

import math

from .world import RENDER_RADIUS, World

VERSION = "1.8.8-sim"


def _f(v: float) -> str:
    return "%.3f" % float(v)


class RuntimeBridge:
    def __init__(self, lua, world: World, counter=None):
        self.lua = lua
        self.w = world
        self.calls: dict[str, int] = {}
        self._counter = counter
        self.unhandled: dict[str, int] = {}
        self.files: dict[str, str] = {}
        # directories searched for real navgrid tiles
        self.tile_dirs: list = []

    def _count(self, name: str) -> None:
        self.calls[name] = self.calls.get(name, 0) + 1
        if self._counter is not None:
            self._counter(name)

    # ------------------------------------------------------------------ API
    def install(self) -> None:
        """Expose the dispatcher as a REAL Lua function.

        Assigning the Python callable straight to the global does not work: lupa
        exposes Python callables to Lua as USERDATA, and API.lua's is_our_bridge
        starts with `type(fn) ~= "function"` and rejects it outright. Every call
        then returns nil and the bot behaves exactly as if the runtime were never
        injected - alive, ticking, and totally blind. So wrap it in a Lua closure.
        """
        self.lua.globals()["__py_runtime"] = self.dispatch
        # THE BRIDGE IS IsLinuxClient. core/Runtime.lua deliberately probes ONLY
        # that stock global (the injector rebinds it, for stealth), so stubbing it
        # to nil - which looks like the safe, faithful thing to do - guarantees
        # HasRuntime() is false. Every Actions call then fails its ensure() gate
        # and silently no-ops, so the bot thinks, plans, and never moves a step.
        # API.lua additionally checks RaijinLab_Runtime, so bind both.
        self.lua.execute(
            "IsLinuxClient = function(...) return __py_runtime(...) end" + chr(10) +
            "RaijinLab_Runtime = IsLinuxClient"
        )

    def visible(self):
        return self.w.visible_units()

    def dispatch(self, cmd=None, *args):
        cmd = str(cmd) if cmd is not None else ""
        self._count(cmd)
        w = self.w
        p = w.player

        if cmd == "GetRuntimeVersion":
            return VERSION

        # ---- position / facing ----
        if cmd == "ObjectPosition":
            tok = args[0] if args else None
            if tok is None or tok in ("player", "Player"):
                x, y, z = p.x, p.y, p.z
            else:
                st = str(tok)
                # Unit tokens resolve through the player's current target, matching
                # API.lua resolve_object_arg + UnitGUID("target").
                if st.lower() in ("target", "focus", "mouseover", "pet"):
                    guid = getattr(p, "target", None) if st.lower() == "target" else None
                    u = w.unit(str(guid)) if guid else None
                else:
                    u = w.unit(st)
                if u is None or u.dead:
                    return None
                if math.hypot(u.x - p.x, u.y - p.y) > RENDER_RADIUS:
                    return None                # out of render range: unknown
                x, y, z = u.x, u.y, u.z
            if x == 0 and y == 0 and z == 0:
                # The addon reads this as failure, so never emit it by accident.
                z = 0.001
            return "|".join((_f(x), _f(y), _f(z)))

        if cmd == "ObjectFacing":
            tok = args[0] if args else None
            if tok is None or tok in ("player", "Player"):
                return p.facing
            u = w.unit(str(tok))
            return 0.0 if u is None else 0.0

        if cmd == "PlayerFacing":
            return p.facing

        # ---- sensing ----
        if cmd == "TraceLine":
            try:
                x1, y1, z1, x2, y2, z2 = (float(a) for a in args[:6])
            except (TypeError, ValueError):
                return None
            blocked, hx, hy, hz = w.terrain.trace(x1, y1, z1, x2, y2, z2)
            return "|".join(("1" if blocked else "0", _f(hx), _f(hy), _f(hz)))

        # ---- object manager ----
        vis = self.visible()
        if cmd == "GetObjectCount":
            return len(vis)
        if cmd == "GetObjectWithIndex":
            i = int(args[0]) if args else 0
            return vis[i - 1].guid if 1 <= i <= len(vis) else None
        if cmd == "GetGameObjectCount":
            return len([u for u in vis if u.otype == 5])
        if cmd == "GetGameObjectWithIndex":
            gos = [u for u in vis if u.otype == 5]
            i = int(args[0]) if args else 0
            return gos[i - 1].guid if 1 <= i <= len(gos) else None
        if cmd in ("ObjectId", "ObjectEntry"):
            u = w.unit(str(args[0])) if args else None
            return u.entry if u else 0
        if cmd == "ObjectType":
            u = w.unit(str(args[0])) if args else None
            return u.otype if u else 0
        if cmd == "ObjectTypeFlags":
            # RunObjectManager classifies by this BITMASK, not by ObjectType, so
            # without it typeFlags was 0, no branch matched, and object_list.npcs
            # stayed empty even once the manager was running. Masks are
            # RaijinLab.enums.ObjectTypeFlags (API.lua): Object=1, Unit=32,
            # Player=64, GameObject=256 - note these are the addon's own values,
            # NOT the raw 3.3.5 TypeMask, so read them from there if they change.
            u = w.unit(str(args[0])) if args else None
            if not u:
                return 0
            if u.otype == 5:
                return 1 | 256          # Object | GameObject
            return 1 | 32               # Object | Unit
        if cmd == "ObjectQuestGiverStatus":
            # Deliberately INTERMITTENT - see Unit.giver_status_flaky. A perfect
            # sensor here would make the real defect unreproducible: giver_status
            # had no memory, so a 0 read as "not a giver" and progress_step
            # flipped accept<->objective about three times a second.
            u = w.unit(str(args[0])) if args else None
            if not u or not u.giver_status:
                return 0
            self._gs_n = getattr(self, "_gs_n", 0) + 1
            every = max(1, int(u.giver_status_flaky or 1))
            return u.giver_status if (self._gs_n % every) == 0 else 0
        if cmd == "ObjectName":
            u = w.unit(str(args[0])) if args else None
            return u.name if u else None
        if cmd == "ObjectCreatureType":
            return 1
        if cmd == "UnitCombatReach" or cmd == "ObjectCombatReach":
            return 1.5
        if cmd == "ObjectBoundingRadius" or cmd == "UnitBoundingRadius":
            return 0.5
        if cmd == "InWorld":
            return 1
        if cmd == "UnitIsMounted":
            return 1 if p.mounted else 0
        if cmd == "ArmUnlock":
            return 1

        # STAGED INPUT CARRIER (2026-08-03). The addon no longer dispatches
        # MoveForwardStart etc. across the bridge - the client judges the call
        # ORIGIN, so that taints. It stages intent via StageInput and the
        # runtime's native frame hook applies it. The simulator must model the
        # carrier or every scenario silently stops moving: without this, 9 of
        # 17 scenarios failed with the addon perfectly correct.
        #
        # Bit order matches Actions.h InputBit and Actions.lua's table.
        if cmd == "StageInput":
            try:
                bit = int(float(args[0])); down = int(float(args[1])) != 0
            except (TypeError, ValueError, IndexError):
                return 0
            # Route each bit through the SAME command path the real runtime
            # hook drives, so broken-primitive modelling below still applies.
            names = {
                0: ("MoveForwardStart", "MoveForwardStop"),
                1: ("MoveBackwardStart", "MoveBackwardStop"),
                2: ("StrafeLeftStart", "StrafeLeftStop"),
                3: ("StrafeRightStart", "StrafeRightStop"),
                4: ("TurnLeftStart", "TurnLeftStop"),
                5: ("TurnRightStart", "TurnRightStop"),
                6: ("PitchUpStart", "PitchUpStop"),
                7: ("PitchDownStart", "PitchDownStop"),
                # Vertical swim/fly. Added to the carrier in round 79;
                # omitting them here made "ascend was never held" - the
                # addon staged bit 8 and the mock silently dropped it, so
                # the bot drowned in breath_panic_surfaces with the addon
                # perfectly correct. A harness must model EVERY bit of the
                # transport it is testing, not most of them.
                8: ("AscendStart", "AscendStop"),
                9: ("DescendStart", "DescendStop"),
            }
            pair = names.get(bit)
            if not pair:
                return 0
            return self.dispatch(pair[0] if down else pair[1])

        # ---- movement: HELD state, applied by the world's physics ----
        if cmd == "MoveForwardStart":
            p.fwd = True; return 1
        if cmd == "MoveForwardStop":
            p.fwd = False; return 1
        # BROKEN-PRIMITIVE MODELLING. Must come before every movement
        # handler: placed later, TurnLeftStart was already serviced above
        # and the sim character kept rotating, so the scenario silently
        # tested nothing.
        if p.turn_broken and cmd in ("FaceDirection", "TurnByDelta",
                                     "TurnLeftStart", "TurnRightStart",
                                     "TurnLeftStop", "TurnRightStop"):
            return 1        # accepted, and does nothing - the live bug
        if p.strafe_broken and cmd in ("StrafeLeftStart", "StrafeRightStart"):
            return 1
        if cmd == "StrafeLeftStart":
            p.strafe = -1; return 1
        if cmd == "StrafeRightStart":
            p.strafe = 1; return 1
        if cmd in ("StrafeLeftStop", "StrafeRightStop"):
            p.strafe = 0; return 1
        if cmd == "TurnLeftStart":
            p.turn = 1; return 1
        if cmd == "TurnRightStart":
            p.turn = -1; return 1
        if cmd in ("TurnLeftStop", "TurnRightStop"):
            p.turn = 0; return 1
        if cmd == "StopMoving":
            p.fwd = False; p.strafe = 0; p.turn = 0
            p.ascend = False; p.descend = False
            return 1
        if cmd == "FaceDirection":
            # Absolute snap-turn. The navigator uses this for large heading
            # errors (aerr > 1.0) before handing off to the fine controller.
            # Leaving it unhandled meant the sim bot could not turn AT ALL on a
            # big correction and drove into the wall it was trying to route
            # around - a harness gap that read exactly like a pathfinder bug.
            # It is real on the live client (verified: facing 1.577 -> -0.612).
            try:
                p.facing = float(args[0]) % (2 * math.pi)
            except (TypeError, ValueError, IndexError):
                return 0
            return 1
        if cmd == "IpcPoll":
            return ""          # no external driver during a sim run
        if cmd == "IpcReply":
            return 1
        if cmd == "TurnByDelta":
            try:
                p.facing = (p.facing + float(args[0])) % (2 * math.pi)
            except (TypeError, ValueError, IndexError):
                return 0
            return 1
        # Swim vertical is HELD state (same as forward). A one-shot Jump that does
        # not leave ascend true cannot lift the character through a water column.
        if cmd in ("AscendStart", "JumpOrAscendStart"):
            p.ascend = True; p.descend = False; return 1
        if cmd == "AscendStop":
            p.ascend = False; return 1
        if cmd in ("DescendStart", "SitStandOrDescendStart"):
            p.descend = True; p.ascend = False; return 1
        if cmd == "DescendStop":
            p.descend = False; return 1
        if cmd == "Jump":
            # Land hop only: no sustained lift. Swim-up must use AscendStart.
            return 1
        if cmd in ("MouselookStart", "MouselookStop",
                   "CommitMovement", "MouseMove", "StopCasting", "StopAttack"):
            return 1

        # ---- casting / interaction ----
        if cmd in ("CastSpell", "CastSpellByName"):
            w.casts.append((w.t, str(args[0]) if args else "?"))
            return 1
        if cmd in ("Interact", "ObjectInteract", "InteractUnit"):
            u = w.unit(str(args[0])) if args else None
            if u and math.hypot(u.x - p.x, u.y - p.y) < 6.0:
                if u.otype == 5:
                    w.merchant_open = True
                return 1
            return 0

        # ---- camera (packed, same as the client) ----
        if cmd == "GetCameraData":
            # ORDER MATTERS AND I HAD IT WRONG: API.lua parses
            #   pos(3), forward(3), right(3), up(3), fov(1)
            # This emitted forward first, so every simulated run has had garbage
            # camera data - which went unnoticed only because live facing is the
            # primary heading source and the camera is a fallback. A packed format
            # is exactly where a simulator diverges silently.
            fx, fy = math.cos(p.facing), math.sin(p.facing)
            rx, ry = math.cos(p.facing - math.pi / 2), math.sin(p.facing - math.pi / 2)
            vals = [p.x, p.y, p.z + 2.0,      # position
                    fx, fy, -0.5,             # forward
                    rx, ry, 0.0,              # right
                    0.0, 0.0, 1.0,            # up
                    1.0]                      # fov
            return "|".join(_f(v) for v in vals)

        # ---- file IO (ConfigBackup / DevLog are genuinely exercised) ----
        if cmd == "GetWoWDirectory":
            return "SIMDIR"
        if cmd == "WriteFile":
            self.files[str(args[0])] = str(args[1]); return 1
        if cmd == "AppendFile":
            k = str(args[0])
            self.files[k] = self.files.get(k, "") + str(args[1]); return 1
        if cmd == "ReadFile":
            key = str(args[0])
            hit = self.files.get(key)
            if hit is not None:
                return hit
            # Navgrid tiles live on the real disk, not in the in-memory file map.
            # Serving them here is what lets a scenario exercise the ENTIRE chain -
            # generated tile -> loader -> planner -> movement - headlessly, instead
            # of trusting a decoder test plus a live login.
            base = key.replace(chr(92), "/").rsplit("/", 1)[-1]
            for root in self.tile_dirs:
                cand = root / base
                if cand.exists():
                    return cand.read_text(encoding="ascii", errors="replace")
            return None
        if cmd == "FileExists":
            return 1 if str(args[0]) in self.files else 0

        self.unhandled[cmd] = self.unhandled.get(cmd, 0) + 1
        return None
