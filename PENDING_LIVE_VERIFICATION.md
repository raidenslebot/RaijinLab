> **First live run (1.8.30) returned 8 passed / 1 failed.** The eight are
> confirmed working in the real client - including the unit-enumeration fast
> path (97 units, previously never executed) and swim pitch. The one failure
> was traced to `ObjectGUID` handing back a unit token as if it were a GUID;
> fixed in **1.8.32-oneparser**, which also unifies the two divergent GUID
> parsers in Dispatch.cpp - the reason `interact_honest` passed while
> `facing_wired` failed on the SAME bad input. That is what now needs re-running.

# Pending live verification - runtime 1.8.32-oneparser

Everything below is **built, deployed to disk, and verified as far as is possible
without a running client**. None of it has executed in the live game yet, because
the runtime lives in an injected DLL and the client was not running when it was
written (2026-07-29).

This file exists so that fact survives the session that produced it. Delete it
once the selftest below comes back green.

## Run this first

```
C:\Ascension\Workspace\RaijinLab\runtime\dist\RaijinLabLoader.exe
```

Then in-game:

```
/raijin selftest
```

`/raijin version` must read **1.8.32-oneparser**. A rebuilt DLL and a stale
resident one are otherwise indistinguishable, which is why the selftest checks it
first.

Eight of the nine checks need no target, no location and no setup. Target any NPC
and re-run to cover the ninth (`interact_honest`). Every failure prints a
"why it matters" line naming the original defect.

## What is awaiting confirmation

Seven defects, each of which failed **silently underneath a correct, fully-tested
upper layer** — which is why the Lua suite was green throughout:

| # | Defect | Selftest check |
|---|--------|----------------|
| 1 | `InteractGuid` returned `true` unconditionally — `ok=1` meant nothing, so the suite waited forever for a dialog nobody asked for | `interact_honest` |
| 2 | Interact pushed its argument to the wrong Lua stack index, so the handler read the bridge command name as the unit token | `interact_honest` |
| 3 | Interact trusted "the handler did not throw" as success; now verifies the asked-for unit is actually targeted afterwards | `interact_honest` |
| 4 | Swim pitch: `name[7]=='a'` picked `'S'` for **both** `PitchUpStart` and `PitchUpStop`, so pitch could only ever STOP — swim depth control had never worked | `pitch_dispatch` |
| 5 | `World.lua` called `GetUnitCount`; the bridge only knew `GetNpcCount`, so the path the code calls "faster + complete" never ran once | `unit_enum_fastpath` |
| 6 | Click-to-move was the actual interact mechanism (CTM action 5) and `OM::MoveTo` (action 4) — a hard project constraint, violated in the one language the guard could not see | `ctm_refused` |
| 7 | Unimplemented bridge commands answered `0`, and **0 is truthy in Lua** | `stubs_answer_nil` |

Separately fixed and already covered by the simulator (no live check needed): the
corpse-run stub rejection, which reused `arrive_dist` as a progress yardstick and
discarded a correct `status=found` route on every search.

## What could NOT be established offline

Only one thing: **client state** — whether the interact handler succeeds given a
live target, in range, on an actually-interactable NPC. Everything upstream of
that is machine-checked:

- every hardcoded call address validated against the shipped `Ascension.exe`
  (46/46, `rl.py verify` gate `addresses`)
- `HANDLER_InteractUnit` confirmed `__cdecl` by reading its terminator from the
  binary (0x105 bytes, ends `ff 59 c3`, no `C2` in body) — a `__stdcall`
  mismatch would have leaked stack on every interact
- every bridge command the addon calls confirmed to exist (gate `bridge`)
- `SelfTest.EXPECT_VERSION` vs `Dispatch.cpp kVersion` (gate `version-sync`)

## If a check comes back red

Paste the selftest output. It names the defect per line, so the failure is
actionable without another round of instrumentation.

## Standing warning for whoever picks this up

Five gates were added in the session that produced this file. **Four of them were
decorative or outright broken on first write** — the address gate passed a 3-byte
corruption, the bridge gate's regex contained a literal backspace byte and could
never match, the selftest group failed to parse. Treat any new gate as decorative
until a mutation proves it fails. See `raijinlab_runtime_verification` in memory.

## Fixed after the first live run (addon-side; /reload is enough)

Three defects the live log exposed, all now tested and deployed:

1. **`no_fly` was disabling the PATHFINDER** in `Suite.goto_point`. `no_fly`
   means "do not take a flight path"; it was gating `use_pf`. The search sweep
   passes `{ no_fly = true }`, so the bot's primary mode of exploration had never
   planned a route. Log proof: zero `[path]` lines and zero `pathfind_to` calls
   in a whole session, only `move_to waypoints=0` for a goal 64yd away. That is
   the "ran straight at a wall".
2. **`_last_turn_cmd` was never written by the KEYBOARD turn branch**, so it kept
   a stale non-zero value and the `turning_actually_turns` contract sat
   permanently armed. Every live turn line reads `m=keyboard`, so that contract
   had been watching a stale value in the only mode the bot uses.
3. **`om.object_list.npcs` had NO WRITER anywhere in the codebase** - initialised
   to `{}` and only ever read. The engine saw zero npcs while the runtime
   enumerated 94, so there were no quest givers AND no kill objectives
   (`found=none`); the belief-field beeline is what a blind bot does. Added
   `RaijinLab.om.refresh()` (throttled, keeps the last good snapshot if a sweep
   reads nothing) and called it from both `nearest_giver` paths.

## Still owed - needs the live client, cannot be derived offline

**`UNIT_NPC_FLAGS` offset is wrong.** Runtime log on a confirmed quest giver:
`QG guid=F13000062100002D ... st=10 interact=25 npcf=1584`. 1584 = 0x630, and
`UNIT_NPC_FLAG_QUESTGIVER` (0x2) is CLEAR on an npc the client itself reports as
a turn-in. So `OM::NpcFlags` is reading the wrong field. It is a *hint* input
only - never a veto - so it is not what broke discovery, but it is wrong and
should be calibrated empirically with `/raijin npcflags` against a known giver.
Do NOT guess the offset; that needs RE against the client.
