# Ascension Custom AC — First Pass (Static)

**Status:** Preliminary. Samples taken mid-download (~80%). Re-verify hashes at 100%.

## Stack map (working model)

```
┌─────────────────────────────────────────────────────────┐
│  Ascension Launcher.exe (Electron)                      │
│  AscensionClientServices.exe                            │
└──────────────────────────┬──────────────────────────────┘
                           │ launches / patches
┌──────────────────────────▼──────────────────────────────┐
│  MMgr64.exe  (x64)                                      │
│  - External process                                     │
│  - OpenProcess / VirtualAlloc / IsDebuggerPresent       │
│  - Candidate: module manager / watchdog                 │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Ascension.exe  (x86, 3.3.5-class)                      │
│  - Build tree: wow-patch-3_3_5_A-BNet                   │
│  - Loads: Extensions.dll, DivxDecoder.dll, …            │
│  - Legacy: ScanDLL*, IsLinuxClient stub, addon checks   │
└───────┬─────────────────────────────┬───────────────────┘
        │                             │
┌───────▼────────────┐    ┌───────────▼───────────────────┐
│  Extensions.dll    │    │  DivxTac.dll  (C++/CLI)       │
│  (~12MB, x86)      │    │  **Primary AC surface**       │
│  .vm_sec present   │    │  AntiCheatService.*           │
│  High .text ent.   │    │  BannedProccesses             │
│  Custom Lua APIs   │    │  DetourMgr / ManagedDetourMgr │
│  DBG_* detections  │    │  Server opcode handlers       │
└────────────────────┘    └───────────────────────────────┘
```

## DivxTac.dll — confirmed AC module

RTTI / managed names recovered from strings:

| Symbol / name | Likely role |
|---------------|-------------|
| `AntiCheatService` | Core AC service class |
| `AntiCheatService.DetectHackProcesses` | Process blacklist scan |
| `AntiCheatService.DetectHackTitles` | Window title scan |
| `AntiCheatService.DetectHackModules` | Injected/loaded module scan |
| `AntiCheatService.DetectDebugger` | Debugger presence |
| `AntiCheatService.SendProcessAntiCheatAlert` | Report process hit |
| `AntiCheatService.SendModuleAntiCheatAlert` | Report module hit |
| `AntiCheatThreadLoop` | Background scan thread |
| `BannedProccesses` / `BannedProccessesManaged` | Blacklist singleton (note typo “Proccess”) |
| `DetourMgr` / `ManagedDetourMgr` | Function detours + offset map (`GlobalOffsets`) |
| `AnticheatInitializeHandler` | Server → client AC init opcode |
| `AnticheatBannedProcessListHandler` | Server pushes ban list |

**Tech:** Mixed native + **C++/CLI** (`mscoree.dll`, managed type names). Detours map `enum GlobalOffsets → unsigned char*`.

**Detection classes (known so far):**

1. Blacklisted process names  
2. Blacklisted window titles  
3. Blacklisted / unexpected modules  
4. Debugger presence  

**Server-driven:** ban lists and init appear opcode-based (not purely local static lists).

## Extensions.dll — custom client + hardening

- Section **`.vm_sec`** + `.text` entropy **7.53** → commercial VM/packer (VMP-family markers in noise strings).
- Single export: `ClientExtensionsDummy` (load confirmation / linker stub).
- Embeds large Ascension feature surface (banks, skill cards, custom points, Hand of Fate, JSON content loaders).
- Explicit debug-API tags: `DBG_ISDEBUGGERPRESENT`, `DBG_NTQUERYINFORMATIONPROCESS`, `DBG_NTSETINFORMATIONTHREAD`.
- FrameScript/Lua helpers (`FrameScript::lua_totable`, many `GetAscension*` natives).

**Role:** Not pure AC — product features + integrity/debug checks, virtualized.

## Ascension.exe — base client

- Confirmed **3.3.5** lineage (Blizzard source path in strings).
- Still contains retail-era names: `IsLinuxClient`, `ScanDLLStart`, `IsScanDLLFinished`, addon version check.
- Explicit load/reference of `Extensions.dll`.
- `SMSG_ADDON_INFO`, ban URLs, standard WotLK auth ban paths.

## MMgr64.exe

- **x64** companion while game is **x86** → cross-arch monitor pattern.
- Imports: `OpenProcess`, `VirtualAlloc`, `IsDebuggerPresent`, `TerminateProcess`.
- Sparse strings; needs import/xrefs + dynamic observation (parent/child, handles into Ascension.exe).

## Implications for RaijinLab runtime (later)

Any unlocker/runtime that injects into Ascension must account for at least:

1. **Module enumeration** — DLL name/path reputation (DivxTac).  
2. **Process / window title** reputation.  
3. **Debugger / debug-API** behavior (DivxTac + Extensions).  
4. **Detoured client functions** — `DetourMgr` may guard sensitive paths; hooks on already-detoured code are high risk.  
5. **External x64 manager** — MMgr64 may notice handle activity, suspended threads, or module lists from outside.  
6. **Server-fed lists** — static bypass of local lists is incomplete; need opcode/path understanding.  
7. **Virtualized Extensions** — deep static RE of Extensions is expensive; prefer boundary analysis (imports, Lua natives, cross-module calls).

## Re-sample checklist (download 100%)

- [ ] Re-copy all five PE samples; diff SHA256 vs `pe_triage.json`  
- [ ] Confirm final `Extensions.dll` / `DivxTac.dll` sizes  
- [ ] Capture `MMgr64` command line + open handles when client runs  
- [ ] Map load order: who loads DivxTac (Ascension vs Extensions vs MMgr)  
- [ ] Enumerate managed types in DivxTac (ildasm / dnSpy / `monodis`)  
- [ ] Install Ghidra + x32dbg for next RE phase  

## Scripts

```
python RaijinLab\re\scripts\pe_triage.py
python RaijinLab\re\scripts\string_scan.py
```
