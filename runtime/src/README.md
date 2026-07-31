# RaijinLab Runtime (native x86)

Injected DLL that implements the `IsLinuxClient` bridge against an
**Ascension-validated 3.3.5.12340-class** client. Provides the addon with a
taint-free path to `CastSpell`, `Target*`, `Attack`, `Interact`, movement,
`ExecSecure`, the object manager enumerator, and a hardware-event flag patch
(`ArmUnlock`). All offsets are binary-verified against `re/dumps/Ascension.exe`.

**Current version:** `1.6.1-crashfix` (string lives in `bridge/Dispatch.cpp` as
`kVersion`; verified via the addon's `GetRuntimeVersion` probe in `Runtime.lua`).

> **Stealth-related invariants**: only the stock `IsLinuxClient` global is
> registered — the branded `RaijinLab_Runtime` global was removed in 1.6. The
> worker thread **never** touches Lua (post-R03 invariant); Bridge::Register
> runs on the main thread after a TLS-safe settle window.

## Targets (`CMakeLists.txt`)

| Target | Type | Arch | Entry sources |
|--------|------|------|---------------|
| `RaijinLabRuntime.dll` | Injected game module | **x86** | `main.cpp` + `core/`, `game/`, `lua/`, `bridge/Dispatch.cpp` |
| `RaijinLabLoader.exe`  | External injector    | **x86** | `loader/loader.cpp` (random-stage %TEMP% copy + optional `--quiet`) |
| `RaijinLabValidate.exe`| Offline offset check | **x86** | `tools/validate_offsets.cpp` + `core/Patterns` / `core/Log` |

## Live source layout

```
runtime/src/
  main.cpp                   DllMain -> worker thread; worker never calls Lua (R03).
                             Bridge::Register runs on main thread after TLS settle,
                             then loader thread returns. On unload, restores taint
                             patches (both full and HW-only) and clears the bridge.
  CMakeLists.txt

  core/
    Log.cpp/.h               Structured line logger, gated by RL_LOG env.
    Config.cpp/.h            Persistent config: %LOCALAPPDATA%\Microsoft\Crypto\Keys\~cfg.dat
                             (legacy fallback: logs\raijinlab_vars.cfg).
    Patterns.cpp/.h          Signature scanner (byte + wildcard).
    PebUnlink.cpp/.h         Stealth: unlinks the DLL from all THREE PEB Ldr lists
                             (InLoad / InMemory / InInitialization), scrubs
                             FullDllName + BaseDllName UNICODE_STRING buffers,
                             then WipePeHeaders zeroes bytes up to SizeOfHeaders.
                             Opt-out via RL_PEB_UNLINK=0 / RL_WIPE_PE=0.

  game/
    Offsets.h/.cpp           Verified VAs (see notes/HANDOFF_claude.md).
    AddressDB.h              Duplicate constants used by Actions.cpp helpers.
                             (Long-term: collapse into Offsets.)
    ObjectManager.cpp/.h     EnumVisibleObjects wrapper with SEH guards and a
                             POD staging buffer (kMaxEnum=2048), NO std::string
                             or std::vector inside the callback. g_enumDead
                             circuit-breaker after AV to stop the 40Hz retry
                             flood. Cached list offsets + one-shot probe.
    TaintPatch.cpp/.h        Two entry points:
                               Apply()                 — full taint bypass patch
                               ApplyHardwareGatesOnly()— patches `cmp [flag],0`
                                                         + JE/JNE in .text so
                                                         hardware-event-only APIs
                                                         accept our synthetic call
                             Both record originals into g_patches; Restore()
                             reverts and resets g_applied + g_hw_only.
                             Gated by ArmUnlock (Actions.cpp) and env flags.
    MainThread.cpp           TLS-safe snapshot / pulse used by Bridge::Register.
    Actions.cpp/.h           Native Lua-callable handlers (see below).
    Mem.h / Types.h          Portable memory + game type shims.

  lua/
    Lua.cpp/.h               Thin C-API wrappers (lua_gettop/tostring/push*/pcall).
                             Actions.cpp CastViaLuaPCall should read lua_*
                             addresses from AddressDB rather than the raw
                             integer literals it currently uses.

  bridge/
    Dispatch.cpp             THE live bridge (namespace RL::Bridge).
                             kVersion = "1.6.1".
                             Binds ONLY IsLinuxClient — branded global removed.
                             SafeRegisterNative comment: main-thread only.

  loader/
    loader.cpp               Random-stage %TEMP%\<benign_stem>_<hex>.dll copy
                             (stems: msvcirt, atl71, xinput1_3, DWrite,
                             dbghelp) + OpenProcess + CreateRemoteThread +
                             LoadLibraryA. Supports --quiet.
                             KNOWN: does not schedule MOVEFILE_DELAY_UNTIL_REBOOT
                             cleanup — %TEMP% accumulates staged copies.

  tools/
    validate_offsets.cpp     Offline validator (no injection).

  archive/                   DEAD example-port layer (NOT compiled).
```

## `game/Actions.cpp` — native handler map

Every taint-sensitive verb the addon calls goes through one of these.
All are invoked from Lua C callbacks (main thread) and are individually
SEH-guarded.

| Handler | What it does | Path notes |
|---------|--------------|-----------|
| `ArmUnlock`         | One-shot: calls `TaintPatch::ApplyHardwareGatesOnly()` on first invocation, records `g_hw_only`. | Sole entry point for the HW-gate .text patch. Gate is currently unconditional on ArmUnlock — should read a `taint.hw_gates` config flag. |
| `CastSpell(sid[, "target"])` | Three-tier: (A) `lua_pcall(CastSpellByID)` on the current state; (B) native `Spell_C_CastSpell` cdecl; (C) `FrameScript_Execute("CastSpellByID(...)")` — only when NOT re-entering Lua. | Path A preferred; Path C never runs from a Lua C callback (R03 invariant). |
| `TargetGuid(guid)` / `TargetByName(name)` | Target unit by GUID or name via the native target helpers. | GUID path uses `ClntObjMgrGetActivePlayer`-adjacent logic. |
| `ClearTarget`       | Native ClearTarget. | |
| `Attack` / `StopAttack` | StartAttack / StopAttack (physical melee toggle). | |
| `Interact` / `InteractTarget` | Native InteractUnit dispatch. | |
| `MoveTo(x,y,z)`     | Click-to-move handler. | |
| `FaceDirection(rad)`| Native Face. | |
| `Jump`              | `JumpOrAscendStart`. | |
| `StopMoving`        | Native stop-moving; addon-side `RaijinLab:StopMoving` gates on `Actions.available()` and prints a message instead of falling back to bare protected globals. |
| `MoveForwardStart/Stop`, `MoveBackwardStart/Stop`, `StrafeLeft/RightStart/Stop`, `TurnLeft/RightStart/Stop` | Movement primitives. | `MoveBackward*` and `Turn*` are dispatched but not currently exposed by `addon/core/Actions.lua`. |
| `SpellStopCasting`  | Native cancel. | |
| `ExecSecure(str)`   | `FrameScript_Execute` for a plain string, only when NOT re-entering Lua. | |
| `RunMacroText(str)` | Native RunMacroText. | |

Addon-side facade: **all** modules and the rotation Executor go through
`addon/core/Actions.lua`. Grep for bare `CastSpell` / `TargetUnit` /
`InteractUnit` under `addon/modules/` returns zero hits.

## Flag gates

- **`ArmUnlock`** → `TaintPatch::ApplyHardwareGatesOnly()`. Env opt-out:
  `RL_TAINT=0` skips the full-taint path; a `taint.hw_gates` config flag is
  planned to gate the HW-only path independently.
- **`RL_PEB_UNLINK=1`** (default on) — enables PEB Ldr triple-unlink at
  DllMain-attach.
- **`RL_WIPE_PE=1`** (default on) — after unlink, wipe PE headers up to
  `IMAGE_OPTIONAL_HEADER::SizeOfHeaders`.
- **`RL_LOG=1`** — enables `runtime.log` output under
  `C:\Ascension\Workspace\logs\`.
- **`taint.patch=0`** (Config) — retained for the pre-1.6 full-taint path.

Both TaintPatch modes record originals into `g_patches`. On unload, main.cpp
calls `Restore()` when either `g_applied` or `g_hw_only` is set so the client
image comes back to disk-clean before the DLL is freed.

## `archive/` — do not resurrect blindly

`src/archive/` holds the original **example-port** layer that `main.cpp` no
longer uses (namespaces `Bridge`/`API`/`Console`/`Utils`, top-level
`Offsets.h`/`Mem.h`/`Types.h`/`Functions.h`, `stub.cpp`). It is **not** in
`CMakeLists.txt`. In particular `archive/bridge/LinuxClientBridge.cpp` is the
**crash-era** binder that called `FrameScript_Execute` during register
(ERROR #134 / 0x85100086 — see `notes/runtime/R02_crash_85100086.md`) and the
crash-era worker-thread `Execute` path that R03 documents. Kept for provenance
only.

## Build

```bat
tools\build_runtime.bat
```

= `vcvarsall x86` → `cmake -S runtime\src -B runtime\build_x86 -G "NMake Makefiles"`
→ `nmake` → copy `RaijinLabRuntime.dll` / `RaijinLabLoader.exe` /
`RaijinLabValidate.exe` to `runtime\dist\`.

## Inject / test

Short version — see `notes/RUNBOOK.md` for the full loop with failure decoding:

```bat
:: character in world (level >= 10 so chat prints reliably)
set RL_LOG=1
set RL_PEB_UNLINK=1
set RL_WIPE_PE=1
tools\inject.bat
```

Then in-game:

```
/reload
/raijin diag
/raijin menu
```

Confirm from Lua that the runtime is armed:

```
/run print(type(IsLinuxClient))         -- "function" when armed
/run print(IsLinuxClient("GetRuntimeVersion"))  -- "1.6.1"
```

`Runtime.lua` only accepts `IsLinuxClient` if `GetRuntimeVersion` answers with a
matching version string, so an un-injected client cannot false-positive
`HasRuntime()`. Press **END** in-game to unload.

## References

- `notes/runtime/R03_crash_worker_thread_lua.md` — why worker-thread Lua Execute
  crashes the client and how 1.5+ avoids it.
- `notes/runtime/R04_stealth_surface.md` — PEB unlink completeness, MEM_IMAGE
  residual risk, loader stems, and the manual-map plan.
- `notes/HANDOFF_claude.md` — full AC RE writeup incl. Warden VAs.
- `notes/HANDOFF_grok.md` — suite/runtime session handoff.
