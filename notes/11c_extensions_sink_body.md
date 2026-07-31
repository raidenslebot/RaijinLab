# 11c — Extensions.dll violation sink FUN_100b5650: body, cadence, integrity

Complementary to `11_extensions_ac_map.md` (surface: strings + xrefs) and `11a_divxtac_ac_logic.md` (DivxTac managed side). This note dissects the *action* the Extensions.dll anti-debug sink takes when any of its 14 vectors trips.

Analysis is entirely from raw disassembly (`re/scripts/disasm_window.py`) because Ghidra decompilation failed on the whole 0x100b5650..0x100b8xxx cluster (`<decompile failed: >` for every function in this range in `Extensions.dll.decompiled.c`).

---

## TL;DR

- `FUN_100b5650(int vector_code, int extra)` is the single per-vector alarm sink. It **builds a CDataStore packet with opcode 0x51F (1311 = `CMSG_ANTICHEAT_ALERT`)** using client-registered function pointers, **sends it** synchronously via the client's net-service singleton, sets a **local "alert fired" latch byte** at `0x10bdc24c`, and **spawns a short-lived helper thread** (`_beginthreadex`, start routine `FUN_100b5220`) that records the vector code into offset `+4` of the same singleton after a QPC-based delay.
- **No client-side kill, no hashing, no self-integrity check**. Sink and its callees never invoke `TerminateProcess`, `ExitProcess`, `MessageBox*`, `CryptHash*`, `CRC*`, `memcmp` on module ranges, `VirtualProtect`, `ReadProcessMemory`, `DeviceIoControl`, or driver ioctls. The alarm is **server-arbitrated**: Ascension.exe simply transmits the vector name + code and waits for the server's response (or, more typically, an out-of-band ban decision).
- Common parent of all 14 vectors is a single **unrolled monitor loop at `FUN_10a3dc20`** that calls each vector function sequentially with a latch-check between each, sleeps ~5 seconds (via `FUN_10a3d0f0`), and `jmp`s back to the top of the loop. The vector calls are guarded so that once any vector has fired, subsequent vectors in the pass are skipped until the singleton's version counter advances and resets the latch.
- Every byte in this subsystem — sink, 14 vector fns, parent loop, singleton getter — sits in the normal `.text` section (0x10001000..0x10b195eb). **None of it is inside `.vm_sec` (0x10d6e000..0x10d76200)**. It is straight-line x86, moderately obfuscated only by pushed-then-XORed 8-byte encrypted string tokens on the stack. VMProtect is not covering the AC path.
- Bypass is one-time and durable: any of (a) `mov byte [0x100b5650] = 0xC3` (turn the sink into a `ret`; __cdecl, caller cleans stack), (b) `mov byte [0x100b5993] = 0xC3` — the actual `call esi` that sends the packet — or (c) pre-set the latch `byte [0x10bdc24c] = 1` and hook the reinit path — kills all 14 vectors without touching anything Extensions.dll or DivxTac hash. No integrity subsystem in Extensions/DivxTac/MMgr64 verifies this region.

---

## (1) What `FUN_100b5650` does with its args

### Calling convention & args

Prologue at `0x100b5650`:

```
push ebx
mov  ebx, esp                  ; ebx snapshots CALLER'S esp before alignment
sub  esp, 8
and  esp, 0xFFFFFFF0           ; 16-byte align
add  esp, 4
push ebp                       ; frame chain via aligned stack
mov  ebp, [ebx+4]              ; read RET-addr off caller stack
mov  [esp+4], ebp
mov  ebp, esp
...
mov  edi, [ebx+8]              ; ARG1: vector code (0..20)
...
mov  eax, [ebx+0xC]            ; ARG2: extra int (per-vector detail)
```

`ebx` deliberately captures caller-esp before stack re-alignment, then args are read via `[ebx+8]` and `[ebx+0xC]`. Function is `__cdecl` (final epilogue is bare `ret`, not `ret imm16`, and caller cleans stack). Two integer arguments: `vector_code` (used to look up display string), `extra` (opaque per-vector, e.g. `PEB->BeingDebugged` byte value, register content, window handle, etc.).

### Body flow

Direct citations from disassembly of `FUN_100b5650` (VA 0x100b5650, file offset 0xB4A50, `.text`):

**Step 1 — construct CDataStore-like packet, opcode 0x51F = 1311 = `CMSG_ANTICHEAT_ALERT`.**

```
0x100b56d6  call [0x10bca0bc]              ; -> 0x00401050 (client fn: CDataStore ctor)
0x100b56dc  push 0x51F                     ; opcode 1311 = CMSG_ANTICHEAT_ALERT
0x100b56e1  lea  ecx, [ebp-0xB0]           ; this = local CDataStore
0x100b56e7  call [0x10bca0cc]              ; -> 0x0047B0A0 (client fn: SetOpcode/InitPacket)
```

The 7 slots `0x10bca0bc..0x10bca1f0` in `.data` are runtime callbacks populated by Ascension.exe at DLL load (each holds a pointer into Ascension.exe's `.text`, image base 0x00400000). Extensions.dll never resolves them itself — it depends on a "trampoline table" the client sets up:

| Slot        | Client VA  | Role (inferred from surrounding usage)          |
|-------------|-----------|--------------------------------------------------|
| 0x10bca0bc  | 0x00401050 | CDataStore construct (empty packet)              |
| 0x10bca0cc  | 0x0047B0A0 | Set opcode / begin write                          |
| 0x10bca0d8  | 0x0047B300 | Append string / write field                       |
| 0x10bca0fc  | 0x00401130 | Finalize / close packet                           |
| 0x10bca100  | 0x00403880 | Destructor                                        |
| 0x10bca1EC  | 0x00632B50 | Get net-service singleton (returns object ptr)    |
| 0x10bca1F0  | 0x006B0970 | Send-packet method on that singleton              |

**Step 2 — resolve vector display string from a 21-entry table at `0x10B2A380` and build a formatted payload.**

```
0x100b5778  cmp  edi, 0x14                  ; edi = vector_code
0x100b577b  ja   fallback
0x100b577d  push [edi*8 + 0x10B2A380]       ; -> const char* DBG_<name>
0x100b5784  lea  ecx, [ebp-0x78]
0x100b5787  call 0x100874E0                 ; std::string ctor from C-string
```

The table at `0x10B2A380` is 21 `{const char* ptr, size_t length}` pairs; slots 0..20 map exactly to the DBG_* enum documented in `11_extensions_ac_map.md`:

```
[ 0] DBG_NONE                     [11] DBG_HARDWAREDEBUGREGISTERS
[ 1] DBG_BEINGEBUGGEDPEB          [12] DBG_MOVSS
[ 2] DBG_CHECKREMOTEDEBUGGERPRESENT [13] DBG_RDTSC
[ 3] DBG_ISDEBUGGERPRESENT        [14] DBG_QUERYPERFORMANCECOUNTER
[ 4] DBG_NTGLOBALFLAGPEB          [15] DBG_GETTICKCOUNT
[ 5] DBG_NTQUERYINFORMATIONPROCESS [16] DBG_CLOSEHANDLEEXCEPTION
[ 6] DBG_FINDWINDOW               [17] DBG_SINGLESTEPEXCEPTION
[ 7] DBG_OUTPUTDEBUGSTRING        [18] DBG_INT3CC
[ 8] DBG_NTSETINFORMATIONTHREAD   [19] DBG_PREFIXHOP
[ 9] DBG_DEBUGACTIVEPROCESS       [20] DBG_INT2D
[10] DBG_PROCESSFILENAME
```

**Step 3 — write vector name + int fields into the packet, then send.**

```
0x100b584E  call [0x10bca0d8]     ; append string arg
0x100b5978  call [0x10bca0fc]     ; finalize
0x100b597E  mov  esi, [0x10bca1EC] ; esi := &SendPacket method (via getter slot)
0x100b5984  call [0x10bca1F0]     ; call getter -> eax = net-service singleton
0x100b598A  lea  ecx, [ebp-0xB0]  ; ecx = packet
0x100b5990  push ecx
0x100b5991  mov  ecx, eax         ; this = singleton
0x100b5993  call esi              ; *** SEND *** opcode 1311 goes on the wire here
```

XOR-obfuscated string tokens (paired 32-bit constants XOR'd into stack slots and passed to `[0x10bca0d8]`) supply two additional strings written into the packet — this matches the 3-string layout `SendModuleAntiCheatAlert`/`SendProcessAntiCheatAlert` documented in `11a_divxtac_ac_logic.md` for opcode 1311. Managed and native alarms share the same wire format.

**Step 4 — set the "alert fired" latch on the local singleton.**

```
0x100b5995  call FUN_100b5a70    ; magic-static singleton getter -> eax = 0x10bdc244
0x100b599A  push 8                ; new(8)
0x100b599C  mov  byte [eax+8], 1  ; *** LATCH byte [0x10bdc24c] := 1 ***
0x100b59A0  call operator_new     ; -> 8-byte struct, [struct] = vector_code
0x100b59AE  mov  [eax], edi
```

`FUN_100b5a70` is a classic MSVC magic-static: check `[0x10bdc250]` against a per-TLS version counter (`fs:[0x2c][X] + 0xC`); if not initialized, take a lock (`0x10ae70c0`), install vtable `0x10b2a42c` at `0x10bdc244`, zero `[0x10bdc248]` and byte `[0x10bdc24c]`, register a destructor (`0x10ae6b60`), unlock (`0x10ae7060`). Returns pointer to the 16-ish-byte singleton at `0x10bdc244`.

Singleton layout:
```
0x10bdc244  vtable (0x10b2a42c)
0x10bdc248  reserved (0)          // written +4 by helper thread = last vector code
0x10bdc24c  byte alert_fired = 1  // *** THE LATCH ***
```

**Step 5 — spawn secondary thread to record the vector code (delayed, non-blocking).**

```
0x100b59D3  call [0x10b1a50c]     ; api-ms-win-crt-runtime-l1-1-0.dll!_beginthreadex
             args (in push order):
               NULL   NULL   FUN_100b5220   [8-byte-struct with vector_code at +0]
               0      &thread_id
```

Thread proc `FUN_100b5220`:
```
0x100b5220  ...
0x100b5240  call FUN_100b5270      ; QPC-based delay loop, ~1e6..1e7 ticks
0x100b5245  call FUN_100b5a70      ; re-fetch singleton
0x100b524A  mov  [eax+4], esi      ; singleton.last_vector_code = vector_code
0x100b524D  call 0x10ae6446        ; release CRT sync (thread-shutdown assist)
0x100b5252..5A  operator delete(8-byte-struct)
0x100b525D  xor  eax, eax
0x100b5264  ret  4
```

The helper thread does no additional network activity, no MessageBox, no self-terminate. It just persists the last vector code after a delay long enough to defeat naive time-correlation. QPC constants observed: `0xF4240` (1e6, 1 second at 1 MHz QPC) and `0x989680` (1e7).

### What FUN_100b5650 does NOT do

Cross-checked by scanning the sink body and every callee reachable within two calls:

- No `TerminateProcess`, `ExitProcess`, `RaiseException`, `MessageBox*` invocation.
- No `CryptHash*`/`CryptAcquireContext*`/`BCrypt*` call (though `ADVAPI32!CryptAcquireContextA` @ IAT 0x10b1a00c is imported it is used elsewhere in Extensions.dll, not on the AC alarm path).
- No `memcmp` over module ranges. The only `memcmp`-like paths in the vectors compare CPU/OS-supplied bytes (e.g., `PEB->BeingDebugged`, `NtGlobalFlag`, DR0-DR7) to constants, not module bytes.
- No `VirtualProtect`, `ReadProcessMemory`, `WriteProcessMemory`, `NtProtectVirtualMemory`. `KERNEL32!VirtualProtect` @ IAT 0x10b1a058 is imported but consumed by non-AC code (VMProtect stub / TLS initializers).
- No `DeviceIoControl` call from the sink. `KERNEL32!DeviceIoControl` @ IAT 0x10b1a0c0 is imported but used by unrelated file-I/O paths, not by the AC sink or vectors.
- No `MemoryBridge` write. No `MMgr64` handshake. This subsystem is independent of the 64-bit content offloader.

Verdict for (1): FUN_100b5650 is exclusively an alarm-report + local-latch + delayed-log sink. Behavior corresponds to option **(a) build packet + call socket send fn** (via client callbacks); side-effect (b) is present (latch byte at 0x10bdc24c and `+4` field via helper thread). No (c), (d), or (e).

---

## (2) Common parent of the 14 vector callers

### Method

Each of the 14 caller VAs (`0x100b5cba, 0x100b5eb8, ..., 0x100b82e4`) is an `E8` (rel32) instruction *inside* one of the vector functions; disassembly confirms all 14 targets are `0x100b5650`. Mapping each caller VA to the nearest lower Ghidra function start yields exactly 14 vector functions:

```
0x100b5ae0  (DBG_BEINGEBUGGEDPEB    — fs:[0x30] + 2, PEB.BeingDebugged)
0x100b5ce0  0x100b5ed0  0x100b6170  0x100b6750
0x100b69f0  0x100b6c50  0x100b7020  0x100b71b0
0x100b7310  0x100b74e0  0x100b76d0  0x100b7f40  0x100b80e0
```

### The single common parent: FUN_10a3dc20

Scanning the whole `.text` for `E8`-calls targeting each of those 14 vector-fn starts yields exactly one caller per vector, and all 14 call-sites fall inside `[0x10a3dd93..0x10a3e29a]` — a single unrolled function whose true start (walked back past `\xCC` padding to the prologue) is **`FUN_10a3dc20`**.

Prologue and first vector call:

```
0x10a3dc20  sub  esp, 8
0x10a3dc23  push esi
0x10a3dc24  call 0x100b7ca0          ; vector 0 (no sink call — pre-check)
0x10a3dc29  mov  ecx, [0x10d3ecd4]   ; TLS index
0x10a3dc2F  mov  eax, fs:[0x2C]
0x10a3dc35  mov  esi, [eax + ecx*4]  ; esi := &TLS block (holds version counter at +0xC)
0x10a3dc40  <-- LOOP TOP -->
   ; per-vector template, repeated 14 times, each with a different call target:
   cmp  eax, [esi+0xC]                     ; tick vs version threshold
   jle  skip_reinit
     ; reinit singleton 0x10bdc244 (vtable, zero fields, clear latch)
   cmp  byte [0x10bdc24c], 0               ; *** LATCH CHECK ***
   jne  skip_call                           ; latched -> skip this vector
   call FUN_100bXXXX                        ; run vector (may set latch on trip)
```

Order of vectors visited (from the sequence in the parent):

```
0x100b71b0 -> 0x100b5ae0 -> 0x100b74e0 -> 0x100b5ce0 -> 0x100b76d0 ->
0x100b5ed0 -> 0x100b6170 -> 0x100b69f0 -> 0x100b7310 -> 0x100b6750 ->
0x100b80e0 -> 0x100b7020 -> 0x100b6c50 -> 0x100b7f40 -> (0x100b6980 tail)
```

Total unique `call rel32` targets inside `FUN_10a3dc20` = 21 (14 vector-fns that reach the sink, 2 vector-like fns that never reach it — `0x100b7ca0` at the very top and `0x100b6980` at the very bottom, likely bookkeeping — and 5 runtime helpers: CRT lock/unlock at `0x10ae6b60`/`0x10ae7060`, magic-static init at `0x10ae70c0`, and the tail-sleep helper `FUN_10a3d0f0`).

Tail of the loop:

```
0x10a3e2fd  call 0x100b6980
0x10a3e302  lea  eax, [esp+4]
0x10a3e306  mov  dword [esp+4], 5
0x10a3e30E  push eax
0x10a3e30F  mov  dword [esp+0xC], 0
0x10a3e317  call FUN_10a3d0f0        ; sleep-with-cancel (5 sec / 5 ticks)
0x10a3e31F  jmp  0x10a3dc40          ; *** LOOP BACK ***
```

Loop is infinite; `jmp` back to `0x10a3dc40` restarts the vector sequence.

### Latch semantics

Because every vector call is guarded by `cmp byte [0x10bdc24c], 0 / jne skip`, once the FIRST vector trips (sink sets the byte to 1), all remaining vectors in the same pass are skipped. On the next pass the loop head checks `[0x10bdc250] > [esi+0xC]` (a tick/version counter); if the version has advanced enough, the reinit block zeros the latch and the sweep resumes. This ratchets the alarm to *approximately one alert per 5-second pass per vector class*, not one alert per detected event, which matches server-side rate-limiting expectations.

### Thread spawn / cadence

`FUN_10a3dc20` has zero direct `E8` callers in the binary and no data-section pointer references. It is invoked from VMP-protected dispatch (Extensions.dll's `.vm_sec` region) or from a computed jump, so the direct-xref search misses it. The four `_beginthreadex` sites in the binary are:

```
0x100b59D3  <- sink's helper-thread spawn (start = FUN_100b5220)
0x10221010  <- unrelated
0x102c4d9e  <- unrelated
0x10a4b576  <- start routine = FUN_10a3bd00 (a generic thread-arg deleter wrapper, dispatches to FUN_10a3d420); adjacent to the AC monitor code but not the sweep-loop entry itself
```

Attribution of the actual `CreateThread`/`_beginthreadex` for `FUN_10a3dc20` will need runtime confirmation (BP at `FUN_10a3dc20` and inspect the call stack via SEH chain / TLS block — the `esi := TLS[idx]` load at `0x10a3dc35` implies the caller has already established a TLS slot, consistent with a dedicated worker thread). Practically: BP `0x10a3dc20` at process start-up captures the spawning frame.

Verdict for (2): The 14 vector callers share a single common parent, `FUN_10a3dc20`, which is an infinite polling loop with a ~5-second cadence and per-pass latch that clears when a version counter advances. Invocation of the parent itself is from VMP-covered code (spawn site not directly observable via native xrefs; likely a dedicated worker thread).

---

## (3) Section placement — .vm_sec check

Section table of `Extensions.dll` (image base 0x10000000):

```
.text    VA 0x10001000 - 0x10b195eb   size 0xB185EB   (11.6 MB — normal x86)
.rdata   VA 0x10b1a000 - 0x10bc97ea   size 0xAF7EA
.data    VA 0x10bca000 - 0x10d3ecf4   size 0x174CF4
.rsrc    VA 0x10d3f000 - 0x10d3f1e0   size 0x1E0
.reloc   VA 0x10d40000 - 0x10d6e000   size 0x2E000
.vm_sec  VA 0x10d6e000 - 0x10d76200   size 0x8200     (33 KB — VMProtect payload)
```

Placement of relevant addresses:

| Symbol                            | VA         | Section |
|-----------------------------------|-----------|---------|
| Sink `FUN_100b5650`                | 0x100b5650 | .text   |
| Vector fns 0x100b5ae0..0x100b80e0  | 0x100bxxxx | .text   |
| Common parent `FUN_10a3dc20`       | 0x10a3dc20 | .text   |
| Sleep helper `FUN_10a3d0f0`        | 0x10a3d0f0 | .text   |
| Sink helper thread `FUN_100b5220`  | 0x100b5220 | .text   |
| Singleton getter `FUN_100b5a70`    | 0x100b5a70 | .text   |
| Latch byte `0x10bdc24c`            | .data      |
| Vector name table `0x10B2A380`     | .rdata     |
| Runtime callback slots `0x10BCA0xx`| .data      |

**Nothing** in the AC vector / sink / monitor-loop chain lives in `.vm_sec`. `.vm_sec` is 33 KB starting at 0x10d6e000; the AC subsystem terminates at ~0x10a4bxxx, over 3 MB below the VMP payload. The direct-xref miss on the parent's caller merely indicates that the *entry* into `FUN_10a3dc20` is set up from VMP-mutated code (import-thunk fixup or thread-spawn TLS init running inside `.vm_sec`), not that the AC bodies themselves are virtualized. Patches to `FUN_100b5650`, its vectors, or `FUN_10a3dc20` land on normal x86 that x32dbg can disassemble, hook, and single-step without VMP handler dispatch.

---

## (4) Integrity claim — hashing / CRC / memcmp of Extensions.dll or client .text

### Evidence

Imports scan (`Extensions.dll`) — hashing / crypto / self-check surface:

```
ADVAPI32.dll  CryptAcquireContextA   (imported, IAT 0x10b1a00c)
KERNEL32.dll  VirtualProtect         (imported, IAT 0x10b1a058)

<none for BCrypt*, RtlComputeCrc32, CryptHash*, CryptCreateHash,
       Hash*, memcmp-import stub, ReadProcessMemory,
       WriteProcessMemory, NtProtectVirtualMemory, ZwProtect*>
```

`CryptAcquireContextA` is present but not called from the sink or any of its two-level callees; it is used by non-AC subsystems (likely PRNG init or Xact / codec setup) elsewhere in the DLL. `VirtualProtect` is imported for the VMProtect stub itself; it is not called by `FUN_100b5650`, the 14 vector fns, `FUN_100b5a70`, `FUN_100b5220`, or `FUN_10a3dc20`.

Grep for byte-string constants that would hint at self-integrity ("crc", "sha", "hash", "md5") near the sink cluster: none within +/- 0x10000 of `0x100b5650`. The XOR-obfuscated tokens on the stack in the sink and vector bodies (e.g. `0x2E4AD59E`, `0xF95819C`, `0x42198243`, `0xF0F82E91`) are per-string keys for the packet text payload ("BeingDebugged detected in PEB", etc.), not hash constants.

DivxTac and MMgr64 do not backstop this either: ground truth (from `raijinlab_ac_architecture.md` and `11a_divxtac_ac_logic.md`) states:
- DivxTac imports zero `ReadProcessMemory` / `Crypt*` / `RtlComputeCrc32` / `VirtualProtect`. It is a **name-based** module/process/window detector; it never reads or hashes the target's `.text`.
- MMgr64 imports zero `ReadProcessMemory` / hashing. It is a session-token-gated memory-bridge server.

So no other AC binary hashes Extensions.dll or client `.text` either.

### Verdict

**The sink and its immediate callees do NOT hash / CRC / memcmp Extensions.dll or client `.text`.** They read live OS/CPU-supplied state (PEB flags, NtGlobalFlag, `IsDebuggerPresent`, DR0-DR7, `RDTSC` deltas, `QueryPerformanceCounter` deltas, `FindWindowW` results, `CreateToolhelp32Snapshot` process names, etc.), format a report by opcode 1311, and set a latch. There is **no client-side content-integrity backstop** in this subsystem.

Consequence: any bypass patch on `FUN_100b5650`, on the 14 vector fns, on the parent monitor `FUN_10a3dc20`, or on the latch byte `0x10bdc24c` is **one-time and durable** — no other subsystem examined so far will detect the patch. (Caveat: some *other* function inside Extensions.dll may perform TLS-time or timer-driven self-CRC over its own `.text` — such a check is out of scope for this ticket and would need to be surveyed separately by grepping for CRC tables, `IMAGE_NT_HEADERS` reads, or PE-parsing patterns across the whole DLL.)

---

## Recommended breakpoints (x32dbg)

Extensions.dll ImageBase in-process is randomized (ASLR); anchor by module offset (VA - 0x10000000). All targets are in `.text` and directly reachable — no VMP handler dispatch on the path.

| BP (VA in Extensions.dll) | Purpose                                                         | Safe bypass (in-place)                              |
|---------------------------|------------------------------------------------------------------|-----------------------------------------------------|
| `0x100b5650`              | Sink entry — fires on any of 14 vectors                          | Patch `[0x100b5650] = 0xC3` (__cdecl `ret`, caller cleans; kills every alert without side effects) |
| `0x100b5993`              | The `call esi` that actually transmits opcode 1311               | `[0x100b5993..0x100b5994] = 90 90` — packet built but never sent (keeps latch flow intact for debugging) |
| `0x100b599C`              | `mov byte [eax+8], 1` — sets the latch                           | `[0x100b599c..0x100b599f] = 90 90 90 90` — no latch (interesting for tracing; not required for bypass) |
| `0x100b59D3`              | `_beginthreadex` for helper logger thread (proc = `FUN_100b5220`) | Leave; harmless if sink is neutered. Instrument to see spawn frequency during triage. |
| `0x10bdc24c` (byte)       | The latch itself                                                 | Persistent poke: `dbg_write(0x10bdc24c, 1)` at process init and hook the reinit block at `0x10a3dcc0` to skip the byte-zero. |
| `0x100b5a70`              | Singleton getter `FUN_100b5a70` — first call reveals `0x10bdc244`  | Do not patch (used by other code); trace only.      |
| `0x10a3dc20`              | Parent monitor-loop entry — hit reveals thread that spawned it   | Patch `[0x10a3dc20] = 0xC3` to kill the loop entirely (last-resort). |
| `0x10a3e317`              | Sleep tail before `jmp` loop-back — cadence anchor               | Trace only.                                          |

**DetourMgr risk**: `DetourMgr.cs` (managed side in DivxTac) hooks .NET methods via IL rewriting; it does not detour arbitrary native code in Extensions.dll. `ManagedDetourMgrlockRef.cs` synchronizes managed detour state only. No evidence that patched bytes in Extensions.dll `.text` are re-verified by DivxTac or MMgr64. A single-byte `C3` patch on the sink is invisible to the observed AC surface.

---

## Files & cross-refs

- Ghidra decompile (all `<decompile failed>` for this cluster): `re/ghidra_out/Extensions.dll.decompiled.c` lines 3323 onward.
- Sink raw disasm: `re/scripts/disasm_window.py Extensions.dll 0x100b5650 --after 700`.
- Parent raw disasm: `re/scripts/disasm_window.py Extensions.dll 0x10a3dc20 --after 1800`.
- DBG_* string table dump: pefile @ `0x10B2A380`, 21 entries × 8 bytes (ptr + length).
- Vector-name enum + opcode context: `notes/11_extensions_ac_map.md`.
- Managed opcode-1311 wire format + AC cadence: `notes/11a_divxtac_ac_logic.md`.
