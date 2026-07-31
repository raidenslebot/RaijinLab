# RaijinLab — Environment & Prep Notes

**Date:** 2026-07-20  
**Workspace:** `C:\Ascension\Workspace`  
**Client:** `C:\Ascension\Launcher` (download in progress ~80% at last check)

---

## Goal

Fully repurpose **cxmplexpack** → **RaijinLab**, finished and rebranded for **Ascension** (WotLK-class private client with custom content + custom AC).

Work only under `C:\Ascension\Workspace` unless explicitly sampling live client files.

---

## Layout

```
C:\Ascension\
  Launcher\                          # Ascension installer/launcher + live client (DO NOT edit)
    resources\ascension-live\        # Game root
  Workspace\
    cxmplexpack-main\                # Upstream source (read/reference; Shadowlands-era unlocker addon)
    RaijinLab\                       # Active project root
      notes\                         # RE notes, architecture, decisions
      tools\                         # Helper scripts / wrappers
      re\
        dumps\                       # Offline copies of client PE samples
        scripts\                     # PE triage, string scan, etc.
        samples\                     # Additional captures later
      vendor\                        # Third-party deps if needed
    logs\
```

---

## Tooling Status

| Tool | Status | Notes |
|------|--------|-------|
| Python 3.12 | OK | `C:\Program Files\Python312` |
| pefile / capstone / construct / lief | OK | Installed 2026-07-20 |
| git | OK | |
| node / npm | OK | Launcher is Electron |
| rustc / cargo | OK | Available if native loader needed later |
| cmake | OK | |
| MSVC Build Tools 2022 | OK | `cl.exe` Hostx64\x86 + x64 (client is **x86**) |
| dumpbin / link | OK | Same MSVC tree |
| IDA / Ghidra / x64dbg | **Missing** | Install when deep static/dynamic RE starts |
| frida / yara | **Missing** | Optional dynamic instrumentation |
| lua / luajit | **Missing** | Optional for offline script tests |

### MSVC paths (x86 client builds)

```
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x86\cl.exe
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x86\dumpbin.exe
```

---

## Source Inventory: cxmplexpack

**What it is:** Personal WoW “Lua unlocked” addon — full wrapper around a discontinued unlocker whose API is exposed via the disguised global `IsLinuxClient(name, ...)`.

| Piece | Role |
|-------|------|
| `!cxmplexpack.toc` | Interface **90002** (Shadowlands) — wrong era for Ascension |
| `core/API.lua` | ~1854 lines, **124** unlocker entry points, **164** wrappers |
| `core/objects/*` | High-perf object manager / tracker / flags |
| `core/Drawing.lua` | LibDraw-style drawing |
| `modules/*` | Arena, farming, loot, questing, torghast, travel |
| Auth token in FS APIs | `r9svH6YxEQbNTZGH` |

### Unlocker capability groups (API surface)

- **FS / process:** FileExists, Read/WriteFile, dirs, GetWoWDirectory, GetApp*
- **OM:** GetObjectCount/WithIndex, Unit/Player/GO/Dynamic/AreaTrigger/Missile enumerators
- **Object fields:** ObjectDescriptor/Field/Position/Facing/Flags, UnitCasting, UnitFlags, etc.
- **Movement hacks:** EnableFlyingMode, SetNoClipModes, StopFalling, MoveTo, FaceDirection, SetClimbAngle
- **Navmesh:** LoadMap, FindPath, GetClosestPositionOnMesh, mesh polygon APIs
- **Graphics:** WorldToScreen, TraceLine, GetCameraPosition, Draw helpers
- **Network side-channel:** HTTP + WebSocket helpers
- **Debug:** ReadMemory, GetMemoryOffset, packet logger APIs

**Implication:** RaijinLab is *not* a vanilla addon. It requires an unlocker/runtime that injects those APIs into the Lua state. Ascension work is two layers:

1. **Addon layer** — rebrand + port logic to 3.3.5-era APIs / Ascension custom systems  
2. **Runtime layer** — unlocker that survives Ascension custom AC and exposes equivalent API

---

## Client / AC first look (static)

Samples copied to `RaijinLab/re/dumps/` while download still running (re-copy after 100%).

| Binary | Arch | Size | Notes |
|--------|------|------|-------|
| `Ascension.exe` | **x86** | ~7.3 MB | Main client. Imports `DivxDecoder.dll`. Export: `AssertAndCrash`. Classic WotLK-style section layout + `.zdata`. |
| `Extensions.dll` | **x86** | ~12.1 MB | **Primary custom module.** `.text` entropy **7.53**, section **`.vm_sec`** → VMProtect-class protection likely. Export: `ClientExtensionsDummy`. Imports `discord_game_sdk`, `dbghelp`. |
| `MMgr64.exe` | **x64** | ~356 KB | Separate manager process (name suggests module manager). Runs alongside launcher. |
| `DivxTac.dll` | **x86** | ~96 KB | Suspicious name (**TAC**). Imports **mscoree.dll** (CLR). Candidate AC helper. |
| `DivxDecoder.dll` | **x86** | ~404 KB | Legitimate-looking video decoder exports; also may be a load-order/side-load pivot. |

### Early AC working hypothesis

1. **Extensions.dll** = custom client features + anti-tamper (virtualized).  
2. **MMgr64.exe** = external watchdog / module integrity / launcher-side enforcement.  
3. **DivxTac.dll** = smaller TAC component, possibly managed bridge.  
4. Client remains **32-bit**; any inject/loader must be **Wow64-aware x86**.

Full string scan + PE JSON: `re/string_scan.json`, `re/pe_triage.json`.

---

## Ascension vs cxmplexpack era gap

| | cxmplexpack | Ascension live |
|--|-------------|----------------|
| TOC interface | 90002 (SL) | WotLK-class (3.x) + heavy custom patches |
| Features used | Torghast, modern quest APIs, AreaTriggers | Custom Classless / HoF / skill cards / many patch-*.MPQ |
| Lua API | Retail-ish + unlocker | 3.3.5 base + Ascension extensions |
| AC | Retail Warden (original target era) | **Custom** stack above |

Retail modules (Torghast, etc.) are low value; object manager, drawing, farming core, travel, loot are the keepers.

---

## Process snapshot (download phase)

- Multiple `Ascension Launcher.exe` (Electron)
- `AscensionClientServices.exe` active (patch/download service)
- Binaries briefly unlocked mid-download (~42.7 GB Data/) — **re-triage at 100%**

---

## Next actions (when download completes)

1. Re-copy PE samples + re-run `pe_triage.py` / `string_scan.py` (hashes may change).  
2. `dumpbin /imports /exports` on Extensions + MMgr64; map load order from client.  
3. Decide RE toolchain install (Ghidra minimum; x32dbg for dynamic).  
4. Scaffold `RaijinLab` addon tree (rebrand from cxmplexpack): TOC, namespace `RaijinLab` / `RL`, strip SL-only modules.  
5. Document unlocker contract (`IsLinuxClient` → stable Raijin runtime API).  
6. Rigorous AC RE: Extensions `.vm_sec`, MMgr64 IPC, DivxTac role, integrity checks — map detection surface before any runtime work.

---

## Rules of engagement

- All development artifacts stay under `C:\Ascension\Workspace`.  
- Live client under `Launcher\` is reference + runtime only.  
- Re-sample binaries after every client update (hashes in `pe_triage.json`).  
- Prefer offline copies in `re/dumps` for analysis so launcher updates do not corrupt work mid-RE.
