# Extensions.dll — Anti-Debug Module Map & Breakpoint Table

**Date:** 2026-07-20  
**Binary:** `Extensions.dll` — sha256 `4e81e711…433b282e` (from `re/dumps/`)  
**Image base (on-disk):** `0x10000000` (ASLR-rebased at runtime — see note)  
**Scope:** Client-side anti-debug/anti-tamper sweep. **14 detection vectors → 1 shared report sink.**

> ⚠️ All VAs below assume the on-disk preferred base `0x10000000`. At runtime the
> DLL is relocated; compute `runtime_va = module_base + (static_va - 0x10000000)`.
> File offsets are stable and usable for static patching.

---

## The one thing that matters: the shared sink

Every one of the 14 anti-debug checks, when it fires, decrypts a small payload
(SSE `movaps`/`xorps` over stacked constants) and calls the **same** function:

```
sub_100b5650(int severity=1, void* decrypted_blob)   ; cdecl, caller cleans 8 bytes
```

- **VA:** `0x100b5650`  **file offset:** `0x000b4a50`
- **Direct callers:** exactly **14** — one per vector (verified). No other callers.
- This is the dedicated violation-report path. It is the single choke point.

### Neutralization options (in order of preference)

| Approach | Action | Effect |
|----------|--------|--------|
| **Static patch** | Write `0xC3` (`ret`) at file offset `0x000b4a50` | All 14 reports become no-ops. Simplest. |
| **Runtime hook** | Detour `sub_100b5650` → immediate return | Same, survives if applied after load. |
| **Gate patch** | Flip each vector's `je <clean>` → `jmp` (14 sites) | Checks still run but never reach payload build. More surgical, 14 edits. |

> ⚠️ **Integrity caveat:** `Extensions.dll .text` is `0xE0000060` = **self-modifying /
> write+execute**, and `DivxTac.dll`/`MMgr64.exe` do module integrity scanning
> (`AntiCheatService.DetectHackModules`, `DetourMgr`). A raw `.text` patch to the
> sink may be detected by those layers. Sequence of work: **map DivxTac/MMgr64
> integrity checks first**, then decide patch vs. hook vs. gate. Do not patch blind.

---

## The 14 detection vectors

Each vector: `<technique> → result in eax/esi → test/cmp → je <clean_path> →
[build+XOR-decrypt payload] → call sub_100b5650 → converge`.

| # | Vector VA (magic build) | Technique | Gate (`je clean`) | Sink call |
|---|------------------------|-----------|-------------------|-----------|
| 1 | `0x100b5b21` | **PEB.BeingDebugged** — manual `[peb+2] & 0xff` | `je 0x100b5cc2` @ `0x100b5b18` (off `0xb4f18`) | `0x100b5cba` |
| 2 | `0x100b5d1f` | **CheckRemoteDebuggerPresent** (GetCurrentProcess→CRDP) | `je 0x100b5ec0` @ `0x100b5d16` (off `0xb5116`) | `0x100b5eb8` |
| 3 | `0x100b5f92` | **FindWindowW** — debugger window-class scan | `je 0x100b615c` @ `0x100b5f88` (off `0xb5388`) | `0x100b6154` |
| 4 | `0x100b6554` | **FindWindowW** — 2nd window scan (obfuscated call) | (near `0x100b653e`) | `0x100b6731` |
| 5 | `0x100b67d7` | **CloseHandle(0xBEEF)** invalid-handle exception trick | (`test esi` @ `0x100b67cc`) | `0x100b6954` |
| 6 | `0x100b6a82` | **GetThreadContext DR0–DR7** hardware-breakpoint scan (`ContextFlags=0x10010`) | `je 0x100b6c3a` @ `0x100b6a78` (off `0xb5e78`) | `0x100b6c32` |
| 7 | `0x100b6ee8` | **`int 0x2d`** kernel-debugger interrupt probe | (exception-based) | `0x100b6ff1` |
| 8 | `0x100b709e` | **`int3` / 0xCC** breakpoint-exception probe | (exception-based) | `0x100b7189` |
| 9 | `0x100b71d6` | **IsDebuggerPresent** (kernel32 API) | (near `0x100b71c4`) | `0x100b72f7` |
| 10 | `0x100b735e` | **`push ss; pop ss; pushfd`** — single-step-after-SS trap | `jne`/`jmp` @ `0x100b7345` | `0x100b74bd` |
| 11 | `0x100b751f` | **PEB.NtGlobalFlag** — `fs:[0x30]→[peb+0x68] & 0x70` | `je 0x100b76c0` @ `0x100b7516` (off `0xb6916`) | `0x100b76b8` |
| 12 | `0x100b79ef` | **NtQueryInformationProcess** (dyn-resolved, `call esi`, info-len `0x18`, `js` check) | `js 0x100b7c81` @ `0x100b79cf` | `0x100b7c79` |
| 13 | `0x100b7fc7` | **Nt\*** dyn-resolved check (int3-guarded) — likely `NtSetInformationThread(ThreadHideFromDebugger)` verify | — | `0x100b80b2` |
| 14 | `0x100b8167` | **Trap Flag** single-step — `pushfd; or [esp+1],1; popfd` | `test/je` @ `0x100b815c` | `0x100b82e4` |

**Shared magic marker** built by all 14: 64-bit `0x18d790b0_204bda9c`
(`0x204bda9c` low, `0x18d790b0` high). Each vector then adds a **site-specific
64-bit ID** (e.g. vector 1 = `0xb49f40f8_275ba25d`, vector 2 = `0xa2934df4_2a5aa25d`)
— identifies to the server *which* vector tripped. Payload is XOR-decrypted with
SSE right before the sink call.

---

## x32dbg / dynamic-analysis breakpoint set

Set these once the DLL is loaded (rebase to runtime base first):

```
# Master observation point — catches ALL vectors, shows which one fired:
bp Extensions.dll+0xb4a50          # sub_100b5650 entry; inspect [esp+8]=&blob, [esp+4]=severity

# Per-vector gates (break to see the check result before it decides):
bp Extensions.dll+0xb4f18          # v1  PEB.BeingDebugged  — set ZF to take je (skip)
bp Extensions.dll+0xb5116          # v2  CheckRemoteDebuggerPresent
bp Extensions.dll+0xb5388          # v3  FindWindowW
bp Extensions.dll+0xb5e78          # v6  hardware DR scan
bp Extensions.dll+0xb6916          # v11 NtGlobalFlag
```

**To pass a live check dynamically:** at each gate BP, force the detection value
to the "clean" value so the `je` is taken:
- v1: set `[esp+0xc] = 0` before the `cmp`
- v2: set `[esp+0xc] = 0` after CRDP returns
- v6: set `esi = 0` before `test esi,esi` @ `0x100b6a76`
- v11: set `[esp+0xc] = 0` (mask already isolates `& 0x70`)

---

## Open items / next RE

- [ ] Identify what `sub_100b5650` actually does with the blob (network report via
      Extensions' WS2_32 path? local flag? staged for MMgr64 pickup?). Trace its body.
- [ ] Decode a couple site-specific IDs fully (XOR key vs data halves) to recover
      the plaintext report struct format.
- [ ] Confirm vectors 12/13 Nt* targets (NtQueryInformationProcess class +
      NtSetInformationThread) by resolving the `GetProcAddress` name strings feeding `esi`.
- [ ] **Before any patch:** map DivxTac.dll `DetourMgr`/`DetectHackModules` and
      MMgr64.exe integrity coverage — does it hash `.text` of Extensions.dll? If so,
      the sink patch must be paired with integrity-check neutralization.
- [ ] Check whether this whole module is called on a timer/thread vs once at init
      (find callers of the 14 vector functions' parents).

---

## Tooling produced (re/scripts/)

- `xref_imports.py <pe> [apis...]` — IAT thunk → call-site xref finder
- `disasm_window.py <pe> <va...> [--before N --after N]` — annotated disasm window
- `const_xref.py <pe> <const...>` — find all refs to an immediate (magic-marker mapping)
- `classify_checks.py <pe> <va...>` — show technique-before + sink-after per site
