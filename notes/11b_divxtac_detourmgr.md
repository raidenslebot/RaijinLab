# DivxTac DetourMgr / ManagedDetourMgr / GlobalOffsets — Watch Map

**Sub-agent:** Claude (Opus 4.7)
**Binaries:** `re/dumps/DivxTac.dll` (x86 C++/CLI mixed, image base `0x10000000`)
**Sources read:**
- `re/dnspy_out/DivxTac/DetourMgr.cs`
- `re/dnspy_out/DivxTac/ManagedDetourMgrlockRef.cs`
- `re/dnspy_out/DivxTac/-Module-.cs` (grepped for `DetourMgr`, `FunctionMap`, `ManagedDetourMgr`, `_lockRef`)
- `re/dnspy_out/DivxTac/std/unique_ptr-DetourMgr,std.cs`
- `re/dnspy_out/DivxTac/phmap/flat_hash_map-enum GlobalOffsets,unsigned char -,phmap.cs`
- `re/ghidra_out/DivxTac.dll.symbols.txt` (grepped `DetourMgr`, `Detour`, `GlobalOffsets`)
- `re/ghidra_out/DivxTac.dll.decompiled.c` (all matches shown below)
- Full dnSpy re-dump into scratchpad `divxtac_full/DivxTac/`

---

## Headline

**DetourMgr / ManagedDetourMgr in the current DivxTac.dll is DEAD/STUB CODE.** The `DetourMgr` struct is empty (no members, no methods). The `ManagedDetourMgr::FunctionMap` (`phmap::flat_hash_map<GlobalOffsets, unsigned char*>`) is initialised to `EmptyGroup` with size=0, capacity=0, and is NEVER inserted into and NEVER read anywhere in the binary. `ManagedDetourMgrlockRef._lockRef` survives only as a general-purpose monitor object repurposed by `BannedProccesses.Set{Proccess,Modules,WindowTitles}` for thread-safety, not for detour detection. No client-function VAs are watched. No prologue-snapshot / memcmp / byte-compare / `ReadProcessMemory` / address-equality check ever runs.

Confidence: **high** — exhaustive grep of managed C# and Ghidra native symbols.

---

## (1) `enum GlobalOffsets` members

**None recoverable, and none are populated at runtime.**

- Only appearance of `GlobalOffsets` in dnSpy metadata is as a **template type parameter** of the flat_hash_map, mangled as `W4GlobalOffsets@@` (MSVC mangling: `W4` = named enum). It has **no .NET metadata type row**, because it is a native C++ enum used only through mixed-mode C++/CLI template instantiation — the enum body lives in a native `.h` that was never emitted to IL metadata.
- The dnSpy full dump (`divxtac_full/DivxTac/`) produced **no** `enum GlobalOffsets {...}` file. The only file whose name mentions it is the empty templated struct `phmap/flat_hash_map-enum GlobalOffsets,unsigned char -,phmap.cs`:
  ```csharp
  namespace phmap {
      [NativeCppClass]
      internal struct flat_hash_map<enum GlobalOffsets, unsigned char *, ...> { }
  }
  ```
- `FunctionMap$initializer$` (at `0x10001028`, symbol `??__E?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@…`) does exactly this and nothing else:
  ```csharp
  <Module>.?FunctionMap@ManagedDetourMgr@@… = <Module>.phmap.priv.EmptyGroup();
  *((ref FunctionMap) + 4)  = 0;   // size
  *((ref FunctionMap) + 8)  = 0;   // capacity
  *((ref FunctionMap) + 12) = 0;   // growth_left / control
  *((ref FunctionMap) + 20) = 0;   // slot array
  <Module>._atexit_m(ldftn(??__F?FunctionMap@…));   // register dtor
  ```
- There is **no** other reference to `FunctionMap` anywhere in `-Module-.cs` (all 11 hits are the field decl, the ctor, the atexit dtor, and the destructor). Exhaustive grep across the entire `dnspy_out/DivxTac/` tree returns exactly one file matching `FunctionMap` — the module file above. No `emplace`, `insert`, `try_emplace`, `operator[]`, `find`, or iteration on the map exists.
- Ghidra symbols for the entire DetourMgr class = **exactly four**:
  ```
  0x1000100c  DetourMgr::Instance    unique_ptr initializer  ($initializer$)
  0x10001028  ManagedDetourMgr::FunctionMap initializer  ($initializer$)
  0x100085a0  DetourMgr::Instance    atexit destructor
  0x10008654  ManagedDetourMgr::FunctionMap atexit destructor
  ```
  No `Register`, `Install`, `Check`, `Verify`, `Get`, `Contains`, `Detour` member. No accessor.

**Verdict:** the enum values would live in native C++ headers that the current build never emits code for; there is nothing to populate the map with and nothing to look up. The map is a placeholder from an earlier design / abandoned feature.

---

## (2) HOW does DetourMgr decide something is detoured?

**It does not.** There is no mechanism.

Searched for every plausible check pattern in the entire binary:

| Pattern | Presence in DivxTac.dll |
|---|---|
| `ReadProcessMemory` import | **absent** (confirmed by `imports_xref.txt`; already established in `raijinlab_ac_architecture.md` and 11a note) |
| `Crypt*` / `RtlComputeCrc32` / hashing | **absent** (already established) |
| `VirtualProtect` | **absent** |
| `memcmp` / `RtlCompareMemory` (byte compare) | not present in any DetourMgr code path — DetourMgr has no code paths |
| Prologue snapshot on init | none — `Instance$initializer$` only constructs a 4-byte `DetourMgr*` with `<Module>.new(4U)` and stores it in the unique_ptr; `FunctionMap$initializer$` only zero-inits the map header |
| Address-equality check (`fn == FunctionMap[offset]`) | none — the map is empty and never read |
| "JMP present?" (`*(byte*)fn == 0xE9`) | none |

The struct definition literally is:
```csharp
[NativeCppClass]
internal struct DetourMgr { }        // ← empty, zero members
```
and the singleton:
```csharp
internal static unique_ptr<DetourMgr,std::default_delete<DetourMgr>> Instance@DetourMgr;
```
`unique_ptr::delete(Instance, 4U)` at DLL unload confirms the pointed-to object is 4 bytes total.

**Mechanism: none. The subsystem is inert.**

---

## (3) Is DetourMgr checked on the 120 s cycle, a separate timer, or once at init?

**Never checked.** No caller exists.

`AntiCheatThreadLoop` (see 11a note) is:
```
DetectHackProcesses → Sleep 60s → DetectHackModules → Sleep 60s
    → DetectHackTitles → DetectDebugger → loop
```
None of `DetectHackProcesses`, `DetectHackModules`, `DetectHackTitles`, `DetectDebugger`, `AnticheatInitializeHandler`, `AnticheatBannedProcessListHandler`, or any other DivxTac function references `?FunctionMap@ManagedDetourMgr@@…` or `?Instance@DetourMgr@@…`. Grep across `-Module-.cs` finds only the four ctor/dtor sites. The Ghidra symbol table confirms no other function bears a `DetourMgr` symbol.

The **only** runtime interactions with these singletons are:
- CRT static-init: run the two `$initializer$` methods at DLL_PROCESS_ATTACH (registered by `<CrtImplementationDetails>::LanguageSupport`).
- CRT teardown: call the two `atexit` destructors at DLL_PROCESS_DETACH.

Between attach and detach, nothing reads or writes either object.

`ManagedDetourMgrlockRef._lockRef` is a `new ManagedDetourMgrlockRef()` static field (Token `0x04000090`, RID 144). It is used at `-Module-.cs` lines 2676, 2709, 2743 — inside `BannedProccesses.SetProccess`, `SetModules`, `SetWindowTitles` — as the argument to `new lock(...)` (a plain monitor). This is name-inherited from the abandoned DetourMgr subsystem being retasked as the banned-list lock; it has no detection logic.

---

## (4) INTEGRITY CLAIM — does DetourMgr read Extensions.dll `.text` bytes?

**NO.** Explicit evidence:

- `DetourMgr` has **zero methods** (see (2)); it cannot read anything.
- `ManagedDetourMgr::FunctionMap` is **never dereferenced** (see (1)); no lookups → no addresses to compare.
- DivxTac.dll's full import table (per `imports_xref.txt` and 11a ground-truth) contains **no** `ReadProcessMemory`, no `NtReadVirtualMemory`, no `GetModuleHandle` chained to a `.text` walk, no hashing API. The only unusual reads are `DeviceIoControl` for SMART/STORAGE IOCTLs (HDD-serial fetch in `MasterHardDiskSerial`), `IsDebuggerPresent`, `GetProcAddress`, `GetVersionEx`. None are attached to any DetourMgr caller because there are no DetourMgr callers.
- No string constant referencing `Extensions.dll`, `.text`, `_text`, or a byte-window size appears in DivxTac.dll (confirmed by 11a survey; no such string appears in the ctor/dtor sites either).

**Extensions .text integrity is NOT enforced from DivxTac.dll.** The 14 anti-debug callers of the violation sink `Extensions!FUN_100b5650 @ 0x100b5650` live entirely inside Extensions.dll and are behavioural (IsDebuggerPresent / NtGlobalFlag / DR-register / RDTSC / hardware-breakpoint) — see the DBG_* enum list in ground-truth. They do not read their own `.text`. DetourMgr does not augment them.

---

## Consequence for RaijinLab hooking

**No client function is on a DetourMgr watchlist.** The `phmap<GlobalOffsets, unsigned char*>` scaffold, had it been populated, would have listed exact `Ascension.exe`/`Extensions.dll` VAs whose prologues DivxTac would sample. Since the map is empty and never queried, RaijinLab is free to detour arbitrary client functions **from DivxTac's perspective**.

Constraints that remain (from other subsystems, per 11a and ground-truth):
- Do not trip the 14 anti-debug vectors inside `Extensions.dll` (they run independently, unrelated to DetourMgr).
- Do not load a module whose lowercased basename + `.dll` matches the server-pushed banned-module list (`BannedProccessesManaged` name match; opcode 35 delivers the list).
- Do not create a process/window whose lowercased name/title matches the banned-process/title lists.
- Do not import `Extensions.dll` under a name flagged by the banned-modules list (address-neutral; name-based only).

**Green light to detour, for example:** the game's frame-tick, network send/recv, spellcast/movement handlers, Lua stubs, CDataStore accessors — none of these are in a DetourMgr map because there is no DetourMgr map.

---

## Breakpoints (x32dbg)

All targets are in `DivxTac.dll` (base `0x10000000`, ASLR — rebase). VAs listed are as-mapped in the file.

| BP | VA (file) | Purpose | What to expect |
|---|---|---|---|
| `bp DivxTac.dll+0x1028` | `0x10001028` | `ManagedDetourMgr::FunctionMap$initializer$` entry — fires **once** at DLL_PROCESS_ATTACH from the CRT init chain | Should hit exactly once during DivxTac load, then never again for the process lifetime. If it hits twice, the DLL was reloaded. |
| `bp DivxTac.dll+0x100c` | `0x1000100c` | `DetourMgr::Instance$initializer$` entry — the `new(4U)` for the singleton | Hits once, alongside the above; step over the `new` and observe the returned 4-byte block is never written after init. |
| `bp DivxTac.dll+0x85a0` | `0x100085a0` | `DetourMgr::Instance` atexit destructor | Expected to fire only at DLL_PROCESS_DETACH. Between init and this, no member call on the singleton should ever happen. |
| `bp DivxTac.dll+0x8654` | `0x10008654` | `ManagedDetourMgr::FunctionMap` atexit destructor | Same as above — process-exit only. |
| Data BP on `?FunctionMap@ManagedDetourMgr@@…` (the map header, located by the address stored at the init site) | RW-4-byte on `map_ptr + 0`, `+4`, `+8`, `+12`, `+20` | Confirm the map is never modified after init | If nothing fires between DLL load and DLL unload, the map is provably inert on the live process (empirical companion to the static grep). |
| No "comparison call site" BP applicable | — | There is no comparison call site to breakpoint. | If a future DivxTac update wires this up, it will show as new callers to `?FunctionMap@…` — an appropriate diff-check for RaijinLab CI is to watch that symbol's xref count. |

### Safe-bypass strategy

Because the subsystem is inert, **no bypass is required**. The correct action for RaijinLab is:

1. On every DivxTac update, re-run `grep -c "FunctionMap\|Instance@DetourMgr" DivxTac.dll.decompiled.c` and re-run the Ghidra symbol scan for `DetourMgr::` methods; both must remain at the current values (4 refs, 4 symbols) — an increase is the signal that DetourMgr has been armed and this analysis must be redone.
2. If it becomes armed, the map's post-init contents will enumerate the exact VAs to leave alone; RaijinLab can drop equivalent trampolines at `+5` (past the standard 5-byte prologue) or use Detours-style "safe" landing pads so the prologue-byte snapshot still matches. But this contingency does not apply to the current build.

---

## Evidence appendix (raw)

Ghidra symbols matching `DetourMgr` (complete):
```
FUNC 0x1000100c ?A0x347d919e.??__E?Instance@DetourMgr@@2V?$unique_ptr@…    (init)
FUNC 0x10001028 ?A0x347d919e.??__E?FunctionMap@ManagedDetourMgr@@0…        (init)
FUNC 0x100085a0 ?A0x347d919e.??__F?Instance@DetourMgr@@…                   (dtor)
FUNC 0x10008654 ?A0x347d919e.??__F?FunctionMap@ManagedDetourMgr@@…         (dtor)
```

All references to `FunctionMap|Instance@DetourMgr|ManagedDetourMgr` in `DivxTac.dll.decompiled.c` (complete):
```
line   2:  header comment for Instance init @ 0x1000100c   (body: <decompile failed>, __clrcall)
line   5:  header comment for FunctionMap init @ 0x10001028 (body: <decompile failed>, __clrcall)
line 1280: header comment for Instance dtor @ 0x100085a0
line 1286: header comment for FunctionMap dtor @ 0x10008654
```
No function *body* references them.

`DetourMgr.cs` full contents:
```csharp
[NativeCppClass]
internal struct DetourMgr { }
```

`ManagedDetourMgrlockRef.cs` full contents:
```csharp
internal class ManagedDetourMgrlockRef {
    public static ManagedDetourMgrlockRef _lockRef = new ManagedDetourMgrlockRef();
}
```

Consumers of `lockRef._lockRef` (complete): `BannedProccesses.SetProccess` (2676), `BannedProccesses.SetModules` (2709), `BannedProccesses.SetWindowTitles` (2743). All three use it as `new @lock(lockRef._lockRef)` — plain monitor for banned-list mutation. None involve DetourMgr semantics.
