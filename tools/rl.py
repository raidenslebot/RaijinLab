#!/usr/bin/env python3
"""rl - the RaijinLab development environment. One tool for everything.

WHY THIS EXISTS
---------------
Every edit in this project was being made by writing a fresh throwaway script:
twenty-plus tools/_fix_*.py files, each used once, none reviewed. That is not
untidiness, it is the direct cause of the worst damage done here:

  * a slicing patch truncated tests/run_suite_tests.py mid-main(); the suite
    then passed while running ZERO assertions and exited 0
  * a re-run of the same generator stacked three dead copies of a dispatch table
  * heredoc escaping mangled \\n and backslashes into shipped Lua more than once
  * an anchor that silently matched nothing reported success and changed nothing
  * a mutation harness kill left the addon tree mutated

Every one of those is a class this tool makes impossible:

  patch   anchor-based, VERIFIED (asserts the anchor is unique and the file
          changed), IDEMPOTENT (declares its own done-marker), ATOMIC (backup
          then restore on any gate failure), and gated on ASCII + Lua syntax
          before it is allowed to persist.
  verify  one command for the whole truth: units, simulator, source guards.
  probe   drive any simulator scenario and dump live addon state - no script.
  why     automatic failure diagnosis for a scenario, with the state that
          explains it.

Usage
  python tools/rl.py verify [--quick]
  python tools/rl.py probe <scenario> [--secs N] [--expr LUA ...]
  python tools/rl.py why <scenario> [--secs N]
  python tools/rl.py patch <file> --anchor TEXT --replace TEXT --marker ID
  python tools/rl.py deploy
  python tools/rl.py scenarios
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon"
TESTS = ROOT / "tests"
PY = sys.executable


# --------------------------------------------------------------------------
# gates - the checks every mutation of the tree must survive
# --------------------------------------------------------------------------

def gate_ascii(paths=None) -> list[str]:
    """Non-ASCII in a shipped .lua fails the build guard. Catch it at edit time
    instead of three commands later."""
    bad = []
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        if "RaijinQuest" in Path(f).parts:
            continue  # vendored third-party data, not our source
        b = Path(f).read_bytes()
        hits = [i for i, c in enumerate(b) if c > 127]
        if hits:
            ctx = b[max(0, hits[0] - 30):hits[0] + 10].decode("utf-8", "replace")
            bad.append(f"{f}: {len(hits)} non-ascii byte(s) near ...{ctx}...")
    return bad


def gate_lua(paths=None) -> list[str]:
    """Parse with real Lua 5.1 semantics via lupa's loadstring where available."""
    try:
        from lupa import LuaRuntime
    except Exception:                                    # noqa: BLE001
        return []
    # Compile INSIDE Lua and return a plain string, so nothing depends on how
    # lupa marshals a multi-return. The first version unpacked `fn, err` and got
    # a tuple-iteration error on every file - 89 false failures, which is exactly
    # the "a check that cannot be trusted is worse than no check" trap.
    lua = LuaRuntime(unpack_returned_tuples=False)
    check = lua.eval(
        "function(src) local f = loadstring or load "
        "local fn, err = f(src) if fn then return '' end return tostring(err) end")
    bad = []
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        if "RaijinQuest" in Path(f).parts:
            continue  # vendored third-party data, not our source
        src = Path(f).read_text(encoding="utf-8", errors="replace")
        try:
            err = check(src)
            if err:
                bad.append(f"{Path(f).name}: {err}")
        except Exception as e:                           # noqa: BLE001
            bad.append(f"{Path(f).name}: {e}")
    return bad


def gate_localorder(paths=None) -> list[str]:
    """A `local function` CALLED above its own declaration is valid Lua and nil at
    runtime - the upvalue simply is not bound yet. It has bitten this project
    twice: QuestOM.status_sets (which killed the giver diagnostic silently, inside
    a pcall) and Navigator.force_release (which broke the master kill switch).
    Syntax checking cannot see it, so it gets its own gate."""
    bad = []
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        if "RaijinQuest" in Path(f).parts:
            continue  # vendored third-party data, not our source
        f = Path(f)
        src = f.read_text(encoding="utf-8", errors="replace")
        lines = src.splitlines()
        decl = {}
        for i, ln in enumerate(lines):
            m = re.match(r"\s*local function (\w+)\s*\(", ln)
            if m and m.group(1) not in decl:
                decl[m.group(1)] = i
        for name, dline in decl.items():
            # a bare forward declaration (`local name`) legitimises earlier use
            if re.search(r"^\s*local " + name + r"\s*$", src, re.M):
                continue
            for i, ln in enumerate(lines[:dline]):
                if re.match(r"\s*(--|local function )", ln):
                    continue
                # strip trailing comments before matching: "-- vertical bucket (x)"
                # was read as a call to bucket(). A gate with false positives is
                # worse than no gate - it trains you to ignore it.
                ln = re.split(r"--", ln, 1)[0]
                if re.search(r"(?<![\w.:])" + name + r"\s*\(", ln):
                    bad.append(f"{f.name}:{i+1} calls {name}() declared at line {dline+1}")
                    break
    return bad


def gate_optional_filter(paths=None) -> list[str]:
    """An OPTIONAL attribute must never gate whether an object is kept.

    ObjectProcessor had `table.insert(temp, struct)` inside
    `if struct.Flags.value then`. UnitFlags is unimplemented in the runtime and
    returns nil, so EVERY npc was dropped and object_list.npcs was permanently
    empty - the engine saw no targets, no quest givers, no objectives, and the
    bot walked in a circle into a fence. Three separate wrong diagnoses were
    chased before the pipeline log named it.

    This is a source guard rather than a unit test because ObjectProcessor is a
    file-local and cannot be called from the harness.
    """
    bad = []
    f = ADDON / "core" / "objects" / "Manager.lua"
    if not f.is_file():
        return bad
    src = f.read_text(encoding="utf-8", errors="replace")
    # The keep must be unconditional: the line before each `table.insert(temp,`
    # must not be a `Flags.value` guard, and the insert must not be nested
    # deeper than the attribute assignments around it.
    lines = src.splitlines()
    for i, ln in enumerate(lines):
        if "table.insert(temp, struct)" not in ln:
            continue
        window = chr(10).join(lines[max(0, i - 12):i])
        if re.search(r"if\s+struct\.Flags\.value\s+then(?![\s\S]*?end)", window):
            bad.append(f"core/objects/Manager.lua:{i + 1}: object kept only when "
                       f"Flags.value is set - an unreadable optional attribute "
                       f"must not discard the object")
    return bad


def gate_lua51(paths=None) -> list[str]:
    """Shipped Lua must be 5.1. The HARNESS runs 5.5, so it cannot catch this.

    WoW 3.3.5 embeds Lua 5.1. The test harness uses lupa, which is 5.5, so a
    5.2+ API compiles and behaves correctly in every test and is nil in the game.
    That is the worst possible failure shape: green suite, broken client.

    Live cost of exactly this: `coroutine.isyieldable` (5.2+) was used to decide
    whether a 400ms navgrid decode should yield to the frame budget. In-game the
    name is nil, so the check silently said "do not yield" and the decode ran in
    one block - the client sat at under 1 fps and was "constantly almost
    crashing". Every test passed.
    """
    banned = {
        "coroutine.isyieldable": "5.2+; use coroutine.running() ~= nil",
        "table.unpack": "5.2+; 5.1 spells it unpack()",
        "table.pack": "5.2+; build the table literally",
        "math.type": "5.3+; use type() and math.floor comparisons",
        "math.tointeger": "5.3+",
        "string.pack": "5.3+",
        "string.unpack": "5.3+",
        "bit32.": "5.2 library; this client has no bit32",
        "os.exit": "not available in the client sandbox",
        "goto ": "5.2+ statement; 5.1 has no goto",
    }
    bad = []
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        parts = Path(f).parts
        # RaijinQuest is vendored data; addon/libs holds COMPATIBILITY shims that
        # exist precisely to PROVIDE these names on 5.1 (bitops.lua defines
        # Bitops.bit32). Flagging the polyfill for implementing the thing it
        # polyfills is the kind of false positive that trains you to ignore a gate.
        if "RaijinQuest" in parts or "libs" in parts:
            continue
        f = Path(f)
        for i, ln in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines()):
            code = re.split(r"--", ln, 1)[0]
            for needle, why in banned.items():
                if needle in code:
                    bad.append(f"{f.name}:{i+1} uses {needle.strip()} ({why})")
    return bad


def gate_multireturn(paths=None) -> list[str]:
    """`local a, b = cond and f()` TRUNCATES the multi-return to one value.

    Lua evaluates `cond and f()` as an expression, which is adjusted to exactly
    one result - so `b` and everything after it is silently nil. Live: this took
    the CLIENT DOWN. `local px, py, pz = RaijinLab.ObjectPosition and
    RaijinLab:ObjectPosition("player")` set px, left py nil, and the next line's
    arithmetic threw inside a chat handler.

    It is invisible on inspection because the code reads exactly like the guarded
    call it was meant to be. Guard with an `if` statement instead.
    """
    bad = []
    pat = re.compile(r"^\s*local\s+\w+\s*,\s*\w+.*=\s*[\w.]+\s+and\s+[\w:.]+\s*\(")
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        if "RaijinQuest" in Path(f).parts:
            continue  # vendored third-party data, not our source
        for i, ln in enumerate(Path(f).read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if ln.lstrip().startswith("--"):
                continue
            if pat.match(ln):
                bad.append(f"{Path(f).name}:{i}: multi-assign from `cond and call()` "
                           f"truncates to ONE value")
    return bad


def gate_ctm(paths=None) -> list[str]:
    """Click-to-move is a hard project constraint. Modules may not call it."""
    allow = {"core/Actions.lua", "core/API.lua", "core/Nav.lua", "core/DisableCTM.lua"}
    bad = []
    for f in (paths or sorted(ADDON.rglob("*.lua"))):
        if "RaijinQuest" in Path(f).parts:
            continue  # vendored third-party data, not our source
        f = Path(f)
        rel = f.relative_to(ADDON).as_posix() if ADDON in f.parents or f.is_relative_to(ADDON) else str(f)
        if rel in allow:
            continue
        body = re.sub("--[^" + chr(10) + "]*", "", f.read_text(encoding="utf-8", errors="replace"))
        if re.search("[:.]MoveTo[ ]*[(]|ClickPosition[ ]*[(]", body):
            bad.append(f"{rel}: calls click-to-move")
    # THE RUNTIME C++ IS IN SCOPE TOO.
    #
    # This gate used to scan only addon/**/*.lua, so it reported "clean" for
    # months while Actions.cpp built the ENTIRE interact path on
    # Offsets::F().ClickToMove with CTM action 5 ("move-to + interact") - the
    # forbidden thing, in the one language the guard could not see. Dispatch.cpp
    # even refuses "ClickToMove" by name at the bridge, and the C++ simply went
    # around it. A constraint enforced in one language is not enforced.
    #
    # Address DEFINITIONS are fine (they name the thing); CALLS are not.
    src = ROOT / "runtime" / "src"
    defs_ok = {"game/AddressDB.h", "game/Offsets.h", "game/Offsets.cpp",
               "core/Patterns.cpp", "bridge/Dispatch.cpp"}
    if src.is_dir():
        for f in sorted(list(src.rglob("*.cpp")) + list(src.rglob("*.h"))):
            rel = f.relative_to(src).as_posix()
            if rel.startswith("archive/") or rel in defs_ok:
                continue
            body = f.read_text(encoding="utf-8", errors="replace")
            body = re.sub("//[^" + chr(10) + "]*", "", body)
            if re.search("ClickToMove[ ]*[)]?[ ]*[(]|CTM[ ]*[(][ ]*[)][ ]*[(]", body):
                bad.append(f"runtime/src/{rel}: calls click-to-move")
    return bad


def gate_version(paths=None) -> list[str]:
    """SelfTest.EXPECT_VERSION must equal Dispatch.cpp kVersion.

    The selftest's first check compares the resident DLL against an expected
    version string, which is the only way to tell a rebuilt runtime from a stale
    one still sitting in the process. Hand-syncing two constants across two
    languages is precisely the silent-drift defect this session spent its time
    removing; leaving a note asking a human to remember is not a fix. Drift here
    fails the selftest spuriously, which trains you to ignore a red - the worst
    outcome for a diagnostic.
    """
    st = ADDON / "core" / "SelfTest.lua"
    disp = ROOT / "runtime" / "src" / "bridge" / "Dispatch.cpp"
    if not st.is_file() or not disp.is_file():
        return []
    m1 = re.search(r'EXPECT_VERSION\s*=\s*"([^"]+)"', st.read_text(encoding="utf-8", errors="replace"))
    m2 = re.search(r'kVersion\s*=\s*"([^"]+)"', disp.read_text(encoding="utf-8", errors="replace"))
    if not m1 or not m2:
        return ["could not read one of the version constants"]
    if m1.group(1) != m2.group(1):
        return ["SelfTest.EXPECT_VERSION=" + m1.group(1)
                + " but Dispatch kVersion=" + m2.group(1)]
    return []


def gate_bridge(paths=None) -> list[str]:
    """Every bridge command the addon calls must exist in Dispatch.cpp.

    An unhandled RuntimeCall does not raise - it returns nil, and Lua carries on
    with a default. World.lua asked for GetUnitCount/GetUnitWithIndex, which the
    bridge only answered to as GetNpcCount/GetNpcWithIndex; `tonumber(nil or 0)`
    gave 0, so the branch the code itself calls "faster + complete" never ran a
    single time and every scan silently took the slower fallback. Nothing failed,
    nothing logged - it just quietly did less.

    Skipped when the runtime tree is absent so an addon-only checkout stays green.
    """
    disp = ROOT / "runtime" / "src" / "bridge" / "Dispatch.cpp"
    if not disp.is_file():
        return []
    handled = set(re.findall(r'std::strcmp\s*\(\s*name\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)"',
                             disp.read_text(encoding="utf-8", errors="replace")))
    pat = re.compile(r"(?<![A-Za-z_])(?:RLCall|RuntimeCall|rt)" + r"\s*\(\s*" + chr(34) + r"([A-Za-z_][A-Za-z0-9_]*)" + chr(34))
    bad = []
    for f in sorted(ADDON.rglob("*.lua")):
        txt = f.read_text(encoding="utf-8", errors="replace")
        for m in pat.finditer(txt):
            cmd = m.group(1)
            if cmd not in handled:
                line = txt.count(chr(10), 0, m.start()) + 1
                rel = f.relative_to(ADDON).as_posix()
                bad.append(f"{rel}:{line}: calls bridge command '" + cmd + "' that Dispatch.cpp does not handle")
    return bad


def gate_magicindex(paths=None) -> list[str]:
    """A command dispatched by a magic character index is a silent coin-flip.

    name[7] == 'a' was meant to pick the 'a' of "St[a]rt" in "PitchUpStart", but
    that 'a' is at index 9, and index 7 is 'S' in BOTH "PitchUpStart" and
    "PitchUpStop" - so both spellings dispatched STOP and PitchUp could never be
    started. Swim depth control never worked, while every Lua layer above it -
    swim_control, swim_hold_plan, the edge-tracked pitch holds - was correct,
    tested and green. The index is invisible in review and silently wrong for any
    name whose length changes. Match a substring instead: it states the intent.
    """
    src = ROOT / "runtime" / "src"
    if not src.is_dir():
        return []
    bad = []
    # `name[0] == '\0'` is an emptiness check and states its intent; the
    # coin-flip is a MID-STRING index compared against a real character.
    pat = re.compile(r"name\s*\[\s*\d+\s*\]\s*==\s*'(?!\\0')")
    for f in sorted(list(src.rglob("*.cpp")) + list(src.rglob("*.h"))):
        rel = f.relative_to(src).as_posix()
        if rel.startswith("archive/"):
            continue
        body = re.sub("//[^" + chr(10) + "]*", "", f.read_text(encoding="utf-8", errors="replace"))
        for m in pat.finditer(body):
            line = body.count(chr(10), 0, m.start()) + 1
            bad.append(f"runtime/src/{rel}:{line}: dispatches on a magic character index")
    return bad



def gate_spellinfo(paths=None) -> list[str]:
    """A positional GetSpellInfo unpack must bind each name at its real slot.

    Verified live 2026-08-03 (Fireball -> cost=35 powerType=0 castTime=1415
    min=0 max=35): nine returns, and NO spell id.
        1 name  2 rank  3 icon  4 powerCost  5 isFunnel
        6 powerType  7 castTime  8 minRange  9 maxRange   (10 is nil)

    Three defects came from getting this wrong, none of which threw:
      * spell_range_info unpacked through pcall with nine slots, so `ok` ate
        position 1 and maxR received MINRANGE - 0 for nearly every spell, which
        silently disabled the caller's range gate;
      * Actions read slot 7 through pcall as a "spell id" and got powerType, so
        every energy ability would have cast SPELL 3;
      * a cross-check in this session read slot 6 as maxRange and reported a
        40% decode mismatch that did not exist.

    So this checks the ARITHMETIC, not the presence of a comment: it reads the
    variable names off the left-hand side and asserts each sits at the slot that
    actually carries it (pcall shifts everything by one). A comment-only gate
    passed a deliberate re-introduction of the pcall bug, which is why it does
    not work that way.
    """
    EXPECT = {
        "name": 1, "n": 1, "sname": 1, "nm": 1, "spellname": 1,
        "rank": 2, "icon": 3,
        "cost": 4, "powercost": 4, "mana": 4,
        "isfunnel": 5, "funnel": 5,
        "powertype": 6, "ptype": 6,
        "casttime": 7, "castms": 7, "ct": 7,
        "minrange": 8, "minr": 8, "mn": 8,
        "maxrange": 9, "maxr": 9, "mx": 9,
    }
    bad = []
    call = re.compile(r"local\s+([^=]+?)\s*=\s*(pcall\s*\(\s*GetSpellInfo|GetSpellInfo\s*\()")
    for f in sorted((ROOT / "addon").rglob("*.lua")):
        if "RaijinQuest" in f.as_posix():
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").split(chr(10))):
            m = call.search(line)
            if not m:
                continue
            names = [v.strip() for v in m.group(1).split(",")]
            shift = 1 if "pcall" in m.group(2) else 0
            for idx, var in enumerate(names):
                if var == "_" or (idx == 0 and shift):
                    continue                      # the placeholder / pcall's ok
                want = EXPECT.get(var.lower())
                if want is None:
                    continue                      # not a name we can adjudicate
                got = idx + 1 - shift             # 1-based GetSpellInfo slot
                if got != want:
                    bad.append("%s:%d: `%s` is bound at GetSpellInfo slot %d "
                               "but that value lives at slot %d (1 name 2 rank "
                               "3 icon 4 cost 5 isFunnel 6 powerType 7 castTime "
                               "8 minRange 9 maxRange%s)"
                               % (f.relative_to(ROOT).as_posix(), i + 1, var,
                                  got, want,
                                  "; pcall shifts all by one" if shift else ""))
    return bad


def gate_execsecure(paths=None) -> list[str]:
    """No addon Lua may drive ExecSecure. It is THE taint source.

    ExecSecure is FrameScript_Execute called from the bridge. Actions.lua has
    documented it for months as "a nested-VM re-entry crash surface AND the
    'Tainted call to a secure function' source" - and then kept three call
    sites using it as a last resort, so the one path that taints the client was
    the path taken whenever the native route failed.

    The consequence is not local: once tainted, protected calls answer nil to
    every addon sharing that execution path, which is why GatherMate2 and
    XPerl_Player threw tens of thousands of errors that had nothing to do with
    their own code. A refused action is recoverable; a tainted client is not,
    and the project directive is explicit that a red notification must be
    structurally impossible.
    """
    bad = []
    for f in sorted((ROOT / "addon").rglob("*.lua")):
        if "RaijinQuest" in f.as_posix():
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").split(chr(10))):
            code = line.split("--")[0]
            if "ExecSecure" in code:
                bad.append("%s:%d: drives ExecSecure - the documented taint "
                           "source; cast/target/macro must be native-only"
                           % (f.relative_to(ROOT).as_posix(), i + 1))
    return bad


# Protected client actions. Calling ANY of these from addon Lua - even through
# Actions.* into the bridge - is treated by the client as addon taint and pops
# "RaijinLab has been blocked from an action only available to the Blizzard UI",
# after which protected calls answer nil to every addon sharing that execution
# path (which is what buried GatherMate2 and XPerl in errors).
PROTECTED_COMMANDS = (
    "MoveForwardStart", "MoveForwardStop", "MoveBackwardStart", "MoveBackwardStop",
    "StrafeLeftStart", "StrafeLeftStop", "StrafeRightStart", "StrafeRightStop",
    "TurnLeftStart", "TurnLeftStop", "TurnRightStart", "TurnRightStop",
    "PitchUpStart", "PitchUpStop", "PitchDownStart", "PitchDownStop",
    "StopMoving", "CommitMovement", "MouselookStart", "MouselookStop",
    # MISSED in the first pass, and the gate's own blind spot is why:
    # a list of protected commands is only as good as its completeness,
    # so these went on dispatching raw while the gate read "clean".
    "AscendStart", "AscendStop", "DescendStart", "DescendStop",
)


def gate_protected_actions(paths=None) -> list[str]:
    """A protected client API may only be reached through the staged carrier.

    USER DIRECTIVE (2026-08-03): "literally all protected actions must properly
    run native through runtime hooks. all modules in the suite."

    The client judges the ORIGIN of a protected call, not its destination, so
    dispatching MoveForwardStart across the bridge taints exactly as much as
    calling it in Lua - which is why force_release popped the blocked-action
    dialog on every suite-OFF while Master.halt_movement, which stages, did not.

    The sanctioned path is StageInput / HaltMovement: intent is recorded and the
    native frame hook applies it on the main thread with no Lua on the stack.
    Actions.lua's steering wrappers now stage, so every caller is safe through
    them; what this gate forbids is bypassing them to dispatch the raw command.

    Actions.lua itself is exempt - it IS the carrier - but only for StageInput
    and HaltMovement, which are not in the forbidden list.
    """
    bad = []
    pat = re.compile("rt[' + bs + bs + 's]*[(][' + bs + bs + 's]*[" + chr(34) + "'](("
                     + "|".join(PROTECTED_COMMANDS) + "))[" + chr(34) + "']")
    for f in sorted((ROOT / "addon").rglob("*.lua")):
        if "RaijinQuest" in f.as_posix():
            continue
        rel = f.relative_to(ROOT).as_posix()
        for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").split(chr(10))):
            code = line.split("--")[0]
            m = pat.search(code)
            if m:
                bad.append("%s:%d: dispatches the protected command %s across "
                           "the bridge - stage it (StageInput / HaltMovement) so "
                           "the native frame hook applies it"
                           % (rel, i + 1, m.group(1)))
    return bad

def gate_addresses(paths=None) -> list[str]:
    """Every hardcoded VA the runtime CALLS, checked against the real client.

    A wrong address constant is not a compile error - it is a call into whatever
    happens to live at that VA, and the only way to find out used to be injecting
    into a live client and seeing whether it crashed. RaijinLabValidate maps
    Ascension.exe offline and checks each target has a valid function prologue,
    so a bad constant is caught before the DLL is ever loaded.

    Skipped (not failed) when the client or the validator is absent: this must
    not turn a machine without the game installed into a red build.
    """
    exe = ROOT / "runtime" / "dist" / "RaijinLabValidate.exe"
    client = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
    if not exe.exists() or not client.exists():
        return []
    try:
        r = subprocess.run([str(exe), str(client)], capture_output=True, text=True,
                           timeout=180)
    except Exception as e:  # noqa: BLE001 - a broken validator must not mask other gates
        return [f"validator failed to run: {e}"]
    bad = []
    for ln in (r.stdout or "").splitlines():
        if "prol=0" in ln or "OUTSIDE IMAGE" in ln:
            bad.append(ln.strip())
    m = re.search(r"summary ok=(\d+) bad=(\d+)", r.stdout or "")
    if not m:
        return ["validator produced no summary - client unreadable?"]
    if int(m.group(2)) and not bad:
        bad.append(f"validator reports bad={m.group(2)}")
    return bad


# --------------------------------------------------------------------------
# patch - the safe edit primitive
# --------------------------------------------------------------------------

def cmd_patch(a) -> int:
    """Anchor-based edit that cannot silently do nothing, cannot double-apply,
    and cannot leave the tree broken."""
    f = Path(a.file)
    if not f.is_absolute():
        f = ROOT / a.file
    if not f.exists():
        print(f"FAIL  no such file: {f}")
        return 2
    src = f.read_text(encoding="utf-8")

    marker = a.marker
    if marker and marker in src:
        print(f"SKIP  already applied (marker '{marker}' present)")
        return 0

    anchor = a.anchor.replace("\\n", "\n")
    replace = a.replace.replace("\\n", "\n")

    n = src.count(anchor)
    if n == 0:
        print("FAIL  anchor not found - the edit would have silently done nothing")
        return 3
    if n > 1 and not a.all:
        print(f"FAIL  anchor matches {n} times; pass --all or make it unique")
        return 4

    out = src.replace(anchor, replace, -1 if a.all else 1)
    if out == src:
        print("FAIL  replacement is identical to the source")
        return 5

    backup = f.with_suffix(f.suffix + ".rlbak")
    shutil.copy2(f, backup)
    f.write_text(out, encoding="utf-8")

    errs = gate_ascii([f]) + (gate_lua([f]) if f.suffix == ".lua" else [])
    if f.suffix == ".lua":
        errs += gate_ctm([f])
    if errs:
        shutil.copy2(backup, f)
        backup.unlink(missing_ok=True)
        print("FAIL  gates rejected the edit; file restored")
        for e in errs:
            print("   ", e)
        return 6

    backup.unlink(missing_ok=True)
    print(f"OK    patched {f.relative_to(ROOT)} ({n} site{'s' if a.all and n > 1 else ''})")
    return 0


# --------------------------------------------------------------------------
# verify - the whole truth in one command
# --------------------------------------------------------------------------

def _run(cmd, timeout=1800):
    # encoding is pinned because the DEFAULT is the console codepage (GBK on
    # this box), and one 0x92 smart-quote byte in a child's output made decode
    # throw inside the reader thread - stdout became None, `None + stderr`
    # raised, and EVERY gate died before running. The harness being down is
    # exactly how 51 ungated rounds shipped; it must never be killable by a
    # byte in the output it is reading.
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                       timeout=timeout, encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def gate_harness(paths=None) -> list[str]:
    """The test harness must COMPILE and have no unreachable checks.

    Both halves were found broken at once. `tests/discriminate.py` did not parse
    at all - a multi-line string had been pasted in unquoted - so the mutation
    harness had silently not run; and `_check_no_probability`, the guard the
    project believed enforced "zero probability", was defined and never called.

    Neither was visible to any other gate, because every other gate tests the
    ADDON. A harness that cannot run is worse than no harness: it reports nothing
    and is counted as passing.
    """
    import ast as _ast
    # Files where a defined-but-never-called function means a DISABLED CHECK.
    _DEADCODE_SCOPE = {"tests/run_suite_tests.py", "tests/discriminate.py",
                       "tests/simulate.py", "tools/dbload.py", "tools/rl.py"}
    errs = []
    # GLOBBED, NOT LISTED. This was a hardcoded five-file tuple, so
    # tools/_rebuild_main.py - which GENERATED main() of the suite - was never
    # checked. Proven 2026-08-03: appending an unterminated string to it left
    # this gate reporting "[PASS] harness clean" and verify exiting 0, which is
    # how a syntactically broken generator sat unnoticed. (That generator has
    # since been archived - its anchor marker no longer exists in the suite, so
    # running it DUPLICATED main(); see tools/_archive/README.md.) A hardcoded
    # list also means every tool added later is invisible by default; a glob
    # cannot rot.
    _files = sorted(set(list((ROOT / "tests").glob("*.py"))
                        + list((ROOT / "tools").glob("*.py"))))
    for f in _files:
        rel = f.relative_to(ROOT).as_posix()
        if not f.exists():
            continue
        src = f.read_text(encoding="utf-8")
        try:
            tree = _ast.parse(src)
        except SyntaxError as exc:
            errs.append(f"{rel} does not parse: line {exc.lineno}: {exc.msg}")
            continue
        # A module-level function nothing ever names is a check that cannot run.
        literals = {c.value for c in _ast.walk(tree)
                    if isinstance(c, _ast.Constant) and isinstance(c.value, str)}
        for node in tree.body:
            if not isinstance(node, _ast.FunctionDef):
                continue
            if node.name.startswith("__") or node.name == "main":
                continue
            uses = sum(1 for x in _ast.walk(tree)
                       if isinstance(x, _ast.Name) and x.id == node.name)
            # A DERIVED REGISTRY IS STILL A CALL. run_suite_tests.py builds its
            # group list by scanning its own globals() for test_* - which is what
            # makes a truncated file impossible to hide, since a lost function
            # can no longer be a silently smaller suite. A purely syntactic
            # "is this name mentioned?" cannot see that, so it condemned all 35
            # groups. Dispatch is verified for real below, by importing the
            # module and asking which groups it actually resolves.
            derived = ("_discover_groups" in literals or "test_" in literals
                       or node.name.startswith("test_"))
            # DEAD-CODE CHECK IS SCOPED; THE PARSE CHECK IS NOT.
            # "defined but never called" means a GUARD THAT NEVER RUNS in the
            # harness files (that is how _check_no_probability hid). In a one-off
            # tool script an unused helper is untidy, not a defect - failing on it
            # would push someone to narrow the glob again and re-open the hole
            # that let a syntactically broken generator pass.
            if rel not in _DEADCODE_SCOPE:
                continue
            if uses == 0 and node.name not in literals and not derived:
                errs.append(f"{rel}:{node.lineno} {node.name}() is defined but "
                            f"NEVER CALLED - a check that cannot run")

    # THE CHECK THAT ACTUALLY MATTERS: import the suite and confirm every test_*
    # function it defines is in the set it will dispatch. This catches a lost
    # registry entry, a truncated file, and a typo'd name - none of which a text
    # scan can see. It is also what proves the derived registry really covers
    # everything, rather than being trusted because it looks clever.
    try:
        import importlib.util as _ilu
        spec = _ilu.spec_from_file_location("_rl_suite", TESTS / "run_suite_tests.py")
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        defined = {n for n in dir(mod)
                   if n.startswith("test_") and callable(getattr(mod, n))}
        dispatched = {g[0] for g in getattr(mod, "GROUPS", [])}
        missing = sorted(defined - dispatched)
        for name in missing:
            errs.append(f"run_suite_tests.py: {name}() is defined but NOT "
                        f"DISPATCHED - it would never run")
        if defined and not dispatched:
            errs.append("run_suite_tests.py: GROUPS is empty - the suite would "
                        "report success while running nothing")
    except Exception as exc:            # a suite that cannot import is broken
        errs.append(f"run_suite_tests.py: could not verify dispatch: {exc}")

    return errs


def cmd_verify(a) -> int:
    if (TESTS / ".mutation_in_progress").exists():
        print("FAIL  a mutation pass is running - the tree is not stable. Stop it first.")
        return 3

    rows, bad = [], 0

    for name, errs in (("ascii", gate_ascii()), ("lua-syntax", gate_lua()),
                       ("local-order", gate_localorder()), ("no-ctm", gate_ctm()),
                       ("keep-objects", gate_optional_filter()),
                       ("magic-index", gate_magicindex()), ("execsecure", gate_execsecure()), ("protected", gate_protected_actions()), ("spellinfo", gate_spellinfo()), ("bridge", gate_bridge()), ("version-sync", gate_version()),
                       ("addresses", gate_addresses()),
                       ("multireturn", gate_multireturn()),
                       ("lua5.1", gate_lua51()),
                       ("harness", gate_harness())):
        ok = not errs
        rows.append((name, ok, "clean" if ok else f"{len(errs)} problem(s): {errs[0][:70]}"))
        bad += 0 if ok else 1

    rc, out = _run([PY, str(TESTS / "run_suite_tests.py")])
    m = re.search(r"ALL SUITE TESTS PASSED \((\d+) groups\)", out)
    fails = re.findall(r"^  - (.+)$", out, re.M)
    rows.append(("units", rc == 0,
                 f"{m.group(1)} groups green" if rc == 0 else f"{len(fails)} failing: {(fails or ['?'])[0][:60]}"))
    bad += 0 if rc == 0 else 1

    # The vendored quest database loads in a configuration upstream never shipped
    # (data only, no pfQuest code) and every other gate skips that tree on
    # purpose, so this is the only thing that proves it still loads and answers.
    rcd, outd = _run([PY, str(ROOT / "tools" / "dbload.py")])
    dfail = re.findall(r"^FAIL: (.+)$", outd, re.M)
    rows.append(("questdb", rcd == 0,
                 "loads standalone, known query answered" if rcd == 0
                 else (dfail or ["did not load"])[0][:70]))
    bad += 0 if rcd == 0 else 1

    if not a.quick:
        rc2, out2 = _run([PY, str(TESTS / "simulate.py")])
        m2 = re.search(r"(\d+)/(\d+) scenarios passed", out2)
        sfail = re.findall(r"^\[FAIL\] (\S+)", out2, re.M)
        rows.append(("simulator", rc2 == 0,
                     (m2.group(0) if m2 else "no result")
                     + (f" - {', '.join(sfail[:3])}" if sfail else "")))
        bad += 0 if rc2 == 0 else 1

    print("=== rl verify ===")
    for name, ok, detail in rows:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:<12} {detail}")
    print()
    print("VERDICT:", "everything green" if bad == 0 else f"{bad} area(s) failing")
    return 0 if bad == 0 else 1


# --------------------------------------------------------------------------
# probe / why - live state without writing a script
# --------------------------------------------------------------------------

DEFAULT_EXPRS = [
    ("pos", "(function() local x,y=RaijinLab:ObjectPosition('player') "
            "if not x then return 'nil' end return string.format('%.1f,%.1f',x,y) end)()"),
    ("nav.state", "tostring(RaijinLab.Navigator and RaijinLab.Navigator.state)"),
    ("nav.active", "tostring(RaijinLab.Navigator and RaijinLab.Navigator._active ~= nil)"),
    ("nav.moving", "tostring(RaijinLab.Navigator and RaijinLab.Navigator._moving)"),
    ("pf_goal", "(function() local g=RaijinLab.Navigator and RaijinLab.Navigator._pf_final_goal "
                "if not g then return 'none' end return string.format('%.0f,%.0f',g.x,g.y) end)()"),
    ("replan_n", "tostring(RaijinLab.Navigator and RaijinLab.Navigator._replan_n)"),
    ("path", "(function() local a=RaijinLab.Navigator and RaijinLab.Navigator._active "
             "if not a or not a.path then return 'none' end local s='' "
             "for _,p in ipairs(a.path) do s=s..string.format('(%.0f,%.0f) ',p.x,p.y) end return s end)()"),
    ("wall", "(function() local a=RaijinLab.Navigator and RaijinLab.Navigator._active "
             "if not a then return 'no active' end return 'side='..tostring(a.wall_side)"
             "..' bend='..tostring(a.wall_bend)..' block='..tostring(a.block) end)()"),
    ("suite.state", "tostring(RaijinLab.QuestSuite and RaijinLab.QuestSuite.state)"),
    ("goals", "(function() local D=RaijinLab.Director if not D or not D._goals then return 'none' end "
              "local n=0 for _ in pairs(D._goals) do n=n+1 end return n end)()"),
    ("master", "tostring(RaijinLab.Master and RaijinLab.Master.enabled and RaijinLab.Master.enabled())"),
]


def _load_scenario(name):
    sys.path.insert(0, str(TESTS))
    import sim.scenarios as SC                            # noqa: PLC0415
    from sim.runner import SimRun                         # noqa: PLC0415
    hits = [s for s in SC.ALL if name in s.name]
    if not hits:
        return None, None, [s.name for s in SC.ALL]
    sc = hits[0]()
    run = SimRun(sc.build())
    sc.setup(run)
    return sc, run, None


def cmd_probe(a) -> int:
    sc, run, names = _load_scenario(a.scenario)
    if sc is None:
        print("FAIL  no scenario matching", a.scenario)
        for n in names:
            print("   ", n)
        return 2
    secs = a.secs if a.secs else sc.seconds
    run.run(float(secs))
    print(f"=== probe {sc.name} ({secs:.0f}s) ===")
    for label, expr in DEFAULT_EXPRS:
        try:
            print(f"  {label:<12} {run.lua.eval(expr)}")
        except Exception as e:                            # noqa: BLE001
            print(f"  {label:<12} <error: {e}>")
    for expr in (a.expr or []):
        try:
            print(f"  {'custom':<12} {expr} = {run.lua.eval(expr)}")
        except Exception as e:                            # noqa: BLE001
            print(f"  {'custom':<12} {expr} <error: {e}>")
    return 0


class _Res:
    """Minimal stand-in for the simulator result object, so a scenario check()
    that reads metrics can still run during diagnosis."""
    travelled = 0.0
    net = 0.0
    stationary = 1.0
    casts = 0
    errors = 0


def res_stub():
    return _Res()


def cmd_why(a) -> int:
    """Sample the run over time so a STALL is visible as a stall, not as a
    single final position that could mean anything."""
    sc, run, names = _load_scenario(a.scenario)
    if sc is None:
        print("FAIL  no scenario matching", a.scenario)
        for n in names:
            print("   ", n)
        return 2
    total = float(a.secs or sc.seconds)
    step = max(total / 8.0, 5.0)
    print(f"=== why {sc.name} ===")
    print(f"  {'t':>5}  {'pos':>16}  {'nav':<12} {'wall':<26} path")
    prev, stalled_since = None, None
    t = 0.0
    while t < total:
        run.run(step)
        t += step
        pos = run.lua.eval(DEFAULT_EXPRS[0][1])
        nav = run.lua.eval(DEFAULT_EXPRS[1][1])
        wall = run.lua.eval(DEFAULT_EXPRS[7][1])
        path = run.lua.eval(DEFAULT_EXPRS[6][1])
        print(f"  {t:5.0f}  {pos:>16}  {nav:<12} {str(wall):<26} {str(path)[:34]}")
        if pos == prev and stalled_since is None:
            stalled_since = t
        elif pos != prev:
            stalled_since = None
        prev = pos
    print()
    # scenarios whose check() needs the run result must not crash the diagnosis -
    # a tool that dies while explaining a failure is worse than no tool.
    fails = []
    try:
        fails = sc.check(run, res_stub()) if hasattr(sc, "check") else []
    except Exception as e:                                # noqa: BLE001
        fails = [f"<check needs run metrics: {e}>"]
    print("  scenario verdict:", "PASS" if not fails else "; ".join(fails))
    if stalled_since is not None:
        print(f"  STALLED from t={stalled_since:.0f}s - position never changed again")
    print("  goals:", run.lua.eval(DEFAULT_EXPRS[9][1]),
          " suite:", run.lua.eval(DEFAULT_EXPRS[8][1]),
          " replans:", run.lua.eval(DEFAULT_EXPRS[5][1]))
    return 0


def cmd_scenarios(a) -> int:
    sys.path.insert(0, str(TESTS))
    import sim.scenarios as SC                            # noqa: PLC0415
    for s in SC.ALL:
        print(f"  {s.name:<40} {s.seconds:>5.0f}s  {s.why[:60]}")
    return 0


def cmd_deploy(a) -> int:
    rc, out = _run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(ROOT / "tools" / "deploy_addon.ps1")])
    m = re.search(r"OK: deployed \d+ files", out)
    print(m.group(0) if m else out[-300:])
    return 0 if m else 1


def main() -> int:
    ap = argparse.ArgumentParser(prog="rl", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("verify", help="gates + units + simulator")
    v.add_argument("--quick", action="store_true", help="skip the simulator")
    v.set_defaults(fn=cmd_verify)

    p = sub.add_parser("patch", help="safe anchored edit")
    p.add_argument("file")
    p.add_argument("--anchor", required=True)
    p.add_argument("--replace", required=True)
    p.add_argument("--marker", help="unique text proving it is already applied")
    p.add_argument("--all", action="store_true", help="replace every occurrence")
    p.set_defaults(fn=cmd_patch)

    pr = sub.add_parser("probe", help="run a scenario and dump state")
    pr.add_argument("scenario")
    pr.add_argument("--secs", type=float)
    pr.add_argument("--expr", action="append")
    pr.set_defaults(fn=cmd_probe)

    w = sub.add_parser("why", help="time-sampled failure diagnosis")
    w.add_argument("scenario")
    w.add_argument("--secs", type=float)
    w.set_defaults(fn=cmd_why)

    sub.add_parser("scenarios", help="list simulator scenarios").set_defaults(fn=cmd_scenarios)
    sub.add_parser("deploy", help="deploy the addon").set_defaults(fn=cmd_deploy)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    raise SystemExit(main())
