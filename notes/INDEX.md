# RaijinLab notes — index

Start here: **`STATUS.md`** (current state) · **`RUNBOOK.md`** (build/inject/test) ·
**`COMMANDS.md`** (`/raijin` cheat-sheet + troubleshooting) ·
**`HANDOFF_claude.md`** (AC-RE handoff, Claude → Grok) ·
**`HANDOFF_grok.md`** (suite-audit handoff, Claude → Grok, latest).

## AC reverse-engineering spine (Claude)

| # | File | Topic |
|---|------|-------|
| 00 | `00_environment.md` | Environment, toolchain, layout |
| 01 | `01_ac_breakpoint_analysis.md` | AC breakpoint analysis (spine) |
| 01a | `01a_ac_first_pass.md` | Early first-pass recon log |
| 02 | `02_antidebug_module_map.md` | Anti-debug module map |
| 02a | `02a_first_run.md` | First-run log harvest |
| 03 | `03_memorybridge.md` | MMgr64 MemoryBridge |
| 04 | `04_anticheat_map.md` | DivxTac + Extensions map |
| 05 | `05_ascension_lua_natives.md` | Ascension Lua natives |
| 06 | `06_ascension_getters.txt` | Getter dump |
| 08 | `08_extracted_addon_apis.txt` | Extracted addon APIs |
| 09 | `09_ascension_addons_index.md` | Ascension addon index |
| 10 | `10_example_code_integration.md` | Example Code port + validated offsets |
| 11a–f | `11a..11f_*.md` | DivxTac AC logic · DetourMgr · Extensions sink · Extensions network AC · MMgr64 · Scan/DivxDecoder |
| 12 | `12_ac_breakpoint_catalog.md` | **Consolidated breakpoint catalog** (11 subsystems incl. live Warden) |
| 13 | `13_ac_evasion_strategy.md` | Runtime evasion strategy |
| 14 | `14_gap{2,4,5,6,7,8}_*.md` | Completeness-critic gap remediations (0xDEADBABE fix, DetourMgr inert, hash-diff, WowError, Warden handler, DivxTac load edge) |
| 15 | `15_addon_worldentry_hang.md` | Addon world-entry freeze root cause + fix |
| — | `FRIDA_probe_plan.md` | Dynamic Frida probe plan (pending live session) |
| — | `HANDOFF_claude.md` | Claude→Grok handoff (includes 0xDEADBABE + Warden corrections) |

## Runtime-dev notes (Grok) — `runtime/`

| # | File | Topic |
|---|------|-------|
| R01 | `runtime/R01_wowautosdk_integration.md` | WowAutoSDK merge + address-conflict resolution |
| R02 | `runtime/R02_crash_85100086.md` | ERROR #134 crash (`0x84F7A0`-as-setfield) + 1.4.0 fix |
| R03 | `runtime/R03_crash_worker_thread_lua.md` | ERROR #132 crash (worker-thread `FrameScript_Execute` racing the main-thread Lua VM) + 1.4.1 fix |
| R04 | `runtime/R04_stealth_surface.md` | 1.6 stealth posture: random-stage loader, PEB triple-unlink, PE-header wipe, `IsLinuxClient`-only bridge, honest residual risk |

## `archive/`

| File | Why archived |
|------|--------------|
| `archive/07_status_and_next.md` | Stale pre-crash status board — superseded by `STATUS.md` |

## Conventions

- Bare number = AC-RE spine (Claude). Letter suffix (`01a`, `11a`, `14_gapN`) = sub-note of the same topic.
- `R##` under `runtime/` = runtime-development notes (Grok).
- `archive/` = superseded but kept for provenance.
