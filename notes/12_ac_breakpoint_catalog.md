# 12 — Ascension Anti-Cheat Breakpoint Catalog (CONSOLIDATED)

**Purpose:** the single document a reverse engineer opens in x32dbg to plan, set, and reason about anti-cheat breakpoints against the live Ascension client. Every row is grounded in the verified upstream notes (11a–11f) and the extracted JSON tables (`re/ext_antidebug_vectors.json`, `re/ext_virtualprotect_callsites.json`, `re/ascension_ac_opcodes.json`, `re/divxtac_globaloffsets.json`). Contradictory upstream text has been reconciled in favor of the disassembly-anchored evidence (marked "override:" where relevant).

**Binaries (image bases):**
- `Ascension.exe`   — x86, base `0x00400000`
- `Extensions.dll`  — x86, base `0x10000000`, `.text` 0x10001000..0x10b195eb, `.vm_sec` 0x10d6e000..0x10d76200 (33 KB; AC surface is NOT inside .vm_sec)
- `DivxTac.dll`     — x86 C++/CLI mixed, base `0x10000000`
- `MMgr64.exe`      — x64, base `0x140000000` (out-of-process, non-AC)

**Column conventions (all breakpoint rows):**

| Field | Meaning |
|---|---|
| ID | Local ID for cross-reference (e.g. `S1.02`) |
| location | `module + VA (+RVA)` |
| trigger | What in-process event causes the BP to fire |
| observation | What you should see (stack, args, regs) — what the BP is *for* |
| bypass | Minimum patch or hook to neutralize the vector without breaking the game |
| deps | Which BP(s) must fire first, or which prior state must exist |
| detour_risk | Whether DivxTac's DetourMgr / any known self-integrity check covers this byte range |
| confidence | HIGH = disasm-verified; MED = string/xref-inferred; LOW = runtime-only |

**Global integrity claim (repeat, so you don't re-derive it every session):**
- **DivxTac has zero code-integrity checking.** No `ReadProcessMemory`/`Crypt*`/`VirtualProtect`/`VirtualQuery` imports. `DetourMgr` struct is empty (0 methods), `ManagedDetourMgr::FunctionMap` is zero-initialized and never inserted into or read (see 11b).
- **MMgr64 has zero client-memory access.** OpenProcess mask is `0x101000` = SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION only; no RPM/WPM/DuplicateHandle imports (see 11e).
- **Extensions sink `FUN_100b5650` and every callee within two call levels perform no hashing/CRC/memcmp of any module's `.text`.** Only OS/CPU-supplied state is checked (PEB, DR0-DR7, RDTSC/QPC, FindWindowW, ntdll queries) — see 11c.
- **Legacy Warden — mixed.** The disk-cached `Scan.dll` download/verify/load path is dead (`ScanDLLStart @ Ascension!0x4dccf0 = mov eax,0; ret`, zero callers on the download cluster; see 11f). **BUT [Patch Round 1 — GAP 7]** the **in-process** `WardenClient.cpp` module inside Ascension.exe at `0x7DA200..0x7DAAE0` is **fully alive**: handler `0x7DA850` registered at `0x7DA917` for opcode `0x2E6`, dispatcher vtable-calls `WardenClient::OnPacket` at `[[0xD31A4C]]+8`, and the classic memory-read primitives at `0x7DA500`/`0x7DA550` (memcpy via `0x40CB10`, base/length stashed at `[0xD31A50]`/`[0xD31A54]`) are functional. **Server-driven Warden memory scans of the client `.text` ARE possible.** DivxTac lacking `ReadProcessMemory` does not shield anything — Warden runs in-process. See new Subsystem 11.
- **Detour blacklist: empty.** No client function VA is on any DivxTac watchlist in the shipping build (see 11b + `re/divxtac_globaloffsets.json`).

**Consequence: patches to any BP location in this catalog are one-time and durable across the observed AC surface** — with the standing caveat that some *other* uninspected Extensions.dll routine could self-CRC its own `.text` (not observed but not exhaustively ruled out).

---

## Subsystem 1 — Startup / Boot Phase (Extensions self-unpack, hook installer, trampolines)

The DLL does NOT self-unpack `.text` from a packed image on disk. Its "unpacking" is limited to (a) an internal MinHook/Detours-style RAII hook installer that toggles PAGE_EXECUTE_READWRITE around detour patches, and (b) a freshly-allocated trampoline-page stub builder. Both use `KERNEL32!VirtualProtect` (IAT `0x10b1a058`) — exactly 4 call sites, none followed by any hash or self-check (see `re/ext_virtualprotect_callsites.json`).

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S1.01 | Extensions.dll + `0x1000106b` (RVA 0x1006b) — `ScopedProtect::ctor` @ `FUN_10001000` | Any detour install through the primary installer `FUN_10001170`; fires **twice per detour** (source + destination regions). Very hot — 353 total callers of the wrapper `FUN_100010f0`. | `this=ecx`; args `(addr, size)` at `[ebp+8]/[ebp+0xc]`. After the call, `this[0xc] = oldProtect` (typically PAGE_EXECUTE_READ 0x20). | None needed for AC purposes — this is the client's own hook code, not AC. Use as a **surveillance** BP to observe every detour the client installs (helpful during boot). Log-only recommended. | none | none observed | HIGH |
| S1.02 | Extensions.dll + `0x100010e4` (RVA 0x100e4) — `ScopedProtect::dtor` @ `FUN_10001080` | Paired 1:1 with S1.01; fires on every install/failure arm (12 callers). | Restores captured `oldProtect`. Never followed by a hash. | Same as S1.01 — surveillance only. | S1.01 | none | HIGH |
| S1.03 | Extensions.dll + `0x100a0a10` (in `FUN_100a09b0`) — trampoline-page unprotect | Called ONCE from `FUN_10191c00 @ 0x10191cac` when the JMP-rel32 trampoline stub is built into a freshly `VirtualAllocEx`'d 5-byte page. | Target of the write is the fresh page (edi), NOT `.text`. `oldProtect` capture is effectively a no-op (page allocated RWX). | Leave. Instrument only if diagnosing missing/incorrect detours in the runtime. | none | none | HIGH |
| S1.04 | Extensions.dll + `0x100a0a2e` (in `FUN_100a09b0`) — trampoline-page reprotect | Paired with S1.03. | Post-write protection restore. | Leave. | S1.03 | none | HIGH |
| S1.05 | Ascension.exe + `0x0047B0A0` — CDataStore packet preparer (thiscall `(this, uint opcode)`) | The choke point through which **all** client-side AC packets exit (1311/1312 native + managed). Also carries normal traffic — filter by opcode. | `ecx = CDataStore*`, opcode at `[esp+4]`. See ExtendedAnticheatMgr note 11d §3. | See S6.03 — hook this with a filter dropping opcode 1311/1312 while pass-through for everything else. Single-hook whole-subsystem kill. | client init (has to have run enough to register the fptr in `Extensions!0x10bca0cc`) | none | HIGH |
| S1.06 | Extensions.dll `.data` slot `0x10bca0cc` (dword, populated by Ascension.exe at DLL load) | Data-BP READ — fires the first time anyone in Extensions calls the CDataStore preparer. | Value stabilizes to `0x0047B0A0`. If it points elsewhere, someone else has re-plumbed the send path. | Redirect target to a filtering stub — see S6.04. | client loader | none | HIGH |
| S1.07 | Extensions.dll + `0x10A3B690` — **DivxTac.dll loader stub** (9 bytes: `push "DivxTac.dll" ; mov eax,0x86C4E0 ; call eax ; ret`). String at `.rdata:0x10B63CC8`. **[GAP 8 — added Patch Round 1]** | Fires when the runner at `Extensions.dll!0x10073740` (vtable `0x10B1ABE0` entry #4) flushes the callback container `0x10BE3974` — exact trigger event (module init vs login vs world enter) is not statically resolvable, needs runtime capture. | Stub has 0 direct `E8` callers. Registered at `Extensions.dll!0x10A6BDA5` (`push 0x10A3B690 ; call 0x10278B70`). Target `Ascension.exe!0x86C4E0` = `call [0x9DF248]` wrapper, IAT slot resolves to `KERNEL32!LoadLibraryA`. Concrete load call is therefore `LoadLibraryA("DivxTac.dll")` originating from Extensions. | **1-byte `C3` at `0x10A3B690`** — highest-leverage single kill switch for the entire DivxTac subsystem. DivxTac.dll never loads → CLR init never runs → S4/S5/S10 subsystems never instantiate → HDD serial never leaves → banned lists never register. Plain `.text`, not `.vm_sec`. | Extensions loaded, callback runner reached | none | HIGH |
| S1.08 | Extensions.dll IAT thunk `KERNEL32!LoadLibraryA` (locate via `xref_imports.py Extensions.dll LoadLibraryA`) | Data-BP READ on the IAT slot fires per `LoadLibraryA` call. **[GAP 8 — added Patch Round 1]** | Filter arg1 == `"DivxTac.dll"` to catch the DivxTac load event and its enclosing call frame (call-stack walk gives the trigger event that S1.07 can't determine statically). | Alternate to S1.07: an early `LoadLibraryA` hook with a name filter returning `NULL` (or the module base of a benign stub) prevents DivxTac load without touching client `.text`. | Extensions loaded | none | HIGH |
| S1.09 | Extensions.dll + `0x10A6BDA5` — DivxTac loader-stub **registration site** (`push 0x10A3B690 ; call 0x10278B70`) **[GAP 8 — added Patch Round 1]** | Fires ONCE during the large init routine that also registers CVars like `"autoAcceptTrades"`. | Confirms container `0x10BE3974` receives the stub pointer. Trace-only — patching here is riskier than S1.07 because the surrounding routine registers many unrelated callbacks. | Leave. Use S1.07 for the actual kill. | Extensions loaded | none | HIGH |

**Boot triggering sequence** (guarantees S1.01/S1.02 fire): launch the client → wait for the login screen. Boot-time detours install here. The BP should hit hundreds of times in the first 5–10 seconds.

---

## Subsystem 2 — AC Thread Spawn (parent monitor loop `FUN_10a3dc20`)

The 14 anti-debug vectors are driven by a single infinite polling loop `FUN_10a3dc20 @ Extensions.dll+0xa3dc20`. It calls each vector, latch-checks between them, sleeps ~5 s via `FUN_10a3d0f0`, and loops. Cadence ≈ **5 s per pass, per vector class** (once the latch trips, remaining vectors that pass are skipped until a version counter advances).

Direct static xrefs to the parent's entry are missing because the spawn site sits in VMP-covered code (`.vm_sec`). The body itself is normal `.text`, hookable without VMP handler dispatch.

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S2.01 | Extensions.dll + `0x10a3dc20` (RVA 0xa3dc20) — `FUN_10a3dc20` parent-loop entry | Fires ONCE at thread spawn during Extensions load. Call stack at hit reveals the (VMP-obscured) spawn frame. | `[esi]` populated from `fs:[0x2C] + [TlsIdx*4]` — spawn thread has a dedicated TLS block. `[esi+0xC]` = version counter. | Last-resort: patch first byte to `0xC3` (near-ret). Kills all 14 vectors regardless of latch state. Caller expects the thread to run indefinitely — premature return is fine because there is no return-value check. | Extensions.dll fully loaded | none | HIGH |
| S2.02 | Extensions.dll + `0x10a3e317` — sleep tail (`call FUN_10a3d0f0` with arg=5) just before `jmp 0x10a3dc40` loop-back | Fires once per full pass (~5 s cadence anchor). | Confirms polling interval. | Trace only. | S2.01 | none | HIGH |
| S2.03 | Extensions.dll data byte `0x10bdc24c` (alert-fired latch, offset +8 of singleton at `0x10bdc244`, vtable `0x10b2a42c`) | Data-BP WRITE = sink sets it after any vector trip. Data-BP READ = parent loop checks it before each vector call. | READ pattern: `cmp byte [0x10bdc24c], 0 / jne skip_call` at each of the 14 in-loop templates. | Persistent poke: write 1 once at init, then either (a) `VirtualProtect` the page to PAGE_READONLY (loop has no SEH on the read — read returns 1 forever), or (b) NOP the reinit block's `mov byte [0x10bdc24c], 0` instruction inside every per-vector template in `FUN_10a3dc20`. | S2.01 | none | HIGH |
| S2.04 | Extensions.dll + `0x100b5a70` — singleton getter `FUN_100b5a70` | First hit reveals singleton VA `0x10bdc244` (vtable @ `+0`, reserved @ `+4`, latch @ `+8`). | Trace only. Do NOT patch — the singleton may be reused for unrelated state. | — | S2.01 | none | HIGH |
| S2.05 | Extensions.dll + `0x100b5220` — helper-thread proc `FUN_100b5220` (`_beginthreadex` start routine spawned from the sink) | Called from `_beginthreadex` at Extensions.dll+`0x100b59D3` (see S3-sink). Runs a QPC delay of `0x0F4240..0x989680` ticks then persists `vector_code` into `singleton[+4]`. | Trace only — no network I/O, no MessageBox, no self-terminate. | Leave alone if sink is neutered; the thread exits harmlessly. | S3.15 (sink) | none | HIGH |

**Reconciled contradiction with 11a §1 cadence description:** note 11a describes the DivxTac managed loop as "60s→60s→0s (120 s coarse per cycle)". That is correct for the **DivxTac** loop (managed C++/CLI thread, opcode 1311 name-based scans). The Extensions.dll native loop at `FUN_10a3dc20` uses a **~5 s** cadence via `FUN_10a3d0f0(arg=5)`. These are two independent monitor threads; do not conflate them.

**Triggering sequence:** BP `S2.01` at attach; observe it fire once as soon as Extensions.dll finishes loading (before the login screen). BP `S2.02` will then fire every ~5 s indefinitely.

---

## Subsystem 3 — Extensions.dll 14 Anti-Debug Vectors → Sink `FUN_100b5650`

The sink is a __cdecl `void report(int vector_code /*[ebx+8]*/, int extra /*[ebx+0xC]*/)` at `0x100b5650`. It builds a stack `CDataStore` (vtable `0x10b1c384`), writes opcode `0x51F` (CMSG_ANTICHEAT_ALERT = 1311), formats 3 strings + reason-code magic `0x2E4AD59E / 0x0F95819C`, calls the Ascension-provided send fn via `[0x10bca1F0]`, sets latch byte `[0x10bdc24c] = 1`, and spawns the helper logger thread.

Table indexed by the `type_id` argument (1..0x14 = 20), from `re/ext_antidebug_vectors.json` and note 11c. Vectors are grouped by technique class. **Every caller_va below is a direct `E8 rel32` into `0x100b5650`.** All rows below share `detour_risk = none` (verified — 11c §4).

### 3.a Sink itself and packet-emit choke points

| ID | location | trigger | observation | bypass | deps | conf |
|---|---|---|---|---|---|---|
| S3.15 | Extensions.dll + `0x100b5650` (file 0xb4a50) — sink `FUN_100b5650` entry | Any of the 14 vector functions below fires. | Args: `[ebx+8] = vector_code (0..0x14)`, `[ebx+0xC] = per-vector extra int`. Vector→string table at `0x10B2A380` (21 × 8 B pairs). | Poke first byte to `0xC3` — __cdecl, caller cleans stack. Kills all 14 alerts + latch. Cleanest single-BP kill switch. | S2.01 (or any single vector below) | HIGH |
| S3.16 | Extensions.dll + `0x100b56dc` — `push 0x51F` (opcode CMSG_ANTICHEAT_ALERT) in sink | Sink chose to send. | Confirms wire opcode 1311 on stack. | Do NOT patch this imm — the payload build uses that stack layout. Neuter S3.17 instead. | S3.15 | HIGH |
| S3.17 | Extensions.dll + `0x100b56e7` — `call dword ptr [0x10bca0cc]` (CDataStore preparer via Ascension) | Actually initiates the packet on the wire path. Also referenced by the 4 sibling emit sites (`0x102dba13`, `0x10a46260`, `0x10a4d292`, `0x10a7957b`) — patching the **indirect** at `[0x10bca0cc]` (data slot S1.06) filters all 5 native emitters at once. | Args on stack post-call: this=`[ebp-0xB0]`, opcode=0x51F. | Local NOP: 6 bytes `FF 15 CC A0 BC 10 -> 90 90 90 90 90 90`. Global: redirect `[0x10bca0cc]` to a filtering stub — same effect as hooking `Ascension.exe!0x0047B0A0` (S6.03) but scoped to Extensions. | S3.15 | HIGH |
| S3.18 | Extensions.dll + `0x100b5993` — the actual `call esi` (send) | `esi = [0x10bca1F0]` (SendPacket method), `ecx = net-service singleton from [0x10bca1EC]` | The wire transmission. | Overwrite 2 bytes `FF D6 -> 90 90`. Packet built but never sent. Latch still trips (harmless). | S3.17 | HIGH |
| S3.19 | Extensions.dll + `0x100b599C` — `mov byte [eax+8], 1` (latch set) | Latch write. | Sets `[0x10bdc24c] = 1`. | 4 bytes `C6 40 08 01 -> 90 90 90 90`. Loop then no longer skips subsequent vectors — usually useless for bypass, useful for tracing every trip. | S3.15 | HIGH |
| S3.20 | Extensions.dll + `0x100b59D3` — `_beginthreadex` for helper logger | Sink spawns FUN_100b5220 (S2.05). | Confirms spawn frequency during triage. | Leave — harmless if sink neutered. | S3.15 | HIGH |

### 3.b PEB direct-read vectors (no imports; check `fs:[0x30]`)

| ID | location (caller_va) | containing_fn | id | technique | trigger / observation | primitive | bypass | conf |
|---|---|---|---|---|---|---|---|---|
| S3.01 | Extensions.dll + `0x100b5cba` | `FUN_100b5ae0` | 1 | `DBG_BEINGEBUGGEDPEB` | Reads `PEB.BeingDebugged` (`fs:[0x30]+2`). Fires if byte != 0. | `mov eax, fs:[0x30]` @ `0x100b5b01` | Zero PEB.BeingDebugged process-wide (attach-mode of x32dbg already does this; also `Scylla Hide` / manual `mov byte [PEB+2], 0`). Or NOP the compare in the containing fn. | HIGH |
| S3.06 | Extensions.dll + `0x100b76b8` | `FUN_100b74e0` | 4 | `DBG_NTGLOBALFLAGPEB` | Reads `PEB.NtGlobalFlag` (`fs:[0x30]+0x68`); tests for `0x70` (FLG_HEAP_ENABLE_TAIL_CHECK|FREE_CHECK|VALIDATE_PARAMETERS). | `mov eax, fs:[0x30]` @ `0x100b7501` | Zero PEB.NtGlobalFlag. `Scylla Hide`. Or NOP the `test`/`cmp` in the caller. | HIGH |

### 3.c Documented Win32 API debugger probes (IAT-driven)

| ID | location | fn | id | technique | trigger / API | bypass | conf |
|---|---|---|---|---|---|---|---|
| S3.02 | Extensions.dll + `0x100b5eb8` | `FUN_100b5ce0` | 2 | `DBG_CHECKREMOTEDEBUGGERPRESENT` | `call [0x10b1a054]` GetCurrentProcess @0x100b5cff → `call [0x10b1a068]` CheckRemoteDebuggerPresent @0x100b5d0b | IAT hook `CheckRemoteDebuggerPresent` returning `*out=0, ret=TRUE`. | HIGH |
| S3.03 | Extensions.dll + `0x100b72f7` | `FUN_100b71b0` | 3 | `DBG_ISDEBUGGERPRESENT` | `call [0x10b1a060]` IsDebuggerPresent @0x100b71c4 | IAT hook → return 0. Also killed by attach-mode (no debug port). | HIGH |
| S3.07 | Extensions.dll + `0x100b7c79` | `FUN_100b76d0` | 5 | `DBG_NTQUERYINFORMATIONPROCESS` (largest body, 1488 B) | LoadLibraryW `[0x10b1a084]` @0x100b784b (ntdll) → GetProcAddress `[0x10b1a030]` @0x100b79a6 (`NtQueryInformationProcess`) → probes ProcessDebugPort(7), ProcessDebugObjectHandle(0x1E), ProcessDebugFlags(0x1F). | Hook `NtQueryInformationProcess` to spoof 0 for classes 7/0x1E/0x1F. Or ScyllaHide. | HIGH |
| S3.05 | Extensions.dll + `0x100b6c32` | `FUN_100b69f0` | 11 | `DBG_HARDWAREDEBUGREGISTERS` | `call [0x10b1a074]` GetCurrentThread @0x100b6a20 → `call [0x10b1a078]` GetThreadContext @0x100b6a34 (`CONTEXT_DEBUG_REGISTERS`); tests DR0-DR3/DR6/DR7 for nonzero. | Do NOT use HW breakpoints while this runs. Or hook `GetThreadContext` to zero out DR fields in the returned CONTEXT. | HIGH |

### 3.d Window-title/class scan vectors

| ID | location | fn | id | technique | trigger / API | bypass | conf |
|---|---|---|---|---|---|---|---|
| S3.04 | Extensions.dll + `0x100b6154` | `FUN_100b5ed0` | 6 | `DBG_FINDWINDOW` (single-class variant) | `call [0x10b1a3bc]` FindWindowW @0x100b5f80 (1 class lookup) | Hook `FindWindowW` returning NULL for the debugger class list. Rename/hide your debugger window class before attach. | HIGH |
| S3.09 | Extensions.dll + `0x100b6731` | `FUN_100b6170` | 6 | `DBG_FINDWINDOW` (multi-class variant, 1.5 KB body) | `call [0x10b1a3bc]` FindWindowW @0x100b6525 and @0x100b6538 (multiple lookups — OllyDbg/x64dbg/IDA/etc.) | Same as S3.04. Extract exact class-name list by reading string constants near `0x100b6400..0x100b6600` before attach. | HIGH |

### 3.e SEH / CPU-primitive vectors (no imports; use exception behavior differential)

| ID | location | fn | id | technique | primitive | bypass | conf |
|---|---|---|---|---|---|---|---|
| S3.08 | Extensions.dll + `0x100b6954` | `FUN_100b6750` | 16 | `DBG_CLOSEHANDLEEXCEPTION` | `call [0x10b1a020]` CloseHandle @0x100b67a9 on invalid handle inside SEH → only a debugger raises STATUS_INVALID_HANDLE (0xC0000008). | Configure x32dbg to swallow `0xC0000008` exceptions (pass to app). Or hook `CloseHandle` to short-circuit for `-1`/known bad handles. | HIGH |
| S3.10 | Extensions.dll + `0x100b6ff1` | `FUN_100b6c50` | 20 | `DBG_INT2D` | `int 0x2d` (`CD 2D`) @ `0x100b6ec0` inside SEH; without debugger → STATUS_BREAKPOINT, with debugger → skip trailing byte. GetModuleHandleW/GetProcAddress for dynamic ntdll resolution. | Configure debugger to `pass-through` INT 2D. Or NOP the `CD 2D` instruction. | HIGH |
| S3.11 | Extensions.dll + `0x100b7189` | `FUN_100b7020` | 18 | `DBG_INT3CC` | 0xCC (int 3) inside SEH — debugger swallows STATUS_BREAKPOINT so __except never runs. | Configure debugger to pass first-chance int-3 to app; or patch the sole `CC` byte inside `FUN_100b7020` (search 400-B body). | HIGH |
| S3.12 | Extensions.dll + `0x100b74bd` | `FUN_100b7310` | 12 | `DBG_MOVSS` | `pushfd|or [esp],0x100|popfd` @ `0x100b733f` + MOVSS/POP SS trick masking pending single-step. | Configure debugger to correctly emulate MOVSS shadow; or NOP the trap-flag toggle in-place. | HIGH |
| S3.13 | Extensions.dll + `0x100b80b2` | `FUN_100b7f40` | 19 | `DBG_PREFIXHOP` | `pushfd` @ `0x100b7fc7` + `popfd` @ `0x100b7fea` with a redundant instruction prefix (F3/F2/64/65). Debugger single-steps prefix and opcode separately. | Same class as S3.12 — set stepping mode that traverses prefix+opcode atomically, or NOP the SEH-raise path. | HIGH |
| S3.14 | Extensions.dll + `0x100b82e4` | `FUN_100b80e0` | 17 | `DBG_SINGLESTEPEXCEPTION` | Classic EFLAGS.TF toggle via `pushfd` @0x100b813b + `popfd` @0x100b8141 inside SEH. | Configure debugger to pass STATUS_SINGLE_STEP to app; or NOP the toggle. | HIGH |

**Unused type_ids in this build (strings exist, no caller):** 7 OUTPUTDEBUGSTRING, 8 NTSETINFORMATIONTHREAD, 9 DEBUGACTIVEPROCESS, 10 PROCESSFILENAME, 13 RDTSC, 14 QUERYPERFORMANCECOUNTER, 15 GETTICKCOUNT. These vector functions were compiled out — no BP required, but treat as latent-if-server-triggered surface.

**Suggested nuke-order:** S3.15 (sink) is the single-BP kill. If you must let the sink run for logging, patch S3.17 (indirect send) to silence the wire without losing the vector-fire signal.

---

## Subsystem 4 — DivxTac Managed Detection Loop

Cadence: `DetectHackProcesses → sleep 60s → DetectHackModules → sleep 60s → DetectHackTitles → DetectDebugger → loop` (see 11a §1). Full outer cycle ≈ 120 s coarse. Per-item 50 ms throttle inside each Detect*. Detection = **string equality (lowercased ProcessName / MainWindowTitle / ModuleName + ".dll") against server-pushed banned lists**. Banned lists are empty until server opcode 35 arrives.

All rows share `detour_risk = none` (11b — DetourMgr is inert).

| ID | location | trigger | observation | bypass | deps | conf |
|---|---|---|---|---|---|---|
| S4.01 | DivxTac.dll + `0x35BC` (RVA `0x35B0`) — `AntiCheatThreadLoop` entry | Thread start (fire-and-forget from module init). | 60/60/0 pacing between calls; `report=true, sleep=true`. | Patch entry `0xC3`. Init-handler registration still happens on any incoming opcode 14. Kills all polling. | Extensions loaded and DivxTac managed CLR init done | HIGH |
| S4.02 | DivxTac.dll + `0x30A0` (RVA `0x3094`) — `DetectHackModules` | Loop tick or opcode-35 rescan. | Foreach `ProcessModule.ModuleName.ToLower()`; compare via `List<string>.Contains`. `SendModuleAntiCheatAlert(module)` on hit. | Patch entry `31 C0 C3` (`xor eax,eax; ret`). Or NOP `call SendModuleAntiCheatAlert` at L467 to keep detection running but suppress the 1311 packet. | S4.01 or S4.08 | HIGH |
| S4.03 | DivxTac.dll — `DetectHackProcesses` (token 0x0600000C; verify RVA via dnSpy) | Loop tick. | `Process.GetCurrentProcess().ProcessName` compared substring vs `normalizedProcessManagedStrings`. `SendProcessAntiCheatAlert` on hit. | Patch entry `31 C0 C3`. Or NOP the `SendProcessAntiCheatAlert` call. | S4.01 or S4.08 | MED |
| S4.04 | DivxTac.dll — `DetectHackTitles` (token 0x0600000D; verify RVA via dnSpy) | Loop tick. | Iterates `Process[]`, tests `MainWindowTitle.ToLower().Contains(banned)` per item. | Patch entry `31 C0 C3`. | S4.01 or S4.08 | MED |
| S4.05 | DivxTac.dll + `0x2ED0` (RVA `0x2EC4`) — `DetectDebugger` | Loop tick (after Titles). | `IsDebuggerPresent()` P/Invoke → opcode 1311 with (`"DEBUGGER"`, `"DEBUGGER"`, ProcessName). | Patch entry `0xC3`. Or IAT-hook `IsDebuggerPresent` @ IAT `0x10008298` returning 0. | S4.01 or S4.08 | HIGH |
| S4.06 | DivxTac.dll + `0x2FA8` (RVA `0x2F9C`) — `SendModuleAntiCheatAlert` | Any module-scan hit. | Emits opcode 1311 with (ModuleName, MainWindowTitle, FileName). | Patch entry `0xC3`. Suppresses all module reports without touching detection logic. | S4.02 | HIGH |
| S4.07 | DivxTac.dll + `0x22FC` (RVA `0x22F0`) — `SendProcessAntiCheatAlert` | Any process/title hit. | Reads `ProcessDescription+0/+24/+48` (name, title, path) and emits opcode 1311. | Patch entry `0xC3`. | S4.03 / S4.04 | HIGH |
| S4.08 | DivxTac.dll + `0x58C8` (RVA `0x58BC`) — `SetMessageHandlers` | Fires at loop startup AND every time `AnticheatInitializeHandler` is invoked (idempotent re-arm on opcode 14). | Registers opcodes 14 + 35 with context `0xDEADBABE`. | Patch entry `0xC3`. Server dispatch never reaches DivxTac handlers → banned lists stay empty forever → DetectHack* always misses → no HWID ever leaves. **Cleanest single-BP kill switch for the whole DivxTac subsystem.** | S4.01 | HIGH |
| S4.09 | DivxTac.dll IAT thunk `0x10008298` — `IsDebuggerPresent` | Sole DivxTac debugger primitive. | Called only from `DetectDebugger` (S4.05). | IAT hook returning 0. | S4.05 | HIGH |
| S4.10 | DivxTac.dll IAT thunk — `DeviceIoControl` (see subsystem 10 for detail) | HWID (opcode 1312) collection. | Filtered IOCTLs 0x74080 / 0x7C088 / 0x2D1400 / 0x70020 on `\\.\PhysicalDrive0`. | See S10.03. | S5.02 | HIGH |
| S4.11 | DivxTac.dll + `0x8298` (IAT read) | Data-BP READ triggers on first IsDebuggerPresent import. | Confirms whether IAT was already hooked at inject time. | Trace only. | S4.09 | MED |

**Triggering sequence for the entire subsystem:** the DivxTac thread starts at module init but its Detect* only produce hits **after** the server pushes a banned list via opcode 35. To force at least one full pass with all vectors doing something: log in past authentication (server sends opcode 14 → handler emits opcode 1312 HWID → server responds with opcode 35 banlist → DivxTac immediately runs one-shot Detect*Processes/Modules/Titles/Debugger with `sleep=false`). Full loop cadence continues every 120 s thereafter.

---

## Subsystem 5 — Server-Driven Bootstrap (opcodes 14 / 35, magic `0xDEADBABE`)

Server → client opcodes registered by `DivxTac!SetMessageHandlers` (S4.08). The context magic `0xDEADBABE` (int32 `-559039810`) is passed as the handler's `void* context` argument — trivial to verify at breakpoint by reading arg1 at handler entry.

**Reconciled naming (per `re/ascension_ac_opcodes.json`):** the Extensions opcode-name table calls opcode 14 `SMSG_MOVE_CHARACTER_CHEAT` and opcode 35 `SMSG_GODMODE` (stock 3.3.5 debug slots). Ascension repurposes them as `SMSG_ANTICHEAT_INIT` and `SMSG_ANTICHEAT_BANNED_PROCESS_LIST`.

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S5.01 | DivxTac.dll — `SetMessageHandlers` @ RVA `0x58BC` (see S4.08) | Registration. | Two `fpSetMessageHandler` calls (L3108/L3110 in `-Module-.cs`): opcode 14 → `AnticheatInitializeHandler` w/ context `-559039810`; opcode 35 → `AnticheatBannedProcessListHandler` w/ same context. | See S4.08. | S4.01 | none | HIGH |
| S5.02 | DivxTac.dll + `0x5908` — `AnticheatInitializeHandler` | Server sends opcode 14 shortly after login handshake (envelope only, no meaningful body). | Handler: (1) re-registers handlers (idempotent); (2) constructs `MasterHardDiskSerial`; (3) `GetSerialNo` → HDD serial vector; (4) emits opcode 1312 with `PutInt32(4)` + `PutString(serial)`; (5) returns 1. | Patch entry `B8 01 00 00 00 C3` (`mov eax,1; ret`). Server ping is ACKed with no HWID payload. | S5.01 armed | none | HIGH |
| S5.03 | DivxTac.dll + `0x5580` — `AnticheatBannedProcessListHandler` | Server sends opcode 35 (usually right after receiving opcode 1312). | Handler reads 3 length-prefixed string vectors from incoming `CDataStore msg` at `[msg+20]`: (1) BannedProcesses.SetProccess, (2) SetModules (auto-appends ".dll"), (3) SetWindowTitles. Then immediately: `DetectHackProcesses(true,false); DetectHackModules(true,false); DetectHackTitles(true,false); DetectDebugger()` — one-shot with `sleep=false`. Returns 1. | Patch entry `B8 01 00 00 00 C3`. Banned lists never populate → DetectHack* lookups always miss. | S5.01 armed | none | HIGH |
| S5.04 | Read of int32 `-559039810` at handler entry (arg1 or context register) | Confirm magic on first handler dispatch. | Value at `[ebp+8]` (or the equivalent) = `0xDEADBABE`. Note: this constant is NOT stored as a 4-byte literal `BE BA AD DE` anywhere in the AC binaries (YARA v2 note); it is built by immediate constant in the `push`/`mov` at the call sites in `SetMessageHandlers`. | Trace only. | S5.02 or S5.03 | none | HIGH |

**Triggering sequence:** login past character-select and enter world. The server issues opcode 14 within a few seconds. To force a rescan on demand, disconnect and reconnect (each session repeats the handshake).

---

## Subsystem 6 — DetourMgr / GlobalOffsets Watch Points

**Verified inert.** `enum GlobalOffsets` has no .NET metadata (native C++ enum used only as a template type parameter), the `phmap::flat_hash_map<GlobalOffsets, unsigned char*>` `ManagedDetourMgr::FunctionMap` has size=0, capacity=0 initialised to `EmptyGroup`, and no code inserts into it or reads from it (see 11b + `re/divxtac_globaloffsets.json`).

The only breakpoints here are **CI/regression** BPs that fire ONLY if a future DivxTac update arms the map.

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S6.01 | DivxTac.dll + `0x1028` — `ManagedDetourMgr::FunctionMap$initializer$` | Once at DLL_PROCESS_ATTACH. | Should fire exactly once; only 5 zero-init writes visible (offsets +0/+4/+8/+12/+20). If second call site pushes non-zero values → DetourMgr has been armed. | None needed. | Extensions loading DivxTac | n/a | HIGH |
| S6.02 | DivxTac.dll + `0x100c` — `DetourMgr::Instance$initializer$` (unique_ptr new(4U)) | Once at DLL_PROCESS_ATTACH. | Only a 4-byte allocation. Never revisited. | None. | | n/a | HIGH |
| S6.03 | DivxTac.dll + `0x85a0` — `DetourMgr::Instance` atexit dtor | Should fire only at DLL_PROCESS_DETACH. Mid-session hit ⇒ singleton rebuilt (armed). | | None. | | n/a | HIGH |
| S6.04 | DivxTac.dll + `0x8654` — `ManagedDetourMgr::FunctionMap` atexit dtor | Same as S6.03. | | None. | | n/a | HIGH |
| S6.05 | Data-BP (RW-4-byte) on the map header at `map_ptr+0/+4/+8/+12/+20` (resolve `map_ptr` after S6.01 fires) | Any mid-session write ⇒ map was populated. Fires on the exact `GlobalOffsets` key inserted. | If ever fires: capture the key + slot pointer → identifies which client function is being watched → re-analyze before shipping a RaijinLab build. | Static: assert `grep -c "FunctionMap|Instance@DetourMgr" DivxTac.dll.decompiled.c` == 4 across DivxTac updates. | | n/a | HIGH |

---

## Subsystem 7 — Network AC Emit Sites (opcodes 1311 / 1312 on the wire)

**Wire truth (per `push imm32` grep in `.text`, note 11d §2):**
- **CMSG_ANTICHEAT_ALERT = 0x51F = 1311**
- **CMSG_ANTICHEAT_VERSION = 0x520 = 1312**
- **SMSG_WARDEN_DATA / CMSG_WARDEN_DATA**: name-table indices 740/741 (Ascension-shifted −2 from stock 742/743), **zero `push imm` sites, zero handler registrations. Legacy Warden is dead on Extensions.dll's wire.**

Extensions.dll has **5** CMSG_ANTICHEAT_ALERT emit sites, all using the same template (build CDataStore → `push 0x51F` → `call [0x10bca0cc]` → payload magic). Reconciled magic per site:

| Emit site | Payload magic (dwordA, dwordB) | Detection class (candidate) |
|---|---|---|
| `0x100b56dc` (sink S3.15/S3.16) | `0x2E4AD59E, 0x0F95819C` | anti-debug 14-vector |
| `0x102dba13` | (payload not extracted — see 11d follow-ups) | unknown |
| `0x10a46260` | `0x225DC89E, 0x159E97B6` | candidate: hook/module scan |
| `0x10a4d292` | `0x225DC89E, 0x159E97B6` | candidate: hook/module scan |
| `0x10a7957b` | `0x225DC89E, 0x159E97B6` | candidate: hook/module scan |

CMSG_ANTICHEAT_VERSION (`0x520`): **zero `push imm` sites in Extensions.dll**. All 1312 emission is DivxTac managed (`AnticheatInitializeHandler` L2889, subtype=4 + HDD serial).

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S7.01 | Extensions.dll + `0x100b56dc` | Sink send (S3.15). | `push 0x51F` immediately before `call [0x10bca0cc]`. Reason magic `0x2E4AD59E/0x0F95819C`. | See S3.17. | S3.15 | none | HIGH |
| S7.02 | Extensions.dll + `0x102dba13` | 2nd emit path (uninvestigated). Trigger unknown — needs runtime BP. | Confirm reason-code magic dword pair on stack. | Local NOP on the `call [0x10bca0cc]` 6 bytes after the push. | | none | MED |
| S7.03 | Extensions.dll + `0x10a46260` | 3rd emit path. | Reason `0x225DC89E/0x159E97B6`. | Same 6-byte NOP pattern. | | none | MED |
| S7.04 | Extensions.dll + `0x10a4d292` | 4th emit path. | Same as S7.03. | Same. | | none | MED |
| S7.05 | Extensions.dll + `0x10a7957b` | 5th emit path. | Same as S7.03. | Same. | | none | MED |
| S7.06 | Ascension.exe + `0x0047B0A0` — CDataStore preparer | **The single choke point for all 5 Extensions.dll alert sites AND all 3 DivxTac managed alert sites AND the version handshake.** Also carries normal traffic. | `ecx = CDataStore*`, opcode at `[esp+4]`. | Filter hook: return early for opcode 1311/1312, pass-through for everything else. **Single-hook whole-AC-network kill.** | Extensions loaded | none | HIGH |
| S7.07 | Extensions.dll + `0x100b5993` — the `call esi` (net-service send) | Sink actually transmits. | esi/ecx as above. | See S3.18. | S3.15 | none | HIGH |
| S7.08 | Extensions.dll `.data` `0x10bca0bc` (CDataStore ctor fptr → Ascension `0x00401050`) | DR fires on first packet build. | Confirms preparer fptr wired. | — | Extensions loaded | none | HIGH |
| S7.09 | Extensions.dll `.data` `0x10bca0fc` (finalize fptr → Ascension `0x00401130`) | DR fires per packet. | Post-payload finalize. | — | | none | HIGH |
| S7.10 | Extensions.dll `.data` `0x10bca1EC / 0x10bca1F0` (net-service getter / send fn) | DR fires per send. | See sink Step-3 template. | — | | none | HIGH |
| S7.11 | Data-BP on **outbound packet buffer** at `[ebp-0xB0]` in sink | After finalize, before `call esi`. | Full 3-string ASCII payload + opcode + reason magic visible in memory. Snapshot the whole packet. | — | S3.15 | none | HIGH |
| S7.12 | (Stale name-table indices) Extensions.dll `0x102c7f84 / 0x102c7f8a` | Just for reference — the name-table trampolines for CMSG_ANTICHEAT_ALERT/VERSION at indices 1309/1310 (**off-by-2 from wire truth** — see 11d §1). Trampolines have 0 callers; they are debug/logging metadata only. | Never fires organically. | — | | none | HIGH |
| S7.13 | Any bp on strings `SMSG_WARDEN_DATA` (`0x10b4c19c`) / `CMSG_WARDEN_DATA` (`0x10b4c1b0`) references in `Extensions.dll .text` | Never fires. | Reference-only inside Extensions — the strings are dead entries in the `GetOpcodeName` thunk table at `0x102C9928` (indices 228/229, thunks `0x102C722E`/`0x102C7234`). **[Patch Round 1 correction — GAP 7]** The premise "no Warden handler exists" is only true for Extensions.dll. The **live native Warden handler lives in Ascension.exe** — see new Subsystem 11 (S11.01–S11.09) below. Server-driven Warden challenges CAN fire; this row is not the right BP to catch them. | — | | none | HIGH |
| S7.14 | Bp on `SMSG_CHECK_FOR_BOTS` (opcode 21) inbound / `CMSG_BOT_DETECTED2` (opcode 23) outbound in Ascension.exe `RegisterMessageHandler` cluster | Reserved bot-detection opcodes present in the name table. Live-status uninvestigated — may fire if server pushes bot-check probes. | Compare with S5.01 to see if any handler is registered. | Suppress at S7.06 filter if seen on the wire. | | none | LOW |

---

## Subsystem 8 — MMgr64 IPC (client-side call sites of the MemoryBridge protocol)

**Reminder: MMgr64 is NOT anti-cheat.** It is a stateless x64 out-of-process data service for DBC/content tables (see 11e). No RPM, no hashing, no AC opcodes. Included here because the client's MB integration touches process boot: if MMgr64 fails to start or handshake, boot halts on affected code paths, and mis-attributed "AC bans" during triage are often just MB timeouts.

### 8.a Client-side call sites (in Extensions.dll / Ascension.exe)

Names taken from client error strings referenced by the corresponding branches (see 11e §Q1).

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S8.01 | Extensions.dll — the branch containing string `"Refusing to launch MMgr64.exe without a valid object token."` (locate via `const_xref.py Extensions.dll "Refusing to launch MMgr64"`) | Boot, before `CreateProcess("MMgr64.exe", args)`. | Confirms client generated the object-token; args passed are `PID token` decimal + string. | Patch this fail-branch to unconditionally treat MB as "already connected" if running with no MMgr64. | Extensions loaded | none | MED |
| S8.02 | Extensions.dll — `CreateProcessW` / `ShellExecute` call site for `MMgr64.exe` (locate via xref to `MMgr64.exe` string) | Boot spawn. | Command line = `MMgr64.exe <PID> <token>`. | Hook `CreateProcessW` to spoof-success without spawning. | | none | MED |
| S8.03 | Extensions.dll — the branch containing string `"MemoryBridge protocol mismatch. client={} server={}"` | Handshake reply check. | Client expects server protocol version = 3. | Ensure spoof/mock returns 3. | S8.02 | none | MED |
| S8.04 | Extensions.dll — `"Timed out waiting {} ms for MemoryBridge command {}."` branch | Every RPC send that doesn't get a response event within timeout. | Which command timed out reveals which DBC table path is starved. | Extend timeout, or wire an in-process mock. | | none | MED |
| S8.05 | Extensions.dll — `"MemoryBridge server exited before {} opened."` branch | Watchdog on the client side. | Confirms server-death handling. | Suppress if you deleted the bridge entirely (RaijinLab port). | | none | MED |
| S8.06 | Extensions.dll — `"MemoryBridgeClient is not connected."` branch | Graceful degradation attempt on RPC-while-disconnected. | Rarely hit — client code branches on connection state at top-level. | — | | none | MED |

### 8.b Mapping/event name transform (client-side)

The 4 named kernel objects (`request mapping`, `response mapping`, `request event`, `response event`) are per-session (no `Global\`/`Local\` prefix). The name is derived from the object token passed on the command line. To reproduce byte-for-byte in a mock: BP the `CreateFileMappingW` and `CreateEventW` calls **inside Extensions.dll** (client side) at boot, read the `lpName` arg, and reverse the token→name transform.

| ID | location | trigger | observation | bypass | conf |
|---|---|---|---|---|---|
| S8.07 | Extensions.dll IAT thunk `KERNEL32!CreateFileMappingW` (locate via `xref_imports.py Extensions.dll CreateFileMappingW`) | Client-side view-open for request/response mappings. | `lpName` at `[esp+0x18]` (last arg on x86 stdcall). Capture 4 names. | — | MED |
| S8.08 | Extensions.dll IAT thunk `KERNEL32!OpenEventW` / `CreateEventW` | Client-side event-open. | Same. | — | MED |

### 8.c MMgr64 server-side anchors (only if you're mocking the server)

Full set already in note 11e §Breakpoints; repeated here for one-stop access:

| ID | location | trigger | observation | bypass | conf |
|---|---|---|---|---|---|
| S8.09 | MMgr64.exe + `0x14000154b` | `wcstoul(argv[1])` — PID parse. | argc must be ≥3. | Mock honours contract. | HIGH |
| S8.10 | MMgr64.exe + `0x1400018c2` | Fatal `MessageBoxA`. | Fires on invalid CLI. | NOP CALL to silence. | HIGH |
| S8.11 | MMgr64.exe + `0x14000d5ed` / `0x140026a24` | OpenProcess(mask=`0x101000`). | Mask is SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION — cannot read client memory. | Mock returns pseudo-handle. | HIGH |
| S8.12 | MMgr64.exe + `0x14000d79d`+`0x14000d7b7` (ProcessIdToSessionId pair) + `0x14000d7cb` (`cmp`/`je`) | Cross-session rejection. | Client and server session-IDs compared. | Patch `je` to `jmp` for cross-session mock. | HIGH |
| S8.13 | MMgr64.exe + `0x14001fc2d` / `0x14001fe2a` | `CreateFileMappingW` req/resp (1 MB PAGE_READWRITE, page-file-backed). | Capture `lpName` from `[rsp+0x28]`. | — | HIGH |
| S8.14 | MMgr64.exe + `0x14001ff9b` / `0x140020069` | `CreateEventW` auto-reset req/resp. | Same. | — | HIGH |
| S8.15 | MMgr64.exe + `0x140025867` | `WaitForSingleObject(requestEvent)` — server main loop. | Break to dump every request frame before dispatch. | — | HIGH |
| S8.16 | MMgr64.exe + `0x140025d8f` | `SetEvent(responseEvent)` — response commit. | Break to capture every response frame. | — | HIGH |
| S8.17 | MMgr64.exe + `0x140029c87` | Stock MSVC `_seh_filter_exe` `IsDebuggerPresent`. | **Not anti-debug** — no evasive branch, no exit path. | Ignore. | HIGH |

---

## Subsystem 9 — Legacy Warden / Scan.dll download path (dead in this build)

**Scope narrowed after Patch Round 1.** This subsystem covers ONLY the disk-cached `Scan.dll` download / verify / load path. The **in-process native Warden handler** is a different subsystem — see new Subsystem 11 (S11.01–S11.09) added Patch Round 1.

**Verified dead (see 11f).** `ScanDLLStart @ Ascension.exe!0x4dccf0 = mov eax, 0; ret`. Download cluster `0x4e58d0..0x4e5e6x` has 0 callers. `IsLinuxClient` is the stock nil-returning stub shared with `IsMacClient` — not a Wine/unlocker probe.

**Note:** The prior claim "zero `Warden` opcode strings anywhere" was correct for `Ascension.exe` **string references** but did not survey the opcode-based dispatcher. Patch Round 1 GAP 7 found the live handler is dispatched by opcode number (`0x2E6`) with no string reference in Ascension.exe — the `WardenClient.cpp` source-file string at `0x00A40774` is the sole textual anchor. Subsystem 11 covers this.

BPs below are **regression-only** — they confirm the subsystem hasn't been un-stubbed in a client update.

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S9.01 | Ascension.exe + `0x4dccf0` — `ScanDLLStart` entry | Never fires organically (no callers). Reading the first 6 bytes should yield `B8 00 00 00 00 C3`. | Divergence ⇒ someone unpatched or repurposed the stub. Flip the whole 9-subsystem verdict — re-audit. | Not needed — already inert. | none | none | HIGH |
| S9.02 | Ascension.exe + `0x510b90` — `IsMacClient` / `IsLinuxClient` shared body | Fires on Lua-side query. First ~11 bytes should be `55 8B EC 8B 45 08 50 E8 E4 D6 33 00`. | Divergence ⇒ someone repurposed the OS predicate. | Not needed. | Lua VM up | none | HIGH |
| S9.03 | Ascension.exe + `0x4e58d0` — ScanThread download proc | 0 direct callers — never fires. | If ever fires, someone re-wired the launcher. | — | | none | HIGH |
| S9.04 | DivxDecoder.dll + `0x1003a6d1` — sole `LoadLibraryA` call | Fires once during CRT init. Arg `[esp]` must resolve to `"user32.dll"` (VA `0x1004f860`). | Divergence to `DivxTac.dll` / `Extensions.dll` / any AC name ⇒ side-load hypothesis flips. | Not needed. | | none | HIGH |
| S9.05 | DivxDecoder.dll + `0x10038e51` — sole `GetProcAddress` call | Once during CRT init. Arg must resolve to `"IsProcessorFeaturePresent"` (VA `0x1004f728`). | Divergence ⇒ codec is doing something non-CRT. | Not needed. | | none | HIGH |

---

## Subsystem 10 — HWID Collection (`\\.\PhysicalDrive0` + SMART/STORAGE IOCTLs)

Ground truth from 11a §4 + `-Module-.cs` L1852-2134. Two acquisition paths, both hit standard OS storage stack (no kernel driver). Serial is emitted as CMSG_ANTICHEAT_VERSION (opcode 1312, subtype=4) via `AnticheatInitializeHandler` (S5.02).

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S10.01 | DivxTac.dll + `0x3ecc` (RVA `0x3ec0`) — `ReadPhysicalDriveInNTUsingSmart` | Called from `getHardDriveComputerID` if `IsWindowsVersionOrGreater(5,1,0)` returns false. | `CreateFileA("\\\\.\\PhysicalDrive0", 0xC0000000, 7, NULL, 3, 0, NULL)` @ L1857 → IOCTL `0x00074080` SMART_GET_VERSION @ L1877 → IOCTL `0x0007C088` SMART_RCV_DRIVE_DATA @ L1896 (with `bCommandReg = 0xEC` = ATA IDENTIFY DEVICE). Parses IDENTIFY word 10-19 for serial. | See S10.03. | S5.02 | none | HIGH |
| S10.02 | DivxTac.dll + `0x3b30` (RVA `0x3b24`) — `ReadPhysicalDriveInNTWithZeroRights` (preferred path on Win5.1+) | Called from `getHardDriveComputerID` first. | `CreateFileA("\\\\.\\PhysicalDrive0", 0, 3, NULL, 3, 0, NULL)` @ L2062 (zero-rights handle) → IOCTL `0x002D1400` IOCTL_STORAGE_QUERY_PROPERTY @ L2086 → optional IOCTL `0x00070020` @ L2103 (auxiliary, result ignored). Extracts serial from `STORAGE_DEVICE_DESCRIPTOR` @ +12/+16/+20/+24. | See S10.03. | S5.02 | none | HIGH |
| S10.03 | DivxTac.dll IAT thunk `KERNEL32!DeviceIoControl` (locate via `xref_imports.py DivxTac.dll DeviceIoControl`) | Every IOCTL above. | Args: `hDevice, dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize`. | Filter IOCTLs `0x74080` / `0x7C088` / `0x2D1400` / `0x70020` when the handle's device path is `\\.\PhysicalDrive0`: either fail-cleanly (return 0 + SetLastError) or spoof the SerialNumber string in the returned buffer. Cleanest: intercept `S10.02` at entry and short-circuit to a stable dummy serial (mixed alnum, 20 chars, no whitespace so `flipAndCodeBytes` accepts it). | | none | HIGH |
| S10.04 | DivxTac.dll IAT thunk `KERNEL32!CreateFileA` | Called with device path `\\.\PhysicalDrive0`. | Filter by first arg. | Rewrite the path to a benign file, causing the subsequent IOCTLs to fail and forcing `GetSerialNo` to return an empty string. Server accepts empty payload; account then appears with a blank HWID (visible in server logs but no ban trigger). | | none | HIGH |
| S10.05 | DivxTac.dll — `MasterHardDiskSerial::GetSerialNo` (in `-Module-.cs` ~L2140-2170; native RVA locatable via Ghidra `MasterHardDiskSerial` symbols) | Called from `AnticheatInitializeHandler` before opcode 1312 emit. | Populates a `std::vector<char>` with the serial ASCII. | Patch entry to return an empty vector: safest single-BP HWID-spoof. | S5.02 | none | HIGH |

---

## Subsystem 11 — Ascension.exe Native Warden (in-process `WardenClient.cpp`) **[Added Patch Round 1 — GAP 7]**

**Live legacy Blizzard Warden** — refutes prior HANDOFF §2e / §2f "no live Warden path" claim. Module spans `Ascension.exe!0x7DA200 – 0x7DAAE0` (~2.3 KB, 22 xrefs to source-file string `".\\WardenClient.cpp"` at `0x00A40774`). Runs in-process, has a memcpy-based memory-read primitive over ANY region of the client, can be server-driven to scan `.text` of Ascension/Extensions/DivxTac at will. `detour_risk = none` (verified: no calls from Warden cluster into Extensions/DivxTac; not covered by DivxTac DetourMgr which is inert per S6).

**Singleton state layout (Ascension.exe `.data`):**
- `0xD31A48` — alive flag (byte)
- `0xD31A4C` — WardenClient singleton pointer (dword)
- `0xD31A50` — memory-read primitive: base address (dword)
- `0xD31A54` — memory-read primitive: length (dword)
- `0xD31A60` — `CRITICAL_SECTION` guarding all dispatch (EnterCS `0x774640`, LeaveCS `0x774650`)

| ID | location | trigger | observation | bypass | deps | detour_risk | conf |
|---|---|---|---|---|---|---|---|
| S11.01 | Ascension.exe + `0x7DA850` — `WardenClient` opcode-0x2E6 handler entry | Server sends `SMSG_WARDEN_DATA` (opcode `0x2E6` / 742) at any point during the session (frequency realm-dependent; some realms never fire it, others cycle every few minutes). | Dispatcher validates opcode `== 0x2E6`, reads packet body via `CDataStore::GetReadPtr` (`Ascension.exe!0x47B6B0`), then vtable-calls `WardenClient::OnPacket` at `[[0xD31A4C]]+8`. Args at entry: opcode in reg (per calling convention of `SetMessageHandler` slot), CDataStore ptr as second arg. | **1-byte `0xC3` at `0x7DA850`** — handler returns immediately, server-side Warden challenge is silently dropped. Server may interpret prolonged silence as a probe fail, so pair with S11.06 (silent-ACK path) if the realm enforces response timing. | Ascension.exe loaded, S11.03 has run | none | HIGH |
| S11.02 | Ascension.exe + `0x7DA917` — `ClientServices::SetMessageHandler(0x2E6, 0x7DA850, 0)` call | Fires ONCE during client init (early enough that a startup BP catches it). | Confirms handler registration. `[esp]` should show `0x2E6, 0x7DA850, 0`. The `SetMessageHandler` implementation is `Ascension.exe!0x6B0B80`. | NOP the entire call (5 bytes `E8 xx xx xx xx -> 90*5`) — handler never registers, server dispatch has nowhere to land, `SMSG_WARDEN_DATA` becomes a no-op. **Cleanest single-BP kill for the entire Warden subsystem** — preferred over S11.01 because no partial-execution risk. | Ascension.exe init reached | none | HIGH |
| S11.03 | Ascension.exe `.data` `0xD31A4C` — WardenClient singleton pointer | Data-BP WRITE fires ONCE when the singleton is allocated (during init, before S11.02). | Value stabilizes to the WardenClient object base. Vtable at `[value+0]`, `OnPacket` at `[[value+0]] + 8`. | Trace only. Nulling this word after init causes S11.01 to crash on the vtable deref; use S11.02 instead. | Ascension.exe init | none | HIGH |
| S11.04 | Ascension.exe + `0x7DA500` — Warden memory-read primitive (entry variant A) | Called from `WardenClient::OnPacket` when server issues a memory-scan challenge. | Args stash base address in `[0xD31A50]` and length in `[0xD31A54]`, then invoke memcpy at `0x40CB10` copying `[base..base+length]` into a response buffer. Buffer is later serialized into `CMSG_WARDEN_DATA` via S11.06. **THIS is the .text integrity check** — the ONE thing DivxTac lacks. | **1-byte `0xC3` at `0x7DA500`** — memory reads return uninitialized/empty buffer. Alternatively, hook memcpy at `0x40CB10` (careful — used by non-Warden code too) with a filter on the return address. Cleanest: patch S11.02 to prevent handler registration in the first place. | S11.01 fires with a memory-scan sub-command | none | HIGH |
| S11.05 | Ascension.exe + `0x7DA550` — Warden memory-read primitive (entry variant B) | Second entry point into the same primitive family (per GAP 7 findings — likely a length- or region-variant). | Same base/length stash into `[0xD31A50]`/`[0xD31A54]`. | Same as S11.04 — `0xC3` at entry. Patch BOTH `0x7DA500` and `0x7DA550` for complete memory-read neutralization. | S11.01 fires with a memory-scan sub-command | none | HIGH |
| S11.06 | Ascension.exe + `0x7DAAE9` — outbound `CMSG_WARDEN_DATA` (opcode `0x2E7` / 743) build/send | Any Warden challenge that generates a response — memory-read results, hash results, control commands. | Uses CDataStore vtable at `0x9E2148`, `PutOpcode 0x47B0A0` (same preparer choke point as S7.06 — a filter there will also see `0x2E7`), `PutByte 0x47AFE0`, `SendPacket 0x6B0B50`. | Add opcodes `0x2E6`/`0x2E7` to the S7.06 (`Ascension.exe!0x0047B0A0`) filter to catch both directions. For a **silent-ACK** (server sees a well-formed empty response, no timeout): let the handler build the packet but blank the body via hook — patch `[0x7DAAE9]` region to send a zero-length payload. | S11.01 fires | none | HIGH |
| S11.07 | Ascension.exe `.data` `0xD31A50` (memory-read base) / `0xD31A54` (memory-read length) | Data-BP WRITE fires per memory-scan challenge. | Reveals exactly which VA range the server is challenging (Ascension.exe `.text`? Extensions.dll `.text`? DivxTac.dll? your addon? The answer is realm-policy-dependent and only visible at runtime). **Highest-value dynamic probe for understanding realm Warden policy.** | Trace only. Log every base/length pair over a long session to enumerate the realm's scan targets. | S11.01 fires with a memory-scan sub-command | none | HIGH |
| S11.08 | Ascension.exe + `0x774640` — `EnterCriticalSection` wrapper for `0xD31A60` / + `0x774650` — `LeaveCriticalSection` wrapper | Every Warden dispatch enters/exits this CS. Filter Data-BP on `0xD31A60` to isolate Warden-only entries. | Confirms dispatch is serialized (no re-entrancy). | Do NOT hold this CS from another thread — will deadlock the game if Warden dispatch queues behind you. | S11.01 fires | none | HIGH |
| S11.09 | Ascension.exe `.data` `0xD31A48` (alive flag byte) | Data-BP WRITE fires ONCE during S11.03. | Read pattern in the dispatcher gates whether Warden is armed for the current session. | Zero the byte after S11.03 and before login → dispatcher no-ops. Alternate to S11.02 with slightly higher risk (any code that reads the flag for other purposes will also see 0). | Ascension.exe init | none | HIGH |

**Reconciliation:** Prior Subsystem 7 emit table stated CMSG_ANTICHEAT_ALERT (1311) and CMSG_ANTICHEAT_VERSION (1312) were the only client-side AC opcodes on the wire. **Add**: `CMSG_WARDEN_DATA` (0x2E7 / 743) can now fire from `Ascension.exe!0x7DAAE9` in response to server Warden challenges. The S7.06 filter at `Ascension.exe!0x0047B0A0` must be extended to drop/inspect opcodes `0x2E6` (inbound, unusual for a client-side send filter but visible in the read path via S11.01) and `0x2E7` (outbound response). Practical: **the S7.06 opcode-filter list becomes `{0x51F, 0x520, 0x2E7}`** to fully neutralize wire AC traffic.

**Trigger sequence for Subsystem 11:** Warden dispatch is server-driven, not polling. To force a hit: log in and play normally for an extended session; some realms Warden-check on world entry, others on periodic timers, others on suspicious behavior. If S11.01 never fires across a 15-minute session against your realm, that realm does not currently issue Warden challenges — but this is a **policy setting, not a code fact**; the handler is armed and will respond to any future policy change without a client update.

---

## Suggested Trigger Sequence

The full sequence below guarantees every catalog BP that CAN fire will fire at least once, in dependency order. Times assume attach-mode debugger (S3.03 and S4.05 also silently satisfied by attach — no debug port).

### 0. Pre-attach setup
- Launch `x32dbg`. Load the script `re/scripts/set_ac_breakpoints.x32dbg.txt`. Disable HW breakpoints entirely for the session (S3.05 hardware-DR scan will otherwise fire immediately). Configure exception handlers: `pass to app` for `STATUS_BREAKPOINT`, `STATUS_SINGLE_STEP`, `STATUS_INVALID_HANDLE (0xC0000008)`, and `INT 2D`.

### 1. Launch client → S1.01, S1.02 storm; S2.01 fires once
- Start `Ascension.exe`. Wait for the login window. During load:
  - S1.01/S1.02 fire hundreds of times (detour installer). Log-only.
  - S1.03/S1.04 fire once when the trampoline builder runs.
  - S1.06 (data-BP on `0x10bca0cc`) fires when Ascension.exe first populates the client-services fptr table into Extensions.dll `.data`.
  - S8.02 fires when Extensions spawns `MMgr64.exe`.
  - S8.09, S8.10 (if invalid CLI), S8.13, S8.14 fire inside MMgr64.
  - S6.01, S6.02 fire once in DivxTac at DLL_PROCESS_ATTACH.
  - S2.01 fires when the parent monitor thread `FUN_10a3dc20` starts.
  - S4.01 fires when DivxTac's managed AntiCheatThreadLoop starts.
  - S9.04, S9.05 fire inside DivxDecoder's CRT init.
  - S10.01 or S10.02 does **not** fire yet — HDD serial is only fetched on opcode 14.

### 2. Attach x32dbg — Extensions 14 vectors sweep begins
- Attach after ~2 s. S2.02 fires every ~5 s (parent loop sleep). Within one pass:
  - S3.01 (PEB.BeingDebugged) fires. Attach mode → not detected.
  - S3.06 (PEB.NtGlobalFlag) fires. Only detected if debug heap in use.
  - S3.02 (CheckRemoteDebuggerPresent) fires.
  - S3.03 (IsDebuggerPresent) fires. Attach mode → returns 0.
  - S3.07 (NtQueryInformationProcess) fires. Trip if ProcessDebugPort/Handle/Flags nonzero.
  - S3.05 (HW DR scan) fires. Detects if you set HW BPs.
  - S3.04, S3.09 (FindWindowW) fire. Trip if debugger window class in whitelist.
  - S3.08 (CloseHandleException) fires — pass STATUS_INVALID_HANDLE to app.
  - S3.10 (INT 2D), S3.11 (INT 3), S3.12 (MOVSS), S3.13 (PREFIXHOP), S3.14 (SINGLESTEP) fire — pass exceptions to app.
- If any vector trips, S3.15 (sink) fires, S3.16/S3.17/S3.18 execute in sequence, S3.19 latches, S3.20 spawns the helper. S7.01 confirms opcode 0x51F on the wire path. S7.11 dump reveals the full packet.

### 3. Login to character-select → S5.02 fires
- Enter credentials, click Login. On authentication success, server pushes opcode 14. In DivxTac:
  - S5.02 (`AnticheatInitializeHandler`) fires. Confirm S5.04 (arg1 = `0xDEADBABE`).
  - S4.08 (`SetMessageHandlers`) fires (idempotent re-register inside handler).
  - S10.02 or S10.01 fires → S10.03 IOCTL scan → S10.05 GetSerialNo builds the vector.
  - CMSG_ANTICHEAT_VERSION emit path fires — S7.06 (Ascension `0x0047B0A0`) sees opcode 0x520 on the wire.

### 4. Server responds with banned lists → S5.03 fires
- Usually within 100 ms of opcode 1312. In DivxTac:
  - S5.03 (`AnticheatBannedProcessListHandler`) fires. Confirm S5.04.
  - Handler immediately runs one-shot: S4.03 → S4.02 → S4.04 → S4.05 (`sleep=false`).
  - Any hit fires S4.06 or S4.07, which transitively fire S7.06 with opcode 0x51F.

### 5. Enter world (character selection → in-game)
- On world entry, the game emits normal traffic through S7.06 — verify filter is only dropping 1311/1312 (all other opcodes pass through). Continue running for ≥ 130 s to catch a full DivxTac cycle (S4.02 → 60s → S4.03 → 60s → S4.04 → S4.05).
- Extensions' ~5-second sweep continues. Do periodic manipulations to trigger additional detection classes:
  - **Move**: no impact (movement doesn't touch AC).
  - **Cast a spell**: no impact.
  - **Alt-tab out and back**: harmless.
  - **Alt-tab and open a debugger window with a matching class name (temporarily rename x32dbg)**: fires S3.04 / S3.09 on next pass → S3.15.
  - **Set a HW breakpoint**: fires S3.05 on next pass → S3.15.
  - **Attach a second debugger**: fires S3.03, S3.07 → S3.15.
  - **Close-handle trick**: `CloseHandle((HANDLE)0xDEADBEEF)` from an addon Lua stub (if reachable) — no organic client trigger; use manual `set eip = 0x100b6750` + step to force S3.08.

### 6. Force banned-process detection (opcode 1311, non-debug path)
- Rename `notepad.exe` to `mhook.dll` (any banned name — first pass observation of S5.03 reveals the actual server list). Launch it. On next S4.02 pass, hit → S4.06 → S7.06 with opcode 0x51F.

### 7. Emergency dry-run kill
- If AC becomes noisy during triage: single-hook `Ascension.exe!0x0047B0A0` (S7.06) with a filter dropping opcodes 1311 and 1312, pass-through for everything else. All AC packets die on the way to the wire; game keeps working. This is the highest-leverage single intervention in the entire catalog.

### 8. Cleanup / regression check
- Detach. On DLL_PROCESS_DETACH, S6.03 and S6.04 fire (once each). Any earlier hit ⇒ subsystem was armed mid-session → re-audit before shipping.

---

## Cross-reference summary

- **Single-BP kill switches** (choose one, in preference order):
  - S7.06 (Ascension `0x0047B0A0` filter — kills all AC network traffic while preserving game traffic; ONE hook). **[Patch Round 1]** Filter list becomes `{0x51F, 0x520, 0x2E7}` to also cover native Warden responses (S11.06).
  - S1.07 (Extensions `0x10A3B690` = `0xC3` — **[Patch Round 1 — GAP 8]** highest-leverage single kill for the entire DivxTac subsystem: DivxTac.dll never loads, S4/S5/S10 never instantiate)
  - S4.08 (DivxTac `SetMessageHandlers` = 0xC3 — kills the entire DivxTac subsystem post-load, breaks HWID + banned-list flow; use only if S1.07 unavailable)
  - S3.15 (Extensions sink = 0xC3 — kills all 14 anti-debug vectors)
  - S2.01 (Extensions parent loop = 0xC3 — kills the sweep before it starts)
  - S11.02 (Ascension `0x7DA917` `SetMessageHandler` call NOP — **[Patch Round 1 — GAP 7]** kills native Warden by preventing handler registration)
- **Latch-based bypass** (Extensions only, preserves the sink for logging): S2.03 write-once + reinit-block NOPs.
- **HWID spoof**: S10.05 or S10.03 filter.
- **DivxTac IsDebuggerPresent-only bypass**: S4.09 IAT hook.
- **All-vectors debugger evasion without patches**: attach mode + ScyllaHide + Kill-HW-BPs + exception pass-to-app + debugger window-class rename.

## Verified inert (do NOT waste BP slots)

- Scan.dll download / disk-cache path (Subsystem 9) — S9.01-S9.03 regression-only. **NOTE [Patch Round 1 — GAP 7]:** this covers ONLY the disk-cached loader path. The **in-process** `WardenClient.cpp` inside Ascension.exe is fully alive — see Subsystem 11.
- DivxDecoder side-load hypothesis (9.b) — S9.04/S9.05 regression-only.
- DivxTac DetourMgr (S6.01-S6.05) — all BPs are regression-only.
- MMgr64 anti-cheat capability (S8.11 mask, S8.17 IsDebuggerPresent) — no detection capability; MB is data-only.
- WowError.exe **[Patch Round 1 — GAP 6]** — benign crash reporter, no OpenProcess/RPM/dbghelp/HWID capability, no AC opcode traffic. Not on the AC hot path. No BPs needed. If attribution is a concern: block `crash-report.ascension.gg`, NOP `Ascension.exe!0x00403543`, or delete the file.

## Files & upstream

- Notes: `notes/11a_divxtac_ac_logic.md`, `11b_divxtac_detourmgr.md`, `11c_extensions_sink_body.md`, `11d_extensions_network_ac.md`, `11e_mmgr64_memorybridge.md`, `11f_ascension_scan_divxdecoder.md`.
- Patch Round 1 (Static Gap Remediation) notes: `notes/14_gap2_deadbabe_reverify.md`, `14_gap4_functionmap_rawdisasm.md`, `14_gap5_hash_diff_dumps.md`, `14_gap6_wowerror_triage.md`, `14_gap7_warden_native_handler.md`, `14_gap8_ext_divxtac_load_edge.md`. Round-up in `HANDOFF_claude.md` §9.
- Data: `re/ext_antidebug_vectors.json` (14 vectors), `re/ext_virtualprotect_callsites.json` (4 sites), `re/ascension_ac_opcodes.json` (69 opcodes incl. 14/35 handler bindings + 1311/1312), `re/divxtac_globaloffsets.json` (empty — subsystem inert).
- x32dbg script: `re/scripts/set_ac_breakpoints.x32dbg.txt` (39 BPs — subset of this catalog, module+RVA form for ASLR safety).
- YARA v2: `re/yara/ascension_ac_v2.yar` (5 rules; note the `0xDEADBABE` constant is NOT present as literal bytes in the AC binaries, per the YARA report — verify at runtime via S5.04).
- Frida probe plan: `notes/FRIDA_probe_plan.md` (attach-mode 7-hook design complementing this static catalog).
