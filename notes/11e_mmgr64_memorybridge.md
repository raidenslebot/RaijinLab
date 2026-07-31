# 11e — MMgr64.exe = MemoryBridge Server (NOT anti-cheat)

Author: Claude (Opus 4.7) — confirms & extends Grok's `03_memorybridge.md`.

## TL;DR
`MMgr64.exe` is a **stateless x64 shared-memory data-service** launched by 32-bit
`Ascension.exe`/`Extensions.dll` at startup. It hosts large data tables
(DBCs/content mirrors, ~42 MB total in first run) that don't fit in the client's
32-bit address space and serves per-request/per-batch RPC queries over two
page-file-backed file mappings + two auto-reset events. It has **zero
integrity-scanning capability**: it never reads client memory, never hashes,
never crypto's, and its only OpenProcess is `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION`
strictly for session-match and liveness-wait. The lone `IsDebuggerPresent` is
the stock MSVC `_seh_filter_exe` UEF stub; `TerminateProcess` has **zero direct
call sites** (imported but unused). Ghidra's decompiler failed on this binary
(all `<decompile failed>`) — every claim below is grounded in raw
disassembly + strings + IAT xrefs, not decomp.

**Consequence for RaijinLab port:** MemoryBridge is a functional dependency,
not a defensive one. To port, either (a) implement a mock MMgr64 that speaks
protocol v3, or (b) inline the 6 tables directly into the runtime process
(preferred — the client is being re-implemented for 64-bit anyway, so the
whole raison-d'etre of MMgr64 disappears).

---

## Q1 — Shared-memory handshake

### Command line contract (`_tWinMain` around FUN_140001470 / entry at 0x140001220)
Verified disasm around 0x14000154b:
```
call GetCommandLineW          ; 0x1400014f0
call CommandLineToArgvW       ; 0x1400014fe
cmp  [rsp+0x30], 2            ; argc must be >= 3 (progname + PID + token)
jle  <fatal MessageBoxA>      ; else → 0x1400018c2 with "Client PID or object token not provided"
mov  rcx, argv[1]
mov  r8d, 10                  ; base 10
call wcstoul                  ; parse decimal PID
```
Then argv[2] is copied via `strlen`/`memcpy` (0x140029ebe/0x140029e8e) into an
internal string — this is the **object token**.

Fatal-error box at **0x1400018c2** invokes `MessageBoxA(NULL, "Client PID or object token not provided", "Invalid client PID provided", MB_OK)` (per the two format strings `Invalid client PID provided`, `Client PID or object token not provided`) and exits with `ebx=1`.

Additional startup rejects (from strings, in order of the guarded steps):
- `Invalid client PID {}; exiting server.` — PID = 0 or self
- `Client process (PID {}) not found; exiting server.` — OpenProcess failed
- `Client process (PID {}) is not running; exiting server.` — WaitForSingleObject(0) returned WAIT_OBJECT_0 immediately
- `Unable to validate client process session for PID {}; exiting server.` — ProcessIdToSessionId failed
- `Client process (PID {}) is in session {}, server is in session {}; exiting server.` — cross-session
- `MemoryBridgeServer rejected malformed object token.` — token structural validation fails
- `Refusing to use existing MemoryBridge {}.` — CreateFileMapping returned ERROR_ALREADY_EXISTS on either of the two mappings (prevents cross-session hijack via same-token collision, also blocks a second server instance)

### Session validation choke point (verified disasm at 0x14000d7b7)
```
call ProcessIdToSessionId(clientPID, &clientSess)   ; 0x14000d79d
test eax,eax / je <fail>
call GetCurrentProcessId                             ; 0x14000d7ab
call ProcessIdToSessionId(serverPID, &serverSess)   ; 0x14000d7b7
test eax,eax / je <fail>
mov  eax, [serverSess]
cmp  [clientSess], eax
je   <pass>
<fail path builds "in session {}, server is in session {}" error>
```
Duplicated at 0x140026c2d/0x140026c47 (second callsite pair — same pattern; likely
one is the launcher gate and the other is the pre-command-dispatch re-check).

### Object token → object name pattern
Extensions client strings show the token is generated client-side
("Failed to generate a valid MemoryBridge object token." /
 "Refusing to launch MMgr64.exe without a valid object token.")
and passed on the command line to MMgr64. MMgr64 uses it as the name suffix
for the four named kernel objects. The four object *categories* are named in
strings verbatim:
- `request mapping`  (the request file mapping name label)
- `response mapping` (the response file mapping name label)
- `request event`    (auto-reset event, client→server signal)
- `response event`   (auto-reset event, server→client signal)

There is **no `Global\` or `Local\` prefix** in the string table — objects live
in the default (per-session) namespace, which is consistent with the
session-ID rejection: cross-session peers can't even *see* the objects.

`ConvertStringSecurityDescriptorToSecurityDescriptorW` is imported and
referenced by the strings `Failed to create MemoryBridge object security descriptor: {}`.
A SDDL string builds an explicit DACL for the four objects; MMgr64 then passes
that as `lpSecurityAttributes` to CreateFileMappingW and CreateEventW. (No FF15
xref survived the scan because the ADVAPI import is called via a compiler-
emitted thunk that FF15-scanning missed; the string binding is definitive.)

### The 4 shared kernel objects (verified from disasm + strings)
| Object | Created at | Constructor args | Purpose |
|---|---|---|---|
| request mapping  | 0x14001fc2d | `CreateFileMappingW(INVALID_HANDLE_VALUE, sd, PAGE_READWRITE, 0, 0x100000, name)` — 1 MB | client→server serialized request bytes |
| response mapping | 0x14001fe2a | same signature, 1 MB | server→client serialized response bytes |
| request event    | 0x14001ff9b | `CreateEventW(sd, FALSE, FALSE, name)` (auto-reset) | client signals "request ready" |
| response event   | 0x140020069 | same | server signals "response ready" |

MapViewOfFile pairs: 0x14001fd65 (request view, FILE_MAP_ALL_ACCESS, 1 MB offset 0),
0x14001fef7 (response view, same). Views are stored at `[rdi+0x40]` and `[rdi+0x48]`.
Unmapped at 0x14002683d / 0x140026863 during shutdown.

### Protocol version = 3
Emitted in `MemoryBridgeServer initialized. clientPID={} serverPID={} protocol={}`
and matched against client's `MemoryBridge protocol mismatch. client={} server={}`
error. The version is a hard-fail comparison in the handshake reply, not
negotiable.

### PID + session validation (final choke point)
Client emits `MemoryBridge handshake PID mismatch. client expected={} actual={} server={}` —
i.e. the server's handshake response contains the client PID it observed
(`GetCurrentProcessId` at 0x14000d7ab is server-side; the client also passes
its own PID on the cmdline). Mismatch between the PID the client thinks it is
and the PID MMgr64 observed → hard-fail.

---

## Q2 — Full RPC command set

The command dispatcher is a switch on a uint32 opcode inside the deserialized
request message (`Failed to deserialize request message.` on parse failure).
All command IDs below are inferred **structurally** from the ordering of the
error strings in the read-only data segment (they appear in switch/table
order in every MSVC-emitted dispatcher I've seen; log confirms command 3
returned `invalid_argument` — a deliberate gap in the switch used as the
self-test negative case). Numeric IDs are **candidate/observed** not
guaranteed; the shape/name of each verb is verified from the strings.

Two dispatch layers are observed:
1. Top-level opcode → generic memory ops OR sub-dispatch into "batch operation" (`Unknown batch operation {}`)
2. Batch sub-opcode → per-table verbs.

### Generic memory verbs (opcode 1..~8)
| Verb | Args | Reply | Error string |
|---|---|---|---|
| Alloc(size) | u32 size | u32 handle | `Allocation failed for {} bytes` |
| Free(handle) | u32 handle | none | `Invalid handle {} for free` |
| Read(handle, offset, len) | u32×3 | bytes[len] | `Read out of bounds for handle {}` |
| Write(handle, offset, bytes) | u32,u32,bytes | none | `Write out of bounds for handle {}` |
| CreateTable(recordCount, recordSize) | u32×2 | u32 tableHandle | `Table allocation failed for {} records of {} bytes` |
| DestroyTable(tableHandle) | u32 | none | `Invalid table handle {} for destroy` |

Log confirms opcode 3 is the invalid_argument slot ("MemoryBridge command 3
returned invalid_argument. clientPID=30052 serverPID=8164" — after Alloc/Write/
Read/Free and before CreateTable; the client deliberately hits an unassigned
opcode as part of the self-test).

### Per-table verbs (batch sub-op)
| Verb | Purpose | Error string |
|---|---|---|
| RecordWrite | copy raw row into slot | `Record write failed for table {}` |
| RecordPatch | update sub-fields of existing row | `Record patch failed for table {}` |
| RecordRead | fetch raw row | `Record read failed for table {}` |
| StringWrite | intern a string into table's string heap; returns string handle | `String write failed for table {}` |
| StringRead | pull interned string by handle | `String read failed for table {}` |
| CStringRead | pull null-terminated C string | `CString read failed for table {}` |
| CStringBatchRead | vectorized CStringRead | `CString batch read failed for table {}` |
| UInt32IndexBuild | build hash index on a uint32 field | `UInt32 index build failed for table {}` |
| UInt32IndexLookup | primary-key lookup | `UInt32 index lookup failed for table {}` |
| UInt32IndexedRecordRead | index lookup + full row fetch (one call) | `UInt32 indexed record read failed for table {}` |
| IndexedRecordBatchRead | vectorized UInt32IndexedRecordRead | `Indexed record batch read failed for table {}` |
| ProjectedRecordRead | column-subset row fetch (SELECT c1,c3 FROM t WHERE id=?) | `Projected record read failed for table {}` |
| ProjectedRecordBatchRead | vectorized projected read | `Projected record batch read failed for table {}` |
| ProjectedPredicateQuery | filtered projection (WHERE pred(row)) | `Projected predicate query failed for table {}` |

`Response message too large to send: {} bytes` is the response-mapping overflow
guard — the 1 MB response view caps batch response size.

### Wire framing
- Client writes request into request-mapping view, calls SetEvent(request event).
- Server WaitForSingleObject(request event) — WFSO site at 0x140025867 is the
  server's main loop wait; deserializes header, dispatches, serializes reply
  into response view, calls SetEvent(response event) (0x140025d8f).
- Client WFSO(response event) with timeout: on timeout emits
  `Timed out waiting {} ms for MemoryBridge command {}.`

---

## Q3 — Why OpenProcess on the server

**Session check + liveness wait ONLY. Not memory access. No DuplicateHandle
codepath.**

Verified disasm at both OpenProcess sites (0x14000d5ed and 0x140026a24):
```
call GetCurrentProcessId       ; guard: don't OpenProcess on self
cmp  edi, eax
je   <skip>
mov  r8d, edi                  ; PID
xor  edx, edx                  ; bInheritHandle = FALSE
mov  ecx, 0x101000             ; dwDesiredAccess
call OpenProcess
```
`0x101000 = SYNCHRONIZE (0x100000) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000)`.

This mask permits exactly two operations, and **nothing else**:
- `WaitForSingleObject(handle, timeout)` — process-terminated notification
  (used at 0x14000d498, 0x14000d6c1, 0x140026b26 — the "Client process (PID {}) terminated. Shutting down server." watchdog)
- `GetExitCodeProcess`, `QueryFullProcessImageName`, `ProcessIdToSessionId(pid)`
  is called with the raw PID (does not require the handle).

The mask **does NOT** permit:
- `ReadProcessMemory` / `WriteProcessMemory` (needs `PROCESS_VM_READ 0x10` / `PROCESS_VM_WRITE 0x20`)
- `DuplicateHandle` on cross-process handles (needs `PROCESS_DUP_HANDLE 0x40`)
- `CreateRemoteThread` (needs `PROCESS_CREATE_THREAD 0x2`)
- `VirtualAllocEx`/`VirtualProtectEx` (needs `PROCESS_VM_OPERATION 0x8`)
- Module/thread enumeration (needs `PROCESS_QUERY_INFORMATION 0x400` or a snapshot handle)

No `DuplicateHandle` import exists in MMgr64's IAT at all. No `NtDuplicateObject`
either. `PROCESS_DUP_HANDLE` isn't in the access mask. There is no code path
that could touch client memory.

---

## Q4 — The 6 tables

Verified from `MemoryBridge.log`:
| # | records | stride | bytes | comment |
|---|---:|---:|---:|---|
| 1 | 6,801 | 12 | 80 KB | 3× uint32 — small ID map / cross-index |
| 2 | 36,548 | 12 | 428 KB | 3× uint32 — mid-size ID map |
| 3 | 127,121 | 28 | 3.4 MB | 7× uint32 — mid-large fact table |
| 4 | 18,561 | 116 | 2.1 MB | 29× uint32 — wide row struct |
| 5 | 562,792 | 64 | 34.4 MB | 16× uint32 — dominant / very large |
| 6 | 10,667 | 180 | 1.9 MB | 45× uint32 — widest row struct |

**Structural mapping to Ascension data (probabilistic — no server-side
string labels the tables directly; MMgr64 treats them as opaque `(count, stride)` pairs, all naming lives on the client):**

Ascension's extended DBC set (from Extensions strings, e.g. `ItemAddon.dbc`,
`SpellAddon.dbc`, `GameObjectDisplayInfoAddon.dbc`, `Manastorm.dbc`,
`MysticEnchant.dbc`, `MythicKeystones.dbc`, `MythicAffixes.dbc`,
`HDCreatureDisplayInfo.dbc`, `HDCharacterFacialHairStyles.dbc`, plus every
stock 3.3.5 DBC) totals **~250 dbcs**. The 6 tables are almost certainly
the largest / hottest of these hoisted out-of-process. Best guesses (needs
runtime confirmation via a mock server or view-dump):

- **T1 (6,801 × 12 B)** — likely SkillLineAbility.dbc index shim or
  SpellRank.dbc-scale ID→ID map. 3× uint32 = (skillId, spellId, min/max flags).
- **T2 (36,548 × 12 B)** — SpellItemEnchantment / ItemDisplayInfo hash-index.
- **T3 (127,121 × 28 B)** — Item.dbc / ItemSparse-scale. Ascension's extended
  Item.dbc easily hits 100 k+ due to Manastorm/Mysticbound proc'd items.
  28 B = 7 uint32 = (itemId, displayId, class, subclass, quality, inventoryType, flags).
- **T4 (18,561 × 116 B)** — likely CreatureDisplayInfo or Item full row.
- **T5 (562,792 × 64 B)** — **the big one.** 500 k+ rows, 64 B stride. This is
  the size class of a fully-expanded Spell.dbc effect / SpellItemEnchantment
  join. Ascension's Manastorm system materializes hundreds of thousands of
  spell variants (random-rolled procs, scaling entries). Likely a
  materialized `spell_effect × applicable_item` projection or
  `Manastorm.dbc`-derived table.
- **T6 (10,667 × 180 B)** — 180 B stride is stock Spell.dbc-ish header row
  (~45 uint32 out of ~230 fields — a projection). Ascension has ~10 k core
  spell templates before rank/rune multiplication → this fits.

The tables are populated by the client at startup via a burst of
`CreateTable` + `RecordWrite` (or `RecordPatch`) verbs; the string heaps
via `StringWrite`. Once loaded they are read-only for the session. There is
**no CRC / no checksum / no digest** on any table — MMgr64 does not care
what bytes are inside. The wire format is length-prefixed opaque blobs.

**Not integrity mirrors.** The naming ("Addon" variants, plus stock names)
plus the mask (indexing, projection, predicate query verbs) firmly says
**data-service**, not **verification-service**. An integrity service would
need the client's live memory, hashing primitives, and a per-region baseline
— zero of the three exists here.

---

## Q5 — IsDebuggerPresent / TerminateProcess

`IsDebuggerPresent`: **one call site, 0x140029c87.** That address is deep in
the CRT bootstrap cluster (0x140029XXX contains `entry`, `_seh_filter_exe`,
`__scrt_common_main_seh`, `_initterm`, `atexit`, `_guard_check_icall`, etc.).
The call site is `_seh_filter_exe`'s stock check — MSVC's UEF wrapper skips the
fatal-error MessageBox when a debugger is attached (so the debugger sees the
raise instead). This is compiler-emitted boilerplate; there is no anti-debug
behaviour attached to it (no exit, no evasive branch).

`TerminateProcess`: **zero direct call sites** (raw FF15 scan of .text). The
IAT slot at 0x14002b108 is resolved but unused — imported transitively by CRT
linkage (used by the __fastfail path only when an SEH filter returns
EXCEPTION_EXECUTE_HANDLER, which never happens in MMgr64's normal control
flow). No positive-detect self-kill.

---

## Q6 — Consequence if MMgr64 is killed / spoofed

**Killed:** The client's `MemoryBridgeClient` sees the response event never
signal → `Timed out waiting {} ms for MemoryBridge command {}.` and
`MemoryBridge server exited before {} opened.` If the client was waiting on
critical DBC data (e.g. Spell / Item lookups) at boot, the affected subsystem
halts. `MemoryBridgeClient is not connected.` is a supported string, so at
least top-level code branches on connection state and can emit a graceful
error rather than crash. Post-boot kill during play → per-request timeouts,
progressively failing gameplay features. No integrity-triggered ban:
there is no CMSG_ANTICHEAT_ALERT emitted from MB-death path; that opcode
lives entirely in DivxTac.

**Spoofed:** A mock MMgr64 needs to:
1. Accept `argv = [pid, token]` on its command line and parse via wcstoul.
2. Live in the same Windows session as the client (session-ID compare
   will otherwise reject any process it OpenProcess-checks).
3. Create the 4 named kernel objects with the same name pattern the real
   client expects (naming derived from the object token — need to observe
   Extensions' name-building routine to reproduce byte-for-byte).
4. Publish an explicit DACL via SDDL that grants the client's SID access.
5. Reply to the initial handshake with `{ pid, protocol=3 }` matching.
6. Implement the ~22 RPC verbs, at least to the level of Alloc/Write/Read/
   Free/CreateTable/RecordWrite/RecordRead/UInt32IndexBuild/UInt32IndexLookup/
   ProjectedPredicateQuery. Everything else can stub → `invalid_argument`
   during boot as long as the client's boot sequence doesn't need it.

The **easier path for RaijinLab** is to *not* spoof MMgr64 at all: the port
is already 64-bit, has no 32-bit VA pressure, and can hold all DBCs in the
main runtime. Delete the entire out-of-process bridge and back the 6 tables
by in-process arrays.

---

## Q7 — Integrity claim (definitive NOT)

**Not a client-memory integrity scanner.** Evidence:

1. **Import set** (full list captured, 100+ entries) contains NONE of:
   - `ReadProcessMemory`, `WriteProcessMemory`, `NtReadVirtualMemory`
   - `CryptAcquireContext`, `CryptCreateHash`, `CryptHashData` (any Crypt*)
   - `RtlComputeCrc32`, `BCryptHash`, `A_SHA*`, `MD5*`
   - `VirtualQueryEx`, `VirtualProtectEx`
   - `CreateToolhelp32Snapshot`, `Module32First`, `Thread32First`
   - `EnumProcessModules`, `GetModuleFileNameEx`
   - `NtQueryInformationProcess`, `NtQuerySystemInformation`
   - `DuplicateHandle`, `NtDuplicateObject`
   - `DebugActiveProcess`, `WaitForDebugEvent`
2. **OpenProcess access mask = 0x101000** (SYNCHRONIZE |
   PROCESS_QUERY_LIMITED_INFORMATION). Insufficient by design for any memory
   read or handle-duplication path.
3. **File mappings are page-file backed**
   (`CreateFileMappingW(INVALID_HANDLE_VALUE, ...)`) — private working RAM,
   not a view over any client-owned section.
4. **All observed errors are internal data errors** (out-of-bounds relative
   to MMgr64's own allocations, unknown opcode, deserialize failure). No
   error string references the client's process, memory, modules, or code.
5. **No opcode / no packet** in the RPC surface ever refers to client
   memory. Every command is a self-contained query against MMgr64's own
   in-RAM tables.
6. **No AC opcodes** — nothing at MMgr64 encodes CMSG_ANTICHEAT_ALERT
   (1311) or CMSG_ANTICHEAT_VERSION (1312) or any warden variant. That
   entire opcode family lives in DivxTac + Extensions.
7. **The AC pipeline runs elsewhere.** Extensions.dll has the 14-vector
   anti-debug sink at 0x100b5650 (see 11c) and DivxTac.dll does the
   name-based module/process/window scanning (see 11a). MMgr64 is
   orthogonal.

---

## Breakpoints for a runtime mock/spoof

Focus is on the choke points a fake MMgr64 (or a client-side bridge stub)
would need to satisfy or bypass:

| VA / function | Purpose | Safe-bypass strategy |
|---|---|---|
| 0x1400014f0..0x14000154b | `GetCommandLineW → CommandLineToArgvW → wcstoul` — reads argv[1]=PID, argv[2]=token. | For a mock server, honour these; for a client-side patch to allow no server, patch Extensions' `Refusing to launch MMgr64.exe without a valid object token.` branch to unconditionally treat MB as connected. |
| 0x1400018c2 | `MessageBoxA` fatal box for missing/invalid CLI. | Silence during dev by NOPing the CALL — server exits with `ebx=1` anyway. |
| 0x14000d5ed / 0x140026a24 | The two `OpenProcess(SYNCHRONIZE|PROC_QUERY_LIMITED_INFO, FALSE, clientPID)` calls. | Mock returns a valid pseudo-handle; a debugger can NOP-out session/liveness rejection and force the handshake to proceed even from another session. |
| 0x14000d79d & 0x14000d7b7 (also 0x140026c2d/0x140026c47) | `ProcessIdToSessionId` pair + `cmp` — the session-match check. | To relocate the mock to a different session (e.g. run under a service), patch `je 0x14000d8be` (session-match branch) to unconditional `jmp`. |
| 0x14001fc2d & 0x14001fe2a | `CreateFileMappingW(INVALID_HANDLE_VALUE, sd, PAGE_READWRITE, 0, 0x100000, name)` — request+response mappings. | Naming is derived from the object token — extract token-to-name transform by breaking here and reading the `lpName` arg at [rsp+0x28]. Mock uses same name. |
| 0x14001fd65 & 0x14001fef7 | `MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0x100000)` — mapping views. | Nothing to bypass; observe base addresses stored at `[rdi+0x40]`/`[rdi+0x48]` to attach a debugger view. |
| 0x14001ff9b & 0x140020069 | `CreateEventW(sd, FALSE, FALSE, name)` — request + response events. | Same as mappings — reproduce names from token. |
| 0x140025867 | Main-loop `WaitForSingleObject(requestEvent, timeout)`. | Break here to dump each request frame before dispatch. |
| 0x140025d8f | `SetEvent(responseEvent)` — response commit. | Break to intercept every server reply. |
| 0x140029c87 | Stock `_seh_filter_exe`'s `IsDebuggerPresent`. | Ignore — not anti-debug. |

**None** of these addresses are watched by DivxTac's `DetourMgr` (that
watcher is against Extensions.dll code, not MMgr64.exe — see 11d). A
runtime mock can freely diverge on the wire, since no downstream integrity
check inspects MMgr64's behaviour.

---

## Ground truth vs. Grok's `03_memorybridge.md`

Grok's writeup is correct on the shape. Deltas added by this pass:
- Confirmed **exact OpenProcess access mask = 0x101000** and that it is
  insufficient for any memory operation.
- Confirmed **TerminateProcess has zero direct callers** (Grok listed it in
  the imports without stating usage).
- Confirmed **IsDebuggerPresent is the stock MSVC UEF check**, not a custom
  anti-debug.
- Confirmed **mapping size = 1 MB per view** (0x100000) and **PAGE_READWRITE**.
- Extracted the **22 RPC verbs** from error strings and organized into
  generic-memory + per-table batch verbs.
- Named the **4 kernel object categories** by their string labels.
- Confirmed **no `Global\`/`Local\` prefix** — session-namespace default.
- Confirmed **command 3 is deliberately unassigned** — client's self-test hits it.
- Provided **runtime bypass VAs** for a mock-server or DACL-relaxed test rig.
