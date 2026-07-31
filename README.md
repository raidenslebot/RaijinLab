# RaijinLab **1.6.1** — Ascension Automation Suite

Full automation stack for **Ascension Live** (WoW 3.3.5.12340, custom AC).
Rotation creator with conditions and school-aware spell protection, tabbed control
Menu, evidence-validated Actions facade, pure-Lua Nav, World context builder,
and a stealth-loaded native runtime (v1.6.1-crashfix) that binds only the stock
`IsLinuxClient` global — no branded exports.

| | |
|---|---|
| Addon version   | **1.0.0-suite** (TOC), shipping alongside runtime **1.6.1** |
| Runtime version | **1.6.1-crashfix** (`runtime/dist/RaijinLabRuntime.dll`, ~101 KB, x86) |
| Client target   | Ascension Live 3.3.5.12340 (TOC 30300) |
| Offsets         | Binary-verified against `re/dumps/Ascension.exe` |
| Bridge global   | `IsLinuxClient` only (branded globals removed for stealth) |
| Loader          | Random-stage `%TEMP%\<benign_stem>_<hex>.dll` + PEB unlink + PE-header wipe |

> **Status**: 1.6.1 is shipping, crash-free through world entry and menu use.
> The live-prove rotation checklist is P0 — see [`notes/STATUS.md`](notes/STATUS.md).

---

## Quick start

```bat
:: 1. build the runtime (x86)
tools\build_runtime.bat

:: 2. push the addon to the client's Interface\AddOns
powershell -ExecutionPolicy Bypass -File tools\deploy_addon.ps1

:: 3. log a character into the world (>= level 10 so print() reliably shows in chat)
::    then inject with stealth toggles enabled
tools\inject.bat

:: 4. /reload once to make sure the addon sees the freshly-armed runtime
/reload

:: 5. drive it
/raijin diag        :: HasRuntime + version + player guid
/raijin menu        :: open the tabbed control panel
```

Logs stream to `C:\Ascension\Workspace\logs\runtime.log`. Press **END** in-game
to unload the runtime (the addon stays loaded and gracefully degrades to
"runtime offline").

---

## What ships in 1.6.1

### Rotation stack (`addon/core/rotation/`)

| File | Role |
|------|------|
| `Engine.lua`      | Priority-list model, `Engine.evaluate(rotation, ctx, Conditions)`, deep-copies ctx per slot with `slot_spell_id` injected, invariant of exactly one trailing empty slot |
| `Executor.lua`    | Live tick, `Actions.CastSpell(...)` dispatch, before/after `GetSpellCooldown` + `UnitCastingInfo` + `IsCurrentSpell` snapshot to prove the client accepted the cast |
| `Conditions.lua`  | 30+ registered conditions: health/power pct, target buffs/debuffs with stacks+remaining, `spell_usable`, `spell_in_range`, cooldown/GCD, facing, `is_moving`, `enemies_in_range`, combo points, form, `target_protected`, `target_can_take_damage`, universal `invert` modifier |
| `Protection.lua`  | School-aware immunity, absorb, reflect, heavy-DR, and CLEU miss aggregation (Divine Shield / Cloak of Shadows / HoP / Fire Ward / Spell Reflect / Ice Block) |
| `Editor.lua`      | Drag-drop slot UI, spellbook-cursor accept, per-slot condition editor, spell drop from action bars, immediate-save-on-mutation |

### Core suite (`addon/core/`)

- **`Actions.lua`** — the ONE facade. Every taint-sensitive verb (`CastSpell`, `Target`, `Attack`, `Interact`, `MoveTo`, `Face`, `Jump`, `StopMoving`, `MoveForward*`, `Strafe*`, `RunMacroText`, `ExecSecure`) routes through `RaijinLab:RuntimeCall(...)`. When the runtime is offline the facade silently no-ops instead of tainting the client. Grep for bare `CastSpell` / `TargetUnit` / `InteractUnit` under `addon/modules/` returns zero hits.
- **`Menu.lua`** — tabbed control panel: **Home / Rotation / Nav / Gather / Combat / Quest / Grind**. Tabs drive `RotationExecutor`, `Gatherer`, `CombatBrain`, `QuestSuite`, `Grinder`. State mirrored into `RaijinLabDB.modules.*` so `ApplyModuleState` can start/stop uniformly.
- **`World.lua`** — `build_context()` for Executor: cooldowns, known spells, `spell_in_range`, `spell_usable`, target aura tables, `count_enemies_within` closure, live `is_spell_protected` closure, per-power-type pct, TTD tracking.
- **`Nav.lua`** — pure Lua pathfinding: `request_move`, `segment_cost`, `shortest_path`, `classify_slope`, `obstacles_from_entities`. Shared substrate for Brain, Grinder, Suite.
- **`SpellUtil.lua`** — Hspell/spell link parser, `resolve_spellbook_cursor` (with private-server "slot > 1000 is spell id" fallback), aura mark by name.
- **`UI.lua`** — shared palette + paint/backdrop/border/label/button/tab/card primitives. Menu, Editor, and StatusUI draw from this single skin.
- **`StatusUI.lua`** — tiny in-world status widget.
- **`Runtime.lua`** — stealth probe: only accepts `IsLinuxClient` if `GetRuntimeVersion` answers with a real `1.x.y` string. Un-injected clients cannot false-positive `HasRuntime()`.
- **`Compat.lua`** — `C_Timer` polyfill with drain-loop crashfix (snapshot `n = #waiters` before the loop, floor delay at 0.05s).

### Modules (`addon/modules/`)

- `combat/Brain.lua`, `gathering/Gatherer.lua`, `grinding/Grinder.lua`, `questing/Suite.lua`  — new module drivers, all routed through Actions + World.
- `arena/Awareness.lua`, `travel/Travel.lua`, `loot/Looter.lua`, `farming/{Farms,Farmer}.lua`  — legacy holdovers, various states of wiring (see `notes/STATUS.md`).

### Native runtime (`runtime/src/`, v1.6.1-crashfix)

- `main.cpp` — DllMain spawns a worker; worker **never** touches Lua (post-R03 invariant). Register runs on the main thread with a TLS-safe settle window.
- `bridge/Dispatch.cpp` — the live `RL::Bridge` dispatch. Binds `IsLinuxClient` only.
- `game/Actions.cpp/.h` — native cast/target/attack/interact/move. `CastSpell` is a three-tier escalation: `lua_pcall(CastSpellByID)` → native `Spell_C_CastSpell` → `FrameScript_Execute` (only when NOT already re-entering Lua).
- `game/ObjectManager.cpp` — SEH-guarded `EnumVisibleObjects` with POD staging (`kMaxEnum=2048`), circuit-breaker (`g_enumDead`) to stop AV floods, cached list offsets.
- `game/TaintPatch.cpp` — hardware-event flag patching (`ApplyHardwareGatesOnly`) gated by `ArmUnlock`.
- `core/PebUnlink.cpp` — unlinks the loaded DLL from all three PEB Ldr lists, scrubs `FullDllName`/`BaseDllName`, wipes PE headers up to `SizeOfHeaders`. Opt-out via env.
- `loader/loader.cpp` — random-stage: copies the DLL to `%TEMP%\<benign_stem>_<hex>.dll` (stems like `msvcirt`, `atl71`, `xinput1_3`, `DWrite`, `dbghelp`) then `LoadLibrary`. `--quiet` supported.

### Tests (`tests/`)

`run_suite_tests.py` — Python + lupa. Loads shipped `SpellUtil`, `Protection`, `Conditions`, `Engine`, `Nav`. 100+ assertions. Currently green.

---

## `/raijin` slash cheat-sheet

`/raijin`, `/raijinlab`, `/rlab` are all bound. **`/raijin` is canonical.**
`/rl` is shadowed by the client's built-in `/reload`; do not rely on it.

```
UI              menu | status | diag | debug
Rotation        rotation start | stop | status | debug | cast <spellId>
Modules         farm <name> | grindwp | grindclear
Movement        mj (mount jump) | aa (auto-attack toggle) | fly | nc (no-clip)
Object mgr      om | nearby | tracker | track
Utility         gps | trace start|stop | help
```

Chat output goes through `print()` (WoW's `SendSystemMessage` silently drops on
low-level chars — do not rely on it).

---

## Operator path (get from injected to casting)

1. Log a character `>= level 10` and fly to a **Target Dummy** in SW/OG.
2. `set RL_LOG=1` then `tools\inject.bat`.
3. `/reload` (arms the addon-side runtime detection).
4. `/raijin diag` — expect `HasRuntime=true`, `ver=1.6.1`, non-zero player guid.
5. `/raijin menu` → **Rotation** tab.
6. Drop one known-good instant into slot 1 (e.g. Wrath 5176 for druid, Charge 100 for warrior, Auto Shot 75 for hunter).
7. `/target Target Dummy`.
8. `/raijin rotation cast <sid>` — one-shot sanity ping. Expect `CastSpell(sid) => true` and animation.
9. `/raijin rotation start`. After ~8 seconds, `/raijin rotation status`.
10. **Pass**: `ticks>0 casts>0 err=nil last=<name> via Actions.CastSpell ev=cooldown|casting|current`.

Failure decoding table lives in [`notes/RUNBOOK.md`](notes/RUNBOOK.md).

---

## AC honesty — what we know, what we don't

We do NOT claim undetectable. Verified layers on Ascension (see `notes/12_ac_breakpoint_catalog.md`, `notes/HANDOFF_claude.md` §9.5, and `notes/14_gap7_warden_native_handler.md`):

- **Extensions.dll** — 14-vector anti-debug sink (`FUN_100b5650`). Load-edge fingerprint.
- **DivxTac.dll** — name-based process / module / window-title scan + HDD-serial HWID. `DetourMgr` is inert. Real bite is the module-name scan; the random-stage stem defeats exact matches but not entropy heuristics.
- **MMgr64.exe** — MemoryBridge server, **not** AC. Do not kill.
- **Live legacy Blizzard Warden** inside `Ascension.exe` at `0x7DA20F+` (handler entry `0x7DA850`, memcpy primitives `0x7DA500` / `0x7DA550`). Server-driven; dormant on most realms, but capable of in-process memcpy scans of our `.text` if the server issues a challenge. Kill-switch and challenge-response strategy in `HANDOFF_claude.md`.

**Stealth we ship in 1.6.1**: random-stage %TEMP% copy under benign names, PEB Ldr triple-unlink, PE-header wipe, no branded Lua globals, `IsLinuxClient` name reuse.

**Stealth we do NOT ship yet**: full manual-map (still `LoadLibrary` — race window before PEB unlink is observable), `LdrpHashTable` / `LdrpModuleBaseAddressIndex` cleanup (`RtlLookupFunctionEntry` and MEM_IMAGE enumeration still find us), behavior humanization (fixed 0.35s Executor gap, no camera/mouse jitter, no AFK cancel). See `notes/runtime/R04_stealth_surface.md`.

Behavior first, stealth second. Do not run against a realm where you cannot afford a suspension.

---

## Pointers

| Where | What |
|-------|------|
| [`notes/STATUS.md`](notes/STATUS.md) | Current shipping state, P0/P1/P2/P3 board — the single source of truth |
| [`notes/RUNBOOK.md`](notes/RUNBOOK.md) | Build / inject / test / debug loop |
| [`notes/HANDOFF_claude.md`](notes/HANDOFF_claude.md) | AC RE handoff (Claude → Grok) |
| [`notes/HANDOFF_grok.md`](notes/HANDOFF_grok.md) | Suite / runtime handoff (Grok → Claude) |
| [`notes/INDEX.md`](notes/INDEX.md) | Full notes index — spine (00–15) + runtime R## + gap notes |
| [`notes/runtime/R03_crash_worker_thread_lua.md`](notes/runtime/R03_crash_worker_thread_lua.md) | Why the worker thread must never touch Lua |
| [`notes/runtime/R04_stealth_surface.md`](notes/runtime/R04_stealth_surface.md) | PEB unlink, PE-header wipe, loader random-stage, residual risk list |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Layer diagram |
| [`addon/README.md`](addon/README.md) | Addon-side layout |
| [`runtime/src/README.md`](runtime/src/README.md) | Runtime-side source map |
| [`runtime/API_SURFACE.txt`](runtime/API_SURFACE.txt) | `IsLinuxClient` dispatch surface (regenerate after adding handlers) |
