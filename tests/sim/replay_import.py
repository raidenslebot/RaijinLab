"""Import Replay.dump_lines output into the simulator.

Replay writes a compact key=value line format from the live client (no cjson on
3.3.5). This module is the offline half: parse those lines, seed a World with
the recorded positions, and let a scenario ask "would the bot have noticed this
thrash?" without re-running the game.

Full binary session re-execution is the long-term form. Today we give:
  - deterministic parse of the live dump format
  - world seeding of player positions over time
  - stationary-with-goal detection mirrored from Replay.stationary_with_goal
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable

from .world import World

_KV = re.compile(r"(\w+)=([^\s]+)")


@dataclass
class Frame:
    t: float
    x: float
    y: float
    z: float = 0.0
    hp: str = "?"
    goal: str = "idle"
    combat: bool = False


def parse_line(line: str) -> Frame | None:
    line = (line or "").strip()
    if not line or line.startswith("#"):
        return None
    kv = {m.group(1): m.group(2) for m in _KV.finditer(line)}
    if "t" not in kv:
        return None
    try:
        return Frame(
            t=float(kv.get("t", 0)),
            x=float(kv.get("x", 0)),
            y=float(kv.get("y", 0)),
            z=float(kv.get("z", 0)),
            hp=str(kv.get("hp", "?")),
            goal=str(kv.get("goal", "idle")),
            combat=str(kv.get("combat", "0")) in ("1", "true", "True"),
        )
    except ValueError:
        return None


def parse_lines(lines: Iterable[str]) -> list[Frame]:
    out: list[Frame] = []
    for line in lines:
        f = parse_line(line)
        if f is not None:
            out.append(f)
    return out


def seed_world_at(world: World, frame: Frame) -> None:
    """Place the player where the dump says they were at this frame."""
    p = world.player
    p.x, p.y, p.z = frame.x, frame.y, frame.z
    p.in_combat = frame.combat
    world.t = frame.t


def stationary_with_goal(frames: list[Frame], min_secs: float = 30.0) -> list[dict]:
    """Mirror of Replay.stationary_with_goal: thrash = goal held, no movement."""
    out: list[dict] = []
    run_start = None
    run_goal = None
    last_xy = None
    for f in frames:
        xy = (f.x, f.y)
        moved = False
        if last_xy is not None:
            dx = xy[0] - last_xy[0]
            dy = xy[1] - last_xy[1]
            moved = (dx * dx + dy * dy) > 9.0
        g = f.goal
        if g and g != "idle" and not moved:
            if run_start is None:
                run_start, run_goal = f.t, g
        else:
            if run_start is not None and (f.t - run_start) >= min_secs:
                out.append({
                    "from": run_start,
                    "to": f.t,
                    "goal": run_goal,
                    "secs": f.t - run_start,
                })
            run_start, run_goal = None, None
        last_xy = xy
    # trailing run
    if frames and run_start is not None:
        last_t = frames[-1].t
        if (last_t - run_start) >= min_secs:
            out.append({
                "from": run_start,
                "to": last_t,
                "goal": run_goal,
                "secs": last_t - run_start,
            })
    return out


def load_dump_file(path) -> list[Frame]:
    text = open(path, encoding="utf-8", errors="replace").read()
    return parse_lines(text.splitlines())
