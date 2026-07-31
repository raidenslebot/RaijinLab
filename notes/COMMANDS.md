# RaijinLab COMMANDS — operator cheat-sheet (1.6.1)

One page. Everything you type between "world entered" and "why did it break".

---

## 1. In-game slash commands

Primary: `/raijin` (canonical, never shadowed).
Aliases: `/raijinlab`, `/rlab`, `/rl` (WARN: `/rl` is often shadowed by the client's built-in reload — if a `/rl` command silently does nothing, retype with `/raijin`).

All output goes through `print()` — `SendSystemMessage` is silently dropped on characters below level 10.

| Command | What it does | Example |
|---|---|---|
| `/raijin` (bare) or `/raijin status` | Print runtime version + client build + isAscension flag | `/raijin` |
| `/raijin status ui` | Same as above + open the tabbed Menu | `/raijin status ui` |
| `/raijin menu` (alias: `ui`) | Toggle the tabbed Menu (Home / Rotation / Nav / Gather / Combat / Quest / Grind) | `/raijin menu` |
| `/raijin help` | Grouped listing of every subcommand | `/raijin help` |
| `/raijin diag` | Runtime `DiagPlayer` probe (nonzero GUID = runtime online) + Executor status line | `/raijin diag` |
| `/raijin debug` | Toggle verbose prints (rotation debug + `RaijinLab._debug_print`) | `/raijin debug` |
| `/raijin rotation` | Open Menu on Rotation tab + print Executor status | `/raijin rotation` |
| `/raijin rotation start` | Arm the Executor tick (0.05s) on the active rotation | `/raijin rotation start` |
| `/raijin rotation stop` | Halt the Executor tick | `/raijin rotation stop` |
| `/raijin rotation status` | ticks / casts / err / last / via / ev — full diagnostic line | `/raijin rotation status` |
| `/raijin rotation debug` | Toggle Executor `_debug` (dumps per-tick eval decisions) | `/raijin rotation debug` |
| `/raijin rotation cast <spellId>` | Force one Actions.CastSpell (no rotation logic). No id = force one Executor tick, ignoring humanization delay | `/raijin rotation cast 133` |
| `/raijin om` | Object-manager snapshot: player pos + objects / npcs / players / gameobjects counts. Auto-starts OM on first success | `/raijin om` |
| `/raijin nearby [range]` | Dump units within `range` yd (default 60). Reports `no units in OM` if enum not seeding — check `runtime.log hist unit=` | `/raijin nearby 30` |
| `/raijin tracker` | Toggle the world-drawing tracker overlay | `/raijin tracker` |
| `/raijin track add <id\|name>` | Add object id or name to the tracker | `/raijin track add 190175` |
| `/raijin track del <id\|name>` | Remove object from tracker | `/raijin track del 190175` |
| `/raijin track all` | Track every known object | `/raijin track all` |
| `/raijin track quest` | Toggle quest-object tracking | `/raijin track quest` |
| `/raijin mj` | Toggle multi-jump | `/raijin mj` |
| `/raijin aa` | Toggle anti-AFK | `/raijin aa` |
| `/raijin fly` | Toggle flying mode | `/raijin fly` |
| `/raijin nc` | Toggle noclip (mode 7 grounded / 15 flying) | `/raijin nc` |
| `/raijin gps` | Print player world coords | `/raijin gps` |
| `/raijin farm <name>` | Start the named farmer (see `RaijinLab.farmer.farms` keys) | `/raijin farm herb_sholazar` |
| `/raijin farm stop` | Destroy all active farmers | `/raijin farm stop` |
| `/raijin grindwp` | Append current player pos as a Grinder waypoint | `/raijin grindwp` |
| `/raijin grindclear` | Clear all Grinder waypoints | `/raijin grindclear` |
| `/raijin travel <dest>` | Route to named destination (module WIP — see troubleshooting) | `/raijin travel org` |
| `/raijin trace start` | Start a 0.5s object-trace ticker (no-op until `TraceLogObjects` implemented) | `/raijin trace start` |
| `/raijin trace stop` | Stop the object-trace ticker | `/raijin trace stop` |

---

## 2. Runtime bridge probe recipes

The runtime binds to the stock `IsLinuxClient` global (branded `RaijinLab_Runtime` was removed in 1.6.1 for stealth). Both call shapes below work when the runtime is injected; the addon-safe wrapper is `RaijinLab:RuntimeCall(...)`.

Raw form (paste into chat as `/run`):

```lua
/run print(IsLinuxClient("GetRuntimeVersion"))
/run print(IsLinuxClient("Ping"))
/run print(IsLinuxClient("GetObjectCount"))
/run print(IsLinuxClient("ObjectPosition"))
```

Addon-wrapper form (equivalent, safe if runtime is offline — returns `nil`):

```lua
/run print(RaijinLab:RuntimeCall("GetRuntimeVersion"))
/run print(RaijinLab:RuntimeCall("Ping"))
/run print(RaijinLab:RuntimeCall("GetObjectCount"))
/run print(RaijinLab:RuntimeCall("ObjectPosition"))
/run print(RaijinLab:RuntimeCall("DiagPlayer"))
/run print(RaijinLab:RuntimeCall("OmProbe"))
/run print(RaijinLab:RuntimeCall("NearbyUnits", 30, 12))
```

Expected replies (runtime online, in-world):

| Call | Success shape | Failure shape |
|---|---|---|
| `GetRuntimeVersion` | `"1.6.1"` (string) | `nil` (runtime not injected) |
| `Ping` | `"pong"` | `nil` |
| `GetObjectCount` | integer (may be 0 if OM not seeded) | `nil` or `0` |
| `ObjectPosition` | `"x|y|z"` pipe-delimited string, or three numbers | `nil` |
| `DiagPlayer` | nonzero GUID string | `"0"` or `nil` |
| `OmProbe` | `"player=x,y,z objects=N npcs=N players=N gameobjects=N"` | empty / `nil` |

If any of these return `nil` on an in-world character, you never reached "runtime online" — see troubleshooting.

---

## 3. Build & deploy

Run from `C:\Ascension\Workspace\RaijinLab\` (paths are absolute in each script, so cwd is not strictly required).

| Step | Command | What it does |
|---|---|---|
| Build runtime | `tools\build_runtime.bat` | Configures + builds `runtime\build_x86\RaijinLabRuntime.dll` via MSVC/CMake |
| Deploy addon | `tools\deploy_addon.ps1` | Copies `addon\` into the game's `Interface\AddOns\RaijinLab\` (run from PowerShell) |
| Inject runtime | `tools\inject.bat` | Sets `RL_LOG=1` + `RL_PEB_UNLINK=1`, stages random-name DLL to `%TEMP%`, `RaijinLabLoader.exe` -> `LoadLibrary`, tails `C:\Ascension\Workspace\logs\runtime.log` live |

Full loop after a code change:

```
tools\build_runtime.bat
tools\deploy_addon.ps1
# be fully IN-WORLD (past character select) — inject.bat refuses otherwise
tools\inject.bat
# in-game:
/reload
/raijin diag       # expect DiagPlayer <nonzero guid>
/raijin menu       # tabbed control panel
```

Env flags read by `tools\inject.bat` -> the runtime:

| Env var | Effect |
|---|---|
| `RL_LOG=1` | Enable `runtime.log` file logging (verbose) |
| `RL_PEB_UNLINK=1` | Unlink the runtime DLL from PEB Ldr lists after load |
| `RL_WIPE_PE=1` | Wipe the in-memory PE header (SizeOfHeaders clamped, opt-in) |
| `RL_LOAD_MODE` | Reserved for future `--map` manual-map loader |

---

## 4. Test suite

Pure-Lua suite runs against the shipped rotation stack under a lupa harness — no client required.

```
python tests/run_suite_tests.py
```

Covers: SpellUtil, Protection (school inference, absorb, reflect, DR, CLEU miss), Conditions (all 30+ eval funcs with invert modifier), Engine (serialize / deserialize / new_slot / evaluate priority walk), Nav (segment_cost, shortest_path, classify_slope, obstacles_from_entities). 100+ assertions. Expected exit code 0, all pass as of 2026-07-21.

Add new tests to the same file; the harness is a single script by design.

---

## 5. Log paths

| Log | Path |
|---|---|
| Runtime log (RL_LOG=1) | `C:\Ascension\Workspace\logs\runtime.log` |
| Offset validator | `C:\Ascension\Workspace\logs\validate.log` + `validate_report.txt` |
| Client XML/Lua errors | `C:\Ascension\Launcher\resources\ascension-live\Logs\FrameXML.log`, `GlueXML.log`, `Error.txt`, `Fatal.txt`, `Debug.txt` |
| Chat log | in-game `/console scriptErrors 1` + WoW `Logs\` (client) |

Tail live during a session: `inject.bat` already streams `runtime.log`; for others, `Get-Content -Wait <path>` in PowerShell.

---

## 6. Config file

Persistent runtime config lives in a benign-named blob:

```
Primary:  %LOCALAPPDATA%\Microsoft\Crypto\Keys\~cfg.dat
Fallback: C:\Ascension\Workspace\logs\raijinlab_vars.cfg   (when %LOCALAPPDATA% unresolvable)
```

Written by `Config.cpp` on the runtime side. Simple `key=value` per line. Keys of note:

| Key | Meaning |
|---|---|
| `om.enable` | `1` to allow ObjectManager enum starts (auto-set by `/raijin om`) |
| `taint.patch` | `1` = full `Taint::Apply` on ArmUnlock; `0` = HW-gates-only mode |
| `taint.hw_gates` | Reserved gate for `ApplyHardwareGatesOnly` (P1 hardening) |

Delete the file to reset to defaults. The runtime recreates it lazily.

Addon-side SavedVariables live in the client's `WTF\Account\<acct>\SavedVariables\RaijinLab.lua` (per-account) and `WTF\Account\<acct>\<realm>\<char>\SavedVariables\RaijinLab.lua` (per-character). Reset by deleting those files while the client is closed.

---

## 7. Troubleshooting quick table

Four historical bugs plus current top failure modes. Symptom -> likely cause -> fix.

| Symptom | Likely cause | Fix |
|---|---|---|
| Client freezes on world entry / login | Addon polyfill hitting the client mid-frame with a sub-frame `C_Timer` cascade (historical: infinite loop in `C_Timer` polyfill) | Confirmed fixed in `Compat.lua` — snapshot `n = #waiters` before drain loop, floor `delay >= 0.05s`. If it recurs, check `Compat.lua:9-63` was not reverted and no new module registers a `<0.05s` `NewTicker`. |
| Runtime crash inside worker thread (~2s after inject) | Worker thread called `FrameScript_Execute` / any Lua API (historical: R03) | Confirmed fixed. Invariant: **worker thread must never touch Lua**. If a new handler in `Dispatch.cpp` needs Lua, comment `// Call ONLY from main thread` and route it through the Lua-callback path only. See `notes/runtime/R03_crash_worker_thread_lua.md`. |
| `/rl <anything>` silently does nothing (no chat output, no reload) | `/rl` slash shadowed by the client's built-in reload alias (historical) | Use `/raijin` (canonical). The addon registers `/raijin`, `/raijinlab`, `/rlab`, `/rl` — first three always work; `/rl` is a bonus that loses to the client. |
| `/raijin` output missing on a low-level toon (nothing printed) | `SendSystemMessage` is chat-gated and silently dropped below level 10 (historical) | Confirmed fixed — `ChatHandler.lua` shims `SendSystemMessage` to `print()`. If a new module still calls `SendSystemMessage` directly, replace with `print()`. |
| `/raijin diag` returns `DiagPlayer 0` or `nil` | Runtime not injected, or injected before world-entry | Fully enter world first, then run `tools\inject.bat`. Confirm with `/run print(IsLinuxClient("GetRuntimeVersion"))` — must return `"1.6.1"`. |
| `/raijin rotation status` shows `ticks>0 casts=0 err=no_effect:*` | Client refused the cast — usually spell rank / target requirement / hardware-event gate not patched | Check `runtime.log` for `CastSpell unavailable`. Verify `IsUsableSpell(sid)` in-game. Try `/raijin rotation cast <sid>` directly to isolate Executor vs runtime. |
| `/raijin rotation status` shows `ticks=0` after `start` | `OnUpdate` frame never mounted, or `RaijinLabDB.rotation_enabled` not persisted | `/reload` after inject; check `Executor.start()` ran without error (toggle `/raijin rotation debug`). |
| `/raijin om` shows `npcs=0` and `nearby` empty | Known open — OM enum VA / callback arg order still under investigation | See `notes/STATUS.md` P1. Combat modules still use `UnitExists` tokens as a fallback, so most rotations work anyway. |
| `/raijin travel <arg>` errors or does nothing | Travel module is currently a stub (destinations table shape wrong) — see integration audit | Avoid until fixed; use manual flight / hearth. Fix tracked in the audit backlog. |
| Menu opens then vanishes / Rotation tab errors | Historical `Menu:BuildRotation` `UI` upvalue miss | Fixed — `local UI = skin()` added at top of `BuildRotation`. If it recurs, verify `Menu.lua:454` still has that line. |

Escalation order when nothing works:

1. `/raijin status` — is the runtime version printed?
2. `/raijin diag` — is DiagPlayer nonzero?
3. Tail `C:\Ascension\Workspace\logs\runtime.log` — any `exception` / `unavailable` lines?
4. `python tests/run_suite_tests.py` — pure-Lua stack still passing?
5. `notes/STATUS.md` — P0/P1 board for known-broken items.
