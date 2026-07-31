# DivxTac.dll — Anti-Cheat Detection Logic (managed + native)

Binary: `C:\Ascension\Workspace\RaijinLab\re\dumps\DivxTac.dll` (x86, C++/CLI mixed-mode, image base 0x10000000).
Sources used:
- Managed IL/C# (authoritative — Ghidra failed on every `__clrcall` method): `re\dnspy_out\DivxTac\-Module-.cs` and `BannedProccessesManaged.cs`.
- Native Ghidra: `re\ghidra_out\DivxTac.dll.decompiled.c` — **all bodies `<decompile failed>`** (managed methods). Only the symbol table / import thunks are usable there.
- Import xref: only `CreateFileA`, `DeviceIoControl`, `GetLastError`, `Sleep`, `IsDebuggerPresent`, `GetProcAddress`, version APIs. **No** ReadProcessMemory / Crypt* / RtlComputeCrc32 / VirtualProtect / VirtualQuery.

Every AC method lives as a global function on the `<Module>` type; the `AntiCheatService`/`MasterHardDiskSerial` "structs" are empty `[NativeCppClass]` placeholders (`A_0` is a dummy `this`/stack cookie, never dereferenced meaningfully).

---

## 1. AntiCheatThreadLoop — cadence & structure  (VA 0x100035bc, token 0x0600000E)

```
AntiCheatThreadLoop():
    FixInvalidPtrCheck();          // one-time: resolves ClientServices fps / guard fixup
    SetMessageHandlers();          // register server-opcode handlers (see §6)
    for (;;) {
        DetectHackProcesses(&svc, report=true, sleep=true);
        this_thread::sleep_until( now + duration<i64, ratio<1,1>>(60) );   // 60 SECONDS
        DetectHackModules  (&svc, report=true, sleep=true);
        this_thread::sleep_until( now + duration<i64, ratio<1,1>>(60) );   // 60 SECONDS
        DetectHackTitles   (&svc, report=true, sleep=true);
        DetectDebugger     (&svc);
    }
```

- Full outer cycle ≈ **120 s of coarse sleep** (two `ratio<1,1>` = 60-second `sleep_until` waits) + enumeration time. There is **no** sleep after DetectDebugger before looping.
- Coarse waits use `std::this_thread::sleep_until(steady_clock)` via `_To_absolute_time`, **not** the kernel32 `Sleep` thunk (Sleep@0x100084a7 is imported but unused by the loop).
- Fine-grained throttle: when `sleep=true`, each of DetectHackProcesses / Modules / Titles inserts a **50 ms** `sleep_until` (`duration<i64, ratio<1,1000>> = 50`) **between every enumerated item** (each process / module / window). This is a per-item CPU throttle, not the loop cadence.
- The thread is a raw `std::thread` spun up at module init (`std::thread::_Start`, `_beginthreadex`), detached (`std.thread.detach`). It is fire-and-forget; the loop never exits.

`report`/`sleep` are the two `bool` params: `report` gates whether a violation actually emits a packet; `sleep` gates the 50 ms per-item throttle. Thread-loop calls pass `(true,true)`; the banned-list handler calls pass `(true,false)` for an immediate one-shot re-scan.

---

## 2. DetectHackModules — NAME comparison, NOT hashing  (VA 0x10003094, token 0x0600000A)

```csharp
foreach (ProcessModule m in Process.GetCurrentProcess().Modules) {
    List<string> banned = BannedProccessesManaged.GetInstance().GetNormalizedManagedModules();
    string name = m.ModuleName.ToLower();
    if (banned.Contains(name) && report)
        SendModuleAntiCheatAlert(&svc, m);
    if (sleep) sleep_until(now + 50ms);
}
```

**Definitive: pure module-NAME string matching. No hashing, no byte-compare, no memory read of the module image.**
- Iterates the *current process's* loaded modules (`Process.GetCurrentProcess().Modules`).
- Match key = `ModuleName.ToLower()` compared by `List<string>.Contains` (exact, case-normalized equality) against the server-supplied banned list.
- The banned list is normalized in `BannedProccessesManaged.SetNormalizedManagedModules` (`BannedProccessesManaged.cs` L133): each entry = `new string((char*)raw).ToLower() + ".dll"`. So the list holds lowercase `name.dll` strings; the loop compares the module's `ModuleName` (already includes extension, e.g. `mhook.dll`) lowercased. **Confirms the `.ToLower() + ".dll"` name-match** described in ground truth.
- It never touches `m.BaseAddress` / module bytes / `m.FileName` for comparison (FileName is only *reported* in the alert, §5).

---

## 3. DetectDebugger — technique  (VA 0x10002ec4, token 0x0600000B)

```csharp
if (IsDebuggerPresent() != 0) {
    CDataStore ds; fpInit(ds); fpPutInt32(ds, 1311);
    PutString(ds,"DEBUGGER"); PutString(ds,"DEBUGGER");
    PutString(ds, Process.GetCurrentProcess().ProcessName);
    fpFinalize(ds);
    fpSendPacket2(ClientServices::GetCurrent(), ds);   // opcode 1311
    fpDestroy(ds);
}
```

**Single technique: kernel32 `IsDebuggerPresent()`** — i.e. it reads only `PEB->BeingDebugged`.
- Maps to **exactly one** of the Extensions `DBG_*` vectors: `BEINGDEBUGGEDPEB`. It does **not** implement NTGLOBALFLAGPEB, NTQUERYINFORMATIONPROCESS, HARDWAREDEBUGREGISTERS, MOVSS, RDTSC, INT3CC, INT2D, etc. All of those richer vectors live in **Extensions.dll** (`ExtendedAnticheatMgr`, the 14-vector sink `sub_100b5650`), a separate subsystem. DivxTac's debugger check is the minimal PEB-flag check only.
- `IsDebuggerPresent` is imported 3× (thunk 0x10008298); this is the only call site that matters for detection.
- On hit it sends opcode **1311** (= CMSG_ANTICHEAT_ALERT, see §5) with payload strings `"DEBUGGER","DEBUGGER",<procName>`.

---

## 4. CreateFileA device + DeviceIoControl IOCTL — HWID (HDD serial), NOT a kernel driver

All `CreateFileA`/`DeviceIoControl` usage is inside `MasterHardDiskSerial` (the `MasterHardDiskSerial.cs` HWID class). Two acquisition paths:

**Path A — `ReadPhysicalDriveInNTUsingSmart` (VA 0x10003ec0):**
- `sprintf_s(buf,256, "\\\\.\\PhysicalDrive%d", 0)` → opens **`\\.\PhysicalDrive0`**.
- `CreateFileA(dev, 0xC0000000 (GENERIC_READ|WRITE), FILE_SHARE_READ|WRITE(7), NULL, OPEN_EXISTING(3), 0, NULL)`.
- `DeviceIoControl(h, 0x00074080 …)` = **SMART_GET_VERSION** (DFP_GET_VERSION), out=`GETVERSIONINPARAMS`(24).
- `malloc(545)`; set `SENDCMDINPARAMS.bCommandReg = 0xEC` (**ATA IDENTIFY DEVICE**);
  `DeviceIoControl(h, 0x0007C088 …, in=33, out=545)` = **SMART_RCV_DRIVE_DATA** (DFP_RECEIVE_DRIVE_DATA).
- Parses the 256-word IDENTIFY buffer (`PrintIdeInfo` → `flipAndCodeBytes`) to extract the drive **serial number** string.

**Path B — `ReadPhysicalDriveInNTWithZeroRights` (VA 0x10003b24):**
- `CreateFileA("\\\\.\\PhysicalDrive0", 0 access, FILE_SHARE_READ|WRITE(3), OPEN_EXISTING)` (zero-rights handle).
- `DeviceIoControl(h, 0x002D1400 …)` = **IOCTL_STORAGE_QUERY_PROPERTY** (in=`STORAGE_PROPERTY_QUERY`(12), out=10000) then fallback `DeviceIoControl(h, 0x00070020 …)`; extracts serial from `STORAGE_DEVICE_DESCRIPTOR`.

**Purpose: hardware fingerprint (HWID) = physical-disk serial number.** This is **not** a kernel anti-cheat driver and issues **no** custom driver IOCTL — the target is the standard OS storage stack (`\\.\PhysicalDrive0`) with well-known ATA/SMART/STORAGE IOCTLs. The serial is retrieved by `MasterHardDiskSerial.GetSerialNo` and reported to the server in `AnticheatInitializeHandler` (§6). This is the `MasterHardDiskSerial` hardware id referenced in the task.

---

## 5. What the alert senders actually transmit (ClientServices `fpSendPacket2`)

All senders build a `CDataStore` via the client's own function pointers (resolved by `FixInvalidPtrCheck`): `fpInit` → `fpPutInt32(opcode)` → payload `fpPutString`/`PutString` → `fpFinalize` → `fpSendPacket2(ClientServices::GetCurrent(), ds)` → `fpDestroy`. `fpSendPacket2` = `?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA` (thiscall `void(void* client, CDataStore*)`).

- **SendModuleAntiCheatAlert** (VA 0x10002fa8): opcode **`PutInt32(1311)`**, then 3 strings:
  `moduleInfo.ModuleName`, `Process.GetCurrentProcess().MainWindowTitle`, `moduleInfo.FileName`.
- **SendProcessAntiCheatAlert** (VA 0x100022fc): opcode **`PutInt32(1311)`**, then 3 strings read out of the `ProcessDescription` struct at offsets +0, +24, +48 (process name, window title, path — populated by `ProcessDescription.{ctor}` from the matched `System.Diagnostics.Process`).
- **DetectDebugger** inline sender: opcode **`PutInt32(1311)`**, strings `"DEBUGGER","DEBUGGER",<currentProcName>`.

**Opcode 1311 (0x51F) = CMSG_ANTICHEAT_ALERT** — the single client→server violation opcode for all three vectors (banned process, banned module, banned window title, debugger). Payload is always 3 human-readable **strings** (names/titles/paths). **No hashes, no memory dumps.**

`AnticheatInitializeHandler` uses a *different* opcode: **`PutInt32(1312)` then `PutInt32(4)` then `PutString(hddSerial)`** → **opcode 1312 (0x520) = CMSG_ANTICHEAT_VERSION**, carrying a subtype/int `4` and the HWID (hard-disk serial) string.

---

## 6. AnticheatInitializeHandler & AnticheatBannedProcessListHandler — server opcodes & state

`SetMessageHandlers()` (VA 0x100058c8) registers two handlers via
`ClientServices::SetMessageHandler(Opcodes, handler, context, ...)` (`?fpSetMessageHandler@ClientServices@@…`):

| DivxTac `Opcodes` (server→client msgId) | Handler | Context param |
|---|---|---|
| **14** | `AnticheatInitializeHandler` (VA 0x10005908) | `-559039810` = **0xDEADBABE** |
| **35** | `AnticheatBannedProcessListHandler` (VA 0x10005580) | `0xDEADBABE` |

(`0xDEADBABE` is a fixed magic passed as the handler `void* context`.)

**AnticheatInitializeHandler (server opcode 14):**
1. `SetMessageHandlers()` (idempotent re-register).
2. Constructs `MasterHardDiskSerial`, calls `GetSerialNo` → HDD serial (§4) into a `std::vector<char>` → `std::string`.
3. Sends client packet **opcode 1312 (CMSG_ANTICHEAT_VERSION)**: `PutInt32(1312)`, `PutInt32(4)`, `PutString(serial)` → `fpSendPacket2`.
4. Returns 1. **State set: none persistent** — it is a challenge/response: server pings opcode 14, client answers with its HWID + version tag 4.

**AnticheatBannedProcessListHandler (server opcode 35):**
Reads **three** length-prefixed string lists out of the incoming `CDataStore msg` (each: `PutInt32 count` then `count` × `GetString`):
1. list #1 → `BannedProccesses::GetInstance()->SetProccess(vec)`  → normalized (lowercased) into `normalizedProcessManagedStrings`.
2. list #2 → `BannedProccesses::SetModules(vec)` → lowercased **+ ".dll"** into `normalizedModulesManagedStrings`.
3. list #3 → `BannedProccesses::SetWindowTitles(vec)` → lowercased into `normalizedTitleManagedStrings`.
Then **immediately** runs a one-shot scan with `sleep=false`:
`DetectHackProcesses(true,false); DetectHackModules(true,false); DetectHackTitles(true,false); DetectDebugger();`
Returns 1.

**State set:** it populates the singleton `BannedProccesses` (native `std::vector<std::string>`) whose contents `BannedProccessesManaged` mirrors as normalized managed `List<string>`. **The banned lists are entirely server-driven** — pushed at runtime via opcode 35 — and are the sole data the Detect* functions match names against. Before opcode 35 arrives the lists are empty and detection is a no-op.

---

## CRITICAL — Integrity relevance

**DivxTac performs ZERO code integrity checking. It never hashes, checksums, CRCs, or byte-compares Extensions.dll, the client `.text`, or any module image — anywhere.**

Evidence:
- Imports contain **no** cryptographic/hash API (no Crypt*, no RtlComputeCrc32), **no** `ReadProcessMemory`, **no** `VirtualProtect`/`VirtualQuery`, **no** `ToolHelp`/section walking of image bytes. Only `CreateFileA`+`DeviceIoControl` (HDD serial), `IsDebuggerPresent`, `GetProcAddress`, version APIs, `Sleep`. (Confirms ground truth.)
- `DetectHackModules` compares module **names** (`ModuleName.ToLower()` vs server list) with `List.Contains` — no image bytes are read (§2).
- `DetectHackProcesses`/`DetectHackTitles` do substring matching on `ProcessName`/`MainWindowTitle` (`text.Contains(banned)`).
- `DetectDebugger` = `IsDebuggerPresent()` only (PEB flag).
- The only device I/O is standard storage IOCTLs to read a disk **serial number** for HWID (§4) — unrelated to code integrity.
- Alert packets (opcode 1311) carry **strings** (names/titles/paths); the init packet (1312) carries the HWID string. No memory contents or digests are ever transmitted.

Therefore all image/`.text` integrity hashing, the `DBG_*` multi-vector anti-debug battery, and any Extensions.dll self-check are the responsibility of the **separate Extensions.dll `ExtendedAnticheatMgr` subsystem** (14-vector sink `sub_100b5650`), **not** DivxTac. DivxTac is a lightweight, server-configured **name/title/debugger-flag scanner + HWID reporter**.

---

## Claude Verification (pass 2)

Independently re-verified against `re\dnspy_out\DivxTac\-Module-.cs` (dnSpy IL+C#) and the empty `[NativeCppClass]` stubs `AntiCheatService.cs` / `MasterHardDiskSerial.cs` / `Opcodes.cs`. All seven claims checked; every one **CONFIRMED**. Line numbers below are into `-Module-.cs` unless noted.

### (1) AntiCheatThreadLoop cadence 60s→60s→0s (120 s per full cycle) + 50 ms per-item throttle — CONFIRMED
- `AntiCheatThreadLoop` body @ L616-629. Two `sleep_until` calls with `duration<__int64, std::ratio<1,1>> = 60L` (L620 and L624), i.e. 60 whole seconds each (ratio 1/1 = seconds). Sequence is exactly: `DetectHackProcesses(true,true)` → sleep 60s → `DetectHackModules(true,true)` → sleep 60s → `DetectHackTitles(true,true)` → `DetectDebugger(&svc)` → loop. **No third sleep between Titles/Debugger and loop restart**, so "0s" for the third leg is literally accurate.
- Full outer cycle = **120 s coarse sleep + enumeration cost**; not "60 s per full cycle".
- Per-item 50 ms throttle when `sleep=true`: verified inside `DetectHackModules` @ L471 `duration<__int64,std::ratio<1,1000>> = 50L` → `sleep_until` @ L473 (ratio 1/1000 = milliseconds). Identical throttle exists in `DetectHackProcesses` @ L324 and `DetectHackTitles` @ L408.
- Uses `std::this_thread::sleep_until(steady_clock)` via `_To_absolute_time<__int64,ratio<1,1>>` (L869) and `_To_absolute_time<__int64,ratio<1,1000>>` (L839) — **not** kernel32 `Sleep` (imported but unused by the loop, consistent with Grok).

### (2) DetectHackModules compares `ModuleName.ToLower()` vs banned list; NAME-only — CONFIRMED
- Body @ L459-476. Exact managed IL:
  ```
  foreach (ProcessModule processModule in Process.GetCurrentProcess().Modules) {
      List<string> normalizedManagedModules = BannedProccessesManaged.GetInstance().GetNormalizedManagedModules();
      string text = processModule.ModuleName.ToLower();
      if (normalizedManagedModules.Contains(text) && report)
          <Module>.AntiCheatService.SendModuleAntiCheatAlert(A_0, processModule);
      if (sleep) <sleep_until +50ms>;
  }
  ```
- No `BaseAddress`, `Size`, `FileName`, or byte access is used for matching. `FileName` is only *reported* inside the alert (`SendModuleAntiCheatAlert` L594) — never compared.
- Banned-list normalization in `BannedProccessesManaged.SetNormalizedManagedModules` (`BannedProccessesManaged.cs` L133-156): each raw entry → `new string((sbyte*)ptr3).ToLower() + ".dll"`. So banned list holds lowercase `name.dll`; module.ModuleName (which already includes extension, e.g. `mhook.dll`) is lowercased and matched via `List<string>.Contains` — exact case-insensitive string equality.

### (3) DetectDebugger = `IsDebuggerPresent()` only (PEB flag) — CONFIRMED
- Body @ L479-509. Single condition `<Module>.IsDebuggerPresent() != null` at L481 gates everything. `IsDebuggerPresent` is a `[DllImport("KERNEL32.dll")]` P/Invoke declared at L5087. No NtQuery, DR0-DR3, RDTSC, INT2D, INT3, MOVSS, thread-context, or window-title debugger checks anywhere in DivxTac. This maps to exactly one Extensions `DBG_*` enum vector (`BEINGEBUGGEDPEB`); the other 13 are strictly Extensions territory.

### (4) MasterHardDiskSerial IOCTLs — CONFIRMED (with one small addendum)
`ReadPhysicalDriveInNTUsingSmart` @ L1852-1928:
- `CreateFileA("\\\\.\\PhysicalDrive0", 0xC0000000 (GENERIC_READ|WRITE), 7 (FILE_SHARE_READ|WRITE|DELETE), NULL, 3 (OPEN_EXISTING), 0, NULL)` @ L1857.
- `DeviceIoControl(h, 475264, ...)` @ L1877 — **475264 = 0x00074080 = SMART_GET_VERSION** ✅, output = 24-byte `GETVERSIONINPARAMS`.
- `malloc(545)` @ L1893, then `*(byte*)(ptr5 + 10) = 236` @ L1894 — sets `SENDCMDINPARAMS.bCommandReg = 0xEC` (**ATA IDENTIFY DEVICE**) ✅.
- `DeviceIoControl(h, 508040, in=33, out=545, ...)` @ L1896 — **508040 = 0x0007C088 = SMART_RCV_DRIVE_DATA** ✅.
- Error-string literal `"SMART_RCV_DRIVE_DATA IOCTL..."` @ L1907 self-confirms the IOCTL identity.

`ReadPhysicalDriveInNTWithZeroRights` @ L2057-2134:
- `CreateFileA("\\\\.\\PhysicalDrive0", 0 access, 3 (FILE_SHARE_READ|WRITE), NULL, 3, 0, NULL)` @ L2062 — zero-rights handle ✅.
- `DeviceIoControl(h, 2954240, in=12 STORAGE_PROPERTY_QUERY, out=10000, ...)` @ L2086 — **2954240 = 0x002D1400 = IOCTL_STORAGE_QUERY_PROPERTY** ✅. Error-string `"DeviceIOControl IOCTL_STORAGE_Q..."` @ L2129 self-confirms.
- **Addendum (not in Grok's note): a second IOCTL** `DeviceIoControl(h, 458912, in=0, out=10000, ...)` @ L2103 — **458912 = 0x00070020 = IOCTL_DISK_GET_DRIVE_LAYOUT** (harmless fallback; result is ignored beyond a failure log-string sprintf). Grok's note listed only 0x2D1400 for this path; the 0x70020 second call is auxiliary and does not change the "HWID, not AC driver" verdict.
- `getHardDriveComputerID` @ L2155-2162 prefers ZeroRights (calls `IsWindowsVersionOrGreater(5,1,0)` first) then falls back to SMART.
- **Purpose: HWID only.** No custom-driver `.sys` is opened; both paths hit the standard OS storage stack. Serial is extracted via `PrintIdeInfo` → `ConvertToString` / `flipAndCodeBytes` (offsets 10-19 = ATA IDENTIFY word range for **Serial Number**).

### (5) All three Send*Alert paths emit opcode 1311 with 3 strings; AnticheatInitializeHandler emits 1312 with subtype 4 + HDD serial — CONFIRMED
- `SendModuleAntiCheatAlert` @ L579-609: `fpPutInt32(1311)` @ L589; three `PutString` calls at L592-594 = `moduleInfo.ModuleName`, `Process.GetCurrentProcess().MainWindowTitle`, `moduleInfo.FileName`. ✅
- `SendProcessAntiCheatAlert` @ L512-576: `fpPutInt32(1311)` @ L524; three `fpPutString` calls at L534/542/550 read out of `ProcessDescription*` at offsets +0, +24, +48. ✅
- `DetectDebugger` inline sender: `fpPutInt32(1311)` @ L489; three `PutString` at L492-494 = `"DEBUGGER"`, `"DEBUGGER"`, `Process.GetCurrentProcess().ProcessName`. ✅
- `AnticheatInitializeHandler` @ L2861-2938: `fpPutInt32(1312)` @ L2889, then `fpPutInt32(4)` @ L2893, then `CDataStore.PutString(hddSerial)` @ L2894. ✅ Serial vector is built by `MasterHardDiskSerial.GetSerialNo(&mhds, &serialVec)` @ L2875.

### (6) Server-driven handlers: opcode 14 = Initialize, opcode 35 = BannedProcessList, magic context 0xDEADBABE — CONFIRMED
- `SetMessageHandlers` @ L3105-3111:
  - `fpSetMessageHandler((Opcodes)14, __unep@AnticheatInitializeHandler, -559039810)` @ L3108.
  - `fpSetMessageHandler((Opcodes)35, __unep@AnticheatBannedProcessListHandler, -559039810)` @ L3110.
- `-559039810` (int32) = `0xDEADBABE` (unsigned). Confirmed.
- `AnticheatBannedProcessListHandler` @ L2941-3101 reads **three** length-prefixed `basic_string` vectors from the incoming `CDataStore msg` (each: `int count = *(int*)(msg+20)`; advance +4; loop `count` × `CDataStore.GetString`; `emplace_back`), then calls `BannedProccesses.SetProccess` (L3066), `SetModules` (L3070), `SetWindowTitles` (L3074), then **immediately** re-scans: `DetectHackProcesses(true,false)` L3076 / `DetectHackModules(true,false)` L3077 / `DetectHackTitles(true,false)` L3078 / `DetectDebugger()` L3079 — one-shot with `sleep=false` (no 50 ms throttle), matching Grok.
- Note: `AnticheatInitializeHandler` re-invokes `SetMessageHandlers()` at L2863 on every receipt (idempotent re-arm).

### (7) INTEGRITY CLAIM: DivxTac performs ZERO code-integrity checking — CONFIRMED
- Import xref: only `CreateFileA`, `DeviceIoControl`, `CloseHandle`, `GetLastError`, `Sleep`, `IsDebuggerPresent`, `GetProcAddress`, `IsWindowsVersionOrGreater`/version APIs, plus C-runtime/MSVCR helpers. **No** `ReadProcessMemory`, `WriteProcessMemory`, `VirtualProtect`, `VirtualQuery`, `Module32*`, `CreateToolhelp32Snapshot`, `CryptAcquireContext`/`CryptCreateHash`/`CryptHashData`, `BCrypt*`, `RtlComputeCrc32`, `RtlImageNtHeader`, `LdrGetDllHandle`, `NtQuerySystemInformation`. Verified against `DivxTac.dll.imports_xref.txt`.
- Zero byte-level memory access to `Extensions.dll` `.text`, client `.text`, or any module image occurs in `DetectHackModules` — only `ProcessModule.ModuleName` is read, and only by string compare.
- Alert payloads carry only ASCII names/titles/paths (3 strings per 1311 packet); the HWID packet (1312) carries subtype `4` and the HDD serial string. Never a digest, never a memory blob, never a range.
- All 14 anti-debug vectors and any `.text`/section hashing live in **Extensions.dll** `ExtendedAnticheatMgr` (violation sink `sub_100b5650` @ 0x100b5650). DivxTac is orthogonal and inert w.r.t. code integrity.

### Deltas / refinements vs Grok's writeup
1. **Header cadence phrasing tightened:** Grok correctly wrote "60 s + 60 s + enumeration time"; task description "60s→60s→0s" is literally correct because there is no third sleep call before `DetectDebugger` or before looping back. Full outer cycle = 120 s coarse. No error in Grok's note.
2. **ZeroRights path second IOCTL:** Grok mentions "then fallback `DeviceIoControl(h, 0x00070020 …)`" — verified at L2103. It reads `STORAGE_DEVICE_DESCRIPTOR` output but the return value is *ignored* (only a failure sprintf is triggered on error); serial is already extracted from the 0x2D1400 output via `flipAndCodeBytes` on `STORAGE_DEVICE_DESCRIPTOR` offsets +12/+16/+20/+24 (VendorId / ProductId / ProductRevision / SerialNumber). This matches Grok's summary.
3. **Signed vs unsigned handler context:** `-559039810` is the actual int32 constant emitted; interpreting as u32 yields `0xDEADBABE`. Grok's `0xDEADBABE` characterization is correct.
4. No functional errors found in note 11a. All seven target claims stand.

### x32dbg / native breakpoint recommendations (per detection vector)
DivxTac image base = 0x10000000. All addresses are the managed function's native JIT-stub thunk RVA reported by dnSpy ("RVA: 0xXXXXX"); set BPs at `base + RVA`. Because these are mixed-mode C++/CLI methods, the JIT compiles them on first entry — the RVA is stable across runs since ngen isn't in play but dnSpy shows the **stub** entry. Prefer setting BPs on the specific `calli` / API import thunks for reliability.

| VA (image base 0x10000000) | Purpose | Safe bypass |
|---|---|---|
| `0x100035BC` (RVA 0x35B0) | `AntiCheatThreadLoop` entry — the whole loop | `ret` at entry (patch `C3` at 0x100035BC) neuters all polling; init handlers still register (they are re-armed inside the loop but also fired by server-triggered opcode 14 → `SetMessageHandlers` at L2863). Safer alternative: skip only the two `Detect*` calls at L619/623/627/628. |
| `0x100030A0` (RVA 0x3094) | `DetectHackModules` — banned-module scan | Patch entry to `xor eax,eax; ret` OR flip the branch at the `List<string>.Contains` result before `SendModuleAntiCheatAlert` (L465-467). Leaves loop intact; DetourMgr is unaware (no self-hash). |
| `0x10002ED0` (RVA 0x2EC4) | `DetectDebugger` | Patch entry `ret`, OR hook `IsDebuggerPresent@KERNEL32` (thunk 0x10008298) to always return 0. Zero risk: no import-integrity check. |
| `0x10003094`+`SendModuleAntiCheatAlert` @ `0x10002FA8` (RVA 0x2F9C) | Module alert emit path | Patch entry `ret` — prevents opcode 1311 for modules without touching detection logic. |
| `0x100022FC` (RVA 0x22F0) | `SendProcessAntiCheatAlert` — process/title alert emit | Same treatment: patch `ret`. Zero 1311 packets ever hit the wire. |
| `0x100058C8` (RVA 0x58BC) | `SetMessageHandlers` | Patch `ret` at entry. Server opcodes 14/35 will never be dispatched → banned list stays empty forever, detection is a no-op, no HWID leaks. Cleanest kill switch. |
| `0x10005908` (RVA 0x58FC-ish for AnticheatInitializeHandler) | HWID (opcode 1312) emitter | Patch entry `mov eax,1; ret` — server pings drop silently. |
| `0x10005580` (RVA 0x5574) | Banned-process-list ingest + one-shot rescan | Patch entry `mov eax,1; ret` — banned lists never populate. |
| Import `IsDebuggerPresent` IAT slot @ `0x10008298` (verify with `xref_imports.py DivxTac.dll IsDebuggerPresent`) | PEB-flag probe | IAT hook returning 0 kills the only debugger vector this DLL owns. |
| Import `DeviceIoControl` IAT slot | HDD serial collection | Filter/spoof IOCTLs 0x74080 / 0x7C088 / 0x2D1400 / 0x70020 on handle to `\\.\PhysicalDrive0` to return a fake serial or fail cleanly. |

**DetourMgr risk:** `DetourMgr.cs` exists as a class but its instance is only referenced for lock scoping (`ManagedDetourMgrlockRef`). It does **not** hash or verify code pages, and there is no DivxTac self-check pass over any of the above VAs. Any of the patches above will not raise a DivxTac-side alarm. (Extensions.dll `ExtendedAnticheatMgr` is a separate concern — if it hashes DivxTac's `.text`, that check is out-of-scope for this note.)
