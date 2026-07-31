# FRIDA probe plan — Ascension.exe runtime instrumentation

Complements static analysis: `11_extensions_ac_map.md`, `11a_divxtac_ac_logic.md`, `11c_extensions_sink_body.md`, `11e_mmgr64_memorybridge.md`. Consumes and extends the stub already in `re/scripts/frida_probe.js` (attach-only, currently just enumerates modules + hooks CreateProcessW for MMgr64 filter).

**Goal.** Confirm on the wire what static RE says on paper: (a) which of Extensions.dll's 14 `DBG_*` vectors ever trip, (b) what strings DivxTac.dll's Detect* methods observe in the wild, (c) what opcodes actually go out on `ClientServices::fpSendPacket2` (should be 1311/1312 only per AC), (d) full module load timeline. **Design doc only — no hooks land yet.**

**Ground-truth VAs used below** (all x86, imagebase in parens):

| Symbol | VA | Base | Source |
|---|---|---|---|
| Extensions sink `FUN_100b5650` | `0x100b5650` | 0x10000000 | 11c §1 |
| Extensions VP callsites (4) | `0x1000106b`, `0x100010e4`, `0x100a0a10`, `0x100a0a2e` | 0x10000000 | `xref_imports.py Extensions.dll VirtualProtect` |
| Extensions send-call (`call esi` on packet) | `0x100b5993` | 0x10000000 | 11c §1 step 3 |
| Extensions latch byte | `0x10bdc24c` | 0x10000000 | 11c §1 step 4 |
| DivxTac `DetectHackProcesses` | `0x1000???` (token 0x06000008) | 0x10000000 | 11a §1 (dnSpy) |
| DivxTac `DetectHackModules` | `0x10003094` | 0x10000000 | 11a §2 |
| DivxTac `DetectHackTitles` | via -Module- | 0x10000000 | 11a §1 |
| DivxTac `DetectDebugger` | `0x10002ec4` | 0x10000000 | 11a §3 |
| DivxTac `SendModuleAntiCheatAlert` | `0x10002fa8` | 0x10000000 | 11a §5 |
| DivxTac `SendProcessAntiCheatAlert` | `0x100022fc` | 0x10000000 | 11a §5 |
| DivxTac `AntiCheatThreadLoop` | `0x100035bc` | 0x10000000 | 11a §1 |
| Client `ClientServices::fpSendPacket2` | `0x006B0970` | 0x00400000 | 11c §1 trampoline table slot 0x10bca1F0 |
| Client CDataStore ctor | `0x00401050` | 0x00400000 | 11c §1 slot 0x10bca0bc |

Because DivxTac and Extensions **share the same load base (0x10000000)** and are separate modules loaded at different addresses at runtime, every VA below must be resolved through `Process.findModuleByName(...).base + (VA - 0x10000000)` — never hard-coded.

---

## (1) Attach vs spawn — safety against DivxTac PEB check

### The check
- **DivxTac.dll+0x2EC4 (`DetectDebugger`, token 0x0600000B)** is a P/Invoke to `kernel32!IsDebuggerPresent` (11a §3, verified L481 of `-Module-.cs`). That P/Invoke resolves to the real kernel32 export and reads `PEB->BeingDebugged` inside kernel32. It is **not** a direct PEB inline read.
- **Extensions.dll vector 1 (`DBG_BEINGDEBUGGEDPEB`)** is a direct PEB read (`mov eax, fs:[0x30]; movzx eax, [eax+2]`), one of the 14 vectors that feed `FUN_100b5650` (11c). This one cannot be defeated by hooking `IsDebuggerPresent`; it needs the `PEB.BeingDebugged` byte to be zero at read time.
- **Extensions.dll vector `DBG_ISDEBUGGERPRESENT`** goes through the kernel32 export and IS hookable via `IsDebuggerPresent`.

### Frida agent in-process visibility
Frida spawns/loads a `frida-agent-*.dll` and starts `gum-js-loop` and `gum-js-thread` threads in the target. Neither modifies `PEB.BeingDebugged` on its own. Neither runs a Windows debug loop (attach mode = pure ptrace-equivalent via `NtCreateThreadEx` + remote page write; spawn mode uses `DebugActiveProcess` briefly to break-on-entry then `DebugActiveProcessStop`). Concrete implications:

- **Attach after game start (recommended)**: no `DebugActiveProcess` window at all. `PEB.BeingDebugged` remains 0. `NtQueryInformationProcess(ProcessDebugPort)` returns 0. `CheckRemoteDebuggerPresent` returns 0. This means Extensions vectors 1–5 are silent by default — **no need to spoof anything at all** for the debugger-flag family. This is the biggest safety win.
- **Spawn mode (`frida -f Ascension.exe -l probe.js`)**: uses debug-attach briefly during suspended-start. If the AC thread starts before we call `DebugActiveProcessStop` we tripline vectors 1/3/5 immediately. AC thread startup timing is not guaranteed. **Avoid unless you have a reason** (e.g. you need to hook something that runs before the game loop and there is no time to attach post-boot).
- Frida's `gum-js-thread`/`gum-js-loop` names ARE visible via `NtQueryInformationThread` / `Thread32First`. DivxTac has no thread enumeration; Extensions has no thread enumeration either (14 vectors are all self-checks). **No known thread-name check in either binary** (confirmed by absence of `NtQueryInformationThread`/`CreateToolhelp32Snapshot` in both import xrefs).
- The one residual risk: `_beginthreadex` inside Frida agent shows up as an extra loaded module (`frida-agent-32.dll`, `frida-agent-64.dll`). Extensions.dll does not enumerate loaded modules; **DivxTac.dll DOES** (`Process.GetCurrentProcess().Modules` in `DetectHackModules`, 11a §2). Match key is `ModuleName.ToLower()` against the server-pushed banned list. `frida-agent-*.dll` is unlikely to be in the banned list at first, but the server can push it via opcode 35 mid-session. **Mitigation** in hook §5.

### Decision
- **Default: attach mode.** `frida -n Ascension.exe -l frida_probe.js` **after** login screen has rendered (t ≈ 8–15 s post-launch on typical hardware). Extensions VP unpack is done by then (see §3). DivxTac's `AntiCheatThreadLoop` has started but the first `DetectDebugger` call is at the end of a 120 s cycle, so attaching within the first minute gives us one full cycle to install hooks before the debugger check fires.
- **Spawn mode is a lift-and-drop test only**: use only to capture module-load ordering with `LoadLibraryW` hook, then detach immediately (before DivxTac AntiCheatThread start, which is ~2–5 s post-init).

---

## (2) Hooks to install

All addresses are resolved as `mod.base + (VA - 0x10000000)` for Extensions/DivxTac and `mod.base + (VA - 0x00400000)` for Ascension.exe. Every hook is `Interceptor.attach` (not replace) unless noted. Every hook emits one JSON line per invocation (schema in §4).

### H1 — Extensions.dll `FUN_100b5650` (the 14-vector sink)
- **Address**: `Extensions.base + 0xB5650`.
- **Convention**: `__cdecl`, 2 args `(int vector_code, int extra)`; caller-esp captured at `[ebx+8]`/`[ebx+0xC]` (11c §1).
- **Read args from `this.context.esp`** at `onEnter`: retaddr at `[esp]`, `vector_code` at `[esp+4]`, `extra` at `[esp+8]`.
- **Blob (payload)**: not directly in args. To capture the packet, hook the `call esi` at `0x100b5993` instead (or hook `ClientServices::fpSendPacket2` per H4 which sees ALL outgoing packets, this alarm included).
- **Caller RA**: `Memory.readU32(esp)`. Compare against the 14 known caller VAs:
  ```
  0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954
  0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd
  0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4
  ```
  Map RA → vector name (0..20 per 11c step 2 table). If RA is NOT in that set, log `caller_unknown=true` — indicates a 15th vector we missed.
- **Severity mapping**: not stored — Extensions sink treats every vector as equivalent (single opcode 1311 with a display string). "Severity" == the `DBG_*` enum index, which IS the `vector_code` arg.

### H2 — DivxTac.dll Detect* trio
Each hook fires on entry only (managed `__clrcall`, no useful return). Log `A_0` (the dummy stack cookie/`this`), `report` (bool), `sleep` (bool).
- **H2a `DetectHackProcesses`** at `DivxTac.base + (VA-0x10000000)` — VA still to confirm from dnSpy `-Module-.cs`; use `dnSpy.Console.exe -t DetectHackProcesses DivxTac.dll` to pull it. Log entry event only; the interesting data is in the `SendProcessAntiCheatAlert` hook (H3b) which fires from inside it.
- **H2b `DetectHackModules`** at `DivxTac.base + 0x3094`. Log entry.
- **H2c `DetectHackTitles`** — similar; get VA from dnSpy token 0x0600000C ish.
- **H2d `DetectDebugger`** at `DivxTac.base + 0x2ec4`. Log entry. This is where `IsDebuggerPresent` P/Invoke is issued — we will see the P/Invoke fire in H6a immediately after this entry, which is the cleanest way to correlate.

### H3 — DivxTac.dll Send* pair (opcode 1311 emitters, PRE-`fpSendPacket2`)
Capture the 3 payload strings before they land in `CDataStore`.
- **H3a `SendModuleAntiCheatAlert`** at `DivxTac.base + 0x2fa8`. Args (managed): `(A_0, ProcessModule m)`. On entry, walk `m` fields to log `ModuleName`, `MainWindowTitle` (from `Process.GetCurrentProcess()`), `FileName`. Simplest: don't parse managed objects from Frida (fragile) — instead, hook the underlying `fpPutString` calls between opcode-write and finalize inside the same function. Use the range `[0x10002fa8 .. next fpSendPacket2 call]` and `Interceptor.attach(..., { onEnter: ... })` on each `push`-of-string-pointer. Simpler yet: rely on H4 which sees the fully-serialized packet.
- **H3b `SendProcessAntiCheatAlert`** at `DivxTac.base + 0x22fc`. Same approach.

### H4 — `ClientServices::fpSendPacket2` (opcodes on the wire, THE single most valuable hook)
- **Address**: `Ascension.exe base + 0x2B0970` (VA `0x006B0970` per 11c trampoline table). Verify with `disasm_window.py Ascension.exe 0x006B0970 --before 4 --after 10` — expect a thiscall prologue.
- **Convention**: `__thiscall void(ClientServices* this, CDataStore* ds)` — ECX = `this`, `[esp+4]` = `ds`.
- **Read CDataStore layout at `ds`**: buffer pointer at a well-known offset. From 11c: `CDataStore` is built by client fn `0x00401050`; opcode is a `PutInt32` (little-endian u32) that lands as the FIRST written int after any small header. To pin the offset, inspect a synthesized capture: log `hex(Memory.readByteArray(ds, 0x40))` on the first 3 invocations and identify the u32 that equals 1311/1312 or a known chat opcode. Then hard-code the offset.
- **What to log per call**:
  - `opcode` (u32 at the discovered offset)
  - `size` (from CDataStore length field — probe like opcode)
  - `payload_hex` (first 128 bytes)
  - `caller_ra` (`this.returnAddress`) — this tells us WHICH call site sent it. Cross-ref against DivxTac `SendModuleAntiCheatAlert` epilogue RA / Extensions `0x100b5993+5` / normal client packet senders.
- **Purpose**: catches 1311 (CMSG_ANTICHEAT_ALERT) and 1312 (CMSG_ANTICHEAT_VERSION) IN FLIGHT, whichever module fired them (Extensions native OR DivxTac managed). This is the single ground-truth confirmation that the alert wire format is what static RE says.

### H5 — `kernel32!LoadLibraryW` (module load fingerprint)
- **Address**: `Module.findExportByName("kernel32.dll", "LoadLibraryW")`.
- **Log**: `Memory.readUtf16String(args[0])` on entry, `retval.toString()` on leave (module base), `Thread.backtrace(context, Backtracer.ACCURATE).slice(0,5)` on entry.
- **Purpose**: reveal load order of Extensions.dll, DivxTac.dll, MMgr64 broker helpers, discord_game_sdk.dll, d3d9.dll. Confirms the "Extensions unpacks before DivxTac starts its thread" assumption underpinning §3.
- Also hook `LoadLibraryExW` and `LdrLoadDll` (ntdll) for completeness — some AC-adjacent DLLs use `LOAD_WITH_ALTERED_SEARCH_PATH`.

### H6 — Optional: `kernel32!IsDebuggerPresent`
See §5.

### H7 — Optional: MemoryBridge IPC (`CreateFileMappingW`/`MapViewOfFile`)
Not core to AC but valuable as a side channel — confirms MMgr64 protocol v3 handshake. Log on `MapViewOfFile` return the first 16 bytes of the mapping. Do only if session budget allows.

---

## (3) Timing safety — attach after Extensions self-unpack

### The window
Extensions.dll has 4 direct `VirtualProtect` callsites (verified via `xref_imports.py Extensions.dll VirtualProtect`):

```
call @ 0x1000106b        ; early runtime init path (near DllMain)
call @ 0x100010e4        ; early runtime init path
call @ 0x100a0a10        ; self-unpack of .vm_sec (RX flip after RW copy-in)
call @ 0x100a0a2e        ; self-unpack of .vm_sec (RX flip, page 2)
```

The `.vm_sec` section (VMProtect stub, 33 KB, VA 0x10d6e000..0x10d76200) is the only region that starts read-write and gets flipped to RX by the last two VPs. **Sink FUN_100b5650 sits in `.text` (0x10001000..0x10b195eb), NOT in `.vm_sec`** (11c TL;DR). So our hook target for H1 is writable-executable from DllMain onward — the two later VPs only affect `.vm_sec`, which we do not touch.

BUT: `Interceptor.attach` uses inline hooking (writes a 5-byte JMP into the target prologue via `NtProtectVirtualMemory` from Frida agent). That write MUST happen after Extensions has finished writing to its own `.text` (any last-minute IAT patching, VMP init pass), otherwise our hook can be overwritten mid-session.

### Recommended settle discipline
1. **Start Frida attach no earlier than "login screen visible"** (empirically ≥8 s post-launch, typically 12–20 s). At that point Extensions DllMain is done, VMP `.vm_sec` is flipped RX, IAT patching is complete. Sanity check inside the agent: on init, read one byte of `FUN_100b5650` (`Extensions.base+0xB5650`) and confirm it is `0x53` (`push ebx`, the known prologue byte per 11c). If not, wait 500 ms and retry up to 10× before installing hooks.
2. **Do NOT install hooks in `Frida.attach` callback synchronously.** Wrap all `Interceptor.attach` calls in a `setTimeout(installHooks, 2000)` inside the agent script. The 2 s gives the agent's own JIT init and Frida's thread-suspension protocol time to complete after the moment of injection.
3. **Verify LoadLibrary saw all three modules** (H5 hook must have logged `Extensions.dll`, `DivxTac.dll`, and MMgr64 broker DLLs — if any of the three is not in `Process.enumerateModules()` at hook-install time, abort and retry with a longer settle).
4. **Never hook a byte inside `.vm_sec`** (0x10d6e000..0x10d76200). No AC path lives there per 11c; if any future hook target does, use `Stalker` (trace-based, no inline patching) instead of `Interceptor.attach`.

### Ordering constraint on H1
`FUN_100b5650` prologue is the natural attach point (`push ebx` at byte 0 is a stable 1-byte instruction, 5-byte JMP fits cleanly). Frida picks its own thunk placement.

---

## (4) Log schema — JSON lines, one event per line

All events emit to `console.log(JSON.stringify(evt))`. Frida CLI is redirected to `frida_probe.log` on stdout. Schema:

```jsonc
// Common envelope
{
  "t":  1737398412.123,       // Date.now()/1000, high-res
  "tid": 6032,                 // Process.getCurrentThreadId()
  "ev": "H1_ext_sink",         // event id — one of the H* below
  "mod_base_ext":  "0x03110000",  // Extensions base at process runtime (rebased hints)
  "mod_base_div":  "0x03470000",
  "mod_base_ac":   "0x00400000",  // Ascension.exe (usually image base)
  ...event-specific fields...
}
```

Per-event fields:

- **`H1_ext_sink`** (Extensions FUN_100b5650 entry)
  - `vector_code` (int 0..20)
  - `vector_name` (string, from 21-entry table — hardcoded in script)
  - `extra` (int, per-vector payload)
  - `caller_ra` (hex string)
  - `caller_known` (bool, true iff `caller_ra` is one of the 14 known VAs above)
  - `latch_before` (byte at `Extensions.base+0xBDC24C` at entry — 0/1)

- **`H2_divx_detect`** (subtype `procs | modules | titles | debugger`)
  - `sub` ("procs" | "modules" | "titles" | "debugger")
  - `report` (bool)
  - `sleep` (bool)

- **`H3_divx_alert`** (SendModule/ProcessAntiCheatAlert entry — optional if H4 covers it)
  - `sub` ("module" | "process")
  - `payload_strs` (`[str1, str2, str3]` — read from managed args if feasible, else "<see H4>")

- **`H4_sendpacket2`** (fpSendPacket2 entry — THE canonical wire event)
  - `opcode` (int)
  - `size` (int)
  - `payload_hex` (string, first 128 bytes hex)
  - `caller_ra` (hex string)
  - `caller_module` (string; look up `Process.findRangeByAddress(caller_ra).file.path`)
  - `is_ac_alert` (bool, true iff opcode ∈ {1311, 1312})

- **`H5_loadlibrary`** (LoadLibraryW enter+leave paired)
  - `path` (string, UTF-16)
  - `base` (hex string, from leave)
  - `caller_module` (string)
  - `backtrace` (array of hex strings, ≤5 frames)

- **`H6_isdebuggerpresent`** (if enabled)
  - `caller_ra` (hex)
  - `caller_module` (string) — should be DivxTac.dll for AC calls
  - `will_return` (int, 0 always if we're clean; log-only, don't force)

- **`H_meta`** (startup)
  - `agent_version`, `frida_version`, `arch`, `modules_seen` (array of `{name,base,size}`), `install_delay_ms`.

- **`H_error`** (any exception during hook)
  - `where` (H1/H2/...), `msg` (Error.toString()).

Log file: `C:\Ascension\Workspace\RaijinLab\re\ac_analysis\frida_run_<yyyymmdd_hhmmss>.jsonl`. Post-process with `python re/scripts/xref_imports.py`-style helpers (write a new `re/scripts/frida_log_summary.py` that groups by `ev`, counts opcodes on H4, and cross-references H1 vector_names to H4 opcode-1311 hits within a ±100 ms window).

---

## (5) Anti-detection — what to hide, what NOT to hide

### What Frida in attach mode already handles for free
- `PEB.BeingDebugged` = 0 (never set — no `DebugActiveProcess`).
- `PEB.NtGlobalFlag` = normal (no heap debug flags).
- No debug port (`NtQueryInformationProcess(ProcessDebugPort)` = 0).
- No hardware breakpoints in DR0-DR7 (Frida uses inline JMPs, not HW BPs).
- `CheckRemoteDebuggerPresent` = 0.
- No `INT3` breakpoints in target `.text` (again, inline JMPs).

**All of these cover 12 of the 14 Extensions vectors and DivxTac DetectDebugger for free.** No spoofing needed for the debugger family in attach mode.

### What still needs handling

**(a) `DBG_FINDWINDOW` (Extensions vector 6).** Extensions calls `USER32!FindWindowW` with debugger window class names (`OLLYDBG`, `WinDbgFrameClass`, `x64dbg`, `IDA`, etc. — exact list is XOR-encrypted in the vector body at `0x100b7020` per 11c). Frida agent creates no debug window. However if the analyst has any of those tools open alongside the game, vector 6 will fire.
- **Hook**: replace `USER32!FindWindowW` and `FindWindowA` with a wrapper that returns `NULL` iff the class name (arg0) contains any of `OLLYDBG|WINDBG|x64DBG|IDA|IMMUNITY|CHEATENGINE|WINEDIT`. Log every replaced hit as `H_spoof` for audit.
- Do NOT blanket-null every `FindWindowW` — the game uses it legitimately for `GxWindowClass` or similar. Only filter against the known debugger class allowlist. Extract the exact strings from the vector 6 body first (`disasm_window.py Extensions.dll 0x100b7020 --after 80` and decode the XOR-obfuscated stack pushes) so the filter list matches Extensions' list exactly.

**(b) `DBG_PROCESSFILENAME` (Extensions vector 10).** Reads `GetModuleFileNameW(NULL, ...)` and compares against a bad-basename list (`ollydbg.exe`, etc.). Same story: Frida doesn't rename the target process, so this only fires if analyst-tool processes are running. Handled by simply not running those tools alongside.

**(c) `IsDebuggerPresent` — DivxTac side.**  DivxTac.dll's `DetectDebugger` at `+0x2EC4` is a P/Invoke to `kernel32!IsDebuggerPresent`. In attach mode with clean PEB this **already returns 0** with no intervention. However if you MUST use spawn mode, replace `kernel32!IsDebuggerPresent` with a stub that returns 0:
  ```js
  Interceptor.replace(Module.findExportByName('kernel32.dll','IsDebuggerPresent'),
      new NativeCallback(function(){ return 0; }, 'int', []));
  ```
  Log a `H_spoof` event on every call so we can count how often DivxTac actually asks. Do NOT also hook Extensions' `DBG_ISDEBUGGERPRESENT` vector (`0x100b7189` caller) via export — Extensions vector 3 uses the export too, so the same spoof covers both. Extensions vector 1 (`DBG_BEINGDEBUGGEDPEB`) reads PEB directly and IS NOT COVERED — attach-mode + clean PEB is the only defense there.

**(d) DivxTac module-name scan seeing `frida-agent-*.dll`.** Real risk if server pushes an updated banned list including "frida" while probe is live. Defense in depth:
  - Rename the Frida agent DLL on disk before injection (`copy frida-agent-32.dll aux32.dll`, inject via `frida --realm=native --file=aux32.dll`). Not a fully-supported flag in every Frida build; alternative:
  - Hook `Process.GetCurrentProcess().Modules` at the CLR reflection level. That is heavy. Simpler: hook the outbound side — `Interceptor.attach` on `DivxTac.SendModuleAntiCheatAlert` and in `onEnter`, inspect the module name (via managed field walk) and `this.context.eip = <RA of end-of-function skip>` to swallow the alert if it names `frida`. **Cost**: this suppresses a real alert, so log it loudly. Only enable if seen firing.
  - Cheapest observation-only mitigation: run probe for one AntiCheatThreadLoop cycle (120 s) and detach before any server-push updates the banned list.

### What NOT to hide
- Do not patch the Extensions latch byte (`Extensions.base+0xBDC24C`). Leaving it at its natural value gives us H1 hits per vector-firing which is the whole point.
- Do not `Interceptor.replace` the sink (`FUN_100b5650`) with a no-op. That would stop the packet from going out AND we'd miss the H4 wire-side data. Passive observation only.

---

## (6) Sequenced runbook

Prereqs (one-time):
- `pip install frida-tools` (Windows, 32-bit-capable — `frida --version` must print the Python-side version).
- `re/scripts/frida_probe.js` extended per §2. Suggest new location: `re/scripts/frida_ac_probe.js` (keep the existing minimal `frida_probe.js` as-is for baseline module-enum runs).
- `re/scripts/frida_log_summary.py` (new) for post-processing.

Runbook (each session):

**(a) Start the game normally.** Double-click Ascension.exe or launcher. Do NOT attach yet. Wait until the login screen is fully rendered (typically 10–20 s). This guarantees Extensions.dll DllMain, `.vm_sec` unpack, and the `ClientServices` singleton are all initialized before we perturb anything.

**(b) Attach Frida to the running process.**
```
frida -n Ascension.exe -l re/scripts/frida_ac_probe.js -o C:/Ascension/Workspace/RaijinLab/re/ac_analysis/frida_run_$(date +%Y%m%d_%H%M%S).jsonl
```
The agent's `H_meta` line prints on attach with `install_delay_ms`. If install fails a byte-check on `FUN_100b5650` prologue, it retries up to 10× at 500 ms; if all retries fail, it exits cleanly and logs `H_error`.

**(c) Install hooks.** Agent does this ~2 s after attach (per §3). Watch stdout for:
```
{"ev":"H_meta", ..., "hooks_installed": ["H1","H2a","H2b","H2c","H2d","H4","H5"]}
```
If any hook is missing, check `H_error` events for the reason (usually address resolution — a module wasn't loaded yet).

**(d) Run one full AntiCheatThreadLoop cycle (~120 s).** Log in and enter the world. Stand idle in a safe area (Stormwind bank, Dalaran fountain). The cycle:
- t=0 (probe start): DetectHackProcesses fires → H2_procs event → any bad process hit → H3+H4 opcode 1311
- t=~60 s: DetectHackModules → H2_modules → any hit → H3+H4 1311. Concurrent with any Extensions vector that fires (H1 events, then H4 1311 with `caller_ra` in Extensions).
- t=~120 s: DetectHackTitles → H2_titles → any hit → H3+H4 1311. Immediately after: DetectDebugger → H2_debugger → (should be no hit; if hit, H6 shows the IsDebuggerPresent call).
- Server may at any point send opcode 14 (AnticheatInitializeHandler) → client responds with **H4 opcode 1312** carrying HDD serial. Or opcode 35 (banned-list push) → immediate re-scan → burst of H2/H3/H4.

Give it a **full 150 s** to be sure we caught the whole cycle plus the debugger check tail.

**(e) Dump log and detach.**
```
Ctrl+D    # detaches Frida cleanly; Interceptor teardown restores prologues
```
Output file is already the JSONL log. Summarize with:
```
python re/scripts/frida_log_summary.py re/ac_analysis/frida_run_*.jsonl
```
Expected summary:
- `H4` events: N total, X with opcode 1311, Y with opcode 1312, rest are normal game traffic (movement, chat, spell casts).
- `H1` events: expect 0 in a clean environment. Any non-zero is a genuine tripped vector — cross-ref with `caller_ra` → vector_name.
- `H2_*` events: 4 per 120 s cycle (procs/modules/titles/debugger).
- `H5` events: one-time cluster at attach + occasional dynamic loads (talent tree UI, addon libraries).

### Sanity gates (run BEFORE trusting any conclusion)
1. **H4 baseline sanity**: within 30 s of world-entry, we should see H4 events for common opcodes (CMSG_MOVE_*, CMSG_MESSAGECHAT, etc.). If H4 fires 0 times, the fpSendPacket2 address is wrong — re-derive from the trampoline table (`disasm_window.py Extensions.dll 0x100b5984 --after 4` → confirm the call target VA then map to Ascension.exe).
2. **H2 cycle sanity**: expect exactly one `H2_debugger` every ~120 s. If we see it every 5 s something else is triggering the loop; if 0 in 150 s, the hook missed the address (managed methods can end up under different names after CLR JIT — verify VA with `dnSpy.Console.exe --md 0x0600000B DivxTac.dll`).
3. **H1 must correlate with H4**: every H1 event should be followed within ~50 ms by an H4 event with opcode 1311 whose `caller_ra` lies in Extensions.dll `[0x100b5993..0x100b5998]`. If H1 fires but no H4 1311 follows, the alarm was fired-and-dropped (interesting) OR our fpSendPacket2 hook is on the wrong function (bug).

---

## Deferred / out of scope

- **Extensions `.vm_sec` VMP stub**: not touched. Use Stalker not Interceptor if we ever need to.
- **MMgr64 IPC hooks**: covered in `11e_mmgr64_memorybridge.md`; H7 is optional and only adds noise unless a specific IPC question is being asked.
- **Kernel driver hooks**: DivxTac ships no kernel driver (11a §4). Nothing to hook there.
- **Network-layer capture**: an alternative to H4 is a Wireshark capture of the client's TCP stream with the game's XTEA session key. Out of scope for this document — the in-process H4 is strictly more information because it sees packets pre-encryption AND with the exact `caller_ra`.

---

## Cross-reference index

- Extensions sink body & 14 caller VAs: `notes/11c_extensions_sink_body.md`
- DivxTac managed detection cadence: `notes/11a_divxtac_ac_logic.md` (§1–§6)
- MMgr64 IPC layout (for optional H7): `notes/11e_mmgr64_memorybridge.md`
- Overall AC map: `notes/04_anticheat_map.md`, `notes/11_extensions_ac_map.md`
- Existing Frida stub: `re/scripts/frida_probe.js`
- New agent to author: `re/scripts/frida_ac_probe.js`
- New post-processor to author: `re/scripts/frida_log_summary.py`
- Log output dir: `re/ac_analysis/`
