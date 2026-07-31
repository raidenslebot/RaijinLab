# 13 — RaijinLab Runtime AC Evasion Strategy

**Scope:** loadable in-process runtime (`RaijinLabRuntime.dll`) on live Ascension.exe.
**Basis:** verified AC map from notes 11a-11f, ext-antidebug-vectors JSON, opcode table, VirtualProtect callsite classification, and MMgr64 protocol trace.
**Verdict style:** every claim is grounded on a specific upstream finding. Novel guidance is called out as *inference* when it extrapolates.

---

## 1. Ground rules — what integrity checks EXIST vs what DON'T

### DEFINITIVELY DO NOT EXIST (verified by exhaustive import + body scan)

| Check | Where it could have lived | Verified absent |
|---|---|---|
| `.text` byte hashing / CRC / memcmp of any module | DivxTac, MMgr64, Extensions AC sink cluster | DivxTac: no crypto/RPM imports (11a §7). MMgr64: no crypto/RPM/hashing imports, OpenProcess mask 0x101000 is insufficient for RPM (11e). Extensions FUN_100b5650 + 14 vectors + FUN_10a3dc20: **no** memcmp/CRC in the reachable body (11c). |
| DetourMgr / inline-hook prologue verification | DivxTac `DetourMgr` + `ManagedDetourMgr::FunctionMap` | Map is initialised **empty** at DLL_PROCESS_ATTACH and **never inserted into or read** anywhere in the binary (11b). Zero client functions are watched. |
| Cross-process memory reading | MMgr64 | OpenProcess mask lacks `PROCESS_VM_READ`; no `ReadProcessMemory` imported at all (11e). |
| Legacy Warden challenge/response | Ascension.exe Scan.dll cluster | `ScanDLLStart` is a `mov eax,0; ret` null stub, download cluster has zero callers, no Warden opcode strings (11f). SMSG_WARDEN_DATA (742) / CMSG_WARDEN_DATA (743) still exist in opcode table but no live handler emits them from DivxTac; Extensions has the strings but no active send path was found. |
| Second-stage AC loader via DivxDecoder side-load | DivxDecoder.dll | Sole `LoadLibraryA` call is for `user32.dll` on CRT MessageBox path (11f). |
| Self-decrypt / self-patch of Extensions `.text` | Extensions VirtualProtect callsites | All 4 VP sites classified: 2 belong to a ScopedProtect ctor/dtor pair used by the internal hook-installer library (FUN_10001170, 353 xrefs — this is *Extensions'* own detour installer, not a self-integrity check), 2 build a trampoline stub on freshly-allocated RWX memory. **No** post-write hash. |
| DivxTac self-check | DivxTac itself | Empty DetourMgr, no crypto imports, no re-read of its own body. Any of the 10 patch sites in 11a can be tampered without alarm. |
| IAT integrity check in DivxTac | DivxTac IAT | Not present — IAT hook of `IsDebuggerPresent` / `DeviceIoControl` is safe (11a §7). |

### DEFINITIVELY DO EXIST (behavioural, not integrity)

| Check | Owner | Trigger surface |
|---|---|---|
| PEB.BeingDebugged | Extensions vector ID=1 (BEINGDEBUGGEDPEB) + DivxTac DetectDebugger via `IsDebuggerPresent()` | Direct `fs:[0x30]+2` read in Extensions; kernel32 export in DivxTac (11a §3, 11c). |
| NtGlobalFlag | Extensions vector ID=4 (NTGLOBALFLAGPEB) | Direct PEB read. |
| CheckRemoteDebuggerPresent | Extensions vector ID=2 | IAT import. |
| NtQueryInformationProcess (ProcessDebugPort/Object/Flags) | Extensions vector ID=5 | GetProcAddress-resolved (largest vector body, 1488B). |
| GetThreadContext DR0-DR7 | Extensions vector ID=0xB (HARDWAREDEBUGREGISTERS) | GetThreadContext import. |
| FindWindowW against debugger class allowlist | Extensions vector ID=6 (two callers — small class check + multi-class scan) | Verified FindWindowW imports. |
| INT 0x2D | Extensions vector ID=0x14 (INT2D) | Direct `CD 2D` opcode @ 0x100b6ec0. |
| SEH/trap-flag/prefix-hop tricks | Extensions vectors 12/16/17/18/19 (MOVSS, CLOSEHANDLEEXCEPTION, SINGLESTEPEXCEPTION, INT3CC, PREFIXHOP) | Structured-exception probes. |
| Banned-process/module/window-title name match | DivxTac `DetectHack{Processes,Modules,Titles}` | Managed `List<string>.Contains` against server-driven banned list. Lists are empty until server sends opcode 35 (11a §6). |
| HDD serial reporting (HWID) | DivxTac `AnticheatInitializeHandler` (server opcode 14) → CMSG_ANTICHEAT_VERSION (1312) subtype 4 | SMART_GET_VERSION / SMART_RCV_DRIVE_DATA / STORAGE_QUERY_PROPERTY on `\\.\PhysicalDrive0` (11a §4). |

### Headline

**RaijinLab has no `.text` integrity gate to defeat.** The entire AC surface that survives is behavioural (debugger presence) + name-based (module/process/window enumeration) + HWID reporting. Every check is bypassable with either input-side sanitation (attach after login, no HW BPs, spoof PEB, don't publish a debugger window class) or output-side muting (single indirect-call redirect at Ascension.exe 0x0047B0A0 for wire suppression). No hash to preimage.

---

## 2. Module-load evasion — beat DivxTac's `ModuleName.ToLower()` scan

### The threat, precisely

DivxTac `DetectHackModules` (11a §2) iterates `Process.GetCurrentProcess().Modules` on a 120-second outer cadence with 50 ms per-item throttle, lowercases `ProcessModule.ModuleName`, and calls `List<string>.Contains(banned)`. The banned list is:
- **Empty at load time** — it does not populate until the *server* sends opcode 35 (CMSG_ANTICHEAT_BANNED_PROCESS_LIST). Before opcode 35 arrives, `DetectHackModules` is a no-op regardless of what you load.
- Populated **case-normalized to `name.dll`** — matching is exact case-insensitive equality on the last path component only (verified 11a §2, `BannedProccessesManaged.cs` L133-156).

So DivxTac only catches you if (a) the server has pushed your DLL's name onto the banned list, and (b) the module is enumerable via .NET `Process.Modules` (which reflects the Win32 loader's PEB `Ldr.InMemoryOrderModuleList`).

### Options, ranked by (detectability × cost)

| # | Technique | Detectability by DivxTac name scan | Detectability by *anything else* observed | Implementation cost | Notes |
|---|---|---|---|---|---|
| **1** | **Manual-map (no PEB entry)** | **None.** Module is not in `Ldr` lists → `Process.Modules` never enumerates it → banned-name comparison has nothing to compare. | None from any verified check. Extensions vector 10 (PROCESSFILENAME string exists but *no active caller* per the vector classification JSON — id=10 is one of the 7 IDs with no live caller in this build). No module-hash walk anywhere. | Medium — need PE loader (section map + reloc fixup + import resolve + TLS callbacks + exception directory registration for x86 SEH). Public reference implementations exist (Stephen Fewer ReflectiveLoader as base). | **Recommended** for shipping stealth. Even if a future DivxTac build re-arms `DetectHackModules`, manual-mapped code is invisible to it. |
| **2** | **Random filename + `LoadLibraryW` from disk** | Low, but not zero. Random name defeats the string compare *today*. But server can push a substring-match (grep the loop — it uses `.Contains` on `List<string>`, i.e. exact-equality only. So random name **does** defeat current version.) See caveat below. | None. `LoadLibraryW` IAT is imported by Extensions (bp'd in the x32dbg script) but not integrity-checked. | Low — one line change to loader. | Fragile: any future flip of `DetectHackModules` from `List<string>.Contains` to `text.Contains(banned)` (as `DetectHackProcesses` / `DetectHackTitles` already do — see 11a note substring vs equality asymmetry) would kill this. |
| **3** | **`ntdll` direct-syscall LoadLibrary equivalent (LdrLoadDll via syscall stub for the userland calls it makes)** | Low. Still results in PEB Ldr entry. Only benefits are: bypasses hooks *on LoadLibraryW* (none observed), and hides from LoadLibraryW breakpoints an analyst might set. Doesn't help against DivxTac's post-facto `Process.Modules` walk. | None observed. | Medium. | **Not worth it in isolation.** Combine with #2 only if you fear a third-party inspector; unnecessary against DivxTac alone. |
| **4** | **Thread hijack — suspend an existing game thread, hijack context to LoadLibraryW/GetModuleHandle/entry, resume** | Low, same as #2 (module still ends up in PEB Ldr). Advantage: no new thread appears in CreateRemoteThread event logs. | None observed (Extensions doesn't hook `Thread32First`). | Medium-high, and fragile against thread state expectations. | Adds nothing over #1 for AC evasion; buys stealth against outside-observer *loader* forensics, not DivxTac. |

**Warning from note 10 §"AC risk":** `LoadLibrary injection is visible to DivxTac module scans. Expect detection until stealth path exists. First goal is functional correctness offline of stealth.` This warning was written before the empty-banned-list finding — in practice, DivxTac **only** detects your DLL if the server pushes its name. The updated recommendation is:

- **Ship v1 with LoadLibrary + random filename (option #2).** Sufficient today because the banned list is server-driven and empty by default; random name defeats exact-equality matching even if a name is ever added. Test-account safe.
- **Ship v2 with manual-map (option #1).** Removes the last drop of dependency on server behaviour. Do this before wide rollout / paid tier / anything that would motivate the server team to push your name.

### Extra hardening (cheap, do both regardless of option chosen)

- **Never export symbols the vendor knows**: no `RaijinLabRuntime`, no `HookMe`, no `WoWCleanup` etc. Ordinal-only exports; keep only `DllMain` and an unnamed thread proc.
- **Strip PE resources & rich header**: `Ascension_Ext_Sink_FUN_100b5650` YARA in-repo already shows how easy static signatures are; don't be the one who ships a rich-header timestamp identifying your build machine.
- **Strip RTTI / typeinfo strings** (`/GR-` in MSVC or link-time strip): `Ascension_ExtendedAnticheatMgr` demonstrates RTTI is a first-class fingerprint surface.

---

## 3. DetourMgr-watched functions — which prologues to avoid

### Verified state of the watchlist

Per note 11b + `divxtac_globaloffsets.json`:

> `ManagedDetourMgr::FunctionMap` is a `phmap::flat_hash_map<GlobalOffsets, unsigned char*>` initialised to `{size=0, capacity=0}` at DLL_PROCESS_ATTACH and **never mutated for the lifetime of the process.** No `insert`, `emplace`, `find`, or `contains` call exists in DivxTac.dll — the map is dead scaffolding.

**Concrete consequence for RaijinLab:** *zero* client function prologues are currently on any DivxTac blacklist. Inline hooks — whether trampolines, JMP rel32, or hot-patch two-byte — into Ascension.exe game functions (`ClickToMove`, `EnumVisibleObjects`, `FrameScript_Execute`, etc.) are undetected by DivxTac.

### But: Extensions.dll itself is the risk surface, not DivxTac

Extensions.dll ships its own `MinHook/Detours-style` installer at `FUN_10001170` (11 — VirtualProtect callsite analysis). It's used from 353 sites — Extensions itself is heavily instrumented. This means:

- **Extensions already lives on top of the game's function prologues.** If you inline-hook a function Extensions has hooked, you may find you're patching an Extensions trampoline instead of the game function — behaviour depends on install ordering.
- Extensions' own hook installer does **not** verify its hook payloads (no post-write hash), so if you install *after* Extensions and re-hook the same target, you'll clobber Extensions' hook. Sometimes that's fine (game works, Extensions loses the hook and probably an anti-cheat feature); sometimes it breaks the game.

### Recommended hook policy (inference from the observed toolkit)

1. **Prefer trampolining further into the function body** rather than the prologue. Use MinHook/Detours to install into an offset that already has 5 clean bytes past any known Extensions trampoline. This is the standard mitigation for "we're the second hook."
2. **Prefer `ExecuteInMainThread`-style thunks over inline hooks** wherever the operation is initiated by your code. Post a job onto the client's frame-tick (via `FrameScript_RegisterFunction` + an addon that fires the callback per frame, or via a hook you install once on the client's per-frame update to drain a lockless queue). This is a zero-hook interaction with the game engine other than the single frame-tick tap.
3. **Never inline-hook the AC binaries themselves.** Any patch to DivxTac / Extensions / MMgr64 should go through IAT redirection or ScopedProtect+patch, not through a general-purpose hook library.
4. **Do not hook Extensions' `FUN_10001170` or the VirtualProtect wrappers** even though it looks tempting to intercept Extensions' hook installs to spy on what it hooks. That's exactly the kind of surface a future AC update will start watching first.

### Setting the tripwire

Per 11b, the CI signal for "DivxTac just armed DetourMgr" is trivially observable:
- `grep -c 'FunctionMap|Instance@DetourMgr' DivxTac.dll.decompiled.c` — expected value **4**. If ever >4, re-triage before shipping.
- Data BP RW-4-byte on `map_ptr+0/+4/+8/+12/+20` in a Frida agent when doing pre-release check: if it fires, dump the `GlobalOffsets` key enum and cross-reference the resolved pointer against your hook set.

---

## 4. Fourteen-vector sink neutralization — pick one strategy

The 14 vectors and their type_ids are enumerated in `ext_antidebug_vectors.json` (BEINGDEBUGGEDPEB=1, NTGLOBALFLAGPEB=4, NTQUERYINFORMATIONPROCESS=5, HARDWAREDEBUGREGISTERS=0xB, FINDWINDOW=6 ×2, INT2D=0x14, plus SEH-based). All 14 direct-call the sink at `Extensions.dll+0xB4A50`.

### Option comparison

| Approach | What you do | Pros | Cons | Verdict |
|---|---|---|---|---|
| **(a) Patch sink prologue** | Poke `C3` at Extensions VA `0x100B5650`. Confirmed sink is `__cdecl`, no return-value dependency in callers, no self-hash (11c). | 1 byte, 1 place, kills all 14 vectors at once and silences opcode 1311 from Extensions. | Sink is in normal `.text` (not `.vm_sec`) — patchable, but if a *future* Extensions self-hash check ever exists, the sink is the highest-value candidate. 11c ruled it out for *this* build; future builds re-verify. Also visible in any casual RWX walk. | **Recommended default for v1.** Cheap, effective, reversible. |
| **(b) Neutralize the sink's send** | NOP the 2-byte `FF D6` at `0x100B5993` (packet-send indirect call). Latch still trips (harmless). | Sink still executes cleanly, so any code that observes sink-called-from-vector-N still sees it; only the wire packet dies. Slightly less signature (2 bytes vs 1 byte patch). | Same integrity considerations as (a); slightly more surgical but no meaningful stealth advantage. | Fine alternative to (a). |
| **(c) Redirect `[0x10BCA0CC]` — the CDataStore-preparer function pointer** | Replace with a stub that returns without sending when opcode ∈ {1311, 1312}. All 5 Extensions emit sites + all 3 DivxTac senders funnel through this pointer (11d, plus Ascension.exe 0x0047B0A0 as the same-role choke). | **Single-point kill for ALL AC opcodes across ALL three AC modules.** Cleanest, most stealthy, minimal footprint. Only writes one `.data` dword, not `.text`. | Slightly more work (write the filter stub, handle the calling convention). Filter must pass non-AC opcodes through unchanged or you kill networking. | **Recommended for v2 / production stealth.** |
| **(d) Hook each of the 14 vectors individually** | 14 `ret`-patches at the vector-caller VAs. | Every vector self-nullifies before it ever calls the sink. No dependence on sink prologue. | 14× the patch surface, 14× the code-integrity risk if a future build starts hashing. | Worst option — high signature, no advantage over (a). |
| **(e) "Just don't trigger anything"** | Ensure inputs to all 14 vectors return "no debugger": PEB.BeingDebugged=0, NtGlobalFlag=0, no HW BPs on DR0-DR7, no `int3` in your loaded code, don't publish a debugger window class, don't attach a debugger. | Zero patches to any AC binary. Fully invisible to any future integrity check. | Requires discipline forever. Cannot use HW BPs during dev. Cannot use IsDebuggerPresent-tripping tools. Any addon that publishes a window with a class in Extensions vector 6's allowlist trips it. | **Recommended as the *foundational layer* under (a) or (c).** Run this way even *with* patches — belt-and-braces. Frida attach-mode already satisfies most of this (per `FRIDA_probe_plan.md`). |

### Composite plan

- **Belt:** Adopt (e) as a project-wide invariant. No HW BPs in shipping runtime, no PEB.BeingDebugged=1 in the game process. Frida used in attach mode only.
- **Braces v1 (dev + early alpha):** Add (a) — 1-byte `C3` at `0x100B5650`. Instant kill switch, easy to remove for regression testing.
- **Braces v2 (production):** Migrate to (c) — indirect-call filter at `[0x10BCA0CC]` (or Ascension.exe `0x0047B0A0`). Single filter, opcode-aware, drops 1311/1312 while passing everything else.

### FindWindow class allowlist

Vector 6 has *two* callers (small class-name check + larger multi-class scan). Extract the exact class-name list from Extensions vector 6 bodies at VAs `0x100B6720`-ish and `0x100B6944`-ish (from `ext_antidebug_vectors.json`) before shipping — that's your allowlist of window classes RaijinLab addon UIs must NOT create. Names to expect (from public WoW-hack analyses): `OLLYDBG`, `WinDbgFrameClass`, `ID`, `Zeta Debugger`, `Rock Debugger`, `ImmunityDebugger`, `x64dbg`, `x32dbg`, `WinDbg`, `ObsidianGUI`, etc.

---

## 5. Network AC — do not touch outgoing 1311/1312

### The trap

CMSG_ANTICHEAT_ALERT (1311) and CMSG_ANTICHEAT_VERSION (1312) are the only two client→server AC opcodes actively emitted. Their **payload shapes are trivial** (three strings for 1311; int32 subtype + string HWID for 1312). It is tempting to intercept and rewrite them.

**Do not.** Rewriting the payload:
- Doesn't change the fact that the packet was **sent**. The server logs "client reported X" as anomaly-suspicious regardless of the string content (silent-1311 with empty strings = "someone patched their client"). Any 1311 in your session is a red flag.
- The 3-string layout is verified by 3 independent emitters (11a §5); the server surely has parsing that validates length prefixes. Malformed rewrites = crash the recv → dropped session → "client is broken" flag.
- Ascension might correlate 1311 sends against server-side heuristics (session length, movement anomalies, warden ping cadence). Even a well-formed spoofed 1311 is a data point that suggests something's up.

### The right rule

**Prevent the trigger, don't rewrite the packet.** From §4 above, adopting strategies (a) or (c) means opcode 1311 never gets constructed. Adopting (e) means it never gets triggered in the first place. The wire is silent — server sees a normal client.

CMSG_ANTICHEAT_VERSION (1312) is fired in response to server opcode 14 (SMSG_ANTICHEAT_INIT). You have two clean choices:
1. **Answer normally with the real HDD serial.** The server expects an answer; not answering may itself flag the session as suspicious after some timeout. The HDD serial is your genuine hardware ID; the server was going to record it regardless of whether you loaded a runtime. Best default.
2. **Neutralize DivxTac's `AnticheatInitializeHandler`** (patch entry to `mov eax, 1; ret` per 11a). This drops the response entirely. Only do this if you also have HWID-spoof plans (see §7) and understand you'll appear as "client didn't answer init handshake" — investigate first whether the server hard-requires the answer within a timeout. In default risk posture: **answer normally**.

### Warden — legacy path

The opcode table (`ascension_ac_opcodes.json`) confirms both SMSG_WARDEN_DATA (742/0x2E6) and CMSG_WARDEN_DATA (743/0x2E7) exist in the client's name table. Extensions.dll references the strings but no active handler was found emitting or receiving them in the current build (11d finding: "zero live Warden code paths"). Legacy Scan.dll load path is dead (11f: `ScanDLLStart` is null-stubbed).

**Recommendation:** do **not** proactively spoof SMSG_WARDEN_DATA. Reasons:
- No live handler was observed; spoofing a response to a message the client can't/won't parse just adds noise.
- If a *future* Ascension build re-arms Warden, spoofing based on today's null-stub is doomed anyway — Warden's memory-scan primitives require real cooperation with the server-provided module (byte-scan/timing responses).
- Instrument for it instead: add a Frida hook on the CDataStore preparer (Ascension `0x0047B0A0`) with an opcode-741..743 filter that logs when Warden traffic reappears. That's your tripwire.

---

## 6. MMgr64 — leave it alone, entirely

Per 11e:

> MMgr64 is a stateless out-of-process shared-memory data service (22 RPC verbs over 4 named kernel objects hosting 6 opaque count/stride tables ~42 MB); it has zero integrity-scanning capability… The RaijinLab port (already 64-bit) can inline these tables and delete MMgr64 entirely without triggering any AC path.

Also per prior finding: **if MB dies the client dies** (session-token + PID-liveness gated).

### The rule

- **Do not** hook, filter, inject into, or query MMgr64.exe. It is not an AC threat.
- **Do not** kill it or interpose a shim between it and Ascension.exe. The client will crash.
- **Do not** replace it with a mock in production. You'd need to reproduce the exact name-transform for CreateFileMappingW/CreateEventW plus the 6 opaque tables. Not worth the effort — the real MMgr64 already does the job and doesn't spy.

**Only exception:** development instrumentation. If you want to understand what a specific game feature is reading from MMgr64, break at `MMgr64+0x25867` (WaitForSingleObject on requestEvent) and `MMgr64+0x25D8F` (SetEvent responseEvent) to log request/response frames. Do this once for research, then remove.

---

## 7. HWID — SMART serial exposure and spoofing options

### What DivxTac sees

Per 11a §4:
- Primary path: `ReadPhysicalDriveInNTUsingSmart` — opens `\\.\PhysicalDrive0` with GENERIC_READ|WRITE, issues `SMART_GET_VERSION` (IOCTL 0x74080) then `SMART_RCV_DRIVE_DATA` (IOCTL 0x7C088) with `SENDCMDINPARAMS.bCommandReg = 0xEC` (ATA IDENTIFY DEVICE) → parses ATA IDENTIFY offsets 10-19 for the serial ASCII.
- Fallback path: `ReadPhysicalDriveInNTWithZeroRights` — opens `\\.\PhysicalDrive0` with zero access, issues `IOCTL_STORAGE_QUERY_PROPERTY` (0x2D1400) → parses `STORAGE_DEVICE_DESCRIPTOR` at offsets +12/+16/+20/+24. `IOCTL_DISK_GET_DRIVE_LAYOUT` (0x70020) is called too but result ignored.
- Preference: ZeroRights first if `IsWindowsVersionOrGreater(5,1,0)`, else SMART.

Serial is sent as a plain string in CMSG_ANTICHEAT_VERSION (1312) subtype 4.

### The persistent-ban risk

If Ascension issues a HWID-linked ban on the collected `\\.\PhysicalDrive0` serial, that ban persists across game reinstalls, Windows reinstalls, and IP changes — but not across physical disk changes.

### Spoofing options

| Approach | Detectability | Cost | Verdict |
|---|---|---|---|
| **A — User-mode IOCTL hook on `DeviceIoControl`** | Low. DivxTac has no IAT integrity check (11a §7). Filter the 4 IOCTLs (0x74080 / 0x7C088 / 0x2D1400 / 0x70020) only when handle path resolves to `\\.\PhysicalDrive0` (use `GetFinalPathNameByHandle` in the hook prelude), rewrite the ATA-IDENTIFY / STORAGE_DEVICE_DESCRIPTOR serial bytes in the output buffer. | Low-medium. ~200 lines. Handles both DivxTac code paths. | **Recommended if HWID spoof is needed at all.** Do NOT install by default — HWID reporting is legitimate on a clean account. Install only *after* a ban lands, in a fresh runtime build. |
| **B — Kernel driver disk-serial spoofer** | None (below user-mode's visibility). | High. Requires signed driver on modern Windows, or DSE-bypass on unsigned. | **Overkill.** Only worth it if user-mode hook is being defeated (which requires AC to also add a kernel driver — not present in this build). |
| **C — Bit-bucket the IOCTL (return zero serial)** | Medium. Server may treat "empty serial" as suspicious, or as "same HWID as every other bit-bucketed client" and permaban a cohort. | Trivial. | **Do not use.** Worse than the real serial in either direction. |
| **D — Neutralize AnticheatInitializeHandler entirely (send no 1312)** | Medium — see §5. Server may flag "no init response." | 1 byte. | Only in combination with A above, and only if server-timeout tolerance is confirmed. |

### Rule of thumb

- **Default posture:** answer HWID honestly. No spoof, no filter. Fresh account = fresh entry in ban table; nothing personal to hide until you're actually banned.
- **After a ban:** ship a build with (A). Rotate the fake serial per-install. Don't reuse.

---

## 8. Discovery risks introduced by Grok's addon side

From note 10 §"Remaining gaps" and the Example-Code integration surface:

| # | Surface | Discovery risk | Mitigation |
|---|---|---|---|
| 1 | **`RaijinLab_Runtime` FrameScript_RegisterFunction name** (note 10) | Any addon or GM query enumerating registered FrameScript functions sees the name. Not currently scanned by DivxTac (name-based scans target modules/processes/window titles, not Lua globals) but is a giant billboard for any future scan or manual GM review. | Rename to something innocuous (`_G` prefix, mimic a common addon like `Bagnon_Update`). Randomize per-build. |
| 2 | **Console thread window / chat message on register success** (note 10) | If the thread ever creates a visible window (e.g. via `AllocConsole`), it publishes a `ConsoleWindowClass` — trivially findable by any FindWindow-style scan (Extensions vector 6). The chat-line print is visible to the server if the print routes through a normal chat send. | Keep the console gated behind a debug build flag. In release, never call `AllocConsole`. Chat messages must use the client-only `ChatFrame_AddMessage` path, not `SendChatMessage`. |
| 3 | **`/rl status` slash command** (note 10) | Server-side chat/slash-command loggers may capture the slash. Any player observing chat sees it. | Rename to something forgettable, or route via addon message channel with an obscure prefix (already filtered by client for prefixes not registered by any addon). |
| 4 | **LoadLibrary from disk with predictable filename** (note 10 "AC risk") | Even if DivxTac's list is empty, casual anti-cheat forum scraping identifies your DLL name. | Random per-install name; ultimately manual-map (§2). |
| 5 | **DLL exports named `RaijinLabRuntime`** (note 10 build artifacts) | Any string-dump of `Process.Modules[i].FileName` in a diagnostic dump identifies you. | Strip exports, use ordinal-only, keep filename generic. |
| 6 | **Object-manager snapshot enumeration frequency** (note 10 "added ObjectManager snapshot") | If snapshot runs every frame and touches every visible object, timing-side-channel could distinguish a snapshot from normal gameplay. Not currently scanned but is the archetype an AC vendor adds first when moving to behavioural detection. | Enumerate opportunistically (only when addon requests fresh data), not on a tight tick. |
| 7 | **In-world position/health descriptor reads** (note 10 gap #2) | Same as #6 — descriptor reads via ClntObjMgrObjectPtr are unwatched today but are the highest-value target for future behavioural AC. | Cache per-frame; don't hammer. |
| 8 | **ClickToMove / MoveTo invocations** (note 10 API surface) | ClickToMove calls originating from off-main-thread would be immediately suspicious. Currently unchecked but is a common trigger in production AC. | Always dispatch through the main-thread queue (see §3 recommendation). |
| 9 | **DLL timestamp / rich header / RTTI** | Static YARA rules (see `ascension_ac_v2.yar`) are already trivially assembled from strings. Vendor could ship a client-side signature check as a future addition. | Sanitize build metadata; strip RTTI. |
| 10 | **IsLinuxClient patch** (note 10 "added IsLinuxClient") | 11f verified `IsLinuxClient` is a nil-return stub. If Grok patches it to return true (Wine/unlocker probe), that's a client-side self-modification that could trip a *future* Extensions self-hash. | Do not patch. If Linux detection is desired, wrap client Wine detection at the OS level, not by patching the client's own predicate. |
| 11 | **Addon file distribution** | The addon is distributed as text files under `Interface/AddOns/` — trivially inspectable. Any GM who looks sees the whole thing. | Assume the addon is public. Move sensitive logic entirely into `RaijinLabRuntime.dll`; addon should be a thin Lua UI. |

---

## 9. Sequenced implementation plan for Grok

### Phase 0 — Functional-first (already in progress per note 10)

- [x] Ship `RaijinLabRuntime.dll` + `RaijinLabLoader.exe`.
- [ ] Complete note 10 gaps: `lua_tostring` / `lua_push*` resolution, live position/health offset verification, EnumVisibleObjects callback convention, name vfunc index.
- [ ] Confirm the runtime works on a test account, log in, unload, no crash. Assume detection is 100% possible during Phase 0 — that's fine, test account is disposable.

### Phase 1 — Behavioural hygiene (belt)

- [ ] Verify runtime with Frida attach-mode instrumentation (`FRIDA_probe_plan.md`). Run the 150-second probe to confirm:
  - H4 (opcode-1311/1312 filter at Ascension `0x006B0970`) does **not** fire during a clean session.
  - H1 (sink hits at Extensions `0x100B5650`) does **not** fire.
  - H5 (LoadLibraryW timeline) shows the runtime loaded but no unexpected extras.
- [ ] Rename `RaijinLab_Runtime` FrameScript export to something innocuous. Move `/rl status` to a hidden addon-message channel.
- [ ] Enforce dev discipline: no HW BPs on DR0-DR7 while the game is running; no `int3`; no ImmunityDebugger-class window.
- [ ] Strip DLL exports (ordinal-only), strip RTTI (`/GR-`), strip rich header, randomize on-disk filename.

### Phase 2 — Braces v1 (single-byte kill switch)

- [ ] From within `RaijinLabRuntime.dll` init: `VirtualProtect(Extensions+0xB4A50, 1, PAGE_EXECUTE_READWRITE, &old)` → write `0xC3` → restore. This is (§4 option a).
- [ ] Log the pre-patch byte value to catch a future Extensions rebuild that moves the sink. Assertion: pre-patch byte must be `0x53` (verified via note 11c `push ebx` prologue).
- [ ] Re-run the Frida probe. Expect: still no 1311 traffic even if a vector fires — confirm by intentionally tripping vector 1 (touch PEB.BeingDebugged=1) in a *separate* test build and verifying no packet.

### Phase 3 — Braces v2 (single-point wire filter)

- [ ] Replace the sink patch with the indirect-call filter at `[Extensions+0x1BCA0CC]` (or the equivalent Ascension.exe `0x0047B0A0` filter, which is broader).
- [ ] The filter is a small stub with two behaviours:
  - If opcode ∈ {1311, 1312}: return without invoking the real preparer.
  - Otherwise: tail-call the real preparer with all args intact.
- [ ] This is the "leave the sink executing, drop the wire" configuration. Fewer patched `.text` bytes, no `.data` inconsistency for a future integrity check to notice.
- [ ] With this in place, revert the sink prologue patch from Phase 2.

### Phase 4 — Manual-map loader

- [ ] Replace `RaijinLabLoader.exe`'s `LoadLibraryW` call with a manual-map implementation. The runtime DLL never touches disk under its real name; the loader reads the DLL bytes into memory, parses the PE headers, allocates virtual memory, applies relocations, resolves imports, invokes TLS callbacks, calls `DllMain(DLL_PROCESS_ATTACH)`.
- [ ] After manual-map, the runtime is invisible to `Process.GetCurrentProcess().Modules` and thus invisible to DivxTac's `DetectHackModules` even if a future banned list ever contains the runtime's original name.
- [ ] Keep the LoadLibrary path in a debug configuration for easier crash-dump symbol resolution.

### Phase 5 — Instrumented telemetry (optional)

- [ ] Ship a persistent Frida shadow that runs the H4 opcode filter as a tripwire: if opcode 1311 or 1312 ever appears on the wire in production, alert the developer. This catches AC updates or bugs in the wire filter before they generate bans.
- [ ] CI check: `grep -c 'FunctionMap|Instance@DetourMgr' DivxTac.dll.decompiled.c` on every Ascension patch day. If != 4, halt release and re-triage.
- [ ] CI check: verify Extensions `0xB4A50` still has prologue byte `0x53` and the 14 caller VAs still direct-call it. If any caller VA has shifted, re-derive the vector map before shipping the next build.

### Phase 6 — HWID spoof (only if a ban is issued)

- [ ] Ship the user-mode `DeviceIoControl` filter (§7 option A) as a separate build variant. Default builds continue to answer HWID honestly.
- [ ] Rotate serials per-install; never reuse a spoofed serial across installations.

---

## Appendix — quick-reference addresses

| Symbol | VA | Purpose | Patch note |
|---|---|---|---|
| Extensions `FUN_100b5650` | `0x100B5650` | 14-vector alarm sink | `0xC3` = kill all. Prologue byte pre-patch = `0x53`. |
| Extensions sink packet-send indirect | `0x100B5993` | The `call esi` that sends 1311 | 2× `0x90` = mute wire but keep body. |
| Extensions latch byte | `0x10BDC24C` | Alert-fired bool | Data poke; not required for functional bypass. |
| Extensions monitor loop entry | `0x10A3DC20` | Parent sweep thread | `0xC3` = nuclear (all 14 vectors silent). |
| Extensions CDataStore-preparer indirect | `[0x10BCA0CC]` | Universal AC wire choke (5 Extensions + 3 DivxTac sites) | Replace pointer with opcode-filter stub. |
| Ascension.exe CDataStore preparer | `0x0047B0A0` | Deeper universal AC wire choke (also catches DivxTac init handshake) | IAT-hook or trampoline; opcode-1311/1312 filter. |
| DivxTac `AntiCheatThreadLoop` | `0x100035BC` | Scan loop | `0xC3` = kill polling. |
| DivxTac `SetMessageHandlers` | `0x100058C8` | Registers server opcode 14/35 handlers | `0xC3` = server never populates banned list ⇒ scan is no-op forever. Cleanest single-BP DivxTac kill. |
| DivxTac `AnticheatInitializeHandler` | `0x10005908` | 1312 HWID responder | `B8 01 00 00 00 C3` = drop init response (only combine with HWID spoof). |
| DivxTac `IsDebuggerPresent` IAT thunk | `0x10008298` | Sole DivxTac debugger probe | IAT hook returning 0. |
| MMgr64 request wait | `0x140025867` | MB main loop | **Do not touch.** Instrument only. |

**End of note 13.**
