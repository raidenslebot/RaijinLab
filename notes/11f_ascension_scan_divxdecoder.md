# 11f — Ascension.exe legacy Warden/Scan.dll heritage + DivxDecoder side-load hypothesis

Purpose: settle two "is this AC-relevant?" questions on the Ascension.exe side of the map.

- (A) Does the stock Blizzard Warden/ScanDLL/AUTH_BANNED_URL machinery still run, or is it dead code superseded by Extensions + DivxTac? Also — is `IsLinuxClient` the stock harmless stub or a repurposed Wine/unlocker probe?
- (B) Is `DivxDecoder.dll` (timestamped 2004, imported by Ascension.exe with 4 exports) a covert loader for `DivxTac.dll` — i.e. a "name-collision" side-load?

Verdict up front: **both subsystems are AC-irrelevant.** Warden/Scan is dead stubs; DivxDecoder is a genuine 2004 codec.

---

## (A) Legacy Blizzard Warden/Scan.dll subsystem

### Strings that exist in Ascension.exe (.rdata)

Grepped `re/string_scan.json` (`Ascension.exe` bucket) and confirmed presence of the classic 3.3.5 Warden/Scan/CDataStore tokens:

- `ScanDLLStart`, `IsScanDLLFinished`, `ScanDLLContinueAnyway`
- `.\Scan.dll`, `.\Scan.dll.new`, `.\ScanDLLGlue.cpp`, `ScanThread`
- `IsLinuxClient`, `IsMacClient`, `IsWindowsClient`
- `AUTH_BANNED_URL`, `LOGIN_UNABLE_TO_DOWNLOAD_MODULE`
- `&sessionKeyHash=`, `?info_hash=`, `SMSG_ADDON_INFO`
- `Usage: ScanDLLStart("VersionURL", "DLLURL")`

Notably **absent**: no `Warden`, `warden`, `SMSG_WARDEN_DATA`, `CMSG_WARDEN_DATA`, `MODULE_LENGTH_NEGATIVE`, `MODULE_CHECKSUM_ERROR` strings anywhere in the binary. Zero. Blizzard's client-side Warden opcode strings are gone from the Ascension.exe .rdata.

### Xrefs — where are the strings actually referenced?

Custom string-xref pass (script at `scratchpad/str_xref_all.py`) — searches every section for the ASCII string, then every section for a 4-byte little-endian pointer to that VA. Results:

| String                          | .text xrefs | .data xrefs                                 |
| ------------------------------- | ----------- | ------------------------------------------- |
| `ScanDLLStart`                  | 0           | 1 (`0xac4050`)                              |
| `IsScanDLLFinished`             | 0           | 1 (`0xac4060`)                              |
| `ScanDLLContinueAnyway`         | 0           | 1 (`0xac4058`, sibling of ScanDLLStart)     |
| `IsLinuxClient`                 | 0           | 2 (`0xac4078`, `0xac85b0`) — two Lua tables |
| `IsMacClient`, `IsWindowsClient`| 0           | same tables                                 |
| `ScanThread`                    | 1 (`0x4e5e49`, as thread-name literal) | — |
| `.\Scan.dll`                    | 6 (`0x4e59f8`..`0x4e5d4c`)              | — |
| `.\Scan.dll.new`                | 4 (`0x4e5c60`..`0x4e5d37`)              | — |
| `AUTH_BANNED_URL`               | 1 (`0x4db3ba`)                          | — |
| `LOGIN_UNABLE_TO_DOWNLOAD_MODULE`| 0                                     | 1 (`0xab95e0`, string-table)                |
| `SMSG_ADDON_INFO`               | 1 (`0x46442f`)                          | — |
| `Usage: ScanDLLStart(...)`      | 1 (`0x4dcd3f`, unreachable arm inside ScanDLLStart) | — |

The `ScanDLL*` and `Is*Client` names live only as **Lua-function-registration table entries**, not as `push offset name` in code — Blizzard's classic `{name_ptr, fn_ptr, ...}` layout.

### The Lua fn table at `.data:0xac4030..`

Dumped as 16-bit stride `{name_ptr, fn_ptr}` pairs (script `scratchpad/dump_region.py`):

```
0xac4030 -> MatrixEntered            fn=0x4dc3a0
0xac4038 -> MatrixRevert             fn=0x4dc420
0xac4040 -> MatrixCommit             fn=0x4dc430
0xac4048 -> GetMatrixCoordinates     fn=0x4dc440
0xac4050 -> ScanDLLStart             fn=0x4dccf0
0xac4058 -> ScanDLLContinueAnyway    fn=0x4dcdf0
0xac4060 -> IsScanDLLFinished        fn=0x4dce00
0xac4068 -> IsWindowsClient          fn=0x4dce40
0xac4070 -> IsMacClient              fn=0x510b90
0xac4078 -> IsLinuxClient            fn=0x510b90   <-- SAME fn body
0xac4080 -> SetRealmSplitState       fn=0x4de250
...
```

Second table (`.data:0xac85a0`) rebinds the three OS predicates identically — `IsWindowsClient=0x4dce40`, `IsMacClient=0x510b90`, `IsLinuxClient=0x510b90`. Same bodies, no divergence.

### Function bodies — are they live or stubbed?

`ScanDLLStart` @ **0x4dccf0**:
```
mov eax, 0
ret
```
Two-instruction null stub. Everything past `ret` (starting at 0x4dccf6) is orphaned bytes — likely the original body left in place after the prologue was overwritten. **The Lua entry point for downloading and loading `Scan.dll` is a no-op.**

`ScanDLLContinueAnyway` @ **0x4dcdf0**:
```
call 0x4e5860        ; reads flag [0xb6b475] / [0xb6b46c]
xor eax, eax
ret                  ; 0 Lua return values
```
Callable, but pushes nothing back to Lua and the callee only touches state bytes.

`IsScanDLLFinished` @ **0x4dce00**:
```
call 0x4e5880        ; -> mov al, byte ptr [0xb6b474]; ret
test al, al
je   short (return nil)
fld1
push L
call 0x84e2a0        ; lua_pushnumber(L, 1.0)
```
Reads state byte `[0xb6b474]`. That byte is set only by the downloader/thread cluster around `0x4e58d0..0x4e5e6x` — which is only invoked by the launcher at `0x4e5a50`, whose only caller path is (was) via `ScanDLLStart`. With `ScanDLLStart` neutered to `mov eax,0; ret`, the state byte is never set → this always returns nil.

`IsWindowsClient` @ **0x4dce40** — pushes `1.0` via `lua_pushnumber`. Windows client says yes.
`IsMacClient` / `IsLinuxClient` @ **0x510b90** — pushes NIL via helper `0x84e280` (which writes the `[0xd4139c]` type constant, no value payload). Both OS predicates return nil.

**`IsLinuxClient` is the stock Blizzard nil-returning stub, sharing its body with `IsMacClient`. It has NOT been repurposed as a cxmplexpack-style Wine/unlocker probe.** The Ascension developers did not touch this fn; whatever Wine/OS-integrity probing exists is done elsewhere (DivxTac `IsDebuggerPresent`/HDD-serial fingerprint, Extensions `PROCESSFILENAME`/`FINDWINDOW` vectors), not by hijacking this Lua export.

### The ScanThread download cluster (dead code)

Around **0x4e58d0..0x4e5e6x** sits the original download/verify/load path — string usage confirms:
- `.\Scan.dll.new` used with a `CreateFileA(..., GENERIC_WRITE=0x40000000, ...)` around `0x4e5c5f` — the download-to-.new pattern.
- `.\Scan.dll` used multiple times for the rename/load path.
- `.\ScanDLLGlue.cpp` used as `__FILE__` in assertion helpers.
- `ScanThread` pushed at `0x4e5e49` as the thread name argument to threading helper `0x774740`, alongside thread proc `0x4e58d0`.

Callsite verification (script `scratchpad/find_callers.py` — scans every `E8` in `.text`):
- `ScanDLLStart` (0x4dccf0): **0 direct E8 callers.**
- `ScanDLLContinueAnyway` (0x4dcdf0): **0 direct E8 callers.**
- `IsScanDLLFinished` (0x4dce00): **0 direct E8 callers.**
- ScanThread proc (0x4e58d0): **0 direct E8 callers.**
- Enclosing launcher fn (prologue at 0x4e5a50, contains the `push 0x4e58d0 / call threading` site): **0 direct E8 callers.**

Only in-binary reference to 0x4e5a50 is at `0x4e5dc9`, which is *inside* the same dead cluster (self-referential retry callback push). No external code path reaches this launcher.

The four Lua-registered entry points are the sole legitimate ingress into this whole ~1.5 KB region, and the top-level one (ScanDLLStart) is a no-op. **The entire Blizzard ScanDLL download-and-load subsystem is unreachable dead code retained as vestigial 3.3.5 lineage.**

### The `AUTH_BANNED_URL` xref

At `0x4db3ba`:
```
lea eax, [edx*4 + 0x9f444c]   ; 0x9f444c is AUTH_BANNED_URL
push eax
push ecx
push 0x9f4438                 ; format string
push 0x9e1ad8                 ; sink
push 3
call 0x81b530
```
That's `lea eax, [table + index*4]` — `AUTH_BANNED_URL` is at index 0 of a DWORD-array of error-message tokens. This is a classic Blizzard login-result enum table; the string is not a live handler binding, just an entry in a string enum used for error formatting.

Same story for `LOGIN_UNABLE_TO_DOWNLOAD_MODULE` — sits at `.data:0xab95e0` in a bank of localization keys.

### SMSG_ADDON_INFO xref

At `0x46442f`:
```
push 0
push 0
push 0x9e81a4        ; "SMSG_ADDON_INFO"
push esi
call <vftable+0x18>
```
This is a packet-name log/telemetry through a CDataStore-like vftable slot. Not a network handler binding — just a diagnostic string.

### `&sessionKeyHash=` / `?info_hash=`

Three xrefs (`0x54fd1e`, `0x5502d5`, `0x55076e`) and one (`0x462a71`). These are the original Blizzard **BitTorrent-based background-downloader** URL params (Blizzard 3.x used a torrent-style patcher). Nothing to do with AC integrity — vestigial patcher plumbing likely also dead, tangential to this analysis.

### Part-A conclusion

The legacy Warden/ScanDLL subsystem in Ascension.exe is **stubbed and unreachable**:

1. Zero `Warden` opcode strings anywhere.
2. `ScanDLLStart` — the sole ingress that would kick off the download/thread/load path — is a two-instruction `mov eax,0; ret` null stub.
3. The download/verify/load code cluster (0x4e58d0..0x4e5e6x) has zero incoming callers via any static reference.
4. `IsScanDLLFinished` state byte is never set, so its return-value contract to Lua is "always nil".
5. `IsLinuxClient` shares its body with `IsMacClient` (both push nil) — plain stock Blizzard behavior, **not** a repurposed unlocker probe.
6. `AUTH_BANNED_URL` / `LOGIN_UNABLE_TO_DOWNLOAD_MODULE` are entries in login-result / localization enum tables, not live handler bindings.
7. `SMSG_ADDON_INFO` is used once as a diagnostic string, not as a network handler binding.

Client-integrity has been fully migrated off the Blizzard Warden client and onto:
- **Extensions.dll**: the 14-vector debug-detection sink `FUN_100b5650 @ 0x100b5650` (per ground truth), which emits `SMSG_WARDEN_DATA`/`CMSG_WARDEN_DATA`/`CMSG_ANTICHEAT_ALERT`/`CMSG_ANTICHEAT_VERSION`.
- **DivxTac.dll**: managed name-based `DetectHackProcesses`/`DetectHackModules`/`DetectHackTitles`/`DetectDebugger` loop, opcode 1311/1312 with magic 0xDEADBABE (per 11a).

**Integrity relevance: NO.** The Warden/Scan.dll heritage in Ascension.exe is dead stock code — no scan, no hash, no download. RaijinLab does not need to model or bypass this subsystem.

---

## (B) DivxDecoder.dll side-load hypothesis

Hypothesis: `DivxDecoder.dll` (imported by Ascension.exe, timestamped 2004, only 4 exports) is a Trojan / side-loader that pulls in `DivxTac.dll` via `LoadLibrary`. Would explain how DivxTac gets loaded early despite being a "video" DLL and matching name-prefix.

### PE triage

```
Machine:     0x14c (x86)
TimeDateStamp: 0x40299280 = 2004-02-11  (genuine 2004 build)
ImageBase:   0x10000000
Entrypoint RVA: 0x35a21   (well inside .text, standard DllMain)
SizeOfImage: 0x69000

Sections:
  .text    VA=0x1000  VSize=0x3c94c  flags=X R    (NOT writable — clean)
  .rdata   VA=0x3e000 VSize=0x12069  flags=R
  .data    VA=0x51000 VSize=0x15ee0  flags=R W
  .reloc   VA=0x67000 VSize=0x1bf0   flags=R

Exports (exactly the 4 claimed, RVAs into .text):
  InitializeDivxDecoder    RVA=0x1000
  SetOutputFormat          RVA=0x1050
  DivxDecode               RVA=0x11c0
  UnInitializeDivxDecoder  RVA=0x11f0

TLS directory: NONE (no TLS callbacks — no covert pre-DllMain code).

Imports: ONLY KERNEL32.dll (60 fns).
  Notable absences: NO advapi32, NO ntdll, NO user32 statically, NO ws2_32,
                    NO crypt*, NO wininet/winhttp.
  Notable presences: HeapCreate/Alloc/Free/ReAlloc/Destroy,
                     VirtualAlloc/Free (codec working buffers),
                     Tls{Alloc,Free,Get,Set}Value, CRT startup surface,
                     LoadLibraryA (1 IAT slot), GetProcAddress (1 IAT slot),
                     GetModuleHandleA/FileNameA, GetVersionExA, GetCommandLineA.
```

Every one of these is stock MSVC 6 CRT startup / ANSI-locale runtime / video codec working buffer.

**Missing entirely** from imports (would be needed for a real injector / side-loader):
- `WriteProcessMemory`, `CreateRemoteThread`, `OpenProcess` (no remote-thread injection)
- `NtCreateThreadEx`, `RtlAdjustPrivilege` (no ntdll usage of any kind)
- `CreateProcessA/W` (no child process spawning)
- `SetWindowsHookExA/W` (no hook installation)
- Any crypto/hash APIs

### Section characteristics

`.text` is `X R` (executable + readable) — **NOT writable**. Not the pattern of a self-modifying loader. `.data` is `R W` — not executable. Standard segmentation.

Section sizes are proportionate for a codec: 240 KB of .text, 74 KB .rdata (Divx lookup tables), 88 KB .data (state).

### Every LoadLibraryA and GetProcAddress site in the binary

Full IAT xref (script inlined in `scratchpad/`):

```
IAT VirtualFree     @ 0x1003e040  -> 4 call sites (all in codec paths)
IAT VirtualAlloc    @ 0x1003e044  -> 3 call sites (codec buffer alloc)
IAT GetProcAddress  @ 0x1003e0a4  -> 1 call site  @ 0x10038e51
IAT LoadLibraryA    @ 0x1003e0b8  -> 1 call site  @ 0x1003a6d1
```

Only ONE `LoadLibraryA` call, at `0x1003a6d1`:
```
push 0x1004f860              ; -> "user32.dll"
call dword ptr [0x1003e0b8]  ; LoadLibraryA
mov  edi, eax                ; store user32 handle for GetLastActivePopup path
```
Loads `user32.dll` — the CRT fatal-error MessageBox fallback, so `GetLastActivePopup`/`GetActiveWindow`/`MessageBoxA` can be reached when the CRT terminates the process. Idiomatic MSVC 6 CRT.

Only ONE `GetProcAddress` call, at `0x10038e51`:
```
push 0x1004f728              ; -> "IsProcessorFeaturePresent"
push eax                     ; kernel32 handle
call dword ptr [0x1003e0a4]  ; GetProcAddress
```
Lazy-binds `IsProcessorFeaturePresent` from kernel32 — MSVC 6 security-cookie / OS-feature-probe boilerplate.

**Zero `LoadLibrary("DivxTac...")`, zero references to any `DivxTac`, `Extensions`, `MMgr64`, or Ascension.exe string. Full string-scan of the binary turned up 819 strings total, only 11 matched even the loose keyword set `{divx, tac, load, dll, inject, anticheat, warden, hack}`, and every one is either `DivxDecoder.dll` itself, one of its 3 export names, or CRT startup boilerplate (`user32.dll`, `LoadLibraryA`, `GetLastActivePopup`, `GetActiveWindow`, `GetACP`, `KERNEL32.dll`, `TerminateProcess`, `GetModuleHandleA`, `GetModuleFileNameA`, `VirtualAlloc`, `GetProcAddress`).**

### DllMain

Entry `0x10035a21`:
```
push ebp; mov ebp, esp
push ebx; mov ebx, [hDll]
push esi; mov esi, [fdwReason]
push edi; mov edi, [lpReserved]
test esi, esi     ; PROCESS_ATTACH?
je   ...
cmp  esi, 1       ; THREAD_ATTACH?
je   ...
cmp  esi, 2       ; THREAD_DETACH?
```
Textbook DllMain. No pre-DllMain TLS callback exists (TLS directory absent).

### Exports

All four exports start with normal stack-frame prologues immediately, no obfuscation, no immediate calls into loader code:

```
InitializeDivxDecoder   @ 0x10001000   sub esp,0x14; xor eax,eax; mov edx,[esp+0x18] ; ...
SetOutputFormat         @ 0x10001050   push ebx; push ebp; mov ebp,[esp+0x10]; ...
DivxDecode              @ 0x100011c0   mov eax,[esp+0xc]; mov edx,[esp+0x4]; mov ecx,[esp+0x8]; ...
UnInitializeDivxDecoder @ 0x100011f0   push esi; mov esi,[esp+0x8]; push 0; push 0; ...
```

`DivxDecode` matches the classic Divx4/5 SDK signature `int DivxDecode(void *ctx, void *inFrame, void *outFrame, ...)`.

### Part-B conclusion

`DivxDecoder.dll` is a **genuine 2004-vintage DivX SDK codec** compiled with MSVC 6, imported by Ascension.exe because the client shell inherits Blizzard's video-cinematic decode pipeline (the `.avi` intros played through the `bink/divx` codec surface).

The name-prefix collision with `DivxTac.dll` is **just naming camouflage** on DivxTac's side — DivxTac is a mixed-mode C++/CLI DLL (managed .NET assembly + native shim) whose author picked a "boring codec-helper" prefix to reduce visual salience, but there is no runtime relationship between the two:

- `DivxDecoder.dll` never loads or references `DivxTac.dll`.
- `DivxDecoder.dll` never references `Extensions.dll`, `MMgr64.exe`, or any AC string.
- It has no writable code section, no TLS callbacks, no injector-shaped imports.
- Only one `LoadLibraryA` (for `user32.dll`, CRT fatal-error path) and one `GetProcAddress` (for `IsProcessorFeaturePresent`, CRT).

**Integrity relevance: NO.** DivxDecoder.dll is not a covert loader, not a scan module, not a hash/checksum vector. It is a real video codec. Ignore it for RaijinLab AC modeling.

---

## Summary — what to hand back to the AC map

| Question | Answer | Ground truth |
| --- | --- | --- |
| Is Ascension.exe's Warden/Scan.dll subsystem live? | **No — dead stubs.** `ScanDLLStart` = `mov eax,0; ret`; download cluster has zero callers; zero `Warden` opcode strings. | Superseded by Extensions.dll 14-vector sink + DivxTac managed AC. |
| Is `IsLinuxClient` a cxmplexpack unlocker probe? | **No — stock Blizzard nil stub.** Shares fn body with `IsMacClient` at `0x510b90`; both push nil via `lua_push*` helper `0x84e280`. | Wine/OS-integrity probing (if any) happens in DivxTac (HDD serial, IsDebuggerPresent) and Extensions (PROCESSFILENAME/FINDWINDOW vectors), not here. |
| Is `DivxDecoder.dll` a side-loader for `DivxTac.dll`? | **No — real 2004 DivX codec.** No writable .text, no TLS callbacks, only KERNEL32 imports, single `LoadLibraryA("user32.dll")` for CRT MsgBox, no reference to `DivxTac` anywhere. | Name prefix collision only. DivxTac is loaded by Ascension.exe directly (or via its C++/CLI mixed-mode fixup), independent of DivxDecoder. |

## Breakpoints (only for safe bypass, not required to neutralize since already dead)

None required. Both subsystems inspected in this note are inert.

Reference-only anchors (for confirming inertness at runtime, e.g. under a debugger):
- `Ascension.exe!0x4dccf0` — `ScanDLLStart` entry. Read `mov eax, 0; ret`. If those two bytes are not `B8 00 00 00 00 C3`, the stub was patched.
- `Ascension.exe!0x510b90` — `IsMacClient`/`IsLinuxClient` shared body. Read `push ebp; mov ebp,esp; mov eax,[ebp+8]; push eax; call 0x84e280`. If diverged, someone repurposed the stub.
- `DivxDecoder.dll!0x1003a6d1` — sole `LoadLibraryA` call site. Its argument at `[esp]` must resolve to `"user32.dll"`. If it ever resolves to `DivxTac.dll` / `Extensions.dll` / anything AC-shaped, the hypothesis flips.

## Open questions (deferred, not blocking RaijinLab)

- The Blizzard BitTorrent-patcher tokens `&sessionKeyHash=` / `?info_hash=` at `0x54fd1e`, `0x5502d5`, `0x55076e`, `0x462a71` — likely also dead stock code (custom launcher supersedes it), but not audited in this note.
- Table at `.data:0xac85a0` re-registers `IsWindowsClient`/`IsMacClient`/`IsLinuxClient` a second time. Determine which caller registers that second table (may be Glue vs. World state divergence) — not integrity-relevant but worth noting for a full Lua-fn-registration map.
