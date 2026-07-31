# AC Breakpoint Analysis — Ascension Custom AC

**Date:** 2026-07-20  
**Goal:** Identify and document AC detection surfaces to design evasion strategy

---

## AC Stack Architecture

Based on PE + string analysis, the AC is multi-layered:

```
Ascension.exe (x86 client)
  ↓ loads
Extensions.dll (x86, VMProtect-class, 12.1 MB, .vm_sec section)
  - Main AC + feature engine
  - Launches MMgr64.exe with "valid object token"
  - Detects debugger (IsDebuggerPresent, CheckRemoteDebuggerPresent)
  - Checks/logs process + module integrity
  - Watches network opcodes (CHEAT_*, BOT_DETECTED2, etc.)
  
DivxTac.dll (x86, CLR/.NET bridge, 98.8 KB)
  - DetourMgr: Hooks + trampolines detection
  - BannedProccesses: Process whitelist enforcement
  - GlobalOffsets: Suspicious memory offsets tracked
  - AntiCheatThreadLoop: Continuous monitoring
  - AntiCheatService.*: Alerts to AC backend
  
DivxDecoder.dll (x86, old codec, 404 KB)
  - Load-order pivot or sideload mechanism?
  - Legitimate video decoder exports but suspicious TerminateProcess import
  
MMgr64.exe (x64, watchdog, 356 KB)
  - External integrity checker
  - Runs alongside launcher
  - Likely enforces: module hash checks, no tampering, exit on violation
```

---

## Detection Surfaces (Key Findings)

### 1. **Debugger Detection** (Hard-to-bypass)
- **Strings found:**
  - `IsDebuggerPresent` — kernel-level check (unreliable on modern Windows)
  - `CheckRemoteDebuggerPresent` — process-level check
  - `DBG_ISDEBUGGERPRESENT`, `DBG_NTQUERYINFORMATIONPROCESS`, `DBG_NTSETINFORMATIONTHREAD`
  
**Implications:**
- Likely checks `ntdll!NtQueryInformationProcess` with ProcessDebugPort/DebugObject
- May hook these and detect manipulation
- **Breakpoint:** Hook site in Extensions.dll where these APIs are called; look for branches on result

### 2. **Module Integrity (Detours)**
- **Key strings in DivxTac.dll:**
  - `DetourMgr::FunctionMap` — maps `GlobalOffsets` enum to hooked function pointers
  - `AntiCheatService.DetectHackModules` — actively scans loaded modules
  - `ManagedDetourMgr` — managed (.NET) detour supervisor
  
**Implication:**
- Maintains list of "monitored offsets" (likely critical AC functions, Lua API, graphics, network)
- On AC thread loop: checks if those offsets have been tampered with (compare to known good hash/signature)
- **Breakpoint:** `DetourMgr::FunctionMap` initialization & lookup; `AntiCheatService.DetectHackModules` call site

### 3. **Process/Module Watchlist**
- **String:** `BannedProccesses` (sic), with handler `AnticheatBannedProcessListHandler`
- **PDB hint:** `C:\Users\Glader\Documents\Github\Ascension.CustomDLLs\Release\DivxTac.pdb`

**Implication:**
- Maintains banned process list (debuggers, cheating tools, known unlockers)
- Scans running processes via `CreateToolhelp32Snapshot` (in Extensions.dll imports)
- May also check window titles (string: `BannedProccesses.SetWindowTitles`)
- **Breakpoint:** BannedProccesses instantiation; process enumeration loop

### 4. **Addon Scanning & Version Checking**
- **Strings in Ascension.exe:**
  - `readScanning`, `checkAddonVersion`, `ScanDLLStart`, `IsScanDLLFinished`
  - `ADDON_LIST_UPDATE`, `SetAddonVersionCheck`
  - `Usage: ScanDLLStart("VersionURL", "DLLURL")`
  
**Implication:**
- Scans loaded addons for known malicious ones (stored in `BannedAddOns` or registry)
- Version hash check on addon DLLs (ScanDLL download/execute pattern)
- **Breakpoint:** `GetAddOnInfo` result handling; addon enumeration loop in Lua bridge

### 5. **Network-Level Botting Detection**
- **Strings in Extensions.dll:**
  - Opcode: `CMSG_BOT_DETECTED2`, `SMSG_CHECK_FOR_BOTS`
  - `CMSG_MOVE_CHARACTER_CHEAT`, `CMSG_CHEAT_SETMONEY`, `CMSG_LEVEL_CHEAT`
  - `CMSG_WEATHER_SPEED_CHEAT`, `MSG_MOVE_TELEPORT_CHEAT`, etc.
  
**Implication:**
- Server sends `SMSG_CHECK_FOR_BOTS` probe; client must respond correctly
- Any movement/teleport/speed cheat opcode triggers alert
- Anomalies (impossible speeds, illegal zones) flagged
- **Breakpoint:** Opcode handler dispatch (check where `SMSG_CHECK_FOR_BOTS` / `CMSG_BOT_DETECTED2` are handled)

### 6. **MMgr64 Watchdog Control**
- **Strings in Extensions.dll:**
  - "Failed to launch MMgr64.exe server process"
  - "Refusing to launch MMgr64.exe without a valid object token"
  - "Error getting module file name. Error code: {}"
  - "MMgr64.exe not found at: {}"
  
**Implication:**
- Extensions.dll spawns MMgr64.exe with an "object token" (likely a shared secret/nonce)
- If MMgr64 dies or token is invalid → refuse to continue
- MMgr64 likely enforces: client memory integrity, no unwanted DLL loads, no process escape
- **Breakpoint:** Where "valid object token" is checked; MMgr64 launch location

---

## Per-Binary Breakpoint Targets

### **Ascension.exe** (Entry point for addon scanning)
| Target | String Ref | Notes |
|--------|-----------|-------|
| Addon enum loop | `GetAddOnInfo`, `ADDON_LIST_UPDATE` | Hook after `GetNumAddOns` retrieval, before iteration |
| Version check | `checkAddonVersion`, `IsAddonVersionCheckEnabled` | Intercept version comparison |
| ScanDLL trigger | `ScanDLLStart("VersionURL", "DLLURL")` | Detect if scan is called; block download? |

### **Extensions.dll** (Main AC engine)
| Target | String Ref | Notes |
|--------|-----------|-------|
| Debugger check | `IsDebuggerPresent`, `DBG_ISDEBUGGERPRESENT` | Intercept return value or `NtQueryInformationProcess` call |
| Module scan loop | `CreateToolhelp32Snapshot`, `FindFirstFileW`, `FindNextFileW` | Detect banned process enum; can block or whitelist |
| MMgr64 spawn | "Refusing to launch MMgr64.exe without a valid object token" | Intercept token generation or spawn call |
| Opcode dispatch | `CMSG_BOT_DETECTED2`, `SMSG_CHECK_FOR_BOTS` | Intercept packet handler registration |
| Cheat opcode handlers | Movement/teleport cheat opcodes | Hook packet unmarshaling; fake compliance |

### **DivxTac.dll** (Detour manager)
| Target | String Ref | Notes |
|--------|-----------|-------|
| FunctionMap init | `?FunctionMap@ManagedDetourMgr` | Where monitored offsets are registered |
| Integrity loop | `AntiCheatService.DetectHackModules` | Hook to disable or fake checks |
| Alert sender | `AntiCheatService.SendModuleAntiCheatAlert` | Intercept before server report |

### **MMgr64.exe** (Watchdog)
| Target | String Ref | Notes |
|--------|-----------|-------|
| Token validation | Token check on startup | Fake or bypass |
| Integrity check | Module hash/signature verification | Return fake "OK" status |
| Process exit | On violation detection | Prevent termination or restart |

---

## Re Investigation Priorities

### Phase 1: Static Analysis (Now)
1. **Ghidra/IDA setup** — Load Extensions.dll, DivxTac.dll, identify key functions
2. **EntryPoint trace** — From Extensions.DLL EP to first AC thread spin-up
3. **Function signature extraction** — `AntiCheatService::*`, `DetourMgr::*` C++ mangled names
4. **Opcode dispatch table** — Find where SMSG/CMSG handlers are registered

### Phase 2: Dynamic Analysis (x32dbg)
1. **MMgr64 interception** — Break on spawn; observe token handshake
2. **Debugger check flow** — Trace `IsDebuggerPresent` result → branch
3. **Module scan walk** — Step through process enum, identify whitelist comparison
4. **Detour verification** — Trigger & log what `DetourMgr` actually checks

### Phase 3: Design Unlocker Strategy
1. **Hook placement** — Identify which functions to hook, patch, or bypass
2. **Watchdog neutralization** — Prevent MMgr64 from reporting violations
3. **Opcode spoofing** — Fake `SMSG_CHECK_FOR_BOTS` compliance
4. **Addon sandboxing** — Load addon Lua in way that evades version check

---

## Immediate Next Steps

1. **Copy Extensions.dll & DivxTac.dll to Ghidra project**
2. **Dump exported .NET metadata from DivxTac.dll** (use dnSpy or similar)
3. **String cross-reference** — Build graph of who calls `AntiCheatService` methods
4. **MMgr64 reverse** — Determine token format (likely CRC32, HMAC, or UUID)
5. **x32dbg breakpoints** — Set on key imports in Extensions.dll (QueryInformationProcess, StackWalk64, etc.)

---

## Key Hypotheses to Verify

- [ ] IsDebuggerPresent is hooked or wrapper-checked (not raw kernel call)
- [ ] DetourMgr uses CRC/SHA on suspected functions; patch detector first
- [ ] MMgr64 token is time-based or session-based (not static)
- [ ] BannedProccesses whitelist can be bypassed by renaming/cloaking process
- [ ] Addon scanning is Lua-side only (can be hooked in Lua runtime)
- [ ] Network botting detection is speed-check + impossibility heuristics (not client-side state validation)
