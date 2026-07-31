# First-Run Capture — Ascension Live

**Captured:** 2026-07-20 after full download + one in-game session  
**Client root:** `C:\Ascension\Launcher\resources\ascension-live`  
**Artifacts:** `RaijinLab/re/samples/first_run/`  
**PE samples:** `RaijinLab/re/dumps/` (hashes match mid-download — final)

---

## Session facts

| Field | Value |
|-------|--------|
| Build (sound log) | **3.3.5 (12340)** Jun 24 2010 base |
| Auth server | `51.210.230.10:3724` |
| Realm | `Bronzebeard - Warcraft Reborn` |
| Character | `Raijinx` (Alliance Paladin, level 1+) |
| Graphics | DXVK local DLLs (`d3d9/11`, `dxgi`, …) + `Ascension_d3d9.log` |
| Session window | ~19:31 launch → ~19:37 world login → exit |

Connection flow: GRUNT auth OK → realm list polling → realm connect AUTH_OK → character create → `COP_LOGIN_CHARACTER` success.

---

## Binary inventory (final)

| File | Arch | Size | SHA256 (prefix) | Role |
|------|------|------|-----------------|------|
| Ascension.exe | x86 | 7.3 MB | `5b26e33b2129737a` | Main client |
| Extensions.dll | x86 | 12.1 MB | `4e81e71157771b1d` | Custom features + **MemoryBridge client** + AnticheatMgr + VMP |
| MMgr64.exe | x64 | 356 KB | `fa9cbcd062edecc0` | **MemoryBridge server** / module manager |
| DivxTac.dll | x86 | 96 KB | `30c3b677d63ed581` | **AntiCheatService** (C++/CLI) |
| DivxDecoder.dll | x86 | 404 KB | `ed34d37b575c91a5` | Decoder (imported by Ascension.exe) |
| discord_game_sdk.dll | x86 | 3.0 MB | `d8e7d9feb3de8482` | Discord rich presence (imported by Extensions) |
| d3d*.dll / dxgi.dll | x86 | DXVK | — | Graphics translation layer |

Hashes unchanged vs mid-download samples.

---

## Runtime architecture (confirmed by logs + strings)

```
                    ┌──────────────────────┐
                    │  MMgr64.exe (x64)    │
                    │  MemoryBridgeServer  │
                    │  CreateFileMappingW  │
                    │  MapViewOfFile       │
                    │  OpenProcess(client) │
                    └──────────▲───────────┘
                               │ shared memory + object token
                               │ protocol = 3
                    ┌──────────┴───────────┐
                    │  Ascension.exe (x86) │
                    │  + Extensions.dll    │
                    │  MemoryBridgeClient  │
                    │  AnticheatMgr        │
                    │  + DivxTac.dll       │
                    │  AntiCheatService    │
                    └──────────────────────┘
```

### MemoryBridge.log (first run)

```
Monitoring client process with PID 30052.
MemoryBridgeServer initialized. clientPID=30052 serverPID=8164 protocol=3
MemoryBridgeClient initialized. clientPID=30052 serverPID=8164 protocol=3
Allocated 1024 bytes, handle 1  → write/read test → free
MemoryBridge communication test passed.
Created table handle 1 with   6801 records of  12 bytes
Created table handle 2 with  36548 records of  12 bytes
Created table handle 3 with 127121 records of  28 bytes
Created table handle 4 with  18561 records of 116 bytes
Created table handle 5 with 562792 records of  64 bytes   ≈ 34.4 MB
Created table handle 6 with  10667 records of 180 bytes
MemoryBridgeServer shutdown complete.
```

**Implications:**

1. MMgr64 is not optional cosmetics — it co-runs and shares large structured tables with the client.  
2. Handshake binds **client PID + server PID + protocol version + object token + security descriptor**.  
3. Cross-arch IPC (x64 server ↔ x86 client) via file mapping.  
4. Tables may be DBC/content snapshots, integrity baselines, or AC reference data — size/record layout is a RE target.  
5. Any inject that breaks MMgr linkage, steals the mapping name, or mismatches protocol will be noisy.

### MMgr64 imports (relevant)

`OpenProcess`, `CreateFileMappingW`, `MapViewOfFile`, `UnmapViewOfFile`, `VirtualAlloc/Free`, `CreateEventW`, `IsDebuggerPresent`, `TerminateProcess`, `ConvertStringSecurityDescriptorToSecurityDescriptorW`, `_beginthreadex`.

Strings: *“MemoryBridge object token provided”*, *“rejected malformed object token”*, *“object security descriptor”*.

### Extensions.dll (relevant)

- Spawns/attaches **MMgr64**, hosts **MemoryBridgeClient**  
- **AnticheatMgr**, `ANTICHEAT_ALERT`, `ANTICHEAT_VERSION`  
- Explicit load of **DivxTac**  
- FrameScript: `FrameScript_Execute`, `FrameScript_SignalEvent`, custom lua_* helpers  
- Still contains `WARDEN_DATA` (legacy path may remain)  
- `.vm_sec` + high `.text` entropy (virtualized)

### DivxTac.dll (relevant)

- `AntiCheatService.Detect{HackProcesses,HackTitles,HackModules,Debugger}`  
- Alert senders for process/module  
- Server handlers: `AnticheatInitializeHandler`, `AnticheatBannedProcessListHandler`  
- `DetourMgr` / `ManagedDetourMgr` + `GlobalOffsets` map  
- Imports: `DeviceIoControl`, `CreateFileA`, `IsDebuggerPresent` → possible driver/device touch  
- **No exports** (loaded + initialized by Extensions, not by name export)

---

## Addon / UI loading model

On-disk `Interface/AddOns` only has Blizzard `*.pub` load-on-demand stubs.

**In-game addons load from MPQ** (FrameXML.log):

- `Ascension_RandomModeShared`
- `Ascension_CharacterAdvancement`
- SavedVariables for: `AscensionUI`, `Ascension_NamePlates`, `Postal`, `Blizzard_CombatLog`

Missing optional paths (expected noise): `Ascension_GMTools`, DevelopmentXML, PTRXML.

**RaijinLab install path (later):** standard `Interface/AddOns/RaijinLab/` on disk still works for 3.3.5 if TOC interface matches; verify Ascension addon version check / signed addon policy under Extensions.

TOC target for Ascension: **30300** class (3.3.5), not 90002.

---

## Detection surface (updated)

| Vector | Component | Evidence |
|--------|-----------|----------|
| Process name blacklist | DivxTac | `DetectHackProcesses`, server-fed list |
| Window title blacklist | DivxTac | `DetectHackTitles` |
| Module list | DivxTac | `DetectHackModules` |
| Debugger APIs | DivxTac + Extensions + MMgr | `IsDebuggerPresent`, DBG_* tags |
| Function integrity / detours | DivxTac `DetourMgr` | Offset map of critical funcs |
| External process linkage | MMgr64 MemoryBridge | PID handshake, token, shared tables |
| Shared-memory protocol | MemoryBridge protocol 3 | Version mismatch fails hard |
| Server AC opcodes | DivxTac handlers | Init + ban list push |
| Legacy Warden remnants | Ascension.exe / Extensions | `WardenClient`, `WARDEN_DATA` |
| Possible device/driver IO | DivxTac | `DeviceIoControl` import |

---

## RaijinLab impact summary

1. **Addon layer:** Port to 3.3.5 FrameScript; drop SL/Torghast; rebrand namespace; ship as disk addon under Interface/AddOns.  
2. **Runtime layer:** Must coexist with Extensions + MMgr64 + DivxTac — classic “inject random DLL” is high risk.  
3. **MemoryBridge** is a high-value RE target: protocol commands, table schemas, token generation. Understanding it may reveal how Ascension expects trusted co-processes to behave.  
4. **No unlocker present** in this install — cxmplexpack’s `IsLinuxClient` APIs are *not* provided by Ascension. RaijinLab needs its own runtime contract.

---

## Open RE tasks (priority)

1. Map MemoryBridge command IDs (log showed “command 3 returned invalid_argument” during self-test).  
2. Identify table handle 1–6 schemas (record sizes known; column meaning unknown).  
3. Trace Extensions → CreateProcess(MMgr64) and token minting.  
4. Recover managed type list from DivxTac (C++/CLI) — dnSpy/ilspycmd.  
5. Dynamic: module list while in-world; confirm DivxTac load address; watch ban-list opcodes.  
6. Extract FrameXML/AddOns from MPQ for Ascension API surface (`GetAscension*`, events).  
7. Scaffold RaijinLab addon skeleton (TOC 30300, namespace RL).

---

## Privacy note

WTF paths contain the local account email and character name. Samples under `re/samples/first_run/WTF` are for local RE only — do not publish.
