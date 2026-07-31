# RaijinLab Architecture (1.6.1)

## Mission

Private-server **Ascension** automation lab: rebranded unlocker addon + x86 native runtime that implements the full historical `IsLinuxClient` contract against a 3.3.5.12340-class client with custom AC.

## Layers

```
┌───────────────────────────────────────────────────────────────────────────┐
│  addon/  (FrameScript, TOC 30300)                                         │
│                                                                           │
│   Menu (tabbed: Home / Rotation / Nav / Gather / Combat / Quest / Grind)  │
│     │                                                                     │
│     ▼                                                                     │
│   rotation stack                                                          │
│     ├─ Engine       priority-list model, deterministic evaluate()         │
│     ├─ Executor     live tick + evidence-based cast validation            │
│     ├─ Conditions   30+ registered predicates, uniform (ctx,args) sig     │
│     ├─ Protection   school-aware immunity/absorb/reflect/CLEU miss        │
│     └─ Editor       drag-drop UI + per-slot condition editor              │
│                                                                           │
│   core substrate                                                          │
│     ├─ World        build_context() — cooldowns, auras, ranges, GCD est   │
│     ├─ Nav          pure pathfinder + segment cost + slope classify       │
│     ├─ UI           shared palette + paint/backdrop primitives            │
│     └─ SpellUtil    Hspell link parse + spellbook cursor resolve          │
│                                                                           │
│   modules  (Brain · Gatherer · Grinder · Suite · Looter · Farming …)      │
│                                                                           │
│                          │                                                │
│                          ▼                                                │
│   Actions facade — the ONLY taint-sensitive bridge                        │
│     CastSpell · Target · Attack · Interact · MoveTo · Face · Jump ·       │
│     StopMoving · MoveForward · Strafe · RunMacroText · ExecSecure         │
└──────────────────────────┬────────────────────────────────────────────────┘
                           │ RaijinLab:RuntimeCall(name, ...)
                           │ (bound as stock `IsLinuxClient`)
┌──────────────────────────▼────────────────────────────────────────────────┐
│  runtime/  RaijinLabRuntime.dll  (x86, injected)                          │
│                                                                           │
│   bridge/Dispatch         name-dispatched IsLinuxClient handler           │
│   game/Actions            Spell_C_CastSpell + target/attack/interact/move │
│   game/ObjectManager      EnumVisibleObjects + descriptor reads (SEH)     │
│   game/TaintPatch         .text HW-event gate patches (ArmUnlock)         │
│   game/MainThread         thread-safe snapshot                            │
│   game/Offsets            binary-verified address table                   │
│   core/PebUnlink          PEB Ldr unlink + PE header wipe                 │
│   loader/                 random-stage %TEMP% copy + quiet LoadLibrary    │
│   core/{Log,Config,Patterns}                                              │
└──────────────────────────┬────────────────────────────────────────────────┘
                           │ direct calls at verified VAs
┌──────────────────────────▼────────────────────────────────────────────────┐
│  Ascension.exe + Extensions.dll + DivxTac + MMgr64                        │
│  ClntObjMgr* · FrameScript_* · lua_* · Spell_C_CastSpell · CGPlayer_C_*   │
└───────────────────────────────────────────────────────────────────────────┘
```

## Rotation architecture

The rotation is a **priority list** of slots. `Engine.evaluate(rotation, ctx, Conditions)` walks the list in order and returns the first slot whose conditions all pass — no scripting, no per-spec DSL, no APL parser. All logic is condition composition.

### Data model

Each slot (`addon/core/rotation/Engine.lua`):

```
{ id, name, enabled,
  action_type = "spell" | "item" | "macro" | "custom",
  spell_id | item_id | macro_text | custom_fn,
  target = "target" | "player" | "focus" | "auto",
  conditions = { { name, args, invert }, ... } }
```

`Engine.serialize` / `deserialize` round-trips through `RaijinLabDB.rotations[name]`. Slot IDs are stable; the trailing empty slot is a UX invariant (always exactly one drop target at the bottom).

### Condition system

`addon/core/rotation/Conditions.lua` — 30+ registered predicates, uniform `(ctx, args) → bool` signature, universal `invert` modifier, `pcall`-guarded eval, sensible nil-args defaults. Covers: health/power pct, target/player buff/debuff presence + stacks + remaining, `spell_usable`, `spell_in_range`, `cooldown_ready`, `gcd_ready`, facing, is_moving, enemies_in_range, pvp_enemy_nearby, combo_points, form_equals, `target_protected`, `target_can_take_damage`. Empty condition list = "cast when off cooldown."

### Evidence-based casting

`Executor.tick` (`addon/core/rotation/Executor.lua`) does not trust return values. Around every `Act.CastSpell` it takes a `cast_snapshot`: `{ casting_name, channel_name, is_current, cd_start, cd_dur }` before and after. Cast success requires at least one of those bits to have flipped. Failure modes are named and logged: `no_target`, `not_enemy`, `unusable`, `oor`, `no_effect:<name>#<sid>`, `cast_failed`. This kills the whole class of silent-fail "green light, nothing happened" bugs that plagued the prior rotation attempts.

`World.build_context` (`addon/core/World.lua`) populates the ctx that both Engine and Executor consume: player/target auras with stacks + remaining, per-id cooldowns and usability and range, `count_enemies_within` closure, live `is_spell_protected` closure, TTD tracker, per-power-type pct with both name and index keys. One builder, one shape.

## Runtime version

**1.6.1** (`runtime/src/bridge/Dispatch.cpp`). Binds `IsLinuxClient` only — the branded `RaijinLab_Runtime` global was removed for stealth. Register runs main-thread after a ~2 s settle; the worker thread **never touches Lua** (regression R03).

Native additions vs 1.4.x:
- `game/Actions.cpp` — `Spell_C_CastSpell` cdecl fallback + Path A (`lua_pcall(CastSpellByID)`) + Path C (`FrameScript_Execute`, only when NOT re-entered from Lua).
- `game/ObjectManager.cpp` — POD-only staging (kMaxEnum=2048), one-shot list-offset probe, `g_enumDead` circuit-breaker on AV.
- `core/PebUnlink.cpp` — three-list Ldr unlink + `SizeOfHeaders`-clamped PE header wipe.
- `loader/loader.cpp` — random-stage `%TEMP%\<benign>_<hex>.dll` (stems: msvcirt, atl71, xinput1_3, DWrite, dbghelp).

All lua/FrameScript/OM/Spell offsets binary-verified against `re/dumps/Ascension.exe`.

## Actions facade — the one bridge

`addon/core/Actions.lua` is the **only** module in the addon that reaches for a taint-sensitive verb. Every rotation slot, every module tick, every `/raijin` subcommand that moves/casts/targets/interacts routes through it:

```
A.CastSpell · A.CastByName · A.Target · A.ClearTarget · A.Attack · A.StopAttack ·
A.Interact · A.InteractTarget · A.MoveTo · A.Face · A.Jump · A.StopMoving ·
A.MoveForwardStart/Stop · A.StrafeLeft/RightStart/Stop · A.SpellStopCasting ·
A.RunMacroText · A.ExecSecure
```

Rationale — three reasons this is a hard invariant:

1. **Taint containment.** A bare `CastSpell` / `TargetUnit` / `MoveForwardStart` from insecure origin taints the FrameScript for the session and pops the "Interface action failed because of an AddOn" dialog. Routing every call through `RaijinLab:RuntimeCall` (bound as the stock `IsLinuxClient`) means the origin is the native runtime, not the addon.
2. **Runtime-offline degradation.** `Actions.ensure()` gates on `HasRuntime()`. Load-only mode (addon enabled, runtime not injected) silently no-ops instead of erroring — safe first-run posture.
3. **Single point of policy.** HW-event gates, throttling, humanization, and future packet-level filtering all live in one file. New modules cannot forget to route through it — grep-checkable: `\bCastSpell\b|\bTargetUnit\b|\bAttackTarget\b|\bInteractUnit\b|\bJumpOrAscendStart\b|\bMoveForwardStart\b|\bRunMacroText\b|\bUseAction\b` across `addon/modules/` returns exactly one hit and it is `Actions.ClearTarget`.

## Stealth posture

Layered, honest about the residuals. Not "undetectable."

**Loader** (`runtime/src/loader/loader.cpp`)
- Random-stage: copy source DLL to `%TEMP%\<benign_stem>_<8hex>.dll` (stems chosen to look like MS runtime), `HIDDEN|SYSTEM` attrs, then `LoadLibraryA`.
- `--quiet` suppresses all console output; nothing branded on the command line.

**In-process** (`runtime/src/core/PebUnlink.cpp`)
- After `DllMain`, walk `PEB_LDR_DATA` and unlink our entry from all three lists (`InLoadOrderModuleList`, `InMemoryOrderModuleList`, `InInitializationOrderModuleList`). x86-correct offsets: `FullDllName@+0x24`, `BaseDllName@+0x2C`.
- Wipe the PE header up to `SizeOfHeaders` so a memory scan for `MZ` at the module base misses.
- Opt-outs: `RL_PEB_UNLINK=0`, `RL_WIPE_PE=0`.

**Runtime posture**
- No branded exports. Bridge published only as stock `IsLinuxClient`.
- No named mutex, no console window, no branded log path by default. Config at `%LOCALAPPDATA%\Microsoft\Crypto\Keys\~cfg.dat`.
- Quiet logs: `RL_LOG=1` enables file logging on demand.

### AC reality (4 verified layers)

| Layer | Location | Status | Mitigation |
|-------|----------|--------|------------|
| **Extensions 14-vector sink** | `Extensions.dll` | Live | Runtime does not hook or export anything the sink watches; addon calls stock names only |
| **DivxTac name-based scan** | `DivxTac.dll` | Live | `DetourMgr` `FunctionMap` verified **inert**; scan is name-based → random-stage stem + PEB unlink evades current list. Manual-map is the P1 hardening |
| **MMgr64 MemoryBridge** | `MMgr64.dll` | **Not AC** | Protocol-3 memory bridge; do not kill. Confirmed by RE — see `raijinlab_ac_architecture` memory |
| **Legacy Warden** | `Ascension.exe` handler entry `0x7DA850`, memcpy primitives `0x7DA500 / 0x7DA550`, dispatch base `0x7DA20F+` | Server-gated, dormant on most realms | Can memcpy-scan our `.text` on challenge opcode `0x2E6`. Full kill-switch table in `notes/HANDOFF_claude.md §9.5` and `notes/14_gap7_warden_native_handler.md` |

Residual risk (honest): `LoadLibrary` still creates a VAD (P1 = manual map); `CreateRemoteThread` footprint on inject; `.text` HW-gate patches survive to shutdown; behavioural fingerprint (timing, camera stillness, AFK) is not yet humanized past a fixed 0.35 s throttle; HWID / account / folder name unchanged. See `notes/runtime/R04_stealth_surface.md`.

## Test harness

`tests/run_suite_tests.py` — Python + `lupa` (Lua-in-CPython). Loads the shipped Lua modules (`SpellUtil`, `Protection`, `Conditions`, `Engine`, `Nav`) with a minimal FrameScript stub, runs 100+ assertions:

- Engine: serialize/deserialize round-trip, priority ordering, empty-slot invariant, `move_slot` / `move_condition` correctness.
- Conditions: every registered predicate with valid + edge-case + nil-args ctx; universal `invert` modifier; `pcall` guard behaviour.
- Protection: school inference from name substrings, absorb+reflect+CLEU miss aggregation, per-school immunity lookup.
- SpellUtil: `Hspell:` and `spell:` link parse; spellbook cursor with slot > 1000 private-server fallback.
- Nav: `segment_cost`, `shortest_path`, `classify_slope`, `obstacles_from_entities`.

All pass as of 2026-07-21. Zero client required — pure Lua semantics only. The integration story (Menu, Executor tick under a live FrameScript, runtime dispatch) is validated by the operator path in `notes/RUNBOOK.md`.

## External commands

`/raijin` (canonical), `/raijinlab`, `/rlab`, `/rl` (last one is shadowed by the client's built-in `/rl` reload — do not rely on it). All defined in `addon/core/ChatHandler.lua`.

| Command | Effect |
|---------|--------|
| `menu` / `ui` | Open the tabbed control panel |
| `status` [`ui`] | Runtime/version/build banner; `ui` also opens menu |
| `diag` | `DiagPlayer` runtime probe + rotation status |
| `debug` | Toggle chat-visible debug prints (executor + world) |
| `help` | Command list |
| `rotation start\|stop\|status\|debug\|cast [sid]` | Executor control; `cast` forces one attempt via Actions |
| `om` | Live ObjectManager probe (`OmProbe`), starts OM on success |
| `nearby [range]` | Dump units within range from OM |
| `tracker` | Toggle drawn object tracker |
| `track add\|del\|quest\|all <id\|name>` | Add/remove tracked object; quest-object mode |
| `farm <name>` \| `farm stop` | Start / stop a named farmer route (`RaijinLab.farmer.farms`) |
| `travel <dest>` | Travel helper *(see caveat in STATUS)* |
| `mj` / `aa` / `fly` / `nc` | Toggle multi-jump / anti-AFK / fly / noclip |
| `grindwp` / `grindclear` | Add current pos as grind waypoint / clear route |
| `gps` | Print current player position |
| `trace start\|stop` | Object-trace ticker *(see STATUS caveat)* |

## Tooling

| Tool | Path |
|------|------|
| Build runtime | `tools\build_runtime.bat` |
| Deploy addon | `tools\deploy_addon.ps1` |
| Env | `tools\env.ps1` |
| Inject | `tools\inject.bat` (random-stage + `--quiet`) |
| Validate offsets offline | `runtime\dist\RaijinLabValidate.exe` |
| VA → file offset | `runtime\tools\check_va.py` |
| Ghidra / dnSpy / x32dbg | `tools\bin\` |
| Logs (opt-in) | `Workspace\logs\runtime.log` when `RL_LOG=1` |

## Next research (live)

Mirrors `notes/STATUS.md` open board:

1. **P0** — Live-prove cast path end-to-end after 1.6.1 reinject (`/raijin rotation status` after a manual `cast` on a target dummy).
2. **P1** — Full manual-map inject; retire `LoadLibrary` + `CreateRemoteThread` footprint.
3. **P1** — OM unit enum returns `npcs=0` / high `ptrMiss`; combat still relies on unit tokens. Dual-VA probe + arg-order dump in `EnumCb` is the next step.
4. **P2** — Wire-level AC packet filter at `Ascension.exe!fpSendPacket2` (`0x0B0970`) — single `.data` choke.
5. **P2** — Behaviour humanization: post-cast jitter (STATUS advertises 0.18–0.42 s; not yet in code), reaction on target-guid change, camera micro-jitter, mouse nudge, AFK-cancel.
